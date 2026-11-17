# Online play with Lumiose Online

Status: **new, optional, in a separate online edition** (built with `LUMIOSE_ONLINE=1`; the standard app has none of it).
Lumiose Online is a separate service run by its own authors, not by MonZaMac. For the user's view see the README.

## What Lumiose Online is

- A **Switch mod**, not code of this project: a `subsdk9` NSO module that Atmosphère loads next to the game's `main`
  and `sdk`. On a Switch it patches the game when it starts (branch hooks into itself), talks to a **relay server** over
  UDP through `nn::socket`, and shows other players and a chat in the game.
- On a Switch, the mod updates itself by writing a signed `subsdk9` from the relay to the SD card. MonZaMac does
  not use modules from the save's `sdcard` folder. **Play online** uses the module published on the Lumiose Online site.
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

Nothing uses the network unless a command is run on purpose: `fetch.py` downloads builds, and `setup_online.py` checks for updates (the start screen asks for consent before running it).

| Tool | What it does |
|---|---|
| `fetch.py` | Downloads the newest live module from the fixed link the Lumiose Online team keeps for it, and keeps it only if it matches the SHA-256 they publish next to it (https only, size limit, NSO header), under its own hash in `build/lumiose-modules/` |
| `prepare.py` | From the module and the 2.0.2 game: starts the game hidden and offline to capture what the module patches, generates and compiles the module and the patched `main`/`sdk` libraries (unchanged objects are reused), and writes `ready.json` with the hash of every output |
| `activate.py` | Lists prepared versions, makes one the active one after verifying it (optionally after starting it hidden to see that it comes up), goes back to the previous one, sets or clears the relay endpoint (the default is the team's `lumioseonline.site:27777`), prints the command that starts it |
| `setup_online.py` | Verifies cached module bytes against the published digest or downloads a matching module, then prepares, checks and activates it as one job (`PROGRESS` lines) for the start screen |
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
version with `tools/lumiose/setup_online.py` (the button fills as it goes; `runtime/online_prep.c` follows its
`PROGRESS` lines). Every press checks the published SHA-256 of the newest module. An active version can be reused
if its module matches; otherwise the helper prepares the published module. If the published checksum is unavailable,
online play does not start. The launcher uses the exact prepared version returned by that check. In the app, an
install whose game code build was not kept yet (made before the online edition) builds the game code first, then goes
on. The relay is the Lumiose Online
team's (`lumioseonline.site:27777`, the machine their own launcher uses; `activate.py set-server` points elsewhere): the name is looked
up when the version is read and the runtime is given only the resulting IPv4 address. When the name cannot be found the column says
so and nothing is started. The online app runs these tools through its bundled helper (`lasgen online <tool>`); a build without them says "not available here". A version prepared before an app update that changed the game code is prepared again on the next press, since the runtime refuses its library.
`LARECOMP_ONLINE_STATE_TEST=ready|needs|setup|error|noserver (server not found)|off` shows each state without running anything.

RomFS mod layers are also disabled during online play. This protects the launcher's mod loading paths. It does not
verify saves or game files, or detect tampering by a modified client.

What the check covers: the module file (`subsdk9`) the start screen prepares and starts from must be byte for byte the one
the team publishes, so a module put in the save's `sdcard` folder or in the downloads folder is never used. The libraries
prepared from it (`lumiose.dylib`, `lasgame.dylib`) are built on the player's own Mac and are not signed, so someone who
changes them, or who starts the game by hand with the `LUMIOSE_TEST_*` variables, is not stopped here. That check belongs to
the relay. The check needs the team's site every time: when it cannot be reached, online play does not start (an
unchecked version could be swapped by blocking the site), and the screen says to try again. Back at the start screen,
**Play online** starts in the same process again only when the checked version is the one already running; a different
one starts a new process.

The mod's own interface reads the Switch touch screen (`nn::hid::GetTouchScreenStates`, which the game does not import):
the left mouse button held is one finger where the cursor is, in the touch screen's 1280x720 over the game's picture
(`runtime/hle/input.c`). When the left button also turns the camera (Mouse camera "Left button" / "Any button"), a tap is
a touch and a drag the camera. The cursor is shown in game unless the mouse is turning the camera, and hides after 5 seconds without movement or
click (Settings > Controls > Hide the idle cursor: never, 5, 10, 30 or 60 seconds). Offline the cursor stays hidden in game.

Online play also switches off the debug, test and experimental `LARECOMP_*` variables (scripted input, route replay, warps and
the like: only the ten supported ones in `docs/environment.md` stay, `runtime/online_env.c`), and **Play online** stays off
while the start screen's check of the game data (`runtime/gamecheck.c`) finds packs that differ from the original 2.0.2 or
cannot tell. That check runs on the player's own Mac too (its result is kept in `.packcheck`), so it stops mistakes and casual
changes, not someone who sets out to avoid it; the relay is where that belongs.

Online and offline saves are two kinds that never convert on their own (the mod checks a save for anything done to it outside online play). The first **Play online** asks which save is the online one: a new online game (recommended), or one of the player's saves, made online on that choice and a warning (`runtime/ui/launcher.mm`). An online save carries a hidden `.online` file in its folder, next to the game's own `save_0` (`runtime/saves.c`): the start screen's CONTINUE and the Saves page never start it offline, an offline save is never started with the module, an online save can't be copied, and the game itself refuses to start a save of the other kind (`runtime/services/fs.c`; test runs with `LARECOMP_SAVE_DIR` are exempt). The file can be deleted by someone who sets out to, so this stops mistakes, not people; the relay is where that belongs. Not handled yet: an exported online save comes back from an import as an offline one, and a copy of an offline save can't become an online one on its own.

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
