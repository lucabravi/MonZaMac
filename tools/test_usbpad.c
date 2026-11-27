// The wired Xbox pad decoder (runtime/ui/usbpad.h) on made-up reports: buttons, triggers and sticks in SDL's layout,
// the Xbox button's acknowledgement, a re-announce, the start packets per vendor, and short or foreign packets ignored.
#include <assert.h>
#include <stdio.h>
#include "../runtime/ui/usbpad.h"

#define BIT(b) (1u << (b))

static void gip(void) {
    UsbPadState s = {0};
    uint8_t ack[USBPAD_PACKET_MAX];
    size_t ack_len;
    // A + Menu, d-pad right + RB, LT full, RT half, LX full right, LY full up, RX -1/2, RY full down
    uint8_t r[18] = {GIP_INPUT, 0, 1, 14, 0x04 | 0x10, 0x08 | 0x20, 0xff, 0x03, 0x00, 0x02,
                     0xff, 0x7f, 0xff, 0x7f, 0x00, 0xc0, 0x00, 0x80};
    assert(usbpad_gip_decode(&s, r, sizeof r, ack, &ack_len) == 1 && ack_len == 0);
    assert(s.buttons == (BIT(USBPAD_SOUTH) | BIT(USBPAD_START) | BIT(USBPAD_RIGHT) | BIT(USBPAD_RB)));
    assert(s.axis[USBPAD_LT] == 32767 && s.axis[USBPAD_RT] == 512 * 32767 / 1023);
    assert(s.axis[USBPAD_LX] == 32767 && s.axis[USBPAD_LY] == -32767);  // (Y up on the pad, down in SDL)
    assert(s.axis[USBPAD_RX] == -16384 && s.axis[USBPAD_RY] == 32767);
    assert(usbpad_gip_decode(&s, r, sizeof r, ack, &ack_len) == 0);     // the same report again: no change
    // the Xbox button, asking for an acknowledgement with its own sequence number; kept through the next input report
    uint8_t g[6] = {GIP_GUIDE, GIP_OPT_ACK | GIP_OPT_INTERNAL, 0x42, 2, 0x01, 0x5b};
    assert(usbpad_gip_decode(&s, g, sizeof g, ack, &ack_len) == 1 && ack_len == 13 && ack[0] == GIP_ACK && ack[2] == 0x42);
    assert(s.buttons & BIT(USBPAD_GUIDE));
    r[4] = 0;
    assert(usbpad_gip_decode(&s, r, sizeof r, ack, &ack_len) == 1 && (s.buttons & BIT(USBPAD_GUIDE)) && !(s.buttons & BIT(USBPAD_SOUTH)));
    g[1] = GIP_OPT_INTERNAL, g[4] = 0;
    assert(usbpad_gip_decode(&s, g, sizeof g, ack, &ack_len) == 1 && ack_len == 0 && !(s.buttons & BIT(USBPAD_GUIDE)));
    // the pad announcing itself (a reset); short and foreign packets
    uint8_t a[4] = {GIP_ANNOUNCE, 0x20, 0, 0};
    assert(usbpad_gip_decode(&s, a, sizeof a, ack, &ack_len) == 2);
    assert(usbpad_gip_decode(&s, r, 3, ack, &ack_len) == 0);
    assert(usbpad_gip_decode(&s, r, 17, ack, &ack_len) == 0);
    uint8_t st[8] = {0x03, 0x20, 0, 4, 0, 0, 0, 0};
    assert(usbpad_gip_decode(&s, st, sizeof st, ack, &ack_len) == 0);
}

static void start_packets(void) {
    size_t at = 0, n, count = 0;
    uint8_t seq = 7, p[USBPAD_PACKET_MAX];
    while ((n = usbpad_gip_init(0x045e, 0x02d1, &at, &seq, p))) count++;
    assert(count == 1 && seq == 8);  // an original Xbox One pad: power on only
    at = 0, count = 0;
    while ((n = usbpad_gip_init(0x0e6f, 0x02a8, &at, &seq, p))) { assert(p[2] == (uint8_t)(seq - 1)); count++; }
    assert(count == 3);              // PDP: power on, light, authentication
}

static void xusb(void) {
    UsbPadState s = {0};
    // Back + left stick click, B + Guide, triggers 255 / 0, sticks: LX left, LY up
    uint8_t r[20] = {0x00, 20, 0x20 | 0x40, 0x20 | 0x04, 255, 0, 0x00, 0x80, 0xff, 0x7f};
    assert(usbpad_xusb_decode(&s, r, sizeof r) == 1);
    assert(s.buttons == (BIT(USBPAD_BACK) | BIT(USBPAD_LSTICK) | BIT(USBPAD_EAST) | BIT(USBPAD_GUIDE)));
    assert(s.axis[USBPAD_LT] == 32767 && s.axis[USBPAD_RT] == 0 && s.axis[USBPAD_LX] == -32768 && s.axis[USBPAD_LY] == -32767);
    assert(usbpad_xusb_decode(&s, r, sizeof r) == 0);
    uint8_t led[3] = {0x01, 0x03, 0x0e};  // a state message at connect
    assert(usbpad_xusb_decode(&s, led, sizeof led) == 0);
    r[1] = 19;
    assert(usbpad_xusb_decode(&s, r, sizeof r) == 0);
}

int main(void) {
    gip();
    start_packets();
    xusb();
    puts("usbpad: ok");
    return 0;
}
