# Hawk roadmap

**What this is:** where Hawk is today and what comes next. For the runtime
design behind this plan see [architecture.md](architecture.md).

## Current state

**Checkpoint (2026-06).** Foundations are in place: a defined **`.hawkbc`
bytecode format**, a **bytecode interpreter** (Rust), a **self-hosted Hawk
front-end** (`pkgs/cli/`) that type-checks and compiles Hawk source to bytecode,
and a **growing core stdlib**
(in Hawk + natives). **Closures**, generics-aware **inference**, a largely
implemented **visibility/library** model, and **interface dispatch — static on
concrete types and dynamic (`call.virtual`) for interface-typed values and
bounded generics, with bounds enforced at call sites** (see
[language.md](language.md)) — all work; real CLI programs compile and run end to
end (see `examples/`), and `hawk test` runs the `@test` functions in
`*_test.hawk` files, all on a runtime with a **precise mark-sweep GC**. Not yet
done: a **broader stdlib**; _enforced_ visibility; **generic operators**
(`<T: Add>`); **bitwise operators** (`& | ^ << >>`); and **index (`[]`) operator
overloading**. The north star is a language + implementation + stdlib complete
enough to **write the Hawk front-end in Hawk** (arc 3 below).

**Rust runtime (`runtime/`)** — a Tier-0 bytecode interpreter that runs:

- `Int` / `Double` / `Bool` / `Unit`, wrapping integer arithmetic, comparisons,
  conversions;
- control flow (jumps), functions + recursion (native Rust call stack for now);
- enums with fixed `Result`/`Option` tags, and the `?` and `match` lowerings;
- structs + a type table; `List` / `Map` / `Set` (reference semantics);
- observable output via a name-bound native-function table (`println`,
  `stringify`, collection ops, …).

Plus tooling: an `FnBuilder` assembler (labels, auto-tracked locals), a
disassembler, and a serialized **`.hawkbc`** format (header + sections, LEB128,
a string constant pool, natives referenced by name). The `hawk` binary runs a
`.hawkbc` file directly (`hawk [--entry NAME] <file.hawkbc> [args]`), plus an
`emit-demo` dev helper.

**Self-hosted front-end (`pkgs/cli/`, in Hawk)** — lexer, parser, type-checker,
inference, codegen, LSP, **and a bytecode emitter** (`hawk emit <file>
<out.hawkbc>`). `hawk run` compiles to `.hawkbc` and executes it on the Rust
runtime; `hawk test` runs the `@test` functions in `*_test.hawk` files. (It was
bootstrapped by a Dart toolchain, now removed.) The emitter lowers the whole
language _core_ to `.hawkbc`:
functions and recursion, locals and typed arithmetic, control flow
(`if`/`while`/`for`, short-circuit `&&`/`||`), calls and string interpolation,
`Result`/`Option` as ordinary library enums (`?`, `throw`, implicit `Ok`,
`match`; construction qualified — `Result.Ok`/`Option.None`), structs (type
table, literals, field get/set), methods (instance + static, including
`native fn`s and methods on primitives) with named-argument resolution,
interface (`Eq`/`Display`) dispatch on concrete types, and `List`/`Map`
literals/indexing/iteration. `hawk emit` type-checks before lowering.

The front-end carries a real **type system** (`pkgs/cli/element/`): a
separate resolution stage builds a semantic `Type`/element model over the AST
and a synthesizing inference pass annotates every expression with its resolved
type (seeing _through_ generics — `Option<T>`/`List<T>` elements, method
returns, match bindings, `?`/`unwrap`). Codegen consumes those types directly,
and the checker uses them for type-mismatch diagnostics (return type, `let`
annotations, conditions, call arguments).

## The three bootstrap arcs

The path to a self-hosting `hawk`:

1. **Interpreter runs `.hawkbc`** — _largely here._ Remaining: a fuller
   native/stdlib surface (the entry/args convention and `Result`-return
   unwrapping are in place).
2. ~~**Dart front-end emits `.hawkbc`**~~ — _done (the language core)._ A
   bytecode-emitter backend in the Dart toolchain targets our exact
   format/opcodes/native-ABI. This is the bootstrap compiler that will produce
   the first `frontend.hawkbc`. The lowering rules it implements are the
   reference the Hawk-written front-end re-implements.
3. **Hawk front-end emits `.hawkbc`** — self-hosting; **done.** The Hawk-written
   front-end (`pkgs/cli/`: lexer → parser → resolver → checker → inference →
   codegen → encoder, plus `check`/`emit`/`run`/`test`/`lsp`) compiles its own
   sources and the whole stdlib, and `bin/build_sdk.sh` embeds it into the `hawk`
   binary, with a fixpoint check that the front-end reproduces itself. The Dart
   toolchain that bootstrapped this has been **removed**; the build now
   bootstraps from a checked-in `bootstrap/frontend.hawkbc` snapshot. Remaining
   front-end work is below.

## Strategy: walk toward self-hosting, don't run

A full Hawk-in-Hawk front-end is a large endeavour, and attempting it before the
runtime and stdlib are solid would mean co-evolving three moving parts at once.
So we hold arc 3 until arcs 1–2 are comfortably complete, then approach it
incrementally:

- Grow the **runtime + stdlib** until real CLI programs run end to end.
- Use **stdlib-in-Hawk** as the low-risk forcing function — writing library code
  in Hawk (compiled by the Dart front-end) exercises the emitter on real
  programs long before we attempt the front-end itself.
- Only once that is stable, start porting the front-end's lowering rules into
  Hawk and iterate until it compiles itself.

That played out as planned: a scoped **spike** (a calculator front-end in
`pkgs/calc/`) first ranked the real language gaps (tail expressions, nested
patterns, string slicing, interface inheritance, …) rather than guessing; those
gaps were closed; then the full front-end was ported into `pkgs/cli/` and now
self-hosts. The remaining front-end work is the LSP's v2 (inference-at-offset
for hover/definition, overlay-aware imports, memoization) toward an incremental
engine — tracked under Deferred work.

## Deferred work

What the language core compiles today outruns what the runtime can _run_. The
gaps, by where they live:

**Runtime (Rust) — blocks running real programs:**

- **Stdlib native surface.** Grown substantially: `String.*`, `List.*`, `Map.*`,
  and `Option.*` are now `native fn`s / Hawk methods in `sdk/std/core/`, plus
  `std.cli` (`Args`), `std.fs`, and `std.process`. `List.map`/`filter`/`fold`
  are written in Hawk over closures. Remaining: broader coverage
  (`first`/`last`/ `slice`/`sort`, more `String`/`Map`) and the `@test` runner's
  surface — still the bulk of the "batteries included" goal.
- **Interface dispatch (`Display`/`Eq`/`Debug`) — static _and_ dynamic; see
  [language.md](language.md).** Conformance is recorded and checked
  (`impl Interface for Type` must provide every method, signatures matching with
  `Self`). A known concrete type dispatches statically (a direct `call`);
  interface-typed values (`fn show(x: Display)`, fields, returns,
  `List<Display>`) and bounded generics (`<T: Eq + Debug>`, bounds enforced at
  call sites) dispatch via the type-id-keyed `call.virtual` + module dispatch
  table, with built-in fallbacks (primitives' `Display`/`Eq`/`Debug`, structural
  `eq`/`debug` derives) when no impl row matches.
- **Closures.** _Implemented._ Closure conversion lifts each lambda to a
  top-level function whose leading locals are its captured variables; the
  runtime adds a closure value `{ func, captures }`, `closure.new`, and
  `call.indirect`. Lambdas, function-typed parameters (`(Int) -> Int`),
  capturing enclosing locals (and `self`) by value, capturing `mut` locals by
  boxed cell (shared writes), and returning closures all work end to end (see
  `examples/closures.hawk`). Lambda parameters take their type from an
  annotation (`(n: Int) => …`) or, un-annotated, from context (the callee
  signature, a `let` annotation, or the function return type), with a hard error
  when neither applies — no guessing. The payoff has landed:
  `List.map`/`filter`/ `fold` are written in Hawk and take closures
  (`sdk/std/core/list.hawk`, `examples/list_hof.hawk`).
  - **Block-body lambda return inference — _done_.** A `{ … }` lambda body that
    returns via `return` now infers the unified type of its `return` statements
    (recursing into nested `if`/`for`/`while`), falling back to the tail/`Unit`
    when it has none — so `f(() => { … return x; })` types as `() -> typeof(x)`,
    not `() -> Void`. Both front-ends; byte-identical. (See "Type inference —
    model & gaps" below for the broader picture.)
- **GC — _done_.** A precise non-moving mark-sweep, built in free-standing
  steps: **(1) explicit call-frame stack** (`Vm::run_loop` over a `Vec<Frame>`;
  precise roots enumerable, deep recursion no longer overflows the host stack);
  **(2) move heap objects off `Rc<RefCell>` into a runtime-owned `u32`-handle
  heap** (`Value` is `Copy`; `Obj::child_values` is the trace primitive); **(3)
  collect** — mark + sweep over a free-listed slab, traced from the frame-stack
  roots at a safepoint between instructions (`runtime/src/heap.rs`). `gc-arena`
  (the `piccolo` VM's collector) was spiked and set aside — its viral `'gc`
  lifetime would have meant rewriting the interpreter and discarding the handle
  heap; the hand-rolled collector fit the existing structure.
  `examples/gc_stress.hawk` validates it (~16 MB of churn holds flat at ~2.4 MB
  resident). See [architecture.md](architecture.md).
- **Fibers / cooperative concurrency — in progress.** A single-threaded
  cooperative scheduler over the interpreter's explicit frame stack (design in
  [architecture.md](architecture.md) §Concurrency; surface in
  [stdlib.md](stdlib.md) §`std.fiber`). Done: **(phase 0)** a scheduler-drivable
  `run_loop` returning `Done`/`Parked`; **(phase 1)** `spawn`/`join`/`yield` with
  GC roots across every fiber; **(phase 2)** buffered `Channel<T>`
  (`send`/`receive`/`close`), channel buffers rooted too. Upcoming:
  - **Phase 3 — park on real I/O.** Start with `time.sleep` (a timer in the
    scheduler), then offload genuinely-blocking syscalls (`fs`/`stdin`/`process`,
    later sockets) to a worker-thread pool that wakes the fiber on completion —
    keeping the single Hawk thread. This makes "blocking-looking I/O parks the
    fiber, not the thread" real, and unblocks `std.http`.
  - **Phase 4 — readiness poller** (`kqueue`/`epoll`) replacing the worker-pool
    offload for sockets, to scale to many concurrent connections; the first real
    runtime-dependency call (`mio` vs hand-rolled). Gated on `std.http`.
  - **Refinements:** per-channel waiter lists (replace the coarse wake-all-on-
    progress), true 0-capacity rendezvous channels, `select` over channels, and
    deciding program-exit semantics for still-running spawned fibers.
- **Map/Set scaling — hashed, insertion-ordered (deferred).** `Obj::Map` is a
  `Vec<(Value, Value)>` with a linear `map_find` and clone-on-mutate, so lookups
  are O(n) and building an N-entry map (the codegen symbol tables) is O(n²). The
  read-path clone is gone (`with_map_ref` borrows), but the scan and the
  clone-write-back build cost remain. Fix: an insertion-ordered hashed map (a
  Vec for order + a hash→index table, indexmap-style) used **above a size
  threshold** so small maps stay linear. Constraints: content-based key hashing
  consistent with `values_eq`; preserved insertion order (output is
  byte-identical, checked by the self-hosting fixpoint); and precomputed per-key hashes so a lookup
  needn't re-enter the heap while holding the map's borrow (the reason mutators
  clone today). The same treatment applies to `Set`.
- More broadly, **read accessors that clone whole heap objects** are a recurring
  cost (fixed for `list.len`/indexing, GC marking, and map reads — each was the
  hot spot when it was the hot spot). The clone-out is correct when a closure
  re-enters the heap to allocate/compare, but it's silently O(n) for trivial
  reads; prefer the borrowing accessor and clone only when the closure needs it.
- Cranelift JIT, untagged value representation, `f64`/large-int constant-pool
  entries — performance/compaction, not correctness-blocking.

**Front-end (codegen):**

- ~~**User-defined enums** (multi-variant, `.name()`).~~ (done — codegen-only;
  enums erase at runtime)
- **Type-inference system (core built; see `pkgs/cli/element/`).** A
  semantic `Type`/element model and a synthesizing inference pass now annotate
  every expression with a resolved type (`Expr.resolvedType`), which codegen
  consumes. This sees _through_ generics (the `T` behind `Option<T>`/`List<T>`,
  method return types, match-arm bindings, `?`/`unwrap` results) — the walls the
  old bottom-up `_typeOf` kept hitting. Prerequisites #1–#2 done; remaining
  work:
  1. ~~**Generic type/enum declarations** (AST + parser).~~ (done)
  2. ~~**A semantic `Type`/element model** distinct from syntactic `TypeRef`,
     derived as a separate resolution stage.~~ (done — `element/types.dart`,
     `element/element.dart`, `element/resolver.dart`, `element/inference.dart`)
  3. ~~**One source of truth for built-in method signatures.**~~ (done, and
     since superseded: the `element/builtins.dart` native-name + return-type
     tables are gone. The built-in methods on `String`/`List`/`Map`/`Option` are
     now ordinary `native fn`s declared in `sdk/std/core/` and resolved through
     the element model — primitives included, via a receiver→element bridge in
     inference. Only operators and literal syntax remain backend-special.)
  - ~~**Use inferred types for checking.**~~ (done — the checker runs inference
    and reports type mismatches: return type (with implicit `Ok` wrap), `let`
    annotations, non-Bool conditions, and call argument types.)
  - ~~**Retire codegen's `_typeOf` fallback.**~~ (done — `_typeOf` now reads
    `Expr.resolvedType` directly; the bottom-up `_typeOfFallback`/`_typeRefOf`,
    the `_localTypes`/`_localTypeRefs` tracking maps, and the
    `_methodReturnType`/`_returnTypeOf` helpers are deleted.)
- Block expressions and literal/nested `match` patterns remain. Interface
  dispatch is done — static on concrete types, dynamic (`call.virtual` + vtable)
  for interface-typed values and bounded generics (see
  [language.md](language.md)). (Closures lower fully: lambdas lift to top-level
  functions; captures by value, with captured `mut` locals boxed into cells, via
  `closure.new` / `call.indirect`. Lambda parameter types are resolved by
  annotation or bidirectional inference, with a hard error otherwise.)
- **Type inference — the model & remaining gaps.** The goal is _predictable_
  inference: a reader (or LLM) can tell where a type is inferred vs. where an
  annotation is required, and an un-inferable type is a **clear, located
  check-time error** — never a silent `Unknown`/`Void` that misfires downstream.
  The shape already realized for **lambda parameters** is the template: a type
  comes from an annotation or the surrounding context, and when neither applies
  the checker says exactly that (_"cannot infer the type of lambda parameter 'x';
  add a type annotation, e.g. (x: Int) => …"_). Extend it to the cases that still
  yield a silent `Unknown`:
  - ~~**Block-body lambda return.**~~ _Done_ (unifies the body's `return`s; see
    above).
  - ~~**`Option.None` / empty-collection locals.**~~ _Done (forward-flow)._
    `let mut x = Option.None;` and `let xs = [];` infer an `Unknown` element from
    the initializer alone; the binding now takes its element/value type from its
    **first pinning use** later in the block — a `push`, an indexed assignment
    (`m[k] = v`), or a reassignment (`x = Some(5)`). Deterministic (first use
    wins, so a later inconsistent use is a mismatch the checker reports), and
    purely additive: a binding nothing pins stays a lenient `Unknown` (no
    spurious "annotate" error — the corpus showed requiring annotations here
    over-fires). `refine_binding_type` in `element/inference.hawk`, wired into the
    checker and codegen block walkers.
  - ~~**Method-call arguments unchecked.**~~ _Done._ The checker validated free
    function arguments (arity, labels, types) but method calls only checked that
    the method *existed*. Now `check_call_args` takes the receiver's generic
    bindings and validates a resolved method's arguments too (`resolve_method` in
    `element/inference.hawk`), substituting the receiver's type arguments so a
    method's `T` is concrete (`push` on a `List<Int>` wants `Int`). Lenient on
    `Unknown`/`TypeParameter`, so it never false-fires on the method's own
    unbound generics (`map`'s `U`) or an imperfectly-inferred receiver — the whole
    stdlib + self-hosted front-end check clean.
  - ~~**Generic call fixed only by return context.**~~ _Done._ A generic call's
    type parameters are now bound from explicit type arguments (`mk<Int>()`), the
    arguments, **and the expected type** (the binding annotation, the enclosing
    return type, a surrounding argument position) — `call_bindings` in
    `element/inference.hawk`. A callee type parameter that appears only in the
    *return* type and stays unbound after all three is the first real
    "annotate here" diagnostic: _"cannot infer type argument `T` for "mk"; add a
    type annotation … or type arguments (`mk<…>(…)`)"_ — the analogue of the
    lambda-parameter one. Scoped to bare `Ident` free-function calls for now;
    namespace functions (`fiber.channel()`) and static methods (`Set.new()`) are
    always annotated in the corpus today, so extending the diagnostic to them is
    a safe follow-up (it needs the checker to arg-check those call forms first).
  - **`Unknown` propagates permissively.** An `Unknown` value is still accepted
    anywhere it appears, so a genuine "couldn't infer" can slip through silently
    (e.g. a binding nothing pins, passed on untyped). `Unknown` should be a typed
    _hole_ flagged at its origin, not a wildcard. (Forward-flow + method-arg
    checking now catch the once-canonical `xs.push("a"); xs.push(1)` case.)
  - ~~**`match`-arm types not unified.**~~ _Done._ `check_match` folds each arm's
    type into a running reference (the `expected` type when the match is in an
    annotated context, else the first value-producing arm) and flags an arm
    assignable to neither it nor itself — `match c { … => 1, … => "x" }` now
    errors on the second arm, and a wrong *later* arm is caught even when the
    first matches (the old first-arm-wins inference missed it). Value-less arms
    (a `Unit` block, or `Unknown` from a bare `return`/`throw`) are exempt, so a
    side-effecting or partial match still checks.

  The through-line: the checker is currently _conservative on `Unknown`_ (never
  errors on one), trading a confusing late failure for a clear early one.
  Flipping that — diagnosing an un-inferable type at its source, lambda-param
  style — is the bulk of the work, and doubles as the LSP's "why is this an
  error" answer.
- **Tech debt — collapse the checker's `_Scope`.** The checker still tracks
  locals as `Map<String, TypeRef?>`, but since inference annotates expressions
  the type _values_ are now vestigial — only key-presence drives
  `_isDefinedName`. It can become a `Set<String>`, retiring `_inferType` and the
  `type` argument of `_bindPattern`. Small and self-contained.

**Language / libraries & visibility:** (see [language.md](language.md))

- **Visibility model — largely implemented.** `pub`/`pub import` parse; imports
  bind a namespace (trailing segment) and qualified access (`ns.fn`,
  `ns.Type.method`, `ns.Enum.Variant`) resolves in inference + codegen;
  `std.core` is the unqualified prelude; directories resolve through a
  `<dirname>.hawk` barrel. `native fn`s bind to runtime symbols via
  `@extern('...')`, and built-in types host static methods
  (`String.from_chars`). The stdlib is reorganized into directory libraries with
  `core` as a barrel (interfaces/error/string/list/map) and `std.cli` over args;
  examples use qualified imports.
- **Remaining (deferred):** _enforce_ `pub`/privacy (cross-file refs to
  non-`pub` symbols error; drop the flat fallback) and `_test.hawk` white-box
  access — plus selective import, field-level visibility, impl coherence, and a
  "module"→"library" terminology sweep. (Consolidated under _Retiring the Dart
  toolchain_ below.)

**Cross-cutting:** stdlib native names are now written once, as `@extern('...')`
on the `native fn` declarations in `sdk/std` (the `element/builtins.dart` mirror
is gone); the Rust runtime table is the other half. Name-bound calls fail at
load on a mismatch — acceptable, but add a test asserting every `@extern` name
the front-end can emit is accepted by the runtime, and split the runtime table
into per-module files (`natives_fs.rs`, `natives_string.rs`, …) as it grows.

**`hawk test` runner — implemented.** `hawk test <file|dir>...` collects
`*_test.hawk` files, and for each: parses it to find `@test` functions,
synthesizes a driver (`__hawk_test_main`) that runs each test and prints an
`ok`/`FAIL` line (failures rendered via the assertion's `Error` message),
compiles the test file + driver, and runs it on the runtime via
`run --entry __hawk_test_main` (a unique entry so it never collides with a
tested module's own `main`). The exit code is the failure count; an overall
summary follows. `std.testing` throws `error(...)` (the general-purpose
`Error`); the driver renders a caught `Err(e)` via `e.message()` (`Error` now
extends `Display`, so `'${e}'` works too — see [language.md](language.md),
"Interface inheritance").

Remaining polish (not blockers): per-test **source locations** on failure (the
runner reports the test name, not the failing assertion's line — needs spans
plumbed through `throw`); a richer structural `debug` (struct field / enum
variant names); and a machine-readable output mode.

**Type-param bound enforcement — done (the generics arc landed).** Bounds
(`<T: Display>`, `<T: Eq + Debug>`) are enforced at call sites: the inferred
type argument must satisfy every bound (primitives carry the built-in
`Eq`/`Display`/`Debug`; `Eq`/`Debug` derive structurally for structs/enums;
other interfaces need an explicit `impl`). Inside a generic body, a method call
on the erased `T` dispatches via `call.virtual` (see
[language.md](language.md)). Still open from this area: **generic operators**
(`<T: Add>`, operators-as-traits).

**Bitwise operators — not yet in the language.** Hawk has no `& | ^ << >>` (nor
an unsigned integer type), so bit-twiddling code can't be written in Hawk today.
This blocks implementing hashing/encoding and a modern PRNG in Hawk:
`std.random` ships a SplitMix64 generator whose **state lives as a visible `Int`
in Hawk** but whose mixing step is a Rust native (`random_mix`), precisely
because the mix needs shifts and xor; `std.hash` and `std.encoding` (base64/hex)
will hit the same wall. Adding the operators is a self-contained arc — lexer
tokens, parser precedence, checker (Int-only), codegen, and runtime opcodes (the
runtime already does wrapping i64 arithmetic) — that would let these libraries
move from natives into Hawk and dogfood the emitter further. An unsigned type
(or defined wrapping/logical-shift semantics on the signed `Int`) is part of the
design.

**Index operator (`[]`) overloading — not yet.** `a[i]` (read) and `a[i] = v`
(write) are hardcoded in codegen to the built-in `List`/`Map` natives by static
type; any other receiver is a compile error
(`pkgs/cli/codegen/codegen.hawk`, `_indexNative` + the index-assign switch).
Allowing user types to be indexed is a **small–medium, self-contained** change —
no parser or runtime work (both forms already parse; a user index op is just a
method call that reuses the existing static/`call.virtual` dispatch). It
desugars to a method call: inference resolves `a[i]`'s type from the receiver's
index method (`_indexResult` in `element/inference.dart`), and codegen's two
`throw` branches become method-call lowerings. List/Map keep their native fast
path.

Design leaning: a **single `Indexable<K, V>` interface** (one `get`-style method
plus a `set`-style method) rather than separate `Index` / `IndexSet` — accept
that some implementors (read-only containers) won't meaningfully support the
write half, in exchange for one interface to teach and check. Unblocks
user-defined containers (grids, sparse vectors, ordered maps) on its own; it is
also a prerequisite for a Hawk `Map`, though that additionally needs map-literal
lowering and a native↔Hawk-map bridge (see the `std` migration notes).

**Incremental front-end / LSP performance.** The front-end is whole-program and
stateless per request: each `hawk check`, and each LSP edit, re-reads,
re-parses, and re-checks the entire import closure (including the whole
`std.core` prelude) from scratch (see `src/loader.dart`). Fine at today's scale,
but the LSP re-does this on every keystroke, so it won't hold up as the stdlib
and user programs grow. Longer term the analysis needs to be incremental: cache
parsed/resolved libraries and invalidate by file, reuse the element model across
requests, and re-check only what changed. (The CLI/LSP now share `loader.dart`,
but each still builds its own `TypeChecker`/element model per call — the unit to
make reusable.)

**Decided:** the entry/args convention — `main` takes the arguments as a
`List<String>`; `Args` is an explicit `std.cli` import (`cli.Args.new(...)`)
constructed from that list (no auto-import).

**Decided / done:** `Result`/`Option` are ordinary enums defined in `std.core`
(`core/result.hawk`, `core/option.hawk`), not compiler built-ins. Their
constructors are no longer special-cased in the checker/inference/codegen;
construction is qualified like any enum (`Result.Ok(x)`, `Option.None`). What
stays language-blessed (irreducible — the language references these types by
name): the `?` operator, implicit `Ok`-wrapping on `return` and `throw -> Err`,
the reserved runtime type ids 0/1 (so `main`'s exit code and `Option`'s native
methods can recognize them), and the pinned variant tags. Re-introducing
unqualified variant construction (a general "variants of an in-scope enum are
callable unqualified" rule, or sugar) is deferred until there's feedback that
the qualified form is onerous.

## Remaining front-end work

The Hawk front-end self-hosts and the **Dart toolchain has been removed**: the
build bootstraps from the checked-in `bootstrap/frontend.hawkbc` snapshot (see
`bootstrap/README.md`), and `bin/test.sh` + the `build_sdk` self-fixpoint replace
the old Dart byte oracle. What's left to round out the front-end:

- **Per-namespace resolution + `pub`/privacy enforcement — rising priority.**
  Free functions resolve same-file-first with a global fallback, but a `private`
  fn is still reachable cross-file, and a `pub` name still collides across
  libraries through a namespace-qualified call (the qualifier is cosmetic in
  codegen); types/enums/consts/natives are likewise global-by-bare-name. This
  already bites: pulling `std.json`/`std.io` into the front-end collided
  `json.parse` with the parser's `parse` (renamed `parse_tokens`) and a local
  `Message` with `std.core`'s (renamed) — caught only at codegen, not `check`.
  Proper module-scoped resolution (qualified calls resolve _within_ the named
  library) + privacy enforcement is the real fix; a duplicate-top-level-name
  diagnostic would at least surface collisions early. A _permanent_ sub-case:
  **prelude (`std.core`) names are always unqualified**, so they're de-facto
  soft reserved words — the prelude must hold only language-fundamental
  types/traits/verbs, never common domain nouns (why the `Message` error type
  became the `error('…')` constructor over a private carrier).
- **Visibility follow-ups** (from the visibility model now in
  [language.md](language.md)): enforce `pub`/privacy; grant `_test.hawk`
  white-box access to its target's privates (only meaningful once privacy is
  enforced); `impl` coherence / orphan rules; optional selective import
  (`show`/`hide`) and field-level visibility; sweep remaining "module" wording
  to "library"/"source file".
- **Checker predicts codegen — residual gaps.** Field/method validation lands
  (`check` rejects bad field accesses, missing methods, and now bad method
  **arguments** — arity/labels/types with receiver-generic substitution —
  conservative on unknown receivers). Remaining: field access on a non-struct
  concrete value (`5.x`) still slips to codegen; and the remaining
  inference-completeness work (`Unknown`-as-a-diagnosed-hole, return-context-only
  generics) — forward-flow for `Option.None`/empty-literal locals, method-argument
  checking, and `match`-arm unification are now done — see "Type inference — the
  model & remaining gaps" above.
- **Parser/codegen bug — trailing `;` after a block-`if`/`match` corrupts a
  module (near-term).** A trailing `;` on a block-form statement whose body ends
  in a nested block — e.g. `if cond { … match … { } };` as the **last statement
  of a `for`-loop body** — miscompiles: the enclosing source file's exported
  declarations silently fail to register, surfacing as bogus errors in
  *importing* files (`unknown function: <name>`, `field access on non-struct
  value`) rather than at the `;`. Hit while writing `check_match`; worked around
  by dropping the redundant `;` (block statements don't need one) and flattening
  the nesting into a helper. Both front-ends (current + the bootstrap snapshot)
  fail identically, so it's not snapshot drift — it's a real parser or codegen
  defect. To fix: build the minimal repro (`fn` with `for { if c { match x {} }
  ; }` plus an importer), find where the trailing `;` derails declaration
  registration (suspect the statement/tail boundary in the parser, or block
  codegen dropping the file's symbol table), and add a parser test. Until then,
  prefer no trailing `;` on block-form `if`/`for`/`while`/`match` statements.
- **LSP v2 toward an incremental engine** — inference-at-offset
  (hover/definition on locals, expressions, members), overlay-aware imports
  (honor unsaved edits), and memoizing the import-closure load so analysis isn't
  redone per keystroke (see the incremental note above). _Transport now has an
  end-to-end smoke test (`bin/test.sh`) after a line-buffered-stdout bug let only
  the header of each message reach the client; the in-process server `@test`s use
  a `StringWriter` and couldn't catch it._

## Planned sequence

1. ~~Consolidation: entry/args convention + `Result`-return unwrapping in the
   runtime; gate `hawk emit` on the type-checker.~~ (this pass)
2. **Stdlib + interface dispatch + closures** — turns "compiles" into "runs" for
   real CLI programs. _Closures and concrete-type interface (`Eq`/`Display`)
   dispatch are done; the stdlib keeps growing._
3. **GC** — _done_: a precise non-moving mark-sweep over a free-listed slab.
4. **Generics arc** — _done_: dynamic dispatch (type-id `call.virtual`),
   interface-typed values, type-param bound enforcement, and the structural
   `eq`/`debug` fallbacks. Generic operators (`<T: Add>`) remain.
5. **`hawk test` runner** — _done_: runs `@test` functions in `*_test.hawk`
   files, with per-test pass/fail reporting.
6. ~~**Walk toward arc 3** — stdlib-in-Hawk, then the Hawk front-end.~~ _done:
   the front-end self-hosts and ships in the SDK; what's left is under Remaining
   front-end work._

## Staged path (runtime, longer view)

1. ~~Dart POC tree-walker — settle semantics.~~ (done)
2. ~~Define the bytecode — the stable IR / distribution format.~~ (format and
   interpreter exist, see [bytecode.md](bytecode.md))
3. **Interpreter + precise non-moving mark-sweep GC** — _done_. This alone runs
   real Hawk apps with fast startup.
4. **Add the Cranelift JIT tier** for hot functions (or trial copy-and-patch);
   decide the JIT root strategy here (see GC in
   [architecture.md](architecture.md)).
5. **AOT via `cranelift-object`** later — single-binary distribution — optional,
   not on the startup-critical path.
