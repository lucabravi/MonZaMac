<p align="center">
  <img src="docs/icon/icon_1024.png" alt="MonZaMac icon" width="168">
</p>

<h1 align="center">MonZaMac</h1>

<p align="center">
  <strong>Pokémon Legends: Z-A, natively on your Mac</strong><br>
  Apple Silicon &middot; Metal &middot; no emulator
</p>

<p align="center">
  <a href="https://github.com/lucabravi/MonZaMac/releases/latest"><img alt="Latest release" src="https://img.shields.io/github/v/release/lucabravi/MonZaMac?display_name=tag&color=d9993a"></a>
  <img alt="Platform: macOS 15+, Apple Silicon" src="https://img.shields.io/badge/macOS-15%2B%20%C2%B7%20Apple%20Silicon-3a2377">
  <a href="LICENSE"><img alt="License: MIT" src="https://img.shields.io/badge/license-MIT-c2528f"></a>
</p>

<p align="center">
  <a href="#download-and-play">Download</a> &middot;
  <a href="#status">Status</a> &middot;
  <a href="#building-from-source">Build</a> &middot;
  <a href="CHANGELOG.md">Changelog</a> &middot;
  <a href="https://github.com/lucabravi/MonZaMac/issues">Issues</a> &middot;
  <a href="https://github.com/Hexveil404/PokeZ-ARecomp">ZA Recomp (PC)</a>
</p>

---

<p align="center">
  <img src="docs/screenshots/start-screen.png" alt="The MonZaMac start screen: the most recent save, and CONTINUE, NEW GAME, SAVES, SETTINGS and QUIT" width="380">
</p>

A native macOS port of **Pokémon Legends: Z-A** (Nintendo Switch, v2.0.2 + the Mega Dimension DLC) built by **static
recompilation**: the game's ARM64 code is translated ahead of time into C and compiled for the Mac, and the Switch's
operating system and GPU (NVN) are reimplemented in the runtime. No emulator runs at play time.

- A Metal renderer with internal resolutions from 25% up to 4x (1080p), SMAA and MetalFX upscaling, and a dynamic
  resolution that follows your GPU
- About **60 fps in the open world on an Apple M5 at 2880x1620** (1.5x), with SMAA and anisotropic filtering on
  (the maintainer's measurement; other chips and scenes differ)
- 30 fps or 60 fps; docked or handheld mode
- Keyboard and controller, the game's own menus and your saves, with several save slots to pick from
- A guided setup: point the app at your own game files and it prepares everything on your Mac

> **You need your own copy of the game.** No game files, code, assets or fonts are included in this repository.

## Download and play

You need a Mac with Apple Silicon (macOS 15 or later) and **your own copy of the game** (see above).

1. Download `MonZaMac-<version>-macOS.dmg` from the [latest release](https://github.com/lucabravi/MonZaMac/releases/latest).
2. Open it and drag **MonZaMac** onto **Applications**.
3. Open MonZaMac. The app is not notarized by Apple, so the first time macOS may refuse: right-click the app, choose
   **Open**, then **Open** again.
4. On the start screen choose **SET UP GAME FILES** and confirm that you own an original copy. Select your base game
   (**NSP or XCI**), the **v2.0.2 update (NSP)** and your **prod.keys**. The app checks them, applies the update and
   builds the game on your Mac: it takes a while and needs about 25 GB of free space. Nothing is uploaded.
5. When it is done, press **CONTINUE** (your most recent save) or **NEW GAME**. Your saves and settings are kept in
   `~/Library/Application Support/com.monzamac.app`, and stay there when you update the app.

**Saves.** The start screen shows the save you played last. **SAVES** lists them all: pick one, start a new one, copy
(a handy backup before trying something), rename or delete. A save you already had is the first one in the list, called "Main save" until you rename it.

A new install starts with fullscreen, dynamic resolution, 60 fps, SMAA, the original 16:9 picture and sharper textures
(anisotropic filtering); all of it is in **SETTINGS**, on the start screen too.

In the game: **F1** opens the menu (video, audio, controls), **F3** shows the frame rate and the render resolution.
Keyboard: WASD move, arrows d-pad, Enter = A, Backspace = B, K = talk, Q / E = L / R; a controller works too.
The first start after an update recompiles some shaders and may stutter for a moment.

Building from source and the developer tools are in [docs/development.md](docs/development.md).

## Status

**Playable.** The game runs from the intro through the first part of the story, with battles, menus and saves, and
the maintainer has played it that far without problems. It is still a work in progress: later areas and other Macs
have had less testing, so please report what you find.

On an Apple M5 at 2880x1620 (1.5x, SMAA and anisotropic filtering on) the open world runs at about 60 fps, with small dips
in busy animated scenes.

Looking for the Windows version? It's available at **[PokeZ-ARecomp](https://github.com/Hexveil404/PokeZ-ARecomp)** by
**Hexveil404**.

Working:
- Rendering on Metal: environment, walls, characters (GPU skinning through transform feedback), lighting, GPU-driven
  culling (indirect draws), text, dialogue and UI
- Audio, the game's menus, saves
- Controller and keyboard input

**Known issues:** No evident issues are currently known from the maintainer’s testing.

Bugs and questions: [GitHub issues](https://github.com/lucabravi/MonZaMac/issues), see [CONTRIBUTING.md](CONTRIBUTING.md).

## Building from source

For developers: the build steps, game-file extraction, packaging the app and the developer tools are in
[docs/development.md](docs/development.md).

## Credits and license

MonZaMac is a fork of **[PokeZ-ARecomp](https://github.com/Hexveil404/PokeZ-ARecomp)** (branch `pokemon-za`) by
**Hexveil404**, the Pokémon Legends: Z-A port of **[LAS Recomp](https://github.com/peiikai/LASRecomp)** by **Peiikai**,
whose recompiler, runtime and NVN/Maxwell shader work it builds on (made for *The Legend of Zelda: Link's Awakening*).
Contributors and third-party components are listed in [CREDITS.md](CREDITS.md).

The code is under the [MIT License](LICENSE) (LAS Recomp © Peiikai; the Z-A port and MonZaMac's additions under the same license). This is a fan
project, not affiliated with, endorsed by or sponsored by Nintendo, Game Freak or The Pokémon Company.
