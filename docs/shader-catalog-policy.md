# Shader catalog content and publication policy

This policy minimizes what the project packages. It is a technical boundary,
not a copyright opinion or a guarantee against claims.

## Separate metadata from private caches

| Artifact | Treatment |
| --- | --- |
| Schema-v2 catalog | Candidate for reviewed distribution: source hashes, fixed source paths, offsets/lengths, shader identifiers and shared numeric specialization/pipeline profiles only. |
| Validated `shader-recipes` contribution JSON | Candidate for voluntary manual sharing: shared numeric profiles and shader hashes, no source locators or code. Validate/resolve against the maintainer’s private index before adding it to a catalog. |
| Recorded recipes / schema-v1 catalogs | Local developer inputs; convert through the strict exporter before packaging. |
| Reconstructed shader `.bin` inputs | Private, generated from the player's own files; never attach or bundle. |
| Translated MSL, SPIR-V, metallibs, `pipelines.bin` | Private generated caches; never substitute these for a catalog. |
| Game archives, executables, assets, text, keys | Never include in a catalog, repository, contribution or release. |

The source repository contains tools and synthetic fixtures. Generated catalogs
remain under ignored `build/` until their exact contents and publication are
explicitly reviewed/authorized. Local discovery and voluntary export are implemented; no automatic contribution upload is implemented.

## Minimize and validate

The v2 exporter interns shared vertex/fragment keys and pipeline descriptors.
Recipes reference profiles using bounded numeric IDs. It removes archive entry
names and unrelated source-index information. Only fixed NSO/Trinity source
paths and hashes/offsets needed for local reconstruction survive.

Both export and loading reject unknown fields, free-form strings, invalid hash
syntax, unsupported paths, out-of-bounds IDs, duplicate or unused profiles,
and excessive sizes. The bundle script requires
`shader-catalog check --for-distribution`, which accepts v2 only. This command
checks the metadata schema; it does not approve the copyright/license status.

Normalization is conservative: blend factors/operations are omitted when
blending is disabled; write masks and blend state of absent colour targets
are omitted. Active blend state, layouts, specialization, sample count, depth
and all other effective state remain distinct. Native lookup uses the same
normalization; no shader is substituted with an approximately similar shader.

Each recipient reconstructs code from their own files. Executable identity,
compressed span hashes, decoded shader hashes, stage and constant boundaries
are checked before use. No catalog embeds code, decryption keys or commands
to execute. The trusted application chooses the decoder/helper; the catalog
cannot choose an executable. Failures fall back to ordinary rendering.

## Before a release

- Run the schema/distribution check on the exact catalog being packaged.
- Confirm the bundle contains neither an input cache nor translated/compiled
  game shaders. Inspect helper resources as well as the top-level archive.
- Record supported source fingerprints and measured coverage; do not present
  the station's catalog as complete game-wide coverage.
- Review dependency license/provenance and required notices independently.
  Decoder notices are collected separately by the build; catalog schema
  validation does not substitute for the notice inventory or a legal opinion.
- Obtain publication approval. No source change here authorizes a push or
  inclusion of a generated catalog by itself.
