# Development

Everything beyond playing the game: building from source, packaging, the game-file setup in detail, the source layout
and the developer tools. For playing, see the [README](../README.md).

## Building from source

Requirements: macOS on Apple Silicon, Xcode command line tools, GNU Make 4 (`brew install make`, run as `gmake`: the
macOS `make` is too old), SDL3 and FFmpeg (Homebrew).

### Build and run

1. Install the tools: `brew install make python@3.12 sdl3 ffmpeg` (GNU Make 4 runs as `gmake`).
2. Set up the recompiler (Python 3.12):
   `python3.12 -m venv tools/venv && tools/venv/bin/pip install capstone==5.0.9 unicorn==2.1.4 lz4==4.4.5`
3. Get your game files into `extracted/`: extract them from your own dumps with the bundled helper (see
   [Extracting your game files from a dump](#extracting-your-game-files-from-a-dump)), or place them yourself.
4. Recompile the game code from your files: `gmake B=build/za202 GEN=generated-202 gen` (a minute or two).
5. Build: `gmake B=build/za202 GEN=generated-202 -j8` (compiles the generated code and the runtime; the first build
   takes a while).
6. Run: `./build/za202/monzamac extracted --play`. The log goes to the terminal; redirect it to a file to keep it.

### Packaging the app and the dmg

`gmake deps` (once: SDL3, FFmpeg and Python built from pinned sources for macOS 15) then `gmake dmg` build
`build/MonZaMac.app` and `build/dist/MonZaMac-<version>-macOS.dmg`, the file the releases carry. The version comes from
`LARECOMP_VERSION` in `runtime/ui/launcher.mm`; the update check on the start screen reads the GitHub **releases**, not
the tags, so a release needs its dmg attached. The app holds no game files or game code.



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




## Layout

- `runtime/` - the runtime: kernel, HLE services, loader, UI
- `runtime/nvn/` - the NVN-to-Metal backend: `maxwell/translate.c` (Maxwell shader to MSL), `renderer.m` (command
  executor), `metal.m` (window and presentation)
- `tools/` - the recompiler (`gen.py`, `lifter.py`) and game-specific tooling (`tools/za/`)

Z-A v2.0.2 uses larger NPC appearance budgets (64 active / 64 selection candidates) to reduce characters disappearing
while walking through crowded areas. Launch with `LARECOMP_NPC_CAPACITY_FIX=0` to retain the original 20/25 budgets.
The change keeps the game's distance and priority rules; higher population budgets can increase CPU/GPU and memory use.

Debug aids: `LARECOMP_*` environment variables (see `runtime/nvn/renderer.m`); `touch build/dumpframe` captures a frame.

Developer → Experimental → **Uncapped FPS (benchmark)** removes presentation pacing and Metal display sync.
It is off by default and overrides the normal frame-rate selection while enabled. The FPS overlay marks benchmark
mode because gameplay, animations and timers can run too fast. Turn it off for normal play. For scripted runs,
`LARECOMP_UNCAPPED_FPS=1` forces it on and `=0` forces it off; keep resolution/settings fixed when comparing builds.



## Renderer checks

Shaders whose forward jump tables and reconvergence can be proven are translated to structured flow. It is on by
default; `LARECOMP_STRUCTURED_FLOW=0` retains the existing dispatcher.
See [measurements and limitations](docs/performance-brx.md). The focused GPU case is `CASE=structured-brx`.

On macOS, `MTL_DEBUG_LAYER=1 gmake B=build/za202 GEN=generated-202 test-metal-renderer` runs offscreen tests against
the real Metal backend without loading game files. Use `CASE=views`, `clears`, `draws`, `streams`, `layers`, `aspects`, `samplers`
or `types` to select a group. Native sampler reduction and LOD-bias cases require macOS 26 and SDK 26; older builds
report those cases as skipped.

A transform-feedback buffer barrier reuses a render pass after GPU skinning. It is on by
default; turn it off in the Developer tab (Cmd+Shift+D, "Keep passes open after skinning", applies at once), or launch with
`LARECOMP_XFB_END_BARRIER=0` (forces the original behavior and overrides the setting; `=1` forces it on). See
[measurements and limitations](docs/performance-xfb.md). The asset-free regression is `CASE=xfb-barrier`.

### Local GPU profiling

`gpupass 30` in `build/dbgcmd` times each render pass of 30 frames with GPU timestamps (no Xcode, no capture): after the
last frame the log lists the 25 slowest passes by their ordinal in the frame, with size, attachments and draws
(`[gpupass] #12 2.31 ms (idle 0.40) 2880x1620 colors=3 depth=1 draws=412`). The spans of neighbouring passes overlap on the GPU, so
each pass is charged the time between the previous pass's end and its own, so they add up to the frame's GPU span. The
`idle` part is the time before the pass started with no earlier pass still running: the GPU waiting for work. Because
`gpupass` waits for the GPU at each frame end (no CPU/GPU overlap), that part is larger than in normal play; compare a
run with uncapped FPS before reading it as a CPU bottleneck. It waits for the GPU at each frame end: run it on its own,
not together with a benchmark.

In a running development build, write `gpuprofile 30` to `build/dbgcmd` to collect 30 complete presented frames.
The `[gpu-profile]` lines count guest draws, clear requests, compute dispatches, feedback copies, and the reasons
actual render encoders and command buffers ended. Empty close/submit requests do not count. This is off until
requested; it changes no render state and does not wait for the GPU. See [GPU measurements](docs/performance-gpu.md)
for scope, results and limitations.

**Frame times of a scene.** `LARECOMP_PERF_LOG=60` logs a `[perf] frame N cpu X gpu Y` line every 60 presented frames:
the smoothed CPU submit time and GPU busy time per frame, the two numbers of the F3 overlay (Developer tab, "Frame
times in F3"). `tools/perf_scene.py` runs the game from a copy of a save with the scripted title input of
`tools/perf_sweep.py`, lets it settle and averages those lines over a window (30 s by default), once or several times:

```sh
tools/perf_scene.py --save saves/<slot> --runs 2     # internal resolution and the options come from larecomp.ini
```

To compare two builds, run them one after the other, alternating, with the window in front and the Mac idle, and keep
a run of the same build at the end to see the noise.

To capture one complete frame, launch with Metal capture support, then request the capture from another terminal:

```sh
MTL_CAPTURE_ENABLED=1 tools/hang_sample.sh
printf 'gpucapture\n' > build/dbgcmd
```

The command arms at a present boundary and captures the following frame, including uploads, post-processing and
presentation. A `[gpucapture] completed` line gives the unique `.gputrace` path under `build/gputrace/` in the runtime
data directory. Capture drains the queue at its boundaries, so capture-frame FPS is not a benchmark. Renderer
reset cancels a pending or owned capture; another tool's active capture is left alone.

Keep `.gputrace` documents local: they contain game buffers, textures and shaders, and can occupy tens of gigabytes.
Do not commit or upload them, or derived shader sources. Report numeric measurements and descriptions instead.
Xcode replay and **Profile after replay** can consume much more memory than the trace's disk size. Full-game
counter profiling exceeded the available memory on the test Mac; prefer the lightweight histogram and HUD first.
If inspecting a capture, supervise it and use an external process deadline; the one-frame command limits recorded
frames, not Apple's capture finalization or Xcode analysis time.
For live HUD measurements, use a separate launch with `MTL_HUD_ENABLED=1` and, optionally,
`MTL_HUD_ENCODER_TIMING_ENABLED=1`; use a HUD-free process for capture. A combined HUD/capture run failed inside
Apple's capture writer; a later HUD-free capture in a different scene completed, so the cause is not established.

For a running development build, `trace 2` in `build/dbgcmd` logs draw and compute metadata for two presents
without dumping textures. The window is capped at 120 presents; draw records include the frame and indirect-buffer offset.
The offset describes GPU-backed indirect arguments; CPU-decoded indirect draws share the direct-draw sentinel. The same
window also logs one `[cs-out]` line per compute dispatch (hashes of its storage and uniform buffers, its textures);
`tools/cs_diff.py a.log b.log` compares two captures of the same still scene (for example at 1x and 1.5x) and lists the
dispatches whose output differs, and with `LARECOMP_CS_DUMP=1` `tools/cs_dump_diff.py play.log build/csdump` shows which
words changed. Each traced dispatch is waited for, so the game runs slowly while a window is open.



### When Metal's compiler rejects a translated shader

A pipeline that fails with `XPC_ERROR_CONNECTION_INTERRUPTED` is the Metal compiler service crashing, not a transport
problem: the log line names the program (`[metal] pipeline failed (vs ... fs ...)`), and macOS keeps the stack and the
reason in `~/Library/Logs/DiagnosticReports/MTLCompilerService-*.ips` (the JSON `termination.reasons` field, e.g.
`cannot select: ...`; the frames show the compiler pass). To find the construct that triggers it, take the program's MSL
(`LARECOMP_SAVE_MSL=1`) and compile edited copies with `LARECOMP_FS_OVERRIDE_HASH=<fnv64 of the saved MSL>:<file>`
(the hash is of the annotated text, so keep `LARECOMP_SAVE_MSL=1` set when overriding): remove one construct per copy
until the failure goes away. Known case: the facing flag converted to float inside the structured flow of a program
without BRX (the translator keeps the dispatcher for those).

## First-run setup in the packaged app

The complete app bundle includes its extraction tools, game-code generator and compiler. No Homebrew, Python or
compiler installation is needed by the player. Open **SET UP GAME FILES**, confirm that you own an original copy and have
permission to use the selected files, then choose your base-game **NSP/XCI**, the **v2.0.2 update NSP** and your
**prod.keys**. Setup checks the files and free space, applies the update and builds the game locally. Allow at least
25 GB of free space; the exact requirement can be higher. Compressed NSZ/XCZ packages are not supported; unpack
ZIP/7z archives before selecting the NSP/XCI inside them.

Keys are read locally from the selected file, not copied into app storage or uploaded. Your source dumps are left
untouched. Files are prepared in scratch storage and installed only when all steps succeed; an existing installation
must be removed with **Delete game files** before importing a new copy. Saves and settings are kept. You can also
select **Extracted folder** to import your own `exefs`/`romfs` folders as before.

The ownership declaration records the user's confirmation for setup; it does not replace applicable law or grant
rights to Nintendo's content. Building the app from source still needs the developer tools in [Building from source](#building-from-source).



## Near-term follow-up: application updater

The community shader catalog is updated independently of the app executable.
A proper application updater is the next separate distribution task: evaluate
an established macOS updater such as Sparkle before considering a custom
installer. It needs authenticated/signed releases, correct version/channel
handling, recoverable installation and compatibility with the game's generated
library. Updates must preserve extracted game files, keys, saves, settings and
local recipe contributions, and reconcile bundled/downloaded catalog versions. Any required library rebuild uses the player's own
files; no game library is distributed. This is planned work, not an implemented
self-update feature. The existing launcher currently checks for releases and
opens the download page.
