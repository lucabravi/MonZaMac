// The start screen's save card shows what's in a save without booting the game: trainer, play time, money, team. The
// save file is read in place (read only); the format is PKHeX's SAV9ZA / SwishCrypto.
#pragma once
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

#define SAVE_PARTY_MAX 6

typedef struct {
    unsigned short species, form;
    unsigned char level, shiny, egg;
    char name[40];  // its nickname, or the species' name in the save's language; UTF-8
} SaveMon;

typedef struct {
    char trainer[40];  // UTF-8, up to 12 characters
    unsigned id;       // the trainer's 6-digit display ID (ID32 % 1000000)
    int gender;        // 0 male, 1 female
    unsigned money;
    double played;     // seconds
    int party_n;       // party[0 .. party_n-1] are the team, in order
    SaveMon party[SAVE_PARTY_MAX];
} SaveInfo;

// slot_path: a SaveSlot's path ("save" or "saves/<name>"). NULL: no save there, or one this can't read. The result is
// cached by file time (the card is drawn every frame).
const SaveInfo *save_info(const char *slot_path);

#ifdef __cplusplus
}
#endif
