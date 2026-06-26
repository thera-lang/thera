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

**Not yet:** a broader stdlib; generic operators (`<T: Add>`); bitwise operators
(`& | ^ << >>`); index (`[]`) operator overloading; the Cranelift JIT tier.
(Qualified-only resolution + `pub`/privacy are now **enforced**, with a residual
type-position / per-library-ownership tail — see _Resolution correctness_
below.)

## Open work

### Runtime (Rust)

- **Stdlib breadth.** `String.*`/`List.*`/`Map.*`/`Option.*` (native + Hawk),
  and
  `std.cli`/`std.fs`/`std.process`/`std.random`/`std.time`/`std.json`/`std.io`
  exist; `List.map`/`filter`/`fold` are written in Hawk over closures.
  Remaining: `first`/`last`/`slice`/`sort`, more `String`/`Map`, and the rest of
  the "batteries included" goal.
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
  1. **`hawk run --profile` — in-VM, no `.hawkbc` change.** Exact per-function
     **call counts** + per-call-site **allocation counts**, plus a self-time
     distribution from **instruction-budget sampling** (snapshot the frame stack
     every K bytecode instructions at the **GC safepoint already at the top of
     `run_loop`**) — deterministic and cross-platform, so runs are
     _reproducible_, what an agent's before/after comparison needs. A frame
     already knows its function, so v1 needs nothing new in the bytecode; output
     is a flat table sorted by cost. The sampler ships in v1 too (counts alone
     miss "few calls, each slow").
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

- **Resolution correctness — Phase 1 done; the per-library refactor (Phase 2)
  remains.** Qualified-only + `pub` visibility are now **enforced by construction
  in the resolution gates** (not by transitional lints): the value gate
  (`check_expr`'s `Ident`) and the type gate (`check_type_ref` / the shared
  `check_named_type`, threading `current_file` through the top-level signature
  checkers) reject a bare-but-qualifiable name ("qualify as `ns.name`"), a bare
  name owned by an un-imported library (undefined / unknown type — **no global
  last-wins fallback, for types as well as values now**), and a qualified
  `ns.name` to a non-public member ("not a public member of `ns`"). The two lints
  (`qualify_lint`/`visibility_lint`, ~620 lines) are **deleted**. Pinned by
  `mod-qualified-only` (+ `-type-reject`), `vis-pub` (+ `-type-reject`),
  `mod-no-bare-fallback` (+ type version), `mod-ns-file-local`,
  `vis-whitebox-test`. _(Closing the type gate surfaced a genuine latent issue:
  the type-side qualified-only migration had never been done — `server.hawk` used
  `Reader`/`Writer` without importing `std.io`, etc. — now fixed.)_

  **Phase 2 — the `FileScope` abstraction (replaces the flat tables).** The
  element model still merges the closure into flat `functions`/`type_defs`/`consts`
  maps, which **force global name uniqueness** across the whole import closure (two
  libraries can't share a top-level name — `check_duplicates` is closure-wide).
  That's a real latent limitation, not just impurity. The fix is a single
  **`FileScope`** value per file — built once, returning the owning **element** —
  that replaces the ad-hoc lookups scattered across checker/inference/codegen:
  `resolve_value`/`resolve_type`/`resolve_namespace`, composed per position
  (lexical Map kept as-is → file top-level → bare-imports (prelude + `as _`) →
  built-ins; a namespace binds the imported library's scope viewed publicly, so
  `ns.name` resolves *within that library*). The enabler is owner-correctness in the
  data: namespace/bare surfaces gain a `name -> defining-file` origin map, and
  `build_library` keeps per-file element tables so resolution reaches the owning
  file's declaration. This is correct-by-construction and lifts the uniqueness
  limit. Steps 2a–2d (introduce `FileScope`; migrate checker, inference, codegen)
  are behavior-preserving; 2e deletes the global flat tables, makes
  `check_duplicates` per-file, and adds a conformance test proving two libraries can
  share a top-level name. Full design + sequence in [scoping.md](scoping.md) →
  _Phase 2_. (Subsumes the former gaps 2 and 5 there.)

  Related, still open: `impl` coherence / orphan rules, selective import
  (`show`/`hide`), and a "module"→"library" terminology sweep.

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
- **Static-method type arguments — expressiveness gap.** No expression-level
  syntax constructs a generic type whose parameter isn't otherwise inferable:
  `Set<String>.new()` doesn't parse, and `Set.new<String>()` binds `<String>` to
  `new`'s own (empty) parameters, not the owner `Set<T>`'s `T`. The only working
  form is a type-annotated binding (`let s: Set<String> = Set.new()`). Consider
  supporting `Set<String>.new()` (type args on the **receiver type** of a static
  call). Until then the "cannot infer type argument" diagnostic shouldn't
  suggest the non-working `new<...>()` for a static method. A corner now that
  assignment-/argument-context inference covers ordinary cases.
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
  and offers completions/hover. Today recovery is coarse (`sync_to_decl`). A
  future spike: structured recovery + error nodes the resolver tolerates. (Keep
  in mind when touching the parser — the recent precedence-table refactor
  preserved the `panicking`/recovery structure.)
  - **Dependent feature: `textDocument/completion`.** Autocomplete requires
    navigating a mid-keystroke AST (e.g., `obj.`). Deferring until the parser
    can reliably build an AST that doesn't drop the trailing, incomplete member
    access.
  - **Dependent feature: `textDocument/signatureHelp`.** Surfaces parameter
    names while inside a function call. Relies on the parser correctly framing
    an unterminated call `foo(`, which current coarse recovery struggles with.

### Language features not yet built

- **Struct-definition keyword: `type Foo = { … }` → `struct Foo { … }`
  (likely).** Hawk is a **nominal** type system — two identically-shaped structs
  are distinct (`Celsius` ≠ `Fahrenheit`), identity is by name, and interface
  conformance is an explicit `impl I for T` (like Rust traits, not Go's
  structural interfaces). But the struct _syntax_ `type Foo = { … }` is the form
  that connotes **structural** typing — it's TypeScript / Flow / Elm
  `type alias` / PureScript, all structural — so it points an LLM at the wrong
  prior (the strongest read of `type X = {…}` is "TypeScript → same shape
  interchanges", which Hawk rejects). A keyword + name + braces with **no `=`**
  is the near-universal _nominal_ record signal (Rust/Swift/ C#/Haskell/Go's
  `type … struct`). Switch structs to that form:
  `struct Celsius { degrees: Int }`. Two wins: it stops mis-signalling the
  discipline, and it makes structs rhyme with Hawk's other nominal declarations,
  which already use keyword + name + `{}` with no `=` (`enum Name { … }`,
  `interface Name { … }`) — structs are the lone outlier today. Keyword not
  fully settled — **`struct`** is most likely (most universal, fits the
  Rust-adjacent brace family); `record` is the runner-up (leans into
  immutability-by-default but a weaker/mixed nominal signal). Only structs
  change; `enum`/`interface` stay as-is. Bonus: frees `type X = Y` for _real_
  (transparent) aliases later, à la Elm's `type` vs `type alias` split — Hawk
  has no aliases today, so `type` is currently only the struct form and there's
  nothing to untangle. Scope: mechanical but broad — parser, every
  `type … = { … }` across `sdk/std` + `pkgs/cli` + examples + corpus, the docs,
  and the keyword drift-guard; a two-cycle bootstrap ratchet (the old snapshot
  must still parse the new keyword before the sources use it, as with
  `native type`). No semantic/codegen change — purely surface.
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
- **Bitwise operators** (`& | ^ << >>`, plus an unsigned type or
  defined-wrapping/logical-shift semantics on the signed `Int`). Blocks writing
  hashing/encoding and a modern PRNG in Hawk: `std.random`'s SplitMix64 mix is a
  Rust native (`random_mix`) precisely because it needs shifts/xor, and
  `std.hash`/`std.encoding` will hit the same wall. Self-contained arc — lexer
  tokens, parser precedence, checker (Int-only), codegen, runtime opcodes (the
  runtime already does wrapping i64 arithmetic) — that lets these libraries move
  from natives into Hawk.
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
