# embedded-swift-builds

Builds parts of Embedded Swift that Swift doesn't publish for Godot's platforms.

Most of the code here was written by an LLM.

## What it builds

- Embedded `_Concurrency` for Godot's web export, against the Emscripten version a Godot release's web templates are built with.
  - Swift 6.4.0: for `wasm32-unknown-none-wasm`. The Swift half is built for bare wasm and the C++ half against Emscripten's headers, by the recipe in `swift/6.4.0/`. Swift's own build has no step for this. The source is Swift's as tagged plus one patch, `swift/6.4.0/Deque-embedded-capacity.patch`: Concurrency's deque, which `AsyncStream` buffers in, uses the capacity it asked for in Embedded, as Swift does on OpenBSD. In Swift 6.4.0, `ManagedBuffer.capacity` asks the allocator for the block's size, and on bare wasm the standard library's shim answers 0, so the capacity comes out negative and the deque reads and writes outside its buffer. Swift 6.5 returns the requested count instead (swiftlang/swift#94297).
  - Swift 6.5: for `wasm32-unknown-emscripten`, with Swift's own build steps. Not here yet.

## Inputs

- A Godot version. Its file in `godot/` names the Emscripten version its web templates are built with: `godot/4.7.mk` says 4.0.20 and `godot/4.8.mk` says 6.0.12. A new Godot version gets a file once esg has certified it.
- A Swift release. Its folder in `swift/` holds the recipe. The build reads Swift's source from a checkout holding the release's tag, and compiles with the `swiftc` on PATH, which must be that release.

## Output

One folder for each pair of Swift release and Emscripten version, such as `out/swift6.4.0-emscripten6.0.12/`:

- `wasm32-unknown-none-wasm/`: `_Concurrency.swiftmodule` and `libswift_Concurrency.a`, laid out as in an esg pack's folder for that target.
- `LICENSE.txt`: Swift's license.
- `BUILD.txt`: this repo's commit, the Swift tag, the Godot and Emscripten versions, and the compiler.

The GitHub workflow builds the folder on every push to main and keeps it as the run's artifact. Run by hand with `release` ticked, it publishes the folder as a release named for the pair. Publishing stops if the pair already has a release.

## Steps

- `make emsdk GODOT=<version>` installs that Godot's Emscripten into `~/emsdk/<emscripten version>` on this machine. Nothing is added to PATH or to a shell profile.
- `make concurrency GODOT=<version> SWIFT=<version> SWIFT_SOURCE=<Swift checkout>` builds `_Concurrency` into `out/`, after installing the Emscripten it needs. The work files go in `~/.embedded-swift-builds/`.
- `make pair GODOT=<version> SWIFT=<version>` prints the pair's name.
