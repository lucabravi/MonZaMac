# CPU-side ceilings in a walking scene

A CPU profile of the station walk (Time Profiler, wall-clock samples) listed per-command diagnostics and texture
change detection among the renderer's CPU costs. Sample attribution is not a stopwatch, so each candidate was
measured as a **ceiling**: a build that removes the work completely, compared with the same build without that
change. A ceiling is not a safe change (the second one lets changed textures go stale); it only says how much a
real implementation could gain at most.

## Method

- Same executable except for the one change, `develop` commit `3d70b3a`. Runs alternated between the variants
  (rotating the order when there were three), each on a fresh copy of the same save and settings.
- Scene: the station route, A at frame 215, stick forward from frame 650 for 375 presented frames. Fixed
  resolution, shadows 2×, SMAA and MetalFX, frame generation off, Developer uncapped FPS on, no profilers, no
  screenshots, no shader compilation in the measured frames.
- Throughput is the frame difference over the time difference between frames 650 and 1025. CPU and GPU are the
  medians of the `[perf]` lines (`LARECOMP_PERF_LOG`).
- Apple M5, macOS 26.5.1. At 1.5× (2880×1620) the scene is GPU-bound; at 1× it is close to balanced.

## Results

| Removed work | Resolution | Pairs | FPS, normal | FPS, removed | CPU ms | GPU ms |
| --- | --- | ---: | ---: | ---: | --- | --- |
| `op_ring_push` and `probe_step` for every command | 1.5× | 4 | 71.45 | 71.20 | 13.45 → 13.44 | 14.18 → 14.17 |
| same | 1× | 4 | 101.32 | 101.48 | 9.06 → 9.06 | 9.07 → 9.04 |
| Texture change detection (`fnv_sample`, `hash_full`) | 1.5× | 4 | 72.09 | 72.07 | 13.40 → 13.33 | 14.16 → 14.03 |
| same | 1× | 10 | 102.0 | 103.5 | 8.99 → 9.10 | n/a |

Medians of the throughput of each variant. The FPS of single runs of the same variant spread by about 1.5 at 1×
and by 1 at 1.5×. For the texture row at 1×, the ten runs span 99.0 to 102.7 FPS normally and 100.3 to 104.3 without
change detection (means 101.2 and 103.0).

## Conclusion

- The per-command diagnostics (the 64-command history and the pixel probe that returns at once when off) cost
  nothing measurable. The roughly 0.5 ms per frame the profile assigned to them was sampling attribution. Not worth
  a change.
- Removing all texture change detection gains about 1.5 FPS (1.5%) at 1× and nothing at 1.5×. Any safe replacement
  (a faster checksum, a cheaper schedule) can only capture a part of that, and the change detection exists because
  guest-written textures (glyph caches, video) cannot be assumed unchanged. Not worth the risk for now.
- The F3 / `[perf]` CPU figure is the time spent inside command submission, including waits for Metal command-buffer
  capacity, so CPU work that is removed does not necessarily show up in it. Judge CPU changes by throughput in a CPU-bound
  scene, as the uniform snapshot cache was in [its measurement](performance-uniform-snapshots.md).

Repeat the comparison only for a scene or a machine where the frame is CPU-bound, or after a change that alters how
much work these paths do.

## Where the CPU goes, 2026-11-16 (station walk, 1x, uncapped)

A `sample` of the process for 3 s during the walk (about 4000 busy thread-samples; the render thread and the game's
threads together keep a little over two cores busy): recompiled game code 47%, the runtime 24%, the Metal driver 14%.
The game code is flat (thousands of functions, none above 1.3% of the busy samples), so there is no single hot guest
function to fix.

The largest identified part of the runtime is the indirect-call dispatch: `rt_dispatch` and `dispatch_lookup` plus the
stub in the game library and the thread-local access came to about 11% of the busy samples. The per-thread cache in
front of the binary search had 4096 direct-mapped entries. Counted over a run of 200 M indirect calls: 2.9% went to
the slow path, and 1.1% of all calls ended in a binary search over the function table (the other 1.8% are calls to
the Switch OS replacement, which are never cached). With 32768 entries the binary searches fall to 0.07% of the calls
(2.26 M -> 0.14 M); the OS calls are unchanged.

Result at 1x, six alternating runs of each: throughput 113.5 -> 116.0 FPS (+2.2%; four of the six pairs favour the
larger cache, and single runs spread by about 3 FPS), CPU 7.73 -> 7.69 ms, GPU 8.16 -> 8.11 ms. Memory: 16 B x 32768 =
512 KB of thread-local storage for each thread that runs guest code.

Left in the same profile, not tried: the texture lookup in `renderer_texture` with its key and compare (about 7% of
the busy samples), the render thread's command loop (`exec_list`, 6%), the thread-local access in `rt_dispatch` (1.3%),
and the OS calls that skip the cache (the cost of `rt_unwind_point` there is not measured).
