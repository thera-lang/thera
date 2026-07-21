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

## Interface dispatch

A method call on a value whose concrete type is known at the call site is a
direct `call` — no vtable. Dispatch goes dynamic only when the concrete type
isn't statically known: an **interface-typed value** (`fn show(x: Display)`,
`List<Display>`) or a **bounded generic** (`<T: Display>`). Those lower to a
`call.virtual <selector>` op, dispatched **type-id-keyed**: every runtime value
carries its concrete type (`Obj::Struct{ty}` / `Obj::Enum{ty}`; primitives are
self-identifying tags), so `call.virtual` reads the receiver's type id and looks
up `(type_id, selector)` in the module's dispatch table. **Built-in fallbacks**
cover primitives' `Display`/`Eq`/`Debug` and the structural `eq`/`debug` derives
when no impl row matches. (The alternative — monomorphization / dictionary
passing — is heavier; type-id keying is cheap and a natural fit for the tagged
`Value`.) The interface _semantics_ — conformance, inheritance, the
structural-by-default derives — are in [language.md](language.md).

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
  (nothing moves). `maybe_collect` traces from the frame-stack roots and frees
  the unmarked slots. The arena lives behind a **thread-local** so the value
  constructors and `==` need no explicit heap parameter; access is
  closure-scoped and comparisons/recursion **clone the object out** first (cheap
  with `Copy` handles) to avoid re-entering the heap while it is borrowed. The
  one re-entrant path — the structural `debug`/`display` fallback, which calls
  back into the interpreter while its values sit in Rust locals — pauses
  collection for its duration (atomic w.r.t. the GC, like a native). Validated
  by `bench/gc_stress.hawk`: ~16 MB of churn that leaked to ~500 MB under the
  no-collect heap now holds flat at a few MB resident.
- **The collection heuristic is byte-budgeted and allocation-driven.** `alloc`
  tracks a running byte estimate (`Obj::heap_bytes` — slot + payload capacity)
  and, on crossing the threshold, sets a `GC_PENDING` flag; the per-instruction
  safepoint is then two `Cell` reads (`pending && !paused`), so non-allocating
  instructions pay almost nothing and the threshold math lives only on the
  allocating path. A collection retargets the threshold to **2× the surviving
  bytes — or 4× when it reclaimed less than a quarter of the heap** (a
  memory-hungry program is re-marked less often rather than thrashed for little
  gain), floored at 1 MiB. `live_bytes` is summed _during the mark walk_, so
  `heap_bytes` is read once per live object as part of a traversal already
  underway — never a separate pass, never for garbage — and the mark bitmap is
  reused across collections.
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

The v1 collector is deliberately simple (stop-the-world, non-moving). The
byte-budgeted trigger, the cheap allocation-driven safepoint, and the adaptive
anti-thrash threshold above are in; likely further improvements, roughly in
priority order:

- **Poll at fewer sites.** _Implemented._ The interpreter polls for GC only at
  allocation sites, calls, and backward jumps, rather than before every
  instruction. This avoids polling overhead on straight-line non-allocating
  code.
- **A heap ceiling / soft limit.** _The hard ceiling is implemented:_ a
  collection that still leaves more live bytes than the limit
  (`HAWK_MAX_HEAP_MB`, default 1 GiB) raises `Trap::OutOfMemory` at the
  safepoint — the ordinary trap formatting, not a process abort — and an
  allocation past the ceiling arms a collection even when the adaptive threshold
  sits higher. (Runaway recursion is bounded the same way: a call past the
  frame-stack depth ceiling raises `Trap::StackOverflow`.) Still open: a _soft_
  limit the runtime backs toward under memory pressure, bounding peak footprint
  rather than just failing honestly at the cap.
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

## Concurrency: the fiber scheduler

_Status: implemented through I/O parking — the scheduler, `spawn`/`join`/
`yield`, buffered channels, timer parking (`time.sleep`), and worker-pool
offload for blocking fs/stdin/process calls are all in (see
[roadmap.md](roadmap.md) §Fibers for the phase detail); the readiness poller for
sockets is the open phase. The narrative below is the design reference — written
ahead of the implementation, and how it works as built._

Hawk's concurrency is single-threaded cooperative fibers: blocking-looking I/O
parks the calling fiber and resumes another, with no `async`/`await` coloring.
The runtime structure already built for the GC makes this cheap to implement.

**Why it's cheap here.** Hawk calls don't use the Rust call stack — `run_loop`
keeps an explicit `frames: Vec<Frame>` (each `Frame` owning its `pc`, locals,
and operand stack) and pushes/pops it on `Call`/`Return`; a `Return` with no
caller frame already exits the loop. So a fiber's **entire** resumable state is
that frame stack — an ordinary heap-side value the scheduler can set aside and
pick up later. No OS threads, no stack copying, no `unsafe` stack switching: the
property that usually makes green threads hard is already paid for. This is a
**stackless** coroutine design — the fiber _is_ its `Vec<Frame>`.

**Pieces.**

- `Fiber { id, frames: Vec<Frame>, status }`,
  `status ∈ { Ready, Running, Blocked(reason), Done(Value) }`. The running
  fiber's frames live in the `Vm`; a parked fiber's frames are stored back in
  its `Fiber`.
- `Scheduler { fibers: Slab<Fiber>, ready: VecDeque<FiberId>, poller }` on one
  OS thread. Loop: take a `Ready` fiber, run it until it parks or finishes,
  repeat; when `ready` is empty but fibers are blocked on I/O, block the thread
  in the poller until a source is ready, wake the owners, continue. The program
  ends when the **main** fiber (fiber 0) returns — surviving fibers are
  abandoned (Go semantics).

**Parking = returning to the scheduler.** `run_loop` already returns when the
frame stack empties (fiber done). Add a second exit: a native that would block
returns a `Park(reason)` signal instead of a value; `run_loop` hands the current
fiber's `Vec<Frame>` back to its `Fiber`, marks it `Blocked(reason)`, and
returns to the scheduler. Resuming is just re-entering `run_loop` with those
frames reinstated and the awaited result pushed onto the operand stack. Nothing
else is saved — the frames _are_ the continuation.

**The one constraint — park only at the top of the loop.** A fiber can park only
when the Rust stack is _just_ `run_loop`, not when a native has re-entered it
(the structural-`debug`/virtual-dispatch path that pushes onto the same frame
stack within one Rust call — see GC above). Blocking I/O is always called at
Hawk level, so this is the normal case; the rule is simply "a blocking native is
never invoked from inside a nested interpreter re-entry." (If that ever needs
lifting, the nested path can be reworked to loop instead of recurse.)

**Yield points.** Cooperative — a fiber holds the thread until it parks:
blocking I/O (parks on readiness), `join` on an unfinished fiber, channel
`send`/`receive` on a full/empty channel, and an explicit `fiber.yield()`. No
preemption, so a CPU-bound fiber that never parks starves the rest (acceptable
for the model; if it bites, the interpreter's existing loop back-edge counter —
already there for JIT tier-up — can force an occasional yield).

**GC roots span all fibers.** Today the collector's roots are the running frame
stack. With fibers they become the union over **every** live fiber's frames,
plus values buffered in channels. That is the one substantive GC change — and
it's small: the safepoint already sits at the `run_loop` top, so the root walk
just iterates the scheduler's fibers instead of one stack.

**Channels.** `Channel<T>` = a bounded `VecDeque<Value>` plus queues of blocked
senders and receivers. `send` parks the sender when full; `receive` parks the
receiver when empty and returns `None` once closed and drained. Buffered values
are GC roots.

**`spawn`/`join`.** `fiber.spawn(work)` allocates a `Fiber` whose initial frame
invokes the `work` closure, enqueues it `Ready`, and returns a `Fiber<T>` handle
(a heap value carrying the id). `handle.join()` returns the stored result if the
target is `Done`, else parks the caller on its completion; a finishing fiber
re-queues its joiners with its result.

**I/O integration — two stages.** (1) _Implemented:_ a first cut keeps syscalls
blocking but runs them on a small worker-thread pool, parking the Hawk fiber
until a worker signals completion — the single-thread _Hawk_ guarantee still
holds (workers run no Hawk code) and it needs no event loop, so it unblocked
`std.fiber` soonest. (2) The scaling goal is readiness-based non-blocking I/O
via `kqueue`/`epoll` in the scheduler's poller, so thousands of fibers park on
one thread. Both preserve the "blocking-looking, never blocks the thread"
contract. This is also a runtime-dependency question — a poller crate (`mio`)
vs. hand-rolled `kqueue`/`epoll` to keep dependencies minimal. (The runtime is
no longer strictly dependency-free: `std.hash` took the first external crates —
RustCrypto digests — as a deliberate best-of-breed call; new dependencies stay
few and deliberate.)

This design is the reason the [language.md](language.md) `async`/`await`
fallback should stay a fallback: the stackless-fiber model delivers the same
blocking-looking I/O with no function coloring, and the frame-stack groundwork
is already in place.

## Persistence and the native ABI

`bin/hawk` is the Rust runtime with an **embedded `frontend.thera-bc`** (the
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

## The CLI: commands and output streams

`bin/hawk` exposes the toolchain as subcommands:

| command                         | what it does                                                                              |
| ------------------------------- | ----------------------------------------------------------------------------------------- |
| `hawk run <file> [args…]`       | compile `<file>` to bytecode and run it; trailing args pass to the program                |
| `hawk check [target]`           | type-check a `.hawk` file or directory (default: cwd); diagnostics + summary              |
| `hawk emit <file> <out.thera-bc>` | compile `<file>` to a `.thera-bc` bytecode file                                             |
| `hawk test [file\|dir]`         | run the `@test` functions in a file, or in `*_test.hawk` under a directory (default: cwd) |
| `hawk fmt <file\|dir>…`         | format source in place (`--check` reports unformatted files, writes nothing)              |
| `hawk lint [file\|dir]`         | report non-idiomatic code shapes with a known rewrite (read-only; default: cwd)           |
| `hawk lint --fix <file\|dir>`   | apply the safe lint rewrites in place (explicit target required)                          |
| `hawk lsp`                      | start the language server (LSP over stdin/stdout)                                         |

**stdout vs. stderr.** The rule: stdout carries a command's _expected output_;
stderr carries the _unexpected_ (progress, operational failures, crashes). Which
is which turns on whether the command's product is an **artifact** or its
**diagnostics**:

- `check` and `test` are **analyzers** — they emit no artifact, so their results
  (diagnostics for `check`; the failure blocks for `test`; each command's
  closing summary line) **are** the product and go to **stdout**. This matches
  linters (eslint, ruff, mypy) and test runners (`cargo test`, `go test`,
  pytest), and keeps a future `--json`/SARIF mode on the same stream so
  `hawk check --json | jq` works. Pass/fail is _also_ on the **exit code**
  (`check`: 0 clean / 1 diagnostics / 2 missing or unreadable target —
  operational trumps diagnostics; `test`: 0 all passed / 1 any failed or none
  found — never a count, which would collide with a trap's exit 1 and wrap at
  u8). Note the asymmetry this implies: a test file that fails to **compile**
  produces no test results — that's an operational failure of the run, so
  `hawk test` sends those compile diagnostics to **stderr**, even though
  `hawk check` would put the identical lines on stdout (where they are the
  product). Deliberate, not drift.
- `emit` is a **compiler** — its product is the `.thera-bc`, so its diagnostics
  are "why the build failed" and go to **stderr** (the rustc/clang convention),
  leaving stdout clean.
- `lsp` owns **stdout** for the JSON-RPC wire protocol; human-facing output
  (build/compile progress) goes to stderr.
- **Operational failures** for any command (file not found, can't read/write, an
  internal trap) go to **stderr**, as does the dev launcher's build/compile
  progress (`bin/hawk.sh`).

**Diagnostic format.** Every diagnostic — a `check` type error, an `emit` build
failure, a `run`/`test` compile error — is one line:
**`path:line:column: message`** (`users.hawk:42:5: undefined name: total`). The
file is resolved to where the error _originates_: an error in an imported file
names **that** file, not the entrypoint that triggered the compile (a diagnostic
span carries its source text, and the driver maps it back to the owning file).
This is the editor- and `grep`-friendly convention rustc/gcc/clang/eslint use,
and it is the **same shape `hawk test` prints for a failing assertion** —
`std.testing` stamps the call site via the `#loc` caller-location metaconstant
(see [roadmap.md](roadmap.md)), so `assert_eq failed` is reported as
`users_test.hawk:42:5: assert_eq failed …` (indented under the failing test's
name — see [language.md](language.md) §`hawk test` for the report layout). One
format spans compiler errors and test failures, so an agent or editor parses
both with a single rule. Multi-line messages indent continuation lines under the
location; diagnostics are emitted in a deterministic order, and pass/fail is
_also_ on the exit code (above).

### The formatter (`hawk fmt`)

`hawk fmt` canonicalizes source layout, and the expectation is that **most Hawk
projects run it** (in an editor on save, and as a CI `fmt --check` gate). It has
**no configuration options, by design**: there is one canonical layout, so a
project never spends effort choosing or arguing a style. The goal is to
**eliminate essentially all formatting discussion from code review** — layout is
the formatter's output, not a thing humans diff over.

What it normalizes is deliberately bounded. It fixes **vertical layout** (line
indentation, blank-run collapsing, trailing whitespace) and **intra-line
spacing** (`fn  foo( a:Int )` → `fn foo(a: Int)`). It does **not**, for the most
part, reflow across line boundaries — it keeps every line break the author
chose, and does not join short lines or insert breaks into long ones. That
restraint is partly implementation simplicity (reflow is where formatter
complexity lives), but also a readability call: where a line breaks often
carries intent (a grouped argument list, an aligned match, a chain the author
split for clarity), and mechanically canonicalizing it tends to hurt readability
as often as it helps. So the author owns line breaks; the formatter owns
everything within and between them. It moves only whole lines and rewrites only
inter-token whitespace, so it **never changes what the code means** (a
token-equality + re-parse guard enforces this) — running it is always safe.

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
