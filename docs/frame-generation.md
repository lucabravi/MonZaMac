# Optional MetalFX frame generation

Video → Frame generation offers **Off**, **30 → 60 fps**, and **60 → 120 fps**. It is off by default and requires
macOS 26 plus a GPU that reports MetalFX frame-interpolation support. The selected screen must support at least
60 Hz or 120 Hz respectively. Unsupported screens and missing scene inputs use real frames; the saved request is kept.

The mode selects 30 or 60 real game frames per second. Intermediate images are produced by MetalFX on the host;
they do not advance the game's simulation, input, animation timers or guest vblank. Turning generation off restores
the previously selected real frame rate. `LARECOMP_FPS` and Developer's uncapped benchmark suspend generation.

This first implementation reconstructs motion from the camera and scene depth. It does not yet have per-object
motion vectors. Moving characters, particles and newly revealed surfaces can show interpolation artifacts. It adds
GPU work and presentation latency; 120 displayed fps requires enough headroom to maintain 60 real fps plus generation.
It does not make 30-fps input respond like native 60-fps input.

The renderer captures validated, matching-frame depth/camera data and the scene after FXAA but before HUD draws.
MetalFX receives the final composited HUD separately. The selected SMAA/spatial-upscaling path processes both real
and generated images. The native overlay is built once and rendered into both images without advancing ImGui twice.

Generation resets on mode, window size, input-size or projection changes, camera cuts, missing inputs and opening
the native settings menu. After a reset the first two images seed history; they are shown as real frames rather than
counting MetalFX's initial endpoint copy as a generated image. An independent presenter receives immutable GPU-ready
images, uses a separate Metal queue, and limits pending whole-frame pairs to avoid an unbounded latency backlog.

The FPS overlay shows the real rate and actual display rate on one line, for example `60fps -> FG 120fps`.
The FG suffix appears only while synthetic images are reaching the display. Without generation it shows only the real rate. `LARECOMP_DEVLOG=framegen` enables bounded input/generation diagnostics; presentation
summaries also report dropped pending pairs. Counters alone do not establish visual interpolation quality.

## Verification

- `python3 tools/test_frame_generation_settings.py`: persistence, unsupported hardware/platforms, FPS conflicts,
  preservation of preferences and source-rate transitions.
- `python3 tools/test_frame_generation_camera.py`: synthetic normal/reversed projections, rotated cameras translated
  25 km, inconsistent matrices, malformed/unaligned inputs and rejection without modifying outputs.
- `python3 tools/test_frame_generation_gpu.py`: native MetalFX with API/GPU validation, backward motion and depth
  conversion, generated images distinct from both endpoints, HUD, resets, resize and in-flight resource retention.
- `python3 tools/test_frame_generation_display.py`: native private copies, retention, bounded pair drops, failure and
  stale-epoch handling, absolute 60/120 deadlines, reset wakeups and presentation-only counters.

On the tested Apple M5 / 120 Hz screen, the station reached about 60 displayed fps from 30 real at render scale 1.5x.
A 60-real-fps test at 1x reached 120 displayed fps; the 1.5x movement/menu/resize test reached roughly 90–105, so a
sustained 120 is not promised at that load. Short tests exercised walking, camera rotation, menu pause/recovery and
window resize/recovery. A separate 0.75x test exercised SMAA + MetalFX spatial upscaling and F3.
Other locations, game versions and Macs have not been visually verified. No game data or shader dumps are distributed.
