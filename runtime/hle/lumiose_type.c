// Typing straight into the Lumiose Online mod's chat and text fields with the Mac's keyboard, as in a PC launcher: no
// keyboard window. The mod keeps a block for a launcher in its data ("VMPCHAT\0" on a 16-byte boundary; its
// ui/chat_bridge.hpp): what it shows (state: the chat focused, a window's field open for the launcher's text, which field)
// and a ring of 16 commands the launcher fills (set the draft, send / confirm, close / cancel; the text in the block).
// Only those generic commands are used: the mod checks every text it gets against the field's own rules and length, so a
// field it adds later needs nothing here. A block of another version or size is left alone (the keyboard window stays).
//
// Typing is on while the mod says so: the chat has the pad (MINUS) and no applet or other window is up, or a window's
// field is open for the launcher's text (the mod opens it on a mouse tap). Then the keys are the text's, not the game's:
// letters and the like set the draft, Backspace takes the last character, Return sends / confirms, Escape closes / cancels.
// Controllers keep the game's keyboard window (runtime/hle/swkbd.c). LARECOMP_LUMIOSE_TYPE=0: off.
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

#include <SDL3/SDL.h>

#include "../hle.h"

enum { ST_FOCUSED = 1u << 1, ST_KBD_UP = 1u << 2, ST_OTHER_PAD = 1u << 3, ST_FIELD_EDIT = 1u << 5 };
enum { CMD_FOCUS = 1, CMD_CLOSE = 2, CMD_SET_DRAFT = 8, CMD_SEND = 9, CMD_EDIT = 12 };
enum { OFF_VERSION = 8, OFF_SIZE = 12, OFF_STATE = 16, OFF_DONE = 24, OFF_HEAD = 32, OFF_CMDS = 36, OFF_TEXT = 100,
       OFF_FIELD = 228, SIZE_V1 = 228, SIZE_V2 = 232, TEXT_MAX = 120 };

static uint8_t *bridge;  // the mod's block (guest memory, the host's address too)
static uint64_t bridge_room;  // the bytes after it in the mod's data (its size is checked against them)
static _Atomic bool bridge_v2;  // (read by the game thread: runtime/hle/swkbd.c)
static _Atomic int open_field;  // a field the mod asked the keyboard window for, to open for typing instead (0: none)
static uint64_t open_until;
static bool pad_last;  // the last input was a controller's: the mod's keyboard requests keep the keyboard window
static uint64_t next_scan;  // (SDL ticks: the module may not be loaded yet)
static bool typing;
static char draft[TEXT_MAX + 1];
static bool draft_pending;  // the draft is newer than what the mod was given (it was busy reading the last one)
void input_reset(void);

RT_ON_RESET(lumiose_type_reset) { bridge = NULL; bridge_v2 = false; open_field = 0; next_scan = 0; typing = false; draft[0] = 0; draft_pending = false; }

static uint32_t rd32(const uint8_t *p) { return __atomic_load_n((const uint32_t *)p, __ATOMIC_ACQUIRE); }

static bool valid(const uint8_t *b, uint64_t room) {
    if (memcmp(b, "VMPCHAT", 8)) return false;
    uint32_t ver = rd32(b + OFF_VERSION), size = rd32(b + OFF_SIZE);
    return (ver == 1 && size >= SIZE_V1 && size <= room) || (ver == 2 && size >= SIZE_V2 && size <= room);
}

static uint8_t *find_bridge(void) {
    if (bridge && valid(bridge, bridge_room)) return bridge;
    bridge = NULL;
    bridge_v2 = false;
    uint64_t now = SDL_GetTicks();
    if (now < next_scan) return NULL;
    next_scan = now + 2000;
    static int off = -1;
    if (off < 0) { const char *e = getenv("LARECOMP_LUMIOSE_TYPE"); off = e && !strcmp(e, "0"); }
    if (off) return NULL;
    for (int i = 0; i < g_nmodules; i++) {
        const Module *m = &g_modules[i];
        if (!m->name || strcmp(m->name, "subsdk9") || !m->base || m->data_size < SIZE_V2) continue;
        uint8_t *d = (uint8_t *)(uintptr_t)(m->base + m->data_off), *hit = NULL;
        for (uint64_t o = (16 - ((uintptr_t)d & 15)) & 15; o + SIZE_V2 <= m->data_size; o += 16) {
            if (d[o] != 'V' || !valid(d + o, m->data_size - o)) continue;
            if (hit) { LOG("[lumiose type] two chat blocks in the mod: typing in place off\n"); next_scan = UINT64_MAX; return NULL; }
            hit = d + o;
        }
        if (hit) {
            bridge = hit;
            bridge_room = m->data_size - (uint64_t)(hit - d);
            bridge_v2 = rd32(hit + OFF_VERSION) == 2;
            LOG("[lumiose type] the mod's chat block (version %u): typing in place on\n", rd32(hit + OFF_VERSION));
        }
    }
    return bridge;
}

// a command into the ring (head % 16), then head + 1: false when the ring is full or (with text) the mod still reads the text
static bool command(uint16_t cmd, int16_t arg, const char *text) {
    uint32_t done = rd32(bridge + OFF_DONE), head = rd32(bridge + OFF_HEAD);
    if (head - done >= 16 || (text && head != done)) return false;  // (the mod reads the text when it runs the command)
    if (text) {
        size_t n = strlen(text);
        memcpy(bridge + OFF_TEXT, text, n + 1);
    }
    uint8_t *slot = bridge + OFF_CMDS + 4 * (head % 16);
    memcpy(slot, &cmd, 2);
    memcpy(slot + 2, &arg, 2);
    __atomic_store_n((uint32_t *)(bridge + OFF_HEAD), head + 1, __ATOMIC_RELEASE);
    return true;
}

static bool wants_typing(void) {
    if (!find_bridge()) return false;
    uint32_t st = rd32(bridge + OFF_STATE);
    if (rd32(bridge + OFF_VERSION) == 2 && (st & ST_FIELD_EDIT) && bridge[OFF_FIELD]) return true;
    return (st & ST_FOCUSED) && !(st & (ST_KBD_UP | ST_OTHER_PAD));
}

// Once per pass of the window's event loop (runtime/nvn/metal.m): on / off as the mod says, and a draft the mod was too
// busy for handed over now
// runtime/hle/swkbd.c, the mod asks for the keyboard window for its field `field` (1 the chat, then its window fields):
// true = not with a keyboard and mouse player: the window is answered "cancelled" and the field opened for typing in
// place instead (the next tick: the chat focused, or the field edited)
bool lumiose_type_take_keyboard(int field) {
    if (field < 1 || field > 255 || !bridge_v2 || pad_last) return false;
    open_field = field;
    return true;
}

void lumiose_type_tick(SDL_Window *w) {
    if (open_field && bridge) {  // (once the keyboard window's request has ended: commands are dropped while it is up)
        int f = open_field;
        uint64_t now = SDL_GetTicks();
        if (!open_until) open_until = now + 1500;
        uint32_t st = rd32(bridge + OFF_STATE);
        bool sent = false;
        if (!(st & ST_KBD_UP)) {
            if (f == 1) sent = command(CMD_FOCUS, 0, NULL);
            else if (bridge[OFF_FIELD] == f) sent = command(CMD_EDIT, (int16_t)f, NULL);
        }
        if (sent || now > open_until) {
            LOG("[lumiose type] field %d: %s\n", f, sent ? "opened for typing" : "not opened (the mod moved on)");
            open_field = 0, open_until = 0;
        }
    }
    bool want = wants_typing();
    if (want != typing) {
        typing = want;
        draft[0] = 0;
        draft_pending = false;
        if (want) { input_reset(); SDL_StartTextInput(w); }  // (keys held now are not the game's any more)
        else SDL_StopTextInput(w);
        LOG("[lumiose type] %s\n", want ? "typing into the mod's field" : "keys back to the game");
    }
    if (typing && draft_pending && command(CMD_SET_DRAFT, 0, draft)) draft_pending = false;
}

static void set_draft(void) { draft_pending = !command(CMD_SET_DRAFT, 0, draft); }

// The window's events while typing: true when it was the text's (not for the game). Mouse and pads stay the game's.
bool lumiose_type_event(const SDL_Event *e) {
    if (e->type == SDL_EVENT_GAMEPAD_BUTTON_DOWN) pad_last = true;
    else if (e->type == SDL_EVENT_KEY_DOWN || e->type == SDL_EVENT_MOUSE_BUTTON_DOWN) pad_last = false;
    if (!typing || !bridge) return false;
    switch (e->type) {
    case SDL_EVENT_TEXT_INPUT: {
        size_t have = strlen(draft);
        for (const unsigned char *s = (const unsigned char *)e->text.text; *s;) {
            int n = *s < 0x80 ? 1 : *s >= 0xc2 && *s <= 0xdf ? 2 : *s >= 0xe0 && *s <= 0xef ? 3 : *s >= 0xf0 && *s <= 0xf4 ? 4 : 0;
            bool ok = n > 0 && *s >= 0x20 && *s != 0x7f;
            for (int i = 1; ok && i < n; i++) ok = (s[i] & 0xc0) == 0x80;
            if (!ok) break;  // (a broken sequence: the rest dropped, never sent half)
            if (have + n > TEXT_MAX) break;  // (the block's text; the mod cuts each field to its own length)
            memcpy(draft + have, s, n);
            have += n;
            draft[have] = 0;
            s += n;
        }
        set_draft();
        return true;
    }
    case SDL_EVENT_KEY_DOWN:
        if (e->key.scancode == SDL_SCANCODE_BACKSPACE) {
            size_t n = strlen(draft);
            while (n > 0 && ((unsigned char)draft[--n] & 0xc0) == 0x80) {}
            draft[n] = 0;
            set_draft();
        } else if (e->key.scancode == SDL_SCANCODE_RETURN || e->key.scancode == SDL_SCANCODE_KP_ENTER) {
            if (draft_pending) set_draft();
            if (!draft_pending) command(CMD_SEND, 0, NULL);
        } else if (e->key.scancode == SDL_SCANCODE_ESCAPE) {
            command(CMD_CLOSE, 0, NULL);
        }
        return true;
    case SDL_EVENT_KEY_UP: case SDL_EVENT_TEXT_EDITING:
        return true;
    default:
        return false;
    }
}
