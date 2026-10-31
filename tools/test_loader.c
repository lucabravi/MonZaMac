// Exercise the production NSO/LZ4 loader with synthetic data, including under sanitizers.
#include <errno.h>
#include "../runtime/loader.c"

static uint8_t *test_memory;
void plat_commit(uint64_t addr, uint64_t size) {
    if (addr != (uintptr_t)test_memory || size > 0x4000) exit(43);
}
void rt_fatal_msg(const char *fmt, ...) { (void)fmt; }
void rt_fatal_trace(void) { exit(42); }
uint64_t hle_register(const char *name, HostFn fn) { (void)name; (void)fn; return 0; }
HostFn hle_lookup_impl(const char *name) { (void)name; return NULL; }

int main(int argc, char **argv) {
    if (argc == 3 && !strcmp(argv[1], "load")) {
        test_memory = calloc(1, 0x4000);
        if (!test_memory) return 44;
        Module m = {.name = "synthetic"};
        load_nso(&m, argv[2], (uintptr_t)test_memory);
        relocate(&m);
        for (uint64_t i = 0; i < m.nsyms; i++) (void)symname(&m, sym(&m, i));
        fwrite(test_memory, 1, 0x2200, stdout);
        free(test_memory);
        return 0;
    }
    if (argc != 4 || strcmp(argv[1], "lz4")) return 45;
    size_t n = strlen(argv[2]) / 2, cap = strtoul(argv[3], NULL, 0);
    uint8_t *src = malloc(n ? n : 1), *dst = malloc(cap ? cap : 1);
    if (!src || !dst) return 44;
    for (size_t i = 0; i < n; i++) {
        char byte[3] = {argv[2][2 * i], argv[2][2 * i + 1], 0};
        src[i] = (uint8_t)strtoul(byte, NULL, 16);
    }
    size_t got = lz4_decompress(src, n, dst, cap);
    if (got == SIZE_MAX) { free(src); free(dst); return 42; }
    fwrite(dst, 1, got, stdout);
    free(src); free(dst);
    return 0;
}
