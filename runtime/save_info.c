// Reads the player's save (save/save_0/main) for the start screen: trainer, play time, money and team. Read only.
//
// The format is PKHeX's SAV9ZA, a "SwishCrypto" container: the file is XORed with a fixed pad, its last 32
// bytes are a hash (not checked), and what is left is a list of blocks. A block is a u32 key, a type byte and, for
// objects and numeric arrays, a length; everything after the key is masked by a xorshift32 stream seeded by the key.
// A party slot is a Gen 8/9 record: an LCG-encrypted core of four shuffled 0x50-byte parts, then the party tail.
#include "save_info.h"
#include "saves.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>

#define KEY_PARTY 0x3AA1A9ADu    // 6 slots of SLOT_SIZE
#define KEY_TRAINER 0xE3E89BD1u  // MyStatus
#define KEY_MONEY 0x4F35D0DDu    // u32
#define KEY_PLAYED 0xCE3AF8F2u   // double, seconds

#define SLOT_SIZE 0x1E0
#define RECORD_SIZE 0x158  // core + the party tail up to the level
#define CORE_SIZE 0x148
#define PART 0x50
#define STATUS_SIZE 0x2A

// PKHeX's file pad
static const unsigned char PAD[0x7F] = {
    0xA0, 0x92, 0xD1, 0x06, 0x07, 0xDB, 0x32, 0xA1, 0xAE, 0x01, 0xF5, 0xC5, 0x1E, 0x84, 0x4F, 0xE3, 0x53, 0xCA, 0x37,
    0xF4, 0xA7, 0xB0, 0x4D, 0xA0, 0x18, 0xB7, 0xC2, 0x97, 0xDA, 0x5F, 0x53, 0x2B, 0x75, 0xFA, 0x48, 0x16, 0xF8, 0xD4,
    0x8A, 0x6F, 0x61, 0x05, 0xF4, 0xE2, 0xFD, 0x04, 0xB5, 0xA3, 0x0F, 0xFC, 0x44, 0x92, 0xCB, 0x32, 0xE6, 0x1B, 0xB9,
    0xB1, 0x2E, 0x01, 0xB0, 0x56, 0x53, 0x36, 0xD2, 0xD1, 0x50, 0x3D, 0xDE, 0x5B, 0x2E, 0x0E, 0x52, 0xFD, 0xDF, 0x2F,
    0x7B, 0xCA, 0x63, 0x50, 0xA4, 0x67, 0x5D, 0x23, 0x17, 0xC0, 0x52, 0xE1, 0xA6, 0x30, 0x7C, 0x2B, 0xB6, 0x70, 0x36,
    0x5B, 0x2A, 0x27, 0x69, 0x33, 0xF5, 0x63, 0x7B, 0x36, 0x3F, 0x26, 0x9B, 0xA3, 0xED, 0x7A, 0x53, 0x00, 0xA4, 0x48,
    0xB3, 0x50, 0x9E, 0x14, 0xA0, 0x52, 0xDE, 0x7E, 0x10, 0x2B, 0x1B, 0x77, 0x6E};

// PKHeX's BlockPosition: for each of the 24 orders, which stored part holds logical part 0..3
static const unsigned char ORDER[24][4] = {
    {0, 1, 2, 3}, {0, 1, 3, 2}, {0, 2, 1, 3}, {0, 3, 1, 2}, {0, 2, 3, 1}, {0, 3, 2, 1}, {1, 0, 2, 3}, {1, 0, 3, 2},
    {2, 0, 1, 3}, {3, 0, 1, 2}, {2, 0, 3, 1}, {3, 0, 2, 1}, {1, 2, 0, 3}, {1, 3, 0, 2}, {2, 1, 0, 3}, {3, 1, 0, 2},
    {2, 3, 0, 1}, {3, 2, 0, 1}, {1, 2, 3, 0}, {1, 3, 2, 0}, {2, 1, 3, 0}, {3, 1, 2, 0}, {2, 3, 1, 0}, {3, 2, 1, 0}};

// Bytes in a numeric block, by its type (0: the type isn't a number)
static const unsigned char WIDTH[18] = {0, 0, 0, 1, 0, 0, 0, 0, 1, 2, 4, 8, 1, 2, 4, 8, 4, 8};

static unsigned u16(const unsigned char *p) { return p[0] | p[1] << 8; }
static unsigned u32(const unsigned char *p) { return u16(p) | u16(p + 2) << 16; }

// XOR n bytes of p with the block keystream, which starts `from` bytes after the key.
// The stream: the key's xorshift32 state, stepped popcount(key) times first, then once per 4 bytes, low byte first.
static void unmask(unsigned key, size_t from, unsigned char *p, size_t n) {
    unsigned s = key;
    for (int i = __builtin_popcount(key) + (int)(from / 4); i > 0; i--) s ^= s << 2, s ^= s >> 15, s ^= s << 13;
    for (size_t i = from; i < from + n; i++) {
        p[i - from] ^= (unsigned char)(s >> (i % 4 * 8));
        if (i % 4 == 3) s ^= s << 2, s ^= s >> 15, s ^= s << 13;
    }
}

// One block header at p (end - p bytes left). Returns the header's length after the key, sets *size to the payload's
// (the keystream has used that many bytes by then); 0: not a block this can walk past. A boolean has no payload.
static size_t block_head(unsigned key, const unsigned char *p, size_t left, size_t *size) {
    unsigned char h[6];
    memcpy(h, p, left < sizeof h ? left : sizeof h);
    unmask(key, 0, h, sizeof h);
    unsigned type = h[0];
    *size = 0;
    if (type == 1 || type == 2) return 1;
    if (type == 4 && left >= 5) return *size = u32(h + 1), 5;
    if (type == 5 && left >= 6 && h[5] < 18 && WIDTH[h[5]]) return *size = (size_t)u32(h + 1) * WIDTH[h[5]], 6;
    if (type < 18 && WIDTH[type]) return *size = WIDTH[type], 1;
    return 0;
}

// 13 UTF-16 units -> UTF-8, surrogate pairs combined
static void to_utf8(const unsigned char *p, int units, char *out, size_t cap) {
    size_t k = 0;
    for (int i = 0; i < units && u16(p + 2 * i); i++) {
        unsigned c = u16(p + 2 * i);
        if (c >= 0xD800 && c < 0xDC00 && i + 1 < units && (u16(p + 2 * i + 2) & 0xFC00) == 0xDC00)
            c = 0x10000 + ((c & 0x3FF) << 10) + (u16(p + 2 * ++i) & 0x3FF);
        int n = c < 0x80 ? 1 : c < 0x800 ? 2 : c < 0x10000 ? 3 : 4;
        if (k + n + 1 > cap) break;
        if (n == 1) out[k] = (char)c;
        else {
            out[k] = (char)(0xF00 >> n | c >> 6 * (n - 1));  // the lead byte: n ones, then the top bits
            for (int j = 1; j < n; j++) out[k + j] = (char)(0x80 | (c >> 6 * (n - 1 - j) & 63));
        }
        k += n;
    }
    out[k] = 0;
}

// Undo the LCG from the encryption constant over d[from, to), two bytes at a time
static void lcg_words(unsigned char *d, size_t from, size_t to, unsigned seed) {
    for (size_t i = from; i < to; i += 2) {
        seed = seed * 0x41C64E6D + 0x6073;
        d[i] ^= (unsigned char)(seed >> 16), d[i + 1] ^= (unsigned char)(seed >> 24);
    }
}

// One party slot -> a Pokémon; false for an empty slot or anything that isn't one
static bool read_mon(const unsigned char *slot, SaveMon *m) {
    unsigned char d[RECORD_SIZE], rec[RECORD_SIZE];
    memcpy(d, slot, sizeof d);
    unsigned ec = u32(d);
    lcg_words(d, 8, CORE_SIZE, ec);
    lcg_words(d, CORE_SIZE, RECORD_SIZE, ec);  // (the tail runs its own stream from the same seed)
    memcpy(rec, d, sizeof rec);
    const unsigned char *order = ORDER[(ec >> 13 & 31) % 24];
    for (int b = 0; b < 4; b++) memcpy(rec + 8 + PART * b, d + 8 + PART * order[b], PART);

    unsigned species = u16(rec + 8), level = rec[CORE_SIZE];
    if (!species || species > 1025 || !level || level > 100) return false;
    unsigned pid = u32(rec + 0x1C), tid = u32(rec + 0x0C);
    m->species = (unsigned short)species;
    m->form = (unsigned short)u16(rec + 0x24);
    m->level = (unsigned char)level;
    m->egg = u32(rec + 0x8C) >> 30 & 1;
    to_utf8(rec + 0x58, 13, m->name, sizeof m->name);
    m->shiny = (((pid >> 16) ^ pid ^ (tid >> 16) ^ tid) & 0xFFFF) < 16;
    return true;
}

static bool read_save(const char *file, SaveInfo *out) {
    FILE *f = fopen(file, "rb");
    if (!f) return false;
    fseek(f, 0, SEEK_END);
    long size = ftell(f);
    rewind(f);
    unsigned char *raw = size >= 64 && size <= (64 << 20) ? malloc((size_t)size) : NULL;
    bool ok = raw && fread(raw, 1, (size_t)size, f) == (size_t)size;
    fclose(f);
    if (!ok) return free(raw), false;

    size_t end = (size_t)size - 32;  // (the hash)
    for (size_t i = 0; i < end; i++) raw[i] ^= PAD[i % sizeof PAD];

    unsigned char status[STATUS_SIZE], party[6 * SLOT_SIZE], num[8];
    size_t party_n = 0;
    unsigned money = 0;
    double played = 0;
    bool has_status = false;
    for (size_t at = 0; at + 5 <= end;) {
        unsigned key = u32(raw + at);
        size_t size_, head = block_head(key, raw + at + 4, end - at - 4, &size_);
        if (!head) break;
        size_t body = at + 4 + head;
        if (size_ > end - body) break;
        if (key == KEY_TRAINER && size_ >= sizeof status) {
            memcpy(status, raw + body, sizeof status), unmask(key, head, status, sizeof status), has_status = true;
        } else if (key == KEY_PARTY) {
            party_n = size_ < sizeof party ? size_ : sizeof party;
            memcpy(party, raw + body, party_n), unmask(key, head, party, party_n);
        } else if ((key == KEY_MONEY && size_ >= 4) || (key == KEY_PLAYED && size_ >= 8)) {
            memcpy(num, raw + body, 8), unmask(key, head, num, 8);
            if (key == KEY_MONEY) money = u32(num);
            else memcpy(&played, num, 8);  // (little-endian, as the save is)
        }
        at = body + size_;
    }
    free(raw);
    if (!has_status) return false;

    memset(out, 0, sizeof *out);
    to_utf8(status + 0x10, 13, out->trainer, sizeof out->trainer);
    out->id = u32(status) % 1000000;  // what the games print as the trainer ID
    out->gender = status[5];
    out->money = money;
    out->played = played;
    for (int i = 0; (size_t)(i + 1) * SLOT_SIZE <= party_n; i++)
        if (read_mon(party + i * SLOT_SIZE, &out->party[out->party_n])) out->party_n++;
    return true;
}

// The start screen draws the cards every frame and a save is megabytes: a result is kept until the file's time changes
static struct {
    char path[64];
    long long stamp;
    bool ok;
    SaveInfo info;
} g_cache[SAVE_SLOTS_MAX];
static int g_cached;

const SaveInfo *save_info(const char *slot_path) {
    char file[128];
    snprintf(file, sizeof file, "%s/save_0/main", slot_path);
    struct stat st;
    if (stat(file, &st)) return NULL;
    long long stamp = (long long)st.st_mtime;
    int i = 0;
    while (i < g_cached && strcmp(g_cache[i].path, slot_path)) i++;
    if (i < g_cached && g_cache[i].stamp == stamp) return g_cache[i].ok ? &g_cache[i].info : NULL;
    if (i == g_cached) i = g_cached < SAVE_SLOTS_MAX ? g_cached++ : 0;  // (the list is capped: a full cache can't happen)
    snprintf(g_cache[i].path, sizeof g_cache[i].path, "%s", slot_path);
    g_cache[i].stamp = stamp;
    g_cache[i].ok = read_save(file, &g_cache[i].info);
    return g_cache[i].ok ? &g_cache[i].info : NULL;
}
