# Experimental transform-feedback pass reuse

## Change and safety boundary

The stationary plaza histogram from the GPU profiling investigation counted 90 transform-feedback endings
among 208 render encoders. The original `CMD_END_XFB` ends the encoder so later draws can read GPU-produced
vertices. This experiment keeps the encoder open and inserts a buffer memory barrier from the vertex stage to
the vertex and fragment stages instead. Attachment changes, compute dispatches, copies and submissions keep
their existing boundaries. It does not assume all 90 boundaries will disappear in a real frame.

The switch is **off by default**:

```sh
LARECOMP_XFB_END_BARRIER=1 tools/hang_sample.sh
```

It can be switched on in the game, with no restart: Developer tab (Cmd+Shift+D) > "Keep passes open after skinning"
(`xfb_barrier = 1` in `larecomp.ini`). The variable, when set, wins over the setting. Use
`LARECOMP_XFB_END_BARRIER=0`, or leave both off, for the original behavior. The barrier path requires macOS 13
or later; older systems retain the original pass ending. No shader text, texture allocation, Hi-Z LOD,
resolution-scaling or CPU/GPU-overlap behavior changes. This is an optional experiment, not a global default.

## Repeated A/B measurements

Base: `develop` at `f4fecb4`. Hardware: Apple M5, 32 GiB, macOS 26.5.1. Same stationary plaza save, initial
confirmation replay and private settings/data root. The original game files and active save remain untouched.

Settings: steady 60 fps, overlap on, game DRS off, FXAA/DOF/bloom on, SMAA/MetalFX on, Sharper textures off,
4K shadows off, default chunk limit 8. Drawable 3600×2016, rendering 1920×1080 at 1x and 2880×1620 at 1.5x.
Metal HUD/capture support and all other GPU profilers are disabled. Each run warms up to frame 1000 and measures
300 frames (1000–1299). Screenshots at frame 900 are outside that window.

Each scale has three off/on pairs in AB/BA/AB order. FPS is 1000 divided by the mean frame interval; the frame
and GPU columns are sample medians. GPU time is the existing interval-union measurement between presents,
not summed command-buffer spans or a hardware shader counter.

| Scale | Run | Off FPS | On FPS | Off frame ms | On frame ms | Off GPU ms | On GPU ms |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1x | 1 | 60.00 | 60.00 | 16.664 | 16.660 | 13.833 | 12.426 |
| 1x | 2 | 59.96 | 60.00 | 16.663 | 16.646 | 13.256 | 12.098 |
| 1x | 3 | 60.00 | 60.01 | 16.656 | 16.658 | 13.165 | 12.128 |
| 1.5x | 1 | 38.22 | 40.00 | 26.001 | 24.845 | 25.832 | 24.641 |
| 1.5x | 2 | 38.84 | 39.78 | 25.575 | 24.727 | 25.309 | 24.302 |
| 1.5x | 3 | 38.92 | 40.76 | 25.513 | 24.390 | 25.263 | 24.057 |

Medians of the three runs:

| Scale | Off GPU ms | On GPU ms | GPU reduction | Off FPS | On FPS |
| --- | ---: | ---: | ---: | ---: | ---: |
| 1x | 13.26 | 12.13 | **8.51%** | 60.00 | 60.00 |
| 1.5x | 25.31 | 24.30 | **3.98%** | 38.84 | 40.00 |

All three pairs improve at both scales. The 60 fps cap limits the 1x FPS result. The 1.5x improvement is modest
and specific to this scene/Mac; it does not establish a similar gain elsewhere.

## Correctness checks

An asset-free GPU regression writes a triangle's positions through transform feedback and consumes them as
vertex attributes without an intervening CPU wait or submission. It checks exact green output pixels and one
render pass with the option enabled, versus the original two passes with it disabled. The enabled expectation
failed before the implementation and passed afterward. Full Metal API Validation suites passed 83/83 with
the option on and off.

The runtime was rebuilt and linked with the existing complete game library; no game-code regeneration was
needed. The barrier changes no generated shader text, so pipeline-cache invalidation is not required.

Saved frame-900 screenshots were checked at both scales with Sharper textures off and on, plus an off/on pair
in the station at 1.5x. No broken skinning, missing visible NPCs or damaged geometry was observed in those views.
These were stationary checks, not a movement/culling stress test. The station pair is a correctness check and
is not included in the repeated performance table above.

Game screenshots are not pixel-identical between launches: NPC poses, vegetation, the marker animation and
cloud shadows vary. With the HUD excluded, the plaza pairs' mean absolute channel difference (8-bit RGB) was
21.92 at 1x and 1.10 at 1.5x; with Sharper textures it was 14.01 and 2.09. The large 1x differences include the
moving cloud shadow and are not presented as exact-pixel validation. Exact pixels are verified by the synthetic
GPU regression. Battles, long play sessions, camera sweeps, other areas/Macs and the pre-macOS-13 fallback have
not been tested.

Independent code review found no production correctness issue. Its minor test finding was addressed by making
the expected pass count respect the same macOS availability boundary. The production runtime was unchanged by
that test-only correction.

## Follow-up measurements

Start future modifications with **one 1.5x run off and one on**, using the same scene/settings. Investigate further only when that pair
shows a useful signal. Do not repeat unchanged cases or rerun a whole matrix without a specific reason.

## Other paths tried

The preceding chunk-size screen used 0, 8, 16, 32 and 64 at 1.5x. The default 8 had a three-run median of
38.94 fps / 25.317 ms GPU; single candidate runs were 36.28 / 26.945 at 0, 39.11 / 25.345 at 16,
38.74 / 25.752 at 32 and 38.07 / 26.072 at 64. None reduced GPU time, so the default was left unchanged.
Those measurements were taken separately from this A/B; use the paired off/on rows above to assess this change.

Full-frame Xcode replay yielded a numeric encoder inventory, but counter analysis consumed excessive memory
and was abandoned. Large traces were deleted. No further Xcode capture/replay was used here. Per-pass shader
costs and bandwidth remain unknown; load/store, texture-usage, shader and graphics-option optimizations were
not attempted by this change. No game data, shaders, traces or compiled libraries accompany the results.
