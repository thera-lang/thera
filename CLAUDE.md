# Hawk

Hawk is a proof-of-concept programming language designed to maximize the
productivity of LLMs and coding agents (strong static typing, errors as values,
immutability by default, brace-delimited, batteries-included stdlib).

Full design docs: start at **[docs/toc.md](docs/toc.md)**.

## Repo map

- `runtime/` — a Rust runtime: a Tier-0 bytecode interpreter, the serialized
  `.hawkbc` format, GC, and the cooperative fiber scheduler. Builds `hawkrt`
  (the bare runtime).
- `pkgs/cli/` — **the active front-end**, written in Hawk: lexer → parser →
  resolver → checker → inference → codegen → encoder, plus the
  `check`/`emit`/`run`/`test`/`lsp` CLI. It self-hosts.
- `sdk/std/` — Hawk standard library sources (`.hawk`, with `native fn` decls).
  Each library lives in its own named subdir (`sdk/std/path/path.hawk`), with
  Hawk tests beside it as `<name>_test.hawk`.
- `bootstrap/frontend.hawkbc` — the checked-in self-hosting bootstrap (the
  front-end compiled to bytecode); compiles the next revision of the front-end
  so the build needs no external toolchain. See `bootstrap/README.md`.
- `examples/` — example `.hawk` programs. `bench/` — perf/GC benchmark
  harnesses. `bin/` — dev entry scripts.
- `docs/` — design docs.

## Current state

The Rust runtime executes bytecode covering `Int`/`Double`/`Bool`/`Unit`,
control flow, functions + recursion, closures, enums, structs + a type table,
`List`/`Map`/`Set`, cooperative fibers + channels, and observable output.
Bytecode serializes to/from `.hawkbc` (constant pool; natives bound by name).
**The front-end is self-hosted in Hawk** (`pkgs/cli/`) — it parses/checks/runs
`.hawk` and emits `.hawkbc`, and `bin/build_sdk.sh` reproduces it byte-for-byte
(fixpoint). The Dart toolchain that bootstrapped it has been retired.

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
cargo build         # builds `hawkrt` — the bare runtime (runs a .hawkbc)
cargo run -- emit-demo /tmp/x.hawkbc   # write a sample module
cargo run -- /tmp/x.hawkbc             # load + run it
```

The self-hosted front-end runs current Hawk via
`bin/hawk.sh <run|check|test|emit> <args>` — it compiles the current `pkgs/cli`
with the checked-in bootstrap snapshot and runs the result on `hawkrt` (caching
the dev front-end in `build/`, rebuilt when `pkgs/cli`/`sdk/std` change). No
external toolchain.

`bin/test.sh` runs everything: cargo tests, the `pkgs/cli` and `sdk/std` @test
suites, and the examples.

`bin/build_sdk.sh` assembles the binary SDK in `build/sdk/`: `bin/hawk` (the
runtime with the compiled front-end embedded) + `std/` + a `version` stamp. So
`hawkrt` = bare runtime (from `cargo build`); `hawk` = runtime + embedded
front-end (the SDK launcher). The build bootstraps from
`bootstrap/frontend.hawkbc` and ends with a fixpoint check (the SDK re-emits its
own front-end and the bytes must match). Refresh the snapshot after front-end
changes (see `bootstrap/README.md`).

## Working conventions

- Keep every change `cargo test` / `cargo clippy` / `cargo fmt --check` clean.
- Work in small, self-contained increments, each with tests.
- Match the surrounding code's style and comment density.
