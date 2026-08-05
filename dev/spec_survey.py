#!/usr/bin/env python3
"""Survey OpenAPI descriptions, so "which API next" is a table and not an opinion.

docs/api-access.md § Choosing targets asks for this: per API, the operation count,
`operationId` coverage, and a histogram of the OpenAPI constructs used — turning
spec quality from a judgment call into a column. The larger payoff is the aggregate
histogram, which tells the Arc 3 generator which constructs to implement first, in
frequency order.

Three reports:

  targets    one row per API in the hand-list (§ Why OpenAPI's table), measuring
             the six ranking criteria that are mechanically measurable
  constructs the construct histogram, per API and summed — the generator's work
             queue, ordered by how often it would actually hit each thing
  closure    the transitive schema closure of a *named operation set*, which is
             what makes Arc 3's filtering claim ("whole-spec generation would
             produce hundreds of thousands of lines nobody reads") a number

Usage:
    dev/spec_survey.py                        # the hand-list
    dev/spec_survey.py --guru 150             # + a sample of APIs.guru
    dev/spec_survey.py --only anthropic,openai
    dev/spec_survey.py --closure anthropic    # filtered-surface report for one API
    dev/spec_survey.py --markdown             # tables ready for api-access.md

Specs are cached under build/spec-cache/ (gitignored, and they are megabytes —
Cloudflare alone is 23 MB), so reruns are offline and fast. `--refresh` refetches.

**On counting.** The construct walk descends the whole document rather than only
schema positions, but skips subtrees that hold arbitrary user data (`example`,
`examples`, `default`, the *contents* of `enum`, and `x-` extensions) because those
can contain any keys at all, including ones that look like schema keywords. That is
precise enough for a frequency ranking and much simpler than a full schema-position
walk; it is not a validator.
"""

import argparse
import collections
import hashlib
import json
import os
import re
import sys
import time
import urllib.request

CACHE = "build/spec-cache"
UA = {"User-Agent": "thera-spec-survey/1 (+https://github.com/thera-lang/thera)"}

# The hand-list from docs/api-access.md § Why OpenAPI. `stats` marks the Anthropic
# indirection: the spec URL lives in the official SDK's `.stats.yml`, content-hash
# pinned per release, so it has to be resolved rather than hardcoded.
TARGETS = {
    "anthropic": {"stats": "https://raw.githubusercontent.com/anthropics/anthropic-sdk-python/main/.stats.yml"},
    "openai": {"url": "https://raw.githubusercontent.com/openai/openai-openapi/master/openapi.yaml"},
    "gemini": {"url": "https://generativelanguage.googleapis.com/$discovery/OPENAPI3_0"},
    "github": {"url": "https://raw.githubusercontent.com/github/rest-api-description/main/descriptions/api.github.com/api.github.com.json"},
    "cloudflare": {"url": "https://raw.githubusercontent.com/cloudflare/api-schemas/main/openapi.json"},
    "vercel": {"url": "https://openapi.vercel.sh/"},
    "fly": {"url": "https://docs.machines.dev/spec/openapi3.json"},
}

# A realistic tool's surface, for the closure report. Not the whole API — the point
# is to measure how much of a spec a useful client actually needs.
REALISTIC = {
    "anthropic": ["messages_post", "messages_count_tokens_post", "models_list"],
    "fly": ["Machines_list", "Machines_create", "Machines_show"],
    "openai": ["createChatCompletion", "listModels"],
    "github": ["pulls/create", "pulls/list", "issues/create"],
}

METHODS = ("get", "put", "post", "delete", "options", "head", "patch", "trace")

# Keys whose subtrees are arbitrary user data, not schema structure.
OPAQUE = ("example", "examples", "default", "enum")

CONSTRUCTS = ("allOf", "anyOf", "oneOf", "not", "discriminator", "enum", "nullable",
              "patternProperties", "additionalProperties", "$ref", "format")


# --- fetching ---------------------------------------------------------------

def fetch(url, refresh=False):
    """The bytes at `url`, cached by URL digest under build/spec-cache/."""
    os.makedirs(CACHE, exist_ok=True)
    path = os.path.join(CACHE, hashlib.sha256(url.encode()).hexdigest()[:16])
    if os.path.exists(path) and not refresh:
        with open(path, "rb") as f:
            return f.read()
    req = urllib.request.Request(url, headers=UA)
    with urllib.request.urlopen(req, timeout=120) as r:
        body = r.read()
    with open(path, "wb") as f:
        f.write(body)
    return body


def resolve(target, refresh=False):
    """The spec URL for a target, following the `.stats.yml` indirection if any."""
    if "url" in target:
        return target["url"]
    stats = fetch(target["stats"], refresh).decode("utf-8", "replace")
    m = re.search(r"^openapi_spec_url:\s*(\S+)", stats, re.M)
    if not m:
        raise ValueError("no openapi_spec_url in .stats.yml")
    return m.group(1)


def load(body):
    """Parse JSON or YAML, sniffing which. YAML needs a real parser — several of
    these specs are only published as `.yml`, which is why this script is Python
    and not Thera (std.json exists; std.yaml does not)."""
    text = body.decode("utf-8", "replace").lstrip()
    if text.startswith("{"):
        return json.loads(text)
    import yaml
    loader = getattr(yaml, "CSafeLoader", yaml.SafeLoader)
    return yaml.load(text, Loader=loader)


# --- measuring --------------------------------------------------------------

def walk(node, depth=0, hit=None):
    """Visit schema-ish nodes, skipping arbitrary-data subtrees. Yields
    (dict_node, depth) for every mapping reached."""
    if isinstance(node, dict):
        yield node, depth
        for key, value in node.items():
            if key in OPAQUE or key.startswith("x-"):
                continue
            yield from walk(value, depth + 1)
    elif isinstance(node, list):
        for item in node:
            yield from walk(item, depth + 1)


def operations(doc):
    """(operation dict, path, method) for every operation in the document."""
    for path, item in (doc.get("paths") or {}).items():
        if not isinstance(item, dict):
            continue
        for method, op in item.items():
            if method.lower() in METHODS and isinstance(op, dict):
                yield op, path, method


def is_null_schema(branch):
    """A branch that means "or null" — 3.1's `type: null`, or a bare nullable."""
    if not isinstance(branch, dict):
        return False
    t = branch.get("type")
    if t == "null" or (isinstance(t, list) and set(t) == {"null"}):
        return True
    return branch.get("nullable") is True and len(branch) == 1


def classify_anyof(node):
    """Which kind of `anyOf` this is — the distinction api-access.md's "527
    occurrences, the row that will hurt" does not make, and needs to.

    `nullable`  [T, null] — this is 3.1's idiomatic Option<T>, not a union at all
    `tagged`    carries a discriminator, so it maps to an enum like `oneOf` does
    `untagged`  the genuinely hard case: pick a branch by trial, or fall back to Json
    """
    branches = node.get("anyOf") or []
    if "discriminator" in node:
        return "tagged"
    nulls = [b for b in branches if is_null_schema(b)]
    if len(branches) - len(nulls) == 1 and nulls:
        return "nullable"
    return "untagged"


def survey(doc, size):
    """Every measurable ranking criterion for one document."""
    ops = list(operations(doc))
    with_id = [o for o, _, _ in ops if (o.get("operationId") or "").strip()]
    schemas = ((doc.get("components") or {}).get("schemas")) or {}

    counts = collections.Counter()
    anyof = collections.Counter()
    formats = collections.Counter()
    addl_open = 0          # `additionalProperties: true` — the escape-hatch tell
    addl_typed = 0         # `additionalProperties: {schema}` — a Map<String, T>
    max_depth = 0
    union_of_refs = 0      # untagged anyOf whose branches are all $refs

    for node, depth in walk(doc):
        max_depth = max(max_depth, depth)
        for key in CONSTRUCTS:
            if key in node:
                counts[key] += 1
        if "anyOf" in node:
            kind = classify_anyof(node)
            anyof[kind] += 1
            if kind == "untagged":
                branches = node.get("anyOf") or []
                if branches and all(isinstance(b, dict) and "$ref" in b for b in branches):
                    union_of_refs += 1
        if "additionalProperties" in node:
            ap = node["additionalProperties"]
            if ap is True:
                addl_open += 1
            elif isinstance(ap, dict) and ap:
                addl_typed += 1
        if isinstance(node.get("format"), str):
            formats[node["format"]] += 1

    # Feature demand: which media types and auth schemes a client would have to
    # support. Each is Arc 1 work, so the cost belongs in the ranking.
    media = collections.Counter()
    for node, _ in walk(doc):
        if isinstance(node.get("content"), dict):
            for mt in node["content"]:
                media[mt.split(";")[0].strip()] += 1
    auth = sorted({
        (v or {}).get("type", "?") + (
            "/" + v["scheme"] if isinstance(v, dict) and v.get("scheme") else "")
        for v in ((doc.get("components") or {}).get("securitySchemes") or {}).values()
        if isinstance(v, dict)
    })

    return {
        "version": doc.get("openapi") or doc.get("swagger") or "?",
        "bytes": size,
        "paths": len(doc.get("paths") or {}),
        "operations": len(ops),
        "op_id_pct": round(100.0 * len(with_id) / len(ops)) if ops else 0,
        "schemas": len(schemas),
        "max_depth": max_depth,
        "constructs": counts,
        "anyof": anyof,
        "union_of_refs": union_of_refs,
        "addl_open": addl_open,
        "addl_typed": addl_typed,
        "formats": formats,
        "media": media,
        "auth": auth,
        "sse": media.get("text/event-stream", 0),
        "multipart": media.get("multipart/form-data", 0),
    }


# --- the closure report -----------------------------------------------------

def ref_name(ref):
    return ref.rsplit("/", 1)[-1] if isinstance(ref, str) else None


def refs_in(node):
    """Every `$ref` component name reachable inside `node`, not following them."""
    out = set()
    for sub, _ in walk(node):
        if "$ref" in sub:
            name = ref_name(sub["$ref"])
            if name:
                out.add(name)
    return out


def closure(doc, op_ids):
    """The transitive component-schema closure of a named operation set.

    This is the number behind Arc 3's "filtering is mandatory, not an optimization":
    if a realistic three-operation client needs 40 of 928 schemas, generating the
    whole spec is emitting 95% of a library nobody asked for.
    """
    schemas = ((doc.get("components") or {}).get("schemas")) or {}
    wanted = {i.strip() for i in op_ids}
    seeds, found_ids = set(), []
    for op, path, method in operations(doc):
        if (op.get("operationId") or "").strip() in wanted:
            found_ids.append(op["operationId"])
            seeds |= refs_in(op)
    seen, queue = set(), list(seeds)
    while queue:
        name = queue.pop()
        if name in seen or name not in schemas:
            seen.add(name)
            continue
        seen.add(name)
        queue.extend(refs_in(schemas[name]) - seen)
    return found_ids, seen & set(schemas), len(schemas)


# --- reporting --------------------------------------------------------------

def human(n):
    # Decimal, to stay comparable with the sizes already in api-access.md's table.
    for unit, div in (("MB", 1_000_000), ("KB", 1_000)):
        if n >= div:
            return f"{n / div:.1f} {unit}"
    return f"{n} B"


def target_rows(results):
    head = ["API", "Version", "Size", "Paths", "Ops", "opId", "Schemas", "Depth",
            "SSE", "Multipart", "Auth"]
    rows = []
    for name, r in results.items():
        rows.append([
            name, str(r["version"]), human(r["bytes"]), str(r["paths"]),
            str(r["operations"]), f"{r['op_id_pct']}%", str(r["schemas"]),
            str(r["max_depth"]), "yes" if r["sse"] else "—",
            "yes" if r["multipart"] else "—", ", ".join(r["auth"]) or "—",
        ])
    return head, rows


def construct_rows(results):
    total = collections.Counter()
    for r in results.values():
        total.update(r["constructs"])
        total["anyOf:nullable"] += r["anyof"]["nullable"]
        total["anyOf:tagged"] += r["anyof"]["tagged"]
        total["anyOf:untagged"] += r["anyof"]["untagged"]
        total["additionalProperties:true"] += r["addl_open"]
        total["additionalProperties:{T}"] += r["addl_typed"]
    head = ["Construct", "Total"] + list(results)
    rows = []
    for key, n in total.most_common():
        if key == "anyOf":
            continue  # superseded by the three anyOf: rows
        per = []
        for r in results.values():
            if key.startswith("anyOf:"):
                per.append(str(r["anyof"][key.split(":")[1]]))
            elif key == "additionalProperties:true":
                per.append(str(r["addl_open"]))
            elif key == "additionalProperties:{T}":
                per.append(str(r["addl_typed"]))
            else:
                per.append(str(r["constructs"][key]))
        rows.append([key, str(n)] + per)
    return head, rows


def as_table(head, rows, markdown):
    if markdown:
        out = ["| " + " | ".join(head) + " |",
               "| " + " | ".join("---" for _ in head) + " |"]
        out += ["| " + " | ".join(r) + " |" for r in rows]
        return "\n".join(out)
    widths = [max(len(str(c)) for c in [head[i]] + [r[i] for r in rows])
              for i in range(len(head))]
    fmt = "  ".join(f"{{:<{w}}}" for w in widths)
    out = [fmt.format(*head), fmt.format(*["-" * w for w in widths])]
    out += [fmt.format(*r) for r in rows]
    return "\n".join(out)


def guru_sample(n, refresh=False):
    """`n` APIs sampled from APIs.guru, evenly across its (alphabetical) list, so
    the aggregate histogram is not all one vendor's shape."""
    listing = json.loads(fetch("https://api.apis.guru/v2/list.json", refresh))
    names = sorted(listing)
    step = max(1, len(names) // n)
    picked = []
    for name in names[::step][:n]:
        versions = listing[name].get("versions") or {}
        pref = listing[name].get("preferred")
        info = versions.get(pref) or (list(versions.values())[0] if versions else None)
        url = (info or {}).get("swaggerUrl")
        if url:
            picked.append((name, url))
    return picked


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--only", help="comma-separated subset of the hand-list")
    ap.add_argument("--guru", type=int, default=0, help="also sample N APIs.guru specs")
    ap.add_argument("--closure", help="filtered-surface report for one target")
    ap.add_argument("--markdown", action="store_true", help="emit markdown tables")
    ap.add_argument("--refresh", action="store_true", help="refetch, ignoring the cache")
    args = ap.parse_args()

    names = list(TARGETS)
    if args.only:
        names = [n.strip() for n in args.only.split(",")]

    docs, results = {}, {}
    for name in names:
        try:
            t0 = time.time()
            url = resolve(TARGETS[name], args.refresh)
            body = fetch(url, args.refresh)
            doc = load(body)
            docs[name] = doc
            results[name] = survey(doc, len(body))
            print(f"  {name}: {human(len(body))} in {time.time() - t0:.1f}s", file=sys.stderr)
        except Exception as e:  # a dead URL is data, not a crash
            print(f"  {name}: FAILED — {type(e).__name__}: {e}", file=sys.stderr)

    if args.closure:
        doc = docs.get(args.closure)
        if doc is None:
            print(f"no document for {args.closure}", file=sys.stderr)
            return 1
        ids = REALISTIC.get(args.closure)
        if not ids:
            print(f"no REALISTIC operation set for {args.closure}", file=sys.stderr)
            return 1
        found, reached, total = closure(doc, ids)
        print(f"\n== filtered surface: {args.closure} ==")
        print(f"  operations selected: {len(found)}/{len(ids)} matched {found}")
        print(f"  schemas reachable:   {len(reached)} of {total} "
              f"({100.0 * len(reached) / total:.1f}%)")
        print(f"  schemas skipped:     {total - len(reached)}")
        return 0

    print("\n== targets ==")
    print(as_table(*target_rows(results), args.markdown))

    print("\n== constructs ==")
    print(as_table(*construct_rows(results), args.markdown))

    print("\n== the anyOf residue ==")
    for name, r in results.items():
        a = r["anyof"]
        print(f"  {name}: {sum(a.values())} anyOf — {a['nullable']} nullable-shaped, "
              f"{a['tagged']} discriminated, {a['untagged']} untagged "
              f"({r['union_of_refs']} of those all-$ref)")

    if args.guru:
        print(f"\n== APIs.guru sample (n={args.guru}) ==")
        agg, ok, failed = collections.Counter(), 0, 0
        anyof, using, versions = collections.Counter(), collections.Counter(), collections.Counter()
        skipped_v2 = 0
        for name, url in guru_sample(args.guru, args.refresh):
            try:
                body = fetch(url, args.refresh)
                r = survey(load(body), len(body))
            except Exception:
                failed += 1
                continue
            # Swagger 2.0 is explicitly out of scope (api-access.md § Why OpenAPI),
            # and it has no oneOf/anyOf/nullable at all — leaving it in would make
            # the histogram describe a format we are not targeting. APIs.guru is
            # roughly 40% 2.0, so this matters.
            if not str(r["version"]).startswith("3"):
                skipped_v2 += 1
                continue
            ok += 1
            agg.update(r["constructs"])
            anyof.update(r["anyof"])
            versions[str(r["version"])] += 1
            for key, count in r["constructs"].items():
                if count:
                    using[key] += 1
        print(f"  surveyed {ok} OpenAPI 3.x; skipped {skipped_v2} Swagger 2.0, "
              f"{failed} unreadable")
        print(f"  versions: {dict(versions.most_common())}")
        # Two columns, because they answer different questions. `total` says how
        # much work a construct is; `specs` says whether it can be skipped at all —
        # one 6000-occurrence spec and 60 specs using it a hundred times each are
        # very different signals, and only the second means "mandatory".
        print(f"    {'construct':<24} {'total':>7}  {'specs':>5}")
        for key, n in agg.most_common(14):
            print(f"    {key:<24} {n:>7}  {using[key]:>5}/{ok}")
        print(f"    anyOf split: {dict(anyof)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
