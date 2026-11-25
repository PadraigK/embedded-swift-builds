# embedded-swift-builds

Builds parts of Embedded Swift that Swift doesn't publish for Godot's platforms, from Swift's own source with Swift's own build steps.

## What it builds

- Embedded `_Concurrency` for `wasm32-unknown-emscripten`, against the Emscripten version a Godot release's web templates are built with. Needs Swift 6.5. Not built yet.

## Inputs

- A Swift release: a checkout of Swift's repo at the release tag, with `llvm-project` beside it.
- An Emscripten version: the one the Godot release's web templates use (6.0.12 for Godot 4.8).

## Output

A folder for each pair of Swift release and Emscripten version, named for both, such as `swift6.5-emscripten6.0.12`. esg's `esg pack` copies it into the pack's web folder.

Open: where the built folders are kept for `esg pack` to copy from.

## Steps

`make emsdk EMSCRIPTEN=<version>` installs that Emscripten into `~/emsdk/<version>` on this machine. Each machine has its own install, since the binaries are per platform. Nothing is added to PATH or to a shell profile. Swift's build takes `~/emsdk/<version>/upstream/emscripten` as its Emscripten path.
