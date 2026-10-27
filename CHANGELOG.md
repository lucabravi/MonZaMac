# Changelog

Versions follow `v<major>.<minor>.<patch>` (0.x until a stable 1.0). The version shows on the start screen and in
the in-game menu; the start screen also offers a newer release from GitHub when there is one.

## Unreleased

- **Texture size queries at higher internal resolutions (Metal):** a shader asking a scaled texture for the size of a
  mip level now gets the guest's size (the base halved per level) instead of the allocation's size divided by the
  scale, which was off by one at some levels (1.5x: 17 rows where the game has 16). A suspect for objects popping
  in and out at 1.5x; needs a check on a Mac.
- **CPU/GPU overlap (on by default; Developer > Experimental to turn it off):** the game's frame fence is waited
  one frame late, so the CPU prepares the next frame while the GPU draws the current one instead of taking turns
  (about 49 to 58 fps standing still, 53 to 59 in motion on one Mac). `LARECOMP_GPU_OVERLAP=0` also turns it off.

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
