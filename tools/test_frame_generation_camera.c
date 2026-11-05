#include "frame_generation_camera.h"

#include <assert.h>
#include <math.h>
#include <stdio.h>
#include <string.h>

static void identity(float *m) {
    memset(m, 0, 16 * sizeof *m);
    for (int i = 0; i < 4; i++) m[5 * i] = 1;
}

static void multiply(const float *a, const float *b, float *out) {
    for (int c = 0; c < 4; c++) for (int r = 0; r < 4; r++) {
        double value = 0;
        for (int k = 0; k < 4; k++) value += (double)a[k * 4 + r] * b[c * 4 + k];
        out[c * 4 + r] = (float)value;
    }
}

// The fixtures use a general inverse, independently of the decoder's matrix checks.
static void inverse(const float *input, float *out) {
    double a[4][8];
    for (int r = 0; r < 4; r++) for (int c = 0; c < 8; c++)
        a[r][c] = c < 4 ? input[c * 4 + r] : (double)(c - 4 == r);
    for (int k = 0; k < 4; k++) {
        int pivot = k;
        for (int r = k + 1; r < 4; r++) if (fabs(a[r][k]) > fabs(a[pivot][k])) pivot = r;
        assert(fabs(a[pivot][k]) > 1e-12);
        for (int c = 0; c < 8; c++) {
            double tmp = a[k][c]; a[k][c] = a[pivot][c]; a[pivot][c] = tmp;
        }
        double divisor = a[k][k];
        for (int c = 0; c < 8; c++) a[k][c] /= divisor;
        for (int r = 0; r < 4; r++) if (r != k) {
            double scale = a[r][k];
            for (int c = 0; c < 8; c++) a[r][c] -= scale * a[k][c];
        }
    }
    for (int r = 0; r < 4; r++) for (int c = 0; c < 4; c++) out[c * 4 + r] = (float)a[r][c + 4];
}

static void fixture(float buffer[136], bool reversed, bool rotated, float translation) {
    memset(buffer, 0, 136 * sizeof *buffer);
    float *view = buffer + 16, *projection = buffer + 32;
    identity(view);
    if (rotated) {
        float c = cosf(0.7f), s = sinf(0.7f);
        view[0] = c; view[2] = -s; view[8] = s; view[10] = c;
    }
    view[12] = translation; view[13] = -translation * 0.4f; view[14] = translation * 0.8f;
    const double near = 0.1, far = 6000;
    projection[0] = (float)(1.0 / tan(40.0 * 3.141592653589793 / 360.0) / (16.0 / 9.0));
    projection[5] = (float)(1.0 / tan(40.0 * 3.141592653589793 / 360.0));
    projection[10] = (float)(reversed ? near / (far - near) : -far / (far - near));
    projection[11] = -1;
    projection[14] = (float)(reversed ? near * far / (far - near) : -near * far / (far - near));
    multiply(projection, view, buffer);
    inverse(buffer, buffer + 48);
    inverse(view, buffer + 64);
    inverse(projection, buffer + 80);
}

static void rejected(const void *bytes, size_t size) {
    FgCamera before, after;
    memset(&before, 0x5a, sizeof before);
    after = before;
    assert(!fg_camera_decode(bytes, size, &after));
    assert(memcmp(&before, &after, sizeof before) == 0);
}

int main(void) {
    float buffer[136];
    FgCamera camera;
    for (int reversed = 0; reversed < 2; reversed++) for (int rotated = 0; rotated < 2; rotated++) {
        fixture(buffer, reversed, rotated, rotated ? 25000 : 0);
        assert(fg_camera_decode(buffer, sizeof buffer, &camera));
        assert(camera.reversed_depth == (bool)reversed);
        assert(fabsf(camera.near_plane - 0.1f) < 0.00001f);
        assert(fabsf(camera.far_plane - 6000) < (reversed ? 0.1f : 30.0f));
        assert(fabsf(camera.vertical_fov - 40) < 0.001f);
        assert(fabsf(camera.aspect - 16.0f / 9.0f) < 0.00001f);
        assert(memcmp(camera.view_projection, buffer, 64) == 0);
        assert(memcmp(camera.inverse_view_projection, buffer + 48, 64) == 0);
    }
    fixture(buffer, true, true, 25000);
    unsigned char unaligned[545];
    memcpy(unaligned + 1, buffer, sizeof buffer);
    assert(fg_camera_decode(unaligned + 1, sizeof buffer, &camera));
    rejected(buffer, sizeof buffer - 1);
    rejected(NULL, sizeof buffer);
    assert(!fg_camera_decode(buffer, sizeof buffer, NULL));
    buffer[0] += 1; rejected(buffer, sizeof buffer);
    fixture(buffer, true, true, 25000);
    buffer[48] += 1; rejected(buffer, sizeof buffer);
    fixture(buffer, true, true, 25000);
    buffer[64 + 12] += 100; rejected(buffer, sizeof buffer);
    fixture(buffer, true, false, 0);
    buffer[32 + 4] = 0.1f; rejected(buffer, sizeof buffer);
    fixture(buffer, true, false, 0);
    buffer[32] = 0; rejected(buffer, sizeof buffer);
    fixture(buffer, true, false, 0);
    buffer[48 + 10] = NAN; rejected(buffer, sizeof buffer);
    fixture(buffer, true, false, 0);
    buffer[16 + 12] = INFINITY; rejected(buffer, sizeof buffer);
    fixture(buffer, true, false, 0);
    memset(buffer + 48, 0, 64); rejected(buffer, sizeof buffer);
    memset(buffer, 0, sizeof buffer); rejected(buffer, sizeof buffer);
    puts("frame generation camera: passed synthetic projection, rotation, large-world and rejection checks");
    return 0;
}
