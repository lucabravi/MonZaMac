// nn::pl shared system fonts. The Switch's system fonts are not part of the game; in order of preference:
//  1. LARECOMP_FONT=<file> (.ttf / .otf / .ttc face 0 / .bfttf)
//  2. a dump from the user's own console in fonts/: nintendo_udsg-r_std_003.bfttf (Standard, Morisawa UD Shin Go)
//     and nintendo_ext_003.bfttf (NintendoExt button glyphs); plain .ttf versions of those names also work
//  3. a Japanese gothic like UD Shin Go (much closer to the game's look than Arial): Hiragino Sans W4 on macOS,
//     Yu Gothic Regular / Medium on Windows
//  4. Arial
// .bfttf is the console's obfuscated TTF: 8-byte header (magic, size) then every u32 XORed with a fixed key.
// .ttc collections get face 0 copied out as a standalone font (the game's font engine wants one sfnt).
#include <stdlib.h>
#include <string.h>
#include <strings.h>

#include "../hle.h"
#include "../settings.h"
#include <SDL3/SDL_gamepad.h>

typedef struct { uint64_t addr, size; } Font;
static Font fonts[2];  // [0] Standard (every type), [1] NintendoExt when a dump provides it

static uint32_t be32(const uint8_t *p) { return (uint32_t)p[0] << 24 | p[1] << 16 | p[2] << 8 | p[3]; }
static void put32(uint8_t *p, uint32_t v) { p[0] = v >> 24; p[1] = v >> 16; p[2] = v >> 8; p[3] = v; }

static uint8_t *read_file(const char *path, size_t *len) {
    FILE *f = fopen(path, "rb");
    if (!f) return NULL;
    fseek(f, 0, SEEK_END);
    *len = (size_t)ftell(f);
    fseek(f, 0, SEEK_SET);
    uint8_t *p = malloc(*len + 4);
    if (fread(p, 1, *len, f) != *len) { free(p); p = NULL; }
    fclose(f);
    return p;
}

// .bfttf -> TTF in place (returns the new length, 0 if it isn't one)
static size_t bfttf_decode(uint8_t *d, size_t len) {
    static const uint32_t KEY = 0x49621806;
    if (len < 12) return 0;
    for (int swap = 0; swap < 2; swap++) {  // the key's byte order differs between descriptions; accept both
        uint32_t k = swap ? __builtin_bswap32(KEY) : KEY;
        uint32_t w0, w1, w2;
        memcpy(&w0, d, 4); memcpy(&w1, d + 4, 4); memcpy(&w2, d + 8, 4);
        uint32_t size = w1 ^ k, ver = w2 ^ k;
        if (size > len - 8) size = __builtin_bswap32(size);  // (the console's files store it big-endian)
        if (size == 0 || size > len - 8 || (ver != 0x00000100u && ver != 0x4F54544Fu)) continue;  // sfnt 1.0 / OTTO
        (void)w0;
        for (size_t i = 0; i + 4 <= size; i += 4) {
            uint32_t w;
            memcpy(&w, d + 8 + i, 4);
            w ^= k;
            memcpy(d + i, &w, 4);
        }
        return size;
    }
    return 0;
}

// .ttc -> face 0 as its own sfnt (table data copied, offsets rewritten)
static uint8_t *ttc_face0(const uint8_t *f, size_t len, size_t *out_len) {
    if (len < 16 || memcmp(f, "ttcf", 4)) return NULL;
    uint32_t o = be32(f + 12);
    if (o + 12 > len) return NULL;
    uint32_t nt = (uint32_t)f[o + 4] << 8 | f[o + 5];
    size_t total = 12 + 16 * nt;
    for (uint32_t i = 0; i < nt; i++) total += (be32(f + o + 12 + 16 * i + 12) + 3) & ~3u;
    uint8_t *out = calloc(1, total);
    memcpy(out, f + o, 12);
    size_t pos = 12 + 16 * nt;
    for (uint32_t i = 0; i < nt; i++) {
        const uint8_t *e = f + o + 12 + 16 * i;
        uint32_t off = be32(e + 8), n = be32(e + 12);
        if ((size_t)off + n > len) { free(out); return NULL; }
        memcpy(out + 12 + 16 * i, e, 8);  // tag, checksum
        put32(out + 12 + 16 * i + 8, (uint32_t)pos);
        put32(out + 12 + 16 * i + 12, n);
        memcpy(out + pos, f + off, n);
        pos += (n + 3) & ~3u;
    }
    *out_len = total;
    return out;
}

// The game's font engine sizes text by the font's OS/2 usWinAscent + usWinDescent: 1.5 em for the console's UD Shin Go
// (1158 + 378 of 1024 units) against the 1.1-1.3 em of the usual substitutes, so their glyphs come out too large for
// the UI's text boxes and get clipped away (small labels vanish, titles drawn over open space stay visible).
// Hand the substitute the console font's values.
static void match_switch_metrics(uint8_t *d, size_t len) {
    if (len < 12) return;
    unsigned ntab = (unsigned)d[4] << 8 | d[5];
    if (12 + 16 * (size_t)ntab > len) return;
    const uint8_t *head = NULL;
    uint8_t *os2 = NULL;
    for (unsigned i = 0; i < ntab; i++) {
        const uint8_t *e = d + 12 + 16 * i;
        uint32_t off = be32(e + 8), tlen = be32(e + 12);
        if (off > len || tlen > len - off) continue;
        if (!memcmp(e, "head", 4) && tlen >= 20) head = d + off;
        if (!memcmp(e, "OS/2", 4) && tlen >= 78) os2 = d + off;
    }
    if (!head || !os2) return;
    unsigned upem = (unsigned)head[18] << 8 | head[19];
    if (!upem) return;
    unsigned asc = (1158 * upem + 512) / 1024, desc = (378 * upem + 512) / 1024;
    os2[74] = (uint8_t)(asc >> 8), os2[75] = (uint8_t)asc;    // usWinAscent
    os2[76] = (uint8_t)(desc >> 8), os2[77] = (uint8_t)desc;  // usWinDescent
    LOG("[pl] metrics: usWinAscent %u + usWinDescent %u of %u em\n", asc, desc, upem);
}

static int load_one(const char *path, Font *ft) {
    size_t len;
    uint8_t *d = read_file(path, &len);
    if (!d) return 0;
    size_t n = strlen(path);
    bool console_font = n > 6 && !strcasecmp(path + n - 6, ".bfttf");
    if (console_font) {
        len = bfttf_decode(d, len);
        if (!len) { LOG("[pl] %s: not a valid .bfttf\n", path); free(d); return 0; }
    } else if (len >= 4 && !memcmp(d, "ttcf", 4)) {
        size_t l2;
        uint8_t *f0 = ttc_face0(d, len, &l2);
        free(d);
        if (!f0) { LOG("[pl] %s: bad font collection\n", path); return 0; }
        d = f0;
        len = l2;
    }
    if (!console_font) match_switch_metrics(d, len);  // (the console's own .bfttf already has these values)
    void *p = hle_alloc(len + 16);
    memcpy(p, d, len);
    free(d);
    ft->addr = (uint64_t)p;
    ft->size = len;
    LOG("[pl] system font %s (%zu bytes)\n", path, len);
    return 1;
}

static int g_fonts_loaded;
RT_ON_RESET(pl_reset) { g_fonts_loaded = 0; memset(fonts, 0, sizeof fonts); }  // (they were in the HLE heap)

static void load_fonts(void) {
    if (g_fonts_loaded) return;
    g_fonts_loaded = 1;
    const char *env = getenv("LARECOMP_FONT");
    const char *std[] = {env, "fonts/nintendo_udsg-r_std_003.bfttf", "fonts/nintendo_udsg-r_std_003.ttf",
                         "fonts/nintendo_udsgr_std_003.ttf", "fonts/nintendo_udsgr_std_003.bfttf",
                         "/System/Library/Fonts/ヒラギノ角ゴシック W4.ttc", "C:/Windows/Fonts/YuGothR.ttc",
                         "C:/Windows/Fonts/YuGothM.ttc", "/System/Library/Fonts/Supplemental/Arial.ttf",
                         "C:/Windows/Fonts/arial.ttf",
                         // Linux: DejaVu Sans (Debian / Ubuntu, Arch, Fedora). Not Noto Sans CJK: CFF outlines,
                         // which the game's font engine crashes on (it wants TrueType)
                         "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf", "/usr/share/fonts/TTF/DejaVuSans.ttf",
                         "/usr/share/fonts/dejavu-sans-fonts/DejaVuSans.ttf"};
    for (size_t i = 0; i < sizeof std / sizeof *std && !fonts[0].addr; i++)
        if (std[i]) load_one(std[i], &fonts[0]);
    if (!fonts[0].addr) FATAL("no usable system font substitute\n");
    // Xbox prompts (setting prompts = xbox, or auto with an Xbox controller): the button glyphs relabelled
    // (tools/za/xbox_font.py). Keyboard prompts (auto with no controller connected at boot): the glyphs drawn as keys
    // with the bound keys' names (tools/za/keyboard_font.py, from the settings' bind_key_* lines)
    const char *pl_prompt_set(void);
    const char *set = pl_prompt_set();
    LOG("[pl] button prompts: %s\n", set ? set : "Nintendo");
    char path[64];
    snprintf(path, sizeof path, "fonts/nintendo_ext_003_%s.ttf", set ? set : "");
    if (!(set && load_one(path, &fonts[1])) && !load_one("fonts/nintendo_ext_003.bfttf", &fonts[1]))
        load_one("fonts/nintendo_ext_003.ttf", &fonts[1]);
}

// The prompts' style, chosen once at boot: "keyboard", "xbox" (controls by position: A/B and X/Y traded - the
// Switch's A on the east button), "xboxlabel" (by letter, A on the Xbox pad's A: the letters stay; both name the
// shoulders / triggers / menu buttons LB RB LT RT Menu View) or NULL (the game's own). Names both the button glyph
// font (fonts/nintendo_ext_003_<set>.ttf: tools/za/keyboard_font.py, xbox_font.py) and the game's own UI icons
// relabelled (textures/prompts/<set>: tools/za/prompt_textures.py, runtime/nvn/vulkan/textures.c).
const char *pl_prompt_set(void) {
    static int done;
    static const char *set;
    if (done) return set;
    done = 1;
    extern int input_pad_family(void);
    extern int16_t g_bind_pad[];
    bool pad = SDL_HasGamepad();
    bool xbox = g_settings.prompts == PROMPTS_XBOX || (g_settings.prompts == PROMPTS_AUTO && pad && input_pad_family() == 1);
    bool keys = g_settings.prompts == PROMPTS_KEYBOARD || (g_settings.prompts == PROMPTS_AUTO && !pad);
    set = keys ? "keyboard" : !xbox ? NULL : g_bind_pad[0] == SDL_GAMEPAD_BUTTON_EAST ? "xbox" : "xboxlabel";
    return set;
}

// SharedFontType: 0 Standard, 1 ChineseSimple, 2 ChineseSimpleExt, 3 ChineseTraditional, 4 Korean, 5 NintendoExt
static const Font *font_for(uint64_t type) {
    load_fonts();
    return type == 5 && fonts[1].addr ? &fonts[1] : &fonts[0];
}

static void pl_trace(const char *what, uint64_t type, uint64_t got) {
    static int n;
    if (n++ < 24) LOG("[pl] %s(%llu) -> %llx\n", what, (unsigned long long)type, (unsigned long long)got);
}

HLE_FUNC("_ZN2nn2pl22GetSharedFontLoadStateENS0_14SharedFontTypeE", pl_get_load_state) {
    pl_trace("GetSharedFontLoadState", c->x[0], 1);
    c->x[0] = 1;
}
HLE_FUNC("_ZN2nn2pl20GetSharedFontAddressENS0_14SharedFontTypeE", pl_get_address) {
    uint64_t type = c->x[0];
    c->x[0] = font_for(type)->addr;
    pl_trace("GetSharedFontAddress", type, c->x[0]);
}
HLE_FUNC("_ZN2nn2pl17GetSharedFontSizeENS0_14SharedFontTypeE", pl_get_size) {
    uint64_t type = c->x[0];
    c->x[0] = font_for(type)->size;
    pl_trace("GetSharedFontSize", type, c->x[0]);
}
HLE_FUNC("_ZN2nn2pl21RequestSharedFontLoadENS0_14SharedFontTypeE", pl_request_load) {
    pl_trace("RequestSharedFontLoad", c->x[0], 0);
}
