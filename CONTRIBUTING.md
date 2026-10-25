# Contributing to MonZaMac

Bug reports, testing on other Macs and code contributions are welcome. This project is developed mostly with AI
assistance; code written by hand or with AI is equally welcome as long as it works and is tested.

## The one hard rule: no Nintendo files

Nothing owned by Nintendo may ever be committed or attached to an issue or pull request:

- no copies of the game in any form
- no extracted game files (`extracted/`), no generated code (`generated*/`), no fonts (`.bfttf` / Switch `.ttf`)
- no game assets of any kind: textures, models, music, text, level files - also not "just one file for testing"
- no keys (`.keys/`) and no compiled builds: a built `monzamac` contains the recompiled game code

Pull requests that include Nintendo files can't be merged. Screenshots and short clips of the game are fine in bug
reports.

## Reporting bugs

Open a [GitHub issue](https://github.com/lucabravi/MonZaMac/issues) with:

- your Mac (chip, RAM) and macOS version
- what you did, what happened, and what you expected
- a screenshot or short clip if it's visual (say where in the game you are)
- the log: run the game from a terminal and redirect the output to a file
  (`./build/za202/monzamac extracted --play > play.log 2>&1`)

For graphics bugs, a frame capture helps a lot: `touch build/dumpframe` while the game shows the problem, then attach
the log lines (not the PNG dumps if they contain game art you are unsure about).

## Building

See the README. In short: put your own game files in `extracted/`, then
`gmake B=build/za202 GEN=generated-202 -j8` (GNU Make 4: `brew install make`).

## Project layout

- `tools/gen.py`, `tools/lifter.py` - the recompiler: translates the game's ARM64 code into C (`generated*/`, never
  committed). `tools/za/` holds game-specific tooling.
- `runtime/` - the host side: `kernel.c`, `loader.c`, `services/` (the Switch OS replacement), `hle/`, `ui/`
- `runtime/nvn/` - the graphics layer: command recording (`cmdbuf.c`), the Metal backend (`renderer.m`, `metal.m`) and
  the Maxwell shader translator (`maxwell/translate.c`)

## Testing your change

- Build cleanly (`gmake B=build/za202 GEN=generated-202 -j8`).
- Renderer changes: `MTL_DEBUG_LAYER=1 gmake B=build/za202 GEN=generated-202 test-metal-renderer` runs offscreen tests
  against the real Metal backend without game files (`CASE=views`, `clears`, `draws`, ... see the README).
- Test in the game and look at the result: a graphics fix isn't verified until you've seen it on screen. Say what you
  tested and what you could not.
- Debug hooks are `LARECOMP_*` environment variables, documented where they are defined (grep `getenv("LARECOMP_`).

## Code style

- Match the surrounding code: its naming, structure and comment density. Comments explain *why*, not what the next
  line does.
- Don't include personal paths or information in code, comments or commit messages.

## Pull requests

- Branch from `main`, keep each pull request focused on one change, and describe what changed, why and how you tested it.

## License

By contributing, you agree that your contributions are licensed under the project's [MIT License](LICENSE).
