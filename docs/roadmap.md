# Hawk roadmap

**What this is:** where Hawk is today and what's next. Design details for
_completed_ work live in [architecture.md](architecture.md) and
[language.md](language.md); this doc focuses on what's open.

## Current state

**Checkpoint (2026-06).** Hawk **self-hosts**. The front-end (`pkgs/cli/`,
written in Hawk) lexes, parses, resolves, type-checks, infers, and lowers Hawk
to `.hawkbc`, and runs the `check`/`emit`/`run`/`test`/`lsp` CLI (see
[architecture.md](architecture.md) for the commands and their output streams).
It compiles its own sources and the whole stdlib; `bin/build_sdk.sh` embeds it
into the `hawk` binary with a **fixpoint check** that the front-end reproduces
itself byte-for-byte. The Dart toolchain that bootstrapped it has been removed —
the build bootstraps from a checked-in `bootstrap/frontend.hawkbc` snapshot (see
`bootstrap/README.md`), and `bin/test.sh` (cargo + the `pkgs/cli`/`sdk/std`
`@test` suites + examples) is the suite.

**Runtime (`runtime/`, Rust).** A Tier-0 bytecode interpreter with an explicit
call-frame stack (`Vm::run_loop` over `Vec<Frame>`, each frame a
`{func, pc, base}` into one **unified value stack** per fiber — locals +
operands laid end to end, so a call passes its arguments in place with no
per-call allocation) and a **precise non-moving mark-sweep GC** (`heap.rs`). It
runs the full language core: `Int`/`Double`/ `Bool`/`Unit`, control flow,
functions + recursion, **closures**, enums (`Result`/`Option` as ordinary
`std.core` enums, with `?`/`match`/implicit-`Ok`), structs + a type table,
`List`/`Map`/`Set`, and **interface dispatch** — static on concrete types,
dynamic (`call.virtual` + a type-id-keyed table) for interface-typed values and
bounded generics, with bounds enforced at call sites. Natives are bound by name
at load (the native ABI). Bytecode serializes to `.hawkbc` (header + sections,
LEB128, string constant pool). A first cut of **cooperative fibers**
(`std.fiber`) is in: `spawn`/`join`/`yield` + buffered channels.

**Inference.** The front-end carries a semantic `Type`/element model
(`pkgs/cli/element/`) built by a resolution stage; inference is a **pure,
on-demand** query (`infer_expr` — no AST annotation) the checker and codegen
call. It sees through generics (`Option<T>`/`List<T>` elements, method returns,
match bindings, `?`/`unwrap`), does bidirectional and forward-flow inference,
and the checker reports located diagnostics (type mismatches, bad
calls/fields/methods, unpinnable generics). The inference-completeness arc is
**closed** — see _Completed_ at the end.

**Not yet:** a broader stdlib; generic operators (`<T: Add>`); index (`[]`)
operator overloading; the Cranelift JIT tier.
(Qualified-only resolution + `pub`/privacy are now **enforced**, and value
resolution is owner-correct; the residual is **type-name** owner-correctness — see
_Owner-correct type resolution_ below.)

## Open work

### Runtime (Rust)

- **Stdlib breadth.** `String.*`/`List.*`/`Map.*`/`Option.*` (native + Hawk),
  and
  `std.cli`/`std.fs`/`std.process`/`std.random`/`std.time`/`std.json`/`std.io`
  exist; `List.map`/`filter`/`fold` are written in Hawk over closures. The
  collection/string/bytes staples are now in (pure Hawk over the existing
  primitives, except the two `trim_*` natives): `List.first`/`last`/`is_empty`/
  `contains`/`index_of`/`reverse`/`sort` (comparator-based — a no-arg `sort()`
  waits on an `Ord` interface); `String.replace`/`repeat`/`reverse`/`find`/
  `pad_start`/`pad_end`/`trim_start`/`trim_end`; `Map.get_or`; `Bytes.is_empty`
  and a `BytesReader` (the reader counterpart to `BytesBuilder`:
  `read_u8`/`read_bytes`/`read_u32_le`/`read_u64_le`/`read_uvarint`/`read_ivarint`,
  pure Hawk, round-trips the writer). (`slice` on `String`/`List`/`Bytes` was
  already there.) The `Ord` interface + `std.sort` (`sorted`/`min`/`max`) are now
  in — see _Completed_. `std.encoding` (base64/hex/url, pure Hawk), `std.hash`
  (native digests), and `std.regex` (the `regex` crate) are in too. Remaining: the
  rest of the "batteries included" goal (`std.log`, `std.term`), and
  sorted/`Ord`-keyed `Set`/`Map` variants.
- **Fibers — phases 3–4.** Phases 0–2 are done (scheduler-drivable `run_loop`;
  `spawn`/`join`/`yield` with GC roots across every fiber; buffered
  `Channel<T>`). Design in [architecture.md](architecture.md) §Concurrency.
  Next:
  - **Phase 3 — park on real I/O.** `time.sleep` (a scheduler timer), then
    offload blocking syscalls (`fs`/`stdin`/`process`) to a worker-thread pool
    that wakes the fiber — keeping the single Hawk thread; unblocks `std.http`.
  - **Phase 4 — readiness poller** (`kqueue`/`epoll`) for sockets, to scale to
    many connections (`mio` vs. hand-rolled — the first real runtime
    dependency).
  - **Refinements:** per-channel waiter lists, true 0-capacity rendezvous
    channels, `select`, and exit semantics for surviving spawned fibers.
- **Interpreter performance — profiled (2026-06); the easy wins are in.**
  Probes: the front-end **self-compile** (`hawk emit pkgs/cli/main.hawk`) ≈ 11.6
  s release, and **mandelbrot** ≈ 0.81 s (a call-free arithmetic/loop guard).
  Measured with the built-in `native-stats` feature (per-native call counts) +
  macOS `sample` (time). Findings:
  - **The cost is the heap-access path, not dispatch.** `HEAP.with` (a
    thread-local `RefCell`) is ~62 % of `run_loop` inclusive / ~15 % pure
    self-time, and allocation (`Vec::from_iter` + `memmove`, ~27 %: per-object
    field-`Vec` construction, string/list building) is the other big chunk.
    Native _dispatch_ is cheap — the volume leaders (`eq` 9.2 M, `list_len` 8.4
    M calls) cost mostly the `HEAP.with` round-trip _around_ the call, not the
    call itself.
  - **Map/Set is not a self-compile hotspot** (≈0 time samples; `Set` isn't used
    hot). Hashed Map/Set (below) is a **scaling-robustness** item for large
    _user_ programs, not a front-end speedup — re-scoped from "perf" to
    "scaling".
  - **Done:** the **unified value stack** (one `Vec` per fiber, args passed in
    place — ~8.6 %, the real win, and the JIT shares that stack); the
    **`ListLen` opcode** (lowers `list.len()` out of `call.native` —
    time-neutral, but shrinks bytecode and is JIT-aligned like
    `ListGet`/`ListSet`).
  - **Measured and declined:** converting the heap `RefCell`→`UnsafeCell` bought
    only ~1 % (the borrow flag isn't the cost; the thread-local TLV lookup +
    allocation are) and would trade the runtime's loud-panic safety net for
    silent UB if a future `with_*_mut` closure read another heap object. Not
    worth it standalone.
  - **What's left is structural:** cut per-object allocation (an arena / inline
    small-field object representation) and the thread-local heap-access path.
    The latter is best done in the **JIT era** (a raw heap base pointer shared
    by interpreted and compiled frames, no `thread_local`, no per-access
    indirection) — where it is load-bearing and rides along with the
    untagged-value move. See the Cranelift bullet below.
- **Map/Set scaling — hashed, insertion-ordered.** _(Scaling, not a self-compile
  hotspot — see above.)_ `Obj::Map` is a `Vec<(Value, Value)>` with a linear
  `map_find` and clone-on-mutate, so building an N-entry map (the codegen symbol
  tables) is O(n²). Fix: an insertion-ordered hashed map (a Vec for order + a
  hash→index table) used **above a size threshold** so small maps stay linear.
  Constraints: content-based key hashing consistent with `values_eq`; preserved
  insertion order (the fixpoint checks byte-identity); precomputed per-key
  hashes so a lookup needn't re-enter the heap under the map's borrow. Same
  treatment for `Set`. Matters when a _user_ program builds large maps; the
  front-end's own maps are small enough that O(n) doesn't bite.
- **Read accessors that clone whole heap objects** are a recurring hot spot
  (fixed for `list.len`/indexing, GC marking, map reads; `list.len()` is now the
  `ListLen` opcode entirely). Prefer the borrowing accessor; clone only when a
  closure re-enters the heap to allocate/compare.
- **Native resource finalization — GC-owned `Obj::Foreign` (Drop on sweep).**
  Native-backed resources currently live in a process-global registry keyed by an
  `Int` handle the Hawk wrapper holds (`std.regex` compiled patterns;
  `std.process` children). The registry is never pruned, so a `Regex` that becomes
  unreachable **leaks** its compiled engine — benign for the compile-a-handful-at-
  startup norm, but unbounded for dynamic compilation (e.g. a server compiling
  user-supplied patterns in a loop). The fix is **not** Hawk-level finalizers
  (resurrection / ordering / latency footguns) **nor** a finalizer-closure
  registry, but letting a Hawk object *own* the Rust resource: add an
  `Obj::Foreign` variant that holds the resource, and the existing sweep's
  `*slot = None` drops it — **Rust's `Drop` glue is the finalizer**, run exactly
  when the object is collected, with no Hawk code and no resurrection. `std.regex`
  stops using the registry/handle: the compiled engine lives in the `Foreign`
  object the `Regex` value points at, and frees when unreachable.
  - **Perf:** per-object free cost is **unchanged** — drop dispatch is static per
    `Obj` variant (no "has a finalizer?" branch); only `Foreign` objects run a
    non-trivial destructor, and they're rare. Allocation is one slab slot like any
    object plus one `Rc` for the resource, only at `compile`. A compiled regex
    holds no Hawk `Value`s, so it's also a GC leaf (`for_each_child` yields
    nothing).
  - **The one invariant:** the sweep drops objects **while holding the `HEAP`
    `RefCell` borrow**, so a `Foreign` `Drop` must not re-enter the Hawk heap
    (no allocating, no touching `Value`s). True for regex / files / sockets (they
    release memory or OS handles, not Hawk objects) — document it on the variant.
  - **Impl:** add `Obj::Foreign`; arms in `for_each_child` (none) / `heap_bytes`;
    the `derive(Clone, PartialEq)` won't cover `dyn Any`, so a small newtype with
    manual `Clone` (`Rc` bump) + `PartialEq` (`Rc::ptr_eq` — identity). The
    `str_byte_slice` primitive and the Hawk `std.regex` layer are untouched.
  - **Scope it to *pure* resources.** Collect-on-unreachable is right for a regex
    (no external effect). It is **wrong** for `std.process` — a spawned child must
    not be reaped/killed because a GC pass noticed its handle went out of scope;
    explicit `wait`/`kill` stays. Files/sockets want an explicit `close()` with
    GC-drop only as a backstop (non-deterministic close timing risks fd
    exhaustion). So introduce `Obj::Foreign` as general infrastructure but apply
    it only where collection-on-unreachable is the intended semantics — `std.regex`
    being the clean first case. Not urgent (the leak is benign for typical apps);
    the payoff is the dynamic-compile case.
- **Cranelift JIT tier** (+ the untagged value representation and
  `f64`/large-int constant-pool entries it forces) — performance/compaction, not
  correctness-blocking. See runtime staging below and
  [architecture.md](architecture.md). This is also where the **heap-access
  rework** belongs (the interpreter profiling above pointed at `HEAP.with` as
  the dominant cost): the JIT needs a JIT-callable heap-access path anyway — a
  raw heap base pointer rather than a thread-local `RefCell`, with the borrow
  discipline enforced by construction — so the non-moving slab grows that path
  _for_ the JIT, and the interpreter inherits it. A standalone interpreter-only
  version was measured (~1 %) and declined as not worth the unsafety; here it is
  load-bearing. Strategic note from that review: a first JIT can keep the
  **tagged** 16-byte `Value` (Cranelift handles it as an aggregate; precise GC
  stays trivial because the tag survives) and defer the untagged + stackmap work
  to a second pass — decoupling "JIT works" from "JIT is fast", which de-risks
  bring-up.
- **Profiling Hawk code — planned, staged.** OS-level samplers (`perf`,
  Instruments, samply) are nearly blind to an interpreter: every Hawk function
  is the same `run_loop` native frame, and the Hawk call stack lives in the VM's
  `Vec<Frame>`. So the runtime grows its own profiler — as CPython
  (cProfile/py-spy), Ruby (stackprof/rbspy), and Lua do. The primary audience is
  **coding agents**, which shifts the design toward _deterministic,
  function-level, flat text_ over flame-graph SVGs and line-level precision.
  1. **In-VM profiler — done (v1).** Implemented as an always-shipping runtime
     feature gated by the **`HAWK_PROFILE`** env var (not a compile-time feature
     like `native-stats`; `run_loop` reads it once into a local, so a non-profiled
     run pays one predictable branch — `src/profile.rs`). Per Hawk function: exact
     **call counts**, **self + inclusive time** via **instruction-budget sampling**
     (every `HAWK_PROFILE_INTERVAL`=1000 instructions, sample the live frame stack
     at the loop top), and **allocations** attributed via the single `heap::alloc`
     chokepoint. Output is a flat table to stderr at run end, sorted by self-time;
     **deterministic** (instruction-keyed, not wall-clock — two runs are
     byte-identical, what an agent's before/after needs), guarded by a presence +
     determinism smoke in `bin/test.sh`. Because the env var propagates to the
     child runtime and the front-end is itself a Hawk program, it profiles both a
     user program (`HAWK_PROFILE=1 hawk run x.hawk`) and the front-end's own
     compilation (`HAWK_PROFILE=1 hawk check pkgs/cli` — which already shows the
     lexer at ~50% self-time and ~55M allocations, the data for the check-perf
     work). A `hawk run --profile` flag is thin sugar to add later; line/allocation
     call-site precision is #2 below.
  2. **Line attribution — enhancement.** A bytecode→source-line table in
     `.hawkbc` (debug info) so a sample/counter resolves to a Hawk line. Demoted
     from a v1 prerequisite once we accepted function-level is enough for
     _algorithmic_ issues. The same debug info gives traps a source location and
     backs the test-failure / stack-trace needs.
  3. **OS-profiler integration — JIT tier.** Once Cranelift lands, JITed Hawk
     functions are real native frames; emit `perf`'s `/tmp/perf-<pid>.map` or
     `jitdump` (the V8/JVM/.NET trick) so `perf`/samply/Instruments resolve
     them. The deep-dive view; #1 stays the portable always-on view. #1 and #3
     are complementary, not a choice.

  (Profiling the _runtime itself_ — the Rust interpreter/natives — is separate
  and already covered by `cargo` + samply/Instruments and the
  `[profile.profiling]` / `native-stats` setup.)

### Front-end / tooling

- **Owner-correct type resolution (`Type` carries its origin) — + an architecture
  review.** Phase 2e makes *value* resolution (functions/consts) owner-correct and
  lifts global name uniqueness for them, but **type names stay globally unique**:
  `resolve_type_def` resolves a type by **name** alone, because an already-resolved
  `Type.Interface(name)` (a namespace-qualified receiver type, a field's type, …)
  carries no origin, so by-name lookup is unambiguous only while type names don't
  collide across libraries. Making types owner-correct needs an **origin threaded
  into every `Type`** — through inference, unification, and codegen's type table —
  so `Foo` from library A and `Foo` from library B stay distinct. This is
  foundational (a language should resolve types correctly), and the friction hit
  while doing 2e suggests the surrounding resolution/`Type` representation is due
  for an **architecture review** — evaluate the element-model / `Type` design before
  (or as part of) this work, rather than bolting origin on. Not urgent: Hawk's
  nominal types already discourage cross-library type-name clashes, and the painful
  uniqueness case (two libraries' same-named *functions*, e.g. `std.json.parse` vs
  `std.toml.parse`) is handled by 2e. See [scoping.md](scoping.md) → Phase 2e S5.

- **Resolution — smaller open items.** (Qualified-only + `pub` visibility
  enforcement, the `FileScope` refactor, and owner-correct **value** resolution are
  done — see _Completed_; type-name owner-correctness is the _Owner-correct type
  resolution_ item above.) Remaining: `impl` coherence / orphan rules, selective
  import (`show`/`hide`), and a "module"→"library" terminology sweep.

- **Whole-closure diagnostics — remaining tail.** (Per-file origin + surfacing
  imported-file parse errors are done — see _Completed_.) Two pieces remain:
  - **Cascade suppression / cause-naming.** When an import fails to parse, its
    dependent symbols may not recover (`greet`'s decl is dropped), so the
    importer still shows a secondary `` `greet` is not a public member `` after
    the root cause. The resolver should distinguish "undefined" from
    "unavailable because its source file errored" and either suppress the
    cascade or name the cause
    (`helper.greet is unavailable: helper.hawk failed to parse`). Rides partly
    on **better parser recovery** (recover a decl's _signature_ past a body
    error — see the LSP parser-recovery item) so fewer decls drop in the first
    place.
  - **Check-path closure scope.** `check app.hawk` body-checks only the primary
    program, so an error _inside_ an imported body isn't reported by a
    single-file check (directory/project checking covers it, checking each
    file). Defensible as request-scoping, but the eventual target is
    closure-wide computation with request-scoped display. Format target stands:
    `path:line:col: severity: message`, grouped by file, deterministically
    ordered, exit non-zero iff a displayed diagnostic is an error; a
    machine-readable JSON mode can follow.

- **`native type` / `native fn` follow-ups.** (The bodyless `native type` decls
  for the built-ins are done — see _Completed_.) Open: whether to _gate_
  `native fn`/`native type` to SDK paths (ties to the `@extern` name-check
  item), and the checker leniency that lets a bare field access on an opaque
  value slip to codegen (the existing `type-field-nonstruct` residual).
- **Generics — residual follow-ons.** (Static-method type args, struct/enum bound
  enforcement, and the inference-classification cleanup are done — see _Completed_.)
  Remaining: enum construction with an *inferred* (un-annotated) argument isn't
  bound-checked yet (annotated enum use is); a bound isn't **propagated** onto an
  enclosing function's own type parameter (`fn f<U>(x: U) -> Box<U>` doesn't require
  `U: Display`); and `expected_arg_types` still handles only the namespace callee
  head inline. (Generics are **invariant by design** — no variance work planned.)
- **Semantic (scope-aware) references & rename.** `textDocument/references` and
  `textDocument/rename` are implemented but **lexical only** — they match every
  identifier token with the same text, across files, with no binding/scope
  analysis, so they'd report (or rewrite) unrelated same-named symbols. They are
  therefore **not registered** by the server (`pkgs/cli/lsp/references.hawk`,
  `rename.hawk` are parked with TODOs). Making them precise needs name
  resolution at a cursor — resolve the identifier to its _declaration_ via the
  element model, then collect only the references that bind to it (and, for
  rename, verify the new name doesn't collide). This rides on the same
  inference-at-offset work as below.
- **LSP v2 toward an incremental engine.** Inference-at-offset (hover/definition
  on locals, expressions, members), overlay-aware imports (honor unsaved edits),
  and memoizing the import-closure load. The front-end is whole-program and
  stateless per request: each `hawk check` / LSP edit re-reads, re-parses, and
  re-checks the entire import closure (incl. the `std.core` prelude) from
  scratch — fine now, but the LSP re-does it per keystroke. Longer term: cache
  parsed/resolved libraries, invalidate by file, reuse the element model across
  requests, re-check only what changed. (Transport has an end-to-end smoke test
  in `bin/test.sh`, added after a line-buffered-stdout bug let only each
  message's header reach the client — which the in-process `StringWriter`
  `@test`s couldn't catch.)
  - **Partial down-payment landed — cross-file parse cache.** `hawk check <dir>`
    now shares one parse cache (`Map<path, ParsedFile>`) across all checked
    files, so the import closure (the prelude above all) is lexed+parsed once per
    run instead of once per file — `hawk check pkgs/cli` 80s → ~10s (see
    _Completed_). The remaining duplication this item targets: a file checked as a
    primary *and* imported by a sibling is still parsed ~twice (share the primary
    parse forward — small, with an overlay-correctness note for the LSP path); and
    the per-file `build_library` still rebuilds the prelude's **element model**
    every file (the larger, invalidation-bearing piece). Back-port these into the
    incremental engine rather than bolting more caches onto the stateless path.
  - **LSP server perf landed — server-lived parse cache + edit coalescing.** The
    server now persists the parse cache across requests (keyed by path, evicted on
    edit), so the import closure is parsed once and reused per keystroke instead of
    re-parsed every change: a doc importing std.cli + std.json went 186 → 8.3
    ms/edit (~22×). And the `serve` loop drains a whole buffered burst of edits
    (non-blocking `MsgBuffer.try_message`) before a single diagnostics flush, so a
    backlog collapses to one re-check per document (100 bunched edits ≈ the cost of
    1). **Still on the table here:** (a) the per-flush re-check still rebuilds the
    closure's **element model** and re-runs the checker — the big remaining lever,
    and exactly the resolved-library caching this item is about; (b) *time-based*
    debounce for edits that arrive just apart (needs a timeout/non-blocking read
    native — small runtime add) — low priority now that warm latency (~8 ms) keeps
    pace with typing; (c) incremental `textDocumentSync` — still low ROI (the
    re-check, not the JSON, dominates) and carries UTF-16 offset risk. Profile a
    warm flush before picking (a) up, to confirm the checker pass is the cost.
- **`@extern` name check.** Native names are written once as `@extern('…')` on
  the `native fn` decls in `sdk/std`; the Rust runtime table is the other half,
  bound by name at load. Add a test asserting every `@extern` name the front-end
  can emit is accepted by the runtime, and split the runtime table into
  per-module files (`natives_fs.rs`, `natives_string.rs`, …) as it grows.
- **codegen unit-test coverage — in progress.** codegen + module_scope (~2.9k
  lines) were covered mainly end-to-end (fixpoint + examples + every suite
  running through them), so a regression surfaced as a fixpoint/example break,
  not a located unit failure. **Instruction-level tests now exist** for the
  trickier lowerings — the call-resolution branches (enum ctor / enum `name()` /
  user static+instance / native instance+static / free native / field call /
  virtual dispatch), match-dispatch bisection-vs-linear, and closure mut-capture
  boxing — decoding the emitted `Module` and asserting which opcode each lowers
  to (so a regression is a readable, located failure). Remaining: direct
  coverage of `module_scope` internals (name mangling, same-file-first
  resolution edge cases, dispatch-table building) still leans on the implicit
  end-to-end suites.
- **Parser error recovery for the LSP.** The LSP's normal input is
  _syntactically broken_ code mid-edit; the parser should synthesize a
  best-effort tree (recover past the error) so semantic resolution still runs
  and offers completions/hover. Today recovery is coarse (`sync_to_decl` — a
  single declaration-level recovery point). **Design + staged plan in
  [parser-recovery.md](parser-recovery.md):** non-fatal `expect` (fill known holes
  in place so the leaf node survives for completion) + an `Expr.Error` placeholder
  the resolver/checker analyze leniently (no semantic cascade) + finer recovery
  points (statement/block) + signature-past-body. (Keep in mind when touching the
  parser — the recent precedence-table refactor preserved the `panicking`/recovery
  structure.)
  - **Dependent feature: `textDocument/completion`.** Autocomplete requires
    navigating a mid-keystroke AST (e.g., `obj.`). Deferring until the parser
    can reliably build an AST that doesn't drop the trailing, incomplete member
    access.
  - **Dependent feature: `textDocument/signatureHelp`.** Surfaces parameter
    names while inside a function call. Relies on the parser correctly framing
    an unterminated call `foo(`, which current coarse recovery struggles with.

- **Formatter (`hawk fmt`) — design stub.** Today's `fmt` is v0 (trailing-whitespace
  trim + final newline). The real formatter should be **canonical** (one obvious
  output; expect ~all Hawk code to use it), **near-zero config**, and **idempotent**
  (formatting a formatted file is a no-op). It *mostly* normalizes layout — fix
  indentation, normalize inter-token whitespace (`fn  foo( name:String )` →
  `fn foo(name: String)`) — to eliminate ~99% of format discussion, **not** fully
  canonicalize. **Deliberately out of scope (for now): automatic line breaking /
  re-joining** — the usual source of formatter complexity; instead rely on manual
  conventions for where to break and see how far that gets. A first cut can be
  **token-only** (walk the token stream with brace/paren depth, no AST).
  - **Prerequisite + sequencing.** The lexer currently *discards* comments and
    whitespace (`skip_whitespace_and_comments`; no comment token kind / no trivia on
    `Token`), so the one real prerequisite is surfacing comments + blank-line
    structure as a **parser-invisible side channel** — trivia on tokens, or a
    positioned comment list re-associated by span (gofmt's model) — **not** in-stream
    comment tokens (which would force `advance`/`expect` to skip them, the same
    surface parser recovery rewrites). Kept that way, the compile path stays
    byte-identical (fixpoint-clean) and the formatter is **orthogonal to parser
    recovery** — sequence by priority, not coupling. Holds as long as we **only
    format syntactically-valid files** (so the formatter never consumes recovery
    output); revisit if format-through-errors is ever wanted. Hardest design call
    when we dig in: **comment attachment** (leading / trailing / dangling).

- **Doc-comment tooling — convention specced, machinery pending.** The doc
  conventions are defined ([language.md](language.md#documentation)): `///` item
  docs, `//!` file/package docs, plain `//` never extracted; a summary-first
  sentence; a small Markdown subset (fenced code only, no headers, bold-label
  sections); prose params. **`sdk/std/` is migrated** to `///`/`//!` (all 61
  files; a behavior-neutral source change — the lexer skips `///`/`//!` as
  ordinary comments, so it stayed fixpoint-clean). The remaining work is tooling:
  (1) **attach docs to AST nodes** — shares the same trivia side-channel the
  formatter needs (comments are currently discarded), so sequence it alongside
  `fmt`; (2) **LSP hover** surfaces the item/file doc; (3) a **doc generator**
  extracts a package's `pub` surface + barrel `//!` into an index for agent
  navigation; (4) **reference resolution + lint** — resolve `[Symbol]` references
  (link them in hover/doc-gen, flag ones that no longer resolve), plus a lint for
  `pub` symbols whose doc only restates the signature, and normalization of doc
  layout. (Not yet migrated: `pkgs/cli/` and `examples/`, deliberately deferred —
  the public API surface was the priority.)

### Language features not yet built

- ~~**Module initializers — computed-once immutable globals.**~~ _Done (Phase 1)_
  — see the changelog below and [module_init.md](module_init.md). Phase 2
  (process-stable ambient natives, e.g. the path separator) remains.

- **Disambiguate the empty `{}` in a `match` arm (map-literal vs block).** In
  expression position `{}` is an empty **map** (`return {}`, `let m = {}`, a
  call argument, an `if`-branch tail `{ {} }` all work). The sharp edge is a
  **`match` arm**: `pat => ( exprBlock | expr )` tries `exprBlock` first, so a
  bare `pat => {}` is an empty **block** (value `Void`), not an empty map. This
  is nasty when mixed with a non-`Void` arm: match-arm unification exempts
  `Void` arms, so `match x { Some(m) => m, None => {} }` type-checks as `Map`
  yet the `None` path returns `Void` and only **traps at runtime**
  (`map.keys: expected map`). Today's workarounds: spell it `=> { {} }` (a block
  whose tail is the map) or bind it first (`let none: Map<…> = {}; … none`) —
  both indirect and easy to forget. Want an empty map that is **unambiguous on
  its own**: a distinct empty-map token (e.g. `[:]` as in Swift/Dart, or `{:}`),
  `Map.new()`, or having the arm parser treat a bare `=> {}` as a map when the
  arm's expected type is a map. Pick by the **LLM lens**: one obvious way to
  write an empty map, no silent `Void`. (A non-empty `{ … }` is never
  ambiguous.)

- **Syntax-elegance pass — through the LLM lens.** Several common shapes are
  more verbose than they need to be; the dominant one is the resolution cascade
  `match X { Some(v) => { …; return …; }, None => {} }` (55× in codegen, 38× in
  inference, 28× in checker) — "look up, act-and-return, else fall through."
  Sugar could collapse it: an `if let Some(v) = X { … }`, `?` working on
  `Option` in a fallthrough/`-> Void` position, or a `guard`-style early return.
  Evaluate options by what's best for **LLMs** — terseness, expressiveness, and
  _one_ obvious way to do a thing (the same lens as the ternary-for-`if`
  question). A general pass, not a single feature. (Surfaced by the pkgs/ code
  review.)

- **Generic operators** (`<T: Add>`, operators-as-traits) — the remaining piece
  of the generics arc (bound enforcement + `call.virtual` dispatch on `T` are
  done). This is also where the language's **implicit operator/literal
  lowerings** would gain a Hawk-level surface: `==`, `+`/interpolation,
  `[]`/`[]=`, and the `{}` map literal are emitted by codegen straight to
  runtime natives (`eq`, `str_concat`, `stringify`,
  `list_index`/`list_set`/`map_index`, `map_new`/`map_set`) with no named Hawk
  method behind them — the one category of addressable behaviour not represented
  in `sdk/std`. Operators-as-interfaces (`Eq`, `Add`, and `Indexable` below) is
  what turns those into ordinary Hawk methods; revisit the exact shape then (the
  `[]` half is the _Index operator_ item).
- **Richer structural `Debug`.** The auto-derived `Debug` renders a struct
  **positionally** (`Name { 1, 2 }`, no field names) and a user enum **by tag**
  (`variant1`; only `Result`/`Option` variants are named) — the runtime type
  table doesn't carry field/variant names. Now user-visible: total rendering
  renders collection elements via `Debug`, so `${someEnumList}` shows
  `[variant1, variant0]`. Add field/variant names to the rendering — needs the
  names threaded into the runtime type table, or the bytecode-level name table
  the Profiling/`.hawkbc` debug-info item would add. (`Display`-for-collections
  and total rendering are done — see _Completed_.)
- **Primitive vtables — scope it (runtime / generics / soundness).** A primitive
  reached through _virtual_ dispatch — `call.virtual('display'|'eq'|'debug')`
  from a generic `<T: Display>` / interface-typed context where the runtime
  value is an `Int`/`Double`/`Bool`/`String` — does not resolve to that
  primitive's method via a vtable; it hits a **hardcoded fallback** in the
  interpreter (`virtual_fallback` in `mod.rs`: `display` → `display_string`,
  `eq` → `==`, `debug` → `debug_value`). That fallback is why `display_string`
  can't be fully retired even after the `Display` work above (it also backs
  `list.join`), and it's a small soundness gap: the dispatch is correct only
  because every primitive interface bound is one of the three built-ins, not
  because the type actually carries the method. The task: **determine the
  scope** of giving primitives real vtable entries (a type-id → selector → impl
  table for the built-in primitive types), so virtual dispatch resolves
  `Int.display → int_to_string` etc. uniformly — letting the `virtual_fallback`
  hardcodes and the primitive arms of `display_string` retire, and removing the
  "primitives are special in dispatch" axiom. Open questions to answer first:
  how primitives get a stable type-id keyed into the vtable (they're unboxed
  `Value` variants, not heap objects); whether this composes with — or should
  wait for — the bounded/conditional-impl and operators-as-interfaces generics
  work (it's the same "dispatch a built-in interface on a concrete type"
  machinery); and the cost/benefit vs. keeping a single well-documented
  fallback. Surfaced while scoping the `Display` Option B follow-up.
- **Index operator (`[]`) overloading.** `a[i]` / `a[i] = v` are hardcoded in
  codegen to the built-in `List`/`Map` natives by static type; any other
  receiver is a compile error (`pkgs/cli/codegen/codegen.hawk`). Small–medium,
  self-contained: desugar to a method call reusing static/`call.virtual`
  dispatch (inference resolves `a[i]` from the receiver's index method;
  codegen's two `throw` branches become method-call lowerings; List/Map keep
  their native fast path). Design leaning: a single `Indexable<K, V>` interface
  (one `get`- and one `set`-style method) rather than separate
  `Index`/`IndexSet`. Also a prerequisite for a Hawk `Map` (which additionally
  needs map-literal lowering and a native↔Hawk-map bridge).

## Runtime staging (longer view)

See [architecture.md](architecture.md) for the design behind each tier.

1. ~~Tree-walker POC (settle semantics); define the bytecode IR.~~ _Done._
2. ~~Tier-0 interpreter + precise non-moving mark-sweep GC.~~ _Done_ — runs real
   Hawk apps with fast startup.
3. **Cranelift JIT tier** for hot functions (or trial copy-and-patch); decide
   the JIT GC-root strategy here. This is what forces the tagged→untagged
   value-representation move (interpreted and compiled frames must share a
   representation).
4. **AOT via `cranelift-object`** later — single-binary distribution; optional,
   not on the startup-critical path.

## Completed (changelog)

Brief summaries of finished arcs; design details live in
[architecture.md](architecture.md) / [language.md](language.md) and the linked
conformance specs. Newest first.

- **Module initializers — computed-once immutable globals** (2026-06). Top-level
  `let NAME[: T] = expr;` computed once at load into a stored global slot. Runtime
  gained `global.get`/`global.set`, a `global_count` header field, a per-run
  globals vector (a GC root), and a reserved `<init>` thunk run before the entry.
  Front-end: typed globals + slot codegen, dependency-topological init with cycle
  detection, an effectful-native denylist in initializer position, and `const`
  tightened to manifest constants (a computed `const` now points at `let`).
  **Immutable only** (no top-level `let mut`). First use: `std.math`
  `INFINITY`/`NAN`; the lookup-table/keyword-map motivations proved moot
  (native/arithmetic/`match`). Full design: [module_init.md](module_init.md);
  conformance `module-let*`, `const-manifest`.
- **`std.regex` — RE2 regular expressions over the `regex` crate** (2026-06). The
  runtime's **2nd deliberate dependency** (after `std.hash`): the Rust team's
  `regex` crate, RE2-derived and linear-time. `compile`/`is_match`/`find`/
  `find_all`/`captures`/`replace`/`replace_all`, byte-offset `Match`, a
  `RegexError.Syntax` on a bad pattern. A compiled pattern lives in a runtime
  registry behind an `Int` handle (the `std.process` pattern; compiled patterns
  are not freed — a benign leak addressed by the planned _Native resource
  finalization_ item under _Open work → Runtime_); natives return byte-offset
  `List<Int>`s and the Hawk layer assembles `Match`/`Captures` via a new
  `String.byte_slice` (the byte-offset companion to `slice`), so natives never
  hardcode a struct type-id. Replaces the pure-Hawk `re2_*` version that didn't
  survive the runtime migration. Full design: [stdlib.md](stdlib.md) §std.regex.
- **`std.hash` — native digests + the runtime's first external dependencies**
  (2026-06). `sha256`/`sha1`/`md5` (digests as `Bytes`) and `crc32` (IEEE 802.3,
  as `Int`), thin `native fn` wrappers over **audited Rust crates** rather than
  reimplemented in Hawk — hashing is crypto-adjacent and wants battle-tested code.
  This adds the runtime's **first external dependencies** (previously zero),
  deliberately: the RustCrypto `sha2`/`sha1`/`md-5` crates and `crc32fast`, each
  named in its function's doc comment. The native ABI is the existing
  `with_bytes` reader + `Value::new_bytes`/`Value::Int`. Checked against published
  test vectors; pairs with `std.encoding` to render a digest. (Precedent for the
  deliberate-dependency policy the `std.regex` rebuild will revisit.)

- **`std.encoding` — base64 / hex / url** (2026-06). Flat module (`import
  std.encoding`): `base64_encode`/`decode` (RFC 4648, `+/`, `=`-padded),
  `hex_encode`/`decode` (lowercase out, case-insensitive in), and
  `url_encode`/`decode` (RFC 3986 percent-encoding — unreserved `A-Z a-z 0-9 -_.~`
  pass through, space is `%20` not `+`, `+` decodes literally). Decoding is
  fallible (`Result`), never a trap. **Pure Hawk** over `Bytes`/`String` + the
  bitwise operators — no natives and **no lookup tables** (an arithmetic char
  mapping, so it's unaffected by the pending module-initializer; a precomputed
  base64-decode table would be a marginal future tidy-up). RFC 4648 vectors +
  binary round-trip + malformed-input cases covered. `std.path` `normalize`/
  `relative` also landed (see status table).

- **Struct-definition keyword: `type Foo = { … }` → `struct Foo { … }`**
  (2026-06). Hawk is a **nominal** type system, but `type Foo = { … }` reads as
  the *structural* `type alias` of TypeScript/Flow/Elm — the wrong prior. Structs
  now use the near-universal nominal signal (keyword + name + braces, no `=`),
  rhyming with `enum`/`interface`: `struct Celsius { degrees: Int }`. Purely
  surface — the parser produces the **same `TypeDecl` AST**, so checker/codegen
  are untouched and the migrated front-end re-emits **byte-identically** (the
  bootstrap snapshot didn't even change). `native type` (opaque built-ins) is
  unchanged; the removed `type Foo = { … }` form now errors with a hint, freeing
  `type X = Y` for transparent aliases later. Landed as a **three-cycle ratchet**:
  (1) additive parser accepting both forms + snapshot refresh (so the snapshot
  groks `struct` before any source uses it, as with `native type`); (2)
  mechanically migrate all 145 sites across `sdk/std` + `pkgs/cli` + examples +
  `tests/lang`; (3) remove the legacy form + grammar/language docs + the keyword
  test. Full suite green at each step (front-end, stdlib, 93 lang conformance,
  examples).

- **LSP keystroke latency — parse cache + edit coalescing** (2026-06). Two
  pure-front-end wins (no runtime change), targeting the per-keystroke backlog.
  (1) A **server-lived parse cache** (the same lever as the `hawk check` win),
  keyed by resolved path and evicted on edit, so the import closure is parsed once
  and reused across keystrokes instead of re-read+re-parsed from disk every change:
  a doc importing std.cli + std.json went **186 → 8.3 ms/edit (~22×)**. (2) **Edit
  coalescing** — the `serve` loop drains a whole buffered burst (a non-blocking
  `MsgBuffer.try_message`), applying each edit but deferring diagnostics to a single
  `flush`, so a backlog collapses to one re-check per document (**100 bunched edits
  ≈ the cost of 1**). Next lever is caching the resolved/element-model closure (the
  incremental-engine work); see the LSP item under _Front-end / tooling_.

- **In-VM profiler + `hawk check` made ~7.7× faster** (2026-06). A deterministic,
  instruction-budget profiler (`HAWK_PROFILE`, see _Profiling_ above) drove a
  pure measure-then-fix pass on `hawk check pkgs/cli` (80s): (1) a **cross-file
  parse cache** — `check <dir>` re-lexed+re-parsed the whole import closure once
  per file, so the `std.core` prelude was parsed 46× — now shared across files
  (80s → 10.8s; 2.1B → 310M instructions; 55.6M → 9.1M allocations); (2) **string
  constant interning** — `const.str` allocated a fresh heap string per execution
  (a 24-arm keyword `match` allocated ~23 strings/call); interned constants are
  allocation-free after first use and permanent GC roots (9.1M → 6.3M
  allocations). Net 80s → ~10.4s, byte-identical fixpoint (both are runtime/
  loader-only). Notable Hawk constraint surfaced: a top-level `const` keyword map
  can't replace the `match` — with no load-time init, `const` inlines its
  initializer, rebuilding the map per call; interning was the right lever. (A
  computed-once **module `let`** would lift this constraint — see _Module
  initializers_ under _Language features not yet built_.)
  _Further check-dedup is part of the LSP incremental engine (above)._

- **Unified checker/codegen inference context + a differential oracle**
  (2026-06). Inference is one pure `infer_expr` query, but the checker and codegen
  built its `InferCtx` independently, and the fields that differed were the root of
  a bug class where the two stages inferred the same expression to different types
  (the `for_element_type` miscompile that trapped at runtime; the lambda-bounds
  spurious rejection). A **differential oracle** (`HAWK_INFER_ORACLE`, in codegen)
  maps the divergence: it found 28/855 front-end units diverged, every one a method
  on a generic type, every divergence the identical pattern — codegen dropped the
  receiver's type arguments (`self_type` `List` vs `List<T>`) and omitted the owner
  type parameters. **Fix:** codegen now builds the receiver type with its parameters
  applied (from the type definition) and adds those to the in-scope set, matching the
  checker; the chosen `self_type` is recorded so the oracle *observes* (not models)
  what codegen built. The oracle now reports **0** and is a permanent assert-zero
  guard in `bin/test.sh`. Byte-identical fixpoint (the correction is principled but
  the front-end's own lowerings were already `Unknown`-tolerant). _Remaining: extend
  the lambda-unit context snapshot to `self_type`/`type_params` (only bounds today)
  and bring the 34 lambda units into the oracle; a per-expression oracle; and a
  targeted "unexpected-Unknown" audit for inference incompleteness (distinct from
  this divergence pass — a blanket Unknown-reject is ~330 false positives)._
  **Note (lambda extension, attempted + reverted):** giving lifted lambdas the full
  inherited `self_type`/`type_params` (not just bounds) is correct on small inputs
  but made `hawk check pkgs/cli` hang — a compile-time blowup (98% CPU, no output)
  that the per-file closure recompilation in `check` exposes but a single `emit`
  and the minimal repro do not (lambdas already resolve `self`/`T` via captures, so
  the richer context is redundant *and* expensive). Redo it perf-aware: profile the
  blowup first (likely repeated work over the inherited generic context across many
  nested lambdas), or narrow what lambdas inherit.

- **`Ord` interface + `std.sort`** (2026-06). Total ordering, modeled on
  `Eq`/`Display`: `interface Ord { fn compare(self, other: Self) -> Ordering }`
  with `enum Ordering { Less, Equal, Greater }` (a third runtime-blessed enum
  alongside `Option`/`Result`, reserved type-id `TY_ORDERING`). The primitives
  carry explicit `impl Ord` (Int/Double/Bool in Hawk via `<`; String a native);
  a generic `<T: Ord>` calling `.compare()` dispatches dynamically, backed by a
  `compare` arm in the runtime `virtual_fallback` that orders the four primitives
  and returns an `Ordering` — the same explicit-impl-for-static /
  fallback-for-virtual split as `Display`. `std.sort` (qualified module) ships
  `sorted`/`sorted_desc`/`min`/`max` over `<T: Ord>` (free functions, since a
  `List<T>` *method* can't add a `T: Ord` bound). Comparison operators
  (`< <= > >=`) stay Int/Double-only — wiring them through `Ord` is left to the
  _Generic operators_ arc. Spec `iface-ord`. Fixed a latent codegen gap on the
  way: a lambda inside a generic `<T: Bound>` function lost the enclosing bounds
  when compiled as its own unit, so a bound method on a `T`-typed param failed
  (`Display` hit it too) — lifted lambdas now inherit their enclosing function's
  `type_param_bounds`.

- **Bitwise operators** (2026-06). `& | ^ << >> >>> ~` on `Int`: `<<`/`>>`
  (arithmetic) / `>>>` (logical) shifts, AND/OR/XOR, and unary NOT — lexer →
  parser precedence → checker (Int-only) → runtime opcodes (wrapping i64). Specs
  `expr-bitwise` / `expr-shift`. This let `std.random`'s SplitMix64 mix and
  `BytesBuilder`/`BytesReader`'s LEB128 / little-endian codecs move into pure
  Hawk (the `random_mix` native is gone; only the entropy seed stays native).

- **Generics: static-method type args, struct/enum bounds, inference cleanup**
  (2026-06). Three solidifications. **Static-method owner type parameters:**
  `Set.new() -> Set<T>` recovers `T` from call context (binding annotation,
  directly-passed argument, return position), and `Set<String>.new()` names it
  explicitly via **receiver type args** (`CallExpr.recv_type_args`; the parser accepts
  `Ident<...>.method(...)`; a shared `static_call_bindings` seeds the owner params for
  both inference and the checker) — `gen-static-context` / `gen-static-recv-args`.
  **Generic struct/enum bounds enforced:** a bound on a type's own parameter
  (`type Box<T: Display>`) is stored on `TypeDefElement` and checked where a concrete
  argument is supplied (annotation, struct construction) via `check_type_arg_bounds`
  — `generic-type-bounds`. **Inference cleanup:** the static-receiver classification
  (`(ns.)?Type.method` / `ns.fn`) is unified in `resolve_static_receiver` (shared by
  the three call cascades), the instance arm routes through `resolve_method`, and the
  four return-type instantiation paths collapsed onto `call_bindings` /
  `instantiate_return_ctx` (namespace arm now context-aware; `instantiate_return`
  deleted). All byte-identical fixpoint except the added checks. Generics are
  **invariant by design**. _Open follow-ons above (Generics — residual)._

- **Resolution: `FileScope` + owner-correct value resolution (Phase 2)** (2026-06).
  Resolution moved off the flat global name tables onto a single **`FileScope`** per
  file (checker, inference, codegen all consult it). Surfaces gained `name ->
  defining-file` origin maps and `build_library` per-file element tables, so **value
  (function / const) resolution is owner-correct** — bare to its own file, qualified
  within the named library — and the flat `functions`/`consts` tables were deleted.
  This **lifts global value-name uniqueness** (two libraries may share a top-level
  value name; `mod-shared-value-name`). Landed as eight behavior-preserving steps
  with the byte-identical fixpoint as the oracle, ending in one small `check_duplicates`
  relaxation. Surfaced + fixed a latent **duplicate-file-loading** bug (the loader
  compiled every shared library 3–4× under different `../` path spellings); path
  canonicalization cut the self-compile ~11.5 s → ~4.3 s and the bootstrap 282 KB →
  124 KB. _Open: type-name owner-correctness (above)._

- **`#loc` caller-location + assertion source locations** (2026-06). `#loc` is a
  compiler metaconstant (new `#` sigil) evaluating to a
  `SourceLoc { file, line, column }`; as a **default parameter value** it
  captures the call site, because Hawk materializes default arguments at the
  call site and codegen re-stamps a `#loc` default with the call's span + the
  caller's file. `std.testing` assertions take `at: SourceLoc = #loc` and prefix
  failures `file:line:column:` — the same shape `hawk check` prints, so test
  failures and compiler diagnostics share one format. Pinned by `expr-loc`.
  _Open tail above (single-hop limit; runtime backtraces)._
- **Total rendering — `Display`-preferred, `Debug`-fallback** (2026-06). `${x}`
  / `println(x)` are total: a value renders via its `Display` impl if present,
  else its auto-derived `Debug` — never a `check` error or a runtime trap
  (matching Python/Go/Swift/Java). `List`/`Map`/`Set`/`Option`/`Result` carry
  `Display` impls (elements rendered via `Debug`, so nested strings quote:
  `['a', 'b']`), with no `T: Display` bound. Mechanism: the runtime
  `virtual_fallback` for `display` falls back to `debug_value`; codegen's
  `emit_display` emits `CallVirtual('display')` for any not-statically-`Display`
  value; `display` and `debug` are **universal selectors** (`infer_callee_kind`
  → `Virtual` on any unresolved receiver). Pinned by `iface-display` /
  `iface-debug` specs. Needed a bootstrap ratchet (std impls required the
  front-end change first). _Open follow-ons:_ Richer structural `Debug`,
  Primitive vtables (both above).
- **Primitive `Display` explicit** (2026-06). `Int`/`Double`/`Bool`/`String`
  carry real `impl Display`s bound to per-type natives
  (`int_to_string`/`double_to_string`/`bool_to_string`/`str_identity`); the
  catch-all `stringify` native is gone and both front-end hardcodes removed. The
  print natives (`println`/`print`/`eprintln`/`eprint`) became plain string
  writers. `display_string` still backs the per-type natives + `list.join` + the
  virtual fallback — full retirement waits on Primitive vtables.
- **`native type` declarations for the built-ins** (2026-06).
  `Int`/`Double`/`Bool`/`String`/`List`/`Map`/`Bytes`/`BytesBuilder` have
  bodyless `native type` decls in `sdk/std/core/` — a definition + doc site,
  opaque `Builtin` type def, no codegen / no runtime type-table entry (shadows
  the `builtin_type_defs()` floor byte-identically). Spec `type-native`. _Open
  follow-ups above (`native type` / `native fn`)._
- **Whole-closure diagnostics — per-file origin + import parse errors**
  (2026-06). `Diagnostic` carries a `file` origin resolved from the span's
  source text (a span carries source _text_, not a path), so an imported-file
  error prints against its own file (exit non-zero); the loader parses every
  closure file best-effort and surfaces each file's lex/parse diagnostics
  (`LoadDiagnostic`), the LSP filtering per-URI. _Open tail above (cascade
  suppression / check-path scope)._
- **Unify call/member resolution** (2026-06). Codegen's `method_call` dispatches
  on the element model's `infer_callee_kind` (the single source of callee kind),
  choosing only the backend lowering per kind; the old codegen `ModuleScope`
  cascade was deleted, byte-identity held by the fixpoint.
- **Inference completeness** (2026-06). An un-inferable type is a clear, located
  check-time error, never a silent `Unknown`: lambda params (annotation/context
  or error), block-body lambda return, forward-flow for empty-literal/`None`
  locals (typed from first pinning use), call-argument checking for every call
  form, generic inference from context (incl. the assignment target), and
  match-arm unification. A broad "reject `Unknown`" flip was ruled out — ~330
  `Result.Ok(x)` → `Result<T, Unknown>` make leniency load-bearing.
- **`hawk test` per-test stdout capture** (2026-06). Each test's output is
  buffered via the `test_capture_*` runtime natives and shown only on failure
  (or always with `--show-output`). _Open: per-test source locations,
  machine-readable output (above)._
- **Runtime tiers 0–baseline.** Tree-walker POC + bytecode IR; Tier-0 bytecode
  interpreter + precise non-moving mark-sweep GC (see Runtime staging 1–2). Plus
  the interpreter perf wins (unified value stack, `ListLen` opcode) noted under
  _Interpreter performance_.
