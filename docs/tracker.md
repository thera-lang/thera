# Issue-tracker conventions

**What this is:** how work is tracked — what belongs in the
[GitHub issue tracker](https://github.com/thera-lang/thera/issues) vs. in
[roadmap.md](roadmap.md), and the label vocabulary for issues and PRs.

## Tracker vs. roadmap

The **issue tracker** holds work items: things with a done state. Issues carry
their full rationale in the body (an agent picking one up reads it cold — a
one-liner with a link is not an issue), link the design docs they implement, and
close via `Fixes #N` on the PR.

The **roadmap** holds direction: current state, themes and sequencing, the
policy/process paragraphs that govern how items get decided (e.g. the idioms
razor), and **decision records** — choices deliberately made or deliberately
deferred ("type aliases: no, by design"). A decision record is documentation,
not a work item; an issue that exists never to be closed pollutes the queue.

Rule of thumb: if it can be closed, it's an issue; if it explains, it's a doc.

## Labels

Four orthogonal facets. Every issue and PR gets **one `area-*`**; issues also
get **one `type-*`** and **one priority**; state labels apply as they become
true. Keep the vocabulary exactly this — a label that isn't queried is noise.

### Area (blue) — where the work lives

| Label           | Covers                                                          |
| --------------- | --------------------------------------------------------------- |
| `area-runtime`  | the Rust runtime — interpreter, GC, fibers, natives, bytecode   |
| `area-frontend` | `pkgs/cli` — lexer→codegen, checker, diagnostics, fmt, lint     |
| `area-lsp`      | the language server                                             |
| `area-lang`     | language design & spec — language.md and companions             |
| `area-stdlib`   | `sdk/std` libraries                                             |
| `area-tooling`  | CLI UX, `thera doc`/`init`, `bin/` scripts                      |
| `area-pkgs`     | `pkgs/*` clients and the API-client generator                   |
| `area-docs`     | design docs and SDK-shipped docs                                |
| `area-infra`    | CI, bootstrap, release engineering                              |

`area-lang` vs. `area-frontend`: a **design call** (syntax, semantics, a
spec-level decision) is `area-lang`; **implementing** it in the compiler is
`area-frontend`. An issue that is both starts as `area-lang` with
`needs-design` and flips when the design settles.

### Type (green) — what kind of work

| Label              | Meaning                                        |
| ------------------ | ---------------------------------------------- |
| `type-bug`         | something is wrong                             |
| `type-enhancement` | new capability or improvement                  |
| `type-perf`        | performance                                    |
| `type-design`      | the deliverable is a decision, not code        |
| `type-task`        | chore, refactor, maintenance                   |
| `type-epic`        | tracking issue for an arc, linking child items |

### Priority (warm colors)

| Label | Meaning                        |
| ----- | ------------------------------ |
| `P1`  | current arc — do next          |
| `P2`  | agreed worth doing, unscheduled |
| `P3`  | someday / speculative          |

No P0: at this repo's size, drop-everything items just get done.

### State (purple/gray) — the decision axis

| Label          | Meaning                                          |
| -------------- | ------------------------------------------------ |
| `needs-design` | open question — decide before coding             |
| `decided`      | design settled — ready to implement              |
| `deferred`     | consciously parked; the rationale is in the body |
| `blocked`      | waiting on a named dependency (link it)          |

## Querying

The labels exist to be work queues:

```
gh issue list -l area-stdlib -l P1        # what's next in the stdlib
gh issue list -l needs-design             # open design questions
gh issue list -l type-epic                # the arcs
```

(The three dependabot labels — `dependencies`, `rust`, `github_actions` — are
tool-managed; leave them alone.)
