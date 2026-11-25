#!/bin/bash
# Embedded _Concurrency for wasm32-unknown-none-wasm from Swift 6.4.0's source: the Swift half for bare wasm, the C++
# half against Emscripten's headers. The Makefile runs it with SWIFT_SOURCE, TAG, BIN, EM, BUILD and OUT set.
set -u -o pipefail
LISTS=$(cd "$(dirname "$0")" && pwd)
SRC=$BUILD/src
C=$SRC/stdlib/public/Concurrency
mkdir -p "$SRC" "$BUILD/gyb" "$BUILD/runtime" "$BUILD/gen/swift/Runtime" "$OUT/_Concurrency.swiftmodule" || exit 1

git -C "$SWIFT_SOURCE" archive "$TAG" \
  stdlib/public/Concurrency stdlib/public/CompatibilityOverride stdlib/public/SwiftShims stdlib/public/runtime \
  stdlib/public/stubs stdlib/public/Threading stdlib/include include/swift utils/gyb.py utils/availability-macros.def \
  | tar -x -C "$SRC" || exit 1

printf '#ifndef SWIFT_RUNTIME_CMAKECONFIG_H\n#define SWIFT_RUNTIME_CMAKECONFIG_H\n#define SWIFT_VERSION_MAJOR "6"\n#define SWIFT_VERSION_MINOR "4"\n#endif\n' \
  > "$BUILD/gen/swift/Runtime/CMakeConfig.h" || exit 1

for g in Task+init.swift.gyb TaskGroup+addTask.swift.gyb Task+immediate.swift.gyb; do
  python3 -I "$SRC/utils/gyb.py" --line-directive '' -o "$BUILD/gyb/${g%.gyb}" "$C/$g" || exit 1
done

SOURCES=()
while read -r f; do SOURCES+=("$C/$f"); done < "$LISTS/swift-sources.txt"
SOURCES+=("$C/PlatformExecutorNone.swift" "$BUILD"/gyb/*.swift)
AVAIL=()
while read -r line; do
  case "$line" in ''|\#*) continue ;; esac
  name="${line%%:*}"
  AVAIL+=(-Xfrontend -define-availability -Xfrontend "$name:*")
  case "$name" in SwiftStdlib*) AVAIL+=(-Xfrontend -define-availability -Xfrontend "${name/SwiftStdlib/StdlibDeploymentTarget}:*") ;; esac
done < "$SRC/utils/availability-macros.def"

echo "Swift half: ${#SOURCES[@]} files"
"$BIN/swiftc" -target wasm32-unknown-none-wasm \
  -enable-experimental-feature Embedded -Xfrontend -emit-empty-object-file \
  -Xcc -ffreestanding -Xfrontend -disable-stack-protector \
  -parse-stdlib -parse-as-library -module-name _Concurrency -swift-version 5 -wmo -Osize \
  -DSWIFT_CONCURRENCY_EMBEDDED \
  -I "$C/InternalShims" \
  -enable-experimental-feature IsolatedAny -strict-memory-safety \
  -enable-experimental-feature AllowUnsafeAttribute -enable-experimental-feature Extern \
  -enable-experimental-feature SuppressedAssociatedTypesWithDefaults -enable-experimental-feature NonescapableTypes \
  -enable-experimental-feature Lifetimes -enable-experimental-feature AddressableParameters \
  -enable-upcoming-feature MemberImportVisibility \
  -runtime-compatibility-version none -disable-autolinking-runtime-compatibility-dynamic-replacements \
  -Xfrontend -disable-autolinking-runtime-compatibility-concurrency \
  -Xfrontend -disable-objc-interop -Xfrontend -disable-implicit-concurrency-module-import \
  -Xfrontend -disable-implicit-string-processing-module-import \
  "${AVAIL[@]}" \
  -emit-module -emit-module-path "$OUT/_Concurrency.swiftmodule/wasm32-unknown-none-wasm.swiftmodule" -avoid-emit-module-source-info \
  -c -o "$BUILD/_Concurrency.o" \
  "${SOURCES[@]}" > "$BUILD/swift.log" 2>&1 || { cat "$BUILD/swift.log"; exit 1; }

FLAGS=(--target=wasm32-unknown-emscripten -fPIC -Os -std=c++17
  -ffreestanding -fno-exceptions -fno-cxx-exceptions -fno-unwind-tables -fno-rtti
  -ffunction-sections -fdata-sections -fswift-async-fp=never -fvisibility=hidden
  -nostdinc -nostdinc++
  -isystem "$EM/lib/libcxx/include" -isystem "$EM/lib/libcxxabi/include"
  -isystem "$("$BIN/clang++" -print-resource-dir)/include"
  -isystem "$EM/include/compat" -isystem "$EM/include"
  -isystem "$EM/lib/libc/musl/arch/emscripten" -isystem "$EM/lib/libc/musl/arch/generic" -isystem "$EM/lib/libc/musl/include"
  -I "$BUILD/gen" -I "$SRC/include" -I "$SRC/stdlib/include" -I "$SRC/stdlib/public/SwiftShims" -I "$C"
  -DNDEBUG -DSWIFT_OBJC_INTEROP=0 -DSWIFT_LIBRARY_EVOLUTION=0 -DSWIFT_COMPACT_ABSOLUTE_FUNCTION_POINTER=1
  -DSWIFT_STDLIB_SINGLE_THREADED_CONCURRENCY -DSWIFT_THREADING_NONE -DSWIFT_LIBC_IS_MUSL
  -DSWIFT_STDLIB_HAS_DLSYM=0 -DSWIFT_STDLIB_HAS_DARWIN_LIBMALLOC=0
  -DSWIFT_CONCURRENCY_EMBEDDED=1 -DSWIFT_RUNTIME_EMBEDDED=1 -DSWIFT_CONCURRENCY_ENABLE_DISPATCH=0
  -D__STDC_WANT_LIB_EXT1__=1 -DSWIFT_TARGET_LIBRARY_NAME=swift_Concurrency -Dswift_Concurrency_EXPORTS)
count=0
while read -r f; do
  b=$(basename "$f")
  "$BIN/clang++" "${FLAGS[@]}" -c "$C/$f" -o "$BUILD/runtime/$b.o" > "$BUILD/runtime/$b.log" 2>&1 \
    || { cat "$BUILD/runtime/$b.log"; exit 1; }
  count=$((count + 1))
done < "$LISTS/c-sources.txt"
echo "C++ half: $count files"

"$BIN/llvm-ar" rcs "$OUT/libswift_Concurrency.a" "$BUILD/_Concurrency.o" "$BUILD"/runtime/*.o || exit 1
