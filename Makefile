# make emsdk GODOT=<version>
#   Installs the Emscripten that Godot <version>'s web templates are built with, into ~/emsdk/<emscripten version>.
# make concurrency GODOT=<version> SWIFT=<version> SWIFT_SOURCE=<a Swift checkout holding the release's tag>
#   Builds Embedded _Concurrency for the web into out/swift<version>-emscripten<version>/, with the swiftc on PATH.
# make windows SWIFT=<version> SWIFT_SOURCE=<a Swift checkout holding the release's tag>
#   On Windows, builds Embedded Swift for x86_64-unknown-windows-msvc into out/swift<version>-windows/: the Swift,
#   Synchronization and _Concurrency modules and _Concurrency's archive, in a resource dir. With the swiftc on PATH.
# make windows-check SWIFT=<version> SWIFT_SOURCE=<the same checkout>
#   Runs Swift's Embedded concurrency tests against that build (tests/windows.py).

TAG = swift-$(SWIFT)-RELEASE
# The home folder as the shell spells it: Windows make's HOME has backslashes, which an unquoted shell word loses.
HOME_DIR := $(shell cd ~ && pwd)
# The folder of the swiftc on PATH, through any symlink, with a trailing slash. (The shell resolves it: make's
# realpath can't read Git Bash's /c/... paths.)
BIN := $(shell s=$$(command -v swiftc) && cd "$$(dirname "$$(readlink -f "$$s")")" && pwd)/

.PHONY: emsdk concurrency pair windows windows-check windows-name

# The web: its Emscripten comes from the Godot version.
ifneq ($(filter emsdk concurrency pair,$(MAKECMDGOALS)),)
GODOT_FILE = godot/$(GODOT).mk
ifeq ($(wildcard $(GODOT_FILE)),)
$(error No file for Godot "$(GODOT)" in godot/: give a version that has one, as in GODOT=4.8)
endif
include $(GODOT_FILE)
endif

EMSDK = $(HOME_DIR)/emsdk/$(EMSCRIPTEN)
EMCC = $(EMSDK)/upstream/emscripten/emcc
PAIR = swift$(SWIFT)-emscripten$(EMSCRIPTEN)
BUILD = $(HOME_DIR)/.embedded-swift-builds/$(PAIR)
OUT = out/$(PAIR)

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

# Windows: run from Git Bash, with the swift.org toolchain on PATH and SDKROOT set (its installer sets both).
WINDOWS = swift$(SWIFT)-windows
WINDOWS_BUILD = $(HOME_DIR)/.embedded-swift-builds/$(WINDOWS)
WINDOWS_OUT = out/$(WINDOWS)
# Python for gyb and the tests. On Windows "python3" is often the Microsoft Store's stand-in, which runs nothing.
PYTHON ?= $(shell for p in python3 python; do $$p -c '' 2>/dev/null && { echo $$p; break; }; done)

windows-name:
	@echo $(WINDOWS)

windows:
	@test -f "swift/$(SWIFT)/windows.sh" || { echo "No Windows recipe for Swift \"$(SWIFT)\" in swift/: give a version that has one, as in SWIFT=6.4.0" >&2; exit 1; }
	@test -n "$(SWIFT_SOURCE)" && git -C "$(SWIFT_SOURCE)" rev-parse -q --verify "$(TAG)^{commit}" > /dev/null || { echo "SWIFT_SOURCE \"$(SWIFT_SOURCE)\" has no tag $(TAG): give a Swift checkout that holds it" >&2; exit 1; }
	@test -x "$(BIN)swiftc" || { echo "No swiftc on PATH" >&2; exit 1; }
	@"$(BIN)swiftc" --version 2>&1 | grep -qE "Swift version ($(SWIFT)|$(patsubst %.0,%,$(SWIFT))) " || { echo "The swiftc on PATH isn't Swift $(SWIFT): $$("$(BIN)swiftc" --version 2>&1 | head -1)" >&2; exit 1; }
	@test -n "$$SDKROOT" || { echo "SDKROOT isn't set; the Swift installer sets it, but not in shells opened before the install" >&2; exit 1; }
	@test -n "$(PYTHON)" || { echo "No Python on PATH (python3 or python)" >&2; exit 1; }
	rm -rf "$(WINDOWS_BUILD)" "$(WINDOWS_OUT)"
	SWIFT_SOURCE="$(SWIFT_SOURCE)" TAG=$(TAG) BIN=$(BIN) SDK="$$(cygpath -u "$$SDKROOT")" PYTHON=$(PYTHON) BUILD=$(WINDOWS_BUILD) OUT=$(WINDOWS_OUT) bash swift/$(SWIFT)/windows.sh
	git -C "$(SWIFT_SOURCE)" show $(TAG):LICENSE.txt > $(WINDOWS_OUT)/LICENSE.txt
	{ echo "embedded-swift-builds $$(git rev-parse --short HEAD)$$(git diff --quiet HEAD || echo ', with uncommitted changes')"; \
	  echo "Swift source: $(TAG)"; echo "Target: x86_64-unknown-windows-msvc"; "$(BIN)swiftc" --version 2>&1 | head -1; \
	  "$(BIN)clang" --target=x86_64-unknown-windows-msvc -### -c -x c /dev/null 2>&1 \
	    | grep -oE 'MSVC[/\\]+[0-9.]+|Windows Kits[/\\]+10[/\\]+Include[/\\]+[0-9.]+' | sort -u \
	    | sed -E 's/^MSVC[^0-9]+/Visual Studio C++ tools: /; s/^Windows Kits[^0-9]+10[^0-9]+/Windows SDK: /'; } > $(WINDOWS_OUT)/BUILD.txt
	cat $(WINDOWS_OUT)/BUILD.txt

windows-check:
	@test -f "$(WINDOWS_OUT)/BUILD.txt" || { echo "No build in $(WINDOWS_OUT): run make windows first" >&2; exit 1; }
	$(PYTHON) -I tests/windows.py "$$(cygpath -m "$(WINDOWS_BUILD)")" "$$(cygpath -m "$(WINDOWS_OUT)")" \
	  "$$(cygpath -m "$(SWIFT_SOURCE)")" $(TAG) "$$(cygpath -m "$(WINDOWS_BUILD)-tests")"
