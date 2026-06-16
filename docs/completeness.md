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
- **Translate the LSP command.** `hawk lsp` is still a stub; the Dart
  `lsp/server.dart` (~870 LOC: diagnostics, hover, definition, symbols) is
  unported. This is the largest remaining chunk and the gateway to the horizon-1
  incremental engine (see [frontend_in_hawk.md](frontend_in_hawk.md) §1).
  *Effort: large.*
- **`hawk check <dir>` and multi-target.** The Dart `check`/`test` accept files
  *or directories* (recursing for `*.hawk` / `*_test.hawk`); the Hawk `check`/`emit`
  take a single file (`test` already recurses). Generalize `check` to dirs +
  multiple targets for parity. *Effort: small.*
- **Minor parity:** port `hawk parse` (AST dump); send diagnostics/errors to
  **stderr** (the Hawk CLI currently `println`s them to stdout, the Dart CLI uses
  stderr). *Effort: small.*

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
- **Body-check imported libraries.** Importing a module does **not** type-check
  its function bodies — body-level errors hide until a *direct* `hawk check` of
  that file. The self-hosting milestone wants every source to pass a direct check,
  and this is also what let the `let`-annotation codegen bug hide from `check`.
- **Backward-flowing inference for `Option.None` locals.** `let mut x = Option.None;`
  needs an annotation when only a later `x = Some(v)` pins the element type;
  inference doesn't flow backward. Minor, recurring in stateful code.

## Module system / visibility

- **Real per-namespace resolution + private enforcement.** Free functions resolve
  same-file-first with a global fallback (fixes collisions), but: a `private` fn is
  still reachable cross-file via the fallback, and a `pub` name still collides
  across libraries through a namespace-qualified call (the qualifier is cosmetic in
  codegen — this is why `main.hawk`'s dispatch fn had to be renamed off `run` to
  avoid `process.run`). Types/enums/consts/natives remain global-by-bare-name.
  Proper module-scoped resolution + `pub`/private enforcement is the real fix.
  See [frontend_in_hawk.md](frontend_in_hawk.md) driver/loader findings.

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
2. **Do we want a separate binary SDK snapshot?** Eventually, yes — for *release*
   stability, not for development. A periodically-updated **SDK artifact (the Rust
   VM binary + a frozen `frontend.hawkbc` + the stdlib sources)** decouples "the
   compiler people use" from "the compiler in `main`", so a breaking in-progress
   change can't brick the build, and bootstrapping doesn't require a from-source
   Rust + Dart toolchain. Until the Dart toolchain is retired it *is* our stable
   bootstrap, so the binary-SDK snapshot becomes worthwhile precisely when we drop
   Dart. Plan: define the SDK layout + a `hawk` launcher that finds it (the
   `find_sdk_root` / `find_runtime_binary` seams already exist), then cut snapshots
   on a cadence.

## Retiring the Dart toolchain (the finish line)

The Dart toolchain (`tool/`) is the bootstrap compiler and the per-phase oracle.
It can be retired once: (a) the LSP is ported, (b) the checker is robust enough
that `check` predicts `emit`/`run` (the static-analysis items above), (c) the
binary-SDK snapshot replaces "compile the front-end with Dart" as the bootstrap,
and (d) we're confident enough in byte-identity to stop diffing against it. Until
then it stays as the safety net.
