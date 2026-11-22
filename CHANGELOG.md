# Changelog

Versions follow `v<major>.<minor>.<patch>` (0.x until a stable 1.0). The version shows on the start screen and in
the in-game menu; the start screen also offers a newer release from GitHub when there is one.

## Unreleased

### Lumiose Online
- **Chat messages are no longer cut to 8 characters.** The mod opens the keyboard with no maximum, which MonZaMac read as 8; each field now takes its own length: 120 bytes for the chat (an accented letter counts 2), 200 for a Mail message, 60 for the friend status, 32 for a Mystery Gift code, 24 for the Market search, Mail recipient, guild and outfit names, 8 for prices and money. The keyboard shows the field's own title ("Chat", "Pokémon name"...) instead of "Enter your name". Cancelling it closes it: in the Market's filters it opened again at once, round and round (the button that closed it reached the game).
- **The Market's Pokémon pictures are sharp.** The mod asks the launcher for the game's own 160 px picture of each Pokémon and enlarged its 32 px icon when there was none. MonZaMac now makes those pictures from your game files once (about a minute in the background on the first start, 35 MB) and hands them over, shiny looks included.

## 0.4.5

A new look for Lumiose Online on the start screen. No game code rebuild and no shader preparation are needed.

### Start screen
- **Lumiose Online's column has the Lumiose Online art**, its logo as the title; the button and the online loading ball are in the logo's green. The state shows inside the trainer card: a green check by the team when the service is ready (its words on hover), the message in place of the team while preparing or after an error, so the column no longer moves when you press Play online. The team's levels read "Lv. 9".

## 0.4.4

Button icons for the keyboard, Xbox and PlayStation controllers, and two fixes for Lumiose Online. **The first start after updating builds the game code again** (a few minutes, once): the tools that make it changed. Play online then prepares the online version again too. No shader preparation is needed.

### Controls
- **Button icons now follow your controller:** keyboard keys, Xbox (A B X Y, LB RB LT RT, Menu View) or PlayStation (cross circle square triangle, L1 R1 L2 R2, Options Share), chosen in F1 > Controls > Button icons (Auto follows the controller, and shows the keys when none is connected). Before, that setting did nothing on a new installation. The icons are drawn from your own game files once, at the setup or the next time the start screen opens (about a minute, in the background), and drawn again after you change a binding, so each icon names the key or button you press. They cover the HUD, the menus' key guides and the icons inside the game's text. A change in F1 shows at once on the HUD and in the menus; the icons inside text follow at the next start.

### Lumiose Online
- The start-up check of a new online version runs hidden again. Since 0.4.2 it plays an empty online save of its own, and its window showed what looked like a new game; closing it made the preparation fail with "the game exited".
- The current online module (from 17 November) locks its decimal conversions again through a shared lock function, which the preparation no longer recognized, so MonZaMac added its own lock on top. Two locks taken in opposite orders could hang the game. The preparation now recognizes the new form and leaves its own lock off.

## 0.4.3

The 0.4.2 disk images shipped without its Lumiose Online fix. This release carries it. No shader preparation is needed.

### Lumiose Online
- **Play online works for players with no online save yet** (new players, or players who only played offline). 0.4.2 described this fix, but its app still held the previous online helper, so the start screen kept saying "not activated, the start-up log reports an error".

## 0.4.2

A fix for Play online with no online save yet, and smoother controller moves on the start screen. No shader preparation is needed.

### Start screen
- With a controller, Down from **CONTINUE** goes to **NEW GAME** and Right goes to **PLAY ONLINE** (Down used to jump to PLAY ONLINE).
- In Settings, switching tabs with L1/R1 while the cursor is on a row no longer moves the cursor up to the MonZaMac logo: it goes to the new tab (the in-game menu too).

### Lumiose Online
- **Play online works again for players with no online save yet** (new players, or players who only played offline). In 0.4.1 the hidden start-up check that runs before a new online version is used stopped at once on the save-kind check, so the start screen said "not activated, the start-up log reports an error". The check now plays a fresh online save of its own, in a scratch folder.

### Developer tools
- The translation table (`i18n/translations.tsv`) no longer holds 31 sentences that the interface stopped using (for example the old help lines, the game-language prompt and the fullscreen hint), so the 11 catalogs are smaller and a translator does not spend time on text nobody sees.
- The applet test (`tools/test_am_applet.c`) builds again after 0.4.1 (it needed a stub for the game's build ID) and now also checks the game version the game is told (1.0.0, 2.0.0 or 2.0.2).

## 0.4.1

A few follow-ups to 0.4.0: a save of the wrong kind now stops the game, a GPU program built to fit is found again at the next start, and the game version that mods read follows the game files. No shader preparation is needed.

### Game
- **A save of the wrong kind now stops the game** instead of only writing a line to the log: online saves start only online, the others only offline. The start screen already kept them apart; this is the last stop behind it.
- The game version that Lumiose Online reads follows the game files (1.0.0, 2.0.0 or 2.0.2) instead of always saying 2.0.2. Nothing changes for the start screen, which accepts only 2.0.2.

### Graphics
- On Macs where a GPU program is built to fit the threads per group the game asks for (seen as a possible gap on M1 and M2), the saved copy of it is now found at the next start, so it is not compiled twice every time.

## 0.4.0

Cleaner skin and hair in some close-ups, a little more speed, a new way to install the game from a Switch 2 Edition `.nup` file, a new look for the start screen, stricter rules for Lumiose Online (one online save, original game files, the official module, the current version), and fixes. **After updating, run Prepare all shaders again** (the **All shaders** badge turns yellow): the shader translation changed. **If you play online, the first Play online asks which save is your online save.**

### Graphics
- **Close-ups of characters no longer show moving blotchy noise** on skin and hair (seen in a story cutscene with two characters and red dotted lights on the wall). The screen-space contact shadow ignored one of its conditions, so every step of its ray counted as a hit. Now it matches the Switch.
- More shaders follow the same kind of condition the contact shadow ignored: about 340 that branch after an integer compare, and about 60 fragment shaders whose early exit has such a condition (until now they always exited early). Which scenes this changes has not been seen yet.
- **Faster:** in the station walk, characters' materials and shadows use less GPU time (about 5% and 1% of the frame, 62 -> 65 and 75 -> 76 fps on an Apple M5 with the same settings). The shaders that read whether a surface faces the camera no longer run in the slow generic mode, and the smoothed shadow test reads four texels with one fetch instead of four.
- Vertex shaders are translated with the same compiler constants as the fragment shaders, so the precompiled ones match what the game asks for. This does not change the speed.
- On Macs where a GPU program cannot run as many threads per group as the game asks for (seen as a possible gap on M1 and M2), that program is now built to fit instead of being skipped without a word. Nothing changes where it already fit. A line in the log says when it happens.

### Setup
- **The start screen checks that the game files are intact.** A damaged download of the 2.0.2 update has a broken part that crashes the game when it loads, for example, a character's model. The first time (a few seconds, once for each set of game files), each part of the game's data is compared with the original version 2.0.2. If some differ, a window says how many and offers **Delete game files**, so you can set them up again with a fresh update; **Play anyway** goes on. A crash that follows is now named in the crash window, and the log lists the parts.
- **Import from a `.nup` file:** a third **Import from** choice takes one Switch 2 Edition `.nup` container made from your own dump, with the base game, the update and the add-ons already decrypted. It needs no `prod.keys` and no `nstool`. The ownership confirmation is still required. Every file is checked against its hash as it is written, and a damaged or unsafe container is refused.
- The Switch 2 Edition upgrade add-on from a `.nup` no longer makes the start screen say **DLC found**: it now looks for the Mega Dimension DLC itself, so **Add DLC...** stays available until it is installed.

### Game
- **A crash in the first Mega Dimension mission's battle is avoided.** A game function that reads a few values from an object could be called when the object was already gone (the game's threads run in another order than on the Switch), and the game closed with a memory error. It now reads zeros instead and goes on; the log says `[guard]` when this happens. `LARECOMP_NULL_GETTER=0` turns it off. Not tried in that battle yet: a test call with no object, made at the start of the game, came back with zeros and the game went on.
- **The in-game DLC purchase no longer closes the game.** The game's shop screen opens as an applet the Mac cannot show; it now ends at once as "the user backed out" and the game returns to its own menu.
- **A little less CPU work:** the game's indirect calls (virtual functions and function pointers) are answered from a bigger cache, so fewer of them search the function table. About 2% more frames per second in the station at 1x on an Apple M5 (113.5 -> 116.0, six alternating runs); it costs about 20 MB of memory. No shader preparation is needed.
- **The game now reports its real version (2.0.2) to itself and to mods.** It used to answer 1.0.0, so Lumiose Online told players their game was no longer supported even with the right files.

### Start screen
- The team on the offline card has more room: bigger balls, further apart, with the buttons lower. The Saves page follows.
- **Prepare all shaders** no longer leaves the black loading screen over the start screen when the game returns before its first frame.
- **A new look for the two columns** (online edition): Play offline and Lumiose Online are the same width, and the online column shows your online save's trainer card (trainer, ID, play time, money and team) over the picture. On the offline card the save's name is the title and the trainer's name has its own row. The Saves page lists the online save first, greyed, with an **ONLINE** tag, and the page's messages are no longer cut off at the bottom.

### Lumiose Online (online edition)
- **Play online only starts a module that matches the one Lumiose Online publishes.** A module placed in the save's `sdcard` folder (for example a cheat or debug menu installed like on a Switch) or in the downloads folder is no longer used. The check runs on every press, so online play needs the team's site to be reachable; without it, it asks you to try again. Back at the start screen, **Play online** restarts the game only when the version changed. Thanks to **DarthMDev** for this one.
- **Online saves are separate from offline ones.** Lumiose Online checks a save for anything done to it outside online play, so the first **Play online** asks which save is the online one: a **new online game** (recommended), or one of your saves, which then becomes online only (the window warns that getting around that block can get you banned). An online save is never started offline, an offline save is never started online, an online save can't be copied, and the Saves page marks it **ONLINE**. The saves you do not choose are not touched. Exporting and importing an online save is not handled yet: an import comes back as an offline save.
- **The in-game menu has no Saves tab while you play online,** and the Saves tab of an offline game no longer lists your online save: it is played only from **Play online**. An online save is named after its character and can't be renamed, copied or deleted from the app.
- **Online play waits for the update.** When a newer MonZaMac release is out, the Lumiose Online column says **Update MonZaMac first** and **Play online** stays off until you update. Without an answer from GitHub (no connection, or `LARECOMP_NO_UPDATE_CHECK`), nothing is held. A release marked as a pre-release is no longer offered as an update.
- **Online play is the same game for everyone.** While the Lumiose module is loaded, the debug and test `LARECOMP_*` variables (scripted input, route replay, warps...) are ignored; only the supported ones stay, and they come back for an offline game. **Play online** also stays off while the game data check finds files that differ from the original 2.0.2 (**Game files changed**).

### Developer tools
- `docs/environment.md` lists the ten `LARECOMP_*` environment variables that are supported (where the files are, switching off one fix to find a problem, logs and benchmarks); the rest stay debug hooks described in the code. A test fails when a name in the docs is no longer read by the code.
- The interface text goes to the drawing library as an argument, never as its format (20 places in the start screen and the menus): a translation with a stray `%` can no longer read memory. The compiler's format warnings in the renderer's logs are fixed, and git ignores `.game-setup/`.
- `gmake test-tools` runs every test in `tools/test_*.py` that needs no game files, with the project's Python. Eight of them (the settings, menu, crash window, shader trace and SIMD tests) no longer built after changes in the code they test, and the offscreen Metal renderer test ended a ring before its command buffer was submitted: all pass again.
- With `LARECOMP_DEVTOOLS=1`, the **0** key takes one complete frame dump (F9 is awkward on a Mac) and debug frames log more: sampler state, raw depth and the scene constants.
- `docs/frame-generation.md` explains the blocky patches that can appear between a character's arms and torso while the camera turns at 30 -> 60: they come from MetalFX's interpolator, not from the data MonZaMac gives it. `docs/performance-gpu.md` records the station walk's GPU profile and what was tried and dropped.

## 0.3.1

Discord status for online players, and a set of fixes.

### Lumiose Online (online edition)
- **Discord status** *(optional)*: **Settings > Show on Discord** (off until you turn it on) shows on your Discord profile that you are playing MonZaMac, through the Discord app on your Mac, with "Exploring Lumiose" and, after five minutes without input, "Relaxing in Lumiose". Nothing else is shared: no name, save or game data. Thanks to **DarthMDev** for the first version.
- When a new version of the mod is downloaded and the online version was prepared before, the start screen says **Updating the online version** (the quick one) instead of **Preparing the online version**, which stays for a first preparation.
- Online play does not load RomFS mods (`mods/<name>/romfs`), so the game is the same for every player. Offline play loads them as before.

### Graphics
- **Frame generation follows your display's current refresh rate**: with the screen set to a fixed 60 Hz, 60 -> 120 fps no longer stays on. On an adaptive (ProMotion) screen nothing changes.

### Start screen
- **Saves:** on a save with no progress, **Copy** and **Export** now look disabled and **Rename** and **Delete** stay available; the toolbar showed the state of the previous button. Disabled buttons are dimmer everywhere.

### Safety
- A damaged RomFS index, a broken mod patch file or a save name with a path in it can no longer read or write outside where it should; copying a save handles interrupted writes. The online setup trusts a downloaded mod from its cache only if its full checksum matches.

## 0.3.0

A new look for the start screen and the settings, and the app now speaks 11 languages.

### Languages
- The whole app is translated: **English, Italian, French, Spanish, German, Portuguese (Brazil), Japanese, Chinese (Simplified and Traditional), Korean and Russian**. It follows your Mac's language at first. Change it from the **flag in the top bar** or in **Settings**; the in-game menu shows the game's own language as a flag. The game still asks for its language itself, as on the Switch.
- The translations were written without native review. Corrections are welcome on GitHub.

### Start screen and settings
- One top bar for the whole app; the logo takes you back to the start screen.
- A cleaner **Play online** card with the new Lumiose banner, and a modern save card and buttons.
- **Settings**, **Saves** and the first-start screen share one style. Dialog buttons grow to fit longer texts.
- A **loading screen with a spinning Poké Ball** while the game starts. Going back to the menu no longer closes and reopens the window; only switching between the offline and the online game still does.

## 0.2.3

Ready for **Lumiose Online 1.5.2**. Recommended for everyone who plays online.

### Lumiose Online (online edition)
- **Lumiose Online 1.5.2 fixes the battle zone crash itself**, so MonZaMac now leaves its own fix off for that version and later ones. With 0.2.2 the two fixes together could, rarely, freeze the game; older versions of the mod keep MonZaMac's fix.
- The developer benchmark option **Uncapped FPS** is never active online, so the game always runs at its normal speed next to other players.
- After updating, the next **Play online** prepares the online version again (a few minutes, with a progress bar).

## 0.2.2

A fix for online play: the game no longer crashes when entering the battle zone with Lumiose Online.

### Lumiose Online (online edition)
- **Entering the battle zone no longer crashes the game.** Two parts of the mod could write numbers at the same time and get in each other's way; now they take turns. Thanks to **DarthMDev** for finding the cause and testing the fix. New versions of the mod should keep the fix without a MonZaMac update.
- After updating, the next **Play online** prepares the online version again (a few minutes, with a progress bar).

## 0.2.1

MonZaMac now also starts on macOS 27, the mouse works in online play, shadow edges are smooth in close-ups, and a set of smaller fixes. **After updating, run Prepare all shaders again** (the **All shaders** badge turns yellow): the shadows changed.

### macOS 27
- The game starts on **macOS 27**, where it used to stop right at launch. Tried on macOS 27.2.1 in a virtual machine: offline and online, with existing saves. Thanks to **DarthMDev** for reporting it and finding the cause. macOS 15 and 26 work as before.

### Mouse
- **Online play:** the cursor is visible in game, so you can click the buttons and lists of Lumiose Online. The left button works as the touch screen for the mod. When the left button also turns the camera, a click is a touch and a drag turns the camera.
- The cursor hides after **5 seconds** without moving, and comes back as soon as you move it. **Settings > Controls > Hide the idle cursor** sets the time (never, 5, 10, 30 or 60 seconds); it shows only in the online edition. A two-finger swipe on the trackpad turns the camera and does not bring the cursor back.
- **Offline play** keeps the cursor hidden in game, as before.

### Graphics
- **Smoother shadow edges** in close-ups and cutscenes: the edge of a shadow no longer shows steps.

### Start screen
- The cursor is back when you return to the start screen from a game.
- **Compile all shaders** goes back to the start screen when it finishes, is stopped or fails, instead of carrying on into a new game. While it runs, the cursor stays visible, so **Stop** can be clicked.

### Fixes
- Saves: an existing backup is kept when an export fails, an imported save is always checked, and the save cards update right after a change.
- Online preparation: a failed or stopped preparation is no longer reported as finished, folders with any character in their name work, and every download goes over a secure connection.
- Several smaller robustness fixes in file handling and in the developer tools.

## 0.2.0

A new start screen, and **Lumiose Online**: optional online play with the multiplayer mod of the same name, in a separate online edition. The offline edition is the one you know, with the new start screen. **After updating, the game code is rebuilt once on its own (a few minutes, with a progress bar), because the generator changed.**

### Start screen
- The bottom bar says whether the optional **Mega Dimension DLC** was found. The guided setup has an optional **DLC** file row (the Mega Dimension `.nsp`), and an installed game can get it later with **Add DLC...** in the bottom bar, a screen that says which two files to choose (no rebuild); `tools/extract_game.sh` takes it as a third argument; the README no longer claims the DLC is required.
- **Landscape layout:** a header across the top (logo, name, **All shaders**, **Shader catalog**, **Legal notice**, **Settings** and **Quit**), the **Play offline** column in the middle (the save card, **Continue**, **New game**, **Saves**) and a bar along the bottom with the state of the game files and the version. The shader chips moved from the bottom to the header and show their state with an icon.
- **Saves** now only chooses the save and goes back to the start screen; **Continue** and the card use the chosen save, or the most recent one.
- **Settings** outside the game fill the window under the header, with a **Back** button instead of the X and more room around the rows. The in-game menu is unchanged.
- When only the game code is out of date after an update, the **rebuild starts by itself** instead of waiting for **Update game code**.

### Lumiose Online (online edition)
- **Play online** in a second column: the first press asks for your consent (your game data is shared with Lumiose Online, a separate service run by its own team, not by MonZaMac), prepares the online version on your Mac (a few minutes, with a progress bar) and starts the game with the mod. It is available only with the game files of version 2.0.2.
- Every later press first checks for a newer module from the Lumiose Online team (a download checked against the SHA-256 they publish) and prepares it before starting. The server is the team's, `lumioseonline.site`; offline play never contacts it.
- The mod's text starts at 120% so it is less grainy at 1080p; a size you set yourself is kept.
- **Quit to start screen** from an online session restarts the program, so **Continue** there plays offline, without the mod.
- The online edition keeps the game code build (about 1.3 GB more on disk) to prepare the mod quickly; **Delete game files** removes it.
- **Microphone** for the mod's voice chat: the game can use the Mac's microphone, and macOS asks for the permission the first time. The voice itself has not been heard by another player yet.
- Not verified yet: chat text entry and delivery, play against Windows or Linux players, and every optional feature of MonZaMac together with the mod.
- A new build of the Lumiose Online module is prepared without a MonZaMac update: the app reads what it needs from the module itself. A build that works differently and does not start is not activated. An update the mod installs by itself in the game is prepared on the next **Play online**, even if the site has not got it yet.

### Audio settings
- **Microphone** section in Settings > Audio: the **input device** (the Mac's default or any microphone it finds), the **microphone volume** (0 to 200%) and a **Microphone test** with a live level bar, for the voice chat of Lumiose Online. If nothing is heard, the page says to check the permission in System Settings > Privacy & Security > Microphone.
- **Room reverb** and **Movie audio** are gone from the Audio page: the first never did anything in this game, and the second's help text still spoke of the first game this project was made from. The movies keep their sound.

### Defaults
- New installs start with the **two-finger trackpad swipe turning the camera** (Controls > Mouse). An existing `larecomp.ini` keeps its own choice. The other graphics defaults are unchanged: fullscreen, fixed 1080p, 60 fps, SMAA, MetalFX spatial upscaling, smooth distant animation, sharper textures, frame generation off.

### Fixes
- **The game code build takes about half the time** and less disk: `zig cc` was turning `-O1` into `-O2` with full debug info. It now compiles at `-O1`.
- Pressing **Esc** a few times with a controller connected could stop the app (an ImGui assertion in the menu). The menu now cancels a layer toggle it cannot finish.
- **Export and import of a save** now include the mod's folder (`sdcard`: Lumiose Online's settings and data) next to the save itself, so a backup or a move to another Mac keeps them; copying a save already did. A zip from before, or from JKSV, still imports as just the save.
- The key **0** no longer does anything: it wrote a dump of the next frame into `build/` for every player. **F9** does it only with `LARECOMP_DEVTOOLS`.

## 0.1.7

MetalFX temporal upscaling, a Video page in sections with a clearer help panel, a fix for animations flickering between two poses with smooth distant animation, and a shader translator fix. **After updating, run Prepare all shaders again.**

### Smoother
- **MetalFX temporal** (experimental, macOS 13 or later; Video > Upscaling and AA), a new Upscaler choice next to bilinear and MetalFX spatial, which also works together with frame generation (30 to 60 and 60 to 120). The game is drawn at a lower resolution and rebuilt from the frames before it; the generated frames use the same motion and depth. Measured at a 2880x1620 picture on an Apple M5 in the station walk, one run per configuration: without frame generation 82.7 fps at 1920x1080 input against 75.5 native; with 60 to 120 generation 97.4 shown fps against 84.5. Small artifacts remain at character edges and where something uncovered appears; moving foliage, particles, water and transparency, combat and older Macs have not been checked. While it is selected the other anti-aliasing and the generated-frame Performance quality are inactive, and your saved choices are kept. Defaults are unchanged.

### Menu
- **Video settings reorganized** into six sections: Display, Rendering resolution, Frame rate and generation, Upscaling and AA, Game effects, and Shadows. Rows, shortcuts, defaults and saved choices are unchanged; the same page serves the launcher and the in-game menu.
- The help of **Resolution mode** (Video > Rendering resolution) now gives both sizes when they differ: "Rendering at 2880 x 1620, shown at 3600 x 2025", the resolution the game draws and the size of the picture in the window. With MetalFX temporal this is the size it reconstructs from and to. The F3 overlay shows it too: "render 2880 x 1620 -> 3600 x 2025".
- The help text of the **Video** settings has paragraph and line breaks: one line per choice for Upscaler, Frame rate, Frame generation quality and Resolution mode, and a paragraph per idea elsewhere. No wording of the settings changes.

### Fixes
- **Smooth distant animation** no longer makes some animated characters and Pokémon flicker between two poses at certain camera positions (a head, for example). The option now relaxes the game's two per-frame animation channels together, through their four update policies, instead of forcing one flag at the update. Z-A v2.0.2 only, `LARECOMP_SMOOTH_ANIM=0` still turns it off for a run. The second channel now runs every frame too; its CPU cost was not measured.
- The shader translator honors the directed rounding modes (toward negative infinity, toward positive infinity, toward zero) of 32-bit integer to float (`I2F`) and float to half (`F2F`) conversions, instead of always rounding to nearest. Conversions rounded to nearest, and every shader that does not use these modes, translate exactly as before. Whether the game's shaders use them, and what that changes on screen, was not measured. The translated code of shaders that use them changes, so **Prepare all shaders** has to be run again (the **All shaders** badge turns yellow; the precompile version is 5). Directed rounding of 64-bit integer conversions and of integer to half conversions is not covered yet.

## 0.1.6

Optional frame generation up to 120 fps, shadows without the sharp-to-blurry step at the cascade boundary, smoother distant animation, simpler defaults, and shader work. **After updating, run Prepare all shaders again** (the **All shaders** badge turns yellow): the translated shaders changed.

### Smoother
- **Optional frame generation up to 120 fps** (macOS 26, experimental): MetalFX adds an intermediate frame, so **30 real fps are shown at 60 and 60 real fps at 120**. Pick it in Video > Frame generation; it is off by default and needs a GPU with MetalFX frame interpolation and a 60 or 120 Hz screen (the row is greyed out, with the reason, when it is unavailable). The game keeps its original speed and input timing, the HUD is composited separately, and missing inputs fall back to real frames. Skinned characters and Pokémon give their previous vertex positions as motion (in docked and handheld mode), the rest uses camera and depth, so small edge artifacts and particles can still show. A **Frame generation quality** option (Native or Performance) caps only the generated frames at 1920 pixels wide to save GPU time. It needs GPU headroom: at 1.5x on an M5 it reached about 80 to 100 displayed fps from 60. See `docs/frame-generation.md`.
- **Smooth distant animation** (Video > Rendering, on by default): characters and Pokémon away from the camera animate every frame instead of in visible steps. The game's per-frame animation update skips the full path for entities outside a small selected set (about 24 of 70 in the station), chosen by distance and view; a per-entity flag decides it, and the option sets that flag before the update, so the game's own logic is untouched. Applied as a runtime override of the update and its vtable stub, with no change to the game library; Z-A v2.0.2 only (the row is greyed out on the other versions). `LARECOMP_SMOOTH_ANIM=0` turns it off for a run. At the station the CPU and GPU cost was not measurable.

### Picture
- **Consistent shadow filtering across cascades:** keeps the filter's world-space width consistent in both materials and the deferred shadow mask, removing the abrupt sharp-to-blurry boundary seen at the station. Cascade distances stay unchanged; distant shadow detail still depends on map resolution. See `docs/shadow-cascades.md`.
- **Shadow resolution** applies at once: changing it in Video > Rendering makes the shadow maps again at the new size while the game runs, instead of from the next start (the maps are drawn again every frame, so nothing is lost; at 4x they take about 240 MB while it is on)

### Menu and defaults
- New installs start with a **fixed 1080p** internal resolution instead of Dynamic up to 1080p. **Dynamic** is still one choice away in Video > Resolution mode, and an existing `larecomp.ini` keeps its own choice.
- The **Aspect ratio** option is gone for now: the picture is always the game's original 16:9, with bars on other windows. A saved "Unlocked" choice is ignored, so nobody is left on a framing the menu can no longer change. (The separate **Wider view** option is unchanged.)
- The save being played can be **reloaded** from the in-game Saves tab (**Reload this save**, with the same confirmation as playing another one): the game restarts from its last save there, to undo what happened since. Before, only the other saves could be played
- A menu row with ◀ ▶ arrows no longer shows the arrow that has nowhere to go (first or last choice, minimum or maximum).

### Shaders and loading
- **Prepare all shaders** also builds the game's compute programs (57), with the texture setup the game really uses, so the first attack effects in a battle no longer stall: in a replay of the first battle the compute programs took 0.4 to 0.6 ms each to build instead of 350 to 380 ms, and no frame took more than 50 ms after loading.
- The shader translator honors `.FTZ` on the floating-point compares FSET, FSETP and FCMP: subnormal operands are flushed to zero before the comparison, as the hardware does. Compares without `.FTZ` translate exactly as before.
- Compute programs are shared by content: the same compute shader streamed to another address, or registered again, reuses the program already translated and built instead of making another one. Identity is the shader bytes, the code/constants split, the texture and image types, the workgroup size and the memory window, the same one **Prepare all shaders** uses, so prepared programs are found too. Nothing is hashed on the dispatch path.
- Scene draws wait up to 1 ms (6 ms a frame, less when the frame has no room left) for a shader program or pipeline that is being built, instead of being skipped for a frame. In a replay of the first battle with warm caches, skipped draws fell from 49 to 32 in every one of three pairs, every wait was answered in time (0.15 ms on average, 0.26 ms at most, 10 to 11 ms in total over the run) and the frame rate did not change. A shader built for the first time still takes longer than that and is skipped as before. `LARECOMP_SCENE_WAIT_MS=0` turns it off.
- Shader preparation workers are also bounded by the number of compilations Metal accepts at once (`maximumConcurrentCompilationTaskCount`), not only by the CPU count. No change on a 10-core M5, where both are 10; it matters on machines where Metal allows fewer.

### Performance
- The renderer reuses its retired 64 MB upload buffers instead of allocating a new one on every wrap (about 46 allocations in 1500 frames). Measured on a station walk replay, uncapped at 1x: 83.1, 87.1, 89.4 fps without it and 87.9, 89.4, 90.9 with it, alternating runs, so about 3% more, a small margin. `LARECOMP_NO_RING_POOL=1` turns it off.
- Sampled textures whose full contents are unchanged no longer recompute their sampled-change hash, which saves a little CPU per frame. Nothing visible changes: first uploads and changed textures still refresh both hashes.

### Fixes
- The error applet (`ILibraryAppletCreator`, applet `0x0e`) now answers like the real system: the game gets an applet object with its events, start, completion and an empty result, and the error is acknowledged without a dialog (only numeric fields are logged, never the message text). Other applets and unsupported commands now fail with an error instead of reporting success. Malformed or oversized IPC messages (handle counts, domain input ids, declared body length) are rejected. No native error dialog is shown.

### Developer tools
- Developer log: a file of warnings for the developers (`logs/devlog.txt`, or `LARECOMP_DEVLOG_FILE`), apart from the normal log, every line with its date and time and the file empty while all is well. It is the **Developer log** switch of the Developer tab (`dev_log` in `larecomp.ini`), or `LARECOMP_DEVLOG=<subjects>`; nothing is written when it is off. First subject, `compute`: a compute program the game builds with a key that the precompilation does not cover.
- **Record a route** (Developer tab, Tests): asks for a name, copies the save in use to `routes/<name>/save` and records every pad change into `routes/<name>/route.txt` until you stop. Routes are not in the save list. `LARECOMP_ROUTE=<name>` plays one back on a fresh copy of its starting save each time, so an autosave during the replay never touches it; `LARECOMP_INPUT_REPLAY_AT=<frame>` delays the start (the game needs about 600 frames to load a save and press Continue). For repeatable performance tests.

## 0.1.5

### Shaders
Fewer stalls the first time you see a scene. Nothing here uploads anything; everything is rebuilt on your Mac from your own
game files.
- **Prepare all shaders**: the **All shaders** badge at the top right of the start screen (green check when done and
  current, yellow triangle when not done or out of date) explains the cost and offers **Compile all shaders** or Cancel.
  Compiling starts the game, which reads every shader from your game files (about 40 s), translates them with their usual
  settings and compiles their Metal libraries on all cores (about 4.5 minutes on a 10-core M5), behind a progress page with
  a Stop button; what was compiled is kept. It leaves about 370 MB in Metal's shader cache and deletes its 115 MB of
  temporary files. A stamp records the precompile version, macOS, the GPU and the game files, so the badge turns yellow when
  any of them changes. Cold-cache station walk on an M5, nothing else: the worst frame while entering the station went from
  about 16 s to 0.57 s. See `docs/shader-precompile.md`.
- **Compile shaders early** (Shaders tab, on by default): when the game registers a shader that a catalog or your own
  recipe journal knows, it is translated and compiled on background workers before its first draw, and the draw shares that
  work if it comes first. Misses compile normally. Cold station walk with a catalog: the worst frame entering the station
  fell from about 8 s to 1.4 s and the walk compiled nothing. `docs/shader-early-experiment.md`.
- **Prepare known shaders** (Shaders tab, off by default, needs a catalog): before the game starts, rebuilds the shaders a
  catalog lists (hashes and offsets, never code) from your game files and builds their pipelines, on workers sized to the CPU
  count behind a progress page. With the precompile done it takes 1.3 s instead of 9 s. A small native decoder
  (`oozextract`, MIT; notices packaged) reads the game's compressed archives. `docs/shader-first-install.md`.
- **Collect new shader recipes** (Shaders tab, on by default, local): the pipelines the game builds that no catalog covers
  are saved as hashes and numbers in `cache/shader-recipes/recipes.jsonl`, written off the render thread, no limit on how
  many (100 MiB of file). **Export shader recipes** writes a metadata-only JSON to share by hand; **Contribute recipes on
  GitHub** opens the issue form. See `docs/shader-recipe-contributions.md`.
- **Update shader catalog** (Shaders tab) checks the project's official releases for a `shader-catalog.json` asset only when
  you press it, verifies size, SHA-256 and schema, rebuilds the inputs from your files and installs it atomically (the
  previous one stays if anything fails). The **Shader catalog** badge on the start screen shows whether yours is current and
  stays hidden until a catalog is published. No catalog is published yet.
- **Compute programs** join the rest: their pipelines go into the pipeline archive and their source into the warm-up cache,
  and compute recipes (shader hash, texture-type masks, workgroup size) are collected, exported, put in catalogs and
  prepared. No count limit in the catalog, the preparation or the journal.

### Fixes
- Ansha's donuts show up: `std::chrono::system_clock::now` answers from the Mac's clock. The SDK's own path read ~0,
  and the game files a donut stamped 0 as an empty slot, so new donuts never appeared and each overwrote the last.
  Found and fixed by [Hexveil404](https://github.com/Hexveil404) in
  [PokeZ-ARecomp](https://github.com/Hexveil404/PokeZ-ARecomp/commit/36e14c5).
- The Royale profile photo is no longer black: `nvnTextureReadTexels[Strided]` read the texture back, and a copy into a
  pitch-linear texture also reaches guest memory (the game reads that memory and encodes the photo itself). After the fix in
  PokeZ-ARecomp by [Hexveil404](https://github.com/Hexveil404).
- Indirect draws with parameters no draw can have (a count over 4M, a base instance past an instance buffer) are skipped
  instead of drawn (`LARECOMP_IB_GUARD=0` draws them). After the same fix in PokeZ-ARecomp by
  [Hexveil404](https://github.com/Hexveil404).
- Playing another save from the in-game menu, or going back to the start screen, no longer aborts the game: the reboot
  freed a CPU state that belonged to a thread.
- Pipeline archive (Metal): a new archive is built after each save, and the archive stays off after a save that crashed
  inside Metal (issue #101). The first save of a session was always fine; the next one crashed on some Macs.
- The shader preparation page lays itself out with the window, so the game is no longer left pinned to the left of a
  fullscreen window afterwards.

### Start screen and saves
- **Import and export saves** (SAVES page): Export makes a .zip of the selected save, named after the save, its play time
  and the day (`Main save - 12h34 - 2026-10-31.zip`); Import takes a .zip or a folder (our export, a JKSV backup, a copy from
  a console), shows whose save it is (trainer, play time, money, team) and adds it as a new save: one of our exports gets its
  old name back, anything else "<trainer> - <play time> - <file name>". Nothing existing is replaced; Copy duplicates a save.
- **Saves tab in the in-game menu:** the save being played (trainer, play time, coins, team), with Copy and Export; every
  other save, each with a window to **play it** (after a yes, the game restarts with it), copy, export, rename or delete it;
  Import, and a New game in a new save. A reboot into the game keeps the save it was playing.
- **Legal notice** button at the top right: MonZaMac is independent and unofficial, you need your own copy of the game and
  the right to use the files and keys you provide, and no game files or keys come with the app.

### Settings and menu
- **Resolution mode** (Fixed / Dynamic) is its own choice, above Internal resolution. Dynamic goes **up to 1080p**,
  **up to 1620p** or **up to match display** (up to 1080p is new, `resolution = dynamic 1x`). Sizes are named in lines:
  1080p, 1620p, 2160p... (720p and up in handheld mode); Match display shows its lines too; every list is in order of lines.
- **25% / 50% / 75%** are shares of the game's own 1080p (270p / 540p / 810p; before, of the display's resolution).
  Existing `larecomp.ini` values keep working. New installs start at Dynamic, up to 1080p.
- Moving the cursor onto a menu tab with the keyboard or a pad opens it, like L / R and Q / E. The mouse still needs a click.

### Rendering
- Fragment programs that only branch forward (no jump tables) run as structured code instead of the `switch (pc)` loop:
  63.2 -> 64.7 fps (+2.4%) uncapped in the starting scene at 1.5x. Programs that read the facing flag keep the loop.
- Texture change checks hash in four parallel chains: about 1.1 ms less CPU per frame at 1.5x (65.2 fps uncapped).
- The uniform snapshot cache holds 4096 entries instead of 128: bytes copied fell 57%. Uncapped: 99.0 -> 100.4 fps at 1x,
  65.0 -> 65.6 at 1.5x.

### Developer tools
- **Shader diagnostics** (off unless `LARECOMP_SHADER_TRACE=<new directory>`): metadata only, each registered shader's hash,
  stage, where it was read from, and when it was registered and compiled. Shader dumps need a separate opt-in. See
  `docs/shader-diagnostics.md`.
- The shader preparation prototype (`LARECOMP_SHADER_PREP` / `LARECOMP_SHADER_INPUTS`) and
  `tools/shader_catalog_from_journal.sh`, which grows a local catalog from the journal after each session.

## 0.1.4

### Rendering
- **Shadow resolution and shadow sharpness** (Settings > Rendering): the sun's shadow maps can be drawn 2x, 3x or 4x
  bigger (from the next start), and the filter 2x to 4x narrower (at once, up to the resolution): smooth, crisp shadow
  edges. They replace "4K shadows", which is gone from the menu: a `game_shadows_4k = 1` in `larecomp.ini` becomes 4x for
  both. Off ("Game's") by default.

### Start screen and saves
- **Crashes are explained**: when the app is opened by double click and the game stops on an error, an alert says in plain
  words what happened and what to do (graphics driver, the game's own check, a bug in MonZaMac), and points to
  `logs/play.log` (the previous run: `play-anterior.log`) to attach to a report.
- **The save card shows the trainer's data:** name, trainer ID, play time, money and the team, read from the save
  itself (read only), laid out in two columns. The SAVES list shows the same for every save.
- **Each save can open its team:** a button on the right of the card (or Y / I) lists every Pokémon with its ball
  (gold for a shiny), name and level. Names in another script use a macOS system font when the launcher starts; the
  Pokédex number stands in for a character that font lacks.

### Controls
- **Mouse settings** (Settings > Controls, a Mouse section): the camera turns with the mouse while a button is held (right,
  left, middle or any), always, or not at all; a two-finger trackpad drag turns it too; each axis can be
  inverted; the speed is adjustable (100% is the default, a higher base than before). In the game the cursor is hidden
  and held in place, so the camera never stops at the window's edge; the menu gives it back. The right stick snap
  (0 = off) sits with the d-pad.

### Stability
- **Game file paths stay inside the mounted folder:** a path with `..` is refused as not found instead of reaching
  outside the save directory.
- **File service:** short writes are completed, errors are returned to the game instead of being dropped, and file
  descriptors are released when the game closes them.
- **Loading and generation checks:** executable sizes are checked before they are read, truncated shader headers are
  refused, SIMD batches in the generated code no longer overwrite a guest register with the flags, and the renderer's
  program and pipeline indexes can no longer loop when full.
- **Build helpers** stop on a failed step and rebuild when the compile flags change.

### Developer
- **CPU and GPU frame time log** (`LARECOMP_PERF_LOG`) and a scene benchmark (`tools/perf_scene.py`), with the measured
  cost of the shadow options in `docs/performance-shadows.md`.

## 0.1.3

### Performance
- **Frame rate: one 60 fps choice.** Settings > Video has 30 fps and 60 fps; the old "steady speed" option is retired
  (a saved `fps60_steady` is ignored). `dynamic 60 fps` now keeps the world at a steady speed on its own.
- **Guest compare and branch fusion:** a conservative fusion of compare and branch instructions in the generated code
  (`tools/flagfuse.py`, with its tests). Behaviour is unchanged; the gain is in the frame time, measured on one Mac.

### Start screen and saves
- **The save card and the SAVES list show no file size:** name and last-modified date tell saves apart.
- **Hidden files** such as `.DS_Store` in `save/` are no longer counted as progress.

### Station
- **NPC pop-ins at Lumiose station are fixed:** the game's appearance budgets for characters are raised (64 active
  instead of 20; `LARECOMP_NPC_CAPACITY_FIX=0` restores the originals).

### Developer
- **Uncapped frame rate benchmark** (Developer tab): turns off the frame limit to measure the GPU and CPU on their own.
  Off by default.

## 0.1.2

About 60 fps in the open world on an Apple M5 at 2880x1620 (1.5x), up from about 41 on the same Mac and scene, and a new
start screen with save slots.

### Performance
- **Structured shader flow (on by default):** a shader whose only computed jumps are bounded forward jump tables now
  runs as plain conditionals and small switches instead of a `switch (pc)` loop (about 20% less measured GPU time for
  the whole frame in one test, 48 to 60 fps at 1.5x). Anything it cannot prove falls back to the old output.
  `LARECOMP_STRUCTURED_FLOW=0` turns it off.
- **Faster shaders with jump tables (on by default):** a fragment shader with a computed jump (BRX) got a label on every
  instruction, which stopped the Metal compiler from optimising it (the lighting pass went from 11.6 to 6.2 ms; 41 to 54
  fps at 1.5x in one test). Now only the starts of code blocks are labels. `LARECOMP_BRX_ALL_LABELS=1` restores the old
  output.
- **Fewer render passes after GPU skinning (on by default):** the pass used to end after each transform-feedback stage;
  it now stays open with a Metal buffer barrier (about 1 ms less GPU time a frame in the tested scenes: 38 to 42 fps at
  1.5x in one test). Developer tab "Keep passes open after skinning" turns it off at once;
  `LARECOMP_XFB_END_BARRIER=0` too.
- **Clears as load actions:** a clear the game issues at the start of a pass now clears the attachment as the pass
  begins instead of loading it and drawing over it (less GPU bandwidth; `LARECOMP_CLEAR_DRAWS=1` goes back).
- **Dynamic resolution follows the GPU better:** it settled at 70% and then 85% where 100% held 60 fps. The GPU time it
  reads tops out at the frame period (a GPU busy all the time that still makes 60 fps reads about 16 ms), so it now lowers
  when frames are missed and raises while the busy time is under 16.3 ms.

### Start screen and saves
- **New start screen, with save slots:** the logo and name on top, a card with the most recent save, and CONTINUE / NEW
  GAME / SAVES / SETTINGS / QUIT under it, as in the Pokémon games. CONTINUE starts the most recent save; NEW GAME asks
  for a name and starts a fresh one; SAVES lists them all, in the order they were made, to pick one, copy, rename or
  delete. Your existing save is the first slot ("Main save", you can rename it), untouched; extra saves live in `saves/`
  next to `save/`. The app opens on it (`--play` skips it and plays the most recent save).
- **No more aspect ratio question on the first PLAY:** the saved aspect ratio is used (authentic 16:9 until you change it
  in Settings).
- **New look for the menus:** deep blue panels with a cyan accent instead of green and gold (start screen, Settings,
  in-game menu); the Settings window is smaller, with smaller type and the version in its header.
- **Fix:** a hidden file such as `.DS_Store` in `save/` (Finder makes one when you open the folder) made it count as the
  most recent save, so CONTINUE started an empty game. Hidden files are ignored now.

### Settings
- **Defaults for new players:** fullscreen, dynamic resolution, 60 fps, SMAA, authentic 16:9 and sharper textures
  (anisotropic filtering) are on from the first start. An existing `larecomp.ini` keeps its own settings.
- **Settings before the game starts:** the Video tab of the start screen's Settings now shows the game's own options
  (game mode, frame rate, FXAA, depth of field, bloom, wider view, sharper textures, 4K shadows, game dynamic
  resolution), which only appeared once the game was running.

### Tools
- `gpupass N` (in `build/dbgcmd`): GPU time of each render pass over N frames, no Xcode needed (developer tool).
- Developer GPU profiling: opt-in, one-frame Metal captures and per-frame pass/submission break histograms.

## 0.1.1

### Performance
- **CPU/GPU overlap (on by default; Developer > Experimental to turn it off):** the game's frame fence is waited
  one frame late, so the CPU prepares the next frame while the GPU draws the current one instead of taking turns
  (about 49 to 58 fps standing still, 53 to 59 in motion on one Mac). `LARECOMP_GPU_OVERLAP=0` also turns it off.
- **Uniform buffer snapshots are reused when nothing changed:** the renderer copied about 44 MiB of uniforms a frame
  and now about 13 MiB, compared byte for byte (about 11% more fps in the plaza scene on one Mac;
  `LARECOMP_NO_UNIFORM_CACHE=1` goes back to copying).

### Settings
- **Developer tab** (Cmd+Shift+D, or `developer = 1` in `larecomp.ini`): "Frame times in F3" adds the CPU time to
  submit a frame and the GPU busy time to the F3 overlay, "GPU timing log" writes the GPU time per present to the log,
  and the experimental CPU/GPU overlap switch is there.
- **Wait for shaders** (Display tab): a shader or pipeline the game needs for the first time is compiled on the spot and
  the game waits (a short stutter, nothing missing from the picture); off, it compiles in the background and the
  objects that need it are left out until it is ready.

### Graphics
- **No more objects popping in and out above 1x (Metal):** the game's culling tests objects against the scene depth's
  mip chain with a min / max sampler; at a higher internal resolution those mips cover less of the screen than the game
  expects, so visible objects were culled. Those reads now go up a level by the scale (`LARECOMP_HIZ_LOD=0`: off).
- **"Sharper textures" no longer brings the popping back:** its LOD bias (-1) and anisotropy applied to that same
  min / max sampler, which then looked a level finer than the game asks for. Reduction samplers now ignore both.
- **Smoother higher internal resolutions:** fixes the jagged character and scenery edges at 1.5x and higher, caused by
  integer screen-space texture reads losing their subpixel positions.
- **Texture size queries at higher internal resolutions:** a shader asking a scaled texture for the size of a mip level
  now gets the guest's size (the base halved per level) instead of the allocation's size divided by the scale, which
  was off by one at some levels (1.5x: 17 rows where the game has 16).
- **Textures a shader writes as an image stay at the game's size:** SUST / SURED store at the game's pixel coordinates,
  so such a texture can't be rendered at a scaled resolution (none seen in Z-A so far; `[scale] image-bound texture
  back to the guest size` in the log names one; `LARECOMP_IMAGE_SCALE=1` keeps the old behaviour).

### Tools
- `trace n` (in `build/dbgcmd`) also logs one `[cs-out]` line per compute dispatch: hashes of its storage and uniform
  buffers and its textures (guest size, `*` scaled, `i` image). `tools/cs_diff.py` compares two such logs (same scene,
  two internal resolutions) and lists the dispatches whose output depends on the resolution; with
  `LARECOMP_CS_DUMP=1` the buffers are written to `build/csdump` and `tools/cs_dump_diff.py` shows which words differ.
- The Developer tab's GPU timing log writes two lines per frame instead of one per command buffer (about 140 a
  frame); `LARECOMP_GPU_TIMING_TRACE=1` brings the per-buffer lines back.

### Logs
- A cube slot holding a 2D texture is no longer reported as a type mismatch (it says what it is), and a pipeline left
  out of the archive says what it is made of.

### Notes
- The first start after updating recompiles some shaders (their Metal source changed) and the pipeline archive
  (`cache/pipelines.bin`) keeps the old entries; deleting the file is safe, it is rebuilt.

## 0.1.0 - first tagged release

MonZaMac is the native macOS (Apple Silicon, Metal) port of Pokémon Legends: Z-A. This is the first numbered
version: everything below is new since the project began, grouped by what you notice.

### Setup
- **Guided first-run setup:** choose your own base game (NSP/XCI), the v2.0.2 update (NSP) and `prod.keys`; the app
  extracts, applies the update and compiles the game on your Mac. It bundles its extractor (nstool, with a path-safety
  patch), the game-code generator and the compiler, installs only when every step succeeded, and keeps your saves
  and settings. An ownership declaration gates the setup. Importing an extracted `exefs`/`romfs` folder still works.
- New app icon; the version on the start screen (and the update check, from GitHub releases).

### Graphics and display
- **Z-A options** (Display tab): depth of field, the game's FXAA, bloom, a wider view, "Sharper textures" (8x
  anisotropic filtering, and a LOD bias on macOS 26 or later), 4K shadows, and widescreen with the original or an
  unlocked aspect ratio.
- **Internal resolution:** Match display, 25-75%, 1x-4x, **Dynamic** and **Dynamic 1.5x** (1.5x while the GPU holds
  the frame rate, lower when it can't). The controller measures the GPU's real busy time, follows the game's frame
  rate (no more collapse to 50% at 30 fps), climbs back quickly and restarts when you change mode.
- SMAA and MetalFX upscaling; defaults: original 16:9, 1x, SMAA.
- **F3** shows the render resolution, the dynamic share, frame and GPU time and the present interval.
- The game's own dynamic resolution is off by default (a stall, such as a minimised window, used to blur the picture
  for a while); "Game dynamic resolution" brings it back.

### Frame rate and modes
- **Frame rate:** 30 fps (as on the Switch), 60 fps, or **60 fps, steady speed**, where the world steps by the real
  frame time so it does not slow down when a frame takes longer than 1/60 s (down to 30 fps).
- **Game mode:** docked (1080p) or handheld (720p, lighter settings, far less GPU work); toggle live with
  Cmd+Ctrl+H or from the menu.

### Performance and stability
- Compiled Metal pipelines are kept on disk (a pipeline archive) and warmed at start; pipelines the GPU archiver
  rejects are left out and the rest is saved.
- Fixed a game freeze caused by weak ordering of the game's atomic loads on Apple Silicon.
- Fixed freezes and lost frames around a hidden or minimised window.
- Fixed a crash from a texture used after the game finalized it.
- On quit, the game's threads stop before the cache is saved.

### Tools
- `tools/hang_sample.sh` samples every thread and prints the kernel's wait dump when the game freezes.
- Renderer tests with no game files: `gmake test-metal-renderer` (GPU timing, the renderer, the shader translator).

### Known issues
See the README.
