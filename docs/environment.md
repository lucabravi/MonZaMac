# Environment variables

MonZaMac reads some `LARECOMP_*` environment variables. The ones below are supported: they keep their name and meaning
from one release to the next. The code reads many more (debug switches, test hooks, experiments). They are not listed
because they can change or disappear at any time; each one is described where the code reads it
(`grep 'getenv("LARECOMP_'`).

In the online edition, **Play online** keeps only these ten and what the start screen passes on (the game library, the save
and the loading cover): every other `LARECOMP_*` variable is ignored while the Lumiose module is loaded, so the game is the
same for every player (`runtime/online_env.c`; a line in the log names each one). They come back for an offline game started
afterwards.

To start the app with a variable, run the executable inside the bundle from a terminal:

```sh
LARECOMP_PERF_LOG=60 /Applications/MonZaMac.app/Contents/MacOS/monzamac
```

A number variable is off at `0` and on at any other number. A variable that is not set leaves the setting of the
Developer tab (or the default) in charge.

## Where the files are

| Variable | Effect |
|---|---|
| `LARECOMP_DATA_ROOT=<folder>` | The data folder (game files, saves, caches, settings) instead of `~/Library/Application Support/com.monzamac.app`. The folder is created when it is missing. MonZaMac does not start if it cannot write there. |
| `LARECOMP_SETTINGS=<file>` | Settings file instead of `larecomp.ini`. A relative path starts at the data folder. For a scratch run that must not touch your settings. |
| `LARECOMP_NO_UPDATE_CHECK=1` | The start screen does not look for a new version and does not check the shader catalog for an update. Any value turns it off. |

## When something goes wrong

Each of these switches off or changes one thing, to find out whether it causes a problem. The first two are on by
default. The two GPU ones also exist as settings in the Developer tab; the variable wins over the setting.

| Variable | Effect |
|---|---|
| `LARECOMP_NULL_GETTER=0` | Switches off the guard that returns zeros when the game reads an object that is not there (a crash in the first Mega Dimension mission's battle). |
| `LARECOMP_NPC_CAPACITY_FIX=0` | The game's own limits of 20 and 25 people in view, instead of 64. Only version 2.0.2 of the game has the fix. |
| `LARECOMP_GPU_OVERLAP=0\|1` | `0`: the CPU waits for the GPU at the end of every frame (slower, simpler). Use it to check whether something that pops in or flickers comes from the overlap. |
| `LARECOMP_XFB_END_BARRIER=0\|1` | `0`: the render pass ends after the GPU has skinned the characters, as in the first versions. Needs macOS 13 or later for `1`. See [the XFB notes](performance-xfb.md). |

## Reports and measurements

| Variable | Effect |
|---|---|
| `LARECOMP_DEVLOG=<subjects>` | Writes the developer log to `logs/devlog.txt` in the data folder: warnings only, so the file stays empty while all is well. Subjects are separated by commas, or `all`. The Developer tab has the same switch for every subject. |
| `LARECOMP_PERF_LOG=<n>` | A `[perf] frame N cpu X gpu Y` line in the log every `n` frames: the smoothed CPU and GPU time that the F3 overlay shows. See [the development guide](development.md). |
| `LARECOMP_UNCAPPED_FPS=0\|1` | Benchmark mode: no frame rate limit, the game's own speed is left alone. `0` forces it off even when the Developer tab has it on. Never on while Lumiose Online is loaded. |
