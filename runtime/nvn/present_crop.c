// How the game's 1920x1080 image is shown in a window of another shape. The game always draws 16:9, so a window that
// is wider or taller than that shows the 16:9 part in the middle (bars at the sides, or above and below). Called by
// the presenter (runtime/nvn/metal.m) with the window shape from output_scale.c.
#include <stdbool.h>

#include "../hle.h"
#include "../settings.h"

bool present_unlocked(void) { return g_settings.aspect == ASPECT_UNLOCKED && !ENV("LARECOMP_NO_WIDESCREEN"); }

// crop: the part of the image shown (uv origin and size); (vx, vy, vw, vh): its place in the window, narrowed to match.
void present_crop(double shape, float crop[4], double *vx, double *vy, double *vw, double *vh) {
    crop[0] = crop[1] = 0, crop[2] = crop[3] = 1;
    if (shape == 1.0) return;
    if (shape < 1.0) {  // taller than 16:9: the 16:9 band
        crop[1] = (float)((1.0 - shape) / 2), crop[3] = (float)shape;
        double nh = *vh * shape;
        *vy += (*vh - nh) / 2, *vh = nh;
        return;
    }
    float u0 = (float)((1.0 - 1.0 / shape) / 2);  // wider: the 16:9 centre
    crop[0] = u0, crop[2] = 1.0f - 2 * u0;
    *vx += *vw * u0, *vw *= crop[2];
}
