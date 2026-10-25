// Software keyboard (naming Link on a new file, ...). On the Switch nn::swkbd::ShowKeyboard launches the keyboard
// library applet; our am service has no applets, so the game crashed. ShowKeyboard is replaced here: the overlay
// (runtime/ui/menu.mm menu_keyboard_run) asks for the text - typed directly with a keyboard, an on-screen keyboard
// with a controller - while this (game) thread keeps re-presenting the last frame.
#include <stdio.h>
#include <string.h>

#include "../hle.h"

int menu_keyboard_run(const char *initial, int max_len, char *out, int cap);  // runtime/ui/menu.mm

// nn::swkbd::ShowKeyboard(nn::swkbd::String *out, const nn::swkbd::ShowKeyboardArg &arg) -> nn::Result
// String = {void *ptr; size_t bufSize}
// ShowKeyboardArg (probed 2026-10-08, naming Link): +0x3ac text max length, +0x3b0 min length, +0x3c0 / +0x3c4
// initial text offset / length (UTF-16) in the work buffer at +0x4d0. The game reads the answer as UTF-8.
HLE_FUNC("_ZN2nn5swkbd12ShowKeyboardEPNS0_6StringERKNS0_15ShowKeyboardArgE", swkbd_show) {
    uint64_t out = c->x[0], arg = c->x[1];
    uint64_t ptr = LD64(out), size = LD64(out + 8);
    int max_len = (int)*(const int32_t *)(uintptr_t)(arg + 0x3ac);
    uint32_t off = *(const uint32_t *)(uintptr_t)(arg + 0x3c0), n = *(const uint32_t *)(uintptr_t)(arg + 0x3c4);
    uint64_t wb = LD64(arg + 0x4d0);
    char initial[96] = "";
    for (uint32_t i = 0; wb && i < n && i < sizeof initial - 1; i++) {
        uint16_t ch = *(const uint16_t *)(uintptr_t)(wb + off + 2 * i);
        initial[i] = ch < 0x80 ? (char)ch : '?';
    }
    char text[96];
    LOG("[swkbd] name entry: waiting for host input (max %d, initial \"%s\")\n", max_len, initial);
    int ok = menu_keyboard_run(initial, max_len, text, sizeof text);
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
    c->x[0] = 0;
}
