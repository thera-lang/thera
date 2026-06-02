# Hawk

Hawk is a proof-of-concept programming language designed to maximize the
productivity of LLMs and coding agents (strong static typing, errors as values,
immutability by default, brace-delimited, batteries-included stdlib).

Full design docs: start at **[docs/toc.md](docs/toc.md)**.

## Repo map

- `runtime/` — **the active codebase**: a Rust runtime with a Tier-0 bytecode
  interpreter and the serialized `.hawkbc` format.
- `sdk/std/` — Hawk standard library sources (`.hawk`, with `native fn` decls).
- `tool/` — legacy Dart toolchain (lexer/parser/checker/tree-walking
  interpreter/LSP). Maintained until the Hawk front-end can self-host.
- `pkgs/cli/` — placeholder for the future Hawk-written front-end + CLI.
- `examples/` — example `.hawk` programs. `bin/` — dev entry scripts.
- `docs/` — design docs.

## Current state

The Rust runtime executes bytecode covering `Int`/`Double`/`Bool`/`Unit`,
control flow, functions + recursion, enums (`Result`/`Option`, `?`/`match`),
structs + a type table, `List`/`Map`/`Set`, and observable output. Bytecode
serializes to/from `.hawkbc` (constant pool; natives bound by name). The Dart
toolchain parses/checks/runs `.hawk` **and emits `.hawkbc`** (`hawk emit`),
covering the language core; the Hawk-written front-end is deferred. See
[docs/roadmap.md](docs/roadmap.md).

## Commands

The runtime is the main thing to build and test:

```
cd runtime
cargo test          # also: cargo clippy, cargo fmt
cargo run -- emit-demo /tmp/x.hawkbc   # write a sample module
cargo run -- run /tmp/x.hawkbc          # load + run it
```

The Dart toolchain runs current Hawk: `bin/hawk.sh <run|check> <file.hawk>`.

## Working conventions

- Keep every change `cargo test` / `cargo clippy` / `cargo fmt --check` clean.
- Work in small, self-contained increments, each with tests.
- Match the surrounding code's style and comment density.
