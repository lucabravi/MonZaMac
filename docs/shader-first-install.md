# First-install shader preparation (local, partial-coverage prototype)

A player can now prepare **catalog-covered** graphics/XFB pipelines from their
own installed game files before encountering them. The consumer does not need
a recorded play-through, an input index, translated MSL, or another player's
shader/pipeline cache. This does not enumerate every pipeline in the game.

## Player flow

A build containing a compatible `shader-catalog.json` and the complete `lasgen`
helper offers **Graphics > Prepare known shaders**, off by default. On the next
game start it:

1. Checks the catalog and the installed executable fingerprints.
2. Reads only referenced NSO images and compressed archive spans from the
   player's files, decodes shared blocks once, and verifies all SHA-256 hashes.
3. Publishes a private, content-addressed generation under
   `cache/shader-preparation/<catalog SHA-256>/`, then updates `current.json`.
4. Translates and compiles the covered pipelines locally using a worker pool sized to active CPUs
   (and bounded by the number of program groups), showing progress for input verification and pipeline preparation.
5. Starts normal rendering. Unknown variants retain normal first-use behavior.

No Rust/Python installation or network access is needed on the player's machine:
the existing standalone `lasgen` includes reconstruction code/LZ4, and its
adjacent `monzamac-shader-decode` executable decodes archive blocks natively.
The helper process has a 120-second runtime deadline and is terminated on
shutdown. Each decoder invocation has a 30-second deadline and 128 MiB input/
output bounds. Existing generations are reused only after their metadata,
source identities and shader hashes have been checked. Corrupt generations
cause safe fallback; delete the reported generation to rebuild it. Interrupted
staging directories are not published; unfinished extraction is not resumed.

Missing/incompatible catalogs, unavailable tools and reconstruction failures
fall back to ordinary compilation. Details are in
`cache/shader-preparation/prepare.log`. There is no Skip button yet.

## Developer/catalog preparation

Catalogs are generated artifacts; keep them under ignored `build/`, never
commit them. The schema-v2 exporter interns shared numeric profiles and permits only hashes, fixed source paths, offsets,
lengths and numeric render state. It strips archive names and rejects unknown
fields. Native compiled data, shader bytes and translated MSL are not included.
This structural check is not a comprehensive legal assessment.

```sh
# Source index and developer recordings remain private. Use the native decoder
# with shader_inputs.py --ooz-exe when building an index.
tools/venv/bin/python tools/lasgen_main.py shader-catalog export \
    build/recorded-recipes.jsonl build/shader-inputs/index.json \
    build/shader-catalog.json --allow-partial

# Explicit --allow-partial is required to omit recipes with unresolved inputs.
# The omitted count remains in the catalog; it does not imply full coverage.
make gen-helper  # use gmake on macOS; Rust/Cargo is a developer dependency
build/helper/lasgen/lasgen shader-catalog check --for-distribution build/shader-catalog.json

# Optional inclusion; bundling validates the catalog before copying it.
SHADER_CATALOG="$PWD/build/shader-catalog.json" gmake app
```

A source checkout can use `LARECOMP_SHADER_CATALOG=<catalog>` with
`prepare_shaders = 1`. The existing direct `LARECOMP_SHADER_PREP` and
`LARECOMP_SHADER_INPUTS` developer overrides retain their behavior. A catalog
may also be installed at `cache/shader-preparation/catalog.json`; the bundled
resource takes precedence. Catalog replacement selects a new immutable
cache generation. Native binaries are rebuilt on the consumer's GPU/macOS.

## Evidence, 2026-11-01

- Strict catalog export: 147 complete recipes referencing 146 inputs, with two
  uncovered recipes explicitly omitted from the original 149-recipe sample.
  The generated metadata-only file is about 240 KiB; no catalog was published.
- Native ARM64 decoder reconstructed and hash-verified all 146 references from
  the installed game files, without copying the existing private shader index
  or input cache. Its deployment target was inspected as macOS 11.0.
- One bounded clean-data-root app run used the opt-in setting, a catalog next
  to the runtime, and the bundled standalone helper. No direct preparation or
  input-directory environment overrides were used. A copied station save was
  used only to select the test scene, not as a source of shader recipes.
- The run reconstructed inputs, prepared 113 program variants and 147 PSOs in
  9,577 ms of native preparation, then reached the station. Exit logs reported
  115 program-variant reuse events and 182 prepared-pipeline lookup events;
  these are event counts, not unique variants. The test process was stopped.
- 88 Metal Validation tests passed. Seven synthetic catalog tests cover clean
  reconstruction, reuse, incomplete coverage, strict fields/paths/ranges,
  source/hash failure, corrupted cached metadata and required NSO identity.
  Three existing synthetic index tests and native decoder positive/negative
  protocol checks passed. Review caught two cache validation gaps, both fixed.
- Portable JSON may represent boolean values as 0/1: pipeline state is
  canonicalized through the native descriptor before computing reuse keys.
  The focused renderer regression covers this representation difference.

## Still required before distribution

- Broader graphics recipe coverage and compute preparation. The two omitted
  recipes/four unresolved inputs can still compile at first encounter.
- Decoder notice packaging is implemented: original dependency notices and Rust
  library notices are collected and verified by the build. oozextract explicitly
  declares MIT; its missing standalone LICENSE file is not treated as a ban on
  use. See `tools/shader_decode/README.md`. No helper/catalog has been published.
- Full signed/release-bundle validation, older macOS/other Apple chips,
  fresh gameplay beyond the station, and update/rollback UX testing. The
  standalone helper and packaged resource lookup were tested, not a new DMG.
- User approval before any push or PR update. This implementation remains local.

## Catalog minimization follow-up

The current exporter writes schema v2 with shared vertex, fragment and pipeline
profiles; v1 remains readable for existing private generations but cannot pass
the packaging check. The 147-recipe station catalog retains 146 input references
with 3 vertex profiles, 9 fragment profiles and 63 pipeline descriptors. Its
serialized size is 128,118 bytes versus the original 241,960 bytes (47.0% less).
The covered recipe count is unchanged; the two unresolved recipes stay omitted.

See [catalog content/publication policy](shader-catalog-policy.md) for the exact
metadata boundary and private-cache exclusions. The normalization is limited
to inactive blending/absent-target fields and preserves active state. Neither
profiling/deduplication nor a successful schema check establishes legal approval.

The v2 follow-up passed 11 synthetic catalog regressions and 88 native Metal
Validation cases, including inactive-state equivalence, active-state separation,
and prepared green-pixel rendering/reuse. A single bounded fresh-root app check
used the standalone helper and the v2 resource: all 146 inputs were reconstructed,
113 program variants and 147 pipelines prepared in 3,052 ms, and the station
rendered with 115 program reuse and 182 pipeline lookup events. Compiler entry
points were salted for this smoke test; no performance comparison is claimed.
The packaging check accepted v2 and rejected the legacy v1 catalog. Source review
reported no actionable P1/P2 issues. All changes remain local and unpublished.
