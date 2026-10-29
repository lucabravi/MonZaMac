// Save slots: the start screen's save picker (runtime/ui/launcher.mm). The game's save data lives in g_save_dir
// (runtime/services/fs.c); a slot is a folder holding one. The first slot is the original `save/` (so existing
// saves show up as they are), the others are `saves/<name>/`.
#pragma once
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

#define SAVE_NAME_MAX 24
#define SAVE_SLOTS_MAX 32

typedef struct {
    char id[SAVE_NAME_MAX + 1];  // "" = the original `save/` slot
    char name[40];               // shown
    char path[64];               // relative to the data root
    long long played;            // last write in it (unix seconds); 0 = nothing saved yet
    long long born;              // when the folder was made (the order of the list)
} SaveSlot;

// The slots in a fixed order: the original `save/` first (as "Main save" until renamed, only when it holds something), then the others as
// they were made. Returns how many (0: no save yet).
int saves_list(SaveSlot *out, int max);
// New empty slot / copy of `id` named `name` (letters, digits, space, - _ ; trimmed). false: bad or taken name.
bool saves_create(const char *name, char *id_out);  // id_out (SAVE_NAME_MAX + 1, or NULL): the new slot's id
bool saves_copy(const char *id, const char *name);
bool saves_rename(const char *id, const char *name, char *id_out);  // (the original slot too: it moves to saves/<name>); id_out as saves_create
bool saves_delete(const char *id);                    // removes the slot's folder (the original: empties it)
// The game uses this slot's data from now on (g_save_dir). Unknown id: the original.
void saves_select(const char *id);
// The save with the most recent write (as the start screen's CONTINUE); none has progress: the original `save/`.
void saves_select_latest(void);

#ifdef __cplusplus
}
#endif
