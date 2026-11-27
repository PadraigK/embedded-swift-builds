#!/bin/bash
# Embedded Swift for x86_64-unknown-windows-msvc from Swift 6.4.0's source: the Swift, Synchronization and
# _Concurrency modules and _Concurrency's archive, which the Windows toolchain doesn't ship (Swift's own build makes
# them only on Linux and macOS hosts). They're written as a resource dir, laid out as the Linux toolchain's
# (embedded/<module>.swiftmodule/<triple>.swiftmodule, embedded/<triple>/libswift_Concurrency.a) beside the
# toolchain's clang headers and the SDK's shims, so a compiler given -resource-dir finds them as its own.
#
# Each step follows Swift's CMake at the tag (stdlib/public/core, Synchronization and Concurrency's CMakeLists.txt,
# stdlib/cmake/modules/AddSwiftStdlib.cmake); the lists in this folder are its Embedded sources. The Makefile runs it
# with SWIFT_SOURCE, TAG, BIN, SDK, PYTHON, BUILD and OUT set.
set -u -o pipefail
LISTS=$(cd "$(dirname "$0")" && pwd)
# BUILD and OUT absolute and as Windows spells them (C:/...). Absolute because the Windows driver resolves its SDK
# module-map overlay inside -resource-dir and fails on a relative one; Windows' spelling because Git Bash converts
# its own /c/... paths only for the programs it starts, and tests/windows.py reads the flags saved in runtime-flags.
mkdir -p "$BUILD" "$OUT" || exit 1
BUILD=$(cd "$BUILD" && pwd -W) || exit 1
OUT=$(cd "$OUT" && pwd -W) || exit 1
SRC=$BUILD/src
TRIPLE=x86_64-unknown-windows-msvc
RES=$OUT/resource
EMB=$RES/embedded
C=$SRC/stdlib/public/Concurrency
mkdir -p "$SRC" "$BUILD/gyb" "$BUILD/runtime" "$BUILD/gen/swift/Runtime" "$EMB/$TRIPLE" || exit 1

# The source as committed, whatever this machine's line-ending setting, so every machine compiles the same bytes.
git -C "$SWIFT_SOURCE" -c core.autocrlf=false archive "$TAG" \
  stdlib/public/core stdlib/public/Synchronization \
  stdlib/public/Concurrency stdlib/public/CompatibilityOverride stdlib/public/SwiftShims stdlib/public/runtime \
  stdlib/public/stubs stdlib/public/Threading stdlib/include include/swift \
  utils/gyb.py utils/SwiftIntTypes.py utils/SwiftFloatingPointTypes.py utils/SwiftAtomics.py utils/gyb_stdlib_support.py \
  utils/GYBUnicodeDataUtils.py utils/UnicodeData utils/availability-macros.def \
  | tar -x -C "$SRC" || exit 1
# The patches in this folder are fixes to Swift's source; each says why in its header.
for p in "$LISTS"/*.patch; do
  patch -s -p1 -d "$SRC" < "$p" || exit 1
done

# The resource dir's other parts are the toolchain's: the clang headers its compiler reads, and the SDK's shims
# (SwiftShims), which the stdlib and every client import.
cp -R "$BIN/../lib/swift/clang" "$RES/clang" || exit 1
cp -R "$SDK/usr/lib/swift/shims" "$RES/shims" || exit 1

# A list in this folder, one path per line.
list() { tr -d '\r' < "$LISTS/$1"; }

# gyb as Swift's CMake runs it (SwiftHandleGybSources.cmake, SWIFT_GYB_FLAGS), with no line directives, so no build
# path is written into the modules. The templates import Swift's utils/ modules.
gyb() { # gyb <template> <output>
  "$PYTHON" -I -c "import sys; sys.path.insert(0, sys.argv.pop(1)); import gyb; gyb.main()" "$SRC/utils" \
    -DCMAKE_SIZEOF_VOID_P=8 \
    -DunicodeGraphemeBreakPropertyFile="$SRC/utils/UnicodeData/GraphemeBreakProperty.txt" \
    -DunicodeGraphemeBreakTestFile="$SRC/utils/UnicodeData/GraphemeBreakTest.txt" \
    --line-directive '' -o "$2" "$1"
}

# A module's sources, into the array SOURCES: each list's entries under <dir>, a .gyb entry expanded into
# gyb/<module>/ first.
collect() { # collect <module> <dir> <list>...
  local module=$1 dir=$2 f out; shift 2
  SOURCES=()
  mkdir -p "$BUILD/gyb/$module" || return 1
  for l in "$@"; do
    while read -r f; do
      case "$f" in
        *.gyb) out="$BUILD/gyb/$module/$(basename "${f%.gyb}")"; gyb "$dir/$f" "$out" || return 1; SOURCES+=("$out") ;;
        *) SOURCES+=("$dir/$f") ;;
      esac
    done < <(list "$l")
  done
}

# Under Embedded Swift every availability macro expands to * (the Embedded blocks of the CMakeLists).
AVAIL=()
while read -r line; do
  case "$line" in ''|\#*) continue ;; esac
  name="${line%%:*}"
  AVAIL+=(-Xfrontend -define-availability -Xfrontend "$name:*")
  case "$name" in SwiftStdlib*) AVAIL+=(-Xfrontend -define-availability -Xfrontend "${name/SwiftStdlib/StdlibDeploymentTarget}:*") ;; esac
done < <(tr -d '\r' < "$SRC/utils/availability-macros.def")

# Every module: AddSwiftStdlib.cmake's flags for an IS_STDLIB, IS_FRAGILE library in the "embedded" SDK, and -static,
# which SwiftSource.cmake gives a STATIC library. Swift builds none of these for a windows-msvc target, and on Windows
# -static matters: a client otherwise takes the module for a DLL and reaches what it and its C declarations provide
# through dllimport (an import lld-link won't resolve from an archive, or resolves but then drops under /OPT:REF) and
# through lazy witness-table accessors that call the full runtime. (On Linux and macOS it changes nothing.)
# The clang module cache is the build's own, not the user's: nothing from another build or toolchain reaches it.
COMMON=(-target "$TRIPLE" -resource-dir "$RES" -static -O -whole-module-optimization -swift-version 5
  -module-cache-path "$BUILD/module-cache"
  -enable-experimental-feature Embedded -Xcc -ffreestanding
  -Xfrontend -disable-objc-interop -no-link-objc-runtime
  -runtime-compatibility-version none -disable-autolinking-runtime-compatibility-dynamic-replacements
  -Xfrontend -disable-autolinking-runtime-compatibility-concurrency
  -enable-upcoming-feature MemberImportVisibility -strict-memory-safety
  -enable-experimental-feature SuppressedAssociatedTypesWithDefaults -enable-experimental-feature NonescapableTypes
  -enable-experimental-feature Lifetimes -enable-experimental-feature AddressableParameters
  -enable-experimental-feature AllowUnsafeAttribute -enable-experimental-feature Extern
  "${AVAIL[@]}")
# Swift and Synchronization, ONLY_SWIFTMODULE: the stdlib's compile conditions.
STDLIB=(-Xfrontend -empty-abi-descriptor
  -D SWIFT_ENABLE_EXPERIMENTAL_CONCURRENCY -D SWIFT_ENABLE_SYNCHRONIZATION -D SWIFT_STDLIB_ENABLE_UNICODE_DATA
  -D SWIFT_STDLIB_HAS_COMMANDLINE -D SWIFT_STDLIB_HAS_STDIN -D SWIFT_STDLIB_HAS_ENVIRON -Xcc -DSWIFT_STDLIB_HAS_ENVIRON
  -enable-experimental-feature LifetimeDependence -enable-experimental-feature InoutLifetimeDependence
  -enable-experimental-feature LifetimeDependenceMutableAccessors)

# swiftc writes no source-info file: Swift's toolchains ship none, and it would hold this machine's paths. It runs in
# the build folder and names its sources from there (src/..., gyb/...), since a module records their paths as given
# (#filePath in Synchronization's inlinable code): so every machine writes the same bytes. Its arguments go in a
# response file, since a module's sources pass Windows' 32,767-character command line in a deep folder; each is
# quoted, with its " and \ escaped, as Windows reads a command line.
module() { # module <name> <flags>... (with SOURCES, all under BUILD)
  local name=$1 arg; shift
  mkdir -p "$EMB/$name.swiftmodule" || return 1
  echo "$name: ${#SOURCES[@]} files"
  for arg in "${COMMON[@]}" -module-name "$name" "$@" \
      -emit-module -emit-module-path "$EMB/$name.swiftmodule/$TRIPLE.swiftmodule" -avoid-emit-module-source-info \
      "${SOURCES[@]#"$BUILD/"}"; do
    arg=${arg//\\/\\\\}
    printf '"%s"\n' "${arg//\"/\\\"}"
  done > "$BUILD/$name.rsp" || return 1
  (cd "$BUILD" && "$BIN/swiftc" "@$name.rsp") > "$BUILD/$name.log" 2>&1 || { cat "$BUILD/$name.log"; return 1; }
}

# Swift: core/CMakeLists.txt's SWIFTLIB_EMBEDDED_SOURCES and SWIFTLIB_EMBEDDED_GYB_SOURCES, with
# swift_stdlib_compile_flags. Its -plugin-path is the toolchain's host plugins, which the Windows toolchain keeps in
# usr/bin (SwiftMacros.dll and the rest), not usr/lib/swift/host/plugins.
collect Swift "$SRC/stdlib/public/core" stdlib-sources.txt stdlib-gyb-sources.txt || exit 1
module Swift "${STDLIB[@]}" -parse-stdlib -nostdimport \
  -Xfrontend -group-info-path -Xfrontend "$SRC/stdlib/public/core/GroupInfo.json" \
  -Xfrontend -enable-experimental-concise-pound-file -Xfrontend -enforce-exclusivity=unchecked \
  -Xllvm -sil-inline-generics -Xllvm -sil-partial-specialization \
  -plugin-path "$BIN" \
  -enable-experimental-feature Macros -enable-experimental-feature FreestandingMacros \
  -enable-experimental-feature BitwiseCopyable -enable-experimental-feature ValueGenerics \
  -enable-experimental-feature AddressableTypes -enable-experimental-feature Reparenting \
  -enable-experimental-feature BorrowAndMutateAccessors -enable-experimental-feature BorrowInout || exit 1

# Synchronization: the atomics, as for any target but wasm (Synchronization/CMakeLists.txt).
collect Synchronization "$SRC/stdlib/public/Synchronization" synchronization-sources.txt synchronization-gyb-sources.txt || exit 1
module Synchronization "${STDLIB[@]}" -enable-builtin-module \
  -enable-experimental-feature RawLayout -enable-experimental-feature StaticExclusiveOnly || exit 1

# _Concurrency's Swift half: Concurrency/CMakeLists.txt's sources and flags for an Embedded target other than wasm,
# which has no platform executor (PlatformExecutorNone.swift): the program supplies it. Its object is empty, as
# Swift builds its own Embedded libraries; clients compile what they use from the module.
collect _Concurrency "$C" swift-sources.txt || exit 1
SOURCES+=("$C/PlatformExecutorNone.swift")
for g in Task+init.swift.gyb TaskGroup+addTask.swift.gyb Task+immediate.swift.gyb; do
  gyb "$C/$g" "$BUILD/gyb/_Concurrency/${g%.gyb}" || exit 1
  SOURCES+=("$BUILD/gyb/_Concurrency/${g%.gyb}")
done
module _Concurrency -parse-stdlib -parse-as-library -Xfrontend -emit-empty-object-file \
  -DSWIFT_CONCURRENCY_EMBEDDED -I "$C/InternalShims" -enable-experimental-feature IsolatedAny \
  -Xfrontend -disable-implicit-concurrency-module-import -Xfrontend -disable-implicit-string-processing-module-import \
  -c -o "$BUILD/_Concurrency.o" || exit 1

# _Concurrency's C++ half: SWIFT_RUNTIME_CONCURRENCY_C_SOURCES with the Embedded block's settings (single-threaded,
# no threading package, no dispatch), compiled against Visual Studio's and the Windows SDK's headers, which clang
# finds itself. From AddSwiftStdlib.cmake's flags for Windows: the DLL C runtime games link (-fms-runtime-lib=dll:
# _MT, _DLL and msvcrt), the CRT macros, and -mcx16 for the double-word atomics.
printf '#ifndef SWIFT_RUNTIME_CMAKECONFIG_H\n#define SWIFT_RUNTIME_CMAKECONFIG_H\n#define SWIFT_VERSION_MAJOR "6"\n#define SWIFT_VERSION_MINOR "4"\n#endif\n' \
  > "$BUILD/gen/swift/Runtime/CMakeConfig.h" || exit 1
# -mno-incremental-linker-compatible: no timestamp in an object's header, so every build writes the same bytes.
FLAGS=(--target=$TRIPLE -Os -std=c++17 -fms-runtime-lib=dll -mcx16 -mno-incremental-linker-compatible
  -fno-exceptions -fno-cxx-exceptions -fno-unwind-tables -fno-rtti
  -ffunction-sections -fdata-sections -fswift-async-fp=never -fvisibility=hidden
  -I "$BUILD/gen" -I "$SRC/include" -I "$SRC/stdlib/include" -I "$SRC/stdlib/public/SwiftShims" -I "$C"
  -DSWIFT_RUNTIME -DSWIFT_LIB_SUBDIR='"embedded"' -DSWIFT_ARCH='"x86_64"'
  -DNDEBUG -U_DEBUG -DSWIFT_OBJC_INTEROP=0 -DSWIFT_LIBRARY_EVOLUTION=0
  -DSWIFT_STDLIB_SINGLE_THREADED_CONCURRENCY -DSWIFT_THREADING_NONE
  -DSWIFT_STDLIB_HAS_DLSYM=0 -DSWIFT_STDLIB_HAS_DARWIN_LIBMALLOC=0
  -DSWIFT_CONCURRENCY_EMBEDDED=1 -DSWIFT_RUNTIME_EMBEDDED=1 -DSWIFT_CONCURRENCY_ENABLE_DISPATCH=0
  -D__STDC_WANT_LIB_EXT1__=1 -DSWIFT_TARGET_LIBRARY_NAME=swift_Concurrency -Dswift_Concurrency_EXPORTS
  -D_CRT_SECURE_NO_WARNINGS -D_CRT_NONSTDC_NO_WARNINGS -D_CRT_USE_BUILTIN_OFFSETOF
  -D_CRT_USE_WINAPI_FAMILY_DESKTOP_APP -D_ENABLE_ATOMIC_ALIGNMENT_FIX -D_ENABLE_EXTENDED_ALIGNED_STORAGE=1
  -D_HAS_STATIC_RTTI=0
  -DSWIFT_STATIC_STDLIB)
# SWIFT_RUNTIME, SWIFT_LIB_SUBDIR and SWIFT_ARCH are what AddSwiftStdlib.cmake gives every runtime source. Without
# SWIFT_RUNTIME, swift/Basic/LLVM.h declares function_ref in ::llvm, and the files that include it before the runtime's
# own LLVM (in __swift::__runtime::llvm) call a TaskStatus.cpp function by a name it doesn't define.
# SWIFT_STATIC_STDLIB is Swift's setting for its static libraries on Windows (shims/Visibility.h): its exports carry no
# __declspec, so the archive neither expects its symbols from a DLL nor exports them from the game's.

# The fallbacks for the names in windows-fallbacks.txt: one function each, in its own section so a link with
# /OPT:REF drops it unless something live calls it, and an /alternatename that makes it the name's definition when
# nothing else defines it. Every runtime object asks the linker for the marker (/include), so loading any of them
# loads this object and its directives.
{
  echo '// Written by windows.sh from windows-fallbacks.txt.'
  echo '#include <stdio.h>'
  echo '#include <stdlib.h>'
  echo 'char swift_embedded_coff_fallbacks;'
  echo '__declspec(noreturn) static void missing(const char *name) {'
  echo '  fprintf(stderr, "Embedded _Concurrency: %s was called, and the program does not define it "'
  echo '          "(embedded-swift-builds, windows-fallbacks.txt)\n", name);'
  echo '  abort();'
  echo '}'
  n=0
  while read -r name _; do
    case "$name" in ''|\#*) continue ;; esac
    echo "void swift_embedded_fallback_$n(void) { missing(\"$name\"); }"
    echo "#pragma comment(linker, \"/alternatename:$name=swift_embedded_fallback_$n\")"
    n=$((n + 1))
  done < <(list windows-fallbacks.txt)
} > "$BUILD/gen/fallbacks.c" || exit 1
printf '#pragma comment(linker, "/include:swift_embedded_coff_fallbacks")\n' > "$BUILD/gen/fallbacks-include.h" || exit 1
(cd "$BUILD" && "$BIN/clang" --target=$TRIPLE -Os -std=c17 -fms-runtime-lib=dll -mno-incremental-linker-compatible \
  -ffunction-sections -fdata-sections \
  -D_CRT_SECURE_NO_WARNINGS -c gen/fallbacks.c -o "$BUILD/runtime/fallbacks.c.obj") || exit 1

# Swift's list for every target has Clock.cpp. The web recipe leaves it out, its 6.4.0 source having no Emscripten
# branch; Windows has one. Its clocks are in mincore (as Concurrency/CMakeLists.txt links on Windows), which its
# object names for the linker.
# Each is compiled in Concurrency/ and named from there, as the Microsoft C++ ABI names an anonymous namespace with a
# hash of the source's path as given: so every machine writes the same bytes.
printf '#pragma comment(lib, "mincore")\n' > "$BUILD/gen/mincore.h" || exit 1
count=0
while read -r f; do
  b=$(basename "$f")
  extra=()
  [ "$b" = Clock.cpp ] && extra=(-include "$BUILD/gen/mincore.h")
  (cd "$C" && "$BIN/clang++" "${FLAGS[@]}" -include "$BUILD/gen/fallbacks-include.h" "${extra[@]}" -c "$f" \
    -o "$BUILD/runtime/$b.obj") > "$BUILD/runtime/$b.log" 2>&1 || { cat "$BUILD/runtime/$b.log"; exit 1; }
  count=$((count + 1))
done < <(list c-sources.txt; echo Clock.cpp)
echo "_Concurrency C++: $count files, and $(grep -c '^void ' "$BUILD/gen/fallbacks.c") fallbacks"
# For tests/windows.py, which compiles Swift's test-only executor as the archive's sources are compiled.
printf '%s\0' "${FLAGS[@]}" > "$BUILD/runtime-flags" || exit 1

rm -f "$EMB/$TRIPLE/libswift_Concurrency.a"
"$BIN/llvm-ar" rcs "$EMB/$TRIPLE/libswift_Concurrency.a" "$BUILD/_Concurrency.o" "$BUILD"/runtime/*.obj || exit 1
