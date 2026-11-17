#!/usr/bin/env python3
"""Every LARECOMP_* name the docs mention is still read by the code, and docs/environment.md keeps its promise.

A documented variable that the code no longer reads sends a player to a switch that does nothing. No game files."""
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
NAME = re.compile(r"LARECOMP_[A-Z0-9_]+")
# Named in the docs without being an environment variable: the version macro in runtime/ui/launcher.mm.
NOT_ENV = {"LARECOMP_VERSION"}


def quoted_in_code():
    """Names that appear as a string in the runtime, or in a C/Objective-C test harness (a getenv / ENV / setenv)."""
    found = set()
    for top in ("runtime", "tools"):
        for dirpath, _, files in os.walk(os.path.join(ROOT, top)):
            if "/venv" in dirpath or "/__pycache__" in dirpath:
                continue
            for f in files:
                if f.endswith((".c", ".h", ".m", ".mm", ".inc", ".cpp")):
                    with open(os.path.join(dirpath, f), errors="replace") as fh:
                        found.update(re.findall(r'"(LARECOMP_[A-Z0-9_]+)"', fh.read()))
    return found


def doc_files():
    for f in ("README.md", "CONTRIBUTING.md"):
        yield f
    for f in sorted(os.listdir(os.path.join(ROOT, "docs"))):
        if f.endswith(".md"):
            yield os.path.join("docs", f)


def main():
    code = quoted_in_code()
    bad = []
    for rel in doc_files():
        path = os.path.join(ROOT, rel)
        if not os.path.exists(path):
            continue
        with open(path) as fh:
            for n in sorted(set(NAME.findall(fh.read())) - NOT_ENV):
                if n not in code:
                    bad.append(f"{rel}: {n} is not read by the code any more")
    # The public page: a table row per variable, and at least the ones people are told to use.
    with open(os.path.join(ROOT, "docs", "environment.md")) as fh:
        listed = set(re.findall(r"^\| `(LARECOMP_[A-Z0-9_]+)", fh.read(), re.M))
    if len(listed) < 5:
        bad.append(f"docs/environment.md lists {len(listed)} variables: the table was damaged")
    if bad:
        print("\n".join(bad))
        return 1
    print(f"ok: {len(listed)} supported variables, every name in the docs is read by the code")
    return 0


if __name__ == "__main__":
    sys.exit(main())
