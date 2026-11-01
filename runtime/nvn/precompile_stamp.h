// "Prepare all shaders": what was done, so the start screen can say whether it is still good.
#pragma once
#include <stdbool.h>
#ifdef __cplusplus
extern "C" {
#endif
// Bump when a precompile has to be redone: the translator's output changed (the libraries it made no longer match what the
// game asks for) or the precompile covers more kinds of shader than before.
#define SHADER_PRECOMPILE_VERSION 1

typedef enum { PRECOMPILE_NOT_DONE, PRECOMPILE_CURRENT, PRECOMPILE_OUTDATED } PrecompileState;

// root: the game files (<root>/exefs, <root>/romfs). Reads cache/shader-precompile/stamp.txt and compares it with this
// build, macOS, the GPU and the game files; `reason` (may be NULL) gets a short sentence for the first difference.
PrecompileState precompile_state(const char *root, char *reason, unsigned reason_size);
// After a complete run: records the version, macOS, GPU, the game files and how many shaders were compiled.
bool precompile_write_stamp(const char *root, unsigned shaders);
// The pure comparison, for tests: two stamps in the stamp file's text form.
PrecompileState precompile_compare(const char *saved, const char *now, char *reason, unsigned reason_size);
#ifdef __cplusplus
}
#endif
