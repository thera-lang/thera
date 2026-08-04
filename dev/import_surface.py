#!/usr/bin/env python3
"""Report each library's public import surface, and what can't be reached.

Written after `import std.http.server` turned out to be a check error that
nothing noticed — the file was a plain sibling inside the `std/http` directory
library, so from outside it only the barrel was importable, and its only callers
were its own tests. This finds that shape mechanically.

Three checks, per docs/language.md -> Imports:

  structure   notes, not defects — which directories are barrel-fronted
              libraries, which are barrel-less folders of single-file libraries,
              and which libraries nest. The shape decides what is importable
              from where, so it is worth seeing.
  siblings    a non-barrel file with `pub` declarations that its barrel does not
              re-export and no non-test sibling imports is UNREACHABLE — its
              public surface can only be seen from its own `_test.thera`
  spellings   every `import std.…` written anywhere in the tree resolves, and
              resolves to something the writing file is allowed to import

Usage:
    dev/import_surface.py                 # sdk/std and pkgs/cli
    dev/import_surface.py sdk/std

Note the third check reads *all* tracked text files, comments and docs
included — deliberately, since that is where the `std.http.server` claim lived
while no code exercised it. Prose that merely mentions an import spelling (`there
is no `import std.list``) shows up as a finding; read the hits, don't just count
them.
"""

import os
import re
import subprocess
import sys

EXT = ".thera"
STD_ROOT = "sdk/std"


def is_library(d):
    """A directory fronted by its own barrel is a library in its own right."""
    return os.path.isdir(d) and os.path.isfile(
        os.path.join(d, os.path.basename(d) + EXT)
    )


def barrel_of(d):
    return os.path.join(d, os.path.basename(d) + EXT)


def reexports(d):
    """The sibling names a barrel re-exports with `pub import`."""
    return set(re.findall(r"^pub import '([^']+)'", open(barrel_of(d)).read(), re.M))


def check_structure(root):
    """Notes on the layout. None of these is a defect: docs/language.md allows a
    program root of loose files and a barrel-less folder of single-file libraries.
    They are reported because the shape decides what is importable from where."""
    notes = []
    loose = [f for f in sorted(os.listdir(root)) if f.endswith(EXT)]
    if loose:
        notes.append(f"{root}/ is a root of {len(loose)} loose single-file libraries")
    for dirpath, dirnames, _ in os.walk(root):
        for d in sorted(dirnames):
            full = os.path.join(dirpath, d)
            if not is_library(full):
                n = len([f for f in os.listdir(full) if f.endswith(EXT)])
                notes.append(
                    f"{full}/ has no barrel — a folder of {n} independent "
                    f"single-file libraries, each importable"
                )
            elif dirpath != root:
                notes.append(f"{full}/ is a nested library, importable on its own")
    return notes


def check_siblings(root):
    """Files whose public surface nothing outside their own tests can see."""
    findings = []
    for dirpath, _, filenames in os.walk(root):
        if not is_library(dirpath):
            continue
        barrel = os.path.basename(dirpath) + EXT
        exported = reexports(dirpath)
        for f in sorted(filenames):
            if not f.endswith(EXT) or f == barrel or f.endswith("_test" + EXT):
                continue
            stem = f[: -len(EXT)]
            if stem in exported:
                continue
            src = open(os.path.join(dirpath, f)).read()
            if not re.search(r"^\s*pub (fn|struct|enum|const|interface|import)", src, re.M):
                continue  # nothing public to strand
            users = [
                o
                for o in filenames
                if o.endswith(EXT)
                and o != f
                and re.search(
                    rf"^import '{re.escape(stem)}'",
                    open(os.path.join(dirpath, o)).read(),
                    re.M,
                )
            ]
            if not [u for u in users if not u.endswith("_test" + EXT)]:
                findings.append(
                    f"UNREACHABLE {os.path.join(dirpath, f)}: has public "
                    f"declarations, its barrel does not re-export it, and no "
                    f"non-test sibling imports it (tests: {users or 'none'})"
                )
    return findings


def resolve(dotted):
    """Resolve `std.a.b`. Returns (target, complaint-or-None)."""
    p = os.path.join(STD_ROOT, *dotted.split(".")[1:])
    if os.path.isdir(p):
        if not os.path.isfile(barrel_of(p)):
            return None, f"{p}/ has no barrel"
        target = barrel_of(p)
    elif os.path.isfile(p + EXT):
        target = p + EXT
    else:
        return None, "no such file or directory"
    # A non-barrel file inside a directory library is private to that library.
    holder = os.path.dirname(target)
    if is_library(holder) and os.path.abspath(target) != os.path.abspath(
        barrel_of(holder)
    ):
        return target, f"resolves inside the library {holder}/ — import its barrel"
    return target, None


def check_spellings():
    findings = []
    tracked = subprocess.run(
        ["git", "ls-files"], capture_output=True, text=True
    ).stdout.split()
    for f in tracked:
        if not f.endswith((EXT, ".md", ".rs", ".sh")):
            continue
        try:
            src = open(f).read()
        except (UnicodeDecodeError, IsADirectoryError):
            continue
        for m in re.finditer(r"import (std\.[a-z_][a-z_0-9.]*)", src):
            dotted = m.group(1)
            target, complaint = resolve(dotted)
            if not complaint:
                continue
            # A file inside the library may legitimately import its siblings.
            if target and os.path.dirname(f) == os.path.dirname(target):
                continue
            findings.append(f"{f}: `import {dotted}` — {complaint}")
    return findings


def main():
    roots = sys.argv[1:] or [STD_ROOT, "pkgs/cli"]
    problems = 0
    for root in roots:
        print(f"== {root} ==")
        for line in check_structure(root):
            print(f"  note: {line}")
        stranded = check_siblings(root)
        for line in stranded:
            print(f"  {line}")
        problems += len(stranded)
        print()
    print("== import spellings ==")
    hits = check_spellings()
    for line in sorted(set(hits)):
        print(f"  {line}")
    print(f"\n{len(set(hits))} spelling hit(s) to read, "
          f"{problems} unreachable public surface(s)")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
