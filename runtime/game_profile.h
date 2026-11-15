#pragma once

#include <stdbool.h>
#include <stdint.h>

typedef enum {
    GAME_UNKNOWN = 0,
    GAME_ZA,
    GAME_SWORD,
    GAME_SHIELD,
} GameKind;

GameKind game_kind_from_program_id(uint64_t program_id);
GameKind game_kind(void);
bool game_program_id_supported(uint64_t program_id);
const char *game_title(GameKind kind);
uint64_t game_program_id_from_npdm(const char *path);
