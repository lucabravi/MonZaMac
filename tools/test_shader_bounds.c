// Truncated shader containers must fail before reading headers or scanning instructions.
#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "../runtime/nvn/maxwell/shader.h"

typedef struct { const char *name; int stage; size_t size; bool header, valid; } Case;
static const Case cases[] = {
    {"fragment-short", STAGE_FRAGMENT, 1},
    {"vertex-short", STAGE_VERTEX, 0x7f},
    {"graphics-header-only", STAGE_VERTEX, 0x80},
    {"graphics-schedule-only", STAGE_FRAGMENT, 0x88},
    {"compute-empty", STAGE_COMPUTE, 0},
    {"compute-short-magic", STAGE_COMPUTE, 3},
    {"compute-schedule-only", STAGE_COMPUTE, 8},
    {"compute-truncated-header", STAGE_COMPUTE, 4, true},
    {"compute-header-only", STAGE_COMPUTE, 0x100, true},
    {"compute-header-schedule-only", STAGE_COMPUTE, 0x108, true},
    {"vertex-valid", STAGE_VERTEX, 0x90, false, true},
    {"fragment-valid", STAGE_FRAGMENT, 0x90, false, true},
    {"compute-valid", STAGE_COMPUTE, 0x10, false, true},
    {"compute-header-valid", STAGE_COMPUTE, 0x110, true, true},
};

int main(int argc, char **argv) {
    assert(argc == 2);
    if (!strcmp(argv[1], "null-input")) {
        ShaderInfo *s = maxwell_translate(NULL, 0, STAGE_FRAGMENT, NULL);
        assert(s && !s->msl && s->error[0]); maxwell_free(s);
    } else {
        size_t i;
        for (i = 0; i < sizeof cases / sizeof *cases && strcmp(cases[i].name, argv[1]); i++) {}
        assert(i < sizeof cases / sizeof *cases);
        const Case *c = &cases[i];
        uint8_t *bytes = calloc(1, c->size ? c->size : 1); assert(bytes);
        if (c->header) { uint32_t magic = 0x12345679; memcpy(bytes, &magic, sizeof magic); }
        if (c->valid) {
            size_t start = c->stage == STAGE_COMPUTE ? (c->header ? 0x100 : 0) : 0x80;
            uint64_t exit_op = 0xe30000000007000full;
            memcpy(bytes + start + 8, &exit_op, sizeof exit_op);
        }
        for (int glsl = 0; glsl < 2; glsl++) {
            ShaderKey key = {.glsl = glsl};
            ShaderInfo *s = maxwell_translate(bytes, c->size, c->stage, &key);
            assert(s);
            assert(c->valid ? s->msl != NULL : s->msl == NULL && s->error[0]);
            maxwell_free(s);
        }
        free(bytes);
    }
    printf("PASS %s\n", argv[1]);
    return 0;
}
