# Hawk roadmap

**What this is:** where Hawk is today and what comes next. For the runtime
design behind this plan see [architecture.md](architecture.md).

## Current state

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

**Dart toolchain (`tool/`)** — lexer, parser, type-checker, tree-walking
interpreter, LSP, **and a bytecode emitter** (`hawk emit <file> <out.hawkbc>`).
The emitter lowers the whole language _core_ to `.hawkbc`: functions and
recursion, locals and typed arithmetic, control flow (`if`/`while`/`for`,
short-circuit `&&`/`||`), calls and string interpolation, `Result`/`Option`
(`Ok`/`Err`/`Some`/`None`, `?`, `throw`, implicit `Ok`, `match`), structs (type
table, literals, field get/set), methods (instance + static) with named-argument
resolution, and `List`/`Map` literals/indexing/iteration. `hawk emit` type-checks
before lowering.

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

- **Stdlib native surface.** The runtime has ~19 natives; the Dart interpreter
  has `String.*`, `List.map`/`filter`, `Args`, `fs`, `process`, `testing`. This
  is the bulk of the "batteries included" goal and the biggest single blocker.
- **Interface dispatch (`Display`/`Eq`).** _Design settled_ (see
  [bytecode.md](bytecode.md)): the frontend resolves statically and emits direct
  `call`s while the concrete type is known at the site — so `${user_value}`
  interpolation and `==` on structs need no new runtime mechanism. A vtable
  (`call.interface`) is added only when type-erased interface values arrive.
- **Closures.** _Design settled:_ closure conversion + boxing of captured `mut`
  locals (front-end lowering); the runtime adds only a closure value
  `{ func, env }` and `call.indirect`. Needed for lambdas (`List.map`).
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
  consumes. This sees *through* generics (the `T` behind `Option<T>`/`List<T>`,
  method return types, match-arm bindings, `?`/`unwrap` results) — the walls the
  old bottom-up `_typeOf` kept hitting. Prerequisites #1–#2 done; remaining work:
  1. ~~**Generic type/enum declarations** (AST + parser).~~ (done)
  2. ~~**A semantic `Type`/element model** distinct from syntactic `TypeRef`,
     derived as a separate resolution stage.~~ (done — `element/types.dart`,
     `element/element.dart`, `element/resolver.dart`, `element/inference.dart`)
  3. **One source of truth for built-in/stdlib method signatures** — still split
     across the inference pass's `_builtinMethodReturn`, codegen's
     `_builtinMethods`, and the runtime; ideally described as Hawk signatures in
     `sdk/std`. (next)
  - **Retire codegen's `_typeOf` fallback.** It is now only consulted when
    `resolvedType` is absent/unknown; once inference covers every case it can be
    deleted, along with `_typeRefOf`.
  - **Use inferred types for checking, not just codegen** — the checker still
    does only name/arity/existence checks; the resolved types enable real
    type-mismatch diagnostics (assignments, args, returns).
- Interface/`Display` (vtable form), closures, block expressions, literal/nested
  `match` patterns — mostly gated on the runtime equivalents.

**Cross-cutting:** the stdlib natives are listed in both the Rust runtime and
the Dart interpreter. Acceptable (name-bound calls already fail at load on a
mismatch); add a test asserting every native name codegen can emit is accepted
by the runtime, and split the runtime table into per-module files
(`natives_fs.rs`, `natives_string.rs`, …) as it grows.

**Decided:** the entry/args convention — `main` takes the arguments as a
`List<String>`; `Args` is an explicit `std.args` import constructed from that
list (no auto-import).

## Planned sequence

1. ~~Consolidation: entry/args convention + `Result`-return unwrapping in the
   runtime; gate `hawk emit` on the type-checker.~~ (this pass)
2. **Stdlib + interface dispatch + closures** — turns "compiles" into "runs" for
   real CLI programs; forces the interface/closure decisions everything else
   depends on.
3. **Placeholder GC** — simple non-moving mark-sweep, planned for replacement.
4. **Walk toward arc 3** — stdlib-in-Hawk, then the Hawk front-end.

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
