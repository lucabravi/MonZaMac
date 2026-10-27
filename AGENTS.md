# MonZaMac: guide for coding agents

MonZaMac is a native macOS (Apple Silicon, Metal) port of Pokémon Legends: Z-A built by static recompilation: the
game's ARM64 code is translated to C ahead of time (`tools/gen.py`, `tools/lifter.py`) and the Switch OS and GPU (NVN)
are reimplemented in `runtime/`. Read `README.md` for status and `CONTRIBUTING.md` for the rules.

## Hard rules

- **Never commit, stage, upload or paste Nintendo material:** `extracted/`, `extracted-*/`, `generated*/`, `build/`,
  `.keys/` (prod.keys), fonts, game assets, dumps (`.nsp` / `.xci` / `.nca`), compiled `monzamac` builds. All are in
  `.gitignore`; keep it that way and check `git status` before every commit.
- Never print key material (derived keys, `prod.keys` contents) into logs, issues or PRs. `nstool --showkeys` prints
  derived keys: don't run it where output is shared.
- Don't put personal paths or information in code, comments or commit messages.

## Setup (macOS, Apple Silicon)

```sh
brew install make python@3.12 sdl3 ffmpeg      # use `gmake`: macOS make is too old
python3.12 -m venv tools/venv
tools/venv/bin/pip install capstone==5.0.9 unicorn==2.1.4 lz4==4.4.5
tools/build_nstool.sh                          # clones + builds nstool into tools/nstool/ (git-ignored)
```

Game files come from the user's own dump, with their own `prod.keys` in `.keys/prod.keys`:

```sh
tools/extract_game.sh <base.nsp|base.xci> <update.nsp>  # -> extracted/exefs, extracted/romfs, extracted/romfs.bin
```

Target is **v2.0.2** (+ Mega Dimension DLC). Pass the v2.0.2 update NSP as the second argument so the patch is applied
on top of the base (`nstool --basenca`); the base alone is v1.0.0. `extract_game.sh` refuses to overwrite an existing
`extracted/`: move it away first.

## Build and run

```sh
gmake B=build/za202 GEN=generated-202 gen      # recompile the game code (about 1-2 minutes)
gmake B=build/za202 GEN=generated-202 -j8      # build game library + runtime (first build is slow)
./build/za202/monzamac extracted --play > play.log 2>&1
```

Renderer tests need no game files: `MTL_DEBUG_LAYER=1 gmake B=build/za202 GEN=generated-202 test-metal-renderer`
(`CASE=views|clears|draws|streams|layers|aspects|samplers|types`).

## Layout

- `runtime/`: kernel, loader, `services/` (Switch OS replacement), `hle/`, `ui/`
- `runtime/nvn/`: NVN to Metal backend (`cmdbuf.c`, `renderer.m`, `metal.m`, `maxwell/translate.c` shader translator)
- `tools/`: recompiler, extraction scripts (`build_nstool.sh`, `extract_game.sh`), `za/` game-specific tools

## Working here

- Match the surrounding code's naming, structure and comment density; comments explain why.
- Keep each change focused. A graphics fix isn't verified until seen on screen: say what you tested and what you
  couldn't (a Mac with the user's game files is needed for in-game checks).
- Debug hooks are `LARECOMP_*` environment variables (grep `getenv("LARECOMP_`).
- Never commit to `main` directly: branch from `main` (a worktree is fine) and open a PR to `lucabravi/MonZaMac`,
  from a fork if you can't push there.
