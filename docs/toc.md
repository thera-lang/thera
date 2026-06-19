# Hawk documentation

The entry point to Hawk's design docs. Each doc opens with a one-line "what this
is"; read top-down for progressive detail.

- [overview.md](overview.md) — the **why**: an external-facing whitepaper on what
  Hawk is, the LLM-native design rationale, the CLI-tooling target domain, the
  runtime, and the key design trade-offs.
- [language.md](language.md) — the language **reference**: syntax and semantics
  (types, functions, control flow, tail expressions, error handling, interfaces,
  visibility & libraries), the standard `hawk` tool, the SDK layout, and open
  design questions.
- [grammar.md](grammar.md) — the **EBNF grammar**: the keyword set, the
  operator/precedence table, every production, and a parser-completeness
  checklist of what's not yet in the syntax.
- [stdlib.md](stdlib.md) — the **standard library** design: principles, the
  prelude/core/ecosystem tiers, and the module-by-module catalog.
- [testability.md](testability.md) — the **ambient-capability** design: an
  ambient free function + opt-in capability interface (`Clock`/`FileSystem`),
  where test doubles live, and why there's no global override.
- [bytecode.md](bytecode.md) — the bytecode **spec**: value model, instruction
  set, the Tier-0 interpreter, and the serialized `.hawkbc` format.
- [architecture.md](architecture.md) — the runtime **architecture**: the tiered
  VM (interpreter → Cranelift JIT), execution pipeline, interface dispatch, GC
  strategy, the native-function ABI, the embedded front-end, and the CLI's
  commands & output-stream (stdout/stderr) convention.
- [roadmap.md](roadmap.md) — current **status**, the bootstrap arcs, deferred
  work, and remaining front-end work.

(A concise orientation for agents lives in the repo-root `CLAUDE.md`.)
