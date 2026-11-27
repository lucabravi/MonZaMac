// Wired Xbox controllers that macOS has no driver for, read straight over USB (runtime/ui/usbpad.mm finds them and moves
// the packets; this half is pure, so tools/test_usbpad.c checks it without a controller).
//
// - Xbox One / Series pads speak GIP (device class ff/47/d0): a 4-byte header (command, options, sequence, payload
//   length), then the payload. A pad sends nothing until the host powers it on (usbpad_gip_init: some vendors want a
//   few more packets). The input report (0x20) carries the buttons, the d-pad, the 10-bit triggers and the four 16-bit
//   stick axes (Y up); the Xbox button comes in a report of its own (0x07), which the pad may want acknowledged.
// - Xbox 360 pads speak XUSB (device ff/ff/ff, controller interface ff/5d/01): a 20-byte report, 8-bit triggers.
//
// The state is SDL's gamepad layout (usbpad.mm hands it to SDL as a virtual gamepad, so the rest of the app sees an
// ordinary controller): buttons as bits of SDL_GamepadButton (south = Xbox A ...), axes as SDL gives them (Y down,
// triggers 0..32767).
#pragma once
#include <stddef.h>
#include <stdint.h>
#include <string.h>

enum {  // SDL_GamepadButton's values (SDL3/SDL_gamepad.h), kept here so the decoder needs no SDL
    USBPAD_SOUTH = 0, USBPAD_EAST, USBPAD_WEST, USBPAD_NORTH, USBPAD_BACK, USBPAD_GUIDE, USBPAD_START,
    USBPAD_LSTICK, USBPAD_RSTICK, USBPAD_LB, USBPAD_RB, USBPAD_UP, USBPAD_DOWN, USBPAD_LEFT, USBPAD_RIGHT, USBPAD_NBUTTONS
};
enum { USBPAD_LX = 0, USBPAD_LY, USBPAD_RX, USBPAD_RY, USBPAD_LT, USBPAD_RT, USBPAD_NAXES };  // SDL_GamepadAxis's

typedef struct {
    uint32_t buttons;            // 1 << USBPAD_*
    int16_t axis[USBPAD_NAXES];
    int heard;                   // an input report has come
} UsbPadState;

#define GIP_CLASS 0xff
#define GIP_SUBCLASS 0x47
#define GIP_PROTOCOL 0xd0
#define XUSB_IF_SUBCLASS 0x5d   // (class ff, protocol 01; 81 is a wireless receiver, 02 a headset)
#define XUSB_IF_PROTOCOL 0x01
#define USBPAD_PACKET_MAX 16

enum { GIP_ACK = 0x01, GIP_ANNOUNCE = 0x02, GIP_POWER = 0x05, GIP_AUTH = 0x06, GIP_GUIDE = 0x07, GIP_RUMBLE = 0x09,
       GIP_LED = 0x0a, GIP_INPUT = 0x20 };
#define GIP_OPT_ACK 0x10
#define GIP_OPT_INTERNAL 0x20

// The packets a GIP pad gets at its start, in order (vid / pid 0: any). Byte 2, the sequence number, is filled in.
typedef struct { uint16_t vid, pid; uint8_t len, p[USBPAD_PACKET_MAX]; } UsbPadPacket;
static const UsbPadPacket usbpad_gip_start[] = {
    {0, 0, 5, {GIP_POWER, GIP_OPT_INTERNAL, 0, 1, 0x00}},                               // power on
    {0x045e, 0x02ea, 5, {GIP_POWER, GIP_OPT_INTERNAL, 0, 0x0f, 0x06}},                  // Xbox One S: start the input
    {0x045e, 0x0b00, 6, {0x4d, GIP_OPT_ACK, 0, 2, 0x07, 0x00}},                         // Elite Series 2: the paddles
    {0x0e6f, 0, 7, {GIP_LED, GIP_OPT_INTERNAL, 0, 3, 0x00, 0x01, 0x14}},                // PDP: no input without its light
    {0x0e6f, 0, 6, {GIP_AUTH, GIP_OPT_INTERNAL, 0, 2, 0x01, 0x00}},                     // PDP: authentication done
    {0x24c6, 0x541a, 13, {GIP_RUMBLE, 0, 0, 9, 0, 0x0f, 0, 0, 0x1d, 0x1d, 0xff, 0, 0}}, // PowerA: no input without a
    {0x24c6, 0x542a, 13, {GIP_RUMBLE, 0, 0, 9, 0, 0x0f, 0, 0, 0x1d, 0x1d, 0xff, 0, 0}}, // rumble start and stop
    {0x24c6, 0x543a, 13, {GIP_RUMBLE, 0, 0, 9, 0, 0x0f, 0, 0, 0x1d, 0x1d, 0xff, 0, 0}},
    {0x24c6, 0x541a, 13, {GIP_RUMBLE, 0, 0, 9, 0, 0x0f, 0, 0, 0, 0, 0, 0, 0}},
    {0x24c6, 0x542a, 13, {GIP_RUMBLE, 0, 0, 9, 0, 0x0f, 0, 0, 0, 0, 0, 0, 0}},
    {0x24c6, 0x543a, 13, {GIP_RUMBLE, 0, 0, 9, 0, 0x0f, 0, 0, 0, 0, 0, 0, 0}},
};

// The next start packet for this pad at or after *at (moved past it), with the sequence number *seq (then + 1): its
// length, 0 when none is left
static inline size_t usbpad_gip_init(int vid, int pid, size_t *at, uint8_t *seq, uint8_t out[USBPAD_PACKET_MAX]) {
    for (; *at < sizeof usbpad_gip_start / sizeof usbpad_gip_start[0]; (*at)++) {
        const UsbPadPacket *k = &usbpad_gip_start[*at];
        if ((k->vid && k->vid != vid) || (k->pid && k->pid != pid)) continue;
        memcpy(out, k->p, k->len);
        out[2] = (*seq)++;
        (*at)++;
        return k->len;
    }
    return 0;
}

static inline int16_t usbpad_le16(const uint8_t *p) { return (int16_t)(p[0] | p[1] << 8); }
static inline int16_t usbpad_flip(int16_t v) { return v == -32768 ? 32767 : (int16_t)-v; }  // (Y up -> SDL's Y down)
static inline void usbpad_sticks(UsbPadState *s, const uint8_t *p) {
    s->axis[USBPAD_LX] = usbpad_le16(p);
    s->axis[USBPAD_LY] = usbpad_flip(usbpad_le16(p + 2));
    s->axis[USBPAD_RX] = usbpad_le16(p + 4);
    s->axis[USBPAD_RY] = usbpad_flip(usbpad_le16(p + 6));
}
static inline uint32_t usbpad_bits(const uint8_t *r, const uint8_t (*map)[3], size_t n) {
    uint32_t m = 0;
    for (size_t i = 0; i < n; i++) if (r[map[i][0]] >> map[i][1] & 1) m |= 1u << map[i][2];
    return m;
}

// One GIP packet. Returns 1 the state changed, 2 the pad announced itself (again: send the start packets), 0 nothing.
// *ack_len > 0: send `ack` back (the Xbox button's report can ask for one).
static inline int usbpad_gip_decode(UsbPadState *s, const uint8_t *r, size_t n, uint8_t ack[USBPAD_PACKET_MAX], size_t *ack_len) {
    *ack_len = 0;
    if (n < 4) return 0;
    if (r[0] == GIP_ANNOUNCE) return 2;
    if (r[0] == GIP_GUIDE && n >= 5) {
        if (r[1] == (GIP_OPT_ACK | GIP_OPT_INTERNAL)) {
            static const uint8_t a[13] = {GIP_ACK, GIP_OPT_INTERNAL, 0, 9, 0x00, GIP_GUIDE, GIP_OPT_INTERNAL, 0x02};
            memcpy(ack, a, sizeof a);
            ack[2] = r[2];
            *ack_len = sizeof a;
        }
        uint32_t b = (r[4] & 3) ? s->buttons | 1u << USBPAD_GUIDE : s->buttons & ~(1u << USBPAD_GUIDE);
        int changed = b != s->buttons;
        s->buttons = b;
        return changed;
    }
    if (r[0] != GIP_INPUT || n < 18 || r[3] < 14 || n < 4u + r[3]) return 0;
    static const uint8_t map[][3] = {
        {4, 2, USBPAD_START}, {4, 3, USBPAD_BACK}, {4, 4, USBPAD_SOUTH}, {4, 5, USBPAD_EAST}, {4, 6, USBPAD_WEST}, {4, 7, USBPAD_NORTH},
        {5, 0, USBPAD_UP}, {5, 1, USBPAD_DOWN}, {5, 2, USBPAD_LEFT}, {5, 3, USBPAD_RIGHT}, {5, 4, USBPAD_LB}, {5, 5, USBPAD_RB},
        {5, 6, USBPAD_LSTICK}, {5, 7, USBPAD_RSTICK},
    };
    UsbPadState t = *s;
    t.buttons = usbpad_bits(r, map, sizeof map / sizeof map[0]) | (s->buttons & 1u << USBPAD_GUIDE);
    t.axis[USBPAD_LT] = (int16_t)(((r[6] | r[7] << 8) & 0x3ff) * 32767 / 1023);
    t.axis[USBPAD_RT] = (int16_t)(((r[8] | r[9] << 8) & 0x3ff) * 32767 / 1023);
    usbpad_sticks(&t, r + 10);
    t.heard = 1;
    int changed = !s->heard || memcmp(&t, s, sizeof t);
    *s = t;
    return changed;
}

// One XUSB report: 1 when it is an input report and the state changed. Byte 2: d-pad, Start, Back, stick clicks;
// byte 3: LB, RB, Guide, A, B, X, Y; bytes 4-5 the triggers (0..255); 6-13 the sticks (Y up).
static inline int usbpad_xusb_decode(UsbPadState *s, const uint8_t *r, size_t n) {
    if (n < 20 || r[0] != 0x00 || r[1] != 20) return 0;
    static const uint8_t map[][3] = {
        {2, 0, USBPAD_UP}, {2, 1, USBPAD_DOWN}, {2, 2, USBPAD_LEFT}, {2, 3, USBPAD_RIGHT}, {2, 4, USBPAD_START}, {2, 5, USBPAD_BACK},
        {2, 6, USBPAD_LSTICK}, {2, 7, USBPAD_RSTICK}, {3, 0, USBPAD_LB}, {3, 1, USBPAD_RB}, {3, 2, USBPAD_GUIDE},
        {3, 4, USBPAD_SOUTH}, {3, 5, USBPAD_EAST}, {3, 6, USBPAD_WEST}, {3, 7, USBPAD_NORTH},
    };
    UsbPadState t = *s;
    t.buttons = usbpad_bits(r, map, sizeof map / sizeof map[0]);
    t.axis[USBPAD_LT] = (int16_t)(r[4] * 32767 / 255);
    t.axis[USBPAD_RT] = (int16_t)(r[5] * 32767 / 255);
    usbpad_sticks(&t, r + 6);
    t.heard = 1;
    int changed = !s->heard || memcmp(&t, s, sizeof t);
    *s = t;
    return changed;
}
