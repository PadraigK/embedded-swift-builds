# make emsdk EMSCRIPTEN=<version>
#   Installs Emscripten <version> into ~/emsdk/<version> on this machine.

EMSDK = $(HOME)/emsdk/$(EMSCRIPTEN)
EMCC = $(EMSDK)/upstream/emscripten/emcc

.PHONY: emsdk

emsdk: $(EMCC)

$(EMCC):
	@test -n "$(EMSCRIPTEN)" || { echo "EMSCRIPTEN isn't set: give the version Godot's web templates are built with, as in make emsdk EMSCRIPTEN=6.0.12" >&2; exit 1; }
	test -d $(EMSDK)/.git || git clone --quiet --depth 1 --branch $(EMSCRIPTEN) https://github.com/emscripten-core/emsdk.git $(EMSDK)
	$(EMSDK)/emsdk install $(EMSCRIPTEN)
	$(EMSDK)/emsdk activate $(EMSCRIPTEN)
	$(EMCC) --version | head -1
