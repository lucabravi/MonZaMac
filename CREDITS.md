# Credits and third-party components

MonZaMac is a fork of **[PokeZ-ARecomp](https://github.com/Hexveil404/PokeZ-ARecomp)** (branch `pokemon-za`) by
**[Hexveil404](https://github.com/Hexveil404)**, who ported **[LAS Recomp](https://github.com/peiikai/LASRecomp)** to
Pokémon Legends: Z-A. LAS Recomp, by **[Peiikai](https://github.com/peiikai)**, is a static recompilation of
*The Legend of Zelda: Link's Awakening*; the recompiler, the runtime and the NVN/Maxwell shader work come from it. The
list below is inherited from LAS Recomp: it names everyone who contributed to it. Components that only the Zelda randomizer or the Windows / Linux builds used are no longer part of
MonZaMac and are not listed.

**Contributors** - thank you to everyone who has sent code (GitHub handles, in order of first contribution):
- **[@dvilelaf](https://github.com/dvilelaf)** - the System language setting (#15), packaging fix for the game code
  generator helper (#10), and the task forwarder fix for the level-transition crash (#34, issue #19)
- **[@Tensorlong](https://github.com/Tensorlong)** - Metal half-precision fix for the white Link on M1 Macs (#18)
- **[@mansarip](https://github.com/mansarip)** - support for unrecognised controllers through a simple mapping file (#26)
- **[@we11adam](https://github.com/we11adam)** - shared fonts served per language instead of one Japanese font (#27),
  and the zh-Hans / zh-Hant codes for Chinese (#25)
- **[@Maganra](https://github.com/Maganra)** - Linux page write tracking (userfaultfd + PAGEMAP_SCAN) for the Vulkan
  vertex cache and texture checks (#42)
- **[@hjqcan](https://github.com/hjqcan)** - centralized game patch and runtime addresses (#57); CRLF settings
  parsing and Traditional Chinese locale detection (#53); Windows game thread stacks reserved instead of committed,
  about 9 GB less memory committed (#107); the Vulkan fence fix for reused submission slots (#108); x86 rounding
  without x87 state changes (#115); movie memory freed on close, source change and reboot (#112); Vulkan stopping
  cleanly on GPU timeouts (#127); a strict Vulkan validation mode for automated tests (#128); Windows session logs: `lasrecomp.log` always the latest run, with five backups (#114); resumable game-code builds: a cancelled or interrupted setup picks up where it stopped (#56); randomizer check flags kept with committed saves (#170); save write fixes that keep a failed save from losing data (#169, merged in #182)
- **[@gitarre1234rr5](https://github.com/gitarre1234rr5)** - controller rumble: the game's vibration on your controller
  (#104), and a regression test for the kernel's timed condition-variable wait (#88)
- **[@rkammoun](https://github.com/rkammoun)** - diagnosed and patched the Metal 16-sampler limit behind the black walls in the Ukuku Prairie cave (#215, fixed in #216)

Thanks also to everyone who reports issues and tests builds; your logs and screenshots find most of the bugs.

**Libraries and tools**
- [nstool](https://github.com/jakcron/nstool) - local extraction of user-provided game packages (MIT), pinned to
  `cfb826ca6c165fbcd816fd7949df88ef3d72a948`. The app includes its license and the licenses of its static dependencies:
  libpietendo and libtoolchain (MIT), fmt (MIT), LZ4 (BSD), and mbedTLS (Apache 2.0).
- [SDL 3](https://libsdl.org) - windowing, input, audio (zlib license)
- [FFmpeg](https://ffmpeg.org) - movie playback (LGPL)
- [Dear ImGui](https://github.com/ocornut/imgui) - overlay menu and start screen (MIT)
- [Baloo 2](https://github.com/EkType/Baloo2) by Ek Type - the start screen's font (SIL Open Font License 1.1, `third_party/fonts/Baloo2/OFL.txt`)
- [SMAA](https://github.com/iryoku/smaa) by Jorge Jimenez, Jose I. Echevarria, Belen Masia, Fernando Navarro and Diego
  Gutierrez - the anti-aliasing option (MIT, `third_party/smaa/LICENSE.txt`)
- [PyInstaller](https://pyinstaller.org) - packs the game code generator into a standalone helper (GPL 2.0+ with the
  bootloader exception, which allows distributing the packed program)
- [Zig](https://ziglang.org) - its C compiler (`zig cc`: Clang and LLD) builds the game code on the player's
  machine during setup (MIT; LLVM, Clang, LLD: Apache 2.0 with LLVM exceptions)
- The helper bundles CPython (PSF License),
  [Capstone](https://www.capstone-engine.org) (BSD 3-clause; disassembly), [Unicorn](https://www.unicorn-engine.org)
  (GPL 2.0; Python bindings BSD; runs small pieces of code to resolve jump tables) and
  [python-lz4](https://github.com/python-lz4/python-lz4) (BSD 3-clause, with the LZ4 library: BSD 2-clause)
- [envytools](https://github.com/envytools/envytools) - NVIDIA GPU documentation used for the shader translator
- **Dusklight** by the TwilitRealm team (https://github.com/TwilitRealm/dusklight) - design inspiration for the start
  screen (Play / Settings / Game Files layout)
- The Switch homebrew community's documentation ([Switchbrew](https://switchbrew.org))


## Legal

MonZaMac is a fan project. It is not affiliated with, endorsed by or sponsored by Nintendo, Game Freak or The Pokémon
Company. *Pokémon* and *Pokémon Legends: Z-A* are trademarks of their owners. No game files, game code, assets or fonts
are included in this repository. You must provide your own legally obtained copy of the game to play.

## License

The code of MonZaMac and of LAS Recomp, which it forks (the recompiler tools, the runtime, the renderer), is open
source under the [MIT License](LICENSE). Third-party components keep their own licenses: Dear ImGui (MIT), SMAA (MIT),
the Baloo 2 font (SIL OFL 1.1), SDL 3 (zlib), FFmpeg (LGPL 2.1+, linked dynamically), the Zig compiler (MIT; its LLVM /
Clang / LLD: Apache 2.0 with LLVM exceptions; its C library headers keep their own licenses), and the libraries bundled
in the game code generator helper listed under Credits (Unicorn is under the GPL: the helper is a separate program the
app runs, and its sources are this repository plus those projects' published sources). The license covers this project's
code only - it grants nothing for Nintendo's game, which you must supply yourself.

### Components of the app bundle

`make app` / `make dmg` (macOS) package these; MonZaMac itself is built from source and publishes no binaries.

| Component | Version | License | Source |
|---|---|---|---|
| nstool (game-package import) | cfb826ca6c165fbcd816fd7949df88ef3d72a948 | MIT; dependency licenses included in the bundle | https://github.com/jakcron/nstool/tree/cfb826ca6c165fbcd816fd7949df88ef3d72a948 |
| PyInstaller (packs the game code generator) | 6.22.3 | GPL 2.0+ with bootloader exception | https://github.com/pyinstaller/pyinstaller/releases/tag/v6.22.3 |
| CPython (game code generator) | 3.12.14 | PSF | https://github.com/python/cpython/releases/tag/v3.12.14 |
| Zig (builds the game code during setup; includes LLVM, Clang, LLD) | 0.17.0 | MIT; LLVM: Apache 2.0 with LLVM exceptions | https://ziglang.org/download/0.17.0/zig-0.17.0.tar.xz |
| Capstone (game code generator) | 5.0.9 | BSD 3-clause | https://pypi.org/project/capstone/5.0.9/ |
| Unicorn (game code generator) | 2.1.4 | GPL 2.0 (Python bindings: BSD) | https://pypi.org/project/unicorn/2.1.4/, https://github.com/unicorn-engine/unicorn |
| python-lz4 (game code generator; includes LZ4) | 4.4.5 | BSD 3-clause; LZ4: BSD 2-clause | https://pypi.org/project/lz4/4.4.5/ |
| FFmpeg (LGPL configuration) | 9.0.2 | LGPL 2.1+ | https://ffmpeg.org/releases/ |
| SDL 3 | 3.4.18 | zlib | https://github.com/libsdl-org/SDL/releases/tag/release-3.4.18 |
| Baloo 2 font (SemiBold) | 1.640 | SIL OFL 1.1 | https://github.com/EkType/Baloo2 |
| SMAA (shader and lookup textures, built in) | 2013 (repository master) | MIT | https://github.com/iryoku/smaa |

The build script that fetches and builds these (with checksums) is `tools/build_deps_macos.sh`.
