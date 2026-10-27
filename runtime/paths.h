// Where MonZaMac keeps its files (runtime/paths.c).
//
// Data root: everything the app writes or the user brings - extracted/ (game files), save/,
// cache/ (shaders / pipelines), fonts/ (imported), larecomp.ini. rt_paths_init() picks it and makes it the
// working directory, so the rest of the runtime opens those by their relative names. In order:
//   1. LARECOMP_DATA_ROOT (tests, scratch installs)
//   2. dev / portable mode: the starting directory already has extracted/ (a source checkout: `./build/monzamac
//      extracted`, the test scripts) - used as is
//   3. ~/Library/Application Support/com.monzamac.app (the .app bundle itself is never written to)
//
// Resources: files that ship with the app (helper programs, the window icon) - next to the executable (the
// Windows folder, the .app's Contents/MacOS), in the .app's Contents/Resources, or in the source tree.
#pragma once
#include <stdbool.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

#define RT_BUNDLE_ID "com.monzamac.app"

void rt_paths_init(void);         // first thing in main(), after plat_init
const char *rt_data_root(void);   // absolute
bool rt_dev_mode(void);           // dev / portable mode (rule 2 above): e.g. a source checkout

// A shipped file: `name` next to the executable or in Contents/Resources, else `dev_rel` in the source tree (the
// starting directory or the executable's parent; NULL = shipped builds only). Absolute path in out; false = none.
bool rt_resource(const char *name, const char *dev_rel, char *out, size_t n);

// The only way the app deletes game files. Removes the named entry of game_dir (an extracted/ folder) only if
// game_dir is <data root>/extracted itself (symlinks resolved; a symlinked extracted/ is refused) and the entry is
// one the setup creates (exefs, romfs, romfs.bin, leftover folders) and not a link. The folder the user picked
// never gets here. true = removed or not there.
bool rt_remove_game_file(const char *game_dir, const char *name);
// All the game files set up there (rt_remove_game_file on each, then the empty folder). Saves, seeds, settings stay.
bool rt_remove_game_files(const char *game_dir);
// Bytes taken by the extracted game files in game_dir (links not followed).
unsigned long long rt_game_files_size(const char *game_dir);

// First-run setup: lock and prepare app-owned scratch storage, then publish a
// complete install into an empty extracted/ directory. Existing files are never
// replaced implicitly. Failed/interrupted scratch work is removed on retry.
// rebuild_code stages only a replacement library, preserving existing game data.
bool rt_game_setup_begin(const char *game_dir, bool rebuild_code, char *stage, size_t size, char *why, size_t why_size);
bool rt_game_setup_end(bool publish, char *why, size_t why_size);

typedef struct SDL_Window SDL_Window;
void rt_window_icon(SDL_Window *w);  // the shipped icon.png, if any

#ifdef __cplusplus
}
#endif
