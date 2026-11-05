#pragma once
#include <stdbool.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
// True only while synthetic images are actually reaching the display.
bool fg_presentation_active(double *display_fps);
void fg_presentation_stats(uint64_t *real, uint64_t *generated, double *display_fps);
#ifdef __cplusplus
}
#endif
