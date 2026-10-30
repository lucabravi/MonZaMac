# Shadow resolution and sharpness: cost

Settings > Rendering > **Shadow resolution** (Game's / 2x / 3x / 4x, from the next start) and **Shadow sharpness**
(Game's / 2x / 3x / 4x, at once, at most the resolution). What they do is in `runtime/nvn/metal.m`
(`tex_shadow_scale`) and `runtime/nvn/renderer.m` (the size the shadow maps report to the shaders' size queries).

## Measurement (2026-10-30)

Pokémon Legends: Z-A 2.0.2, the maintainer's save at the platform of Lumiose station (the scene of the shadow
screenshots), window 1280x720, Apple Silicon Mac. Every run starts the game from the save with the same scripted title
input (`TITLE_INPUT` of `tools/perf_sweep.py`), then stands still. The CPU time (submit) and the GPU time (busy) per
frame are the ones the Developer tab's F3 overlay shows (`g_stat_cpu_ms`, `g_stat_gpu_ms`, smoothed), logged every 60
frames by a temporary line that is not in the repository; the figures are the mean of the 34 samples from frame 3600
on (a run is about 5600 frames). The first and the last run are the same setting, to see the noise.

| Run | Setting | CPU ms | GPU ms |
|---|---|---|---|
| 1 | Resolution Game's, sharpness Game's | 8.18 | 13.56 |
| 2 | Resolution 2x, sharpness Game's | 8.47 | 14.01 |
| 3 | Resolution 2x, sharpness 2x | 9.25 | 14.50 |
| 4 | Resolution 3x, sharpness Game's | 9.14 | 15.18 |
| 5 | Resolution 3x, sharpness 3x | 9.18 | 15.20 |
| 6 | Resolution 4x, sharpness Game's | 9.27 | 15.44 |
| 7 | Resolution 4x, sharpness 4x | 9.27 | 15.58 |
| 8 | the older "4K shadows" (`game_shadows_4k = 1`) | 9.25 | 15.40 |
| 9 | as run 1 | 8.23 | 13.55 |

- Runs 1 and 9 agree to 0.01 ms of GPU time: the differences below are not noise.
- The resolution is what costs: about +0.5 ms of GPU time at 2x, +1.6 at 3x, +1.9 at 4x, and about +1 ms of CPU time
  from 2x on. At 60 fps a frame is 16.7 ms: 15.6 ms of GPU time at the most expensive setting still fits.
- The sharpness is nearly free: at the same resolution it adds 0.0 to 0.5 ms.
- The older 4K shadows (a 4096 map made by patching the size the game loads) costs the same as resolution 4x.

## Limits

One scene (the platform in this sun), one run per setting, one window size, one Mac. Not measured: interiors, battles,
other times of day, 1.5x and larger render scales (where the shadow share of a frame is smaller or larger), other
GPUs, memory pressure (4x is about 240 MB for the two shadow arrays, the game's own are 15 MB).
