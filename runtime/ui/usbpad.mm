// Wired Xbox controllers that macOS has no driver for (another vendor's Xbox One pad, an Xbox One pad of a model the
// system driver doesn't take, any wired Xbox 360 pad): SDL never sees them, the browser does (it reads USB itself).
// Here they are found and read through IOUSBHost (the decoding: usbpad.h) and handed to SDL as a virtual gamepad of
// the pad's own vendor / product, so the game, the menus and the button prompts take them as any other controller.
//
// A pad is taken only when no driver has it USBPAD_WAIT after it appeared: one the system's Xbox driver takes stays
// with SDL (through GameController) and is never read twice. An unconfigured pad is configured without the system
// matching drivers to it, its controller interface opened, the start packets sent (GIP) and its interrupt IN pipe read;
// a GIP pad that announces itself again (a reset) gets them again. Everything runs on one serial queue of its own.
// LARECOMP_USB_PADS=0: off. Not read: rumble and the player light (shortcut: add GIP 0x09 / XUSB rumble packets in
// Rumble when someone asks).
#import <Foundation/Foundation.h>
#import <IOKit/IOKitLib.h>
#import <IOUSBHost/IOUSBHost.h>
#include <SDL3/SDL.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include "usbpad.h"

#define LOG(...) fprintf(stderr, __VA_ARGS__)
#define USBPAD_WAIT 1.5

struct UsbPad {
    int xusb = 0, vid = 0, pid = 0;
    uint64_t entry = 0;
    char name[64] = {};
    uint8_t seq = 0;
    UsbPadState st = {};    // the decoded state (the queue writes it, SDL's Update reads it: g_lock)
    uint32_t tapped = 0;    // buttons pressed since SDL's last Update: a tap shorter than its pass still reaches it (g_lock)
    IOUSBHostDevice *dev = nil;
    IOUSBHostInterface *intf = nil;
    IOUSBHostPipe *in = nil, *out = nil;
    NSMutableData *buf = nil;
    SDL_JoystickID jid = 0;
    bool gone = false;      // being removed: a read that completes is not queued again
    int pending = 0;        // requests not completed yet (the pad is freed at 0 once gone)
    UsbPad *next = nullptr;
};

static dispatch_queue_t g_q;
static IONotificationPortRef g_port;
static io_iterator_t g_gip_iter, g_xusb_iter;
static UsbPad *g_pads;
static pthread_mutex_t g_lock = PTHREAD_MUTEX_INITIALIZER;
static bool g_log;  // LARECOMP_USB_PADS_LOG=1: each report that changed the state, raw

static const char *kind(const UsbPad *d) { return d->xusb ? "Xbox 360" : "Xbox One"; }

// SDL's joystick update (its thread, while the gamepad is open): the latest decoded state
static void SDLCALL pad_update(void *user) {
    UsbPad *d = (UsbPad *)user;
    pthread_mutex_lock(&g_lock);
    UsbPadState s = d->st;
    s.buttons |= d->tapped;
    d->tapped = 0;
    pthread_mutex_unlock(&g_lock);
    SDL_Joystick *js = SDL_GetJoystickFromID(d->jid);
    if (!js) return;
    for (int b = 0; b < USBPAD_NBUTTONS; b++) SDL_SetJoystickVirtualButton(js, b, (s.buttons >> b & 1) != 0);
    for (int a = 0; a < USBPAD_NAXES; a++) SDL_SetJoystickVirtualAxis(js, a, s.axis[a]);
}

static void attach(UsbPad *d) {
    SDL_VirtualJoystickDesc desc;
    SDL_INIT_INTERFACE(&desc);
    desc.type = SDL_JOYSTICK_TYPE_GAMEPAD;
    desc.vendor_id = (Uint16)d->vid, desc.product_id = (Uint16)d->pid;  // (the prompts' family: input.c)
    desc.naxes = USBPAD_NAXES, desc.nbuttons = USBPAD_NBUTTONS;
    desc.button_mask = (1u << USBPAD_NBUTTONS) - 1, desc.axis_mask = (1u << USBPAD_NAXES) - 1;
    desc.name = d->name;
    desc.userdata = d;
    desc.Update = pad_update;
    d->jid = SDL_AttachVirtualJoystick(&desc);
    if (!d->jid) LOG("[usbpad] '%s': SDL took no virtual gamepad (%s)\n", d->name, SDL_GetError());
}

static void done(UsbPad *d) { if (--d->pending == 0 && d->gone) delete d; }

static void close_usb(UsbPad *d) {
    d->gone = true;
    IOUSBHostInterface *intf = d->intf;
    IOUSBHostDevice *dev = d->dev;
    d->intf = nil, d->dev = nil, d->in = nil, d->out = nil, d->buf = nil;
    [intf destroy];
    [dev destroy];
}

static void remove_pad(UsbPad *d) {
    UsbPad **link = &g_pads;
    while (*link && *link != d) link = &(*link)->next;
    if (!*link) return;  // removed already
    *link = d->next;
    d->gone = true;
    d->pending++;  // (alive while destroy completes the pending requests)
    if (d->jid) SDL_DetachVirtualJoystick(d->jid);  // (SDL calls Update no more after this)
    d->jid = 0;
    close_usb(d);
    done(d);
}

static void send(UsbPad *d, const uint8_t *p, size_t n) {
    if (d->gone || !d->out) return;
    NSMutableData *data = [NSMutableData dataWithBytes:p length:n];
    NSError *err = nil;
    BOOL ok = [d->out enqueueIORequestWithData:data completionTimeout:0 error:&err completionHandler:^(IOReturn st, NSUInteger) {
        (void)data;
        if (st != kIOReturnSuccess && st != kIOReturnAborted && !d->gone) LOG("[usbpad] '%s': a packet was not sent (0x%x)\n", d->name, st);
        done(d);
    }];
    if (ok) d->pending++;
    else LOG("[usbpad] '%s': cannot send a packet (%s)\n", d->name, err.localizedDescription.UTF8String);
}

static void send_start(UsbPad *d) {
    size_t at = 0, n;
    uint8_t p[USBPAD_PACKET_MAX];
    while ((n = usbpad_gip_init(d->vid, d->pid, &at, &d->seq, p))) send(d, p, n);
}

static void listen(UsbPad *d) {
    if (d->gone || !d->in || !d->buf) return;
    NSMutableData *buf = d->buf;
    NSError *err = nil;
    BOOL ok = [d->in enqueueIORequestWithData:buf completionTimeout:0 error:&err completionHandler:^(IOReturn st, NSUInteger n) {
        if (d->gone) { done(d); return; }
        if (st != kIOReturnSuccess) {
            LOG("[usbpad] '%s' (%s): reading stopped (0x%x)\n", d->name, kind(d), st);
            remove_pad(d);
            done(d);
            return;
        }
        const uint8_t *r = (const uint8_t *)buf.bytes;
        pthread_mutex_lock(&g_lock);
        int act;
        uint32_t before = d->st.buttons;
        uint8_t ack[USBPAD_PACKET_MAX];
        size_t ack_len = 0;
        if (d->xusb) act = usbpad_xusb_decode(&d->st, r, n);
        else act = usbpad_gip_decode(&d->st, r, n, ack, &ack_len);
        d->tapped |= d->st.buttons & ~before;
        if (act == 2) memset(&d->st, 0, sizeof d->st);
        if (g_log && act) {
            char hex[3 * 24 + 1] = {};
            for (NSUInteger i = 0; i < n && i < 24; i++) snprintf(hex + 3 * i, 4, "%02x ", r[i]);
            LOG("[usbpad] '%s': %s-> buttons %04x\n", d->name, hex, d->st.buttons);
        }
        pthread_mutex_unlock(&g_lock);
        if (ack_len) send(d, ack, ack_len);
        if (act == 2) {
            LOG("[usbpad] '%s' (Xbox One) announced itself again: started again\n", d->name);
            send_start(d);
        }
        listen(d);  // (before done: the pad stays allocated while a read is queued)
        done(d);
    }];
    if (!ok) {
        LOG("[usbpad] '%s': cannot read it (%s)\n", d->name, err.localizedDescription.UTF8String);
        remove_pad(d);
        return;
    }
    d->pending++;
}

// A driver has the device already: the system's Xbox driver puts a service of its own on it and its HID driver on the
// controller interface. Interfaces with nothing but user clients on them (a browser reading it, an earlier run of
// this app: the pad stays configured) are no driver.
static bool has_driver(io_registry_entry_t s, int depth) {
    io_iterator_t it;
    if (IORegistryEntryGetChildIterator(s, kIOServicePlane, &it) != KERN_SUCCESS) return true;
    bool claimed = false;
    io_object_t c;
    while (!claimed && (c = IOIteratorNext(it))) {
        if (IOObjectConformsTo(c, "IOUserClient")) {}
        else if (!depth && IOObjectConformsTo(c, "IOUSBHostInterface")) claimed = has_driver(c, 1);
        else claimed = true;
        IOObjectRelease(c);
    }
    IOObjectRelease(it);
    return claimed;
}
static int int_prop(io_service_t s, CFStringRef key) {
    NSNumber *n = CFBridgingRelease(IORegistryEntryCreateCFProperty(s, key, kCFAllocatorDefault, 0));
    return [n isKindOfClass:[NSNumber class]] ? n.intValue : -1;
}
static bool interface_ok(int xusb, int cls, int sub, int pro) {
    return xusb ? cls == 0xff && sub == XUSB_IF_SUBCLASS && pro == XUSB_IF_PROTOCOL
                : cls == GIP_CLASS && sub == GIP_SUBCLASS && pro == GIP_PROTOCOL;
}
static bool config_has_interface(const IOUSBConfigurationDescriptor *cd, int xusb) {
    const IOUSBInterfaceDescriptor *id = NULL;
    while ((id = IOUSBGetNextInterfaceDescriptor(cd, (const IOUSBDescriptorHeader *)id)))
        if (interface_ok(xusb, id->bInterfaceClass, id->bInterfaceSubClass, id->bInterfaceProtocol)) return true;
    return false;
}

// The controller interface (GIP: IN and OUT interrupt pipes; XUSB: an IN one) opened: its read size, 0 when none is
// ready. *any: interfaces seen at all (none yet: they register a moment after the configuration).
static NSUInteger open_interface(UsbPad *d, int *any, NSError **err_out) {
    *any = 0;
    io_iterator_t it;
    if (IORegistryEntryGetChildIterator(d->dev.ioService, kIOServicePlane, &it) != KERN_SUCCESS) return 0;
    NSUInteger cap = 0;
    io_object_t c;
    while (!cap && (c = IOIteratorNext(it))) {
        if (!IOObjectConformsTo(c, "IOUSBHostInterface")) { IOObjectRelease(c); continue; }
        (*any)++;
        if (!interface_ok(d->xusb, int_prop(c, CFSTR("bInterfaceClass")), int_prop(c, CFSTR("bInterfaceSubClass")), int_prop(c, CFSTR("bInterfaceProtocol")))) {
            IOObjectRelease(c);
            continue;
        }
        NSError *err = nil;
        IOUSBHostInterface *intf = [[IOUSBHostInterface alloc] initWithIOService:c options:IOUSBHostObjectInitOptionsNone queue:g_q error:&err interestHandler:nil];
        IOObjectRelease(c);
        if (!intf) { if (err_out && !*err_out) *err_out = err; continue; }
        const IOUSBInterfaceDescriptor *id0 = intf.interfaceDescriptor;
        IOUSBHostPipe *in = nil, *out = nil;
        NSUInteger size = 64;
        for (const IOUSBDescriptorHeader *h = NULL;
             id0 && (h = IOUSBGetNextAssociatedDescriptorWithType(intf.configurationDescriptor, (const IOUSBDescriptorHeader *)id0, h, kIOUSBDescriptorTypeEndpoint));) {
            const IOUSBEndpointDescriptor *ep = (const IOUSBEndpointDescriptor *)h;
            if ((ep->bmAttributes & 3) != kIOUSBEndpointTypeInterrupt) continue;
            bool is_in = (ep->bEndpointAddress & 0x80) != 0;
            if (is_in ? in != nil : out != nil) continue;
            IOUSBHostPipe *p = [intf copyPipeWithAddress:ep->bEndpointAddress error:&err];
            if (!p) continue;
            if (is_in) { in = p; NSUInteger mps = ep->wMaxPacketSize & 0x7ff; if (mps > size) size = mps; }
            else out = p;
        }
        if (!in || (!d->xusb && !out)) {
            if (err_out && !*err_out) *err_out = err;
            [intf destroy];
            continue;
        }
        d->intf = intf, d->in = in, d->out = out;
        cap = size;
    }
    IOObjectRelease(it);
    return cap;
}

static void open_pad(uint64_t entry, int xusb, int tries, bool configured) {
    for (UsbPad *o = g_pads; o; o = o->next) if (o->entry == entry) return;
    io_service_t s = IOServiceGetMatchingService(kIOMainPortDefault, IORegistryEntryIDMatching(entry));
    if (!s) return;  // unplugged meanwhile
    if (has_driver(s, 0)) { IOObjectRelease(s); return; }  // the system's driver: SDL reads it
    UsbPad *d = new UsbPad;
    d->xusb = xusb, d->entry = entry;
    d->vid = int_prop(s, CFSTR("idVendor")), d->pid = int_prop(s, CFSTR("idProduct"));
    NSString *name = CFBridgingRelease(IORegistryEntryCreateCFProperty(s, CFSTR("USB Product Name"), kCFAllocatorDefault, 0));
    snprintf(d->name, sizeof d->name, "%s", [name isKindOfClass:[NSString class]] && name.length && strcmp(name.UTF8String, "Controller")
                                                ? name.UTF8String : xusb ? "Xbox 360 Controller" : "Xbox One Controller");
    NSError *err = nil;
    d->dev = [[IOUSBHostDevice alloc] initWithIOService:s options:IOUSBHostObjectInitOptionsNone queue:g_q error:&err
                                        interestHandler:^(IOUSBHostObject *, uint32_t type, void *) {
        if (type != kIOMessageServiceIsTerminated) return;
        dispatch_async(g_q, ^{  // (by its registry entry: the pad may be gone already)
            for (UsbPad *p = g_pads; p; p = p->next)
                if (p->entry == entry) { LOG("[usbpad] '%s' (%s) unplugged\n", p->name, kind(p)); remove_pad(p); return; }
        });
    }];
    IOObjectRelease(s);
    if (!d->dev) {
        LOG("[usbpad] '%s' (%04x:%04x): cannot open it (%s): another app may be reading it\n", d->name, d->vid, d->pid, err.localizedDescription.UTF8String);
        delete d;
        return;
    }
    int any = 0;
    NSUInteger cap = open_interface(d, &any, &err);
    if (!any && !configured) {  // configured once (configuring again tears down interfaces still registering)
        const IOUSBConfigurationDescriptor *cd = [d->dev configurationDescriptorWithIndex:0 error:nil];
        if (cd && !config_has_interface(cd, xusb)) { close_usb(d); delete d; return; }  // (not a controller: a receiver, a headset)
        if (![d->dev configureWithValue:cd ? cd->bConfigurationValue : 1 matchInterfaces:NO error:&err]) {
            LOG("[usbpad] '%s': cannot configure it (%s)\n", d->name, err.localizedDescription.UTF8String);
            close_usb(d);
            delete d;
            return;
        }
        configured = true;
        cap = open_interface(d, &any, &err);
    }
    if (!cap) {
        if (any && (err || !xusb)) LOG("[usbpad] '%s' (%04x:%04x): its %s interface cannot be opened (%s)\n", d->name, d->vid, d->pid, kind(d),
                     err ? err.localizedDescription.UTF8String : "none usable");
        close_usb(d);
        delete d;
        if (!any) {  // its interfaces register a moment after the configuration
            if (tries > 1) dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 10), g_q, ^{ open_pad(entry, xusb, tries - 1, configured); });
            else LOG("[usbpad] an %s pad's interface did not appear after its configuration\n", xusb ? "Xbox 360" : "Xbox One");
        }
        return;
    }
    d->buf = [d->intf ioDataWithCapacity:cap error:&err];
    if (!d->buf) { LOG("[usbpad] '%s': no read buffer (%s)\n", d->name, err.localizedDescription.UTF8String); close_usb(d); delete d; return; }
    d->next = g_pads, g_pads = d;
    LOG("[usbpad] '%s' (USB, %s, %04x:%04x): no macOS driver has it, read here\n", d->name, kind(d), d->vid, d->pid);
    if (!xusb) send_start(d);
    attach(d);
    listen(d);
}

static void matched(void *ctx, io_iterator_t it) {
    int xusb = (int)(intptr_t)ctx;
    io_object_t s;
    while ((s = IOIteratorNext(it))) {
        uint64_t entry = 0;
        IORegistryEntryGetRegistryEntryID(s, &entry);
        IOObjectRelease(s);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(USBPAD_WAIT * NSEC_PER_SEC)), g_q, ^{ open_pad(entry, xusb, 10, false); });
    }
}

static bool watch(int xusb, int cls, int sub, int pro, io_iterator_t *iter) {
    // (by property: the keys of +[IOUSBHostDevice createMatchingDictionary...] are a driver personality's, which a
    // notification does not find a device by)
    NSDictionary *props = @{@"bDeviceClass": @(cls), @"bDeviceSubClass": @(sub), @"bDeviceProtocol": @(pro)};
    CFDictionaryRef match = (__bridge_retained CFDictionaryRef)@{@kIOProviderClassKey: @"IOUSBHostDevice", @kIOPropertyMatchKey: props};
    if (IOServiceAddMatchingNotification(g_port, kIOFirstMatchNotification, match, matched, (void *)(intptr_t)xusb, iter) != KERN_SUCCESS) return false;
    matched((void *)(intptr_t)xusb, *iter);  // the pads plugged in already, and arms the notification
    return true;
}

// After SDL_Init (runtime/nvn/metal.m): once per process
extern "C" void usbpad_start(void) {
    static bool started;
    const char *e = getenv("LARECOMP_USB_PADS");
    if (started || (e && !strcmp(e, "0"))) return;
    started = true;
    g_log = getenv("LARECOMP_USB_PADS_LOG") && strcmp(getenv("LARECOMP_USB_PADS_LOG"), "0");
    g_q = dispatch_queue_create("monzamac.usbpad", DISPATCH_QUEUE_SERIAL);
    g_port = IONotificationPortCreate(kIOMainPortDefault);
    if (!g_port) return;
    IONotificationPortSetDispatchQueue(g_port, g_q);
    dispatch_async(g_q, ^{
        bool gip = watch(0, GIP_CLASS, GIP_SUBCLASS, GIP_PROTOCOL, &g_gip_iter);
        bool xusb = watch(1, 0xff, 0xff, 0xff, &g_xusb_iter);
        if (!gip || !xusb) LOG("[usbpad] cannot watch USB devices (Xbox One %d, Xbox 360 %d): only the controllers SDL sees are read\n", gip, xusb);
    });
}
