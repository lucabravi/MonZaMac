# Guest memory layout

The guest's addresses are the host's: the generated code reads and writes them directly, and its images are at
fixed addresses (`runtime/rt.h`). Everything must lie below 2^39 (the SDK encodes IPC buffer addresses in 39 bits).

The reservations (`runtime/guest_layout.c`, claimed in a constructor, before anything else can map there):

| Part | Address | Size |
|---|---|---|
| Low window: images, host-implemented functions, TLS, stacks, heap | `0x70_0000_0000` | 7 GB |
| Alias region (the SDK's virtual address memory; Z-A reserves 12 GB in it) | right behind the low window, else the first free hole below 2^39 | 16 GB, or 14 / 13 GB when no 16 GB hole is left |

Both are address space only: pages are committed on first touch.

**Why two.** One 32 GB window at `0x70_0000_0000` does not fit on macOS 27: the system reserves `0x10_0000_0000` to
`0x70_0000_0000`, and keeps two blocks of about 12 GB at random places in `0x70_0000_0000..2^39` that change at every
launch, so the largest free block there is smaller than 32 GB. Only the low window has to be at its address (the generated
code has it baked in); the alias region's address is whatever `GetInfo` reports, so it can move. When the low window is
taken, or no hole holds the alias region, the process starts again (`LARECOMP_REEXEC`, up to 60 times) for a new layout.
On macOS 26 and earlier the address space is free and the alias region is right behind the low window.

`GetInfo` reports the ASLR region as the one reserved span that starts at `0x70_0000_0000`: both reservations when they
touch, the low window alone otherwise, so that anything the game or the Lumiose module picks inside it is memory we own
(the Lumiose module places private copies of game code at random addresses of it: `MapProcessMemory`).

`tools/test_guest_layout.py` imitates the macOS 27 address space (two 12 GB blocks at random places) and checks the
reservations. Not checked on a real macOS 27: that needs one.
