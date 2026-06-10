# Hawk runtime architecture

**What this is:** how a Hawk program executes — the tiered VM, the execution
pipeline, garbage collection, and the native-function ABI. For the bytecode
format itself see [bytecode.md](bytecode.md); for status and sequencing see
[roadmap.md](roadmap.md).

## Priorities

For the production runtime (how a real Hawk app executes), in order:

1. **Fast startup**, measured as _source/IR → running_, not just process launch.
   A short-lived CLI tool should feel instant.
2. **Reasonable steady-state performance** — good enough for real work; not a
   goal to beat C.
3. **Mature, broad toolchain** — fewer codegen bugs, support for the chips
   people actually ship CLI tools to.
4. **Managed memory** — a GC, without inventing a world-class one up front.

## Direction: a tiered VM (bytecode interpreter → Cranelift JIT)

We own the execution pipeline: compile Hawk to our own bytecode, run it
immediately in a fast interpreter, and JIT only the hot code to native via
Cranelift.

```
Hawk source ──(compile, off the hot path)──► Hawk bytecode  (our IR; serializable, compact)
                                                   │
                                          ┌────────┴─────────┐
                                          ▼                  ▼
                                  Tier 0: bytecode      Tier 1: Cranelift JIT
                                  interpreter           (hot functions only)
                                  (instant; runs        (lower bytecode → Cranelift
                                   run-once code)         IR → native code)
```

- **`bin/hawk` is the runtime**: bytecode interpreter + Cranelift JIT + GC +
  stdlib, written in **Rust**. A compile step (implicit for `hawk run foo.hawk`)
  produces bytecode.
- **The interpreter tier earns its place for the CLI domain.** A CLI tool
  starts, does bounded work, and exits — most code paths run _once_. A
  JIT-everything design pays compile latency on first call with no steady state
  to amortize it; the interpreter runs that code immediately at zero compile
  cost, and Cranelift is spent only on genuine hot loops.
- **Static typing is the key simplifier.** The complexity in V8/SpiderMonkey/
  PyPy comes from _speculation_: hidden classes, inline caches, type feedback,
  deoptimization. Hawk's bytecode carries concrete types, so the JIT does
  straight-line typed lowering with no guards and no deopt — roughly 80% of what
  makes a tiered VM hard simply does not apply.

Why our own stack-based bytecode (rather than Wasm/JVM/CPython) is argued in
[bytecode.md](bytecode.md); the short version is that off-the-shelf formats
discard Hawk's static types, which is exactly what keeps the JIT
speculation-free.

## Execution pipeline

How a single `hawk run foo.hawk` flows through the runtime:

```
hawk source ──[front-end]──► Module (in-memory bytecode)
                               │
                               ▼
                        Tier-0 interpreter ── per-function execution counter++
                               │
                  counter ≥ threshold (hot)
                               ▼
                  Cranelift JIT compiles that function ──► native code
                               │
                next call dispatches to the compiled version
```

- **Tier dispatch.** Each function carries a tier state (`Bytecode` vs.
  `Compiled(ptr)`); the call path checks it and prefers compiled code. Tier-up
  takes effect on the _next_ call — the in-flight invocation finishes in the
  interpreter (no on-stack replacement to start; OSR is deferred).
- **Counters at calls _and_ loop back-edges.** Call counts miss a hot loop
  inside one long-running function; a back-edge counter catches those. For
  run-once CLI code, calls dominate — which is why only genuine hot loops tier
  up.
- **The value-representation boundary** is the main latent refactor: the JIT
  wants the untagged, typed values the format already carries, while the Tier-0
  interpreter starts with a tagged `Value`. When the JIT lands, interpreted and
  compiled frames must share a representation, so the JIT tier is what forces
  the tagged→untagged move (and it is entangled with precise GC roots).

## Garbage collection

The two-tier stack (interpreter and JIT frames interleaved) is what makes root
finding interesting.

- **The interpreter now uses an explicit call-frame stack** (`Vm::run_loop`, a
  `Vec<Frame>` where each frame owns its operand stack + locals), not Rust
  recursion. That was the precise-roots prerequisite: every active frame's
  values are enumerable from one place, and deep Hawk recursion is bounded by the
  heap rather than the host stack.
- **Precise, non-moving mark-sweep, interpreter-only.** With frames enumerable
  and the typed bytecode saying exactly what is a pointer, precise roots are
  straightforward. Sequenced as: (a) move heap objects off `Rc<RefCell>` into a
  runtime-owned heap that doesn't yet collect — absorbs the broad
  construction/borrow churn while staying trivially correct — then (b) add mark +
  sweep + the frame-stack root walk.
- **A proven precise Rust GC is a live alternative to hand-rolling** (b): e.g.
  **`gc-arena`** (the GC behind the `piccolo` Lua VM) — precise mark-sweep, no
  stack maps, rooting via a branded-arena/`Collect` model that leverages our
  pointer knowledge. Its programming model is invasive (a `'gc` lifetime), but it
  pairs with exactly the explicit-heap + explicit-loop structure above, so the
  two refactors keep both the hand-rolled and `gc-arena` doors open. (Not Boehm —
  conservative scanning can't use what we know about pointers.)
- **When the Cranelift tier lands**, JIT frames need roots too: either emit
  Cranelift safepoints/stackmaps (precise, but the API is fiddly and has been in
  flux), or keep interpreter roots precise and **conservatively scan JIT
  frames** (a known hybrid, less work). The hybrid forces the GC to stay
  **non-moving**.
- **Boehm (bdwgc) is the zero-effort escape hatch** — conservative across both
  tiers, no stack maps anywhere (the Crystal playbook) — if GC is not where we
  want to spend effort.
- **Constraint on the future:** non-moving is plenty for v1, but a
  moving/generational GC later requires _full_ precision including the JIT, so
  avoid baking in conservative-everywhere if generational is a someday-goal.

## Persistence and the native ABI

`bin/hawk` is the Rust runtime with an **embedded `frontend.hawkbc`** (the
front-end, compiled to bytecode, `include_bytes!`'d in). `hawk run foo.hawk`
runs that embedded front-end _on our own interpreter_; it parses `foo.hawk`,
emits a `Module`, and runs it. The front-end is just another Hawk program riding
the runtime — the self-hosting endgame.

This makes the **native-function table an ABI**: every `native fn` in `sdk/std/`
maps to a runtime native, and persisted bytecode references them. Natives are
bound **by name, resolved at load** (Wasm-style imports), not by baked index —
so bytecode stays robust across runtime versions and a separate emitter (the
Dart front-end) need not hard-code an index table. The names live in the
constant pool.

## Options considered and rejected

- **Wasmtime as the runtime.** The Wasm sandbox fights Hawk's central use case:
  subprocess spawning and broad filesystem access are exactly what it restricts,
  and WASI has no mature subprocess/exec API — so shelling out would require
  host shims, eroding the sandbox's value while adding friction. We would also
  be betting memory management on Wasm GC, its newest, least battle-tested
  subsystem. Emitting Wasm as a _secondary_ target (browser/plugin sandboxing)
  remains fine later — just not the primary CLI runtime.
- **LLVM as the JIT.** A re-targetable _optimizing_ pipeline; compile latency is
  high by design — the wrong tool for a fast-startup JIT. (Cranelift exists
  precisely because Wasmtime needed acceptable code at a fraction of LLVM's
  compile time.)
- **Transpiling to another platform** (Go, TypeScript, C). Reasonable — Go in
  particular maps the fiber model onto goroutines almost for free — but it cedes
  ownership of the execution pipeline, which is the part worth building.

## Alternative JIT engines (for the Tier 1 slot)

Cranelift is the mature default (Rust, battle-tested in Wasmtime; targets
x86-64, aarch64, riscv64, s390x). Two alternatives, decidable later since the
bytecode is the stable interface:

- **Copy-and-patch compilation** (CPython 3.13's experimental JIT). Precompile
  per-opcode "stencils" at build time; runtime codegen is essentially `memcpy` +
  patching immediates — far faster than even Cranelift, code quality between
  interpreter and optimizing JIT, smaller runtime dependency. Best fit for
  minimizing source→running latency.
- **MIR** (Makarov's lightweight JIT IR) — fast compilation, ~70% of `gcc -O2`
  output at a fraction of the compile time. C-based, lighter than Cranelift,
  less mature.
