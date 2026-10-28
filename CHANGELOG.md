# Changelog

Versions follow `v<major>.<minor>.<patch>` (0.x until a stable 1.0). The version shows on the start screen and in
the in-game menu; the start screen also offers a newer release from GitHub when there is one.

## Unreleased

- **Fewer render passes after GPU skinning (on by default):** the pass used to end after each transform-feedback stage;
  it now stays open with a Metal buffer barrier (about 1 ms less GPU time a frame in the tested scenes: 38 to 42 fps at
  1.5x in one test). Developer tab "Keep passes open after skinning" turns it off at once;
  `LARECOMP_XFB_END_BARRIER=0` too.
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
