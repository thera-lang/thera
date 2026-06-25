# Hawk roadmap

**What this is:** where Hawk is today and what's next. Design details for
_completed_ work live in [architecture.md](architecture.md) and
[language.md](language.md); this doc focuses on what's open.

## Current state

**Checkpoint (2026-06).** Hawk **self-hosts**. The front-end (`pkgs/cli/`, written
in Hawk) lexes, parses, resolves, type-checks, infers, and lowers Hawk to
`.hawkbc`, and runs the `check`/`emit`/`run`/`test`/`lsp` CLI (see
[architecture.md](architecture.md) for the commands and their output streams). It
compiles its own sources and the whole stdlib; `bin/build_sdk.sh` embeds it into
the `hawk` binary with a **fixpoint check** that the front-end reproduces itself
byte-for-byte. The Dart toolchain that bootstrapped it has been removed — the
build bootstraps from a checked-in `bootstrap/frontend.hawkbc` snapshot (see
`bootstrap/README.md`), and `bin/test.sh` (cargo + the `pkgs/cli`/`sdk/std`
`@test` suites + examples) is the suite.

**Runtime (`runtime/`, Rust).** A Tier-0 bytecode interpreter with an explicit
call-frame stack (`Vm::run_loop` over `Vec<Frame>`, each frame a `{func, pc, base}`
into one **unified value stack** per fiber — locals + operands laid end to end, so
a call passes its arguments in place with no per-call allocation) and a **precise
non-moving mark-sweep GC** (`heap.rs`). It runs the full language core: `Int`/`Double`/
`Bool`/`Unit`, control flow, functions + recursion, **closures**, enums
(`Result`/`Option` as ordinary `std.core` enums, with `?`/`match`/implicit-`Ok`),
structs + a type table, `List`/`Map`/`Set`, and **interface dispatch** — static on
concrete types, dynamic (`call.virtual` + a type-id-keyed table) for
interface-typed values and bounded generics, with bounds enforced at call sites.
Natives are bound by name at load (the native ABI). Bytecode serializes to
`.hawkbc` (header + sections, LEB128, string constant pool). A first cut of
**cooperative fibers** (`std.fiber`) is in: `spawn`/`join`/`yield` + buffered
channels.

**Inference.** The front-end carries a semantic `Type`/element model
(`pkgs/cli/element/`) built by a resolution stage; inference is a **pure,
on-demand** query (`infer_expr` — no AST annotation) the checker and codegen call.
It sees through generics (`Option<T>`/`List<T>` elements, method returns, match
bindings, `?`/`unwrap`), does bidirectional and forward-flow inference, and the
checker reports located diagnostics (type mismatches, bad calls/fields/methods,
unpinnable generics). The inference-completeness arc is essentially closed — see
[Inference](#inference--essentially-complete) below.

**Not yet:** a broader stdlib; generic operators (`<T: Add>`); bitwise operators
(`& | ^ << >>`); index (`[]`) operator overloading; the Cranelift JIT tier.
(Qualified-only resolution + `pub`/privacy are now **enforced**, with a residual
type-position / per-library-ownership tail — see *Resolution correctness* below.)

## Open work

### Runtime (Rust)

- **Stdlib breadth.** `String.*`/`List.*`/`Map.*`/`Option.*` (native + Hawk), and
  `std.cli`/`std.fs`/`std.process`/`std.random`/`std.time`/`std.json`/`std.io`
  exist; `List.map`/`filter`/`fold` are written in Hawk over closures. Remaining:
  `first`/`last`/`slice`/`sort`, more `String`/`Map`, and the rest of the
  "batteries included" goal.
- **Fibers — phases 3–4.** Phases 0–2 are done (scheduler-drivable `run_loop`;
  `spawn`/`join`/`yield` with GC roots across every fiber; buffered `Channel<T>`).
  Design in [architecture.md](architecture.md) §Concurrency. Next:
  - **Phase 3 — park on real I/O.** `time.sleep` (a scheduler timer), then offload
    blocking syscalls (`fs`/`stdin`/`process`) to a worker-thread pool that wakes
    the fiber — keeping the single Hawk thread; unblocks `std.http`.
  - **Phase 4 — readiness poller** (`kqueue`/`epoll`) for sockets, to scale to
    many connections (`mio` vs. hand-rolled — the first real runtime dependency).
  - **Refinements:** per-channel waiter lists, true 0-capacity rendezvous
    channels, `select`, and exit semantics for surviving spawned fibers.
- **Interpreter performance — profiled (2026-06); the easy wins are in.** Probes:
  the front-end **self-compile** (`hawk emit pkgs/cli/main.hawk`) ≈ 11.6 s release,
  and **mandelbrot** ≈ 0.81 s (a call-free arithmetic/loop guard). Measured with
  the built-in `native-stats` feature (per-native call counts) + macOS `sample`
  (time). Findings:
  - **The cost is the heap-access path, not dispatch.** `HEAP.with` (a thread-local
    `RefCell`) is ~62 % of `run_loop` inclusive / ~15 % pure self-time, and
    allocation (`Vec::from_iter` + `memmove`, ~27 %: per-object field-`Vec`
    construction, string/list building) is the other big chunk. Native *dispatch*
    is cheap — the volume leaders (`eq` 9.2 M, `list_len` 8.4 M calls) cost mostly
    the `HEAP.with` round-trip *around* the call, not the call itself.
  - **Map/Set is not a self-compile hotspot** (≈0 time samples; `Set` isn't used
    hot). Hashed Map/Set (below) is a **scaling-robustness** item for large *user*
    programs, not a front-end speedup — re-scoped from "perf" to "scaling".
  - **Done:** the **unified value stack** (one `Vec` per fiber, args passed in
    place — ~8.6 %, the real win, and the JIT shares that stack); the **`ListLen`
    opcode** (lowers `list.len()` out of `call.native` — time-neutral, but shrinks
    bytecode and is JIT-aligned like `ListGet`/`ListSet`).
  - **Measured and declined:** converting the heap `RefCell`→`UnsafeCell` bought
    only ~1 % (the borrow flag isn't the cost; the thread-local TLV lookup +
    allocation are) and would trade the runtime's loud-panic safety net for silent
    UB if a future `with_*_mut` closure read another heap object. Not worth it
    standalone.
  - **What's left is structural:** cut per-object allocation (an arena / inline
    small-field object representation) and the thread-local heap-access path. The
    latter is best done in the **JIT era** (a raw heap base pointer shared by
    interpreted and compiled frames, no `thread_local`, no per-access indirection)
    — where it is load-bearing and rides along with the untagged-value move. See
    the Cranelift bullet below.
- **Map/Set scaling — hashed, insertion-ordered.** *(Scaling, not a self-compile
  hotspot — see above.)* `Obj::Map` is a `Vec<(Value, Value)>` with a linear
  `map_find` and clone-on-mutate, so building an N-entry map (the codegen symbol
  tables) is O(n²). Fix: an insertion-ordered hashed map (a Vec for order + a
  hash→index table) used **above a size threshold** so small maps stay linear.
  Constraints: content-based key hashing consistent with `values_eq`; preserved
  insertion order (the fixpoint checks byte-identity); precomputed per-key hashes
  so a lookup needn't re-enter the heap under the map's borrow. Same treatment for
  `Set`. Matters when a *user* program builds large maps; the front-end's own maps
  are small enough that O(n) doesn't bite.
- **Read accessors that clone whole heap objects** are a recurring hot spot (fixed
  for `list.len`/indexing, GC marking, map reads; `list.len()` is now the `ListLen`
  opcode entirely). Prefer the borrowing accessor; clone only when a closure
  re-enters the heap to allocate/compare.
- **Cranelift JIT tier** (+ the untagged value representation and `f64`/large-int
  constant-pool entries it forces) — performance/compaction, not
  correctness-blocking. See runtime staging below and [architecture.md](architecture.md).
  This is also where the **heap-access rework** belongs (the interpreter profiling
  above pointed at `HEAP.with` as the dominant cost): the JIT needs a JIT-callable
  heap-access path anyway — a raw heap base pointer rather than a thread-local
  `RefCell`, with the borrow discipline enforced by construction — so the
  non-moving slab grows that path *for* the JIT, and the interpreter inherits it.
  A standalone interpreter-only version was measured (~1 %) and declined as not
  worth the unsafety; here it is load-bearing. Strategic note from that review:
  a first JIT can keep the **tagged** 16-byte `Value` (Cranelift handles it as an
  aggregate; precise GC stays trivial because the tag survives) and defer the
  untagged + stackmap work to a second pass — decoupling "JIT works" from "JIT is
  fast", which de-risks bring-up.
- **Profiling Hawk code — planned, staged.** OS-level samplers (`perf`,
  Instruments, samply) are nearly blind to an interpreter: every Hawk function is
  the same `run_loop` native frame, and the Hawk call stack lives in the VM's
  `Vec<Frame>`. So the runtime grows its own profiler — as CPython
  (cProfile/py-spy), Ruby (stackprof/rbspy), and Lua do. The primary audience is
  **coding agents**, which shifts the design toward _deterministic,
  function-level, flat text_ over flame-graph SVGs and line-level precision.
  1. **`hawk run --profile` — in-VM, no `.hawkbc` change.** Exact per-function
     **call counts** + per-call-site **allocation counts**, plus a self-time
     distribution from **instruction-budget sampling** (snapshot the frame stack
     every K bytecode instructions at the **GC safepoint already at the top of
     `run_loop`**) — deterministic and cross-platform, so runs are _reproducible_,
     what an agent's before/after comparison needs. A frame already knows its
     function, so v1 needs nothing new in the bytecode; output is a flat table
     sorted by cost. The sampler ships in v1 too (counts alone miss "few calls,
     each slow").
  2. **Line attribution — enhancement.** A bytecode→source-line table in `.hawkbc`
     (debug info) so a sample/counter resolves to a Hawk line. Demoted from a v1
     prerequisite once we accepted function-level is enough for _algorithmic_
     issues. The same debug info gives traps a source location and backs the
     test-failure / stack-trace needs.
  3. **OS-profiler integration — JIT tier.** Once Cranelift lands, JITed Hawk
     functions are real native frames; emit `perf`'s `/tmp/perf-<pid>.map` or
     `jitdump` (the V8/JVM/.NET trick) so `perf`/samply/Instruments resolve them.
     The deep-dive view; #1 stays the portable always-on view. #1 and #3 are
     complementary, not a choice.

  (Profiling the _runtime itself_ — the Rust interpreter/natives — is separate and
  already covered by `cargo` + samply/Instruments and the `[profile.profiling]` /
  `native-stats` setup.)

### Inference — essentially complete

The completeness arc landed: an un-inferable type is a **clear, located check-time
error**, never a silent `Unknown` that misfires downstream. Done (in
`pkgs/cli/element/inference.hawk` + the checker):

- **Lambda parameters** — type from an annotation or surrounding context, else a
  "cannot infer the type of lambda parameter 'x'; add a type annotation" error
  (the template the rest follow).
- **Block-body lambda return** — unifies the body's `return`s.
- **Forward-flow** for `Option.None` / empty-literal locals — `let xs = []` /
  `let mut x = Option.None` take their element type from the first **pinning use**
  (a `push`, an indexed assignment, a reassignment), descending into
  `if`/`while`/`for` bodies. First use wins; a binding nothing pins stays a lenient
  `Unknown` (the corpus showed requiring an annotation here over-fires).
- **Call-argument checking** for every call form — free functions, methods (with
  receiver-generic substitution), namespace functions, static methods (arity,
  labels, types), lenient on `Unknown`/`TypeParameter`.
- **Generic inference from context** — type parameters bind from explicit type
  args, the arguments, **and the expected type** (a binding annotation, the
  enclosing return type, a surrounding argument, or an **assignment target**).
  A return-only parameter left unbound is the "cannot infer type argument" error;
  enum construction recovers the un-built variant's parameter (`Result.Ok(x)` under
  an expected `Result<T, Error>` infers `E = Error`).
- **Match-arm unification** — value-producing arms must agree (Unit/`Unknown`
  arms exempt), catching a wrong _later_ arm the old first-arm-wins missed.

A spike settled the **`Unknown`-as-a-diagnosed-hole** question: a broad "reject
`Unknown`" flip is **not viable**. Of the residual partial-`Unknown`s across the
whole corpus, ~330 are `Result.Ok(x)` → `Result<T, Unknown>` (constructing one
variant of a two-parameter enum can't determine the other), so leniency on
`Unknown` is **load-bearing** — it's what lets `return Result.Ok(0)` typecheck in
a `-> Result<Int, Error>` fn without annotating the error type. Targeted,
origin-located diagnostics are the right model; the practical hole problem is
closed.

**Residual:** field access on a non-struct concrete value (`5.x`) still slips past
`check` to codegen.

### Front-end / tooling

- **Resolution correctness — mostly done; a residual tech-debt tail.** The scoping
  rules ([scoping.md](scoping.md)) are now **enforced** for the common cases:
  qualified-only and `pub` visibility (via `qualify_lint`/`visibility_lint`,
  corpus-guarded at 0 violations); **per-file namespaces** (a file can only qualify
  with what it imports); **bare *value* resolution** restricted to
  same-file + prelude + `as _` + built-ins, with **no global last-wins fallback**
  (a value owned by an un-imported library is `undefined`); and the **white-box
  test exception** (`foo_test.hawk` sees `foo.hawk`'s privates bare). Pinned by
  `mod-ns-file-local`, `mod-no-bare-fallback`, `vis-whitebox-test`, plus the
  existing `mod-qualified-only`/`vis-pub`. The closure-wide `modules` alias set was
  removed; the duplicate-top-level-name diagnostic still guards same-name
  collisions. **Residual tech debt** (architectural purity; the corpus is clean, so
  these are not user-visible bugs today — see [scoping.md](scoping.md) →
  *Implementation gaps* 1/2/5):
  - **the per-file gate for bare *type* positions** — `check_type_ref` still
    consults the flat `type_defs`, so the type analogue of the bare-name hole
    remains; needs `current_file` threaded through type checking (incl. top-level
    declaration sites that have no `InferCtx`);
  - **surface-checked, within-library qualified resolution** (`ns.name` resolving
    *within* `ns`'s library rather than via the global table);
  - **physical per-library ownership** of the still-flat
    `functions`/`type_defs`/`consts` tables (so same-name cross-file definitions are
    correct by construction, not by the duplicate diagnostic);
  - once the above land, **`qualify_lint`/`visibility_lint` retire** (their
    enforcement + the "qualify as `ns.name`" message move into the resolver).

  Related, still open: `impl` coherence / orphan rules, selective import
  (`show`/`hide`), and a "module"→"library" terminology sweep.
- **Whole-closure diagnostics with per-file origin — correctness bug.** A
  diagnostic today carries only a message + span, **no owning file** (`Diagnostic`
  in `driver.hawk`, `CheckError` in `checker.hawk`); the CLI prints each against
  whatever single path it was handed — the entrypoint. Two consequences, both
  verified against an `app.hawk` that imports `helper.hawk`:
  - **Import errors vanish.** The checker body-checks only the *primary* program
    (`check_program` iterates `program.decls`); imports supply signatures only. So a
    check error inside an imported body (`helper.hawk`'s `name.frobnicate()`) is
    never produced when checking `app.hawk` — `check helper.hawk` reports it,
    `check app.hawk` reports nothing. A *parse* error in an import is dropped by the
    loader and surfaces only as a misleading downstream `undefined name: helper` in
    the importer — printed with **exit 0** (a printed error under a success code, a
    bug in itself). (This was the root of the "trailing-`;` corrupts a module"
    symptom; the parser half — `parse_block` rejecting a stray `;` after a
    block-form statement — is fixed.)
  - **Misattribution is latent, not yet observable.** Because import diagnostics
    never reach the reporter, nothing is *mis*-attributed today — but the moment
    they are surfaced they'd each print with the entrypoint's path, since a
    diagnostic has no origin of its own. Per-file origin is therefore the
    prerequisite, not a separate fix (these two were previously tracked as two
    items).

  Target — the standard error-tolerant analyzer model:
  - The engine computes diagnostics for the **whole import closure**, each carrying
    its **owning file** (origin) + span. The loader recovers-and-parses every file,
    collecting that file's diagnostics under its path and marking failed imports.
  - The **request** scopes which files' diagnostics are *displayed* (a single file
    vs. a directory/project — the typical case); computation stays closure-wide
    regardless, so an importer can react to a failed dependency.
  - **Recover and resolve:** a partially-parsed `b` still offers whatever decls it
    recovered; an importer `a` errors only on symbols genuinely missing.
  - **Cascade suppression / cause-naming:** the resolver distinguishes "undefined"
    from "unavailable because its source file errored" — suppressing the downstream
    cascade and naming the cause: `helper.greet is unavailable: helper.hawk failed
    to parse` rather than a bare `undefined name: helper`, so the reader is pointed
    straight at the file to fix.
  - **Format for the LLM lens:** `path:line:col: severity: message`, one per line,
    grouped by file, deterministically ordered (file → line → col) so an agent's
    before/after diffs are stable; exit non-zero iff a displayed diagnostic is an
    error. (A machine-readable JSON mode can follow — see the `hawk test` output
    modes.)
- ~~**`native type` declarations for the built-in types — uniformity / discovery.**~~
  _Done (2026-06)._ `Int`/`Double`/`Bool`/`String`/`List`/`Map`/`Bytes`/`BytesBuilder`
  now have a bodyless **`native type`** declaration in `sdk/std/core/` (a new
  `bool.hawk` for `Bool`), so each built-in has a definition site, a doc home, and
  its type parameters written down — like `Set`/`Option`/`Result`. Reuses the
  `native` keyword (symmetric with `native fn`); no `@extern` (its identity is its
  name). It resolves as a `Builtin` type def — opaque, an attachment point for
  `impl` blocks, **no field layout** (no struct literal) — and emits no code / no
  runtime type-table entry, so it shadows the hardcoded `builtin_type_defs()` floor
  with zero behaviour change (the SDK fixpoint stayed byte-identical). Spec test
  `type-native`. Open follow-ups: whether to *gate* `native fn`/`native type` to SDK
  paths (with the `@extern` name-check item), and the checker leniency that lets a
  bare field access on an opaque value slip to codegen (the existing
  `type-field-nonstruct` residual).
- **Static-method type arguments — expressiveness gap.** No expression-level syntax
  constructs a generic type whose parameter isn't otherwise inferable:
  `Set<String>.new()` doesn't parse, and `Set.new<String>()` binds `<String>` to
  `new`'s own (empty) parameters, not the owner `Set<T>`'s `T`. The only working
  form is a type-annotated binding (`let s: Set<String> = Set.new()`). Consider
  supporting `Set<String>.new()` (type args on the **receiver type** of a static
  call). Until then the "cannot infer type argument" diagnostic shouldn't suggest
  the non-working `new<...>()` for a static method. A corner now that
  assignment-/argument-context inference covers ordinary cases.
- **Semantic (scope-aware) references & rename.** `textDocument/references` and
  `textDocument/rename` are implemented but **lexical only** — they match every
  identifier token with the same text, across files, with no binding/scope
  analysis, so they'd report (or rewrite) unrelated same-named symbols. They are
  therefore **not registered** by the server (`pkgs/cli/lsp/references.hawk`,
  `rename.hawk` are parked with TODOs). Making them precise needs name resolution
  at a cursor — resolve the identifier to its *declaration* via the element model,
  then collect only the references that bind to it (and, for rename, verify the new
  name doesn't collide). This rides on the same inference-at-offset work as below.
- **LSP v2 toward an incremental engine.** Inference-at-offset (hover/definition on
  locals, expressions, members), overlay-aware imports (honor unsaved edits), and
  memoizing the import-closure load. The front-end is whole-program and stateless
  per request: each `hawk check` / LSP edit re-reads, re-parses, and re-checks the
  entire import closure (incl. the `std.core` prelude) from scratch — fine now, but
  the LSP re-does it per keystroke. Longer term: cache parsed/resolved libraries,
  invalidate by file, reuse the element model across requests, re-check only what
  changed. (Transport has an end-to-end smoke test in `bin/test.sh`, added after a
  line-buffered-stdout bug let only each message's header reach the client — which
  the in-process `StringWriter` `@test`s couldn't catch.)
- **`hawk test` polish** (the runner is implemented; **per-test stdout capture**
  is done — each test's output is buffered via the `test_capture_*` runtime natives
  and shown only on failure, or always with `--show-output`). Per-test **source
  locations** on failure (it reports the test name, not the failing assertion's
  line) — likely
  via **caller-location metaconstants**: `__FILE__` / `__LINE__` as _default
  parameter values the compiler fills in at the call site_, à la C#'s
  `[CallerLineNumber]` / Rust's `#[track_caller]` (`fn assert_eq<T>(…, file: String
  = __FILE__, line: Int = __LINE__)`), which needs no `.hawkbc` debug info; the
  heavier alternative is the bytecode→line table (which also serves trap locations
  / a future stack trace — see Profiling). Also: a richer structural `debug`
  (struct field / enum variant names) and a machine-readable output mode.
- **`@extern` name check.** Native names are written once as `@extern('…')` on the
  `native fn` decls in `sdk/std`; the Rust runtime table is the other half, bound
  by name at load. Add a test asserting every `@extern` name the front-end can emit
  is accepted by the runtime, and split the runtime table into per-module files
  (`natives_fs.rs`, `natives_string.rs`, …) as it grows.
- ~~**Unify call/member resolution — codegen re-derives what inference computes.**~~
  _Done (2026-06)._ Codegen no longer carries its own callee resolver: `method_call`
  dispatches on the element model's `infer_callee_kind` — the **single source** of
  which kind of callee a `recv.field(...)` site is — and only chooses the backend
  lowering per kind (a native symbol, a unit index, or a virtual selector). A
  corpus-wide cross-check first proved codegen's old `ModuleScope` cascade and the
  element-model classification agreed everywhere; the codegen cascade was then
  deleted, byte-identity held by the fixpoint. (Inference's type-producing
  `infer_call_field` is deliberately left separate — its cases are coarser than
  codegen's emission distinctions, so routing it through the same classifier would
  fragment a clean uniform branch.) (Surfaced by the pkgs/ code review.)
- **codegen unit-test coverage — in progress.** codegen + module_scope (~2.9k
  lines) were covered mainly end-to-end (fixpoint + examples + every suite running
  through them), so a regression surfaced as a fixpoint/example break, not a
  located unit failure. **Instruction-level tests now exist** for the trickier
  lowerings — the call-resolution branches (enum ctor / enum `name()` / user
  static+instance / native instance+static / free native / field call / virtual
  dispatch), match-dispatch bisection-vs-linear, and closure mut-capture boxing —
  decoding the emitted `Module` and asserting which opcode each lowers to (so a
  regression is a readable, located failure). Remaining: direct coverage of
  `module_scope` internals (name mangling, same-file-first resolution edge cases,
  dispatch-table building) still leans on the implicit end-to-end suites.
- **Parser error recovery for the LSP.** The LSP's normal input is _syntactically
  broken_ code mid-edit; the parser should synthesize a best-effort tree (recover
  past the error) so semantic resolution still runs and offers completions/hover.
  Today recovery is coarse (`sync_to_decl`). A future spike: structured recovery +
  error nodes the resolver tolerates. (Keep in mind when touching the parser — the
  recent precedence-table refactor preserved the `panicking`/recovery structure.)
  - **Dependent feature: `textDocument/completion`.** Autocomplete requires navigating
    a mid-keystroke AST (e.g., `obj.`). Deferring until the parser can reliably build
    an AST that doesn't drop the trailing, incomplete member access.
  - **Dependent feature: `textDocument/signatureHelp`.** Surfaces parameter names
    while inside a function call. Relies on the parser correctly framing an
    unterminated call `foo(`, which current coarse recovery struggles with.

### Language features not yet built

- **Struct-definition keyword: `type Foo = { … }` → `struct Foo { … }` (likely).**
  Hawk is a **nominal** type system — two identically-shaped structs are distinct
  (`Celsius` ≠ `Fahrenheit`), identity is by name, and interface conformance is an
  explicit `impl I for T` (like Rust traits, not Go's structural interfaces). But
  the struct *syntax* `type Foo = { … }` is the form that connotes **structural**
  typing — it's TypeScript / Flow / Elm `type alias` / PureScript, all structural —
  so it points an LLM at the wrong prior (the strongest read of `type X = {…}` is
  "TypeScript → same shape interchanges", which Hawk rejects). A keyword + name +
  braces with **no `=`** is the near-universal *nominal* record signal (Rust/Swift/
  C#/Haskell/Go's `type … struct`). Switch structs to that form:
  `struct Celsius { degrees: Int }`. Two wins: it stops mis-signalling the
  discipline, and it makes structs rhyme with Hawk's other nominal declarations,
  which already use keyword + name + `{}` with no `=` (`enum Name { … }`,
  `interface Name { … }`) — structs are the lone outlier today. Keyword not fully
  settled — **`struct`** is most likely (most universal, fits the Rust-adjacent
  brace family); `record` is the runner-up (leans into immutability-by-default but a
  weaker/mixed nominal signal). Only structs change; `enum`/`interface` stay as-is.
  Bonus: frees `type X = Y` for *real* (transparent) aliases later, à la Elm's
  `type` vs `type alias` split — Hawk has no aliases today, so `type` is currently
  only the struct form and there's nothing to untangle. Scope: mechanical but broad
  — parser, every `type … = { … }` across `sdk/std` + `pkgs/cli` + examples +
  corpus, the docs, and the keyword drift-guard; a two-cycle bootstrap ratchet (the
  old snapshot must still parse the new keyword before the sources use it, as with
  `native type`). No semantic/codegen change — purely surface.
- **Disambiguate the empty `{}` in a `match` arm (map-literal vs block).** In
  expression position `{}` is an empty **map** (`return {}`, `let m = {}`, a call
  argument, an `if`-branch tail `{ {} }` all work). The sharp edge is a **`match`
  arm**: `pat => ( exprBlock | expr )` tries `exprBlock` first, so a bare
  `pat => {}` is an empty **block** (value `Void`), not an empty map. This is
  nasty when mixed with a non-`Void` arm: match-arm unification exempts `Void`
  arms, so `match x { Some(m) => m, None => {} }` type-checks as `Map` yet the
  `None` path returns `Void` and only **traps at runtime** (`map.keys: expected
  map`). Today's workarounds: spell it `=> { {} }` (a block whose tail is the map)
  or bind it first (`let none: Map<…> = {}; … none`) — both indirect and easy to
  forget. Want an empty map that is **unambiguous on its own**: a distinct
  empty-map token (e.g. `[:]` as in Swift/Dart, or `{:}`), `Map.new()`, or having
  the arm parser treat a bare `=> {}` as a map when the arm's expected type is a
  map. Pick by the **LLM lens**: one obvious way to write an empty map, no silent
  `Void`. (A non-empty `{ … }` is never ambiguous.)

- **Syntax-elegance pass — through the LLM lens.** Several common shapes are more
  verbose than they need to be; the dominant one is the resolution cascade
  `match X { Some(v) => { …; return …; }, None => {} }` (55× in codegen, 38× in
  inference, 28× in checker) — "look up, act-and-return, else fall through." Sugar
  could collapse it: an `if let Some(v) = X { … }`, `?` working on `Option` in a
  fallthrough/`-> Void` position, or a `guard`-style early return. Evaluate options
  by what's best for **LLMs** — terseness, expressiveness, and _one_ obvious way to
  do a thing (the same lens as the ternary-for-`if` question). A general pass, not
  a single feature. (Surfaced by the pkgs/ code review.)

- **Generic operators** (`<T: Add>`, operators-as-traits) — the remaining piece of
  the generics arc (bound enforcement + `call.virtual` dispatch on `T` are done).
  This is also where the language's **implicit operator/literal lowerings** would
  gain a Hawk-level surface: `==`, `+`/interpolation, `[]`/`[]=`, and the `{}` map
  literal are emitted by codegen straight to runtime natives (`eq`, `str_concat`,
  `stringify`, `list_index`/`list_set`/`map_index`, `map_new`/`map_set`) with no
  named Hawk method behind them — the one category of addressable behaviour not
  represented in `sdk/std`. Operators-as-interfaces (`Eq`, `Add`, and `Indexable`
  below) is what turns those into ordinary Hawk methods; revisit the exact shape
  then (the `[]` half is the *Index operator* item).
- **`Display` for the collection/wrapper built-ins + bounded impls.** `List`, `Map`,
  `Set`, `Option`, `Result` don't implement `Display`, so interpolating one
  (`'${xs}'`) is a `check` error — yet these are exactly the values you most want to
  drop into a string. They *can* be rendered with an explicit `impl Display`, and a
  plain `impl Display for List<T>` already works end-to-end today (verified:
  `'${[1,2,3]}'` → `[1, 2, 3]`), because the checker is lenient on the unconstrained
  element type and the runtime dispatches `display` per element. So the ergonomic
  fix is just to *ship* these five impls in `sdk/std/core` (rendering `[a, b, c]` /
  `{k: v}` / `{a, b}` / `Some(x)`·`None` / `Ok(x)`·`Err(e)`). This stays consistent
  with the "Display is explicit, no default" rule — they're explicit stdlib impls,
  not an auto-default; a user `struct` still writes its own.
  - **Prerequisite — bounded / conditional impls.** `impl<T: Display> Display for
    List<T>` doesn't parse today (no bound on an impl's own type parameter). Without
    it, an *unconstrained* `impl Display for List<T>` claims `List<anything>` is
    `Display`, so interpolating a `List<Point>` (no `Display` on `Point`) compiles
    and **traps at runtime** instead of erroring at `check`. The `where T: Display`
    bound turns that back into a compile error. This is a general generics feature
    (bounded impls), adjacent to *Generic operators* above; ship the unconstrained
    impls now for the ergonomic win, tighten them when bounded impls land.
  - ~~**Related uniformity — make primitive `Display` explicit.**~~ _Done (2026-06,
    Options A + B)._ `Int`/`Double`/`Bool`/`String` carry real `impl Display`s, each
    bound to a per-type native (`int_to_string`/`double_to_string`/`bool_to_string`/
    `str_identity`) — the catch-all `stringify` native is gone. Both front-end
    hardcodes were removed (Option A): codegen renders via a uniform `emit_display`
    cascade (native-instance-method / virtual / concrete-impl; `String` elided as
    "already a `String`"), and the checker's `satisfies_bound` routes primitive
    `Display` through declared conformance (seeded into `builtin_type_defs` as a
    hermetic floor), keeping only `Eq`/`Debug` intrinsic. Then (Option B)
    interpolation and all four console writers (`println`/`print`/`eprintln`/
    `eprint`) were unified onto `emit_as_string`, so the print natives became plain
    string writers (`str_contents`, no rendering). The front-end doesn't print raw
    primitives, so the SDK fixpoint held byte-for-byte — no ratchet. **Still
    hardcoded:** `display_string` remains the single built-in renderer behind the
    per-type natives, `list.join`, and the virtual-`display` fallback — fully
    retiring it needs *primitive vtables* (its own roadmap item); and the sibling
    `eq`/`str_concat` operator lowerings retire with operators-as-interfaces.
- **Primitive vtables — scope it (runtime / generics / soundness).** A primitive
  reached through *virtual* dispatch — `call.virtual('display'|'eq'|'debug')` from a
  generic `<T: Display>` / interface-typed context where the runtime value is an
  `Int`/`Double`/`Bool`/`String` — does not resolve to that primitive's method via a
  vtable; it hits a **hardcoded fallback** in the interpreter (`virtual_fallback` in
  `mod.rs`: `display` → `display_string`, `eq` → `==`, `debug` → `debug_value`).
  That fallback is why `display_string` can't be fully retired even after the `Display`
  work above (it also backs `list.join`), and it's a small soundness gap: the dispatch
  is correct only because every primitive interface bound is one of the three built-ins,
  not because the type actually carries the method. The task: **determine the scope** of
  giving primitives real vtable entries (a type-id → selector → impl table for the
  built-in primitive types), so virtual dispatch resolves `Int.display → int_to_string`
  etc. uniformly — letting the `virtual_fallback` hardcodes and the primitive arms of
  `display_string` retire, and removing the "primitives are special in dispatch" axiom.
  Open questions to answer first: how primitives get a stable type-id keyed into the
  vtable (they're unboxed `Value` variants, not heap objects); whether this composes
  with — or should wait for — the bounded/conditional-impl and operators-as-interfaces
  generics work (it's the same "dispatch a built-in interface on a concrete type"
  machinery); and the cost/benefit vs. keeping a single well-documented fallback.
  Surfaced while scoping the `Display` Option B follow-up.
- **Bitwise operators** (`& | ^ << >>`, plus an unsigned type or
  defined-wrapping/logical-shift semantics on the signed `Int`). Blocks writing
  hashing/encoding and a modern PRNG in Hawk: `std.random`'s SplitMix64 mix is a
  Rust native (`random_mix`) precisely because it needs shifts/xor, and
  `std.hash`/`std.encoding` will hit the same wall. Self-contained arc — lexer
  tokens, parser precedence, checker (Int-only), codegen, runtime opcodes (the
  runtime already does wrapping i64 arithmetic) — that lets these libraries move
  from natives into Hawk.
- **Index operator (`[]`) overloading.** `a[i]` / `a[i] = v` are hardcoded in
  codegen to the built-in `List`/`Map` natives by static type; any other receiver
  is a compile error (`pkgs/cli/codegen/codegen.hawk`). Small–medium, self-contained:
  desugar to a method call reusing static/`call.virtual` dispatch (inference
  resolves `a[i]` from the receiver's index method; codegen's two `throw` branches
  become method-call lowerings; List/Map keep their native fast path). Design
  leaning: a single `Indexable<K, V>` interface (one `get`- and one `set`-style
  method) rather than separate `Index`/`IndexSet`. Also a prerequisite for a Hawk
  `Map` (which additionally needs map-literal lowering and a native↔Hawk-map bridge).

## Runtime staging (longer view)

See [architecture.md](architecture.md) for the design behind each tier.

1. ~~Tree-walker POC (settle semantics); define the bytecode IR.~~ _Done._
2. ~~Tier-0 interpreter + precise non-moving mark-sweep GC.~~ _Done_ — runs real
   Hawk apps with fast startup.
3. **Cranelift JIT tier** for hot functions (or trial copy-and-patch); decide the
   JIT GC-root strategy here. This is what forces the tagged→untagged
   value-representation move (interpreted and compiled frames must share a
   representation).
4. **AOT via `cranelift-object`** later — single-binary distribution; optional, not
   on the startup-critical path.
