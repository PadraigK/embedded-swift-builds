# make emsdk GODOT=<version>
#   Installs the Emscripten that Godot <version>'s web templates are built with, into ~/emsdk/<emscripten version>.

GODOT_FILE = godot/$(GODOT).mk
ifeq ($(wildcard $(GODOT_FILE)),)
$(error No file for Godot "$(GODOT)" in godot/: give a version that has one, as in make emsdk GODOT=4.8)
endif
include $(GODOT_FILE)

EMSDK = $(HOME)/emsdk/$(EMSCRIPTEN)
EMCC = $(EMSDK)/upstream/emscripten/emcc

.PHONY: emsdk

emsdk: $(EMCC)

$(EMCC):
	test -d $(EMSDK)/.git || git clone --quiet --depth 1 --branch $(EMSCRIPTEN) https://github.com/emscripten-core/emsdk.git $(EMSDK)
	$(EMSDK)/emsdk install $(EMSCRIPTEN)
	$(EMSDK)/emsdk activate $(EMSCRIPTEN)
	$(EMCC) --version | head -1
