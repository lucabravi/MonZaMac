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

## Cache size (2026-10-31)

At 1x in the starting scene a frame binds ~2300 indexed constant buffers (14.8 MB, copied whole: the shader indexes
them with a register) and ~5600 fixed ones (3.3 MB). With 128 direct-mapped slots they evicted each other: per 2 s,
1.61 GB copied / 2.85 GB reused. 4096 slots (128 KB): 0.70 GB copied / 3.93 GB reused. Uncapped, four alternating
pairs: 99.0 -> 100.4 fps at 1x (CPU 9.2 -> 9.0 ms), 65.0 -> 65.6 at 1.5x. Same rules: a hit still compares every
byte, a ring reset still invalidates every entry. Reading indexed buffers in place instead (no snapshot) would remove
the remaining traffic but lets a CPU write reach a draw still on the GPU: it is an experimental switch,
`LARECOMP_CBUF_INPLACE=1`, off by default. Same scene, 1x, uncapped, four pairs: CPU 9.00 -> 8.73 ms (-3%), GPU
7.90 -> 7.97 ms; captures at the same frame with the frame rate capped were identical (uncapped captures differ only
by the time of day, which runs at another speed). A standing scene does not show the risky case (a buffer rewritten
while a draw that reads it is still on the GPU): it needs play-testing - battles, running, cutscenes - before it can
be on by default. At 1.5x (4K shadows, GPU bound) it costs: four pairs, GPU 15.24 -> 15.76 ms,
65.6 -> 63.4 fps (-3.3%) - the GPU reads the indexed buffers worse from the guest heap than from the ring of
snapshots. Worth it only where the CPU is the limit (1x, slower CPUs), so it stays off. 8192 cache entries instead of 4096: copied bytes -1.5%, CPU 9.00 vs 8.97 ms (no difference).

## Correctness checks

The native `uniform-snapshots` fixture checks unchanged reuse and changed data, then executes GPU reads of all
snapshots after source mutation and ring replacement. It also checks reset/overwrite safety. The broader Metal suite
exercises graphics and compute uniform bindings, which both use the cache.

Local game captures and profiles stay under ignored `build/perf/`; no game files or generated code belong in this PR.
