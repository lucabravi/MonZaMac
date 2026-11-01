# MonZaMac build (macOS, Apple Silicon: Homebrew clang/SDL3/FFmpeg, Metal renderer)
comma := ,
GEN      ?= generated

# B: build dir. MACOS_MIN: oldest macOS to run on (default: this one). DEPS: prefix with SDL3 / FFmpeg instead of
# Homebrew's (make deps). `make app` sets all three (build/mac15, 15.0, build/deps); plain `make` uses none.
B         ?= build
MACOS_MIN ?=
DEPS      ?=
MINFLAG  := $(if $(MACOS_MIN),-mmacosx-version-min=$(MACOS_MIN))
CC       := clang $(MINFLAG)
CXX      := clang++ $(MINFLAG)
IMGUI    := third_party/imgui
# GENOPT: the generated code's optimization (-O0 builds in seconds: some lifted functions take clang -O1 minutes)
GENOPT   ?= -O1
GENFLAGS := $(GENOPT) -fno-strict-aliasing -Wno-return-type -Wno-unused-label -fvisibility=hidden -Iruntime

# The game code (made by `make gen` from your own game files) is its own library next to the app (runtime/gamelib.h);
# the app itself holds none of it
GEN_SRC  := $(wildcard $(GEN)/main/*.c) $(wildcard $(GEN)/sdk/*.c)
GEN_OBJ  := $(patsubst %.c,$(B)/obj/%.o,$(patsubst $(GEN)/%,%,$(GEN_SRC))) $(B)/obj/tools/gamelib_entry.o
RT_SRC   := $(wildcard runtime/*.c) $(wildcard runtime/hle/*.c) $(wildcard runtime/services/*.c) \
            $(wildcard runtime/nvn/*.c) $(wildcard runtime/nvn/maxwell/*.c) runtime/platform/macos.c
RT_HDRS  := $(wildcard runtime/*.h) $(wildcard runtime/platform/*.h) $(wildcard runtime/services/*.h) \
            $(wildcard runtime/nvn/*.h) $(wildcard runtime/nvn/maxwell/*.h) $(wildcard runtime/ui/*.h)
UI_SRC   := $(wildcard runtime/ui/*.mm)
UI_OBJ   := $(patsubst runtime/%.mm,$(B)/rt/%.o,$(UI_SRC))
IMGUI_OBJ := $(B)/imgui/imgui.o $(B)/imgui/imgui_draw.o $(B)/imgui/imgui_tables.o $(B)/imgui/imgui_widgets.o \
             $(B)/imgui/imgui_impl_sdl3.o

SDL      := $(or $(DEPS),/opt/homebrew/opt/sdl3)
FFMPEG   := $(or $(DEPS),/opt/homebrew/opt/ffmpeg)
EXE      := $(B)/monzamac
DEPINC   := -I$(SDL)/include -I$(FFMPEG)/include
LDFLAGS  := -L$(SDL)/lib -lSDL3 -Wl,-rpath,$(SDL)/lib -L$(FFMPEG)/lib -lavformat -lavcodec -lavutil -lswscale -Wl,-rpath,$(FFMPEG)/lib \
            -framework CoreFoundation -framework Foundation -framework Metal -framework MetalFX -framework QuartzCore -framework AppKit -framework ImageIO -framework CoreGraphics -framework UniformTypeIdentifiers
BACKEND_SRC := $(wildcard runtime/nvn/*.m)
BACKEND_OBJ := $(patsubst runtime/%.m,$(B)/rt/%.o,$(BACKEND_SRC))
IMGUI_OBJ += $(B)/imgui/imgui_impl_metal.o
UIFLAGS  := -fobjc-arc
GAMELIB  := $(B)/lasgame.dylib
GAMELIB_LDFLAGS := -dynamiclib -undefined dynamic_lookup  # (the runtime functions it calls: the app's own)
GAMELIB_SHARED := -shared -Wl,-undefined,dynamic_lookup  # (the same, for the start screen's build: zig cc)
# GAMELIB_ID: what the game code library is built from (the generator, the headers it is compiled against, the
# flags). A library with another id is rebuilt by the start screen, never loaded.
GAMELIB_SRCS := tools/gen.py tools/flagfuse.py tools/lifter.py tools/analyze.py tools/nso.py tools/passes.py tools/patches.py \
                tools/simd_c.py tools/gamelib_entry.c runtime/hle/hle_symbols.txt \
                runtime/cpu.h runtime/simd.h runtime/simd_fp.h runtime/gamelib.h
GAMELIB_ID := $(shell (cat $(GAMELIB_SRCS); echo '$(GENFLAGS)') | (shasum -a 256 2>/dev/null || sha256sum) | cut -c1-16)

RT_OBJ   := $(patsubst runtime/%.c,$(B)/rt/%.o,$(RT_SRC))
RTFLAGS  := -O2 -g -fno-strict-aliasing -Wall -Wno-unused-function -Iruntime -Iruntime/nvn $(DEPINC) $(OSFLAGS)
CXXFLAGS := -O2 -g -std=c++17 -I$(IMGUI) -I$(IMGUI)/backends -Iruntime -Iruntime/nvn $(DEPINC)

all: $(EXE) $(if $(GEN_SRC),$(GAMELIB))

$(B)/obj/%.o: $(GEN)/%.c runtime/cpu.h runtime/simd.h runtime/simd_fp.h
	@mkdir -p $(dir $@)
	@$(CC) $(GENFLAGS) -c $< -o $@

$(B)/obj/tools/gamelib_entry.o: tools/gamelib_entry.c $(GAMELIB_SRCS) Makefile
	@mkdir -p $(dir $@)
	$(CC) $(GENFLAGS) -DGAMELIB_ID='"$(GAMELIB_ID)"' -c $< -o $@
$(B)/rt/gamelib.o: $(GAMELIB_SRCS) Makefile
$(B)/rt/gamelib.o: RTFLAGS += -DGAMELIB_ID='"$(GAMELIB_ID)"'
# the start screen's build of it (runtime/gamebuild.c) uses the same flags
$(B)/rt/gamebuild.o: $(GAMELIB_SRCS) Makefile
$(B)/rt/gamebuild.o: RTFLAGS += -DGAMELIB_ID='"$(GAMELIB_ID)"' -DGAMELIB_CFLAGS='"$(strip $(filter-out -Iruntime,$(GENFLAGS)))"' \
                                -DGAMELIB_SHARED='"$(GAMELIB_SHARED)"'

# Command-line GENOPT / GENFLAGS changes have no source mtime. Keep the game objects and both runtime copies of
# their build identity in sync, without rebuilding when the effective flags are unchanged.
$(GEN_OBJ) $(B)/rt/gamelib.o $(B)/rt/gamebuild.o: $(B)/gamelib-flags
$(B)/gamelib-flags: force-gamelib-flags
	@mkdir -p $(dir $@)
	@printf '%s\n' '$(GENFLAGS)' > $@.tmp
	@if cmp -s $@.tmp $@; then rm -f $@.tmp; else mv -f $@.tmp $@; fi
.PHONY: force-gamelib-flags

$(B)/rt/%.o: runtime/%.c $(RT_HDRS)
	@mkdir -p $(dir $@)
	$(CC) $(RTFLAGS) -c $< -o $@

# SMAA (third_party/smaa, MIT): the reference shader as a C string for runtime/nvn/smaa_data.c (both backends build
# their passes from it); the non-ASCII bytes in its comments become '?', and its CRLF line ends plain LF (a CR left in
# the string literals ends them early on macOS clang)
$(B)/inc/smaa_hlsl.inc: third_party/smaa/SMAA.hlsl
	@mkdir -p $(dir $@)
	LC_ALL=C tr -d '\r' < $< | LC_ALL=C tr '\200-\377' '?' | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/^/"/' -e 's/$$/\\n"/' > $@
$(B)/rt/nvn/smaa_data.o: $(B)/inc/smaa_hlsl.inc
$(B)/rt/nvn/smaa_data.o: RTFLAGS += -I$(B)/inc -Ithird_party/smaa/Textures

$(B)/rt/%.o: runtime/%.cpp $(RT_HDRS)
	@mkdir -p $(dir $@)
	$(CXX) $(CXXFLAGS) $(OSFLAGS) -c $< -o $@

$(B)/rt/%.o: runtime/%.m $(RT_HDRS)
	@mkdir -p $(dir $@)
	$(CC) $(RTFLAGS) -fobjc-arc -c $< -o $@

# linked to a temp file, then renamed over: a copy of the game still running keeps its (old) file - relinking in
# place gets running copies killed by macOS (code signature of the changed pages). The temp file keeps the real name
# (in a folder of its own): on Windows the import library records the name the game code library loads it by.
$(EXE): $(RT_OBJ) $(BACKEND_OBJ) $(UI_OBJ) $(IMGUI_OBJ)
	@mkdir -p $(dir $@)link
	$(CXX) -o $(dir $@)link/$(notdir $@) $^ $(LDFLAGS)
	mv -f $(dir $@)link/$(notdir $@) $@

# its id file (<library>.id) says what it was built from without loading it (runtime/gamelib.c)
$(GAMELIB): $(GEN_OBJ) | $(EXE)
	$(file >$@.rsp,$^)
	$(CC) $(GAMELIB_LDFLAGS) -o $@.tmp @$@.rsp  # (response file: Windows' command line limit, ~1400 objects)
	mv -f $@.tmp $@
	echo $(GAMELIB_ID) > $@.id

$(B)/rt/ui/%.o: runtime/ui/%.mm $(RT_HDRS)
	@mkdir -p $(dir $@)
	$(CXX) $(CXXFLAGS) $(UIFLAGS) -c $< -o $@

$(B)/imgui/%.o: $(IMGUI)/%.cpp
	@mkdir -p $(dir $@)
	$(CXX) $(CXXFLAGS) -c $< -o $@

$(B)/imgui/imgui_impl_%.o: $(IMGUI)/backends/imgui_impl_%.cpp
	@mkdir -p $(dir $@)
	$(CXX) $(CXXFLAGS) -c $< -o $@

$(B)/imgui/imgui_impl_metal.o: $(IMGUI)/backends/imgui_impl_metal.mm
	@mkdir -p $(dir $@)
	$(CXX) $(CXXFLAGS) -fobjc-arc -c $< -o $@

# Python: tools/venv (macOS, Linux: bin/python, Windows: Scripts/python.exe)
PY := $(firstword $(wildcard tools/venv/bin/python) $(wildcard tools/venv/Scripts/python.exe))

# EXEFS: the game's exefs folder (another version's: with its own GEN and B)
EXEFS ?= extracted/exefs
gen:
	cd tools && ../$(PY) gen.py sdk ../$(EXEFS)/sdk 0x7008000000 ../$(GEN)/sdk --hle ../runtime/hle/hle_symbols.txt $(GENSIMD)
	cd tools && ../$(PY) gen.py main ../$(EXEFS)/main 0x7000000000 ../$(GEN)/main $(GENSIMD)

gen-objs: $(GEN_OBJ)

# Runtime objects only (no generated code, no link): quick compile check
runtime-objs: $(RT_OBJ) $(BACKEND_OBJ) $(UI_OBJ)

VERSION  := $(shell sed -n 's/^\#define LARECOMP_VERSION "\(.*\)"/\1/p' runtime/ui/launcher.mm)

# macOS: build/MonZaMac.app, runs on macOS $(APP_MIN)+: the game rebuilt for that in build/mac15 against build/deps
# (`make deps`: SDL3, LGPL FFmpeg, keystone, Python, from pinned sources), the generator helper when built
# (`make gen-helper` after `make deps`), packaged by tools/bundle_macos.sh. No game files or fonts.
APP_MIN  := 15.0
APP_B    := build/mac15
deps:
	MACOS_MIN=$(APP_MIN) tools/build_deps_macos.sh
app:
	@[ -f build/deps/lib/libSDL3.0.dylib ] || { echo "make deps first"; exit 1; }
	MACOS_MIN=$(APP_MIN) tools/build_nstool.sh
	$(MAKE) gen-helper
	tools/fetch_zig.sh
	$(MAKE) B=$(APP_B) MACOS_MIN=$(APP_MIN) DEPS=$(CURDIR)/build/deps $(APP_B)/monzamac
	MACOS_MIN=$(APP_MIN) tools/bundle_macos.sh $(APP_B)/monzamac

# macOS release disk image (the .app + an Applications shortcut to drag it onto): build/dist/MonZaMac-<v>-macOS.dmg
dmg: app
	tools/make_dmg.sh

# The game code generator, the same way (tools/lasgen.spec): build/helper/lasgen/, shipped as lasgen/ next to the exe or
# in Contents/Resources. The start screen's setup runs it on the player's own game files (runtime/gamebuild.c).
gen-helper: build/helper-venv/.ok build/shader-decode/release/monzamac-shader-decode
	build/helper-venv/bin/python -m PyInstaller --noconfirm --clean --log-level WARN --distpath build/helper \
	    --workpath build/pyinstaller tools/lasgen.spec
	cp build/shader-decode/release/monzamac-shader-decode build/helper/lasgen/
	build/helper-venv/bin/python tools/shader_decoder_notices.py --deps build/shader-decode/release/deps \
	    --lock tools/shader_decode/Cargo.lock --manifest tools/shader_decode/Cargo.toml --output build/helper/lasgen/shader-decoder-licenses
	@du -sh build/helper/lasgen

build/helper-venv/.ok:
	$(or $(firstword $(wildcard build/deps/python/bin/python3.12)),python3.12) -m venv build/helper-venv
	build/helper-venv/bin/python -m pip install -q pyinstaller==6.22.3 capstone==5.0.9 unicorn==2.1.4 lz4==4.4.5
	touch $@

.PHONY: dmg all gen gen-helper gen-objs runtime-objs deps app

build/test_shaders: tools/test_shaders.m runtime/nvn/maxwell/translate.c runtime/nvn/maxwell/shader.h
	clang -O1 -fobjc-arc -framework Metal -framework Foundation -o $@ tools/test_shaders.m runtime/nvn/maxwell/translate.c

# Tests include the production TUs to inspect native views/state without adding app-only test hooks.
METAL_TEST_OBJS := $(filter-out $(B)/rt/nvn/metal.o $(B)/rt/nvn/renderer.o,$(RT_OBJ) $(BACKEND_OBJ) $(UI_OBJ) $(IMGUI_OBJ))
$(B)/tests/metal_backend.o: tools/test_metal_backend.m runtime/nvn/metal.m $(RT_HDRS)
	@mkdir -p $(dir $@)
	$(CC) $(RTFLAGS) -fobjc-arc -ftrivial-auto-var-init=pattern -c $< -o $@
$(B)/rt/nvn/renderer.o: runtime/nvn/shader_prepare.inc runtime/nvn/shader_recipe_record.inc
$(B)/tests/metal_renderer.o: tools/test_metal_renderer.m runtime/nvn/renderer.m runtime/nvn/shader_prepare.inc runtime/nvn/shader_recipe_record.inc $(RT_HDRS)
	@mkdir -p $(dir $@)
	$(CC) $(RTFLAGS) -fobjc-arc -c $< -o $@
$(B)/test_metal_renderer: $(METAL_TEST_OBJS) $(B)/tests/metal_backend.o $(B)/tests/metal_renderer.o
	$(CXX) -o $@ $^ $(LDFLAGS) -Wl,-dead_strip -Wl,-e,_metal_renderer_test_main
.PHONY: test-metal-renderer
test-metal-renderer: $(B)/test_metal_renderer
	$(B)/test_metal_renderer $(or $(CASE),all)

$(B)/test_saves_io: tools/test_saves_io.c runtime/saves.c runtime/saves.h
	@mkdir -p $(dir $@)
	$(CC) -O1 -Wall -Iruntime -o $@ tools/test_saves_io.c runtime/saves.c
.PHONY: test-saves-io
test-saves-io: $(B)/test_saves_io
	$(B)/test_saves_io

# Native bounded shader decoder: developer build dependency only; players get the helper.
build/shader-decode/release/monzamac-shader-decode: tools/shader_decode/Cargo.toml tools/shader_decode/Cargo.lock tools/shader_decode/src/main.rs
	MACOSX_DEPLOYMENT_TARGET=$(or $(MACOS_MIN),15.0) CARGO_TARGET_DIR=$(CURDIR)/build/shader-decode cargo build --locked --release --manifest-path tools/shader_decode/Cargo.toml

.PHONY: test-shader-catalog
test-shader-catalog:
	$(or $(PY),python3) tools/test_shader_catalog.py
	$(or $(PY),python3) tools/test_shader_catalog_update.py
	$(or $(PY),python3) tools/test_shader_inputs.py
	$(or $(PY),python3) tools/test_shader_decoder.py build/shader-decode/release/monzamac-shader-decode
