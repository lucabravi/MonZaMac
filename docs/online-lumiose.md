# Online play with Lumiose Online

Status: **new, optional, in a separate online edition** (built with `LUMIOSE_ONLINE=1`; the standard app has none of it).
Lumiose Online is a separate service run by its own authors, not by MonZaMac. For the user's view see the README.

## What Lumiose Online is

- A **Switch mod**, not code of this project: a `subsdk9` NSO module that Atmosphère loads next to the game's `main`
  and `sdk`. On a Switch it patches the game when it starts (branch hooks into itself), talks to a **relay server** over
  UDP through `nn::socket`, and shows other players and a chat in the game.
- It updates itself: it gets a signed `subsdk9` from the relay and installs it on the SD card; on a Switch the next start runs that one. Here the SD card is the save's `sdcard` folder, and `setup_online.py` prepares that file on the next **Play online**, before looking at the site (which can be behind the relay). A module that is not newer than the active version, or is not the PC build (platform 2), is not activated.
- The relay is the team's server, `lumioseonline.site:27777` (the machine behind their site, also the one their own launcher uses). It is the default here and can be pointed elsewhere; the runtime only ever reaches the one IPv4 address it is given.

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

## Preparing a version (`tools/lumiose/`)

Nothing uses the network unless a command is run on purpose: only `fetch.py`, and `setup_online.py` when it has no module (the start screen asks for consent before running it).

| Tool | What it does |
|---|---|
| `fetch.py` | Downloads the newest live module from the fixed link the Lumiose Online team keeps for it, and keeps it only if it matches the SHA-256 they publish next to it (https only, size limit, NSO header), under its own hash in `build/lumiose-modules/` |
| `prepare.py` | From the module and the 2.0.2 game: starts the game hidden and offline to capture what the module patches, generates and compiles the module and the patched `main`/`sdk` libraries (unchanged objects are reused), and writes `ready.json` with the hash of every output |
| `activate.py` | Lists prepared versions, makes one the active one after verifying it (optionally after starting it hidden to see that it comes up), goes back to the previous one, sets or clears the relay endpoint (the default is the team's `lumioseonline.site:27777`), prints the command that starts it |
| `setup_online.py` | Does find (or download, when there is none), prepare, check and activate as one job with one progress (`PROGRESS` / `STATUS` lines) for a screen |
| `versions.py` | Reads the module's switch tables from its own code (their targets are entry points for the generator). There is no list of known builds |

In the online app the start screen's game code build is kept (`.gamebuild` in the game folder: generated C, objects,
link list, about 1.3 GB), and the tools read it with `--cache`, the bundled headers with `--include` and the bundled
compiler with `--cc "<zig> cc"`; downloads go through `/usr/bin/curl` when Python has no TLS (the bundled helper).

A prepared version never becomes active unless its files match their manifest and it started; the state file is replaced
only as a whole, so a failure leaves the previous choice as it was.

## The start screen (built with `LUMIOSE_ONLINE=1`)

A second column, **Lumiose Online**, beside the offline one. **Play online** is available only when the game files are
there and are the 2.0.2 build (otherwise the column says what is missing, and the runtime itself refuses the module for any
other build). The first press asks for consent (the game data goes to Lumiose Online, a separate service), prepares the
version with `tools/lumiose/setup_online.py` (the button fills as it goes; `runtime/online_prep.c` follows its `PROGRESS` /
`STATUS` lines) and then starts the game again with the module: offline and online are a restart apart. Every later press first
checks the published SHA-256 of the newest module: the same one starts at once, a newer one is downloaded and prepared
first, and when the check cannot be made the active version starts. In the app, an install whose game code build was not
kept yet (made before the online edition) builds the game code first, then goes on. The relay is the Lumiose Online
team's (`lumioseonline.site:27777`, the machine their own launcher uses; `activate.py set-server` points elsewhere): the name is looked
up when the version is read and the runtime is given only the resulting IPv4 address. When the name cannot be found the column says
so and nothing is started. The online app runs these tools through its bundled helper (`lasgen online <tool>`); a build without them says "not available here". A version prepared before an app update that changed the game code is prepared again on the next press, since the runtime refuses its library.
`LARECOMP_ONLINE_STATE_TEST=ready|needs|setup|error|noserver (server not found)|off` shows each state without running anything.

The mod's own interface reads the Switch touch screen (`nn::hid::GetTouchScreenStates`, which the game does not import):
the left mouse button held is one finger where the cursor is, in the touch screen's 1280x720 over the game's picture
(`runtime/hle/input.c`). When the left button also turns the camera (Mouse camera "Left button" / "Any button"), a tap is
a touch and a drag the camera. The cursor is shown in game unless the mouse is turning the camera.

## What is verified, and what is not

- Native and ASan/UBSan tests for the kernel sessions, the HLE hooks, the UDP service and the texture uploads
  (`tools/test_kernel_sessions.py`, `test_lumiose_hle.py`, `test_lumiose_net.py`, `test_lumiose_identity.py`,
  `test_tegra_rect.py`). The HLE test cannot be run under ASan because its fixed guest address range cannot be instrumented.
- On one Mac, with the module of build 1.4.3 prepared by hand: offline play, a real relay handshake, another player
  visible in a two-client test, the mod's own interface. Not verified: chat text entry and delivery, play against
  Windows or Linux peers, every optional feature of this project with the patched library.

## Still to do

- Chat text entry and delivery, play against Windows or Linux players, and every optional feature of this project with
  the patched library are not verified.
- A new module build is prepared without a MonZaMac release. One that works differently (no tables found, or it fails the start-up check) is not activated, and the previous version stays; that case needs a compatibility update.
- The packaged online app was built and its pieces tried one by one; a complete first run on a clean Mac is still to be seen.

## Risks

1. **Permission for the module and the servers** rests with their authors.
2. **A self-patching module:** the patched library has to be rebuilt for every module version.
3. **Native code from a download:** a new module is new code running on the player's Mac. The rule: https from the team's fixed link and a match with the SHA-256 they publish; any build is accepted, with no list of ours in between.
4. **Compatibility with other platforms** needs the same game and module versions.
5. **This project's optional features** (frame generation, temporal upscaling, smooth distant animation) change timing in
   ways an online game may not tolerate.
