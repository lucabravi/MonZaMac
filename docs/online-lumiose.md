# Online play with Lumiose Online

Status: **experimental, off by default.** Nothing here is reachable from the start screen yet; the pieces land one pull
request at a time on the `lumiose-online` branch. Lumiose Online is a separate service run by its own authors, not by
MonZaMac.

## What Lumiose Online is

- A **Switch mod**, not code of this project: a `subsdk9` NSO module that Atmosphère loads next to the game's `main`
  and `sdk`. On a Switch it patches the game when it starts (branch hooks into itself), talks to a **relay server** over
  UDP through `nn::socket`, and shows other players and a chat in the game.
- It updates itself: it downloads a new `subsdk9` to its SD-card path and the next start runs that one.
- The relay address is configuration, never part of this repository.

## What the runtime has for it

A static recompilation has to translate the mod like the game, including the code the mod writes into `main` and `sdk`
when it starts. This is what the runtime provides:

| Part | What it does |
|---|---|
| `runtime/lumiose_module.c`, `loader.c` | Loads `subsdk9` as a third module at `0x7006200000` (checks its build id), remaps `rtld` and runs its initialization |
| `runtime/lumiose_cpu.h`, `lumiose_rtld.h`, `tools/gen.py` | The entry points and branch checks the module needs; generator changes only apply to this module |
| `runtime/dispatch.c`, `rt.h` | Guest hooks on HLE entry points, with the original function still callable |
| `runtime/kernel.c` | Local session pairs and process handle transfer between the module and the game |
| `runtime/hle/lumiose_net.c` | `nn::nifm` / `nn::socket` as non-blocking UDP, off unless asked for, with the destination pinned to one exact IPv4 endpoint |
| `runtime/nvn/tegra.c`, `objects.c` | Partial 2D block-linear texture uploads, used by the mod's font and icon atlas |
| `tools/lumiose/identity.c`, `runtime/gamelib.c` | Libraries made for a module carry its build id; a library that does not match is refused |

The network is **off** unless `LUMIOSE_TEST_NETWORK=1` and `LUMIOSE_TEST_SERVER=<ipv4>:<port>` are set; only that
endpoint is reachable. Traffic is logged (`lumiose-net` developer log) by destination and size, never by content.

## What is verified, and what is not

- Native and ASan/UBSan tests for the kernel sessions, the HLE hooks, the UDP service and the texture uploads
  (`tools/test_kernel_sessions.py`, `test_lumiose_hle.py`, `test_lumiose_net.py`, `test_lumiose_identity.py`,
  `test_tegra_rect.py`). The HLE test cannot be run under ASan because its fixed guest address range cannot be instrumented.
- On one Mac, with the module of build 1.4.3 prepared by hand: offline play, a real relay handshake, another player
  visible in a two-client test, the mod's own interface. Not verified: chat text entry and delivery, play against
  Windows or Linux peers, every optional feature of this project with the patched library.

## Still to do (separate changes)

- Preparing the patched library on the player's Mac (capture, generation, compilation) and choosing the version to use.
- Fetching the module, with a check of what was downloaded.
- The start screen: one Play online entry, consent, progress and errors; only for game version 2.0.2.
- Packaging, and a statement of what is not our service.

## Risks

1. **Permission for the module and the servers** rests with their authors.
2. **A self-patching module:** the patched library has to be rebuilt for every module version.
3. **Native code from a download:** a new module is new code running on the player's Mac; it needs a deliberate rule.
4. **Compatibility with other platforms** needs the same game and module versions.
5. **This project's optional features** (frame generation, temporal upscaling, smooth distant animation) change timing in
   ways an online game may not tolerate.
