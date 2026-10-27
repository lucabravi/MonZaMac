# MonZaMac

*Pokémon Legends: Z-A on macOS (Apple Silicon, Metal).*

A native macOS port of **Pokémon Legends: Z-A** (Nintendo Switch, v2.0.2 + the Mega Dimension DLC) built by **static
recompilation**: the game's ARM64 code is translated ahead of time into C and compiled for the Mac, and the Switch's
operating system and GPU (NVN) are reimplemented in the runtime. No emulator runs at play time.

> **You need your own copy of the game.** No game files, code, assets or fonts are included in this repository.

## Status

Work in progress. It boots, goes through the intro and reaches Lumiose City.

Looking for the Windows version? It's available at **[PokeZ-ARecomp](https://github.com/Hexveil404/PokeZ-ARecomp)** by
**Hexveil404**.

Working:
- Rendering on Metal: environment, walls, characters (GPU skinning through transform feedback), lighting, GPU-driven
  culling (indirect draws), text, dialogue and UI
- Audio, the game's menus, saves
- Controller and keyboard input

Known issues:
- NPCs can still pop in and out while walking

Bugs and questions: [GitHub issues](https://github.com/lucabravi/MonZaMac/issues), see [CONTRIBUTING.md](CONTRIBUTING.md).

## Building and running

Requirements: macOS on Apple Silicon, Xcode command line tools, GNU Make 4 (`brew install make`, run as `gmake`: the
macOS `make` is too old), SDL3 and FFmpeg (Homebrew).

1. Install the tools: `brew install make python@3.12 sdl3 ffmpeg` (GNU Make 4 runs as `gmake`).
2. Set up the recompiler (Python 3.12):
   `python3.12 -m venv tools/venv && tools/venv/bin/pip install capstone==5.0.9 unicorn==2.1.4 lz4==4.4.5`
3. Get your game files into `extracted/`. Either extract them from your own dumps with the bundled helper, or place
   them yourself (see below).
4. Recompile the game code from your files: `gmake B=build/za202 GEN=generated-202 gen` (a minute or two).
5. Build: `gmake B=build/za202 GEN=generated-202 -j8` (compiles the generated code and the runtime; the first build
   takes a while).
6. Run: `./build/za202/monzamac extracted --play`. The log goes to the terminal; redirect it to a file to keep it.

### Extracting your game files from a dump

The game is v2.0.2 (+ the Mega Dimension DLC). You need, all from your own Switch and copy of the game:

- your `prod.keys` (dump them with Lockpick_RCM), saved as `.keys/prod.keys` (never committed)
- the base game `.nsp` and the **v2.0.2 update `.nsp`** (the base alone is v1.0.0 and won't work)

```sh
tools/build_nstool.sh                                   # once: builds nstool (jakcron/nstool, MIT) into tools/nstool/
tools/extract_game.sh base.nsp update.nsp               # -> extracted/exefs, extracted/romfs, extracted/romfs.bin
```

`extract_game.sh` unpacks both NSPs, applies the update on top of the base, writes `extracted/exefs/` (`main`,
`main.npdm`, `rtld`, `sdk`) and `extracted/romfs/`, and packs `extracted/romfs.bin`. It needs roughly 25 GB of free disk while it runs
and refuses to overwrite an existing `extracted/`. Already have the files extracted another way? Put them in
`extracted/exefs/` and `extracted/romfs/` (+ `romfs.bin`, which the start screen can also build).

Keyboard: WASD move, arrows d-pad, Enter = A, Backspace = B, K = talk, Q / E = L / R. F1 opens the in-game menu.

## Layout

- `runtime/` - the runtime: kernel, HLE services, loader, UI
- `runtime/nvn/` - the NVN-to-Metal backend: `maxwell/translate.c` (Maxwell shader to MSL), `renderer.m` (command
  executor), `metal.m` (window and presentation)
- `tools/` - the recompiler (`gen.py`, `lifter.py`) and game-specific tooling (`tools/za/`)

Debug aids: `LARECOMP_*` environment variables (see `runtime/nvn/renderer.m`); `touch build/dumpframe` captures a frame.

## Renderer checks

On macOS, `MTL_DEBUG_LAYER=1 gmake B=build/za202 GEN=generated-202 test-metal-renderer` runs offscreen tests against
the real Metal backend without loading game files. Use `CASE=views`, `clears`, `draws`, `streams`, `layers`, `aspects`, `samplers`
or `types` to select a group. Native sampler reduction and LOD-bias cases require macOS 26 and SDK 26; older builds
report those cases as skipped.

For a running development build, `trace 2` in `build/dbgcmd` logs draw and compute metadata for two presents
without dumping textures. The window is capped at 120 presents; draw records include the frame and indirect-buffer offset.
The offset describes GPU-backed indirect arguments; CPU-decoded indirect draws share the direct-draw sentinel.

## Credits and license

MonZaMac is a fork of **[PokeZ-ARecomp](https://github.com/Hexveil404/PokeZ-ARecomp)** (branch `pokemon-za`) by
**Hexveil404**, the Pokémon Legends: Z-A port of **[LAS Recomp](https://github.com/peiikai/LASRecomp)** by **Peiikai**,
whose recompiler, runtime and NVN/Maxwell shader work it builds on (made for *The Legend of Zelda: Link's Awakening*).
Contributors and third-party components are listed in [CREDITS.md](CREDITS.md).

The code is under the [MIT License](LICENSE) (LAS Recomp © Peiikai; the Z-A port and MonZaMac's additions under the same license). This is a fan
project, not affiliated with, endorsed by or sponsored by Nintendo, Game Freak or The Pokémon Company.
