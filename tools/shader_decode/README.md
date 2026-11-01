# Shader block decoder

This is a bounded, offline subprocess used by the shader catalog helper. It
accepts an eight-byte little-endian decoded length followed by a compressed
block, and creates a new output file. Input and output are limited to 128 MiB;
the caller verifies both the compressed block and every reconstructed shader
with SHA-256. No Nintendo bytes or decoder library are bundled here.

Build: `CARGO_TARGET_DIR=build/shader-decode cargo build --locked --release
--manifest-path tools/shader_decode/Cargo.toml`. Rust/Cargo is a developer
build dependency; players receive the native binary inside `lasgen/` and do
not install Rust or Python. `make gen-helper` builds and copies it. The
macOS helper must target the release's minimum OS and architecture.

The dependency is pinned to published `oozextract` 0.5.7 and Cargo.lock checksums.
The upstream package and repository manifest explicitly declare MIT. Cargo's
`license` field is a license declaration; a separate LICENSE file is not required
for that declaration. The crate supplies no separate copyright notice, so
`licenses/oozextract-MIT.txt` attributes the project, preserves that fact and
includes the standard MIT permission/disclaimer without inventing an author/year.

`make gen-helper` collects original notices for the crates used by the actual
build, verifies their registry archive checksums against Cargo.lock, and includes
Rust standard-library copyright information. It retains the Unicode-3.0 notice
required by unicode-ident, as well as the supplied MIT/Apache/Zlib alternatives.
The notice bundle is `lasgen/shader-decoder-licenses/` in the app resources; the
app packager verifies the inventory and refuses missing/modified/extra files.
The generator works offline from Cargo's build/cache; no uploads are performed.
Unknown license expressions or missing required notices fail the build for review.

Tests: `python3 tools/test_shader_decoder_notices.py`. The explicit declaration
and supplied notices are packaging evidence, not a comprehensive legal opinion
on every upstream source. References:
- https://doc.rust-lang.org/cargo/reference/manifest.html#the-license-and-license-file-fields
- https://github.com/lvlvllvlvllvlvl/oozextract

`python3 tools/test_shader_decoder.py <binary>` checks a synthetic raw block,
exclusive output creation, and malformed/oversized input rejection.
