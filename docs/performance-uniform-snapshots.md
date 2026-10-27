# Metal uniform snapshots: measured CPU copy reduction

On Apple M5 / macOS 26.5.1, steady-state profiling of the saved plaza scene found substantial work in uniform
buffer copies (`bind_cbufs` → `memcpy`). This investigation excludes shader precompilation and render-thread changes.

## Change

Graphics and compute uniforms still use immutable snapshots. A bounded cache reuses a snapshot only when its source
address, size, and every byte match. A changed source gets a separate allocation, preserving earlier GPU reads.
Resetting or replacing the ring invalidates cached offsets. Vertex/index allocations keep the existing copy path.
Hash collisions and cache replacement only reduce the hit rate; they never substitute a different buffer's bytes.

`LARECOMP_NO_UNIFORM_CACHE=1` selects the copying path for comparisons. `LARECOMP_UNIFORM_STATS=1` prints copied and
reused bytes with the existing renderer statistics.

## A/B results

Both variants used the same executable, based on `develop` commit `5ec7ab8`. Runs alternated off/on, with a fresh
copy of the same save and settings each time: docked mode, steady 60 FPS, internal 1x, MetalFX and SMAA, window
1280×720. Inputs were A at frames 180, 240, and 300. Each run warmed up through at least frame 800, then measured
about eight seconds using frame/time differences from the renderer log. The timed intervals had no shader or
pipeline compilation, screenshot captures, or CPU sampling. Archive persistence and shader warm-up were disabled
for both variants to exclude background work from the comparison.

| Pair | Cache off (FPS) | Cache on (FPS) |
| --- | ---: | ---: |
| 1 | 45.19 | 50.12 |
| 2 | 48.64 | 53.50 |
| 3 | 48.02 | 53.25 |
| Median | 48.02 | 53.25 |

The median gain in this scene was **10.9%** (about 20.82 → 18.78 ms/frame). Uniform copies fell from about
43.97 MiB/frame to 13.49 MiB/frame; about 30.48 MiB/frame was reused after comparison, a 69% reduction in writes.
GPU-active time in pairs 2/3 stayed around 14 ms/frame, fence waits around 7.3 ms/frame, and submissions at
93/frame. These are scene-specific results, not a claim of a 10.9% gain throughout the game or a guaranteed 60 FPS.

A separate five-second CPU sample showed 649 leaf samples in memory copies before the optimization, versus 241 in
copies plus 147 in comparisons with the cache. Sampling counts are wall-clock observations, not precise CPU-time
percentages; the repeated A/B runs above provide the frame-rate evidence.

## Remaining measured leads

- Texture change detection remains hot: 363 baseline / 383 candidate samples were in the texture path, with sampled
  instructions inside the scalar full-hash and sampled-hash loops. Any optimization must preserve detection of sparse
  CPU writes, including glyph updates; simply checking less often would change correctness.
- The baseline sample included 678 leaf samples in command-buffer submission to the driver. Roughly 93 small
  submissions per frame remain after this change. Batching needs separate fence/guest-memory ordering analysis.
- Fence waits are significant, but protect guest reads/reuse of GPU-written memory. They are not safe to remove on
  the basis of these timings. GPU work itself is already close to a 16.7 ms budget in this scene.

The prior `develop-update.log` also contained a `fiber_reset` crash during in-place reboot. That separate correctness
issue was recorded; it was not involved in these isolated normal-quit benchmark runs.

## Correctness checks

The native `uniform-snapshots` fixture checks unchanged reuse and changed data, then executes GPU reads of all
snapshots after source mutation and ring replacement. It also checks reset/overwrite safety. The broader Metal suite
exercises graphics and compute uniform bindings, which both use the cache.

Local game captures and profiles stay under ignored `build/perf/`; no game files or generated code belong in this PR.
