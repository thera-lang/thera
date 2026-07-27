#!/usr/bin/env python3
"""Report the distribution of source line lengths across the corpus.

A measurement aid for the formatter/line-length discussion (see
docs/roadmap.md -> Developer tooling -> "Canonical (line-wrapping)
formatter"). Two uses: sanity-checking the authoring guideline in
docs/language.md against what the corpus actually does, and — if a
reflowing formatter is ever prototyped — comparing the distribution
before and after a reflow pass.

Usage:
    dev/line_lengths.py pkgs sdk examples bench
    dev/line_lengths.py --ext .rs runtime/src

Notes: lengths are counted in characters (not bytes) with tabs expanded,
and comment lines are reported separately from code — the two populations
behave differently and averaging them hides that.
"""

import argparse
import collections
import os
import sys

SKIP_DIRS = {".git", "build", "target", ".dart_tool", "node_modules"}


def iter_files(roots, exts):
    for root in roots:
        if os.path.isfile(root):
            yield root
            continue
        for dirpath, dirnames, filenames in os.walk(root):
            dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS]
            for name in sorted(filenames):
                if any(name.endswith(e) for e in exts):
                    yield os.path.join(dirpath, name)


def percentiles(hist, targets):
    """Yield (target, length) for each percentile target, in order."""
    total = sum(hist.values())
    cum = 0
    ti = 0
    for n in sorted(hist):
        cum += hist[n]
        while ti < len(targets) and cum >= total * targets[ti] / 100:
            yield targets[ti], n
            ti += 1


def main():
    ap = argparse.ArgumentParser(
        description="Report the distribution of source line lengths.")
    ap.add_argument("roots", nargs="*", default=["."],
                    help="files or directories to scan (default: .)")
    ap.add_argument("--ext", action="append", default=None,
                    help="file extension to include, repeatable "
                         "(default: .thera)")
    ap.add_argument("--tab-width", type=int, default=4,
                    help="columns per tab when expanding (default: 4)")
    ap.add_argument("--comment-prefix", default="//",
                    help="line-comment marker (default: //)")
    ap.add_argument("--top", type=int, default=15,
                    help="how many of the longest lines to list")
    args = ap.parse_args()

    exts = args.ext or [".thera"]
    roots = args.roots or ["."]

    code = collections.Counter()
    comment = collections.Counter()
    longest = []  # (length, path, lineno, text)
    total_files = 0

    for path in iter_files(roots, exts):
        total_files += 1
        with open(path, encoding="utf-8", errors="replace") as f:
            for lineno, line in enumerate(f, 1):
                line = line.rstrip("\n").rstrip("\r").expandtabs(args.tab_width)
                if not line.strip():
                    continue
                n = len(line)
                if line.lstrip().startswith(args.comment_prefix):
                    comment[n] += 1
                else:
                    code[n] += 1
                longest.append((n, path, lineno, line))

    if not longest:
        print("no lines found", file=sys.stderr)
        return 1

    combined = code + comment
    total = sum(combined.values())
    print(f"files: {total_files}   non-blank lines: {total} "
          f"(code {sum(code.values())}, comment {sum(comment.values())})")
    print()

    targets = [50, 75, 90, 95, 99, 99.9, 100]
    for label, hist in (("code", code), ("comment", comment),
                        ("all", combined)):
        if not hist:
            continue
        pcts = " ".join(f"p{t}={n}" for t, n in percentiles(hist, targets))
        print(f"  {label:<8} max={max(hist):<6} {pcts}")
    print()

    print("lines over candidate limits (code / comment):")
    for limit in (80, 88, 90, 100, 110, 120):
        c = sum(v for k, v in code.items() if k > limit)
        m = sum(v for k, v in comment.items() if k > limit)
        print(f"  >{limit:<4} {c:>5} code ({c / max(1, sum(code.values())) * 100:5.2f}%)"
              f"   {m:>5} comment")
    print()

    print("histogram, 10-char buckets (code only):")
    buckets = collections.Counter()
    for n, c in code.items():
        buckets[n // 10 * 10] += c
    peak = max(buckets.values())
    for lo in range(0, max(code) + 10, 10):
        c = buckets[lo]
        if c == 0 and lo > 120:
            continue  # collapse the sparse tail
        print(f"  {lo:>4}-{lo + 9:<4} {c:>6} {'#' * int(c / peak * 50)}")
    print()

    longest.sort(key=lambda t: -t[0])
    print(f"{args.top} longest lines:")
    for n, path, lineno, text in longest[:args.top]:
        print(f"  {n:>5}  {os.path.relpath(path)}:{lineno}")
        print(f"         {text.strip()[:100]}")

    return 0


if __name__ == "__main__":
    sys.exit(main())
