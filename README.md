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
- **Data structures and interfaces** - avoid deep class heirarchies
- **Single opinionated formatter** — fewer stylistic decisions, less token waste
- **Comprehensive standard library** — reduces reliance on unfamiliar
  third-party APIs

See [docs/guidelines.md](docs/guidelines.md) for the full architectural
rationale.
