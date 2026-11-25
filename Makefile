# make emsdk GODOT=<version>
#   Installs the Emscripten that Godot <version>'s web templates are built with, into ~/emsdk/<emscripten version>.
# make concurrency GODOT=<version> SWIFT=<version> SWIFT_SOURCE=<a Swift checkout holding the release's tag>
#   Builds Embedded _Concurrency for the web into out/swift<version>-emscripten<version>/, with the swiftc on PATH.

GODOT_FILE = godot/$(GODOT).mk
ifeq ($(wildcard $(GODOT_FILE)),)
$(error No file for Godot "$(GODOT)" in godot/: give a version that has one, as in GODOT=4.8)
endif
include $(GODOT_FILE)

EMSDK = $(HOME)/emsdk/$(EMSCRIPTEN)
EMCC = $(EMSDK)/upstream/emscripten/emcc

PAIR = swift$(SWIFT)-emscripten$(EMSCRIPTEN)
TAG = swift-$(SWIFT)-RELEASE
BUILD = $(HOME)/.embedded-swift-builds/$(PAIR)
OUT = out/$(PAIR)
BIN = $(dir $(realpath $(shell command -v swiftc)))

.PHONY: emsdk concurrency pair

emsdk: $(EMCC)

$(EMCC):
	test -d $(EMSDK)/.git || git clone --quiet --depth 1 --branch $(EMSCRIPTEN) https://github.com/emscripten-core/emsdk.git $(EMSDK)
	$(EMSDK)/emsdk install $(EMSCRIPTEN)
	$(EMSDK)/emsdk activate $(EMSCRIPTEN)
	$(EMCC) --version | head -1

concurrency: $(EMCC)
	@test -f "swift/$(SWIFT)/build.sh" || { echo "No recipe for Swift \"$(SWIFT)\" in swift/: give a version that has one, as in SWIFT=6.4.0" >&2; exit 1; }
	@test -n "$(SWIFT_SOURCE)" && git -C "$(SWIFT_SOURCE)" rev-parse -q --verify "$(TAG)^{commit}" > /dev/null || { echo "SWIFT_SOURCE \"$(SWIFT_SOURCE)\" has no tag $(TAG): give a Swift checkout that holds it" >&2; exit 1; }
	@test -x "$(BIN)swiftc" || { echo "No swiftc on PATH" >&2; exit 1; }
	rm -rf "$(BUILD)" "$(OUT)"
	SWIFT_SOURCE="$(SWIFT_SOURCE)" TAG=$(TAG) BIN=$(BIN) EM=$(EMSDK)/upstream/emscripten/system BUILD=$(BUILD) OUT=$(OUT)/wasm32-unknown-none-wasm bash swift/$(SWIFT)/build.sh
	git -C "$(SWIFT_SOURCE)" show $(TAG):LICENSE.txt > $(OUT)/LICENSE.txt
	{ echo "embedded-swift-builds $$(git rev-parse --short HEAD)$$(git diff --quiet HEAD || echo ', with uncommitted changes')"; \
	  echo "Swift source: $(TAG)"; echo "Godot $(GODOT): Emscripten $(EMSCRIPTEN)"; "$(BIN)swiftc" --version 2>&1 | head -1; } > $(OUT)/BUILD.txt
	cat $(OUT)/BUILD.txt

pair:
	@echo $(PAIR)
