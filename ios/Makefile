# iOS build of the translated game: static libraries for the Xcode target in ios/app.
#   make -f ios/Makefile libs -j8   libgame.a + the two rebased DLL libraries + the iOS runtime sources
# Translate first: `make gen` (exe), and for the DLLs rebased into the claimed strip (see ios/README.md):
#   .venv/bin/python framework/tools/recomp64.py orig_superscript.dll gen_superscript_ios --module superscriptx64 --rebase 155000000
#   .venv/bin/python framework/tools/recomp64.py orig_bink.dll gen_bink_ios --module bink2w64 --rebase 156000000 --no-abi-trim
FW     = framework
OUT    = ios/build
SDK   := $(shell xcrun --sdk iphoneos --show-sdk-path)
CC     = xcrun clang -target arm64-apple-ios26.0 -isysroot $(SDK)
GEN_CFLAGS = -O2 -g0 -Wno-unused-variable -Wno-unused-but-set-variable -Wno-unused-label -DRT_RELAX_FP -I$(FW)/runtime

define LIB
$(1)_SRC = $$(sort $$(wildcard $(2)/code_*.c)) $(2)/tables.c
$(1)_OBJ = $$(patsubst %.c,$$(OUT)/%.o,$$($(1)_SRC))
$$(OUT)/$(2)/%.o: $(2)/%.c $(FW)/runtime/cpu.h $(FW)/runtime/tables.h
	@mkdir -p $$(dir $$@)
	$$(CC) $$(GEN_CFLAGS) $(3) -c $$< -o $$@
$$(OUT)/lib$(1).a: $$($(1)_OBJ)
	rm -f $$@; ar rcs $$@ $$^
endef
$(eval $(call LIB,game,gen,))
$(eval $(call LIB,superscriptx64,gen_superscript_ios,))
$(eval $(call LIB,bink2w64,gen_bink_ios,-DRT_TSO=0))

libs: $(OUT)/libgame.a $(OUT)/libsuperscriptx64.a $(OUT)/libbink2w64.a $(OUT)/rt.c $(OUT)/steam.c $(OUT)/kernel32.c $(OUT)/vulkan.c
# framework/runtime/rt.c with the iOS guest-strip patch applied (the framework submodule stays pristine)
$(OUT)/rt.c: $(FW)/runtime/rt.c ios/patches/framework/0001-ios-claim-guest-strip.patch
	@mkdir -p $(OUT)
	cp $(FW)/runtime/rt.c $@
	patch $@ < ios/patches/framework/0001-ios-claim-guest-strip.patch
# Use native present modes on iOS and remove the framework's adaptive timer.
$(OUT)/vulkan.c: $(FW)/runtime/vulkan.c ios/patches/framework/0002-ios-vulkan-standard-vsync.patch
	@mkdir -p $(OUT)
	patch -o $@.tmp $< < ios/patches/framework/0002-ios-vulkan-standard-vsync.patch
	mv $@.tmp $@
# steam.c with a short offline-failure delay: the stubbed Steam ticket request otherwise takes 10 s per attempt (30 s of
# title-storage login retries at startup). DOOM_ONLINE_LOGIN=1 restores the original delay.
$(OUT)/steam.c: $(FW)/runtime/steam.c
	@mkdir -p $(OUT)
	sed 's|^\#define OFFLINE_DELAY_MS 10000.*|static int offline_delay_ms(void) { const char *e = getenv("DOOM_ONLINE_LOGIN"); return e \&\& *e == 0x31 ? 10000 : 300; }\n\#define OFFLINE_DELAY_MS offline_delay_ms()|' $< > $@
# kernel32.c reporting an 8 GB machine: the framework claims 16 GB, so the game sizes its caches for it and grows past the
# ~6 GB an iPhone app may use (footprint climbed to 5.9 GB and the game then crashed on a failed allocation).
$(OUT)/kernel32.c: $(FW)/runtime/kernel32.c
	@mkdir -p $(OUT)
	sed -e 's|total = 16ull << 30, avail = 12ull << 30|total = 8ull << 30, avail = 5ull << 30|' -e 's|wr64(b + 8, 16ull << 30); wr64(b + 16, 12ull << 30); wr64(b + 24, 32ull << 30); wr64(b + 32, 24ull << 30)|wr64(b + 8, 8ull << 30); wr64(b + 16, 5ull << 30); wr64(b + 24, 16ull << 30); wr64(b + 32, 10ull << 30)|' $< > $@
ios/runtime/display_ios.c: $(FW)/runtime/display.c ios/scripts/gen_display_ios.py
	python3 ios/scripts/gen_display_ios.py .
.PHONY: libs
