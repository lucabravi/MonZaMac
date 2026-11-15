// Runs the bundled extractor on the user's own packages. No key material is retained or logged.
#pragma once
#include <stdbool.h>
#include <stddef.h>
#ifdef __cplusplus
extern "C" {
#endif
bool gameimport_available(void);
bool gameimport_nup_available(void);  // .nup needs the extractor only (no nstool)
// Fast read-only check for obvious package/keys errors before the setup progress overlay starts.
bool gameimport_preflight(const char *base, const char *update, const char *keys,
                          char *bad_field, size_t bad_field_size, char *why, size_t why_size);
bool gameimport_run(const char *base, const char *update, const char *keys, const char *dlc, const char *stage,
                    const unsigned char build_id[8], void (*progress)(double, const char *),
                    char *bad_field, size_t bad_field_size, char *why, size_t why_size);
// Switch 2 Edition .nup: one unencrypted container holding base, update and add-ons. No keys, no update package.
bool gameimport_preflight_nup(const char *nup, char *bad_field, size_t bad_field_size, char *why, size_t why_size);
bool gameimport_run_nup(const char *nup, const char *stage, const unsigned char build_id[8],
                        void (*progress)(double, const char *), char *bad_field, size_t bad_field_size,
                        char *why, size_t why_size);
// Adds only the optional DLC: extracts it into work/aoc-tree/<title id>/ (the caller packs it). Blocks.
bool gameimport_dlc(const char *dlc, const char *keys, const char *work, char *why, size_t why_size);
#ifdef __cplusplus
}
#endif
