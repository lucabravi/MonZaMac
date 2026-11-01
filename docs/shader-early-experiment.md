# Early registration compilation

Early compilation is **on by default** (`early_shaders = 1` when the setting is missing). **Shaders > Compile shaders
early** turns it off for new jobs (`LARECOMP_SHADER_EARLY=1` forces it on, `=0` off); existing compiled results remain
reusable.

## Cold-cache station walk (current)

Four configurations on an M5 at 1.5x / 30 fps, shader waiting enabled, a copy of the Stazione save, a catalog of 580
recipes installed, a fresh data root, salted shader names, no pipeline archive or warm-up, and the user-wide Metal library
cache cleared before every run; the route presses A at frame 300 and walks forward from frame 750 for 210 frames. Two rounds,
the same result both times:

| Configuration | Worst frame, load (frames 0-750) | Walk (750-1110): compiles, worst frame |
| --- | ---: | ---: |
| Nothing on | 8165 / 7930 ms | 13, 57 ms |
| Early compilation | 1448 / 1412 ms | 0, 38 / 44 ms |
| Startup preparation (5.6-5.7 s before the game) | 357 / 267 ms | 0, 39 / 38 ms |
| Both | 304 / 265 ms | 0, 39 / 38 ms |

With both on, early has nothing left to do (the preparation covered it). The "compile" time the log reports for early runs
is the summed time of parallel workers, not a stall. An earlier single run showed 430 ms for early compilation, but the
Metal cache had been warmed by another test: the cleared-cache figure above is the one to trust.

## Earlier experiment notes

At app launch the renderer reads the installed metadata catalog (downloaded
base first, then bundled base) and independent local recipe journal. It uses
known graphics variants only; unknown specializations retain ordinary first-use
compilation. Unresolved file origins do not prevent early compilation when a
known recipe's exact shader inputs are later registered by the game. No manual
recipe path is required and no network request is made by this feature.

Selected code/constants are copied with checked guest-memory reads. Translation
and publication stay on the renderer thread. Utility-priority native workers
are limited by active CPUs and unique available program groups. The existing
full identity (content, memory window, specialization, descriptor) governs live
reuse. Already prepared/live variants are skipped. In-flight exact identities
are shared with live draws: waiting publishes completed program/PSO results
without starting translation; asynchronous draws retain normal skip behavior.
Failed speculative entries are cleared so ordinary first-use compilation can
retry. Reset joins workers before dropping input snapshots and renderer state.

Bounds are at most two input hashes per recipe (no recipe count limit), 16 MiB
per input/metadata file and 32 MiB retained input bytes. Additional/new input
registration wakes scheduling; an idle scheduler does not rescan recipes.
Metadata is read once per app launch. Shader overrides disable the early path.
`LARECOMP_SHADER_EARLY=0` forces it off, `LARECOMP_SHADER_EARLY_WORKERS=1`
selects serial native work, and `LARECOMP_SHADER_EARLY_RECIPES=/path/file.jsonl`
is an optional developer override. All inputs and native artifacts stay local.

## Apple M5 experiment, 2026-11-01

One completed off/on pair used the same station save copy, fixed 1.5x and 30 fps,
empty private application caches, shader waiting enabled, catalog preparation
and source warming disabled, and distinct Metal entry-point salts. The salts
reduce cache reuse; they do not flush the OS shader cache. Both runs used the
visible game and `tools/hang_sample.sh`, A at frame 300, forward movement from
750 for 210 frames, screenshot/exit at 1100, and external 90-second deadlines.
Primary saves, settings and caches were untouched. No test process remains.

The metadata selected only the two programs comprising the four unresolved
station input hashes. These were learned in an earlier private recording;
this is not evidence of cold coverage for arbitrary unobserved variants.

| Measurement | Off | On |
| --- | ---: | ---: |
| Target program construction completion frames | 410 / 410 | 355 / 357 |
| Target native program compilation | 46.52 / 45.28 ms, first use | 76.84 / 48.22 ms, background |
| Registration to complete program + PSO | — | 123.60 / 198.09 ms |
| Target early live program hits | 0 | 2 |
| Logged synchronous pipeline builds, frames 300–1100 | 117 | 115 |
| Walk compilation latency | 46.37 ms | 45.92 ms |
| Walk maximum sampled present gap | 63 ms | 63 ms |
| Scene-entry maximum sampled present gap | 6,803 ms | 6,672 ms |

Both target programs were identified across runs by their translated-source
hash pairs, not unstable guest addresses. Their native compilation and both
PSO builds moved ahead of their first live rendering use. The worker's native
latencies increased under concurrent game work; moving work is the result,
not making the compiler faster. About 92 ms of the off run's program work was
removed from first use. The 131 ms difference in the entire scene-entry gap
is a single-pair observation confounded by other compilation and scheduling,
not a repeatable overall speedup claim. The walk hitch remains unresolved.

Both final station screenshots were inspected with no obvious new rendering
defect; weather/animation differences prevent pixel equality. The focused
Metal Validation regression passed: copied inputs survive immediate overwrite,
live uploads at different addresses reuse both the program and PSO, synthetic
pixels remain green, and reset clears copied inputs after joining the worker.
The runtime built successfully. There was no additional GPU suite/scale sweep,
long-session validation, general recipe discovery or production integration.

## Separate finding to revisit

The local recipe writer can represent boolean descriptor fields as numeric
0/1, while Metal's KVC descriptor serialization produces JSON false/true.
Those are semantically equivalent but produce different raw JSON hashes. The
spike keys its PSOs from the reconstructed native descriptor, and the focused
test catches the mismatch if keyed from raw learned JSON. Audit the existing
startup preparation/import identity path separately; this experiment does not
claim that every catalog generation or existing preparation path is affected.

## Bounded concurrent native jobs

A follow-up cold private-cache pair at the same fixed 1.5x / 30 fps compared
`LARECOMP_SHADER_EARLY_WORKERS=1` with automatic concurrency. The same two
learned programs were available, so automatic sizing selected two, not ten,
workers. Logs verified peak native activity of one versus two. Original
save/settings/cache files were again untouched; both bounded runs exited.

| Measurement | One worker | Automatic (two jobs) |
| --- | ---: | ---: |
| Both programs and PSOs ready since registration | 191.12 ms | 141.93 ms |
| Both programs reused before first-use compilation | 2 | 2 |
| Maximum sampled gap during early jobs, frames 350–399 | 38 ms | 38 ms |
| Walk maximum sampled gap | 62 ms | 59 ms |
| Settled maximum sampled gap | 38 ms | 38 ms |
| Scene-entry maximum sampled gap | 6,690 ms | 6,746 ms |

The two-job batch finished about 26% sooner in this single pair. Individual
compiler jobs can take longer while running together; concurrency improved
batch completion rather than each compile's latency. Neither early variant
was late at first use in either run. The large scene-entry pause did not
improve: the selected jobs are only a small part of its work. These capped
short runs do not establish uncapped overhead, other-chip behavior or the
best worker count for a larger catalog.

The Metal Validation synthetic test still verifies overwritten guest inputs,
exact program/PSO reuse at a different live address, green pixels and reset
joining workers. It now also checks CPU/job sizing and aliases in learned
metadata: two records resolving to the same mutable native program must
submit only one compiler job. The automatic-run final station screenshot
was inspected without an obvious new defect. No further in-game sweeps were
performed. This remains local, explicitly enabled experimental functionality.

## Verification with it on

With `early_shaders = 1` and no `LARECOMP_SHADER_EARLY*` environment variables,
a cold private 1.5x / 30 fps station run discovered installed catalog recipes
plus a copied local journal. With startup preparation enabled, 192 programs /
292 pipelines were prepared and only the two remaining uncatalogued known
programs were queued early; both were reused. Without startup preparation,
143 native program jobs completed with peak concurrency 10 and 83 unique early
program hits (91 content-variant reuse events and 119 pipeline lookups overall).
Both runs reached the recorded station destination and exited after frame 1100.
These are functional coverage observations, not an isolated performance A/B.

The focused Metal Validation regression covers on and force-off,
v2 profile/local normalization, copied input lifetime, alias deduplication,
already-built skip, live PSO pixels, and reset. It now suspends the native queue,
requests the actual live identity before compilation starts, verifies reuse of
the same pending object, then resumes and checks synchronous publication without
a frame-boundary deadlock. Review identified that in-flight gap before the
change; it was fixed and re-reviewed with no further P1/P2 findings.
