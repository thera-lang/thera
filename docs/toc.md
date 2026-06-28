# Hawk documentation

The entry point to Hawk's design docs. Each doc opens with a one-line "what this
is"; read top-down for progressive detail.

- [overview.md](overview.md) — the **why**: an external-facing whitepaper on
  what Hawk is, the LLM-native design rationale, the CLI-tooling target domain,
  the runtime, and the key design trade-offs.
- [language.md](language.md) — the language **reference**: syntax and semantics
  (types, functions, control flow, tail expressions, error handling, interfaces,
  visibility & libraries), the standard `hawk` tool, the SDK layout, and open
  design questions.
- [grammar.md](grammar.md) — the **EBNF grammar**: the keyword set, the
  operator/precedence table, every production, and a parser-completeness
  checklist of what's not yet in the syntax.
- [scoping.md](scoping.md) — **name resolution & scoping**: lexical/file scope,
  the prelude, qualified-only cross-library access, the resolution algorithm,
  and the gaps where the implementation still diverges.
- [conformance.md](conformance.md) — the **conformance coverage map**: every
  testable unit of the spec, its stable logical ID, and its language-test status
  (the index behind `tests/lang/`).
- [stdlib.md](stdlib.md) — the **standard library** design: principles, the
  prelude/core/ecosystem tiers, and the module-by-module catalog.
- [testability.md](testability.md) — the **ambient-capability** design: an
  ambient free function + opt-in capability interface (`Clock`/`FileSystem`),
  where test doubles live, and why there's no global override.
- [module_init.md](module_init.md) — **module initializers**: immutable
  top-level `let` computed once at load into a global slot, eager topological
  init, and how it stays clear of "no hidden global state". The principled
  replacement for "no load-time init".
- [bytecode.md](bytecode.md) — the bytecode **spec**: value model, instruction
  set, the Tier-0 interpreter, and the serialized `.hawkbc` format.
- [architecture.md](architecture.md) — the runtime **architecture**: the tiered
  VM (interpreter → Cranelift JIT), execution pipeline, interface dispatch, GC
  strategy, the native-function ABI, the embedded front-end, and the CLI's
  commands & output-stream (stdout/stderr) convention.
- [roadmap.md](roadmap.md) — current **status**, the bootstrap arcs, deferred
  work, and remaining front-end work.
- [parser-recovery.md](parser-recovery.md) — **parser error recovery**:
  resilient parsing design, AST preservation, and incremental implementation
  plan.

(A concise orientation for agents lives in the repo-root `CLAUDE.md`.)
