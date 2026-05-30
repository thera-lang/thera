# hawk

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
- **Comprehensive standard library** — reduces reliance on unfamiliar
  third-party APIs
- **Single opinionated formatter** — fewer stylistic decisions, less token waste

See [docs/guidelines.md](docs/guidelines.md) for the full architectural
rationale.
