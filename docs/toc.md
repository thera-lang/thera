# Hawk documentation

The entry point to Hawk's design docs. Each doc opens with a one-line "what this
is"; read top-down for progressive detail.

- [guidelines.md](guidelines.md) — **why** Hawk exists: the LLM-native design
  rationale and the target domain (CLI tooling).
- [language.md](language.md) — the language **reference**: syntax, semantics,
  the standard `hawk` tool, and open design questions.
- [grammar.md](grammar.md) — the **EBNF grammar**: the keyword set, the
  operator/precedence table, every production, and a parser-completeness
  checklist of what's not yet in the syntax.
- [overview.md](overview.md) — a user facing language overview doc; what Hawk
  is, the runtime, and the why behind design decisions.
- [visibility.md](visibility.md) — the **visibility & libraries** design: the
  file privacy boundary, `pub`, barrels for directories, and the test white-box
  rule.
- [interfaces.md](interfaces.md) — the **interfaces & dispatch** design:
  conformance, `Eq`/`Display`/`Debug`, static-vs-dynamic dispatch, and the
  staged plan.
- [stdlib.md](stdlib.md) — the **standard library** design: principles, the
  prelude/core/ecosystem tiers, and the module-by-module catalog.
- [testability.md](testability.md) — the **ambient-capability** design: ambient
  free function + opt-in capability interface (`Clock`/`FileSystem`), where test
  doubles live, and why there's no global override.
- [bytecode.md](bytecode.md) — the bytecode **spec**: value model, instruction
  set, the Tier-0 interpreter, and the serialized `.hawkbc` format.
- [architecture.md](architecture.md) — the runtime **architecture**: the tiered
  VM (interpreter → Cranelift JIT), execution pipeline, GC strategy, and the
  native-function ABI.
- [roadmap.md](roadmap.md) — current **status**, the three bootstrap arcs, and
  what's next.
- [tailexpr.md](tailexpr.md) — **tail expressions** spec & sizing: making a
  block's last expression its value (and `if`/`match` value-position), the #1
  gap from the self-hosting spike.
- [frontend_in_hawk.md](frontend_in_hawk.md) — the **Hawk-in-Hawk front-end
  architecture**: the incremental/LSP target, the first batch-compiler port and
  its Dart→Hawk representational mapping, and the de-risking Dart refactors.
  Opens with the grounding self-hosting spike (the calculator slice) that ranked
  the language gaps the port depended on.

(A concise orientation for agents lives in the repo-root `CLAUDE.md`.)
