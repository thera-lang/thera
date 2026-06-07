# Hawk documentation

The entry point to Hawk's design docs. Each doc opens with a one-line "what this
is"; read top-down for progressive detail.

- [guidelines.md](guidelines.md) — **why** Hawk exists: the LLM-native design
  rationale and the target domain (CLI tooling).
- [language.md](language.md) — the language **reference**: syntax, semantics,
  the standard `hawk` tool, and open design questions.
- [overview.md](overview.md) — a user facing language overview doc; what Hawk
  is, the runtime, and the why behind design decisions.
- [visibility.md](visibility.md) — the **visibility & libraries** design: the
  file privacy boundary, `pub`, barrels for directories, and the test white-box
  rule.
- [bytecode.md](bytecode.md) — the bytecode **spec**: value model, instruction
  set, the Tier-0 interpreter, and the serialized `.hawkbc` format.
- [architecture.md](architecture.md) — the runtime **architecture**: the tiered
  VM (interpreter → Cranelift JIT), execution pipeline, GC strategy, and the
  native-function ABI.
- [roadmap.md](roadmap.md) — current **status**, the three bootstrap arcs, and
  what's next.

(A concise orientation for agents lives in the repo-root `CLAUDE.md`.)
