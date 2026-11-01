# Prepare all shaders

An opt-in step that compiles the Metal library of every shader in the player's own game files before the game asks for it.

## What it does

1. The start screen's **All shaders** badge shows the state: a green check when the precompile is current, a yellow triangle
   when it was never done or is out of date (the reason is in the window that opens when it is clicked).
2. **Compile all shaders** sets a request and starts the game. The game must do the work because the translator embeds the
   running game's guest memory window, so a translation made outside it would not match what the game later asks for.
3. In the game process, before the normal start: the bundled helper (`lasgen shader-catalog index`, with the native
   decoder) writes every shader of the game files to `cache/shader-precompile/inputs/` (12,949 inputs, about 115 MB, read in
   25-40 s). Each one is translated serially with the default specialization (all textures as floats, no transform feedback,
   every vertex output available to fragment programs) and its library is compiled on workers sized to the CPU count, behind
   the native progress page with a **Stop** button. The inputs are deleted at the end.
4. A complete run writes `cache/shader-precompile/stamp.txt`: the precompile version (`SHADER_PRECOMPILE_VERSION` in
   `runtime/nvn/precompile_stamp.h`), macOS, the GPU name, size and modification time of `exefs/main` and
   `romfs/arc/data.trpfs`, and how many shaders were compiled. The badge compares it with the current values.

Bump `SHADER_PRECOMPILE_VERSION` when the translator's output changes or the precompile covers more kinds of shader.
`LARECOMP_PRECOMPILE=1` requests it from the environment (tests).

## Measured (Apple M5, 10 cores)

- 12,949 shaders: 12,943 translated and built (six fail to translate and compile normally when used), 258-268 s of compile
  on 10 workers after the 24-40 s of reading.
- Metal's shader cache after a clean run: 364-376 MB.
- Against what a real session asked for, the default-specialization program was identical for 99.5% of vertex and 73% of
  fragment programs (`blind-libraries` in `tools/test_metal_renderer.m`).
- Cold-cache station walk (Stazione save, 1.5x, 30 fps, shader waiting on, no catalog, no recipes, Metal cache cleared before
  the control, compile early on): with the precompile, the worst frame while loading was 566 ms and the walk compiled
  nothing noticeable (1 ms, worst frame 39 ms); the cold control had a 15,982 ms worst frame and 22,960 ms of compile time.
  One run each. Pipelines (library plus render state) still get created when first used; with the libraries cached that costs
  little.

## With and without the catalog (waiting off, the normal setting)

The same station walk, one run each, cold start except where the precompiled Metal cache is restored from a snapshot, no
other changes (compile early on in all rows; the catalog has 580 recipes):

| Configuration | Worst frame, load | Draws skipped (pipeline still compiling) | Compile time | Startup wait |
| --- | ---: | ---: | ---: | ---: |
| Nothing | 5135 ms | 826 | 32.1 s | 0 |
| Precompile only | 2164 ms | 369 | 2.1 s | 0 |
| Precompile + catalog (early) | 2134 ms | 45 | 2.1 s | 0 |
| Precompile + catalog + preparation at start | 478 ms | 2 | 0.4 s | 1.3 s |
| Catalog + preparation, no precompile | 474 ms | 0 | 0.5 s | 9.0 s |

The precompile removes most of the compile time and the long stalls; the pipelines (library plus render state) still get
created when first used, so draws are skipped for a few frames until they are ready (369 without a catalog). The catalog
prepares those pipelines: skipped draws fall to 2, and because the libraries are already cached the startup preparation
takes 1.3 s instead of 9.0 s. They complement each other.

## What it does not do

It does not know render state, vertex/fragment pairs or texture-type variants, so some variants still compile when first
used; the catalog and the local recipes (Shaders tab) cover those. macOS manages Metal's cache and may clear it: the badge
then still says current until a macOS or GPU change, so use **Compile again** if the stalls return.
