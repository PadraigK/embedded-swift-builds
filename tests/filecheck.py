#!/usr/bin/env python3
# Copied from Embedded-Swift-GDExtension (esg) tests/concurrency/filecheck.py at 6b13afe; keep the two in step.
"""A small FileCheck: the subset of LLVM's that Swift's Embedded concurrency tests use.
  filecheck.py <test file> [--check-prefix=NAME]      (the text to check comes on stdin)
Directives, with the prefix NAME (CHECK when none is given): NAME:, NAME-NEXT:, NAME-SAME:, NAME-NOT:,
NAME-DAG:, NAME-LABEL: (read as NAME:). Patterns may hold {{regex}}, [[NAME:regex]] and [[NAME]]. Runs of
spaces and tabs count as one space, as in FileCheck. Exit 0 when every directive holds, 1 with a message."""
import re
import sys


def directives(path, prefix):
    found = []
    pattern = re.compile(r"(?<![A-Za-z0-9_-])" + re.escape(prefix) + r"(-NEXT|-SAME|-NOT|-DAG|-LABEL)?:(.*)$")
    for number, line in enumerate(open(path, encoding="utf-8"), 1):
        match = pattern.search(line)
        if match:
            kind = (match.group(1) or "").lstrip("-") or "PLAIN"
            found.append((kind if kind != "LABEL" else "PLAIN", match.group(2).strip(), number))
    return found


def squash(text):
    return re.sub(r"[ \t]+", " ", text)


def to_regex(pattern, variables):
    out, position = "", 0
    for match in re.finditer(r"\{\{(.*?)\}\}|\[\[([A-Za-z_][A-Za-z0-9_]*)(?::(.*?))?\]\]", pattern):
        out += re.escape(squash(pattern[position:match.start()]))
        if match.group(1) is not None:
            out += "(?:" + match.group(1) + ")"
        elif match.group(3) is not None:
            out += "(?P<" + match.group(2) + ">" + match.group(3) + ")"
        else:
            out += re.escape(variables.get(match.group(2), "\0undefined\0"))
        position = match.end()
    return re.compile(out + re.escape(squash(pattern[position:])))


def main():
    args = sys.argv[1:]
    prefix = "CHECK"
    files = []
    for arg in args:
        if arg.startswith("--check-prefix="):
            prefix = arg.split("=", 1)[1]
        elif arg == "--check-prefix":
            pass
        elif not arg.startswith("-"):
            files.append(arg)
    if "--check-prefix" in args:
        prefix = args[args.index("--check-prefix") + 1]
        files = [f for f in files if f != prefix]
    test = files[0]
    text = squash(sys.stdin.read())
    checks = directives(test, prefix)
    if not checks:
        sys.exit(f"filecheck: no {prefix}: directives in {test}")
    variables, position, last_line_end, pending_not = {}, 0, 0, []

    def fail(message, number):
        print(f"filecheck: {test}:{number}: {message}", file=sys.stderr)
        print("--- text checked ---", file=sys.stderr)
        print(text[-3000:], file=sys.stderr)
        sys.exit(1)

    index = 0
    while index < len(checks):
        kind, pattern, number = checks[index]
        if kind == "NOT":
            pending_not.append((pattern, number))
            index += 1
            continue
        if kind == "DAG":
            group = []
            while index < len(checks) and checks[index][0] == "DAG":
                group.append(checks[index])
                index += 1
            end = position
            for _, dag_pattern, dag_number in group:
                match = to_regex(dag_pattern, variables).search(text, position)
                if not match:
                    fail(f"{prefix}-DAG not found: {dag_pattern}", dag_number)
                variables.update({k: v for k, v in match.groupdict().items() if v is not None})
                end = max(end, match.end())
            start = position
        else:
            regex = to_regex(pattern, variables)
            if kind == "NEXT":
                line_start = text.find("\n", last_line_end - 1 if last_line_end else 0)
                line_start = text.find("\n", position) + 1 if position else 0
                line_end = text.find("\n", line_start)
                line_end = len(text) if line_end < 0 else line_end
                match = regex.search(text, line_start, line_end)
                if not match:
                    fail(f"{prefix}-NEXT not on the next line: {pattern}", number)
            elif kind == "SAME":
                line_end = text.find("\n", position)
                line_end = len(text) if line_end < 0 else line_end
                match = regex.search(text, position, line_end)
                if not match:
                    fail(f"{prefix}-SAME not on the same line: {pattern}", number)
            else:
                match = regex.search(text, position)
                if not match:
                    fail(f"{prefix} not found: {pattern}", number)
            variables.update({k: v for k, v in match.groupdict().items() if v is not None})
            start, end = match.start(), match.end()
            index += 1
        for not_pattern, not_number in pending_not:
            if to_regex(not_pattern, variables).search(text, position, start):
                fail(f"{prefix}-NOT found: {not_pattern}", not_number)
        pending_not = []
        position = end
        last_line_end = end
    for not_pattern, not_number in pending_not:
        if to_regex(not_pattern, variables).search(text, position):
            fail(f"{prefix}-NOT found: {not_pattern}", not_number)


main()
