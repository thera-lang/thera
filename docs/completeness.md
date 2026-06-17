# Self-hosting completeness — punchlist

**Where we are.** The Hawk-written front-end (`pkgs/cli/`) is a working batch
compiler + CLI: `check`, `emit`, `run`, and `test` all function, and the
front-end **self-hosts the test pipeline** — it compiles and runs its own
104-test suite, the full 200-test stdlib suite (byte-identical to the Dart
oracle), and all 12 examples. `emit` output stays byte-identical to Dart.

This is the list of what remains before the Hawk front-end can fully replace the
Dart toolchain (`tool/`) — grouped by theme, roughly ordered within each group by
priority. None of these block day-to-day self-hosting; they close the gap to
*parity* and to a trustworthy IDE story.

## CLI / runtime invocation

- **Inherit-stdio for `hawk run` — done.** `process.exec` (backed by the
  `process_exec` runtime native) spawns a child sharing the parent's
  stdin/stdout/stderr and returns its exit code; `hawk run`/`test` drive the
  runtime through it, so output streams live and interactive stdin works
  (`process.run` still captures for the programmatic case).
- **Forward CLI args after `hawk run <file>` to the program — done.** `std.cli`
  gained a `trailing_var_arg` capability: once a command's first positional is
  seen, it and everything after (flags included) are captured verbatim. `run` is
  marked trailing, so `hawk run foo.hawk --bar --baz=qux` forwards
  `--bar --baz=qux` to the program with no `--` separator (the `run` command's
  own flags must precede `<file>`).
- **Translate the LSP command — done (v1).** `hawk lsp` is a working language
  server in Hawk (`pkgs/cli/lsp/`). The JSON-RPC + Content-Length transport is
  reimplemented over `std.io` + `std.json` (replacing the Dart
  `package:lsp_server`); it handles the lifecycle (`initialize`/`shutdown`/`exit`)
  and full-document sync (`didOpen`/`didChange`/`didClose`). The four feature
  slices:
  - **diagnostics** — live `publishDiagnostics` driven by `check_source_at`.
  - **documentSymbol** — the outline: a syntactic walk of the parsed decls into a
    `DocumentSymbol[]` tree (enum variants + impl/interface methods nested), from
    the recovered parse so it works while the file still has errors.
  - **hover** — the identifier under the cursor (found from the token stream)
    resolved to a top-level declaration (file or imports) whose signature shows as
    a `hawk` code block.
  - **definition** — the same identifier-at-offset → declaration lookup, returning
    the declaration's `Location` (same-file or jumping into the imported library).

  Tested in-process (framing helpers, the read loop over an in-memory `Reader`,
  and `Server.handle` via a `StringWriter`) and verified end-to-end over real
  stdio, including cross-file hover/definition. **Follow-ups (v2):** hovering a
  *local*/parameter or an expression to show its *inferred* type, and resolving
  field/method members — both need scope-reconstruction inference at an offset
  (the Dart version's `resolvedType` path, dropped in the port); local-variable
  go-to-definition (needs the scope walk); overlay-aware imports (honor unsaved
  edits in imported libs); and memoization so hover/definition don't reload the
  import closure per request — the gateway to the horizon-1 incremental engine
  (see [frontend_in_hawk.md](frontend_in_hawk.md) §1).
- **`hawk check <dir>` and multi-target — done.** `check` now accepts one or
  more files/directories (directories recurse for `*.hawk`), sums diagnostics
  across them, and exits 0 clean / 1 with diagnostics / 2 on a missing target —
  sharing the recursive collector with `test`. (`emit` stays single-file by
  design.) `hawk parse` is intentionally **not** ported — an AST dump is a
  toolchain-debugging affordance, not agent-facing; the structured-understanding
  capability for agents is the LSP.
- **Diagnostics → stderr — done.** Added the prelude `eprintln`/`eprint` (the
  missing stderr siblings of `println`/`print`); the CLI routes all diagnostics
  and error/usage messages through them, while program output, the `test` report,
  and `--help` success stay on stdout. So `hawk check foo 2>/dev/null` is silent
  and stdout stays pipe-clean.

## Static analysis robustness (the checker must predict codegen)

The guiding invariant: **anything `emit`/`run` rejects, `check` should reject
too.** Several errors used to surface only at codegen, so `hawk check` passed on
programs that then failed to compile — and an LSP built on the checker wouldn't
flag them. Closing these is the prerequisite for a useful IDE.

- **Validate field references — done (both front-ends).** `pt.z` for a
  `Point { x, y }` now reports `no such field "z" on type Point` at `check`.
- **Validate method / built-in method names — done (both front-ends).**
  `xs.remove_last()` now reports `no method "remove_last" on List<Int>` at
  `check`, resolving against user `impl`s, interface methods, the built-in
  `String`/`List`/`Map`/`Option`/primitive natives, the synthesized enum
  `name()`, and function-valued fields. Both checks are **conservative** — they
  fire only when the receiver resolves to a concrete type the checker can judge
  (an unknown/type-parameter/namespace receiver is left to codegen), which kept
  the whole corpus false-positive-free. *(Implemented via `methodResolves` /
  `structFieldMissing` resolution predicates on the inferrer, mirroring the
  codegen ladder.)* Remaining sub-gap: field access on a **non-struct** concrete
  value (e.g. `5.x`) still falls through to codegen — narrow, low-priority.
- **Body-checking imported libraries — not needed (resolved by `hawk check
  <dir>`).** Importing a module contributes only its *signatures*, not a check of
  its function bodies — which is the **right** scoping for single-file check:
  `hawk check foo` should report foo's diagnostics, not dump errors from files it
  merely imports. The original worry ("a library's body errors hide until a
  direct check of that file") is answered by directory checking — `hawk check .`
  checks every file's body directly. One residual, accepted nuance: `hawk run
  foo` can still fail at codegen on a body error in an *imported* lib that
  `hawk check foo` didn't report (codegen compiles imports); the workflow answer
  is to check the project (a dir), not rely on transitive checking from one entry
  file — standard compiler behavior.
- **Backward-flowing inference for `Option.None` locals.** `let mut x = Option.None;`
  needs an annotation when only a later `x = Some(v)` pins the element type;
  inference doesn't flow backward. Minor, recurring in stateful code.

## Module system / visibility

- **Real per-namespace resolution + private enforcement — rising priority.** Free
  functions resolve same-file-first with a global fallback (fixes collisions),
  but: a `private` fn is still reachable cross-file via the fallback, and a `pub`
  name still collides across libraries through a namespace-qualified call (the
  qualifier is cosmetic in codegen). Types/enums/consts/natives are likewise
  global-by-bare-name. This now bites real work: bringing `std.json`/`std.io`
  into the front-end for the LSP collided `json.parse` with the parser's `parse`
  (renamed to `parse_tokens`) and a local `Message` struct with `std.core`'s
  `Message` (renamed) — both surfacing only at codegen, not `check`. The
  rename-to-dodge tax grows with every library the closure pulls in. Proper
  module-scoped resolution (qualified calls resolve within the named library) +
  `pub`/private enforcement is the real fix, and a checker diagnostic for
  duplicate top-level names would at least surface collisions early. See
  [frontend_in_hawk.md](frontend_in_hawk.md) driver/loader findings.

  A distinct, *permanent* sub-case: **prelude (`std.core`) names are always
  unqualified and in scope, so per-namespace resolution can never disambiguate
  them** — they're de-facto soft reserved words. So the prelude must hold only
  language-fundamental types/traits + verbs, never ordinary domain nouns.
  Accordingly `std.core`'s `Message` error type was replaced by an `error('...')`
  **constructor** (Go `errors.New` style) over a private carrier — the user never
  names it, so it can't collide. New common-noun symbols don't belong in the
  prelude.

## Bootstrapping & language evolution (process)

Once the Hawk front-end is the *only* front-end, "change the language" means
changing a compiler written in the language it compiles. Two questions:

1. **Can source + runtime live in one repo?** Yes — keep doing so for now. The
   bootstrap is already two-stage: a **stamped runtime + a checked-in
   `frontend.hawkbc`** (the compiled front-end) compiles the next revision of the
   Hawk sources; the result recompiles itself and must match byte-for-byte
   (fixpoint). A language change that the *current* compiled front-end can't yet
   parse/emit is introduced in two commits: first teach the checked-in compiler
   (rebuild `frontend.hawkbc` from sources that the *previous* compiler accepts),
   then use the new feature in the sources. This is the standard self-hosting
   ratchet; it works in a monorepo.
2. **A binary SDK — done (buildable).** `bin/build_sdk.sh` assembles
   `build/sdk/` = `bin/hawk` (the runtime with `frontend.hawkbc` **embedded** via
   `include_bytes!`) + `std/` (stdlib sources) + a `version` stamp
   (`<pkg>+<gitsha>`). The Rust crate's binary is renamed **`hawkrt`** (the bare
   runtime, what `cargo build` yields); the SDK launcher is **`hawk`** (the same
   binary with the front-end embedded). Dispatch: a `.hawkbc` path or `--entry`
   runs directly on the bare runtime; any other subcommand boots the embedded
   front-end — which, for `run`/`test`, re-invokes the launcher as the runtime.
   SDK-root discovery is **location-based** (no env var): the binary finds its
   `std/` from `<exe>/../` (installed) or a cwd walk-up (in-repo), and `std_root`
   accepts either `<root>/std` (distributed) or `<root>/sdk/std` (in-repo). The
   build ends with a **fixpoint check**: the freshly-built SDK re-emits its own
   front-end and the bytes must match the Dart-bootstrapped `frontend.hawkbc` —
   proving the SDK reproduces its own compiler. The Dart toolchain is still the
   stage-0 bootstrap (it emits the first `frontend.hawkbc`); retiring it means
   bootstrapping the SDK from a *previous* SDK instead. A checked-in
   `frontend.hawkbc` snapshot (so the build needs no Dart at all) is the remaining
   step, worthwhile precisely when we drop Dart.

## Retiring the Dart toolchain (the finish line)

The Dart toolchain (`tool/`) is the bootstrap compiler and the per-phase oracle.
It can be retired once: (a) the LSP is ported — **done**; (b) the checker is
robust enough that `check` predicts `emit`/`run` (the static-analysis items
above); (c) the binary SDK bootstraps from a *previous SDK* rather than from Dart
— the SDK is **buildable** (`bin/build_sdk.sh`) and self-reproduces (fixpoint),
but still takes its stage-0 `frontend.hawkbc` from Dart; the remaining step is a
checked-in `frontend.hawkbc` snapshot to break that dependency; and (d) we're
confident enough in byte-identity to stop diffing against it. Until then it stays
as the safety net.
