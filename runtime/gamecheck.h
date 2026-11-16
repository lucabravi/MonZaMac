// The player's game files checked pack by pack against a clean copy of the same version (runtime/gamecheck_table.h).
// A damaged download of the 2.0.2 update has a broken block in one model pack and the game crashes when it loads that
// model, long after the setup: the start screen runs this once per data.trpfs and says which packs differ.
#pragma once
#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define GAMECHECK_IDS 8  // how many damaged packs are named (the count is complete)

typedef struct {
    bool known;                    // the file's size is a version with a clean copy (else nothing was checked)
    unsigned packs, damaged;       // the packs in the file, and the ones that differ from the clean copy
    uint64_t ids[GAMECHECK_IDS];   // the first damaged packs' own hashes (the id data.trpfs gives each)
} GameCheck;

// Hashes every pack of <trpfs> (a few seconds, the whole file is read). False: it can't be read or isn't a data.trpfs.
bool gamecheck_run(const char *trpfs, GameCheck *r);

// The result kept in <game_dir>/.packcheck for the data.trpfs as it is now (size and time), else run and keep it.
// *fresh tells which: the notice is for a check that has just run, not for every start.
bool gamecheck_ensure(const char *game_dir, GameCheck *r, bool *fresh);

// What the last gamecheck_ensure / gamecheck_load found, for the crash dialog (damaged packs; 0 = none or unknown).
unsigned gamecheck_damaged(void);

// Reads the kept result without hashing, logs it (the game's start).
void gamecheck_load_and_log(const char *game_dir);

#ifdef __cplusplus
}
#endif
