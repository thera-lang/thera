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
interpreter, and LSP for current Hawk. This is how `.hawk` source runs today.

## The three bootstrap arcs

The path to a self-hosting `hawk`:

1. **Interpreter runs `.hawkbc`** — _largely here._ Remaining: a real entry/args
   convention and a fuller native/stdlib surface.
2. **Dart front-end emits `.hawkbc`** — _the linchpin._ Add a bytecode-emitter
   backend to the Dart toolchain (alongside its tree-walker), targeting our
   exact format/opcodes/native-ABI. This runs real Hawk programs on the Rust
   runtime _and_ is the bootstrap compiler that produces the first
   `frontend.hawkbc`.
3. **Hawk front-end emits `.hawkbc`** — self-hosting; bootstrapped by arc 2
   compiling the Hawk-written front-end the first time.

The Dart toolchain is maintained — parsing current Hawk and emitting bytecode —
until the Hawk front-end can compile itself.

## Staged path (runtime)

1. ~~Dart POC tree-walker — settle semantics.~~ (done)
2. ~~Define the bytecode — the stable IR / distribution format.~~ (in progress;
   format and interpreter exist, see [bytecode.md](bytecode.md))
3. **Rust runtime: interpreter + precise non-moving mark-sweep GC.** Interpreter
   exists; the GC is next on the runtime side. This alone runs real Hawk apps
   with fast startup.
4. **Add the Cranelift JIT tier** for hot functions (or trial copy-and-patch);
   decide the JIT root strategy here (see GC in
   [architecture.md](architecture.md)).
5. **AOT via `cranelift-object`** later — single-binary distribution — optional,
   not on the startup-critical path.

## What's next (near-term options)

- **Interpreter features that need front-end co-design** (deferred until then):
  closures (capture representation), interface dispatch (static vs. vtable).
- **Runtime:** the GC; an entry/args convention; growing the native/stdlib
  surface; `f64` / large-int constant-pool entries (compaction).
- **Arc 2:** the Dart bytecode emitter — the highest-leverage next step toward
  running real programs on the Rust runtime.
