# embedded-swift-builds

Builds parts of Embedded Swift that Swift doesn't publish for Godot's platforms.

Most of the code here was written by an LLM.

## What it builds

- Embedded `_Concurrency` for Godot's web export, against the Emscripten version a Godot release's web templates are built with.
  - Swift 6.4.0: for `wasm32-unknown-none-wasm`. The Swift half is built for bare wasm and the C++ half against Emscripten's headers, by the recipe in `swift/6.4.0/`. Swift's own build has no step for this. The source is Swift's as tagged plus one patch, `swift/6.4.0/Deque-embedded-capacity.patch`: Concurrency's deque, which `AsyncStream` buffers in, uses the capacity it asked for in Embedded, as Swift does on OpenBSD. In Swift 6.4.0, `ManagedBuffer.capacity` asks the allocator for the block's size, and on bare wasm the standard library's shim answers 0, so the capacity comes out negative and the deque reads and writes outside its buffer. Swift 6.5 returns the requested count instead (swiftlang/swift#94297).
  - Swift 6.5: for `wasm32-unknown-emscripten`, with Swift's own build steps. Not here yet.
- Embedded Swift for Windows, `x86_64-unknown-windows-msvc`: the `Swift`, `Synchronization` and `_Concurrency` modules and `_Concurrency`'s archive. The swift.org toolchain for Windows ships no Embedded libraries, and Swift's build makes them only on Linux and macOS hosts.
  - Swift 6.4.0: by `swift/6.4.0/windows.sh`, which follows Swift's CMake at the tag step by step and says where each step comes from; the source lists in that folder are the CMake's Embedded sources. The source is Swift's as tagged plus the same deque patch, whose fix (the capacity asked for, as Swift 6.5 has it) is right on every platform. What Windows needs beyond Swift's CMake, each explained in the script:
    - Every module is built `-static`, as Swift builds its static libraries. Otherwise a Windows client takes the module for a DLL and reaches it through `dllimport` and lazy witness-table accessors that call the full runtime.
    - The C++ half is built against Visual Studio's and the Windows SDK's headers with the DLL C runtime (`/MD`) games link, `SWIFT_STATIC_STDLIB` (no `__declspec` on its exports), and Swift's Windows flags (`-mcx16` for its double-word atomics, the CRT macros).
    - Fallbacks (`swift/6.4.0/windows-fallbacks.txt`): the C++ half calls 18 functions an Embedded program may not define: some exist only outside Embedded, others are Swift functions a program contains only if it uses them. Linux's and the Mac's linkers drop the code that calls them when nothing reaches it; `lld-link` reports every undefined name in every object it loads. So the archive gives each a fallback through `/alternatename`, which a real definition overrides and which names the missing function and aborts if called. A link with `/OPT:REF` keeps a fallback only if live code calls it, which is the case Linux's linker reports; `make windows-check` fails such a link.

## Inputs

- A Godot version, for the web. Its file in `godot/` names the Emscripten version its web templates are built with: `godot/4.7.mk` says 4.0.20 and `godot/4.8.mk` says 6.0.12. A new Godot version gets a file once esg has certified it. Windows doesn't depend on it.
- A Swift release. Its folder in `swift/` holds the recipes. The build reads Swift's source from a checkout holding the release's tag, and compiles with the `swiftc` on PATH, which must be that release.

## Output

- The web: one folder for each pair of Swift release and Emscripten version, such as `out/swift6.4.0-emscripten6.0.12/`:
  - `wasm32-unknown-none-wasm/`: `_Concurrency.swiftmodule` and `libswift_Concurrency.a`, laid out as in an esg pack's folder for that target.
  - `LICENSE.txt`: Swift's license.
  - `BUILD.txt`: this repo's commit, the Swift tag, the Godot and Emscripten versions, and the compiler.
- Windows: one folder for each Swift release, such as `out/swift6.4.0-windows/`:
  - `resource/`: a resource dir laid out as the Linux toolchain's, for `-resource-dir`: `embedded/Swift.swiftmodule`, `embedded/Synchronization.swiftmodule` and `embedded/_Concurrency.swiftmodule`, each with its `x86_64-unknown-windows-msvc` module and doc; `embedded/x86_64-unknown-windows-msvc/libswift_Concurrency.a`; and the toolchain's clang headers and the SDK's shims, which the same compile reads.
  - `LICENSE.txt`: Swift's license.
  - `BUILD.txt`: this repo's commit, the Swift tag, the compiler, and the Visual Studio C++ tools and Windows SDK it built against.

The GitHub workflow builds both on every push to main, runs the Windows tests, and keeps each folder as the run's artifact. Run by hand with `release` ticked, it publishes each folder as a release named for it. Publishing stops if one already has a release.

## Steps

- `make emsdk GODOT=<version>` installs that Godot's Emscripten into `~/emsdk/<emscripten version>` on this machine. Nothing is added to PATH or to a shell profile.
- `make concurrency GODOT=<version> SWIFT=<version> SWIFT_SOURCE=<Swift checkout>` builds the web's `_Concurrency` into `out/`, after installing the Emscripten it needs. The work files go in `~/.embedded-swift-builds/`.
- `make pair GODOT=<version> SWIFT=<version>` prints the pair's name.
- On Windows, in Git Bash: `make windows SWIFT=<version> SWIFT_SOURCE=<Swift checkout>` builds the Windows folder into `out/`, in about two minutes, and `make windows-check` with the same arguments runs the tests below against it. It needs swift.org's toolchain for that release (its installer sets PATH and `SDKROOT`; open a new shell after installing), Visual Studio's C++ tools, Python and GNU make. `make windows-name SWIFT=<version>` prints the folder's name.

## The Windows tests

`make windows-check` runs Swift's own Embedded concurrency tests (`test/embedded/` at the tag) against the build: `tests/windows.py` replays each test's `// RUN:` lines with Swift's test substitutions spelt for Windows, as esg's `tests/concurrency/as_written.py` does for Linux, and checks the output with `tests/filecheck.py` (a copy of esg's). The 17 tests that run a program, with Swift's executor or their own: actors, `async let`, continuations, the current task, deleted methods, discarding and plain task groups, a module of its own, `AsyncStream` and its throwing form, task locals, throwing and typed-throwing tasks, and the three custom-executor tests. Left out: `concurrency-leaks`, which counts allocations by defining `malloc` and `free`, which a program can't do against the DLL C runtime; `concurrency-dynamic-isolation-link`, which needs `MainActor`, which Embedded Swift 6.4 has only on WASI.

What the runner adds for Windows, each said in it: Swift's cooperative executor and a small platform layer (`posix_memalign`, random bytes, `nanosleep`) compiled for the tests; Swift's Unicode tables for the test that compares strings (Swift's CMake builds them for every Embedded target but Windows, and a program for Windows brings its own, as esg's bindings do); `-static` on a module another one imports; function sections for the tests' C files; and `/OPT:REF` with a map on every link, which fails if the link kept a fallback. `tests/swift-<version>/` holds our changes to Swift's test files, each a patch that says why: on Windows `%p` prints no `0x`, and COFF writes `dllexport` into a line of IR a test checks.

## Using the Windows build

Compile with `-target x86_64-unknown-windows-msvc -resource-dir <the build>/resource -enable-experimental-feature Embedded` and `-Xcc -DSWIFT_STATIC_STDLIB` (so the shims declare the runtime's C functions without `dllimport`, matching the archive), and build any module another one imports `-static`. Link the archive with `lld-link` and the DLL C runtime. The program supplies the executor (the `swift_task_*Impl` functions of Swift's `ExecutorImpl.h`), `posix_memalign` (the Windows C runtime has none; the runtime frees with `free`, so it must come from `malloc`), and the Unicode tables if it compares or normalizes strings. Define `posix_memalign` outside a section of its own: a definition in a function section can be dropped by `/OPT:REF` when it is reached only through an import.

The archive needs the DLL C runtime, `msvcprt` (the C++ runtime's `_Xlength_error`, from `msvcp140.dll`) and `mincore` (`Clock.cpp`'s clocks, from Windows itself), all of which its objects name for the linker. `msvcp140.dll` is in the Visual C++ redistributable, which a program built this way already needs for `vcruntime140.dll`.

Reproducibility: two builds in different folders write the same bytes for everything except `Synchronization.swiftmodule`, whose bytes depend on the clang module it imports as the module cache built it; two clean builds in the same folder write identical files.
