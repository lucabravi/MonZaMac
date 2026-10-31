# GPU performance investigation

## Scope and setup

This investigation starts from `develop` at `f4fecb4` on an Apple M5, macOS 26.5.1, with Xcode 26.6 (17F113).
The first change adds measurement tools only. It changes no load/store action, texture allocation or usage flag,
shader translation, resolution scaling, reduction-sampler LOD or frame-overlap behavior.

The repeatable test scene is the saved plaza before the starter selection, standing opposite the NPC with the
three starter characters to the left. The active user save initially loaded the station; that scene is a separate
NPC/capture check, not a substitute for the plaza benchmark. All runs use a private copy of the selected save and
settings, the existing compiled game library, and a replay with only the initial confirmation presses and no
analog movement. The user's active save and settings are not modified.

The window drawable is 3600×2016. The game renders at 1920×1080 at 1x and 2880×1620 at 1.5x. Baseline settings are
60 fps with steady speed, CPU/GPU overlap on, game dynamic resolution off, game FXAA, depth of field and bloom on,
SMAA and MetalFX on, Sharper textures off, and 4K shadows off. Shader compilation is waited for during warm-up;
measurements exclude warm-up, screenshot readback, and capture start/stop.

## Warm stationary baseline

These runs have Metal capture support and the Metal HUD disabled. The GPU value comes from the existing
`[gpu-window]` interval-union tracker; it is not a hardware counter or a per-pass Xcode measurement. F3 frame
timing and the GPU timing log are enabled. Each run restores the same private save, warms up to frame 1000 and
collects 300 frames (1000–1299). The histogram runs for 120 frames around frame 600, before the measured window;
the first repeat's screenshot is at frame 900. The order is 1x/1.5x, 1.5x/1x, 1x/1.5x. The command-buffer chunk
limit is the default 8.

| Scale | Run | FPS | Median frame ms | Median GPU-union ms |
| --- | ---: | ---: | ---: | ---: |
| 1x | 1 | 60.00 | 16.691 | 14.328 |
| 1x | 2 | 59.50 | 16.681 | 13.107 |
| 1x | 3 | 60.00 | 16.657 | 13.405 |
| **1x** | **Median of runs** | **60.00** | **16.681** | **13.405** |
| 1.5x | 1 | 38.25 | 25.941 | 25.764 |
| 1.5x | 2 | 38.95 | 25.527 | 25.317 |
| 1.5x | 3 | 38.94 | 25.528 | 25.293 |
| **1.5x** | **Median of runs** | **38.94** | **25.528** | **25.317** |

FPS is 1000 divided by the mean frame interval; frame and GPU columns are medians of the 300 samples. The larger
render targets increase measured GPU occupancy by about 89%, while the steady 60 fps cap limits the 1x result.
This supports investigating GPU costs at 1.5x, but it does not identify a specific pass or establish an
optimization benefit. A prior batch taken while the system recovered from heavy Xcode profiling drifted badly
and was discarded. No trace replay or other profiling process ran alongside this baseline.

## What the diagnostics count

`gpuprofile N` collects the next N complete presented frames (1–120). `[gpu-profile]` counts guest draw calls,
clear requests, compute dispatches and snapshot copies. Its `pass-end` histogram counts actual render-encoder
closures, including explicit copy passes, SMAA, presentation and the overlay. MetalFX's internally created encoders
are visible in a GPU capture but are not separately counted by the application. `cb-end` counts actual commits
registered through the existing timing tracker, not calls to submit an empty buffer. Capture-boundary drain
markers are deliberately outside that tracker.

The existing `[gpu-window] buffers` field counts command buffers intersecting an observation window, including
buffers pending across multiple presents. It must not be read as commits in one game frame. The GPU-union value
also describes intervals intersecting the window between presents; it is distinct from summing encoder execution
times in a captured frame. Concurrent vertex, fragment and compute work means those execution times need not add
up to elapsed GPU time.

## Capture inventory: plaza at 1x

Xcode successfully opened and replayed the local capture of frame 3047. The source scene was stationary and all
guest draws were ready. This capture was made with the HUD disabled.

| Item | Application histogram | Xcode capture |
| --- | ---: | ---: |
| Guest draws | 1,584 | Included below |
| Clear requests | 66 | Encoded as draws |
| All native draws | Not a separate counter | 1,661 |
| Render encoders | 208 | 208 |
| Compute encoders / dispatches | 3 | 3 / 3 |
| Blit encoders | Not a separate counter | 5 |
| Feedback snapshot copies | 3 | Included in blits |
| Command-buffer commits | 90 | 91 including the capture drain marker |
| Live texture memory | — | 543.36 MiB |
| Live buffer memory | — | 3.21 GiB |

The complete-frame histogram was stable for the following 29 frames as well. The same histogram appeared in all
360 profiled 1.5x baseline frames. Some 1x warm-up frames had small draw/attachment-count differences, so the table
is a representative stationary frame, not a universal constant:

| Render encoder ended for | Count |
| --- | ---: |
| Transform-feedback boundary | 90 |
| End of guest submission | 66 |
| Attachment change | 37 |
| Texture copy | 7 |
| SMAA / its presentation interruption | 4 |
| Feedback snapshot interruption | 1 |
| Presentation | 1 |
| MetalFX presentation interruption | 1 |
| Overlay | 1 |
| **Total** | **208** |

These counts were taken with the transform-feedback pass ending of the time (`LARECOMP_XFB_END_BARRIER=0`); with the
barrier on, which is the default after `docs/performance-xfb.md`, those 90 boundaries stay inside open passes.

| Command buffer committed for | Count |
| --- | ---: |
| End of guest submission | 75 |
| Chunk limit (default 8) | 14 |
| Presentation boundary | 1 |
| **Total** | **90** |

These counts identify places to inspect; they do not establish that merging a boundary is legal or profitable.

## Command-buffer chunk screen

A bounded screen changed only `LARECOMP_CHUNK_PASSES`, using the same 1.5x scene/settings and 300-frame warm
window. The nondefault values each have one run; the default row is the median of the three baseline runs above.
This is a candidate screen, not a repeated confirmation of small differences.

| Chunk limit | FPS | Median GPU-union ms |
| --- | ---: | ---: |
| 0 (no chunk limit) | 36.28 | 26.945 |
| **8 (default, three-run median)** | **38.94** | **25.317** |
| 16 | 39.11 | 25.345 |
| 32 | 38.74 | 25.752 |
| 64 | 38.07 | 26.072 |

None reduced the measured GPU time. No setting is promoted and the default remains 8. The near-equal result at
16 is small and was not pursued.

## Measurement cautions

- Enabling Metal capture support adds CPU overhead even outside the captured frame. Live benchmarks must be run
  separately from capture and its queue drains. Capture-frame FPS is not a performance result.
- The first station capture with the HUD and encoder timing enabled crashed in Apple's `GPUToolsCapture` writer
  during `stopCapture`. A subsequent plaza capture with the HUD disabled completed and was opened in Xcode. These
  are different scenes, so this does not by itself prove the HUD caused the crash. The tested capture procedure
  uses a HUD-free process.
- The full-frame trace occupied approximately 48 GiB because buffer contents were snapshotted repeatedly. Xcode
  derived-counter analysis repeatedly restored those resources, and the user reported approximately 300 GB of
  process memory on a 32 GiB Mac. Analysis was abandoned and the large trace was deleted. The inventory above was
  read before that point; reliable per-pass timings, bandwidth counters and a top-ten shader ranking were **not
  obtained**. No further full-game capture/replay is planned on this machine for this phase.
- A one-frame capture is not a wall-clock or memory limit: Apple's finalization and analysis can outlive it.
  Any further capture experiment must run under an external 15-second process deadline independent of the chat.
  Normal timing runs need their own bounded lifetime and must not run alongside capture/replay.
- Xcode's separate Metal Toolchain download failed both in its GUI and through `xcodebuild -downloadComponent
  MetalToolchain`, with an unavailable asset catalog for requested build 17F109. Capture replay itself succeeded;
  shader source-level debugging has not been verified.
- Exact screenshot equality across independent game runs is not assumed: animated characters, vegetation and
  moving shadows can differ even at the same presented-frame index. The profiler's asset-free regression checks
  require exact unchanged pixels; game comparisons must distinguish those changes from rendering artifacts.

## Validation

The starting suite passed 82/82 native Metal tests. With the profiling additions it passed 84/84 with Metal API
Validation on Apple M5. The new cases cover default-off behavior, complete-frame boundaries, actual versus empty
submissions, attachment changes, CPU readback flushes, exact output pixels, repeated captures, directory errors,
reset cancellation and leaving another tool's capture active. The capture cases also passed in a separate run
with `MTL_CAPTURE_ENABLED=1` and Metal API Validation enabled. The runtime was built locally.

No GPU optimization or performance improvement is claimed by this tooling change. Battle scenes, later areas
and other Macs have not been tested.

## Pass map (stationary scene, 1.5x)

`gpupass 30` on a copy of the starting save, 1280x720 window, 1.5x (2880x1620), the settings used had the old "4K shadows" on (shadow maps 4096x4096).
106 passes a frame, about 16-17 ms of GPU. The ordinal (`#n`) and the size of a pass stayed the same over many runs;
the first-draw fragment address (`fs=`) did not (the game uploads its shaders to a moving address), so look a pass up
by ordinal and size, then take its program from the same run's log.

| Pass | Share | Size | Draws | Shader (translated MSL, from `LARECOMP_SAVE_MSL=1`) |
| --- | ---: | --- | ---: | --- |
| #24 | 21-23% | 2880x1620 | ~360 | main scene geometry |
| #8, #9 | 12% + 9.5% | 4096x4096 | 262 each | the two shadow maps; cost follows the shadow resolution setting |
| #30 | 11% | 2880x1620 | 1 | one full-screen program, 3258 lines, 52 transcendentals, 7 samples + 6 reads |
| #29 | 6% | 1440x810 | 1 | one half-resolution program, 1734 lines, 19 samples from a texture array + 19 reads |
| #0 | 4.6% | 2880x1620 | 217 | no depth attachment |
| #104 | 3.4% | 2880x1620 | 1 | |

The rest is a tail under 0.6 ms each. Labels in the last column are read from the draw/size/shader shape, not from the
game, so treat them as hints.

Uncapped, with default shadows, this scene runs at about 74 fps: 13.5 ms a frame with the GPU busy 12.9 ms and the CPU
12.5 ms, so both are close to the limit. The `idle` share `gpupass` reports before #24 (about 2.9 ms) is mostly the
effect of `gpupass` waiting at each frame end.

With the old "4K shadows" off (shadow maps 1024x1024), the same scene is about 12.2 ms of GPU: #24 4.4 ms, #30 1.33 ms,
#29 0.69 ms, #8/#9 0.60 + 0.55 ms. So #29 and #30 get 30% cheaper with smaller shadow maps, and #8/#9 about 70%: those
passes are bound by their shadow-map reads, not by translated-code overhead (no `pc` loop, no FMZ or half-pack helpers
left in #30). #8/#9's fragment program is ~100 lines: a conditional `discard_fragment()` (a fade-out test on constant
buffer values) plus an id write.

Finding what a pass runs: `LARECOMP_SAVE_MSL=1` writes `build/msl/<fs address>_fs.metal` (annotated with the guest pc of
each instruction); `tools/msl_stats.py` summarises one. A `switch (pc)` loop with `ssy[]` arrays in it means the program
fell back to the dispatcher instead of the structured flow (see `docs/performance-brx.md`): that is the first thing to
look at for a heavy single-draw pass.

## Next measurements

Per-pass GPU time, bandwidth and top shader costs remain unmeasured; the pass-count table cannot substitute for
them. No load/store, texture-usage, pass-merging, feedback-copy or shader change is justified by this data alone.
The chunk-size screen above found no useful candidate. Option costs (SMAA, MetalFX, Sharper textures, 4K shadows)
remain pending. They can use the existing interval-union tracker without full-frame Xcode replay. Start each
candidate with one 1.5x run off and one on in the same scene/settings; deepen only for a useful signal, with
focused visual checks and a separate PR. Do not repeat unchanged matrices. Any measured gain is kept, however
small, as long as the checks hold.

## References

- [Apple: Monitoring Metal graphics performance](https://developer.apple.com/documentation/xcode/monitoring-your-metal-apps-graphics-performance)
- [Apple: Customizing the Metal Performance HUD](https://developer.apple.com/documentation/xcode/customizing-metal-performance-hud)
- [Apple: Generating Metal HUD performance reports](https://developer.apple.com/documentation/xcode/generating-performance-reports-with-metal-performance-hud)
