# Thera

Thera is a proof-of-concept programming language designed to maximize the
productivity of LLMs and coding agents (strong static typing, errors as values,
immutability by default, brace-delimited, batteries-included stdlib).

Full design docs: start at **[docs/toc.md](docs/toc.md)**.

## Repo map

- `runtime/` — a Rust runtime: a Tier-0 bytecode interpreter, the serialized
  `.thera-bc` format, GC, and the cooperative fiber scheduler. Builds `thera-rt`
  (the bare runtime).
- `pkgs/cli/` — **the active front-end**, written in Thera: lexer → parser →
  resolver → checker → inference → codegen → encoder, plus the
  `check`/`emit`/`run`/`test`/`fmt`/`lsp` CLI. It self-hosts.
- `sdk/std/` — Thera standard library sources (`.thera`, with `native fn`
  decls). Each library lives in its own named subdir
  (`sdk/std/path/path.thera`), with Thera tests beside it as
  `<name>_test.thera`.
- `bootstrap/frontend.thera-bc` — the checked-in self-hosting bootstrap (the
  front-end compiled to bytecode); compiles the next revision of the front-end
  so the build needs no external toolchain. See `bootstrap/README.md`.
- `examples/` — example `.thera` programs. `bench/` — perf/GC benchmark
  harnesses. `bin/` — dev entry scripts.
- `docs/` — design docs.

## Current state

The Rust runtime executes bytecode covering `Int`/`Double`/`Bool`/`Unit`,
control flow, functions + recursion, closures, enums, structs + a type table,
`List`/`Map`/`Set`, cooperative fibers + channels, and observable output.
Bytecode serializes to/from `.thera-bc` (constant pool; natives bound by name).
**The front-end is self-hosted in Thera** (`pkgs/cli/`) — it parses/checks/runs
`.thera` and emits `.thera-bc`, and `bin/build_sdk.sh` reproduces it
byte-for-byte (fixpoint). The Dart toolchain that bootstrapped it has been
retired.

Notable front-end facts (easy to get wrong): `Result`/`Option` are ordinary
`std.core` enums — construct them **qualified** (`Result.Ok(x)`, `Option.None`);
match patterns stay bare. Built-in methods on `String`/`List`/`Map`/`Option` and
on primitives are `native fn`s in `sdk/std/core/` (no hardcoded method table).
Interfaces (`Eq`/`Display`/`Debug`) are checked contracts with **dynamic
dispatch**: interface-typed values (`fn show(x: Display)`, `List<Display>`) and
bounded generics (`<T: Eq + Debug>`, enforced at call sites) dispatch via
`call.virtual`, with built-in fallbacks for primitives and the structural
`eq`/`debug` derives. See [docs/roadmap.md](docs/roadmap.md) and
[docs/language.md](docs/language.md).

## Commands

The runtime is the main thing to build and test:

```
cd runtime
cargo test          # also: cargo clippy, cargo fmt
cargo build         # builds `thera-rt` — the bare runtime (runs a .thera-bc)
cargo run -- emit-demo /tmp/x.thera-bc   # write a sample module
cargo run -- /tmp/x.thera-bc             # load + run it
```

The self-hosted front-end runs current Thera via
`bin/thera.sh <run|check|test|emit> <args>` — it compiles the current `pkgs/cli`
with the checked-in bootstrap snapshot and runs the result on `thera-rt`
(caching the dev front-end in `build/`, rebuilt when `pkgs/cli`/`sdk/std`
change). No external toolchain.

`bin/test.sh` runs everything: cargo tests, the `pkgs/cli` and `sdk/std` @test
suites, and the examples.

`bin/build_sdk.sh` assembles the SDK in `build/sdk/`: `bin/thera` (the
runtime) + `bin/inc/frontend.thera-bc` (the compiled front-end, loaded from
there at runtime)

- `std/` + a `version` stamp. So `thera-rt` = bare runtime (`cargo build`);
  `thera` = that same runtime, which on a front-end subcommand loads the sibling
  `inc/frontend.thera-bc`. Loading (not embedding) means one compile, and the
  binary stays a pure function of `runtime/` source — so CI caches it. The build
  bootstraps from `bootstrap/frontend.thera-bc` and ends with a fixpoint check
  (the SDK re-emits its own front-end and the bytes must match). Refresh the
  snapshot after front-end changes (see `bootstrap/README.md`). (A single-binary
  release that bakes the front-end in is still possible via
  `THERA_FRONTEND_BC=<blob> cargo build`.)

## Working conventions

- Keep every change `cargo test` / `cargo clippy` / `cargo fmt --check` clean.
- Work in small, self-contained increments, each with tests.
- Match the surrounding code's style and comment density.
- Perform work in new branches (no commits to main).
- Each PR should be focused on a single task, feature, or arc of work.
- PR descriptions should be brief; a summary sentence or two, the main items in
  bullet points, and an optional summary of caveats or things to be aware of.
