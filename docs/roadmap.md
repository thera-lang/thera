# Hawk roadmap

**What this is:** where Hawk is today and what comes next. For the runtime
design behind this plan see [architecture.md](architecture.md).

## Current state

**Checkpoint (2026-06).** Foundations are in place: a defined **`.hawkbc`
bytecode format**, a **bytecode interpreter** (Rust), a **Dart front-end** that
type-checks and compiles Hawk source to bytecode, and a **growing core stdlib**
(in Hawk + natives). **Closures**, generics-aware **inference**, a largely
implemented **visibility/library** model, and interface (`Eq`/`Display`)
**dispatch on concrete types** all work; real CLI programs compile and run end to
end (see `examples/`). Not yet done: a **GC** (currently `Rc<RefCell>`); a
**broader stdlib**; *enforced* visibility; and **dynamic dispatch + generic
bounds** (the generics arc — see [interfaces.md](interfaces.md)). The north star
is a language + implementation + stdlib complete enough to **write the Hawk
front-end in Hawk** (arc 3 below).

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
a string constant pool, natives referenced by name). The `hawk` binary can
`emit-demo` and `run` a `.hawkbc` file.

**Dart toolchain (`tool/`)** — lexer, parser, type-checker, LSP, **and a
bytecode emitter** (`hawk emit <file> <out.hawkbc>`). `hawk run` compiles to
`.hawkbc` and executes it on the Rust runtime. (The original tree-walking
interpreter has been retired; `hawk test` is a TBD stub until the `@test` runner
is reimplemented on the bytecode pipeline.) The emitter lowers the whole
language _core_ to `.hawkbc`: functions and
recursion, locals and typed arithmetic, control flow (`if`/`while`/`for`,
short-circuit `&&`/`||`), calls and string interpolation, `Result`/`Option` as
ordinary library enums (`?`, `throw`, implicit `Ok`, `match`; construction
qualified — `Result.Ok`/`Option.None`), structs (type table, literals, field
get/set), methods (instance + static, including `native fn`s and methods on
primitives) with named-argument resolution, interface (`Eq`/`Display`) dispatch
on concrete types, and `List`/`Map` literals/indexing/iteration. `hawk emit`
type-checks before lowering.

The front-end carries a real **type system** (`tool/lib/src/element/`): a
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
3. **Hawk front-end emits `.hawkbc`** — self-hosting; bootstrapped by arc 2
   compiling the Hawk-written front-end the first time. _Deliberately deferred_
   until the Dart front-end + Rust runtime are stable and complete enough to run
   real programs (see Strategy).

The Dart toolchain is maintained — parsing current Hawk and emitting bytecode —
until the Hawk front-end can compile itself.

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

## Deferred work

What the language core compiles today outruns what the runtime can _run_. The
gaps, by where they live:

**Runtime (Rust) — blocks running real programs:**

- **Stdlib native surface.** Grown substantially: `String.*`, `List.*`, `Map.*`,
  and `Option.*` are now `native fn`s / Hawk methods in `sdk/std/core/`, plus
  `std.cli` (`Args`), `std.fs`, and `std.process`. `List.map`/`filter`/`fold` are
  written in Hawk over closures. Remaining: broader coverage (`first`/`last`/
  `slice`/`sort`, more `String`/`Map`) and the `@test` runner's surface — still
  the bulk of the "batteries included" goal.
- **Interface dispatch (`Display`/`Eq`) — concrete-type dispatch done; see
  [interfaces.md](interfaces.md).** Conformance is recorded and checked
  (`impl Interface for Type` must provide every method, signatures matching with
  `Self`); `==`/`!=` dispatch to an explicit `impl Eq` (else the structural
  default), and `${…}` / `println(user_value)` render via `Display`. All static —
  the concrete type is known at the call site, so no runtime mechanism. Deferred
  to the generics arc: a type-id-keyed `call.virtual` for type-erased interface
  values and generics.
- **Closures.** _Implemented._ Closure conversion lifts each lambda to a
  top-level function whose leading locals are its captured variables; the runtime
  adds a closure value `{ func, captures }`, `closure.new`, and `call.indirect`.
  Lambdas, function-typed parameters (`(Int) -> Int`), capturing enclosing
  locals (and `self`) by value, capturing `mut` locals by boxed cell (shared
  writes), and returning closures all work end to end (see
  `examples/closures.hawk`). Lambda parameters take their type from an
  annotation (`(n: Int) => …`) or, un-annotated, from context (the callee
  signature, a `let` annotation, or the function return type), with a hard error
  when neither applies — no guessing. The payoff has landed: `List.map`/`filter`/
  `fold` are written in Hawk and take closures (`sdk/std/core/list.hawk`,
  `examples/list_hof.hawk`).
- **GC.** Currently `Rc<RefCell>`; a precise non-moving mark-sweep is planned as
  an explicit placeholder, to land _after_ closures/interfaces so it traces the
  value shapes it will actually see.
- Cranelift JIT, untagged value representation, `f64`/large-int constant-pool
  entries — performance/compaction, not correctness-blocking.

**Front-end (codegen):**

- ~~**User-defined enums** (multi-variant, `.name()`).~~ (done — codegen-only;
  enums erase at runtime)
- **Type-inference system (core built; see `tool/lib/src/element/`).** A
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
  `Eq`/`Display` now dispatch on concrete types (done — see
  [interfaces.md](interfaces.md)); the vtable form is deferred to the generics
  arc. (Closures lower fully: lambdas lift to top-level functions; captures by
  value, with captured `mut` locals boxed into cells, via `closure.new` /
  `call.indirect`. Lambda parameter types are resolved by annotation or
  bidirectional inference, with a hard error otherwise.)
- **Tech debt — collapse the checker's `_Scope`.** The checker still tracks
  locals as `Map<String, TypeRef?>`, but since inference annotates expressions
  the type _values_ are now vestigial — only key-presence drives
  `_isDefinedName`. It can become a `Set<String>`, retiring `_inferType` and the
  `type` argument of `_bindPattern`. Small and self-contained.

**Language / libraries & visibility:** (see [visibility.md](visibility.md))

- **Visibility model — largely implemented.** `pub`/`pub import` parse; imports
  bind a namespace (trailing segment) and qualified access (`ns.fn`,
  `ns.Type.method`, `ns.Enum.Variant`) resolves in inference + codegen;
  `std.core` is the unqualified prelude; directories resolve through a
  `<dirname>.hawk` barrel. `native fn`s bind to runtime symbols via
  `@extern('...')`, and built-in types host static methods
  (`String.from_chars`). The stdlib is reorganized into directory libraries with
  `core` as a barrel (interfaces/error/string/list/map) and `std.cli` over args;
  examples use qualified imports.
- **Remaining (deferred, tracked in visibility.md):** *enforce* `pub`/privacy
  (cross-file refs to non-`pub` symbols error; drop the flat fallback) and
  `_test.hawk` white-box access — plus selective import, field-level visibility,
  impl coherence, and a "module"→"library" terminology sweep.

**Cross-cutting:** stdlib native names are now written once, as `@extern('...')`
on the `native fn` declarations in `sdk/std` (the `element/builtins.dart` mirror
is gone); the Rust runtime table is the other half. Name-bound calls fail at load
on a mismatch — acceptable, but add a test asserting every `@extern` name the
front-end can emit is accepted by the runtime, and split the runtime table into
per-module files (`natives_fs.rs`, `natives_string.rs`, …) as it grows.

**`hawk test` runner.** The `@test` runner needs reimplementing on the bytecode
pipeline (compile with the Dart front-end, execute on the Rust runtime); today
it is a TBD stub. Likely shape: synthesize an entry that calls each `@test`
function and reports `Ok`/`Err`. Remaining codegen gaps a `_test.hawk` hits
(unit-in-`Result` / `Ok(void)` now works): generic bounds (`<T: Eq + Debug>`),
`Debug` dispatch in `assert_eq`, and `throw <string>`.

**Type-param bound enforcement (the generics arc).** Type-param bounds
(`<T: Display>`, `<T: Eq + Debug>`) currently parse but are enforced nowhere — no
satisfies/implements check exists in the checker or inference, so
`println<T: Display>(...)` (sdk/std/core/io.hawk) accepts anything. Enforcement
belongs to the generics arc: an erased `T` needs *dynamic* dispatch to call an
interface method, so bounds, dynamic dispatch, and generic operators (`<T: Add>`)
move together. Concrete-type `Eq`/`Display` dispatch already works (see
[interfaces.md](interfaces.md)); primitives render via the runtime's
`display_string`/`stringify` natives (their built-in `Display`), so no formal
`impl Display for Int` is needed for that. Pairs with the `hawk test` runner's
`Debug`-in-`assert_eq` gap (also generic).

**Incremental front-end / LSP performance.** The front-end is whole-program and
stateless per request: each `hawk check`, and each LSP edit, re-reads, re-parses,
and re-checks the entire import closure (including the whole `std.core` prelude)
from scratch (see `src/loader.dart`). Fine at today's scale, but the LSP re-does
this on every keystroke, so it won't hold up as the stdlib and user programs
grow. Longer term the analysis needs to be incremental: cache parsed/resolved
libraries and invalidate by file, reuse the element model across requests, and
re-check only what changed. (The CLI/LSP now share `loader.dart`, but each still
builds its own `TypeChecker`/element model per call — the unit to make
reusable.)

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

## Planned sequence

1. ~~Consolidation: entry/args convention + `Result`-return unwrapping in the
   runtime; gate `hawk emit` on the type-checker.~~ (this pass)
2. **Stdlib + interface dispatch + closures** — turns "compiles" into "runs" for
   real CLI programs. _Closures and concrete-type interface (`Eq`/`Display`)
   dispatch are done; the stdlib keeps growing._
3. **Placeholder GC** — simple non-moving mark-sweep, planned for replacement.
4. **Generics arc** — dynamic dispatch (type-id `call.virtual`), interface-typed
   values, type-param bound enforcement, generic operators.
5. **Walk toward arc 3** — stdlib-in-Hawk, then the Hawk front-end.

## Staged path (runtime, longer view)

1. ~~Dart POC tree-walker — settle semantics.~~ (done)
2. ~~Define the bytecode — the stable IR / distribution format.~~ (format and
   interpreter exist, see [bytecode.md](bytecode.md))
3. **Interpreter + precise non-moving mark-sweep GC.** Interpreter exists; GC is
   the placeholder above. This alone runs real Hawk apps with fast startup.
4. **Add the Cranelift JIT tier** for hot functions (or trial copy-and-patch);
   decide the JIT root strategy here (see GC in
   [architecture.md](architecture.md)).
5. **AOT via `cranelift-object`** later — single-binary distribution — optional,
   not on the startup-critical path.
