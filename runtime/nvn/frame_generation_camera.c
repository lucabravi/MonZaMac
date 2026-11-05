#include "frame_generation_camera.h"

#include <math.h>
#include <string.h>

static bool product_matches(const float *a, const float *b, const float *expected) {
    for (int c = 0; c < 4; c++) for (int r = 0; r < 4; r++) {
        double value = 0, magnitude = 0;
        for (int k = 0; k < 4; k++) {
            double term = (double)a[k * 4 + r] * b[c * 4 + k];
            value += term;
            magnitude += fabs(term);
        }
        double target = expected ? expected[c * 4 + r] : (double)(r == c);
        // Float camera matrices lose precision when large world translations cancel.
        if (fabs(value - target) > 0.00005 + 0.000001 * magnitude) return false;
    }
    return true;
}

static bool rigid_view(const float *view) {
    if (fabsf(view[3]) > 0.00001f || fabsf(view[7]) > 0.00001f ||
        fabsf(view[11]) > 0.00001f || fabsf(view[15] - 1) > 0.00001f) return false;
    for (int c = 0; c < 3; c++) for (int r = 0; r < 3; r++) {
        double dot = 0;
        for (int k = 0; k < 3; k++) dot += (double)view[c * 4 + k] * view[r * 4 + k];
        if (fabs(dot - (double)(r == c)) > 0.001) return false;
    }
    return true;
}

bool fg_camera_decode(const void *bytes, size_t size, FgCamera *out) {
    if (!bytes || !out || size < 544) return false;
    // Shader bank 5 / guest binding 2: VP, V, P, inverse VP, inverse V, inverse P.
    float matrices[96];
    memcpy(matrices, bytes, sizeof matrices);
    for (int i = 0; i < 96; i++) if (!isfinite(matrices[i])) return false;
    const float *view = matrices + 16, *projection = matrices + 32;
    const float *inverse_vp = matrices + 48, *inverse_view = matrices + 64;
    for (int i = 0; i < 16; i++) {
        if (i == 0 || i == 5 || i == 10 || i == 11 || i == 14) continue;
        if (fabsf(projection[i]) > 0.00001f) return false;
    }
    if (projection[0] <= 0 || projection[5] <= 0 || fabsf(projection[11] + 1) > 0.00001f ||
        !rigid_view(view) || !rigid_view(inverse_view) ||
        !product_matches(projection, view, matrices) ||
        !product_matches(matrices, inverse_vp, NULL) ||
        !product_matches(view, inverse_view, NULL) ||
        !product_matches(projection, matrices + 80, NULL)) return false;

    double a = projection[10], b = projection[14];
    bool reversed = a > 0 && b > 0;
    if (!reversed && !(a < -1 && b < 0)) return false;
    double near = reversed ? b / (a + 1) : b / a;
    double far = reversed ? b / a : b / (a + 1);
    double fov = 2 * atan(1.0 / projection[5]) * (180.0 / 3.14159265358979323846);
    double aspect = (double)projection[5] / projection[0];
    if (!isfinite(near) || !isfinite((float)far) || !isfinite((float)aspect) ||
        (float)near <= 0 || (float)far <= (float)near || (float)aspect <= 0 ||
        (float)fov <= 0 || (float)fov >= 180) return false;
    FgCamera camera = {0};
    memcpy(camera.view_projection, matrices, sizeof camera.view_projection);
    memcpy(camera.inverse_view_projection, inverse_vp, sizeof camera.inverse_view_projection);
    camera.near_plane = (float)near;
    camera.far_plane = (float)far;
    camera.vertical_fov = (float)fov;
    camera.aspect = (float)aspect;
    camera.reversed_depth = reversed;
    *out = camera;
    return true;
}
