#include "game_profile.h"

#include <stdio.h>
#include <string.h>

static uint64_t base_program_id(uint64_t id) {
    return id & ~0xfffull;  // updates use the base title ID plus 0x800
}

GameKind game_kind_from_program_id(uint64_t program_id) {
    switch (base_program_id(program_id)) {
    case 0x0100F43008C44000ull: return GAME_ZA;
    case 0x0100ABF008968000ull: return GAME_SWORD;
    case 0x01008BB008C9C000ull: return GAME_SHIELD;
    default: return GAME_UNKNOWN;
    }
}

GameKind game_kind(void) {
    extern uint64_t g_program_id;
    return game_kind_from_program_id(g_program_id);
}

bool game_program_id_supported(uint64_t program_id) {
    return game_kind_from_program_id(program_id) != GAME_UNKNOWN;
}

const char *game_title(GameKind kind) {
    switch (kind) {
    case GAME_ZA: return "Pokémon Legends: Z-A";
    case GAME_SWORD: return "Pokémon Sword";
    case GAME_SHIELD: return "Pokémon Shield";
    default: return "supported Pokémon game";
    }
}

uint64_t game_program_id_from_npdm(const char *path) {
    FILE *f = fopen(path, "rb");
    if (!f) return 0;
    unsigned char meta[0x80], aci0[0x18];
    uint32_t aci0_offset;
    uint64_t id = 0;
    if (fread(meta, 1, sizeof meta, f) == sizeof meta && !memcmp(meta, "META", 4)) {
        memcpy(&aci0_offset, meta + 0x70, sizeof aci0_offset);
        if (!fseek(f, aci0_offset, SEEK_SET) && fread(aci0, 1, sizeof aci0, f) == sizeof aci0 &&
            !memcmp(aci0, "ACI0", 4))
            memcpy(&id, aci0 + 0x10, sizeof id);
    }
    fclose(f);
    return id;
}
