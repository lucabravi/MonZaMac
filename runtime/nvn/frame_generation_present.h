#pragma once
#include <stdbool.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
void fg_presentation_stats(uint64_t *real, uint64_t *generated, double *display_fps);
#ifdef __cplusplus
}
#endif
