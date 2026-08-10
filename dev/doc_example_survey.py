#!/usr/bin/env python3
"""Survey how ready the doc-comment corpus is for doc-example verification.

A throwaway prototype of docs/documentation.md phase 1: extract every fenced
block from `///` / `//!` comments, apply the wrapper the spec describes, and hand
the results to `thera check`. What comes back is the migration list — which
blocks already compile, which assume a name they never bind, which elide, and
which are simply wrong.

This is a *measurement* tool, not the implementation. Its extraction is
line-based where the real pass will be parser-based, so treat a surprising
failure as a question rather than a verdict; the categories below are accurate in
aggregate. Not part of the build.

    python3 dev/doc_example_survey.py [root]        # default: sdk/std
"""

import collections
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile

# A line that starts a top-level declaration. `let` and `const` are deliberately
# absent: at the top level of a doc example they are almost always a loose
# statement destined for the synthesized `main`, not a module-level binding.
DECL = re.compile(r"^(pub\s+)?(fn|struct|enum|interface|impl|import|native)\b|^@")


def fences(root):
    """Every fenced block in a `///` / `//!` comment under `root`."""
    out = []
    for dirpath, _, names in os.walk(root):
        for name in sorted(names):
            if not name.endswith(".thera"):
                continue
            path = os.path.join(dirpath, name)
            lines = open(path).read().split("\n")
            i = 0
            while i < len(lines):
                m = re.match(r"(\s*)//[/!]\s?(.*)$", lines[i])
                if m and m.group(2).strip().startswith("```"):
                    info, body, start = m.group(2).strip()[3:].strip(), [], i
                    i += 1
                    while i < len(lines):
                        m2 = re.match(r"\s*//[/!]\s?(.*)$", lines[i])
                        if not m2 or m2.group(1).strip().startswith("```"):
                            break
                        body.append(m2.group(1))
                        i += 1
                    out.append(
                        dict(file=path, line=start + 1, info=info, body="\n".join(body))
                    )
                i += 1
    return out


def dedent(body):
    lines = body.split("\n")
    widths = [len(l) - len(l.lstrip()) for l in lines if l.strip()]
    n = min(widths) if widths else 0
    return [l[n:] if len(l) >= n else l for l in lines]


def wrap(block):
    """The block as a compilable source file, per documentation.md § Tier 1."""
    lib = block["file"].split("/")[2]
    decls, loose, depth, bucket = [], [], 0, "l"
    for line in dedent(block["body"]):
        if depth == 0 and line.strip():
            bucket = "d" if DECL.match(line.strip()) else "l"
        (decls if bucket == "d" else loose).append(line)
        depth += sum(line.count(c) for c in "{([") - sum(line.count(c) for c in "})]")

    # REPL relaxation: a bare expression statement compiles as if discarded.
    fixed = []
    for line in loose:
        code = re.sub(r"\s*//.*$", "", line.rstrip()).rstrip()
        if code.strip() and not code.rstrip().endswith((";", "{", "}", ",")):
            fixed.append(" " * (len(line) - len(line.lstrip())) + f"let _ = {code.strip()};")
        else:
            fixed.append(line.rstrip())

    decl_text = "\n".join(decls).strip()
    src = ""
    if not re.search(rf"^import std\.{lib}\b", decl_text, re.M):
        src += f"import std.{lib};\n\n"  # the documented library, auto-imported
    src += decl_text + "\n\n"
    if re.search(r"^(pub )?fn main\b", decl_text, re.M):
        return src.rstrip() + "\n"
    body = "\n".join(("    " + l if l.strip() else "") for l in fixed).rstrip()
    return src + "fn main() -> Result<Int, Error> {\n" + body + "\n    return Result.Ok(0);\n}\n"


def categorize(msg):
    if re.search(r'unexpected (token: "\.\.?"|character: …)', msg):
        return "elides with `...` or `…`"
    if re.search(r"undefined name|bare reference|cannot infer the type of lambda", msg):
        return "references a name it never binds"
    if "unknown type" in msg or "unknown namespace" in msg:
        return "references a type/library it never imports"
    return "other — inspect: " + msg[:60]


def main(root="sdk/std"):
    blocks = [b for b in fences(root) if b["info"] in ("", "thera")]
    tagged = [b for b in blocks if b["info"] == "thera"]
    print(f"{len(blocks)} fences under {root} ({len(tagged)} tagged `thera`)")

    work = tempfile.mkdtemp(prefix="doc-example-survey-")
    try:
        index = {}
        for n, b in enumerate(tagged):
            name = f"b{n:03d}.thera"
            open(os.path.join(work, name), "w").write(wrap(b))
            index[name] = b
        proc = subprocess.run(
            ["bin/thera.sh", "check", work], capture_output=True, text=True
        )
        errs = collections.defaultdict(list)
        for line in (proc.stdout + proc.stderr).split("\n"):
            m = re.match(rf".*/({'|'.join(map(re.escape, index))}):\d+:\d+: (.*)$", line.strip())
            if m and "warning:" not in m.group(2):
                errs[m.group(1)].append(m.group(2))
    finally:
        shutil.rmtree(work, ignore_errors=True)

    print(f"\ncompile clean: {len(tagged) - len(errs)}/{len(tagged)}\n")
    buckets = collections.defaultdict(list)
    for name, msgs in errs.items():
        b = index[name]
        buckets[categorize(msgs[0])].append(f"{b['file']}:{b['line']}  {msgs[0][:70]}")
    for label, hits in sorted(buckets.items(), key=lambda kv: -len(kv[1])):
        print(f"{len(hits):3}  {label}")
        for h in hits[:4]:
            print(f"       {h}")


if __name__ == "__main__":
    main(*sys.argv[1:])
