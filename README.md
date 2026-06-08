# Hawk

A proof-of-concept programming language designed to maximize the productivity of
LLMs and coding agents.

Modern languages were designed for human expressiveness. Hawk explores a
different set of tradeoffs — optimized for the way AI agents reason, generate,
and refactor code.

## Design goals

- **Strong static typing** — deterministic type boundaries prune hallucinations
- **Errors as values** — linear, visible control flow; no hidden exception paths
- **Immutability by default** — eliminates multi-hop state tracking
- **Explicit scope markers** — brace-delimited blocks survive diff-based edits
- **Data structures and interfaces** - avoid deep class hierarchies
- **Single opinionated formatter** — fewer stylistic decisions, less token waste
- **Comprehensive standard library** — reduces reliance on unfamiliar
  third-party APIs

See [docs/guidelines.md](docs/guidelines.md) for the full architectural
rationale, [docs/toc.md](docs/toc.md) for the design docs, and
[docs/roadmap.md](docs/roadmap.md) for current status.

## Status

A proof of concept under active development. A Rust bytecode interpreter runs
`.hawkbc`; a Dart front-end type-checks and compiles Hawk source to it; and a
core stdlib is written in Hawk (plus natives). Real CLI programs compile and run
end to end (see [examples/](examples/)). The goal is a language, runtime, and
stdlib complete enough to host the Hawk front-end in Hawk.
