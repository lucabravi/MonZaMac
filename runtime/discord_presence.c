// Discord's local RPC transport. All I/O stays off the game and rendering threads.
#include "discord_presence.h"
#include <SDL3/SDL.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <pthread.h>
#ifdef _WIN32
#include <windows.h>
typedef HANDLE connection;
#define BAD_CONNECTION INVALID_HANDLE_VALUE
#else
#include <errno.h>
#include <fcntl.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>
typedef int connection;
#define BAD_CONNECTION (-1)
#endif

// Shared with the Windows/Linux port so both appear under the same Discord application.
#define CLIENT_ID "1569847514134351932"
#ifndef DISCORD_IDLE_MS
#define DISCORD_IDLE_MS (5 * 60 * 1000)
#endif
static SDL_Thread *worker;
static atomic_bool running;
static time_t started;
static _Atomic uint64_t last_input_ms;
static pthread_mutex_t trainer_lock = PTHREAD_MUTEX_INITIALIZER;
static char trainer[24];

void discord_presence_note_input(void) {
    atomic_store_explicit(&last_input_ms, SDL_GetTicks(), memory_order_relaxed);
}

void discord_presence_set_trainer(const char *name) {
    pthread_mutex_lock(&trainer_lock);
    snprintf(trainer, sizeof trainer, "%s", name ? name : "");
    pthread_mutex_unlock(&trainer_lock);
}

static void trainer_json(char *out, size_t capacity) {
    char name[sizeof trainer];
    pthread_mutex_lock(&trainer_lock);
    memcpy(name, trainer, sizeof name);
    pthread_mutex_unlock(&trainer_lock);
    size_t j = 0;
    for (size_t i = 0; name[i] && j + 7 < capacity; ++i) {
        unsigned char ch = (unsigned char)name[i];
        if (ch < 0x20) { j += (size_t)snprintf(out + j, capacity - j, "\\u%04x", ch); }
        else { if (ch == '"' || ch == '\\') out[j++] = '\\'; out[j++] = (char)ch; }
    }
    out[j] = 0;
}

static void disconnect(connection c) {
#ifdef _WIN32
    CloseHandle(c);
#else
    close(c);
#endif
}
static connection connect_discord(void) {
    for (int i = 0; i < 10; ++i) {
#ifdef _WIN32
        char path[80];
        snprintf(path, sizeof path, "\\\\.\\pipe\\discord-ipc-%d", i);
        HANDLE c = CreateFileA(path, GENERIC_READ | GENERIC_WRITE, 0, NULL, OPEN_EXISTING, 0, NULL);
        if (c != BAD_CONNECTION) {
            DWORD mode = PIPE_READMODE_BYTE | PIPE_NOWAIT;
            if (SetNamedPipeHandleState(c, &mode, NULL, NULL)) return c;
            CloseHandle(c);
        }
#else
        const char *dir = getenv("XDG_RUNTIME_DIR");
        if (!dir || !*dir) dir = getenv("TMPDIR");
        if (!dir || !*dir) dir = getenv("TMP");
        if (!dir || !*dir) dir = getenv("TEMP");
        if (!dir || !*dir) dir = "/tmp";
        struct sockaddr_un addr = {0};
        addr.sun_family = AF_UNIX;
        if (snprintf(addr.sun_path, sizeof addr.sun_path, "%s/discord-ipc-%d", dir, i) >= (int)sizeof addr.sun_path) continue;
        int c = socket(AF_UNIX, SOCK_STREAM, 0);
        if (c < 0) continue;
        int flags = fcntl(c, F_GETFL, 0);
        if (flags >= 0 && fcntl(c, F_SETFL, flags | O_NONBLOCK) == 0) {
            if (connect(c, (struct sockaddr *)&addr, sizeof addr) == 0) {
#ifdef SO_NOSIGPIPE
                int yes = 1;
                setsockopt(c, SOL_SOCKET, SO_NOSIGPIPE, &yes, sizeof yes);
#endif
                return c;
            }
        }
        close(c);
#endif
    }
    return BAD_CONNECTION;
}
static int send_frame(connection c, unsigned op, const char *payload, size_t len) {
    unsigned char frame[4096];
    if (len > sizeof frame - 8) return 0;
    for (int i = 0; i < 4; ++i) { frame[i] = (unsigned char)(op >> (8*i)); frame[i+4] = (unsigned char)(len >> (8*i)); }
    memcpy(frame + 8, payload, len);
#ifdef _WIN32
    DWORD n = 0;
    return WriteFile(c, frame, (DWORD)(len + 8), &n, NULL) && n == len + 8;
#else
#ifdef MSG_NOSIGNAL
    ssize_t n = send(c, frame, len + 8, MSG_NOSIGNAL);
#else
    ssize_t n = send(c, frame, len + 8, 0);
#endif
    return n == (ssize_t)(len + 8);
#endif
}
// Returns zero when disconnected, one when no more data is available.
static int receive_frames(connection c, unsigned char *buf, size_t *used, int *ready) {
    for (;;) {
#ifdef _WIN32
        DWORD avail = 0, n = 0;
        if (!PeekNamedPipe(c, NULL, 0, NULL, &avail, NULL)) return 0;
        if (!avail) break;
        if (*used == 65536 || !ReadFile(c, buf + *used, (DWORD)(65536 - *used), &n, NULL) || !n) return 0;
#else
        if (*used == 65536) return 0;
        ssize_t n = recv(c, buf + *used, 65536 - *used, 0);
        if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) break;
        if (n <= 0) return 0;
#endif
        *used += (size_t)n;
        while (*used >= 8) {
            uint32_t op = 0, len = 0;
            for (int i = 0; i < 4; ++i) { op |= (uint32_t)buf[i] << (8*i); len |= (uint32_t)buf[i+4] << (8*i); }
            if (len > 65528) return 0;
            if (*used < (size_t)len + 8) break;
            if (op == 2) return 0;
            if (op == 3 && !send_frame(c, 4, (const char *)buf + 8, len)) return 0;
            // The first frame after handshake is READY; an error or close is not a successful handshake.
            if (op == 1 && !*ready) {
                unsigned char saved = *used > 8 + len ? buf[8 + len] : 0;
                buf[8 + len] = 0;
                int is_ready = strstr((char *)buf + 8, "\"READY\"") != NULL;
                buf[8 + len] = saved;
                if (!is_ready) return 0;
                *ready = 1;
            }
            memmove(buf, buf + 8 + len, *used - 8 - len);
            *used -= 8 + len;
        }
    }
    return 1;
}
static int presence_thread(void *unused) {
    (void)unused;
    unsigned char *buf = malloc(65537);
    if (!buf) return 0;
    connection c = BAD_CONNECTION;
    size_t used = 0;
    int ready = 0, sent = 0, retry = 0, handshake_wait = 0;
    int last_idle = 0;
    char last_name[160] = "";
    while (atomic_load(&running)) {
        if (c == BAD_CONNECTION && retry-- <= 0) {
            c = connect_discord();
            used = 0; ready = sent = handshake_wait = 0;
            if (c != BAD_CONNECTION && !send_frame(c, 0, "{\"v\":1,\"client_id\":\"" CLIENT_ID "\"}", strlen("{\"v\":1,\"client_id\":\"" CLIENT_ID "\"}"))) { disconnect(c); c = BAD_CONNECTION; }
            retry = 50;
        }
        if (c != BAD_CONNECTION) {
            int ok = receive_frames(c, buf, &used, &ready);
            if (ok && !ready && ++handshake_wait > 50) ok = 0;
            char name[160];
            trainer_json(name, sizeof name);
            uint64_t now = SDL_GetTicks();
            uint64_t last = atomic_load_explicit(&last_input_ms, memory_order_relaxed);
            int idle = now >= last && now - last >= DISCORD_IDLE_MS;
            if (ok && ready && (!sent || strcmp(name, last_name) || idle != last_idle)) {
                char json[512];
#ifdef _WIN32
                unsigned long pid = GetCurrentProcessId();
#else
                unsigned long pid = (unsigned long)getpid();
#endif
                snprintf(json, sizeof json, "{\"cmd\":\"SET_ACTIVITY\",\"args\":{\"pid\":%lu,\"activity\":{\"details\":\"%s\",%s%s%s\"timestamps\":{\"start\":%lld}}},\"nonce\":\"za-presence\"}", pid, idle ? "Relaxing in Lumiose" : "Exploring Lumiose", *name ? "\"state\":\"Trainer: " : "", name, *name ? "\"," : "", (long long)started);
                ok = send_frame(c, 1, json, strlen(json)); sent = ok;
                if (ok) { memcpy(last_name, name, strlen(name) + 1); last_idle = idle; }
            }
            if (!ok) { disconnect(c); c = BAD_CONNECTION; retry = 50; }
        }
        SDL_Delay(100);
    }
    if (c != BAD_CONNECTION) {
        char json[192];
#ifdef _WIN32
        unsigned long pid = GetCurrentProcessId();
#else
        unsigned long pid = (unsigned long)getpid();
#endif
        snprintf(json, sizeof json, "{\"cmd\":\"SET_ACTIVITY\",\"args\":{\"pid\":%lu,\"activity\":null},\"nonce\":\"za-clear\"}", pid);
        if (ready) send_frame(c, 1, json, strlen(json));
        disconnect(c);
    }
    free(buf);
    return 0;
}
void discord_presence_start(void) {
    const char *disabled = getenv("LARECOMP_DISCORD");
    if (worker || (disabled && !strcmp(disabled, "0"))) return;
    started = time(NULL);
    discord_presence_note_input();
    atomic_store(&running, 1);
    worker = SDL_CreateThread(presence_thread, "Discord presence", NULL);
    if (!worker) atomic_store(&running, 0);
}
void discord_presence_stop(void) {
    if (!worker) return;
    atomic_store(&running, 0);
    SDL_WaitThread(worker, NULL);
    worker = NULL;
    discord_presence_set_trainer(NULL);
}
