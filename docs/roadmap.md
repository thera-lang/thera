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
bounded generics, with bounds enforced at call sites and **default methods** on
interfaces. Natives are bound by name at load (the native ABI). Bytecode
serializes to `.hawkbc` (header + sections, LEB128, string constant pool). A
first cut of **cooperative fibers** (`std.fiber`) is in:
`spawn`/`join`/`yield` + buffered channels.

**Inference.** The front-end carries a semantic `Type`/element model
(`pkgs/cli/element/`) built by a resolution stage; inference is a **pure,
on-demand** query (`infer_expr` — no AST annotation) the checker and codegen
call. It sees through generics (`Option<T>`/`List<T>` elements, method returns,
match bindings, `?`/`unwrap`), does bidirectional and forward-flow inference,
and the checker reports located diagnostics (type mismatches, bad
calls/fields/methods, unpinnable generics). The inference-completeness arc is
**closed** — see _Completed_ at the end.

**Not yet:** a broader stdlib; generic operators (`<T: Add>`); index (`[]`)
operator overloading; the Cranelift JIT tier. (Qualified-only resolution +
`pub`/privacy are now **enforced**, and value resolution is owner-correct; the
residual is **type-name** owner-correctness — see _Owner-correct type
resolution_ below.)

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
  already there.) The `Ord` interface + `std.sort` (`sorted`/`min`/`max`) are
  now in — see _Completed_. `std.encoding` (base64/hex/url, pure Hawk),
  `std.hash` (native digests), and `std.regex` (the `regex` crate) are in too.
  The **lazy iteration arc** has landed: `Iterator<T>` with
  `map`/`filter`/`take`/`enumerate`
  - `collect`/`count` as **interface default methods**, the `std.iter` sources,
    and its first consumers — `io.lines`/`BufReader`, `fs.walk`, and streaming
    `fs.open`/`create` → `File` (`Reader`/`Writer`/`Seek`/`Closer`); `List.pop`
    also landed. Remaining: the rest of the "batteries included" goal
    (`std.log`, `std.term`), and sorted/`Ord`-keyed `Set`/`Map` variants.
  - **`List.enumerate()` — _landed._** A lazy `Iterator<Indexed<T>>` right on
    `List` (`for p in xs.enumerate() { … p.index … p.value … }`), the idiomatic
    replacement for a `while i < xs.len()` index loop — no import, no new syntax,
    reusing the blessed `Indexed<T>` struct (so it sidesteps the `Pair`/`Tuple`
    decision below). Backed by a small `ListEnumerateIter` cursor in
    `std.core`. This is the chosen answer to the indexed-loop ergonomics gap the
    review found (see below / [ergonomics.md](ergonomics.md)).
  - **`zip` iterator adapter** (and `flat_map`/`chain`, the other wrapped
    adapters the `enumerate` parser extension opened). `zip(a, b)` pairs two
    iterators; the **design dependency** is what it yields — Hawk has no tuple,
    so it needs a blessed `Pair<A, B>` (the way `enumerate` yields `Indexed<T>`)
    or settling the deferred `Tuple` open question (see
    [language.md](language.md) → Types → Open questions). Motivated by the
    `while i < xs.len()` parallel-index loops the ergonomics review found
    ([ergonomics.md](ergonomics.md) → Secondary observations) — e.g.
    `signatures_match`'s `i_params[i]` vs `o_params[i]`. Deferred with that
    migration (no consumer until then); decide `Pair` vs `Tuple` first.
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
  Native-backed resources currently live in a process-global registry keyed by
  an `Int` handle the Hawk wrapper holds (`std.regex` compiled patterns;
  `std.process` children; `std.fs` open `File`s). The registry is never pruned,
  so a `Regex` that becomes unreachable **leaks** its compiled engine — benign
  for the compile-a-handful-at-startup norm, but unbounded for dynamic
  compilation (e.g. a server compiling user-supplied patterns in a loop).
  `std.fs.File` already follows the guidance below (explicit `close()` frees its
  fd; an unclosed file leaks until exit) — the GC-drop **backstop** is the part
  still missing. The fix is **not** Hawk-level finalizers (resurrection /
  ordering / latency footguns) **nor** a finalizer-closure registry, but letting
  a Hawk object _own_ the Rust resource: add an `Obj::Foreign` variant that
  holds the resource, and the existing sweep's `*slot = None` drops it —
  **Rust's `Drop` glue is the finalizer**, run exactly when the object is
  collected, with no Hawk code and no resurrection. `std.regex` stops using the
  registry/handle: the compiled engine lives in the `Foreign` object the `Regex`
  value points at, and frees when unreachable.
  - **Perf:** per-object free cost is **unchanged** — drop dispatch is static
    per `Obj` variant (no "has a finalizer?" branch); only `Foreign` objects run
    a non-trivial destructor, and they're rare. Allocation is one slab slot like
    any object plus one `Rc` for the resource, only at `compile`. A compiled
    regex holds no Hawk `Value`s, so it's also a GC leaf (`for_each_child`
    yields nothing).
  - **The one invariant:** the sweep drops objects **while holding the `HEAP`
    `RefCell` borrow**, so a `Foreign` `Drop` must not re-enter the Hawk heap
    (no allocating, no touching `Value`s). True for regex / files / sockets
    (they release memory or OS handles, not Hawk objects) — document it on the
    variant.
  - **Impl:** add `Obj::Foreign`; arms in `for_each_child` (none) /
    `heap_bytes`; the `derive(Clone, PartialEq)` won't cover `dyn Any`, so a
    small newtype with manual `Clone` (`Rc` bump) + `PartialEq` (`Rc::ptr_eq` —
    identity). The `str_byte_slice` primitive and the Hawk `std.regex` layer are
    untouched.
  - **Scope it to _pure_ resources.** Collect-on-unreachable is right for a
    regex (no external effect). It is **wrong** for `std.process` — a spawned
    child must not be reaped/killed because a GC pass noticed its handle went
    out of scope; explicit `wait`/`kill` stays. Files/sockets want an explicit
    `close()` with GC-drop only as a backstop (non-deterministic close timing
    risks fd exhaustion). So introduce `Obj::Foreign` as general infrastructure
    but apply it only where collection-on-unreachable is the intended semantics
    — `std.regex` being the clean first case. Not urgent (the leak is benign for
    typical apps); the payoff is the dynamic-compile case.
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
     like `native-stats`; `run_loop` reads it once into a local, so a
     non-profiled run pays one predictable branch — `src/profile.rs`). Per Hawk
     function: exact **call counts**, **self + inclusive time** via
     **instruction-budget sampling** (every `HAWK_PROFILE_INTERVAL`=1000
     instructions, sample the live frame stack at the loop top), and
     **allocations** attributed via the single `heap::alloc` chokepoint. Output
     is a flat table to stderr at run end, sorted by self-time;
     **deterministic** (instruction-keyed, not wall-clock — two runs are
     byte-identical, what an agent's before/after needs), guarded by a
     presence + determinism smoke in `bin/test.sh`. Because the env var
     propagates to the child runtime and the front-end is itself a Hawk program,
     it profiles both a user program (`HAWK_PROFILE=1 hawk run x.hawk`) and the
     front-end's own compilation (`HAWK_PROFILE=1 hawk check pkgs/cli` — which
     already shows the lexer at ~50% self-time and ~55M allocations, the data
     for the check-perf work). A `hawk run --profile` flag is thin sugar to add
     later; line/allocation call-site precision is #2 below.
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

- **Owner-correct type resolution (`Type` carries its origin) — + an
  architecture review.** Phase 2e makes _value_ resolution (functions/consts)
  owner-correct and lifts global name uniqueness for them, but **type names stay
  globally unique**: `resolve_type_def` resolves a type by **name** alone,
  because an already-resolved `Type.Interface(name)` (a namespace-qualified
  receiver type, a field's type, …) carries no origin, so by-name lookup is
  unambiguous only while type names don't collide across libraries. Making types
  owner-correct needs an **origin threaded into every `Type`** — through
  inference, unification, and codegen's type table — so `Foo` from library A and
  `Foo` from library B stay distinct. This is foundational (a language should
  resolve types correctly), and the friction hit while doing 2e suggests the
  surrounding resolution/`Type` representation is due for an **architecture
  review** — evaluate the element-model / `Type` design before (or as part of)
  this work, rather than bolting origin on. Not urgent: Hawk's nominal types
  already discourage cross-library type-name clashes, and the painful uniqueness
  case (two libraries' same-named _functions_, e.g. `std.json.parse` vs
  `std.toml.parse`) is handled by 2e. See [scoping.md](scoping.md) → Phase 2e
  S5.

- **Resolution — smaller open items.** (Qualified-only + `pub` visibility
  enforcement, the `FileScope` refactor, and owner-correct **value** resolution
  are done — see _Completed_; type-name owner-correctness is the _Owner-correct
  type resolution_ item above.) Remaining: `impl` coherence / orphan rules,
  selective import (`show`/`hide`), and a "module"→"library" terminology sweep.

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
- **Generics — residual follow-ons.** (Static-method type args, struct/enum
  bound enforcement, and the inference-classification cleanup are done — see
  _Completed_.) Remaining: enum construction with an _inferred_ (un-annotated)
  argument isn't bound-checked yet (annotated enum use is); a bound isn't
  **propagated** onto an enclosing function's own type parameter
  (`fn f<U>(x: U) -> Box<U>` doesn't require `U: Display`); and
  `expected_arg_types` still handles only the namespace callee head inline.
  (Generics are **invariant by design** — no variance work planned.)
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
- **LSP v2 toward an incremental engine.** Full architecture + phased plan:
  **[lsp_v2.md](lsp_v2.md)** (analysis session, owner-correct value+type
  resolution, symbol identity, query layer, incremental recompute). Direction
  set: correctness-first (finish the type-origin arc before the engine/features),
  medium-scale target (~1–2k files), semantic references+rename as the first
  query-layer feature, one engine shared by `hawk check` + LSP. Near-term
  pull-outs identified there (codegen bare-call owner-correctness; a shared
  `resolve.hawk`; an analysis-session struct). Inference-at-offset
  (hover/definition on locals, expressions, members), overlay-aware imports
  (honor unsaved edits), and memoizing the import-closure load.
  - **Context-aware hover landed (no inference needed).** `hover.hawk` resolves
    the name at the cursor against the **enclosing method/impl**, not just
    top-level decls: `self` → the impl/interface type; `self.method` / `self.field`
    → that type's signature / field type (searched across all its `impl`s + the
    type decl, file + imports); a parameter → its declared type; `Enum.Variant` →
    the variant + payload. Keyed off the AST's impl/method spans + a token-stream
    `RECEIVER.member` check (and `name_at` now also matches `self`/`KwSelf`). A
    member of a **non-`self` receiver** returns null rather than guessing against
    unrelated top-level names. Still deferred to true inference-at-offset: the
    *inferred* type of a local `let` / loop variable, and `xs.foo()` where `xs`'s
    type isn't written down. Unit + end-to-end (`hawk lsp`) tested. The front-end is whole-program and
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
    files, so the import closure (the prelude above all) is lexed+parsed once
    per run instead of once per file — `hawk check pkgs/cli` 80s → ~10s (see
    _Completed_). The remaining duplication this item targets: a file checked as
    a primary _and_ imported by a sibling is still parsed ~twice (share the
    primary parse forward — small, with an overlay-correctness note for the LSP
    path); and the per-file `build_library` still rebuilds the prelude's
    **element model** every file (the larger, invalidation-bearing piece).
    Back-port these into the incremental engine rather than bolting more caches
    onto the stateless path.
  - **LSP server perf landed — server-lived parse cache + edit coalescing.** The
    server now persists the parse cache across requests (keyed by path, evicted
    on edit), so the import closure is parsed once and reused per keystroke
    instead of re-parsed every change: a doc importing std.cli + std.json went
    186 → 8.3 ms/edit (~22×). And the `serve` loop drains a whole buffered burst
    of edits (non-blocking `MsgBuffer.try_message`) before a single diagnostics
    flush, so a backlog collapses to one re-check per document (100 bunched
    edits ≈ the cost of 1). **Still on the table here:** (a) the per-flush
    re-check still rebuilds the closure's **element model** and re-runs the
    checker — the big remaining lever, and exactly the resolved-library caching
    this item is about; (b) _time-based_ debounce for edits that arrive just
    apart (needs a timeout/non-blocking read native — small runtime add) — low
    priority now that warm latency (~8 ms) keeps pace with typing; (c)
    incremental `textDocumentSync` — still low ROI (the re-check, not the JSON,
    dominates) and carries UTF-16 offset risk. Profile a warm flush before
    picking (a) up, to confirm the checker pass is the cost.
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
  [parser-recovery.md](parser-recovery.md):** non-fatal `expect` (fill known
  holes in place so the leaf node survives for completion) + an `Expr.Error`
  placeholder the resolver/checker analyze leniently (no semantic cascade) +
  finer recovery points (statement/block) + signature-past-body. (Keep in mind
  when touching the parser — the recent precedence-table refactor preserved the
  `panicking`/recovery structure.)
  - **Dependent feature: `textDocument/completion`.** Autocomplete requires
    navigating a mid-keystroke AST (e.g., `obj.`). Deferring until the parser
    can reliably build an AST that doesn't drop the trailing, incomplete member
    access.
  - **Dependent feature: `textDocument/signatureHelp`.** Surfaces parameter
    names while inside a function call. Relies on the parser correctly framing
    an unterminated call `foo(`, which current coarse recovery struggles with.

- **Formatter (`hawk fmt`) — _v1 landed (indentation); intra-line spacing still
  open._** `fmt` was v0 (trailing-whitespace trim + final newline); it is now a
  **line-preserving indentation formatter** (`pkgs/cli/fmt.hawk`). It keeps every
  line break the author chose (no automatic line breaking / re-joining — the
  deliberately-deferred source of formatter complexity) and normalizes the
  vertical layout: re-indents each line, collapses blank runs to one, trims
  trailing whitespace, single final newline. Indentation is a **token-only** pass
  over a stack of per-bracket *anchors* — a `{` block hangs from the statement
  base, a `(`/`[` from its opener line's visual column, several opens on one line
  indent the body just once (`push(Foo {`), a continuation line (leading `.`/
  operator/`->`, or after a line ending in a binary operator) gets one extra
  level, and multi-line string literals are emitted **verbatim**. Validated by
  formatting the whole corpus: a **no-op except legit blank/whitespace cleanups**,
  save ~4 lines in test files where the author used open-paren *alignment* or a
  paren-relative value-continuation — styles the canonical hanging-indent form
  deliberately replaces. Idempotent (re-formatting is a fixpoint); moves only
  whole lines, so tokens are preserved and it can never break a compile.
  - **Still open — intra-line spacing** (`fn  foo( name:String )` →
    `fn foo(name: String)`). Deferred because token adjacency alone can't tell
    generics (`List<Int>`) from comparison (`a < b`), nor unary from binary `-`;
    doing it safely wants **AST-aware** spacing, not the token-only pass. This is
    the remaining piece of the "eliminate ~99% of format discussion" goal.
  - **Follow-up — format the corpus.** Dogfood `hawk fmt` over `pkgs/cli`/
    `sdk/std`/`examples` in one sweep so the tree is a fmt fixpoint (safe:
    whitespace-only, fixpoint-clean); pairs with a CI `fmt --check`.
  - **Prerequisite + sequencing — _side channel landed._** The lexer used to
    _discard_ comments; it now captures them on a **parser-invisible side
    channel** — the positioned-comment-list (gofmt) model, chosen over trivia on
    `Token`. `lexer.tokenize` returns `LexResult.comments`: a source-ordered
    `List<Comment>` (`{kind, span}`; `CommentKind` = `Line`/`Doc` `///`/
    `ModuleDoc` `//!`, classified by marker, `////`+ = `Line`), each span the
    `//`-through-end-of-line text. Comments are **not** tokens, so the parser
    stays comment-blind and the compile path is **byte-identical** (fixpoint
    holds). **Blank-line structure is derived**, not stored — every token and
    comment carries a start line, so a blank between two elements is a
    line-number gap (a multi-line token counts newlines in its own text); no
    redundant tracking added. This keeps the formatter **orthogonal to parser
    recovery** and holds as long as we **only format syntactically-valid files**.
    Remaining for the formatter proper: **comment attachment** (leading /
    trailing / dangling) — re-associating the positioned list to AST nodes by
    span — the hardest design call, deferred to `fmt` itself. The same side
    channel is what doc-comment tooling (attach `///` to AST nodes) consumes.

- **Doc-comment tooling — convention specced, machinery pending.** The doc
  conventions are defined ([language.md](language.md#documentation)): `///` item
  docs, `//!` file/package docs, plain `//` never extracted; a summary-first
  sentence; a small Markdown subset (fenced code only, no headers, bold-label
  sections); prose params. **`sdk/std/` is migrated** to `///`/`//!` (all 61
  files; a behavior-neutral source change — the lexer skips `///`/`//!` as
  ordinary comments, so it stayed fixpoint-clean). The **trivia side-channel
  prerequisite is now landed** — the lexer surfaces comments (incl. `///`/`//!`,
  classified) on `LexResult.comments` (see the formatter prerequisite above), so
  they are no longer discarded — but every downstream consumer remains **pending**
  (the side channel is collected, then dropped: each `parse_tokens` call site
  passes only `lex.tokens`). The remaining tooling: (1) **attach docs to AST
  nodes** — a pass re-associating each `///`/`//!` comment to the decl it precedes
  by span, threaded onto the AST (or a side table) — the one piece the side
  channel directly unblocks; (2) **LSP hover** surfaces the item/file doc (today
  `hover.hawk` shows the signature only); (3) a **doc generator** extracts a
  package's `pub` surface + barrel `//!` into an index for agent navigation (no
  `doc` subcommand yet); (4) **reference resolution + lint** — resolve `[Symbol]`
  references (link them in hover/doc-gen, flag ones that no longer resolve), plus
  a lint for `pub` symbols whose doc only restates the signature, and
  normalization of doc layout. (Not yet migrated: `pkgs/cli/` and `examples/`,
  deliberately deferred — the public API surface was the priority.)

- **Tools — refactorings (suggestion diagnostics + code actions).** Once the
  ergonomics features land (see [ergonomics.md](ergonomics.md)), the common
  verbose shapes they replace become **mechanically detectable**, so the
  front-end can suggest (and a `hawk fix` / LSP code action can apply) the
  rewrite. These are tracked here but **decoupled from the language work** —
  shipping `if let` does not require building its suggester. The candidate
  refactorings, roughly highest-value first:
  - **`match` → `if let`.** A two-arm `match` whose other arm is a `_ => {}` /
    `None => {}` catch-all (`match X { Some(v) => { … }, None => {} }`) →
    `if let Some(v) = X { … }`. The dominant cascade (~323 sites; ~279 noise
    arms) — the highest-leverage cleanup.
  - **`match` → `let … else`. _Rewriter landed._** `let x = match opt { Some(v) => v, None => { …diverge… } };`
    → `let Some(x) = opt else { …diverge… };`. Fires on a plain, unannotated `let`
    whose diverging arm binds nothing (the `else` binds nothing).
  - **`match` → `?`. _Rewriter landed._** A `match r { Ok(v) => v, Err(e) => return Result.Err(e) }`
    (or the `Some(v)`/`None => return Option.None` analogue) → `r?`. Parenthesizes a
    low-precedence subject (`match a + b {…}` → `(a + b)?`), since `?` is postfix.
    The corpus had 0 sites (already idiomatic) — but the rule's own verbose
    extractors were the first dogfood: `let x = match f() { Some(n) => n, None => return Option.None }`
    → `let x = f()?`.
  - **`match` → combinator. _Rewriter landed._** `match opt { Some(v) => Option.Some(f(v)), None => Option.None }` →
    `opt.map((v) => f(v))`; `match opt { Some(v) => v, None => d }` →
    `opt.unwrap_or(d)` / `.unwrap_or_else(…)` (already underused — e.g. json
    `write_object` — so this rewrites existing code too).
  - **`while i < xs.len()` → `for` / `enumerate`. _Lint landed; rewriter not
    built (see below)._** A survey of the 65 flagged sites: **A** — `i` only ever
    appears as `xs[i]` + the increment (15, ~23%) → `for x in xs`; **B** — `i`
    never indexes `xs`, only passed on / used as a bound (6, ~9%) →
    `for i in 0..xs.len()`; **C** — `i` used as *both* `xs[i]` and for position
    (bounds, first/last checks, parallel `ys[i]`) (44, ~68%) →
    `for p in xs.enumerate() { … p.value … p.index … }`. The C majority was the
    real blocker — it needs indexed iteration, now provided by **`List.enumerate()`**
    (landed; see _Stdlib breadth_). The corpus has been **hand-migrated** with it:
    47 of the 65 sites converted to `for p in xs.enumerate()` / `for x in xs`
    (a fixpoint-clean, suite-green batch), leaving **18** that genuinely don't fit
    the shape — non-zero start (`let mut i = start`), a stepped/conditional
    increment (`i = i + 2`, argv parsers), a compound min-length bound
    (`while i < a.len() && i < b.len()`), a sub-range bound (`… .len() - 1`), a
    plain count (`while i < 4`), a `Bytes` receiver, or a list mutated mid-loop.
    An **auto-rewriter is still not built** (unlike the `match` rules it needs a
    genuine loop-body rewrite — substitute `xs[i]` → the binding and delete the
    pre-loop `let mut i = 0` + the `i = i + 1`, both outside the loop span); the
    lint flags the shape and the migration was done by hand. Deferred: a `zip`
    adapter for the parallel-two-list sub-case (needs the `Pair`/`Tuple` decision
    below).
  - **Shared machinery — _edit toolkit landed._** Edits are created by
    **AST-guided source-slice reassembly**, not AST pretty-printing: the kept
    sub-expressions (scrutinee/pattern/body) are sliced verbatim from source via
    their spans (comments and all), only the connective scaffolding is generated,
    and each replacement is formatted **as a fragment at the site's own
    indentation** (`fmt.format_fragment(text, indent)` — format at base level, then
    re-indent) so the edit is **localized**: only the rewritten span changes, the
    rest of the file is byte-identical (fmt stays a separate, whole-file concern).
    This avoids needing a faithful unparser — the kept regions carry arbitrary
    code. Landed: `pkgs/cli/edit/edit.hawk` (`TextEdit` + `apply_edits` +
    `span_edit` + offset↔line/col + `line_indent_at`), `fmt.format_fragment`, the
    `MatchExpr.origin` marker (`Source`/`IfLet`/`LetElse`, retiring the
    `span.text()` heuristic — a desugared node never re-fires),
    `lint.match_if_let` (structured site: scrutinee/pattern/body), and
    `pkgs/cli/fix/fix.hawk` — `if_let_edit` + `fix_source` (parse → collect →
    per-edit format → apply), directly unit-tested (incl. comment preservation, a
    reindent-the-spliced-region case, and a minimal-edit-leaves-the-rest-untouched
    case). Each rule adds a structured `lint.match_*` site + a `fix.*_edit`; a
    single `fix.fix_sites` walk emits at most one rewrite per `match` (the rules
    partition) plus `let … else` at the enclosing `let`. The transforms are
    vehicle-independent; a `hawk fix` CLI and an LSP code action both drive them.
  - **`hawk fix` CLI — _landed (`if let`, `?`, `unwrap_or`, `map`, `let … else`)._**
    `hawk fix <file|dir>…` (main.hawk) drives the machinery: previews by default
    (one `path:line:col: match → …` per fix), `--write` applies. UX is flagged
    provisional in `--help` (the LSP code action is the primary per-site vehicle).
    `fix_source` loops non-overlapping edit batches to a fixpoint so **nested**
    convertible matches converge (an inner match becomes visible once its enclosing
    match is rewritten — a bug the dogfooding surfaced). Rewrites are conservative
    (precision over recall — the `lint` reporters flag a broader set than `fix`
    safely rewrites): a block-bodied arm is left to a human, since moving it into a
    closure/`else` could drop statements or `return` out of the enclosing fn.
    `unwrap_or` stays eager only for a **cheap** fallback (literal/ident/field);
    a computed one becomes `unwrap_or_else`, threading the `Err(e)` binding into
    `Result`'s closure. **Dogfooded** on 8 front-end files (26 sites across
    driver/runner/element/lsp/loader/inference), plus the rule set applied to its
    own fresh `lint`/`fix` code (19 sites — the only `?` sites in the tree). That
    self-dogfood surfaced a latent `if_let_body_text` bug: a bare *diverging* arm
    body (`Some(_) => return …`) was wrapped as `{ return … }`, but a `return`
    can't be a block tail — now emitted as `{ return …; }`. The front-end compiles
    itself from all the rewritten source with the SDK fixpoint byte-identical and
    the suite green. Some of the corpus is deliberately left for the **LSP code
    action** to dogfood.
  - **LSP code action — _landed (`if let`, `?`, `unwrap_or`, `map`, `let … else`)._**
    `textDocument/codeAction` (`pkgs/cli/lsp/code_action.hawk`, registered in the
    server capabilities) offers a `refactor.rewrite` action for each rewrite site
    overlapping the request range, driving the same `fix.fix_sites` (each site
    carries its edit + title). The `WorkspaceEdit` is the localized, self-formatted
    replacement (via `format_fragment`), so applying it touches only that span — no
    document-wide reformat. Purely syntactic (parses the open buffer, no import
    closure). Honors the request's **`context.only`**: every action is a
    `refactor.rewrite`, so it is offered only when `only` is absent/empty or lists
    a `.`-separated ancestor (`refactor` / `refactor.rewrite`) — a `quickfix`- or
    `refactor.extract`-only request gets nothing (and skips the tree walk).
    In-process JSON-RPC tests cover offer (`if let` + `unwrap_or`), empty, and the
    `only` filter (ancestor / exact / unrelated / sibling). This is the per-site
    vehicle for dogfooding the rest of the corpus. (Not yet: the `while → for`
    rewriter, which needs a loop-body rewrite.)
  - **First step — a read-only count — _landed._** `hawk lint <file|dir>`
    (`pkgs/cli/lint/lint.hawk`) walks the parsed AST — purely syntactic, no import
    closure — and reports + per-rule tallies convertible sites. Source `match`es
    are told from desugared `if let`/`let … else` (an indistinguishable
    `MatchExpr`) by the keyword the span starts at — no AST marker yet. The rules
    partition (a `match` fires at most one): empty arm → `if let`;
    error-propagating arm → `?`; diverging arm in a `let` initializer →
    `let … else`; value-returning fallback → `unwrap_or`; both arms re-wrap →
    `map`. Precision over recall, so each tally is a **floor**. **The count, this
    corpus** (`pkgs/cli` / `sdk/std`; `examples` is 0 throughout):

    | rule | pkgs/cli | sdk/std | note |
    | --- | --- | --- | --- |
    | `match → if let` | 255 | 3 | the dominant cleanup, as predicted |
    | `while i < len → for` | 43 | 21 | locates candidates; some need `enumerate`/`zip` or don't convert (index lookahead) |
    | `match → unwrap_or` | 38 | 11 | high precision; `unwrap_or` *or* `unwrap_or_else` |
    | `match → let … else` | 14 | 0 | |
    | `match → map` | 11 | 4 | textbook `Some(f(v))`/`None` re-wraps |
    | `match → ?` | **0** | **0** | the codebase already uses `?` everywhere — **no payload** |

    Takeaways: `match → if let` (258) decisively justifies a codemod; `unwrap_or`
    (49) and `while i <` (64, with caveats) are worthwhile; `let … else`/`map` are
    modest; **`match → ?` has zero sites, so skip it.** Spot-checked for precision
    (true positives across all rules). Rules plug into one rule-agnostic walker;
    the calling-convention lint (positional arg → labeled param) is the next one
    but needs resolution, not just AST shape.
  - **Ecosystem payoff.** These aren't one-off cleanups: the same
    shape-matching + located-suggestion + auto-fix machinery is what a Hawk
    `lint` / `hawk fix` is built from, and what the LSP surfaces as code actions.
    Investing here (diagnostics that flag non-idiomatic code, with a mechanical
    fix) pays off for every future idiom, not just this batch — so lean into it
    rather than hand-editing files. Migration of existing code is **opportunistic
    until then** (touch a file, modernize it); the standing guard is the lint.

- **Idioms & best-practices guidance (agent-facing).** The language now has a
  canonical form for each common shape (the _Choosing a form_ table in
  [language.md](language.md), and the per-combinator "reach for it when…" docs),
  but that is reference material. The open piece is **prescriptive guidance an
  agent loads** — "write Hawk this way": prefer `if let`/`let … else`/`?`/
  combinators over `match`-as-guard, `for`/`enumerate` over `while i <`, the
  doc-comment conventions, etc. Surfaced by the ergonomics sprint, which found
  that a lot of **existing** code predates these features and doesn't use them —
  so idiomatic Hawk has to be written down somewhere consulted, not just implied.
  Open question is **where**: (a) a section in [language.md](language.md), (b) a
  separate `docs/idioms.md` (best-practices doc), or (c) a **skill / rules file**
  an agent auto-loads (the most actionable for the LLM-native goal). Likely (c)
  backed by (b). Pairs with _Tools — refactorings_: the doc says what's
  idiomatic, the lint enforces it mechanically.

### Language features not yet built

- **Calling convention — one canonical call form (tighten + enforce).** The
  decided model (see [language.md](language.md) → Named parameters): the author
  chooses each parameter's call form and the call site has exactly **one** —
  **labeled by default**, **positional via `_`** (label forbidden). This
  eliminates caller choice, so every call to a function reads the same (the
  consistency the LLM-native goal wants), while the author still gets terse,
  self-documenting call sites where each is warranted. The checker is currently
  **permissive** (a labeled parameter also accepts a positional argument, and
  labeled arguments may be reordered), so the model ships with an
  enforcement-status caveat in the docs. Sequencing:
  1. **Clarify the docs** — _done_ (language.md Named parameters + style rule).
  2. **Fix existing code** — migrate call sites that pass a labeled parameter
     positionally (or rely on reordering) to the canonical form, and add `_` to
     the parameters that should be positional (the obvious "subject" args). This
     is a corpus-wide sweep; it pairs with the _Tools — refactorings_ machinery
     (a located diagnostic for "positional argument to a labeled parameter" is
     the natural lint, with a mechanical fix).
  3. **Enforce** — the checker requires a labeled parameter's label and forbids a
     positional argument for it. Flip after the sweep so the corpus stays green.
  - **Open sub-decision:** whether to also require **source order** for labeled
    arguments (forbid `f(b: 2, a: 1)`). The same one-form principle argues yes;
    it's a separable call from the positional-vs-labeled tightening. Decide
    during step 3.
  - The style rule (`_` for the single obvious "subject" arg; labels for
    booleans / multiple same-typed / non-obvious roles) belongs in the
    agent-facing idioms guidance (see _Idioms & best-practices guidance_).
  - **Longer-term — first-arg-positional default (investigate, not scheduled).**
    If `_`-on-every-first-parameter proves a frequent irritant once the
    convention tightens, reconsider making the **first ("subject") parameter
    positional by default and the rest labeled**, with explicit overrides both
    ways. It makes the common case need no marker, at the cost of
    position-dependence and a two-way override (less "simple, one rule"). **Not
    an immediate goal.** Measure first — count how often `_` would land on the
    first parameter **under the tightened convention** (not today's permissive
    usage); that frequency is the input to the flat-`_` vs first-arg-positional
    call. (Keyword markers like `pos`/`positional` were considered and declined:
    too verbose at this frequency, and `pos` collides with the ubiquitous `pos`
    variable; `_` reads as "external label = none", consistent with the
    `external internal` slot.)

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
  `match X { Some(v) => { …; return …; }, None => {} }` (~323 sites corpus-wide;
  ~279 noise `None => {}` arms) — "look up, act-and-return, else fall through."
  **Full analysis + prioritized plan in [ergonomics.md](ergonomics.md):** the
  language features are **all landed** — P0 `if let`, P1 `let … else` (parser
  desugars to `match`; specs `cf-if-let`/`cf-let-else`), the P2 **curated
  combinator set** (Option `map`/`and_then`/`unwrap_or_else`; Result
  `is_ok`/`is_err`/`map`/`map_err`/`and_then`/`unwrap_or`/`unwrap_or_else`/`ok`),
  and P2 **`?`-on-`Option`** (same-enum-family rule, cross-family rejected with a
  fix-it; specs `err-propagate-option`/`err-propagate-cross`). Remaining: the
  one-obvious-way guardrail (a canonical form per shape — partly in the docs
  already; a prescriptive LLM rules/skill file is the open piece), and the
  cascade-cleanup refactorings. Those refactorings are now the **highest-value
  remaining item** — the dogfooding showed convertible sites are sparse, so a
  count is the way to know how many wins remain; tracked under _Front-end /
  tooling → Tools — refactorings_.

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

- **Streaming files — `fs.open`/`fs.create` + `Seek`** (2026-06). `std.io`
  gained a `Seek` interface (+ `SeekFrom` enum); `std.fs` gained `File` — a
  handle implementing `Reader`/`Writer`/`Seek`/`Closer` over an OS file (a
  runtime registry keyed by an `Int`, the regex/process pattern). `open` is a
  read handle, `create` a write handle; the OS enforces the mode. So
  `io.lines(fs.open(p)?)` streams a file line by line without `read_all`, and
  `seek` moves the cursor. No GC finalizers → `close()` is the caller's job
  (documented). Independent of the fiber I/O-parking work: a blocking file read
  just blocks the thread today and will transparently park the fiber once that
  lands. Deferred: `temp_file`, append/read-write `open_options`.

- **Interface default methods + Iterator adapters** (2026-06). Interface methods
  may carry a body — a _default_ an `impl` inherits (and may override). Compiled
  once as a shared unit with `self` typed as the interface; each implementing
  type's dispatch row is wired to it unless it overrides (no runtime change —
  same `call.virtual`). Resolution falls back to an implemented interface's
  default for concrete receivers, binding the interface's type params from the
  recorded conformance args (`impl Iterator<Int>` → `T=Int`). First use:
  `Iterator<T>` gained `map`/`filter`/`take` (lazy adapters) + `collect`/`count`
  (consumers) as defaults, so every iterator is fluent without an import and no
  `Iter<T>` wrapper is needed; `std.iter` keeps the `range`/`from_list` sources.
  Also fixed a latent bug: a lambda arg to a _virtual_ call (interface-typed
  receiver) now gets its expected param type, so `it.map((x) => …)` infers `x`.
  Spec `iface-default`; unblocks `io.lines`/`fs.walk`/`BufReader`. (`enumerate`
  followed once `impl` headers accepted nested generic args — next entry.)

- **Nested generic args in `impl` headers → `enumerate`** (2026-06). An `impl`
  header's `<…>` parsed type-parameter _names_ only, so a nested interface arg
  (`impl Iterator<Indexed<T>> for …`) didn't parse. `parse_impl_generics` now
  parses each element once and keeps both views — a TypeRef (interface arg,
  nestable) and a TypeParam (the type's own param, with bounds) — choosing by
  whether `for` follows, so nesting works and bounded inherent params
  (`impl Box<T: Display>`) still parse. With it, `Iterator` gained the
  `enumerate` adapter (`-> Iterator<Indexed<T>>`, pairing each element with its
  index); the same parser extension opens future wrapped adapters
  (`zip`/`flat_map`/`chain`).

- **Iterator-backed stdlib — `io.lines`/`BufReader`, `fs.walk`, `List.pop`**
  (2026-06). The first consumers of the new adapters. `io.lines(src)` returns a
  `BufReader` (a `Reader` wrapper yielding one line per `next`, so an
  `Iterator<String>`; `read_line` is the explicit-error primitive); plus an
  in-memory `io.from_string`/`from_bytes` Reader. `fs.walk(root)` is a lazy
  recursive `Iterator<String>` of descendant paths (unreadable dirs skipped,
  first failure kept for `.error()`). `List.pop() -> Option<T>` (a `list_pop`
  native) — the mutating companion of `last()`, chosen `Option` for consistency
  with `get`/`first`/`last`.

- **Module initializers — computed-once immutable globals** (2026-06). Top-level
  `let NAME[: T] = expr;` computed once at load into a stored global slot.
  Runtime gained `global.get`/`global.set`, a `global_count` header field, a
  per-run globals vector (a GC root), and a reserved `<init>` thunk run before
  the entry. Front-end: typed globals + slot codegen, dependency-topological
  init with cycle detection, an effectful-native denylist in initializer
  position, and `const` tightened to manifest constants (a computed `const` now
  points at `let`). **Immutable only** (no top-level `let mut`). First use:
  `std.math` `INFINITY`/`NAN`; the lookup-table/keyword-map motivations proved
  moot (native/arithmetic/`match`). Full design:
  [module_init.md](module_init.md); conformance `module-let*`, `const-manifest`.
- **`std.regex` — RE2 regular expressions over the `regex` crate** (2026-06).
  The runtime's **2nd deliberate dependency** (after `std.hash`): the Rust
  team's `regex` crate, RE2-derived and linear-time.
  `compile`/`is_match`/`find`/ `find_all`/`captures`/`replace`/`replace_all`,
  byte-offset `Match`, a `RegexError.Syntax` on a bad pattern. A compiled
  pattern lives in a runtime registry behind an `Int` handle (the `std.process`
  pattern; compiled patterns are not freed — a benign leak addressed by the
  planned _Native resource finalization_ item under _Open work → Runtime_);
  natives return byte-offset `List<Int>`s and the Hawk layer assembles
  `Match`/`Captures` via a new `String.byte_slice` (the byte-offset companion to
  `slice`), so natives never hardcode a struct type-id. Replaces the pure-Hawk
  `re2_*` version that didn't survive the runtime migration. Full design:
  [stdlib.md](stdlib.md) §std.regex.
- **`std.hash` — native digests + the runtime's first external dependencies**
  (2026-06). `sha256`/`sha1`/`md5` (digests as `Bytes`) and `crc32` (IEEE 802.3,
  as `Int`), thin `native fn` wrappers over **audited Rust crates** rather than
  reimplemented in Hawk — hashing is crypto-adjacent and wants battle-tested
  code. This adds the runtime's **first external dependencies** (previously
  zero), deliberately: the RustCrypto `sha2`/`sha1`/`md-5` crates and
  `crc32fast`, each named in its function's doc comment. The native ABI is the
  existing `with_bytes` reader + `Value::new_bytes`/`Value::Int`. Checked
  against published test vectors; pairs with `std.encoding` to render a digest.
  (Precedent for the deliberate-dependency policy the `std.regex` rebuild will
  revisit.)

- **`std.encoding` — base64 / hex / url** (2026-06). Flat module
  (`import std.encoding`): `base64_encode`/`decode` (RFC 4648, `+/`,
  `=`-padded), `hex_encode`/`decode` (lowercase out, case-insensitive in), and
  `url_encode`/`decode` (RFC 3986 percent-encoding — unreserved
  `A-Z a-z 0-9 -_.~` pass through, space is `%20` not `+`, `+` decodes
  literally). Decoding is fallible (`Result`), never a trap. **Pure Hawk** over
  `Bytes`/`String` + the bitwise operators — no natives and **no lookup tables**
  (an arithmetic char mapping, so it's unaffected by the pending
  module-initializer; a precomputed base64-decode table would be a marginal
  future tidy-up). RFC 4648 vectors + binary round-trip + malformed-input cases
  covered. `std.path` `normalize`/ `relative` also landed (see status table).

- **Struct-definition keyword: `type Foo = { … }` → `struct Foo { … }`**
  (2026-06). Hawk is a **nominal** type system, but `type Foo = { … }` reads as
  the _structural_ `type alias` of TypeScript/Flow/Elm — the wrong prior.
  Structs now use the near-universal nominal signal (keyword + name + braces, no
  `=`), rhyming with `enum`/`interface`: `struct Celsius { degrees: Int }`.
  Purely surface — the parser produces the **same `TypeDecl` AST**, so
  checker/codegen are untouched and the migrated front-end re-emits
  **byte-identically** (the bootstrap snapshot didn't even change).
  `native type` (opaque built-ins) is unchanged; the removed `type Foo = { … }`
  form now errors with a hint, freeing `type X = Y` for transparent aliases
  later. Landed as a **three-cycle ratchet**: (1) additive parser accepting both
  forms + snapshot refresh (so the snapshot groks `struct` before any source
  uses it, as with `native type`); (2) mechanically migrate all 145 sites across
  `sdk/std` + `pkgs/cli` + examples + `tests/lang`; (3) remove the legacy form +
  grammar/language docs + the keyword test. Full suite green at each step
  (front-end, stdlib, 93 lang conformance, examples).

- **LSP keystroke latency — parse cache + edit coalescing** (2026-06). Two
  pure-front-end wins (no runtime change), targeting the per-keystroke backlog.
  (1) A **server-lived parse cache** (the same lever as the `hawk check` win),
  keyed by resolved path and evicted on edit, so the import closure is parsed
  once and reused across keystrokes instead of re-read+re-parsed from disk every
  change: a doc importing std.cli + std.json went **186 → 8.3 ms/edit (~22×)**.
  (2) **Edit coalescing** — the `serve` loop drains a whole buffered burst (a
  non-blocking `MsgBuffer.try_message`), applying each edit but deferring
  diagnostics to a single `flush`, so a backlog collapses to one re-check per
  document (**100 bunched edits ≈ the cost of 1**). Next lever is caching the
  resolved/element-model closure (the incremental-engine work); see the LSP item
  under _Front-end / tooling_.

- **In-VM profiler + `hawk check` made ~7.7× faster** (2026-06). A
  deterministic, instruction-budget profiler (`HAWK_PROFILE`, see _Profiling_
  above) drove a pure measure-then-fix pass on `hawk check pkgs/cli` (80s): (1)
  a **cross-file parse cache** — `check <dir>` re-lexed+re-parsed the whole
  import closure once per file, so the `std.core` prelude was parsed 46× — now
  shared across files (80s → 10.8s; 2.1B → 310M instructions; 55.6M → 9.1M
  allocations); (2) **string constant interning** — `const.str` allocated a
  fresh heap string per execution (a 24-arm keyword `match` allocated ~23
  strings/call); interned constants are allocation-free after first use and
  permanent GC roots (9.1M → 6.3M allocations). Net 80s → ~10.4s, byte-identical
  fixpoint (both are runtime/ loader-only). Notable Hawk constraint surfaced: a
  top-level `const` keyword map can't replace the `match` — with no load-time
  init, `const` inlines its initializer, rebuilding the map per call; interning
  was the right lever. (A computed-once **module `let`** would lift this
  constraint — see _Module initializers_ under _Language features not yet
  built_.) _Further check-dedup is part of the LSP incremental engine (above)._

- **Unified checker/codegen inference context + a differential oracle**
  (2026-06). Inference is one pure `infer_expr` query, but the checker and
  codegen built its `InferCtx` independently, and the fields that differed were
  the root of a bug class where the two stages inferred the same expression to
  different types (the `for_element_type` miscompile that trapped at runtime;
  the lambda-bounds spurious rejection). A **differential oracle**
  (`HAWK_INFER_ORACLE`, in codegen) maps the divergence: it found 28/855
  front-end units diverged, every one a method on a generic type, every
  divergence the identical pattern — codegen dropped the receiver's type
  arguments (`self_type` `List` vs `List<T>`) and omitted the owner type
  parameters. **Fix:** codegen now builds the receiver type with its parameters
  applied (from the type definition) and adds those to the in-scope set,
  matching the checker; the chosen `self_type` is recorded so the oracle
  _observes_ (not models) what codegen built. The oracle now reports **0** and
  is a permanent assert-zero guard in `bin/test.sh`. Byte-identical fixpoint
  (the correction is principled but the front-end's own lowerings were already
  `Unknown`-tolerant). _Remaining: extend the lambda-unit context snapshot to
  `self_type`/`type_params` (only bounds today) and bring the 34 lambda units
  into the oracle; a per-expression oracle; and a targeted "unexpected-Unknown"
  audit for inference incompleteness (distinct from this divergence pass — a
  blanket Unknown-reject is ~330 false positives)._ **Note (lambda extension,
  attempted + reverted):** giving lifted lambdas the full inherited
  `self_type`/`type_params` (not just bounds) is correct on small inputs but
  made `hawk check pkgs/cli` hang — a compile-time blowup (98% CPU, no output)
  that the per-file closure recompilation in `check` exposes but a single `emit`
  and the minimal repro do not (lambdas already resolve `self`/`T` via captures,
  so the richer context is redundant _and_ expensive). Redo it perf-aware:
  profile the blowup first (likely repeated work over the inherited generic
  context across many nested lambdas), or narrow what lambdas inherit.

- **`Ord` interface + `std.sort`** (2026-06). Total ordering, modeled on
  `Eq`/`Display`: `interface Ord { fn compare(self, other: Self) -> Ordering }`
  with `enum Ordering { Less, Equal, Greater }` (a third runtime-blessed enum
  alongside `Option`/`Result`, reserved type-id `TY_ORDERING`). The primitives
  carry explicit `impl Ord` (Int/Double/Bool in Hawk via `<`; String a native);
  a generic `<T: Ord>` calling `.compare()` dispatches dynamically, backed by a
  `compare` arm in the runtime `virtual_fallback` that orders the four
  primitives and returns an `Ordering` — the same explicit-impl-for-static /
  fallback-for-virtual split as `Display`. `std.sort` (qualified module) ships
  `sorted`/`sorted_desc`/`min`/`max` over `<T: Ord>` (free functions, since a
  `List<T>` _method_ can't add a `T: Ord` bound). Comparison operators
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
  explicitly via **receiver type args** (`CallExpr.recv_type_args`; the parser
  accepts `Ident<...>.method(...)`; a shared `static_call_bindings` seeds the
  owner params for both inference and the checker) — `gen-static-context` /
  `gen-static-recv-args`. **Generic struct/enum bounds enforced:** a bound on a
  type's own parameter (`type Box<T: Display>`) is stored on `TypeDefElement`
  and checked where a concrete argument is supplied (annotation, struct
  construction) via `check_type_arg_bounds` — `generic-type-bounds`. **Inference
  cleanup:** the static-receiver classification (`(ns.)?Type.method` / `ns.fn`)
  is unified in `resolve_static_receiver` (shared by the three call cascades),
  the instance arm routes through `resolve_method`, and the four return-type
  instantiation paths collapsed onto `call_bindings` / `instantiate_return_ctx`
  (namespace arm now context-aware; `instantiate_return` deleted). All
  byte-identical fixpoint except the added checks. Generics are **invariant by
  design**. _Open follow-ons above (Generics — residual)._

- **Resolution: `FileScope` + owner-correct value resolution (Phase 2)**
  (2026-06). Resolution moved off the flat global name tables onto a single
  **`FileScope`** per file (checker, inference, codegen all consult it).
  Surfaces gained `name -> defining-file` origin maps and `build_library`
  per-file element tables, so **value (function / const) resolution is
  owner-correct** — bare to its own file, qualified within the named library —
  and the flat `functions`/`consts` tables were deleted. This **lifts global
  value-name uniqueness** (two libraries may share a top-level value name;
  `mod-shared-value-name`). Landed as eight behavior-preserving steps with the
  byte-identical fixpoint as the oracle, ending in one small `check_duplicates`
  relaxation. Surfaced + fixed a latent **duplicate-file-loading** bug (the
  loader compiled every shared library 3–4× under different `../` path
  spellings); path canonicalization cut the self-compile ~11.5 s → ~4.3 s and
  the bootstrap 282 KB → 124 KB. _Open: type-name owner-correctness (above)._

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
