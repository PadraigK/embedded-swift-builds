#!/usr/bin/env python3
"""Runs Swift's own Embedded concurrency tests against a Windows build (make windows-check).
  windows.py <build dir> <out dir> <Swift checkout> <tag> <work dir> [test name ...]
The build dir and out dir are a run of swift/<version>/windows.sh; the tests are the tag's test/embedded/. Each
test's `// RUN:` lines are replayed with the test suite's substitutions spelt for x86_64-unknown-windows-msvc: the
toolchain on PATH, the resource dir the build wrote, and filecheck.py beside this file. The way the tests replay
follows esg's tests/concurrency/as_written.py, which runs them on Linux.

Swift's tests link Swift's own cooperative executor (CooperativeGlobalExecutor.cpp, which Swift ships as
libswift_ConcurrencyDefaultExecutor.a) and a small platform layer (%target-embedded-posix-shim). Neither is part of
the build's output, which carries what a program with its own executor needs; this script compiles both for the
tests, the executor with the archive's own flags. Every link uses /OPT:REF and writes a map, and fails if it kept one
of the archive's fallbacks (windows-fallbacks.txt): that is a call Linux's linker would have reported.

Prints one line per test and writes <work dir>/<test>/log.txt. Exit 1 when any test fails."""
import os
import pathlib
import re
import shutil
import subprocess
import sys

HERE = pathlib.Path(__file__).resolve().parent
TRIPLE = "x86_64-unknown-windows-msvc"

# esg's as_written.py list, which is every test that runs a program with Swift's executor or one of its own. Left out:
# concurrency-leaks counts allocations by defining malloc and free, which a program can't do against the DLL C
# runtime that the archive calls (its objects import malloc from it); concurrency-dynamic-isolation-link, as on
# Linux (it needs MainActor, which Embedded Swift 6.4 has only on WASI).
TESTS = [
    "concurrency-actors", "concurrency-async-let", "concurrency-continuations", "concurrency-currenttask",
    "concurrency-deleted-method", "concurrency-discardingtaskgroup", "concurrency-modules", "concurrency-simple",
    "concurrency-stream-throwing", "concurrency-stream", "concurrency-taskgroup", "concurrency-tasklocal",
    "concurrency-throwing-task", "concurrency-typed-throws", "custom-executor",
    "dependencies-concurrency-custom-executor", "dependencies-concurrency-custom-executor2",
]

# What Swift's platform layer gives a test program, for Windows: aligned allocation the runtime frees with free(),
# as esg's CGodot shim does it; random bytes for hashing; and nanosleep, which the cooperative executor calls and
# the Windows C runtime lacks.
SHIM = r"""
#include <errno.h>
#include <stdlib.h>
#include <time.h>
#include <windows.h>
#include <bcrypt.h>
#pragma comment(lib, "bcrypt")
int posix_memalign(void **result, size_t alignment, size_t size) {
    if (alignment > 16) abort();
    void *memory = malloc(size ? size : 1);
    if (!memory) return ENOMEM;
    *result = memory;
    return 0;
}
void arc4random_buf(void *buffer, size_t length) {
    if (BCryptGenRandom(NULL, buffer, (ULONG)length, BCRYPT_USE_SYSTEM_PREFERRED_RNG) != 0) abort();
}
int nanosleep(const struct timespec *request, struct timespec *remaining) {
    Sleep((DWORD)(request->tv_sec * 1000 + request->tv_nsec / 1000000));
    if (remaining) { remaining->tv_sec = 0; remaining->tv_nsec = 0; }
    return 0;
}
"""


UNICODE = ["UnicodeData.cpp", "UnicodeEmoji.cpp", "UnicodeGrapheme.cpp", "UnicodeNormalization.cpp",
           "UnicodeScalarProps.cpp", "UnicodeWord.cpp"]


def tool(bin_dir, name):
    return str(bin_dir / f"{name}.exe")


def split_file(source, out):
    """Both forms the tests use: `//--- name` (split-file) and `// BEGIN name` ... `// END` (split_file.py)."""
    current = None
    for line in source.read_text(encoding="utf-8").splitlines(keepends=True):
        begin = re.match(r"//--- (\S+)", line) or re.match(r"// BEGIN (\S+)", line)
        if begin:
            current = open(out / begin.group(1), "w", encoding="utf-8")
        elif re.match(r"// END", line):
            current = None
        elif current:
            current.write(line)


def scaffolding(bin_dir, build, work):
    """The test-only executor and platform layer, and an include dir holding swift/ExecutorImpl.h as Swift installs
    it, for the tests' own executor (Inputs/executor.c)."""
    concurrency = build / "src/stdlib/public/Concurrency"
    include = work / "include"
    (include / "swift").mkdir(parents=True, exist_ok=True)
    shutil.copy2(concurrency / "ExecutorImpl.h", include / "swift/ExecutorImpl.h")
    (work / "shim.c").write_text(SHIM)
    (work / "nanosleep.h").write_text('#include <time.h>\nextern "C" int nanosleep(const struct timespec *, struct timespec *);\n')
    flags = [f for f in (build / "runtime-flags").read_bytes().decode().split("\0") if f]
    # The shim without -ffunction-sections. Embedded Swift declares posix_memalign @_extern(c), which a Windows
    # compile reaches through __imp_posix_memalign as if from a DLL; lld-link points that at the local definition
    # (warning LNK4217) but doesn't count it as a reference, so /OPT:REF drops a definition in a section of its own
    # and the program calls into nothing. Plain .text is never dropped.
    steps = [
        [tool(bin_dir, "clang"), f"--target={TRIPLE}", "-Os", "-fms-runtime-lib=dll",
         "-c", str(work / "shim.c"), "-o", str(work / "shim.obj")],
        [tool(bin_dir, "clang++"), *flags, "-include", str(work / "nanosleep.h"),
         "-c", str(concurrency / "CooperativeGlobalExecutor.cpp"), "-o", str(work / "executor.obj")],
    ]
    # The Unicode tables a test that compares strings links. Swift's CMake builds them for every Embedded target but
    # windows-msvc (stubs/Unicode/CMakeLists.txt), and a program for Windows brings its own, as esg's bindings do.
    unicode = build / "src/stdlib/public/stubs/Unicode"
    objects = []
    for source in UNICODE:
        objects.append(work / f"{source}.obj")
        steps.append([tool(bin_dir, "clang++"), *flags, "-DSWIFT_STDLIB_ENABLE_UNICODE_DATA",
                      "-c", str(unicode / source), "-o", str(objects[-1])])
    steps.append([tool(bin_dir, "llvm-ar"), "rcs", str(work / "libswiftUnicodeDataTables.a"), *map(str, objects)])
    for step in steps:
        result = subprocess.run(step, capture_output=True, text=True)
        if result.returncode != 0:
            sys.exit(f"windows.py: couldn't build the test scaffolding:\n{' '.join(step)}\n{result.stdout}{result.stderr}")
    return include


def commands(test, work, bin_dir, out, include, scaffold):
    sh = lambda p: pathlib.Path(p).as_posix()
    resource = out / "resource"
    archive = sh(resource / "embedded" / TRIPLE / "libswift_Concurrency.a")
    t = sh(work / "t")
    # A program compiles with SWIFT_STATIC_STDLIB for SwiftShims, as the archive does (README, Using the Windows
    # build): the C functions the runtime's static libraries define (the Unicode tables') are otherwise declared
    # dllimport, and lld-link won't take an archive's definition for an import.
    frontend = (f"'{tool(bin_dir, 'swiftc')}' -frontend -target {TRIPLE} -resource-dir '{sh(resource)}' "
                f"-sdk '{sh(os.environ['SDKROOT'])}' -module-cache-path '{sh(work / 'cache')}' -Xcc -DSWIFT_STATIC_STDLIB")
    subs = [
        ("%empty-directory(%t)", f"rm -rf '{t}' && mkdir -p '{t}'"),
        ("%{python} %utils/split_file.py -o %t %s", f"'{sys.executable}' -I '{sh(__file__)}' --split '{sh(test)}' '{t}'"),
        ("split-file %s %t", f"'{sys.executable}' -I '{sh(__file__)}' --split '{sh(test)}' '{t}'"),
        # The custom-executor tests are written for the Mac and name its triple and its folder.
        ("-target %target-cpu-apple-macos14", ""),
        ("%swift_obj_root/lib/swift/embedded/%target-cpu-apple-macos/libswift_Concurrency.a", archive),
        ("%swift_obj_root/lib/swift/embedded/%module-target-triple/libswift_Concurrency.a", archive),
        ("-L%swift_obj_root/lib/swift/embedded/%module-target-triple", ""),
        ("-lswift_Concurrency", archive),
        ("%swift_obj_root/lib/swift/embedded/%module-target-triple/libswiftUnicodeDataTables.a",
         f"'{sh(scaffold / 'libswiftUnicodeDataTables.a')}'"),
        ("%swift_obj_root/include", sh(include)),
        ("%target-swift-frontend", frontend),
        ("%target-clang-resource-dir-opt", ""),
        ("%target-embedded-posix-shim", f"'{sh(scaffold / 'shim.obj')}'"),
        ("%target-swift-default-executor-opt", f"'{sh(scaffold / 'executor.obj')}'"),
        ("%target-clang", f"'{tool(bin_dir, 'clang')}' --target={TRIPLE} -fms-runtime-lib=dll"),
        # The Windows toolchain keeps its host plugins (SwiftMacros.dll and the rest) in usr/bin.
        ("%swift-plugin-dir", sh(bin_dir)),
        ("%target-run", ""),
        # Windows programs end their lines with \r\n.
        ("%FileCheck", f"tr -d '\\r' | '{sys.executable}' -I '{sh(HERE / 'filecheck.py')}'"),
        ("%llvm-nm", f"'{tool(bin_dir, 'llvm-nm')}'"),
        ("%S", sh(test.parent)),
        ("%s", sh(test)),
        ("%t/a.out", f"{t}/a.exe"),
        ("%t", t),
    ]
    out_lines = []
    for line in test.read_text(encoding="utf-8").splitlines():
        match = re.match(r"//\s*RUN:\s*(.*)$", line)
        if not match:
            continue
        line = match.group(1)
        # The dependency checks compare a Mac or Linux program's undefined symbols with a list for that platform;
        # an .exe has none to list. The fallback check below is this platform's check of what the link needed.
        if "allowed-dependencies" in line or "actual-dependencies" in line or "extra.txt" in line:
            continue
        # A placeholder is replaced only where it ends: %s isn't the start of %swift_obj_root.
        for key, value in subs:
            line = re.sub(re.escape(key) + r"(?![A-Za-z0-9_-])", lambda _: value, line)
        if re.search(r"%[A-Za-z{]", line):
            sys.exit(f"windows.py: {test.name} has a placeholder this script doesn't know: {line}")
        # A module another one imports is built -static, as Swift's CMake builds its static libraries: on Windows its
        # importer otherwise takes it for a DLL, and reaches its conformances through swift_getWitnessTable.
        if line.startswith(f"'{tool(bin_dir, 'swiftc')}' -frontend") and " -emit-module " in line:
            line += " -static"
        # A C file is compiled into one section per function and datum: Apple's linker strips dead code per function
        # whatever the compile, and lld-link only per section.
        if "clang.exe'" in line and " -c " in line:
            line += " -ffunction-sections -fdata-sections"
        # The link lines are written for Apple's linker and C++ library; this is the same link said to lld-link,
        # with the platform layer in every one: Windows' C runtime has no posix_memalign, which Embedded Swift calls.
        if "clang.exe'" in line and f" -o {t}/a.exe" in line:
            line = line.replace("-dead_strip", "").replace("-lc++abi", "").replace("-lc++", "")
            if "shim.obj" not in line:
                line += f" '{sh(scaffold / 'shim.obj')}'"
            line += f" -fuse-ld=lld -Wl,/OPT:REF -Wl,/MAP:{t}/a.map"
            out_lines.append(line)
            out_lines.append(f"if grep -o 'swift_embedded_fallback_[0-9]*' '{t}/a.map'; then "
                             f"echo 'the link kept a fallback: live code calls a name the program lacks'; exit 1; fi")
            continue
        out_lines.append(line)
    return out_lines


def run(test, work, bin_dir, out, include, scaffold):
    work.mkdir(parents=True, exist_ok=True)
    with open(work / "log.txt", "w", encoding="utf-8") as log:
        for command in commands(test, work, bin_dir, out, include, scaffold):
            log.write(f"$ {command}\n")
            log.flush()
            result = subprocess.run(["bash", "-o", "pipefail", "-c", command], stdout=subprocess.PIPE,
                                    stderr=subprocess.STDOUT, text=True, timeout=300)
            log.write(result.stdout)
            if result.returncode != 0:
                log.write(f"[exit {result.returncode}]\n")
                return False, command, result.stdout
    return True, "", ""


def main():
    if sys.argv[1] == "--split":
        split_file(pathlib.Path(sys.argv[2]), pathlib.Path(sys.argv[3]))
        return
    build, out, swift, work_root = (pathlib.Path(a).resolve() for a in (*sys.argv[1:4], sys.argv[5]))
    tag = sys.argv[4]
    names = sys.argv[6:] or TESTS
    swiftc = shutil.which("swiftc")
    if not swiftc:
        sys.exit("windows.py: no swiftc on PATH")
    bin_dir = pathlib.Path(swiftc).resolve().parent
    if work_root.exists():
        shutil.rmtree(work_root)
    tests = work_root / "swift-tests"
    tests.mkdir(parents=True)
    archive = subprocess.run(["git", "-C", str(swift), "-c", "core.autocrlf=false", "archive", str(tag), "test/embedded"],
                             capture_output=True, check=True).stdout
    subprocess.run(["tar", "-x", "-C", tests.as_posix()], input=archive, check=True)
    # Our changes to Swift's test files for this release, each a patch saying why: tests/swift-<version>/.
    version = re.fullmatch(r"swift-(.+)-RELEASE", tag).group(1)
    for patch in sorted((HERE / f"swift-{version}").glob("*.patch")):
        subprocess.run(["patch", "-s", "-p1", "-d", tests.as_posix(), "-i", patch.as_posix()], check=True)
    scaffold = work_root / "scaffolding"
    scaffold.mkdir()
    include = scaffolding(bin_dir, build, scaffold)
    failed = 0
    for name in names:
        ok, command, output = run(tests / "test/embedded" / f"{name}.swift", work_root / name, bin_dir, out, include, scaffold)
        if ok:
            print(f"PASS  {name}", flush=True)
        else:
            failed += 1
            step = "compile" if "-frontend" in command else "link" if "/OPT:REF" in command else "run or check"
            last = [l for l in output.strip().splitlines() if l.strip()][-1:] or [""]
            print(f"FAIL  {name}  ({step}) {last[0][:200]}", flush=True)
    print(f"{len(names) - failed} passed, {failed} failed (Swift's tests at {tag})")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
