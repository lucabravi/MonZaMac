// Software keyboard (naming Link on a new file, ...). On the Switch nn::swkbd::ShowKeyboard launches the keyboard
// library applet; our am service has no applets, so the game crashed. ShowKeyboard is replaced here: the overlay
// (runtime/ui/menu.mm menu_keyboard_run) asks for the text - typed directly with a keyboard, an on-screen keyboard
// with a controller - while this (game) thread keeps re-presenting the last frame.
#include <stdio.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

#include "../hle.h"

int menu_keyboard_run(const char *title, const char *initial, int max_len, char *out, int cap);  // runtime/ui/menu.mm

// The Lumiose Online mod (1.4.4 and later) keeps a chat state block in its data, "VMPCHAT\0" on a 16-byte boundary: u32
// version (1, 2) at +8, u32 size at +0xc, u32 state at +0x10 (2 = the chat focused, 32 = a window's field being edited),
// and from version 2 the edited field at +0xe4. It opens the keyboard with no maximum: each field's own length, in UTF-8
// bytes, comes from which one it is: the mod's own field list and lengths (its ui/textfield.hpp ids, the maxBytes each
// window opens its field with): 1 chat 120, 2 Market search 24, 3 Market move 24, 4 / 5 prices 8, 6 sell price 8, 7 Mail
// to 24, 8 Mail message 200, 9 Mail money 8, 10 friend status 60, 11 player note 120, 12 trade money 8, 13 guild name 24,
// 14 Mystery Gift code 32, 15 staff find 24, 16 outfit name 24. The block names the field only while its field-edit bit is on: once a keyboard was cancelled the mod
// turns it off and the byte trails a field behind. The mod also logs "swkbd: requested for field N" right before it opens
// the keyboard (runtime/kernel.c debug_string keeps that N): used then. 0: neither (or two blocks: never guess).
_Atomic int g_lumiose_kbd_field;
_Atomic int g_lumiose_kbd_field_last;  // the field of the request being answered (0: not the mod's, or not known)
static int lumiose_field_max(void) {
    const Module *m = NULL;
    for (int i = 0; i < g_nmodules; i++) if (g_modules[i].name && !strcmp(g_modules[i].name, "subsdk9")) m = &g_modules[i];
    if (!m || !m->base || m->data_off > m->size || m->data_size > m->size - m->data_off || m->data_size < 0x100) return 0;
    const uint8_t *d = (const uint8_t *)(uintptr_t)(m->base + m->data_off), *b = NULL;
    for (uint64_t i = (16 - ((uintptr_t)d & 15)) & 15; i + 0xe8 <= m->data_size; i += 16) {
        if (memcmp(d + i, "VMPCHAT\0", 8)) continue;
        uint32_t ver, len;
        memcpy(&ver, d + i + 8, 4), memcpy(&len, d + i + 12, 4);
        if ((ver != 1 && ver != 2) || len < (ver == 2 ? 0xe8u : 0xe4u) || len > m->data_size - i) continue;
        if (b) return 0;
        b = d + i;
    }
    int logged = atomic_exchange(&g_lumiose_kbd_field, 0);
    if (!b) return 0;
    uint32_t ver, state;
    memcpy(&ver, b + 8, 4), memcpy(&state, b + 0x10, 4);
    int field = ver == 2 && (state & 32) ? __atomic_load_n(b + 0xe4, __ATOMIC_ACQUIRE) : logged ? logged : (state & 2) ? 1 : 0;
    g_lumiose_kbd_field_last = field;  // (a field this table doesn't know yet still gets typed in place, at 120)
    switch (field) {
    case 2: case 3: case 7: case 13: case 15: case 16: return 24;
    case 4: case 5: case 6: case 9: case 12: return 8;
    case 10: return 60;
    case 14: return 32;
    case 1: case 11: return 120;
    case 8: return 200;
    default: return 0;
    }
}

// nn::swkbd::ShowKeyboard(nn::swkbd::String *out, const nn::swkbd::ShowKeyboardArg &arg) -> nn::Result
// String = {void *ptr; size_t bufSize}
// ShowKeyboardArg (probed 2026-10-08, naming Link): +0x24 header text (UTF-16, 65), +0x3ac text max length, +0x3b0 min length, +0x3c0 / +0x3c4
// initial text offset / length (UTF-16) in the work buffer at +0x4d0. The game reads the answer as UTF-8.
HLE_FUNC("_ZN2nn5swkbd12ShowKeyboardEPNS0_6StringERKNS0_15ShowKeyboardArgE", swkbd_show) {
    uint64_t out = c->x[0], arg = c->x[1];
    uint64_t ptr = LD64(out), size = LD64(out + 8);
    int max_len = (int)*(const int32_t *)(uintptr_t)(arg + 0x3ac);
    uint32_t off = *(const uint32_t *)(uintptr_t)(arg + 0x3c0), n = *(const uint32_t *)(uintptr_t)(arg + 0x3c4);
    uint64_t wb = LD64(arg + 0x4d0);
    // No max (0: the Lumiose Online mod sets none; the overlay used to fall back to 8): the mod's field's own length, else
    // 120 bytes; never more than the answer's buffer holds (UTF-16, a NUL left)
    g_lumiose_kbd_field_last = 0;
    int field_max = max_len <= 0 ? lumiose_field_max() : 0;
    if (max_len <= 0) max_len = field_max ? field_max : 120;
    if (size >= 4 && (uint64_t)max_len > size / 2 - 1) max_len = (int)(size / 2 - 1);
    char initial[512] = "";
    for (uint32_t i = 0; wb && i < n && i < sizeof initial - 1; i++) {
        uint16_t ch = *(const uint16_t *)(uintptr_t)(wb + off + 2 * i);
        initial[i] = ch < 0x80 ? (char)ch : '?';
    }
    // the dialog's title: the caller's header (the Lumiose Online chat: "Chat"), else the overlay's "Enter your name"
    char title[200] = "";
    for (int i = 0, o = 0; i < 64; i++) {
        uint16_t ch = *(const uint16_t *)(uintptr_t)(arg + 0x24 + 2 * i);
        if (!ch || o > (int)sizeof title - 4) break;
        if (ch < 0x80) title[o++] = (char)ch;
        else if (ch < 0x800) title[o++] = (char)(0xc0 | ch >> 6), title[o++] = (char)(0x80 | (ch & 0x3f));
        else title[o++] = (char)(0xe0 | ch >> 12), title[o++] = (char)(0x80 | (ch >> 6 & 0x3f)), title[o++] = (char)(0x80 | (ch & 0x3f));
    }
    if (g_lumiose_kbd_field_last > 0) {  // a Lumiose Online field, with a keyboard and mouse: typed in place (runtime/hle/lumiose_type.c)
        extern bool lumiose_type_take_keyboard(int field);
        if (lumiose_type_take_keyboard(g_lumiose_kbd_field_last)) {
            LOG("[swkbd] Lumiose field %d: typed in place, no keyboard window\n", g_lumiose_kbd_field_last);
            c->x[0] = MAKE_RESULT(159, 1);  // (as cancelled: the mod leaves the field as it was)
            return;
        }
    }
    char text[512];
    LOG("[swkbd] name entry: waiting for host input (max %d%s, title \"%s\", initial \"%s\")\n", max_len, field_max ? " from the Lumiose field" : "", title, initial);
    int ok = menu_keyboard_run(title, initial, max_len, text, sizeof text);
    if (!ok) snprintf(text, sizeof text, "%s", initial);  // cancelled: keep what was there
    LOG("[swkbd] name entry (max %d, initial \"%s\"): %s \"%s\"\n", max_len, initial, ok ? "entered" : "cancelled", text);
    if (ptr && size) {  // Pokémon Legends Z-A reads the answer as UTF-16 (UTF-8 bytes came out as CJK: "rh" -> U+6872)
        uint16_t *w = (uint16_t *)(uintptr_t)ptr;
        size_t cap = size / 2, n = 0;  // (size is bytes, or chars in a buffer of twice that: size / 2 fits both)
        memset(w, 0, cap * 2);
        for (const unsigned char *s = (const unsigned char *)text; *s && n + 2 < cap;) {
            uint32_t cp = *s < 0x80 ? *s : *s < 0xe0 ? *s & 0x1f : *s < 0xf0 ? *s & 0x0f : *s & 0x07;
            int more = *s < 0x80 ? 0 : *s < 0xe0 ? 1 : *s < 0xf0 ? 2 : 3;
            s++;
            while (more-- > 0 && (*s & 0xc0) == 0x80) cp = cp << 6 | (*s++ & 0x3f);
            if (cp >= 0x10000) { cp -= 0x10000; w[n++] = (uint16_t)(0xd800 | cp >> 10); w[n++] = (uint16_t)(0xdc00 | (cp & 0x3ff)); }
            else w[n++] = (uint16_t)cp;
        }
    }
    // cancelled: nn::swkbd's "canceled" result (module 159, 1), as on the Switch. An empty success made the Lumiose Online
    // mod's Market fields open the keyboard again at once, so it could not be closed
    c->x[0] = ok ? 0 : MAKE_RESULT(159, 1);
}
