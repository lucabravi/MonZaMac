// Exercise the production IFile handler with real temporary files and injected OS failures.
#include <assert.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#ifndef __APPLE__
static size_t test_strlcpy(char *dst, const char *src, size_t cap) {
    size_t n = strlen(src);
    if (cap) { size_t k = n < cap - 1 ? n : cap - 1; memcpy(dst, src, k); dst[k] = 0; }
    return n;
}
static size_t test_strlcat(char *dst, const char *src, size_t cap) {
    size_t n = strnlen(dst, cap);
    return n + test_strlcpy(dst + n, src, cap - n);
}
#define strlcpy test_strlcpy
#define strlcat test_strlcat
#endif

static int write_interrupts, read_interrupts, sync_interrupts, sync_error, write_zero;
static size_t write_limit, bytes_written;
static int64_t fail_after = -1;

static ssize_t test_pwrite(int fd, const void *p, size_t size, off_t off) {
    if (write_interrupts) { write_interrupts--; errno = EINTR; return -1; }
    if (write_zero) return 0;
    if (fail_after >= 0) {
        if (bytes_written >= (uint64_t)fail_after) { errno = ENOSPC; return -1; }
        if (size > (uint64_t)fail_after - bytes_written) size = (uint64_t)fail_after - bytes_written;
    }
    if (write_limit && size > write_limit) size = write_limit;
    ssize_t n = pwrite(fd, p, size, off);
    if (n > 0) bytes_written += (size_t)n;
    return n;
}
static ssize_t test_pread(int fd, void *p, size_t size, off_t off) {
    if (read_interrupts) { read_interrupts--; errno = EINTR; return -1; }
    return pread(fd, p, size, off);
}
static int test_fsync(int fd) {
    if (sync_interrupts) { sync_interrupts--; errno = EINTR; return -1; }
    if (sync_error) { errno = EIO; return -1; }
    return fsync(fd);
}

#define pwrite test_pwrite
#define pread test_pread
#define fsync test_fsync
#include "../runtime/services/fs.c"
#undef pwrite
#undef pread
#undef fsync
#include "../runtime/ipc.c"
#include "../runtime/saves.c"

_Static_assert(offsetof(IpcResp, data) % _Alignof(uint64_t) == 0, "IPC response payload alignment");

// Unused RomFS / host-service dependencies; the IFile handler above is unchanged.
const char *g_romfs_dir = ".";
bool shader_trace_enabled(void) { return false; }
void shader_trace_read(const char *p, uint64_t off, uint64_t dst, size_t n) { (void)p; (void)off; (void)dst; (void)n; }
const char *pl_prompt_set(void) { return "default"; }
const SaveInfo *save_info(const char *slot) { (void)slot; return NULL; }
void save_info_invalidate(const char *slot) { (void)slot; }
PlatProc plat_spawn(const char *const argv[], const char *log, bool append) { (void)argv; (void)log; (void)append; return 0; }
int plat_proc_wait(PlatProc p, bool block) { (void)p; (void)block; return -1; }
void rt_fatal_msg(const char *fmt, ...) { (void)fmt; }
void rt_fatal_trace(void) { abort(); }
int plat_open_file(const char *path, int flags) { return open(path, flags, 0600); }
int plat_rename(const char *from, const char *to) { return rename(from, to); }
static KObject *test_handles[16];
uint32_t kernel_new_handle(KObject *obj) {
    for (uint32_t h = 1; h < 16; h++) if (!test_handles[h]) { test_handles[h] = obj; return h; }
    abort();
}
KObject *handle_get(uint32_t h) { return h < 16 ? test_handles[h] : NULL; }

static void close_session(uint32_t handle) {
    uint32_t msg[64] __attribute__((aligned(16))) = {2, 0};  // HIPC Close
    Cpu cpu = {.tpidrro = (uintptr_t)msg};
    assert(ipc_handle_request(&cpu, handle) == 0);
    free(test_handles[handle]); test_handles[handle] = NULL;
}

static void check_close(const char *name) {
    bool isdir = !strcmp(name, "close-directory"), clone = strstr(name, "cloned") != NULL;
    bool aoc = strstr(name, "aoc") != NULL;
    char root[] = "/tmp/monzamac-handles.XXXXXX"; assert(mkdtemp(root));
    char path[256], addon[256], romfs[256];
    if (aoc) { snprintf(addon, sizeof addon, "%s/aoc", root); assert(!mkdir(addon, 0700)); }
    snprintf(path, sizeof path, "%s/%s", root, aoc ? "aoc/0000000000000001.bin" : "file.bin");
    int created = open(path, O_CREAT | O_EXCL | O_RDWR, 0600); assert(created >= 0); assert(!close(created));
    HostFs fs = {0}; strlcpy(fs.root, root, sizeof fs.root);
    Service mount = {.state = &fs};
    uint32_t mode = 1;
    const char *guest_path = isdir ? "/" : "/file.bin";
    IpcReq req = {.cmd = isdir ? 9 : 8, .data = (const uint8_t *)&mode, .data_size = sizeof mode, .nx = 1};
    req.x[0] = (IpcBuf){(uintptr_t)guest_path, strlen(guest_path) + 1};
    IpcResp resp = {0};
    if (aoc) {
        snprintf(romfs, sizeof romfs, "%s/romfs", root); g_romfs_dir = romfs;
        uint64_t args[2] = {0, 1};
        req = (IpcReq){.cmd = 202, .data = (const uint8_t *)args, .data_size = sizeof args};
        fsp_srv(NULL, &req, &resp);
    } else filesystem(&mount, &req, &resp);
    assert(!resp.result && resp.nobjects == 1);
    Service *obj = resp.objects[0];
    int fd = isdir ? dirfd(((HostDir *)obj->state)->d) : aoc ? ((Storage *)obj->state)->fd : ((HostFile *)obj->state)->fd;
    uint32_t first = session_new(obj), second = clone ? session_new(obj) : 0;
    close_session(first);
    if (second) { assert(fcntl(fd, F_GETFD) >= 0); close_session(second); }
    errno = 0;
    assert(fcntl(fd, F_GETFD) == -1 && errno == EBADF);
    assert(!obj->state);
    free((char *)obj->name); free(obj);
    assert(!unlink(path));
    if (aoc) { assert(!rmdir(addon)); g_romfs_dir = "."; }
    assert(!rmdir(root));
    printf("PASS %s\n", name);
}

// A ".." path must not reach outside the mounted root (CreateFile / OpenFile), a name that merely contains dots may.
static void check_confine(void) {
    char root[] = "/tmp/monzamac-confine.XXXXXX"; assert(mkdtemp(root));
    char outside[300]; snprintf(outside, sizeof outside, "%s.outside", root);
    HostFs fs = {0}; strlcpy(fs.root, root, sizeof fs.root);
    Service mount = {.state = &fs};
    const char *paths[] = {"/../x.outside", "/a/../../x.outside", "/..", "/..bin"};
    for (int i = 0; i < 4; i++) {
        char rel[64]; snprintf(rel, sizeof rel, "%s", paths[i]);
        int64_t size[2] = {0, 1};
        IpcReq req = {.cmd = 0, .data = (const uint8_t *)size, .data_size = 16, .nx = 1};
        req.x[0] = (IpcBuf){(uintptr_t)rel, strlen(rel) + 1};
        IpcResp resp = {0};
        filesystem(&mount, &req, &resp);
        if (i < 3) assert(resp.result == FS_PATH_NOT_FOUND);
        else assert(!resp.result);
    }
    assert(access(outside, F_OK) != 0);
    char dots[300]; snprintf(dots, sizeof dots, "%s/..bin", root);
    assert(!unlink(dots)); assert(!rmdir(root));
    printf("PASS confine\n");
}

static void check_link_paths(void) {
    char root[] = "/tmp/monzamac-links.XXXXXX"; assert(mkdtemp(root));
    char real[300], mount[300], outside[300], path[400];
    snprintf(real, sizeof real, "%s/real", root); assert(!mkdir(real, 0700));
    snprintf(mount, sizeof mount, "%s/mount", root); assert(!symlink("real", mount));
    snprintf(outside, sizeof outside, "%s/outside", root); assert(!mkdir(outside, 0700));
    snprintf(path, sizeof path, "%s/internal", real); assert(!symlink(".", path));
    snprintf(path, sizeof path, "%s/external", real); assert(!symlink("../outside", path));
    snprintf(path, sizeof path, "%s/leaf", real); assert(!symlink("../outside/sentinel", path));
    snprintf(path, sizeof path, "%s/sentinel", outside);
    int fd = open(path, O_CREAT | O_EXCL | O_RDWR, 0600); assert(fd >= 0); assert(!close(fd));
    HostFs fs = {0}; strlcpy(fs.root, mount, sizeof fs.root);
    Service svc = {.state = &fs};
    const char *paths[] = {"/created", "/internal/new", "/external/new", "/leaf"};
    for (int i = 0; i < 4; i++) {
        uint64_t args[2] = {0, 1};
        IpcReq req = {.cmd = i == 3 ? 8 : 0, .data = (const uint8_t *)args, .data_size = sizeof args, .nx = 1};
        req.x[0] = (IpcBuf){(uintptr_t)paths[i], strlen(paths[i]) + 1};
        IpcResp resp = {0}; filesystem(&svc, &req, &resp);
        assert(i ? resp.result == FS_PATH_NOT_FOUND : !resp.result);
    }
    snprintf(path, sizeof path, "%s/created", real); assert(!access(path, F_OK));
    snprintf(path, sizeof path, "%s/new", real); assert(access(path, F_OK));
    snprintf(path, sizeof path, "%s/new", outside); assert(access(path, F_OK));
    assert(!host_path(&fs, "/created", path, 8));  // a truncated host path must never reach a file operation
    remove_tree(root);
    puts("PASS confine-links");
}

static void check_recursive_links(const char *name) {
    bool clean = strstr(name, "clean") != NULL, missing = strstr(name, "missing") != NULL;
    char root[] = "/tmp/monzamac-recursive.XXXXXX"; assert(mkdtemp(root));
    char mount[300], victim[320], outside[300], sentinel[320], link[350];
    snprintf(mount, sizeof mount, "%s/mount", root); assert(!mkdir(mount, 0700));
    snprintf(outside, sizeof outside, "%s/outside", root); assert(!mkdir(outside, 0700));
    snprintf(sentinel, sizeof sentinel, "%s/keep", outside);
    int fd = open(sentinel, O_CREAT | O_EXCL | O_RDWR, 0600); assert(fd >= 0); assert(!close(fd));
    snprintf(victim, sizeof victim, "%s/victim", mount);
    snprintf(link, sizeof link, "%s/link", victim);
    if (!missing) { assert(!mkdir(victim, 0700)); assert(!symlink("../../outside", link)); }
    HostFs fs = {0}; strlcpy(fs.root, mount, sizeof fs.root); Service svc = {.state = &fs};
    const char *guest = "/victim";
    IpcReq req = {.cmd = clean ? 13 : 4, .nx = 1};
    req.x[0] = (IpcBuf){(uintptr_t)guest, strlen(guest) + 1};
    IpcResp resp = {0}; filesystem(&svc, &req, &resp);
    assert(!access(sentinel, F_OK));
    assert(missing ? resp.result == FS_PATH_NOT_FOUND : !resp.result);
    if (!missing) {
        assert(access(link, F_OK));
        assert(clean ? !access(victim, F_OK) : access(victim, F_OK));
    }
    remove_tree(root);
    printf("PASS %s\n", name);
}

static const char old_bytes[] = "old committed data";
static const char new_bytes[] = "new complete bytes";

static void check_bytes(int fd, const void *expected, size_t size) {
    char actual[64] = {0};
    assert(size <= sizeof actual);
    assert(pread(fd, actual, size, 0) == (ssize_t)size);
    assert(!memcmp(actual, expected, size));
}

static void check_route_mounts(void) {
    char root[] = "/tmp/monzamac-route.XXXXXX", previous[PATH_MAX];
    assert(getcwd(previous, sizeof previous) && mkdtemp(root) && !chdir(root));
    assert(!mkdir("routes", 0700)); assert(!mkdir("routes/Replay", 0700));
    assert(!mkdir("routes/Replay/save", 0700)); assert(!mkdir("routes/Replay/save/save_0", 0700));
    int fd = open("routes/Replay/save/save_0/main", O_CREAT | O_EXCL | O_RDWR, 0600); assert(fd >= 0);
    assert(write(fd, old_bytes, sizeof old_bytes) == sizeof old_bytes); assert(!close(fd));
    assert(!setenv("LARECOMP_ROUTE", "Replay", 1));
    assert(!setenv("LARECOMP_SAVE_DIR", "other", 1));  // the route takes precedence on every mount
    Service *mounts[4];
    mounts[0] = open_host_fs("save_0");
    fd = open("build/route-run/save_0/main", O_RDWR); assert(fd >= 0);
    assert(pwrite(fd, new_bytes, sizeof new_bytes, 0) == sizeof new_bytes); assert(!close(fd));
    mounts[1] = open_host_fs("sdcard");
    mounts[2] = open_host_fs("save_0");
    assert(!strcmp(((HostFs *)mounts[1]->state)->root, "build/route-run/sdcard"));
    fd = open("build/route-run/save_0/main", O_RDONLY); assert(fd >= 0);
    check_bytes(fd, new_bytes, sizeof new_bytes); assert(!close(fd));
    fs_reset();  // a new game session deliberately starts from the recorded snapshot again
    mounts[3] = open_host_fs("save_0");
    fd = open("build/route-run/save_0/main", O_RDONLY); assert(fd >= 0);
    check_bytes(fd, old_bytes, sizeof old_bytes); assert(!close(fd));
    fd = open("routes/Replay/save/save_0/main", O_RDONLY); assert(fd >= 0);
    check_bytes(fd, old_bytes, sizeof old_bytes); assert(!close(fd));
    for (int i = 0; i < 4; i++) { free(mounts[i]->state); free((char *)mounts[i]->name); free(mounts[i]); }
    unsetenv("LARECOMP_ROUTE"); unsetenv("LARECOMP_SAVE_DIR"); fs_reset();
    assert(!chdir(previous)); remove_tree(root);
    puts("PASS route-mounts");
}

int main(int argc, char **argv) {
    assert(argc == 2);
    if (!strcmp(argv[1], "route-mounts")) { check_route_mounts(); return 0; }
    if (!strcmp(argv[1], "confine")) { check_confine(); return 0; }
    if (!strcmp(argv[1], "confine-links")) { check_link_paths(); return 0; }
    if (!strncmp(argv[1], "recursive-", 10)) { check_recursive_links(argv[1]); return 0; }
    if (!strncmp(argv[1], "close-", 6)) { check_close(argv[1]); return 0; }
    char path[] = "/tmp/monzamac-file-io.XXXXXX";
    int fd = mkstemp(path); assert(fd >= 0); assert(!unlink(path));
    assert(pwrite(fd, old_bytes, sizeof old_bytes, 0) == sizeof old_bytes);
    HostFile state = {.fd = fd};
    Service svc = {.state = &state};
    uint64_t args[3] = {0, 0, sizeof new_bytes};
    IpcReq req = {.cmd = 1, .data = (const uint8_t *)args, .data_size = sizeof args, .na = 1};
    req.a[0] = (IpcBuf){(uintptr_t)new_bytes, sizeof new_bytes};
    IpcResp resp = {0};

    if (!strcmp(argv[1], "short-write")) {
        write_limit = 3;
        file(&svc, &req, &resp);
        assert(!resp.result);
        check_bytes(fd, new_bytes, sizeof new_bytes);
    } else if (!strcmp(argv[1], "interrupted-write")) {
        write_interrupts = 2;
        file(&svc, &req, &resp);
        assert(!resp.result);
        check_bytes(fd, new_bytes, sizeof new_bytes);
    } else if (!strcmp(argv[1], "partial-failure")) {
        fail_after = 4;
        file(&svc, &req, &resp);
        assert(resp.result);
        check_bytes(fd, "new ", 4);
    } else if (!strcmp(argv[1], "zero-write")) {
        write_zero = 1;
        file(&svc, &req, &resp);
        assert(resp.result);
        check_bytes(fd, old_bytes, sizeof old_bytes);
    } else if (!strcmp(argv[1], "oversized-write")) {
        req.a[0].size = 3;
        file(&svc, &req, &resp);
        assert(resp.result == MAKE_RESULT(2, 6001));
        check_bytes(fd, old_bytes, sizeof old_bytes);
    } else if (!strcmp(argv[1], "missing-write-buffer")) {
        req.na = 0;
        file(&svc, &req, &resp);
        assert(resp.result == MAKE_RESULT(2, 6001));
        check_bytes(fd, old_bytes, sizeof old_bytes);
    } else if (!strcmp(argv[1], "negative-write-size") || !strcmp(argv[1], "negative-write-offset") ||
               !strcmp(argv[1], "write-offset-overflow")) {
        if (!strcmp(argv[1], "negative-write-size")) args[2] = UINT64_MAX;
        else if (!strcmp(argv[1], "negative-write-offset")) args[1] = UINT64_MAX;
        else args[1] = INT64_MAX - 2;
        file(&svc, &req, &resp);
        assert(resp.result == MAKE_RESULT(2, 6001));
        check_bytes(fd, old_bytes, sizeof old_bytes);
    } else if (!strcmp(argv[1], "flush-error") || !strcmp(argv[1], "interrupted-flush")) {
        req.cmd = 2;
        if (!strcmp(argv[1], "flush-error")) sync_error = 1;
        else sync_interrupts = 2;
        file(&svc, &req, &resp);
        assert(sync_error ? resp.result != 0 : resp.result == 0);
        assert(sync_interrupts == 0);
    } else if (!strcmp(argv[1], "read-error") || !strcmp(argv[1], "interrupted-read") ||
               !strcmp(argv[1], "missing-read-buffer") || !strcmp(argv[1], "negative-read-size") ||
               !strcmp(argv[1], "negative-read-offset") || !strcmp(argv[1], "read-offset-overflow") ||
               !strcmp(argv[1], "bounded-read") || !strcmp(argv[1], "read-eof")) {
        char actual[sizeof old_bytes]; memset(actual, '!', sizeof actual);
        req.cmd = 0; req.na = 0; req.nb = 1;
        args[2] = sizeof actual;
        req.b[0] = (IpcBuf){(uintptr_t)actual, sizeof actual};
        if (!strcmp(argv[1], "read-error")) state.fd = -1;
        else if (!strcmp(argv[1], "interrupted-read")) read_interrupts = 2;
        else if (!strcmp(argv[1], "missing-read-buffer")) req.nb = 0;
        else if (!strcmp(argv[1], "negative-read-size")) args[2] = UINT64_MAX;
        else if (!strcmp(argv[1], "negative-read-offset")) args[1] = UINT64_MAX;
        else if (!strcmp(argv[1], "read-offset-overflow")) args[1] = INT64_MAX - 2;
        else if (!strcmp(argv[1], "bounded-read")) req.b[0].size = 3;
        else args[1] = sizeof old_bytes;
        file(&svc, &req, &resp);
        int64_t nread;
        memcpy(&nread, resp.data, sizeof nread);
        if (!strcmp(argv[1], "interrupted-read")) {
            assert(!resp.result && nread == sizeof old_bytes);
            assert(!memcmp(actual, old_bytes, sizeof actual));
        } else if (!strcmp(argv[1], "bounded-read")) {
            assert(!resp.result && nread == 3);
            assert(!memcmp(actual, "old", 3) && actual[3] == '!');
        } else if (!strcmp(argv[1], "read-eof")) {
            assert(!resp.result && nread == 0 && actual[0] == '!');
        } else {
            assert(resp.result);
            assert(actual[0] == '!');
        }
    } else if (!strcmp(argv[1], "getsize-error") || !strcmp(argv[1], "getsize")) {
        if (!strcmp(argv[1], "getsize-error")) state.fd = -1;
        req.cmd = 4;
        file(&svc, &req, &resp);
        if (state.fd < 0) assert(resp.result);
        else {
            int64_t size;
            memcpy(&size, resp.data, sizeof size);
            assert(!resp.result && size == sizeof old_bytes);
        }
    } else {
        fprintf(stderr, "unknown case: %s\n", argv[1]); return 2;
    }
    assert(!close(fd));
    printf("PASS %s\n", argv[1]);
    return 0;
}
