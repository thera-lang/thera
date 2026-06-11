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

- **The interpreter uses an explicit call-frame stack** (`Vm::run_loop` over
  `self.frames`, a `Vec<Frame>` where each frame owns its operand stack +
  locals), not Rust recursion. That is the precise-roots prerequisite: every
  active frame's values are enumerable from one place, and deep Hawk recursion
  is bounded by the heap rather than the host stack. The stack lives on the `Vm`
  and is **shared across re-entrant interpreter calls** (e.g. structural `debug`
  invoking a user impl runs a nested `run_loop` that pushes onto the same stack)
  — so the collector sees _all_ frames, with no roots hiding in nested Rust
  calls.
- **Collect at a safepoint between bytecode instructions** (the `run_loop` top),
  not inside `heap::alloc`. Then mid-instruction temporaries held only in Rust
  locals (the elements popped for `list.new` before the allocation; a native's
  scratch values) are never exposed to a collection, so the unrooted-temporary
  hazard does not arise — and natives run atomically with respect to the GC.
- **Precise, non-moving mark-sweep, interpreter-only — _done_** (`heap.rs`).
  With frames enumerable and the typed bytecode saying exactly what is a
  pointer, precise roots are straightforward. Sequenced as: **(a) move heap
  objects off `Rc<RefCell>` into a runtime-owned heap** (`Value::Ref` is a `u32`
  handle, `Value` is `Copy`, and `Obj::child_values` is the trace primitive),
  then **(b) add mark + sweep + the frame-stack root walk** — both now landed.
  The heap is a slab of slots; a swept slot becomes a hole on a free list that
  the next `alloc` reuses, so **handles are stable across a collection**
  (nothing moves). `maybe_collect` traces from the frame-stack roots, frees the
  unmarked slots, and grows the next-collection threshold to twice the
  survivors. The arena lives behind a **thread-local** so the value constructors
  and `==` need no explicit heap parameter; access is closure-scoped and
  comparisons/recursion **clone the object out** first (cheap with `Copy`
  handles) to avoid re-entering the heap while it is borrowed. The one
  re-entrant path — the structural `debug`/`display` fallback, which calls back
  into the interpreter while its values sit in Rust locals — pauses collection
  for its duration (atomic w.r.t. the GC, like a native). Validated by
  `examples/gc_stress.hawk`: ~16 MB of churn that leaked to ~500 MB under the
  no-collect heap now holds flat at ~2.4 MB resident.
- **`gc-arena` was evaluated and set aside** for now. It (the GC behind the
  `piccolo` Lua VM) is a proven precise mark-sweep with no stack maps, but its
  generative `'gc` lifetime is viral: it would thread through `Value`, `Obj`,
  the `Vm`, every frame, and all ~114 native signatures, require write barriers
  on the mutable object shapes, move the entire VM state _into_ the arena root
  (collection only happens _between_ `mutate` calls), and restructure `run_loop`
  into a fuel-stepped driver — and it discards the `u32`-handle heap above. A
  spike confirmed it collects correctly but at that cost; the hand-rolled
  mark-sweep slots into the existing heap with near-zero ripple, so it won. If a
  moving/generational GC is ever wanted, `gc-arena` (or a bespoke collector)
  remains reachable from this same explicit-heap + explicit-loop structure. (Not
  Boehm — conservative scanning can't use what we know about pointers.)
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

### Where the collector goes next

The v1 collector is deliberately simple (stop-the-world, count-triggered,
non-moving). Likely improvements, roughly in priority order:

- **Poll the safepoint less often.** `maybe_collect` currently runs at _every_
  instruction — one thread-local borrow plus an occupancy compare. It is cheap,
  but only allocation can make a collection due, so the check only needs to
  happen where the heap can have grown since the last one: at **back-edges and
  calls** (and, conservatively, the allocating opcodes). Move the poll there and
  straight-line non-allocating code pays nothing. The cost is a larger possible
  overshoot between checks — bounded, because a single instruction allocates a
  bounded amount.
- **Trigger on bytes, not object count.** The threshold counts live _objects_,
  so a 10-byte string and a 10 MB one weigh the same. Tracking bytes allocated
  (and bytes live after a sweep) gives a memory-proportional trigger and a real
  heap target — with optional floor/ceiling bounds and a soft-limit the runtime
  backs toward under pressure. `alloc` would maintain an allocation-debt counter
  the safepoint reads, which also subsumes the previous point (poll = "is debt
  over budget?").
- **Generational collection.** The `gc_stress` workload is the textbook case —
  nearly everything dies young. A young/old split with a minor collection over
  just the young set would cut work dramatically on allocation-heavy code. It
  needs a write barrier (to catch old→young pointers; `field.set`/`list.set` are
  the only mutators) and, once the JIT lands, full precision there too.
- **Incremental marking** (tri-color) to bound pause times once heaps are large
  — the explicit worklist in `collect` is already the shape this builds on.
- **Tighter slab layout.** A slot is `Option<Obj>`, sized to the largest `Obj`
  variant; size-segregating pools or boxing the big payloads would shrink the
  slab and improve locality. (Still non-moving — handles stay stable.)
- **Diagnostics.** A `HAWK_GC_STATS`-style knob (collections, bytes reclaimed,
  pause time) — `object_count` is the seed. **Weak references / finalizers**
  stay unbuilt until a Hawk object owns a native resource; the hook would live
  in the sweep loop.

A **moving/compacting** collector is the one direction the stable-handle
contract and the planned conservative-JIT-frame scan both rule out — revisit
only if fragmentation or generational promotion later justifies full precision
across both tiers.

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
