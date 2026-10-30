# Changelog

Versions follow `v<major>.<minor>.<patch>` (0.x until a stable 1.0). The version shows on the start screen and in
the in-game menu; the start screen also offers a newer release from GitHub when there is one.

## Unreleased

### Start screen and saves
- **The save card shows the trainer's data:** name, trainer ID, play time, money and the team, read from the save
  itself (read only), laid out in two columns. The SAVES list shows the same for every save.
- **Each save can open its team:** a button on the right of the card (or Y / I) lists every Pokémon with its ball
  (gold for a shiny), name and level. Names in another script use a macOS system font when the launcher starts; the
  Pokédex number stands in for a character that font lacks.

### Controls
- **Mouse settings** (Settings > Controls, a Mouse section): the camera turns with the mouse while a button is held (right,
  left, middle or any), always (cursor held in the window), or not at all; a two-finger trackpad drag turns it too; each
  axis can be inverted; the speed is adjustable (100% is the default). The right stick snap (0 = off) sits with the d-pad.

## 0.1.3

### Performance
- **Frame rate: one 60 fps choice.** Settings > Video has 30 fps and 60 fps; the old "steady speed" option is retired
  (a saved `fps60_steady` is ignored). `dynamic 60 fps` now keeps the world at a steady speed on its own.
- **Guest compare and branch fusion:** a conservative fusion of compare and branch instructions in the generated code
  (`tools/flagfuse.py`, with its tests). Behaviour is unchanged; the gain is in the frame time, measured on one Mac.

### Start screen and saves
- **The save card and the SAVES list show no file size:** name and last-modified date tell saves apart.
- **Hidden files** such as `.DS_Store` in `save/` are no longer counted as progress.

### Station
- **NPC pop-ins at Lumiose station are fixed:** the game's appearance budgets for characters are raised (64 active
  instead of 20; `LARECOMP_NPC_CAPACITY_FIX=0` restores the originals).

### Developer
- **Uncapped frame rate benchmark** (Developer tab): turns off the frame limit to measure the GPU and CPU on their own.
  Off by default.

## 0.1.2

About 60 fps in the open world on an Apple M5 at 2880x1620 (1.5x), up from about 41 on the same Mac and scene, and a new
start screen with save slots.

### Performance
- **Structured shader flow (on by default):** a shader whose only computed jumps are bounded forward jump tables now
  runs as plain conditionals and small switches instead of a `switch (pc)` loop (about 20% less measured GPU time for
  the whole frame in one test, 48 to 60 fps at 1.5x). Anything it cannot prove falls back to the old output.
  `LARECOMP_STRUCTURED_FLOW=0` turns it off.
- **Faster shaders with jump tables (on by default):** a fragment shader with a computed jump (BRX) got a label on every
  instruction, which stopped the Metal compiler from optimising it (the lighting pass went from 11.6 to 6.2 ms; 41 to 54
  fps at 1.5x in one test). Now only the starts of code blocks are labels. `LARECOMP_BRX_ALL_LABELS=1` restores the old
  output.
- **Fewer render passes after GPU skinning (on by default):** the pass used to end after each transform-feedback stage;
  it now stays open with a Metal buffer barrier (about 1 ms less GPU time a frame in the tested scenes: 38 to 42 fps at
  1.5x in one test). Developer tab "Keep passes open after skinning" turns it off at once;
  `LARECOMP_XFB_END_BARRIER=0` too.
- **Clears as load actions:** a clear the game issues at the start of a pass now clears the attachment as the pass
  begins instead of loading it and drawing over it (less GPU bandwidth; `LARECOMP_CLEAR_DRAWS=1` goes back).
- **Dynamic resolution follows the GPU better:** it settled at 70% and then 85% where 100% held 60 fps. The GPU time it
  reads tops out at the frame period (a GPU busy all the time that still makes 60 fps reads about 16 ms), so it now lowers
  when frames are missed and raises while the busy time is under 16.3 ms.

### Start screen and saves
- **New start screen, with save slots:** the logo and name on top, a card with the most recent save, and CONTINUE / NEW
  GAME / SAVES / SETTINGS / QUIT under it, as in the Pokémon games. CONTINUE starts the most recent save; NEW GAME asks
  for a name and starts a fresh one; SAVES lists them all, in the order they were made, to pick one, copy, rename or
  delete. Your existing save is the first slot ("Main save", you can rename it), untouched; extra saves live in `saves/`
  next to `save/`. The app opens on it (`--play` skips it and plays the most recent save).
- **No more aspect ratio question on the first PLAY:** the saved aspect ratio is used (authentic 16:9 until you change it
  in Settings).
- **New look for the menus:** deep blue panels with a cyan accent instead of green and gold (start screen, Settings,
  in-game menu); the Settings window is smaller, with smaller type and the version in its header.
- **Fix:** a hidden file such as `.DS_Store` in `save/` (Finder makes one when you open the folder) made it count as the
  most recent save, so CONTINUE started an empty game. Hidden files are ignored now.

### Settings
- **Defaults for new players:** fullscreen, dynamic resolution, 60 fps, SMAA, authentic 16:9 and sharper textures
  (anisotropic filtering) are on from the first start. An existing `larecomp.ini` keeps its own settings.
- **Settings before the game starts:** the Video tab of the start screen's Settings now shows the game's own options
  (game mode, frame rate, FXAA, depth of field, bloom, wider view, sharper textures, 4K shadows, game dynamic
  resolution), which only appeared once the game was running.

### Tools
- `gpupass N` (in `build/dbgcmd`): GPU time of each render pass over N frames, no Xcode needed (developer tool).
- Developer GPU profiling: opt-in, one-frame Metal captures and per-frame pass/submission break histograms.

## 0.1.1

### Performance
- **CPU/GPU overlap (on by default; Developer > Experimental to turn it off):** the game's frame fence is waited
  one frame late, so the CPU prepares the next frame while the GPU draws the current one instead of taking turns
  (about 49 to 58 fps standing still, 53 to 59 in motion on one Mac). `LARECOMP_GPU_OVERLAP=0` also turns it off.
- **Uniform buffer snapshots are reused when nothing changed:** the renderer copied about 44 MiB of uniforms a frame
  and now about 13 MiB, compared byte for byte (about 11% more fps in the plaza scene on one Mac;
  `LARECOMP_NO_UNIFORM_CACHE=1` goes back to copying).

### Settings
- **Developer tab** (Cmd+Shift+D, or `developer = 1` in `larecomp.ini`): "Frame times in F3" adds the CPU time to
  submit a frame and the GPU busy time to the F3 overlay, "GPU timing log" writes the GPU time per present to the log,
  and the experimental CPU/GPU overlap switch is there.
- **Wait for shaders** (Display tab): a shader or pipeline the game needs for the first time is compiled on the spot and
  the game waits (a short stutter, nothing missing from the picture); off, it compiles in the background and the
  objects that need it are left out until it is ready.

### Graphics
- **No more objects popping in and out above 1x (Metal):** the game's culling tests objects against the scene depth's
  mip chain with a min / max sampler; at a higher internal resolution those mips cover less of the screen than the game
  expects, so visible objects were culled. Those reads now go up a level by the scale (`LARECOMP_HIZ_LOD=0`: off).
- **"Sharper textures" no longer brings the popping back:** its LOD bias (-1) and anisotropy applied to that same
  min / max sampler, which then looked a level finer than the game asks for. Reduction samplers now ignore both.
- **Smoother higher internal resolutions:** fixes the jagged character and scenery edges at 1.5x and higher, caused by
  integer screen-space texture reads losing their subpixel positions.
- **Texture size queries at higher internal resolutions:** a shader asking a scaled texture for the size of a mip level
  now gets the guest's size (the base halved per level) instead of the allocation's size divided by the scale, which
  was off by one at some levels (1.5x: 17 rows where the game has 16).
- **Textures a shader writes as an image stay at the game's size:** SUST / SURED store at the game's pixel coordinates,
  so such a texture can't be rendered at a scaled resolution (none seen in Z-A so far; `[scale] image-bound texture
  back to the guest size` in the log names one; `LARECOMP_IMAGE_SCALE=1` keeps the old behaviour).

### Tools
- `trace n` (in `build/dbgcmd`) also logs one `[cs-out]` line per compute dispatch: hashes of its storage and uniform
  buffers and its textures (guest size, `*` scaled, `i` image). `tools/cs_diff.py` compares two such logs (same scene,
  two internal resolutions) and lists the dispatches whose output depends on the resolution; with
  `LARECOMP_CS_DUMP=1` the buffers are written to `build/csdump` and `tools/cs_dump_diff.py` shows which words differ.
- The Developer tab's GPU timing log writes two lines per frame instead of one per command buffer (about 140 a
  frame); `LARECOMP_GPU_TIMING_TRACE=1` brings the per-buffer lines back.

### Logs
- A cube slot holding a 2D texture is no longer reported as a type mismatch (it says what it is), and a pipeline left
  out of the archive says what it is made of.

### Notes
- The first start after updating recompiles some shaders (their Metal source changed) and the pipeline archive
  (`cache/pipelines.bin`) keeps the old entries; deleting the file is safe, it is rebuilt.

## 0.1.0 - first tagged release

MonZaMac is the native macOS (Apple Silicon, Metal) port of Pokémon Legends: Z-A. This is the first numbered
version: everything below is new since the project began, grouped by what you notice.

### Setup
- **Guided first-run setup:** choose your own base game (NSP/XCI), the v2.0.2 update (NSP) and `prod.keys`; the app
  extracts, applies the update and compiles the game on your Mac. It bundles its extractor (nstool, with a path-safety
  patch), the game-code generator and the compiler, installs only when every step succeeded, and keeps your saves
  and settings. An ownership declaration gates the setup. Importing an extracted `exefs`/`romfs` folder still works.
- New app icon; the version on the start screen (and the update check, from GitHub releases).

### Graphics and display
- **Z-A options** (Display tab): depth of field, the game's FXAA, bloom, a wider view, "Sharper textures" (8x
  anisotropic filtering, and a LOD bias on macOS 26 or later), 4K shadows, and widescreen with the original or an
  unlocked aspect ratio.
- **Internal resolution:** Match display, 25-75%, 1x-4x, **Dynamic** and **Dynamic 1.5x** (1.5x while the GPU holds
  the frame rate, lower when it can't). The controller measures the GPU's real busy time, follows the game's frame
  rate (no more collapse to 50% at 30 fps), climbs back quickly and restarts when you change mode.
- SMAA and MetalFX upscaling; defaults: original 16:9, 1x, SMAA.
- **F3** shows the render resolution, the dynamic share, frame and GPU time and the present interval.
- The game's own dynamic resolution is off by default (a stall, such as a minimised window, used to blur the picture
  for a while); "Game dynamic resolution" brings it back.

### Frame rate and modes
- **Frame rate:** 30 fps (as on the Switch), 60 fps, or **60 fps, steady speed**, where the world steps by the real
  frame time so it does not slow down when a frame takes longer than 1/60 s (down to 30 fps).
- **Game mode:** docked (1080p) or handheld (720p, lighter settings, far less GPU work); toggle live with
  Cmd+Ctrl+H or from the menu.

### Performance and stability
- Compiled Metal pipelines are kept on disk (a pipeline archive) and warmed at start; pipelines the GPU archiver
  rejects are left out and the rest is saved.
- Fixed a game freeze caused by weak ordering of the game's atomic loads on Apple Silicon.
- Fixed freezes and lost frames around a hidden or minimised window.
- Fixed a crash from a texture used after the game finalized it.
- On quit, the game's threads stop before the cache is saved.

### Tools
- `tools/hang_sample.sh` samples every thread and prints the kernel's wait dump when the game freezes.
- Renderer tests with no game files: `gmake test-metal-renderer` (GPU timing, the renderer, the shader translator).

### Known issues
See the README.
