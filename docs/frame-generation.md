# Optional MetalFX frame generation

**Experimental.** Supported animated geometry supplies previous-vertex motion, improving character turns and animation. Small silhouette/disocclusion artifacts can remain; unsupported geometry and particles use camera motion.

Video → Frame generation offers **Off**, **30 → 60 fps**, and **60 → 120 fps**. It is off by default and requires
macOS 26 plus a GPU that reports MetalFX frame-interpolation support. The selected screen must support at least
60 Hz or 120 Hz respectively. Unsupported screens and missing scene inputs use real frames; the saved request is kept.

The mode selects 30 or 60 real game frames per second. Intermediate images are produced by MetalFX on the host;
they do not advance the game's simulation, input, animation timers or guest vblank. Turning generation off restores
the previously selected real frame rate. `LARECOMP_FPS` and Developer's uncapped benchmark suspend generation.

Motion combines camera/depth reprojection with captured previous vertex positions for supported skinned G-buffer draws.
History is bounded and validated per vertex; missing history and ordinary foreground draws invalidate covered motion.
Moving particles and newly revealed surfaces can still show interpolation artifacts. It adds
GPU work and presentation latency; 120 displayed fps requires enough headroom to maintain 60 real fps plus generation.
It does not make 30-fps input respond like native 60-fps input.

Video → Frame generation quality offers **Native** (default) and **Performance**. Performance limits only the
intermediate images to 1920 pixels wide (1080p at 16:9); real images retain the selected rendering resolution.
Switching applies immediately and resets interpolation history when the working size changes. Intermediate images
may look softer. Native and generated images keep separate SMAA/spatial-MetalFX caches, so alternating sizes do not
recompile filters every frame.

The interpolated picture is the viewport the game draws into: in handheld mode that is 1280x720 inside larger game
targets, so scene, depth, motion and the HUD are all read from that rectangle only.

The renderer captures validated, matching-frame depth/camera data and the scene after FXAA but before HUD draws.
MetalFX receives the final composited HUD separately. The selected SMAA/spatial-upscaling path processes both real
and generated images. When supported, MetalFX writes directly to the game canvas's 8-bit format, avoiding an extra
full-frame conversion. Other formats/devices retain the FP16 output path; `LARECOMP_FG_OUTPUT_FP16=1` forces it for comparison. The native overlay is built once and rendered into both images without advancing ImGui twice.

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
  stale-epoch handling, measured-source deadlines at 30/60/45/50 fps, reset wakeups and presentation-only counters.
- `python3 tools/test_fg_geometry_shaders.py`: generated Metal shaders, rigid/deformed motion, sparse/stale indexed
  history, foreground invalidation, buffer bounds and the history registry.
- Renderer case `frame-generation-filters`: alternating native/generated sizes retain their SMAA pipelines and scalers.

On the tested Apple M5 / 120 Hz screen, the station reached about 60 displayed fps from 30 real at render scale 1.5x.
A 60-real-fps test at 1x reached 120 displayed fps; the 1.5x movement/menu/resize test reached roughly 90–105, so a
sustained 120 is not promised at that load. Short tests exercised walking, camera rotation, menu pause/recovery and
window resize/recovery. A separate 0.75x test exercised SMAA + MetalFX spatial upscaling and F3.
The user also tested character turns and a battle and confirmed the improvement, with minor edge artifacts noted.
Other Macs and all effects/locations have not been exhaustively verified. No game data or shader dumps are distributed.

One station comparison on the same M5 at render scale 1.5x / shadows 2x / 60→120 measured Native at 40.2 real /
80.2 displayed fps (24.85 ms GPU), versus Performance at 49.1 / 98.7 (20.40 ms). This is a quality/performance
tradeoff, not a guarantee of 60 real / 120 displayed fps. The new Performance mode still needs broader motion-quality testing.

## Presentation and diagnostics

The presenter uses the measured source-frame interval, including below the nominal 30/60 rate; this avoids uneven
midpoint spacing under GPU load. Camera data is decoded from the exact uniform snapshot bound to the deferred draw.
The per-vertex path is enabled with frame generation; `LARECOMP_FG_VERTEX_MOTION=0` forces camera-only motion for diagnosis.
Direct single-instance skinned draws with compatible layout and a free MRT7 are tracked, in the G-buffer, recognised by its
formats and a common size for its targets and depth. Other G-buffer draws write
an invalid-motion sentinel, so covered background motion cannot leak into foreground objects. The motion variants of
a shader compile when first drawn, so a new character can cause a short hitch. These limits do not establish
artifact-free interpolation.

## Temporal reconstruction

Frame generation can also consume reconstructed color from the optional [MetalFX temporal upscaler](temporal-upscaling.md), sharing its low-resolution depth/motion. Select Temporal in Video and then either generation target. Combined mode uses the reconstructed output resolution; the saved generated-frame Performance choice is restored when temporal is off. The option remains experimental because incomplete motion coverage can create edge artifacts.
