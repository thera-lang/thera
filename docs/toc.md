# Thera documentation

The entry point to Thera's design docs. Each doc opens with a one-line "what
this is"; read top-down for progressive detail.

- [overview.md](overview.md) — the **why**: an external-facing whitepaper on
  what Thera is, the LLM-native design rationale, the CLI-tooling target domain,
  the runtime, and the key design trade-offs.
- [language.md](language.md) — the language **reference**: syntax and semantics
  (types, functions, control flow, tail expressions, error handling, interfaces,
  generics & assignability, visibility & libraries, name resolution & scoping),
  the standard `thera` tool, the SDK layout, and open design questions.
- [idioms.md](../sdk/doc/idioms.md) — **how to write Thera**: the agent-facing
  primer — a compact orientation, the rules first-time writers get wrong, the
  canonical form for each common shape, and a one-screen stdlib map. Lives in
  `sdk/doc/` (not here) because it ships with the built SDK.
- [documentation.md](documentation.md) — **documentation & examples**: the
  doc-comment model in full (comment forms, the summary sentence, the Markdown
  subset, `[Symbol]` references), the three tiers a code example comes in —
  fenced blocks, `@example` fns, whole programs — and the tooling that verifies
  every one of them. language.md carries the syntax; this carries the detail.
- [grammar.md](grammar.md) — the **EBNF grammar**: the keyword set, the
  operator/precedence table, every production, and a parser-completeness
  checklist of what's not yet in the syntax.
- [conformance.md](conformance.md) — the **conformance coverage map**: every
  testable unit of the spec, its stable logical ID, and its language-test status
  (the index behind `tests/lang/`).
- [stdlib.md](stdlib.md) — the **standard library** design: principles
  (including the **ambient-capability** testability model — ambient free
  function + opt-in capability interface), the prelude/core/ecosystem tiers, and
  the module-by-module catalog.
- [bytecode.md](bytecode.md) — the bytecode **spec**: value model, instruction
  set, the Tier-0 interpreter, and the serialized `.thera-bc` format.
- [architecture.md](architecture.md) — the runtime **architecture**: the tiered
  VM (interpreter → Cranelift JIT), execution pipeline, interface dispatch, GC
  strategy, the native-function ABI, the embedded front-end, and the CLI's
  commands & output-stream (stdout/stderr) convention.
- [frontend.md](frontend.md) — the self-hosted **front-end** design: the
  lexer→parser→resolver→checker→inference→codegen pipeline, and the parser's
  error-recovery design (resilient parsing, AST preservation, the anti-cascade
  suppression contract).
- [roadmap.md](roadmap.md) — current **status**, the bootstrap arcs, deferred
  work, and remaining front-end work.
- [tracker.md](tracker.md) — **issue-tracker conventions**: what belongs in the
  tracker vs. the roadmap, and the label vocabulary (`area-*`, `type-*`,
  `P1`–`P3`, state).
- [http-tls.md](http-tls.md) — **TLS for `std.http`**: the plan to add `https`
  to the client — the `rustls` crate choice, the native ABI, how a TLS session
  rides the socket park/retry model, the `TlsStream` surface, and a hermetic
  test strategy.
- [api-access.md](api-access.md) — **API access for Thera tools**: the plan for
  calling third-party HTTP APIs (GenAI, MCP, GitHub) — the platform substrate
  (HTTPS, SSE streaming, typed JSON, retries), hand-written clients as a forcing
  function (and what they settled about call surfaces, errors, and pagination),
  an OpenAPI generator to scale past them, and a measurable method for ranking
  target APIs.
- [typed-json.md](typed-json.md) — **Typed JSON**: api-access.md item 3 in
  flight — getting structs into and out of JSON well enough to write an API
  client, with a hand-decoded Anthropic Messages response as the forcing
  function.
- [scale.md](scale.md) — **Thera at scale**: the plan for keeping large
  codebases workable for agents — the four scaling failure modes (reading
  radius, discoverability, feedback latency, trustworthy prose), and the work
  items: acyclic imports, per-library checking, barrel-enforced boundaries,
  manifests, generated API indexes, doctests, mechanical refactors.

(A concise orientation for agents lives in the repo-root `CLAUDE.md`.)
