#ifndef NVN_FRAME_GENERATION_CAMERA_H
#define NVN_FRAME_GENERATION_CAMERA_H

#include <stddef.h>
#include "frame_generation.h"

#ifdef __cplusplus
extern "C" {
#endif
// Decode the 544-byte scene camera binding; failure leaves out untouched.
bool fg_camera_decode(const void *bytes, size_t size, FgCamera *out);
#ifdef __cplusplus
}
#endif
#endif
