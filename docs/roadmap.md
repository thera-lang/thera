# Thera roadmap

**What this is:** where Thera is today and what's next. Design details for
_completed_ work live in [architecture.md](architecture.md) and
[language.md](language.md); this doc focuses on what's open. As an arc lands,
its open-work entry is removed and condensed into a one-line note in the
[Changelog](#changelog) at the end.

## Current state

**Checkpoint (2026-06).** Thera **self-hosts**. The front-end (`pkgs/cli/`,
written in Thera) lexes, parses, resolves, type-checks, infers, and lowers Thera
to `.thera-bc`, and runs the `check`/`emit`/`run`/`test`/`lsp` CLI (see
[architecture.md](architecture.md) for the commands and their output streams).
It compiles its own sources and the whole stdlib; `bin/build_sdk.sh` embeds it
into the `thera` binary with a **fixpoint check** that the front-end reproduces
itself byte-for-byte. The Dart toolchain that bootstrapped it has been removed —
the build bootstraps from a checked-in `bootstrap/frontend.thera-bc` snapshot (see
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
serializes to `.thera-bc` (header + sections, LEB128, string constant pool). A
first cut of **cooperative fibers** (`std.fiber`) is in:
`spawn`/`join`/`yield` + buffered channels.

**Inference.** The front-end carries a semantic `Type`/element model
(`pkgs/cli/element/`) built by a resolution stage; inference is a **pure,
on-demand** query (`infer_expr` — no AST annotation) the checker and codegen
call. It sees through generics (`Option<T>`/`List<T>` elements, method returns,
match bindings, `?`/`unwrap`), does bidirectional and forward-flow inference,
and the checker reports located diagnostics (type mismatches, bad
calls/fields/methods, unpinnable generics). The inference-completeness arc is
**closed** — see _Changelog_ at the end.

**Not yet:** a broader stdlib; generic operators (`<T: Add>`); index (`[]`)
operator overloading; the Cranelift JIT tier. (Name resolution is now fully
owner-correct for values _and_ types — the `TypeId` arc — with qualified-only
resolution and `pub`/privacy enforced; see _Changelog_.)

## Open work

### Stdlib

- **Stdlib breadth.** `String.*`/`List.*`/`Map.*`/`Option.*` (native + Thera),
  and
  `std.cli`/`std.fs`/`std.process`/`std.random`/`std.time`/`std.json`/`std.io`
  exist; `List.map`/`filter`/`fold` are written in Thera over closures. The
  collection/string/bytes staples are now in (pure Thera over the existing
  primitives, except the two `trim_*` natives): `List.first`/`last`/`is_empty`/
  `contains`/`index_of`/`reverse`/`sort` (comparator-based — a no-arg `sort()`
  waits on an `Ord` interface); `String.replace`/`repeat`/`reverse`/`find`/
  `pad_start`/`pad_end`/`trim_start`/`trim_end`; `Map.get_or`; `Bytes.is_empty`
  and a `BytesReader` (the reader counterpart to `BytesBuilder`:
  `read_u8`/`read_bytes`/`read_u32_le`/`read_u64_le`/`read_uvarint`/`read_ivarint`,
  pure Thera, round-trips the writer). (`slice` on `String`/`List`/`Bytes` was
  already there.) The `Ord` interface + `std.sort` (`sorted`/`min`/`max`) are
  now in — see _Changelog_. `std.encoding` (base64/hex/url, pure Thera),
  `std.hash` (native digests), and `std.regex` (the `regex` crate) are in too.
  The **lazy iteration arc** has landed: `Iterator<T>` with
  `map`/`filter`/`take`/`enumerate`
  - `collect`/`count` as **interface default methods**, the `std.iter` sources,
    and its first consumers — `io.lines`/`BufReader`, `fs.walk`, and streaming
    `fs.open`/`create` → `File` (`Reader`/`Writer`/`Seek`/`Closer`); `List.pop`
    also landed. `std.log` (named, per-source logging) is now in — see
    _Changelog_. Remaining: the rest of the "batteries included" goal
    (`std.term`, `std.http`), and sorted/`Ord`-keyed `Set`/`Map` variants.
  - **`List.enumerate()` — _landed._** A lazy `Iterator<Indexed<T>>` right on
    `List` (`for p in xs.enumerate() { … p.index … p.value … }`), the idiomatic
    replacement for a `while i < xs.len()` index loop — no import, no new
    syntax, reusing the blessed `Indexed<T>` struct (so it sidesteps the
    `Pair`/`Tuple` decision below). Backed by a small `ListEnumerateIter` cursor
    in `std.core`. This is the chosen answer to the indexed-loop ergonomics gap
    the review found (see below).
  - **`zip` iterator adapter** (and `flat_map`/`chain`, the other wrapped
    adapters the `enumerate` parser extension opened). `zip(a, b)` pairs two
    iterators; the **design dependency** is what it yields — Thera has no tuple,
    so it needs a blessed `Pair<A, B>` (the way `enumerate` yields `Indexed<T>`)
    or settling the deferred `Tuple` open question (see
    [language.md](language.md) → Types → Open questions). Motivated by the
    `while i < xs.len()` parallel-index loops the ergonomics review found — e.g.
    `signatures_match`'s `i_params[i]` vs `o_params[i]`. Deferred with that
    migration (no consumer until then); decide `Pair` vs `Tuple` first.

- **`String.slice` cost — _done._** `String.slice` was
  `String.from_chars(self.chars().slice(start, end))` — `chars()` materialized
  the _whole_ string as a `List<Int>` on every call, so a slice was O(string
  length) regardless of the slice's size, and `SourceSpan.text()` (a
  `source.slice`) inherited it. `slice` is now a native (`str_slice`) that walks
  `char_indices` to the range's end in a single pass — O(end), and it allocates
  only the result rather than a code-point list the size of the whole string.
  This still walks from the front (a byte/code-point offset can't be found in
  O(1) over UTF-8), so slicing at ever-increasing offsets over one large string
  stays superlinear in aggregate — the earlier call-site fixes (the lexer and
  formatter reading from a single materialized `chars` list by index; see
  _Changelog_) remain the right pattern for hot per-token loops — but the common
  case (a short slice, or one near the front) and the per-call allocation are
  fixed, so per-call slicing is no longer a latent O(n²) trap for future
  callers.

### Runtime (Rust)

- **Fibers — phases 3–4.** Phases 0–2 are done (scheduler-drivable `run_loop`;
  `spawn`/`join`/`yield` with GC roots across every fiber; buffered
  `Channel<T>`). Design in [architecture.md](architecture.md) §Concurrency.
  Next:
  - **Phase 3 — park on real I/O.** _Done._ Two park kinds, both on the
    deliver-on-resume model (the native's result is delivered when the fiber
    resumes, not recomputed): a `Timer(deadline)` request for `time.sleep`
    (parks on a scheduler timer, so other fibers run during a sleep; the driver
    sleeps the thread until the earliest deadline when nothing else is
    runnable), and an `Await{job, finish}` request that offloads a blocking
    syscall to a **worker-thread pool** (4 threads, lazily created) — the worker
    returns owned Rust data and the `Value` is built back on the Thera thread
    (the heap is thread-local), keeping the single Thera thread. A program left
    with only timer- or I/O-blocked fibers is no longer a deadlock. Parked: `fs`
    path ops, `stdin` read, `fs.open`/`create` + `File` read/write/seek, and
    `std.process` `run`/`exec`/`wait` + pipe I/O. Handle resources (open files,
    process pipes) use a **take-out/return** discipline — the resource leaves
    the registry for the op's duration so no lock is held across the blocking
    call — which lets one fiber feed a child's stdin while another drains its
    stdout (validated by a >pipe-buffer cross-fiber round-trip through `cat`).
    Left thread-blocking on purpose (fast, non-blocking syscalls): `fs.exists`,
    `process.start`/`kill`/`close_stdin`.
  - **Phase 4 — readiness poller.** _Done_ (`mio`, so `kqueue`/`epoll`/IOCP; the
    hand-rolled alternative needs `libc` for the syscalls anyway, making the real
    cost one extra crate versus two unsafe backends and no windows). Sockets are
    **non-blocking**, so unlike every other blocking family their syscalls run
    inline on the Thera thread and never reach the worker pool — a blocking
    `accept` would pin one of its four threads indefinitely, and four such ops
    would stall every other fiber's I/O. Instead `EWOULDBLOCK` parks the fiber
    (`ParkRequest::Ready`) and the `call.native` re-runs when the kernel reports
    readiness — `BlockRetry`'s discipline, woken by the poller. The driver's idle
    loop keeps **one** wait point (`poll()` bounded by the earliest timer), with
    worker completions interrupting it through a `Waker`, so there is no poller
    thread and the runtime stays single-threaded.

    Two properties keep this small. Sockets carry **no readiness state** despite
    mio being edge-triggered: a fiber only parks *after* its syscall returned
    `EWOULDBLOCK`, so any earlier edge was stale and the next transition fires a
    fresh one — the syscall is the ground truth, and every socket native
    therefore attempts its op *before* parking (a correctness rule, not a fast
    path). And because the ops never leave the Thera thread, sockets need none of
    phase 3's take-out/return discipline, so concurrent read + write on one
    socket from two fibers works (unlike a `File`, where it does not).

    The retry means every socket native must be **idempotent**: `read`/`accept`
    are naturally so; `write` is safe only because it returns a *count* and lets
    `io.write_all` loop (a write-all native would re-send bytes on retry); and
    `connect` is split into `socket_connect` + `socket_connect_finish` because
    re-issuing `connect(2)` on a pending fd reports `EALREADY`. DNS is the one
    socket op still on the worker pool — it blocks with no fd to poll, but is
    bounded, so it cannot pin a worker the way `accept` would.
  - **Refinements:** per-channel waiter lists, true 0-capacity rendezvous
    channels and exit semantics for surviving spawned fibers (`select` is done). The
    poller wants the same waiter-list refinement, and for the same reason: any
    readiness event currently wakes *every* socket-parked fiber (`wake_all_poll`,
    matching `wake_all`'s coarseness), so each retries its syscall and the ones
    that aren't ready re-park. Correct, but O(parked) work per event — it will
    want per-fd routing (the mio `Token` is already the socket handle) before a
    server holds many idle connections open.
- **Fiber synchronization primitives — the combinator layer.** The _core_ async
  values already exist: `Fiber<T>` + `join` **is** a Future (uncolored; and
  `join` is idempotent/multicast — `sched_result` reads `Done(v)` by `&self`, so
  any fiber can await the same result repeatedly, giving a broadcast/shared
  future for free), and `channel<T>(1)` is a Completer. What's thin is the
  second-order layer built on them:
  - **`select` / race.** _Done (2026-07)._ A `Selectable` interface plus an index:
    `fiber.select(sources) -> Int`, with `Fiber`, `Channel`, `Timer`, and
    `net.TcpStream` implementing it. Not Go's `select { case … }` syntax, and it
    doesn't need to be — Go fuses the receive into the branch because another
    thread could take the value between "ready" and "receive"; cooperative
    scheduling means nothing runs between those steps, so ask-then-act is exactly
    equivalent with no new grammar. Lowest ready index wins (deterministic, unlike
    Go's random pick, matching the scheduler's stance) — which does mean a hot
    source at index 0 can starve index 1.

    The interface needs two methods, not one: `is_ready` (which must be
    **non-destructive**, since it's asked speculatively about sources the caller
    may never act on) and `source`, because `select` has to know *how* to wait as
    well as whether to. `TcpListener` is therefore not selectable — probing it
    means `accept`, which consumes.

  - **Cancellation token** — a reusable `cancel()` / `is_cancelled()` /
    selectable `done` (the LSP hand-rolled a generation counter for exactly
    this). The poll form works today; the wait-or-cancel form wants `select`.
  - **Timeout.** _Done (2026-07)._ `fiber.with_timeout(work, dur)`, and it fell
    out of `select` as predicted. Caveat that can't be fixed here: the timed-out
    work **isn't cancelled** — a fiber can't be killed — so it bounds your wait,
    not the work. For a socket read the idiom is to close the socket on timeout,
    which wakes the parked reader (see the per-fd routing entry).
  - **Structured concurrency** — `join_all`, and a scope that joins-or-cancels
    its children when the parent returns so a worker can't leak (the LSP `serve`
    drain does this by hand); ties to "exit semantics for surviving spawned
    fibers".
  - **Bounded concurrency** — a semaphore /
    `parallel_map(items, concurrency, f)`, buildable on a token channel today.
  - _No `Mutex`/lock is warranted:_ cooperative single-threading makes
    shared-state mutation between yield points race-free; a lock only matters to
    hold a section _across_ a yield, which is a one-token semaphore.
- **Interpreter performance — profiled (2026-06); the easy wins are in.**
  Probes: the front-end **self-compile** (`thera emit pkgs/cli/main.thera`) ≈ 11.6
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
- **Read accessors that clone whole heap objects** are a recurring hot spot
  (fixed for `list.len`/indexing, GC marking, map reads; `list.len()` is now the
  `ListLen` opcode entirely). Prefer the borrowing accessor; clone only when a
  closure re-enters the heap to allocate/compare.
- **Native resource finalization — GC-owned `Obj::Foreign` (Drop on sweep).**
  Native-backed resources currently live in a process-global registry keyed by
  an `Int` handle the Thera wrapper holds (`std.regex` compiled patterns;
  `std.process` children; `std.fs` open `File`s). The registry is never pruned,
  so a `Regex` that becomes unreachable **leaks** its compiled engine — benign
  for the compile-a-handful-at-startup norm, but unbounded for dynamic
  compilation (e.g. a server compiling user-supplied patterns in a loop).
  `std.fs.File` already follows the guidance below (explicit `close()` frees its
  fd; an unclosed file leaks until exit) — the GC-drop **backstop** is the part
  still missing. The fix is **not** Thera-level finalizers (resurrection /
  ordering / latency footguns) **nor** a finalizer-closure registry, but letting
  a Thera object _own_ the Rust resource: add an `Obj::Foreign` variant that
  holds the resource, and the existing sweep's `*slot = None` drops it —
  **Rust's `Drop` glue is the finalizer**, run exactly when the object is
  collected, with no Thera code and no resurrection. `std.regex` stops using the
  registry/handle: the compiled engine lives in the `Foreign` object the `Regex`
  value points at, and frees when unreachable.
  - **Perf:** per-object free cost is **unchanged** — drop dispatch is static
    per `Obj` variant (no "has a finalizer?" branch); only `Foreign` objects run
    a non-trivial destructor, and they're rare. Allocation is one slab slot like
    any object plus one `Rc` for the resource, only at `compile`. A compiled
    regex holds no Thera `Value`s, so it's also a GC leaf (`for_each_child`
    yields nothing).
  - **The one invariant:** the sweep drops objects **while holding the `HEAP`
    `RefCell` borrow**, so a `Foreign` `Drop` must not re-enter the Thera heap
    (no allocating, no touching `Value`s). True for regex / files / sockets
    (they release memory or OS handles, not Thera objects) — document it on the
    variant.
  - **Impl:** add `Obj::Foreign`; arms in `for_each_child` (none) /
    `heap_bytes`; the `derive(Clone, PartialEq)` won't cover `dyn Any`, so a
    small newtype with manual `Clone` (`Rc` bump) + `PartialEq` (`Rc::ptr_eq` —
    identity). The `str_byte_slice` primitive and the Thera `std.regex` layer are
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
- **Profiling Thera code — planned, staged.** OS-level samplers (`perf`,
  Instruments, samply) are nearly blind to an interpreter: every Thera function
  is the same `run_loop` native frame, and the Thera call stack lives in the VM's
  `Vec<Frame>`. So the runtime grows its own profiler — as CPython
  (cProfile/py-spy), Ruby (stackprof/rbspy), and Lua do. The primary audience is
  **coding agents**, which shifts the design toward _deterministic,
  function-level, flat text_ over flame-graph SVGs and line-level precision.
  1. **In-VM profiler — done (v1).** Implemented as an always-shipping runtime
     feature gated by the **`THERA_PROFILE`** env var (not a compile-time feature
     like `native-stats`; `run_loop` reads it once into a local, so a
     non-profiled run pays one predictable branch — `src/profile.rs`). Per Thera
     function: exact **call counts**, **self + inclusive time** via
     **instruction-budget sampling** (every `THERA_PROFILE_INTERVAL`=1000
     instructions, sample the live frame stack at the loop top), and
     **allocations** attributed via the single `heap::alloc` chokepoint. Output
     is a flat table to stderr at run end, sorted by self-time;
     **deterministic** (instruction-keyed, not wall-clock — two runs are
     byte-identical, what an agent's before/after needs), guarded by a
     presence + determinism smoke in `bin/test.sh`. Because the env var
     propagates to the child runtime and the front-end is itself a Thera program,
     it profiles both a user program (`THERA_PROFILE=1 thera run x.thera`) and the
     front-end's own compilation (`THERA_PROFILE=1 thera check pkgs/cli` — which
     already shows the lexer at ~50% self-time and ~55M allocations, the data
     for the check-perf work). A `thera run --profile` flag is thin sugar to add
     later; line/allocation call-site precision is #2 below.
  2. **Line attribution — enhancement.** A bytecode→source-line table in
     `.thera-bc` (debug info) so a sample/counter resolves to a Thera line. Demoted
     from a v1 prerequisite once we accepted function-level is enough for
     _algorithmic_ issues. The same debug info gives traps a source location and
     backs the test-failure / stack-trace needs.
  3. **OS-profiler integration — JIT tier.** Once Cranelift lands, JITed Thera
     functions are real native frames; emit `perf`'s `/tmp/perf-<pid>.map` or
     `jitdump` (the V8/JVM/.NET trick) so `perf`/samply/Instruments resolve
     them. The deep-dive view; #1 stays the portable always-on view. #1 and #3
     are complementary, not a choice.

  (Profiling the _runtime itself_ — the Rust interpreter/natives — is separate
  and already covered by `cargo` + samply/Instruments and the
  `[profile.profiling]` / `native-stats` setup.)

### Compiler & front-end

- **Prelude-linked test harnesses.** The checker/resolver unit harnesses
  (`errors_of`, `typed_ctx`, …) build a _hermetic_ element model — no imports,
  empty surfaces — so a test can't reference `std.core`: a closure whose
  parameter type comes from a stdlib generic (`List.fold`) resolves its lambda
  param to `Unknown`, and any test touching `Result`/`Option`/`List` methods
  must stub them. Now that the prelude is mature and the loader is fast,
  evaluate giving these harnesses an option to link the real `std.core` closure
  (cached once), so tests exercise the same surfaces the CLI does. Scope the
  decision: which harnesses opt in, the caching story, and whether the
  fully-hermetic mode stays for the resolver/registry-floor tests that
  deliberately assert no-prelude behavior.

- **Resolution — smaller open items.** (Qualified-only + `pub` visibility
  enforcement, the `FileScope` refactor, and owner-correct value _and type_
  resolution — the `TypeId` arc — are all done; see _Changelog_.) Remaining:
  `impl` coherence / orphan rules, selective import (`show`/`hide`), and a
  "module"→"library" terminology sweep.

- **Whole-closure diagnostics — remaining tail.** (Per-file origin + surfacing
  imported-file parse errors are done — see _Changelog_.) Two pieces remain:
  - **Cascade suppression / cause-naming.** When an import fails to parse, its
    dependent symbols may not recover (`greet`'s decl is dropped), so the
    importer still shows a secondary `` `greet` is not a public member `` after
    the root cause. The resolver should distinguish "undefined" from
    "unavailable because its source file errored" and either suppress the
    cascade or name the cause
    (`helper.greet is unavailable: helper.thera failed to parse`). Rides partly
    on **better parser recovery** (recover a decl's _signature_ past a body
    error — see the LSP parser-recovery item) so fewer decls drop in the first
    place.
  - **Check-path closure scope.** `check app.thera` body-checks only the primary
    program, so an error _inside_ an imported body isn't reported by a
    single-file check (directory/project checking covers it, checking each
    file). Defensible as request-scoping, but the eventual target is
    closure-wide computation with request-scoped display. Format target stands:
    `path:line:col: severity: message`, grouped by file, deterministically
    ordered, exit non-zero iff a displayed diagnostic is an error; a
    machine-readable JSON mode can follow.

- **`native type` / `native fn` follow-ups.** (The bodyless `native type` decls
  for the built-ins are done — see _Changelog_.) Open: whether to _gate_
  `native fn`/`native type` to SDK paths (ties to the `@extern` name-check
  item), and the checker leniency that lets a bare field access on an opaque
  value slip to codegen (the existing `type-field-nonstruct` residual).
- **Generics — residual follow-ons.** (Static-method type args, struct/enum
  bound enforcement, and the inference-classification cleanup are done — see
  _Changelog_.) Remaining: enum construction with an _inferred_ (un-annotated)
  argument isn't bound-checked yet (annotated enum use is); a bound isn't
  **propagated** onto an enclosing function's own type parameter
  (`fn f<U>(x: U) -> Box<U>` doesn't require `U: Display`); and
  `expected_arg_types` still handles only the namespace callee head inline.
  (Generics are **invariant by design** — no variance work planned.)
- **Let a user scope shadow a prelude _value_ name.** Today
  `check_shadowed_surface` flags any top-level decl whose name is in the file's
  bare surface (prelude + `as _` imports), so a `pub fn error` collides with the
  prelude `error()` constructor — which is why `std.log` can't expose an ambient
  `error` free function to match `info`/`warn`/`debug`. Relax it for prelude
  _value_ names (free functions / consts): allow the local definition and let
  same-file-first resolution make it win in-file (qualified access — `log.error`
  — already reaches the intended one), so shadowing is permitted though not
  recommended. Keep reserved core **type** names (`is_reserved_type_name`)
  interdicted — a shadowed type name genuinely breaks codegen (the original
  rationale) — and keep flagging `as _`-imported collisions. Unblocks the
  `std.log` ambient `error` TODO.
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
- **Owner-qualified `FuncDef` names (audit CG-D4) — needs a portable file-key
  scheme.** Two libraries' `Point.area` emit identical `FuncDef` names (stack-
  trace / `--entry` ambiguity). _On hold:_ `FuncDef.name` is the only
  compile-time string emitted into `.thera-bc`, and `owner` is an absolute
  canonical path — embedding it would leak home-dir paths and break the
  reproducible `bootstrap/frontend.thera-bc`. Prerequisite: normalize file keys to
  a portable scheme (`sdk:`/`file:`/`pkg:` + relative). Not a miscompile (calls
  resolve by owner-correct index) — observability; revisit on a forcing function
  (real stack traces).
- **Residual owner-blind keying (audit tail).** Two narrow cases stay
  name-keyed, deferred: interface _name_ collisions across libraries, and the
  `native` instance/static method tables (natives only come from SDK core). Plus
  a CH12 residual — an out-of-order labeled/positional argument mix maps by
  index in the checker but in sequence in codegen; fold into a single
  arg-resolution cleanup.
- **Codegen extraction seams (audit CG-R tail).** `codegen.thera` is large; the
  match-compilation and shared closure/free-variable walker seams landed. Still
  to extract: the module-global init subsystem, the infer-oracle / operator
  tables, and the `emit_virtual_call` / `emit_ordered_args` argument-loop dedup.

### LSP

- **Query layer + incremental engine — landed; Phase-3 follow-ups remain.** The
  analysis session (one engine shared by `thera check` + LSP), owner-correct
  value+type resolution, the resolved-library cache with dependency-graph
  invalidation, `type_at` (inference-at-offset), and semantic references/rename
  all shipped (see _Changelog_). The remaining follow-ups, all deferred:
  - **Workspace diagnostics — streaming partial results (for consideration).**
    Backgrounding on a fiber, per-file `resultId` caching (a re-pull re-emits
    only _changed_ files), and a surface-gated refresh nudge (only a
    public-surface edit, not a body edit, triggers a workspace re-pull) all
    landed (see _Changelog_). One optional refinement remains: stream partial
    results via a `partialResultToken` (`$/progress`) as each batch finishes,
    instead of one report at the end, so a huge first scan appears
    progressively. Lower priority — backgrounding already won the
    perceived-performance battle (requests no longer block behind the full
    workspace analysis); this only smooths the _initial_ scan's fill-in, so it's
    worth doing only if that first pass feels slow in practice.
  - **Reconcile `files.watcherExclude` with `thera.exclude`.** The on-disk scan is
    now cached and invalidated by `didChangeWatchedFiles` (see _Changelog_), so
    the watcher is the sole source of truth for on-disk state. VS Code's watcher
    honors the user's `files.watcherExclude`, which the server never sees: a
    directory excluded there reports no events, so a `.thera` file under it is
    scanned once and then frozen at that content for the session — no diagnostic
    ever updates for it. Nothing warns; it just goes quiet. Options: read
    `files.watcherExclude` via `workspace/configuration` and either fold it into
    the scan's prune set (don't analyze what we can't be told about — consistent,
    and the file simply drops out) or report the overlap as a diagnostic. The
    same question in reverse says `thera.exclude`'s `<base>/**` prunes could seed
    the watcher registration, so we don't ask to be told about subtrees we never
    scan. Low priority: the default `files.watcherExclude` covers `node_modules`
    and `.git/objects`, neither of which holds Thera sources.
  - **Primitive-receiver member resolution.** Hover / definition / member
    resolution on a primitive receiver (`"s".split()`) don't resolve — a
    `Primitive` value carries no `TypeId`. Ties to _Primitive vtables_
    (Runtime).
  - **Further renderers — completion, signature help, semantic tokens.** Thin
    query-layer renderers; completion + signatureHelp additionally need the
    parser recovery below.
  - **Segregate intentional-error test fixtures.** Workspace diagnostics surface
    every file's errors — including the conformance fixtures under
    `tests/lang/`, which are _deliberately_ broken (an `xfail` spec, an
    `// expect:` error directive). A server-side `thera.exclude` now hides them
    (see _Changelog_), but that's a blunt path filter the user has to configure,
    and the server still analyzes the files. Better: split "should analyze
    clean" fixtures from "carries intentional diagnostics" ones — by directory
    or a per-file marker the harness already reads — so the workspace scan skips
    the latter at the source, with no exclude glob to maintain and no wasted
    analysis on files whose errors are the point.
- **Parser error recovery for the LSP.** The LSP's normal input is
  _syntactically broken_ code mid-edit; the parser should synthesize a
  best-effort tree (recover past the error) so semantic resolution still runs
  and offers completions/hover. `sync_to_decl` is now **brace-depth-aware** (the
  audit's PA4 — no more phantom top-level `let`s from resyncing inside a broken
  body). **Design + staged plan in [parser-recovery.md](parser-recovery.md):**
  non-fatal `expect` (fill known holes in place so the leaf node survives for
  completion) + an `Expr.Error` placeholder the resolver/checker analyze
  leniently (no semantic cascade) + the finer recovery points still open
  (per-method in impl/interface, statement/block boundary, match-arm, list
  separators) + signature-past-body. (Keep in mind when touching the parser —
  the recent precedence-table refactor preserved the `panicking`/recovery
  structure.)
  - **Dependent feature: `textDocument/completion`.** Autocomplete requires
    navigating a mid-keystroke AST (e.g., `obj.`). Deferring until the parser
    can reliably build an AST that doesn't drop the trailing, incomplete member
    access.
  - **Dependent feature: `textDocument/signatureHelp`.** Surfaces parameter
    names while inside a function call. Relies on the parser correctly framing
    an unterminated call `foo(`, which current coarse recovery struggles with.

### Developer tooling

- **Verify the code snippets in docs.** Nothing checks that a fenced `thera` block
  in `docs/*.md` or a `///`/`//!` doc comment compiles, and they rot silently —
  which is the worst way for them to fail, because a snippet's whole audience is
  someone (or something) learning the language from it. An LLM reading a doc that
  teaches syntax the compiler rejects is precisely the failure this language
  exists to avoid.

  Not hypothetical: the `std.net`/`std.http` arc (2026-07) shipped a module header
  using `loop { … }`, which is not Thera (there is `while`/`for` and no `loop`), and
  `docs/stdlib.md` plus a `server.thera` example both showed `serve(addr, handler)`
  with a named function — the form that motivated the first-class-functions fix,
  and that did not compile when it was written. Both were caught by hand, which is
  exactly the thing that doesn't scale.

  Design notes. The hard part is that a snippet is a **fragment**, not a program:
  most need a wrapper (`fn main`), some need imports, some are deliberately partial
  (`pub struct Router { let /* method+path table */; }`), and some — the sketches
  in `stdlib.md` — describe an API that does **not exist yet**, so "it must
  compile" is the wrong bar for them. So the mechanism needs an opt-in/opt-out
  marker per block, and the interesting question is which way the default points.
  Prior art worth copying: Rust's `rustdoc --test` (hidden `#` lines for the
  boilerplate; ` ```ignore `/` ```no_run ` for the exceptions) and Go's
  `Example_*` functions (real compiled code, with `// Output:` checked). Note
  `tests/lang/` already has most of the harness shape — directive comments, expect
  lines, an xfail escape hatch — so this may be less new machinery than it looks.
  Sequencing thought: doc comments in `sdk/std` are the higher-value half and the
  easier bar (they document code that exists); the `docs/*.md` design sketches are
  the half that needs the opt-out.

- **Doc-comment tooling — convention specced, machinery pending.** The doc
  conventions are defined ([language.md](language.md#documentation)): `///` item
  docs, `//!` file/package docs, plain `//` never extracted; a summary-first
  sentence; a small Markdown subset (fenced code only, no headers, bold-label
  sections); prose params. **`sdk/std/` is migrated** to `///`/`//!` (all 61
  files; a behavior-neutral source change — the lexer skips `///`/`//!` as
  ordinary comments, so it stayed fixpoint-clean). The **trivia side-channel
  prerequisite is now landed** — the lexer surfaces comments (incl. `///`/`//!`,
  classified) on `LexResult.comments` as a source-ordered, parser-invisible list
  (the gofmt positioned-comment model; compile path byte-identical), so they are
  no longer discarded — but every downstream consumer remains **pending** (the
  side channel is collected, then dropped: each `parse_tokens` call site passes
  only `lex.tokens`). The remaining tooling: (1) **attach docs to AST nodes** —
  a pass re-associating each `///`/`//!` comment to the decl it precedes by
  span, threaded onto the AST (or a side table) — the one piece the side channel
  directly unblocks; (2) **LSP hover** surfaces the item/file doc (today
  `hover.thera` shows the signature only); (3) a **doc generator** extracts a
  package's `pub` surface + barrel `//!` into an index for agent navigation (no
  `doc` subcommand yet); (4) **reference resolution + lint** — resolve
  `[Symbol]` references (link them in hover/doc-gen, flag ones that no longer
  resolve), plus a lint for `pub` symbols whose doc only restates the signature,
  and normalization of doc layout. (Not yet migrated: `pkgs/cli/` and
  `examples/`, deliberately deferred — the public API surface was the priority.)

- **Tools — refactorings (suggestion diagnostics + code actions).** Now that the
  ergonomics features have landed (`if let`, `let … else`, `?` on `Option`, the
  Option/Result combinators), the common verbose shapes they replace are
  **mechanically detectable**, so the front-end can suggest (and a `thera fix` /
  LSP code action can apply) the rewrite. These are tracked here but **decoupled
  from the language work** — shipping `if let` does not require building its
  suggester. The candidate refactorings, roughly highest-value first:
  - **`match` → `if let`.** A two-arm `match` whose other arm is a `_ => {}` /
    `None => {}` catch-all (`match X { Some(v) => { … }, None => {} }`) →
    `if let Some(v) = X { … }`. The dominant cascade (~323 sites; ~279 noise
    arms) — the highest-leverage cleanup.
  - **`match` → `let … else`. _Rewriter landed._**
    `let x = match opt { Some(v) => v, None => { …diverge… } };` →
    `let Some(x) = opt else { …diverge… };`. Fires on a plain, unannotated `let`
    whose diverging arm binds nothing (the `else` binds nothing).
  - **`match` → `?`. _Rewriter landed._** A
    `match r { Ok(v) => v, Err(e) => return Result.Err(e) }` (or the
    `Some(v)`/`None => return Option.None` analogue) → `r?`. Parenthesizes a
    low-precedence subject (`match a + b {…}` → `(a + b)?`), since `?` is
    postfix. The corpus had 0 sites (already idiomatic) — but the rule's own
    verbose extractors were the first dogfood:
    `let x = match f() { Some(n) => n, None => return Option.None }` →
    `let x = f()?`.
  - **`match` → combinator. _Rewriter landed._**
    `match opt { Some(v) => Option.Some(f(v)), None => Option.None }` →
    `opt.map((v) => f(v))`; `match opt { Some(v) => v, None => d }` →
    `opt.unwrap_or(d)` / `.unwrap_or_else(…)` (already underused — e.g. json
    `write_object` — so this rewrites existing code too).
  - **`while i < xs.len()` → `for` / `enumerate`. _Lint landed; rewriter not
    built (see below)._** A survey of the 65 flagged sites: **A** — `i` only
    ever appears as `xs[i]` + the increment (15, ~23%) → `for x in xs`; **B** —
    `i` never indexes `xs`, only passed on / used as a bound (6, ~9%) →
    `for i in 0..xs.len()`; **C** — `i` used as _both_ `xs[i]` and for position
    (bounds, first/last checks, parallel `ys[i]`) (44, ~68%) →
    `for p in xs.enumerate() { … p.value … p.index … }`. The C majority was the
    real blocker — it needs indexed iteration, now provided by
    **`List.enumerate()`** (landed; see _Stdlib breadth_). The corpus has been
    **hand-migrated** with it: 47 of the 65 sites converted to
    `for p in xs.enumerate()` / `for x in xs` (a fixpoint-clean, suite-green
    batch), leaving **18** that genuinely don't fit the shape — non-zero start
    (`let mut i = start`), a stepped/conditional increment (`i = i + 2`, argv
    parsers), a compound min-length bound (`while i < a.len() && i < b.len()`),
    a sub-range bound (`… .len() - 1`), a plain count (`while i < 4`), a `Bytes`
    receiver, or a list mutated mid-loop. An **auto-rewriter is still not
    built** (unlike the `match` rules it needs a genuine loop-body rewrite —
    substitute `xs[i]` → the binding and delete the pre-loop `let mut i = 0` +
    the `i = i + 1`, both outside the loop span); the lint flags the shape and
    the migration was done by hand. Deferred: a `zip` adapter for the
    parallel-two-list sub-case (needs the `Pair`/`Tuple` decision below).
  - **Shared machinery — _edit toolkit landed._** Edits are created by
    **AST-guided source-slice reassembly**, not AST pretty-printing: the kept
    sub-expressions (scrutinee/pattern/body) are sliced verbatim from source via
    their spans (comments and all), only the connective scaffolding is
    generated, and each replacement is formatted **as a fragment at the site's
    own indentation** (`fmt.format_fragment(text, indent)` — format at base
    level, then re-indent) so the edit is **localized**: only the rewritten span
    changes, the rest of the file is byte-identical (fmt stays a separate,
    whole-file concern). This avoids needing a faithful unparser — the kept
    regions carry arbitrary code. Landed: `pkgs/cli/edit/edit.thera`
    (`TextEdit` + `apply_edits` + `span_edit` + offset↔line/col +
    `line_indent_at`), `fmt.format_fragment`, the `MatchExpr.origin` marker
    (`Source`/`IfLet`/`LetElse`, retiring the `span.text()` heuristic — a
    desugared node never re-fires), `lint.match_if_let` (structured site:
    scrutinee/pattern/body), and `pkgs/cli/fix/fix.thera` — `if_let_edit` +
    `fix_source` (parse → collect → per-edit format → apply), directly
    unit-tested (incl. comment preservation, a reindent-the-spliced-region case,
    and a minimal-edit-leaves-the-rest-untouched case). Each rule adds a
    structured `lint.match_*` site + a `fix.*_edit`; a single `fix.fix_sites`
    walk emits at most one rewrite per `match` (the rules partition) plus
    `let … else` at the enclosing `let`. The transforms are vehicle-independent;
    a `thera fix` CLI and an LSP code action both drive them.
  - **`thera fix` CLI — _landed, since folded into `thera lint --fix` (2026-07:
    one analysis command, the eslint/ruff/clippy shape; the provisional UX
    resolved)._** Originally `thera fix <file|dir>…` (main.thera) drives the
    machinery: the lint report is the preview, `--fix` applies (an explicit
    target required — it writes). Historical detail (the LSP code action is the
    primary per-site vehicle). `fix_source` loops non-overlapping edit batches
    to a fixpoint so **nested** convertible matches converge (an inner match
    becomes visible once its enclosing match is rewritten — a bug the dogfooding
    surfaced). Rewrites are conservative (precision over recall — the `lint`
    reporters flag a broader set than `fix` safely rewrites): a block-bodied arm
    is left to a human, since moving it into a closure/`else` could drop
    statements or `return` out of the enclosing fn. `unwrap_or` stays eager only
    for a **cheap** fallback (literal/ident/field); a computed one becomes
    `unwrap_or_else`, threading the `Err(e)` binding into `Result`'s closure.
    **Dogfooded** on 8 front-end files (26 sites across
    driver/runner/element/lsp/loader/inference), plus the rule set applied to
    its own fresh `lint`/`fix` code (19 sites — the only `?` sites in the tree).
    That self-dogfood surfaced a latent `if_let_body_text` bug: a bare
    _diverging_ arm body (`Some(_) => return …`) was wrapped as `{ return … }`,
    but a `return` can't be a block tail — now emitted as `{ return …; }`. The
    front-end compiles itself from all the rewritten source with the SDK
    fixpoint byte-identical and the suite green. Some of the corpus is
    deliberately left for the **LSP code action** to dogfood.
  - **LSP code action — _landed (`if let`, `?`, `unwrap_or`, `map`,
    `let … else`)._** `textDocument/codeAction`
    (`pkgs/cli/lsp/code_action.thera`, registered in the server capabilities)
    offers a `refactor.rewrite` action for each rewrite site overlapping the
    request range, driving the same `fix.fix_sites` (each site carries its
    edit + title). The `WorkspaceEdit` is the localized, self-formatted
    replacement (via `format_fragment`), so applying it touches only that span —
    no document-wide reformat. Purely syntactic (parses the open buffer, no
    import closure). Honors the request's **`context.only`**: every action is a
    `refactor.rewrite`, so it is offered only when `only` is absent/empty or
    lists a `.`-separated ancestor (`refactor` / `refactor.rewrite`) — a
    `quickfix`- or `refactor.extract`-only request gets nothing (and skips the
    tree walk). In-process JSON-RPC tests cover offer (`if let` + `unwrap_or`),
    empty, and the `only` filter (ancestor / exact / unrelated / sibling). This
    is the per-site vehicle for dogfooding the rest of the corpus. (Not yet: the
    `while → for` rewriter, which needs a loop-body rewrite.)
  - **First step — a read-only count — _landed._** `thera lint <file|dir>`
    (`pkgs/cli/lint/lint.thera`) walks the parsed AST — purely syntactic, no
    import closure — and reports + per-rule tallies convertible sites. Source
    `match`es are told from desugared `if let`/`let … else` (an
    indistinguishable `MatchExpr`) by the keyword the span starts at — no AST
    marker yet. The rules partition (a `match` fires at most one): empty arm →
    `if let`; error-propagating arm → `?`; diverging arm in a `let` initializer
    → `let … else`; value-returning fallback → `unwrap_or`; both arms re-wrap →
    `map`. Precision over recall, so each tally is a **floor**. **The count,
    this corpus** (`pkgs/cli` / `sdk/std`; `examples` is 0 throughout):

    | rule                  | pkgs/cli | sdk/std | note                                                                               |
    | --------------------- | -------- | ------- | ---------------------------------------------------------------------------------- |
    | `match → if let`      | 255      | 3       | the dominant cleanup, as predicted                                                 |
    | `while i < len → for` | 43       | 21      | locates candidates; some need `enumerate`/`zip` or don't convert (index lookahead) |
    | `match → unwrap_or`   | 38       | 11      | high precision; `unwrap_or` _or_ `unwrap_or_else`                                  |
    | `match → let … else`  | 14       | 0       |                                                                                    |
    | `match → map`         | 11       | 4       | textbook `Some(f(v))`/`None` re-wraps                                              |
    | `match → ?`           | **0**    | **0**   | the codebase already uses `?` everywhere — **no payload**                          |

    Takeaways: `match → if let` (258) decisively justifies a codemod;
    `unwrap_or` (49) and `while i <` (64, with caveats) are worthwhile;
    `let … else`/`map` are modest; **`match → ?` has zero sites, so skip it.**
    Spot-checked for precision (true positives across all rules). Rules plug
    into one rule-agnostic walker; the calling-convention lint (positional arg →
    labeled param) is the next one but needs resolution, not just AST shape.

  - **Ecosystem payoff.** These aren't one-off cleanups: the same
    shape-matching + located-suggestion + auto-fix machinery is what a Thera
    `lint` / `thera fix` is built from, and what the LSP surfaces as code
    actions. Investing here (diagnostics that flag non-idiomatic code, with a
    mechanical fix) pays off for every future idiom, not just this batch — so
    lean into it rather than hand-editing files. Migration of existing code is
    **opportunistic until then** (touch a file, modernize it); the standing
    guard is the lint.

- **Idioms & best-practices guidance (agent-facing).** The language now has a
  canonical form for each common shape (the _Choosing a form_ table in
  [language.md](language.md), and the per-combinator "reach for it when…" docs),
  but that is reference material. The open piece is **prescriptive guidance an
  agent loads** — "write Thera this way": prefer `if let`/`let … else`/`?`/
  combinators over `match`-as-guard, `for`/`enumerate` over `while i <`, the
  doc-comment conventions, etc. Surfaced by the ergonomics sprint, which found
  that a lot of **existing** code predates these features and doesn't use them —
  so idiomatic Thera has to be written down somewhere consulted, not just
  implied. Open question is **where**: (a) a section in
  [language.md](language.md), (b) a separate `docs/idioms.md` (best-practices
  doc), or (c) a **skill / rules file** an agent auto-loads (the most actionable
  for the LLM-native goal). Likely (c) backed by (b) — the rules file doubles as
  the **primer that gets an LLM up to speed on writing Thera**, and is the
  successor home for the (now-retired) ergonomics review's idiom guidance: the
  canonical-form-per-shape table, the `match`-as-guard anti-pattern, and the
  reach-for-it-when rationale behind each combinator. Pairs with _Tools —
  refactorings_: the doc says what's idiomatic, the lint enforces it
  mechanically.

### Language

- **Only an identifier or a field may be a call target.** `maker()(5)` and
  `fns[0](10)` are rejected with `unsupported call target`
  ([codegen.thera](../pkgs/cli/codegen/codegen.thera) → `call_expr`) — an arbitrary
  expression in callee position doesn't compile, so a function value has to be
  bound to a name before it can be called. Equally true of a lambda, so it is not
  about function *references*; it surfaced next to them (2026-07) because a
  reference makes function values easy to produce.

  This is the same spec/implementation shape the first-class-functions gap had:
  [language.md](language.md) §Functions shows `adder(by: 2)` returning `(Int) ->
  Int` as a headline, and the obvious next keystroke — calling it — needs a bound
  name. Decide whether the spec means to allow an expression callee (and if so,
  compile it: the callee is just another operand to evaluate before
  `call.indirect`) or to require the binding, and say which. A conformance test
  under `tests/lang/functions/` should pin whichever.

- Instance level mutability would be easier for agents to reason about. We
  should consider the impact, pros, and cons of switching from field level
  mutability to instance level mutability.

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
  3. **Enforce** — the checker requires a labeled parameter's label and forbids
     a positional argument for it. Flip after the sweep so the corpus stays
     green.
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

- **Generic operators** (`<T: Add>`, operators-as-traits) — the remaining piece
  of the generics arc (bound enforcement + `call.virtual` dispatch on `T` are
  done). This is also where the language's **implicit operator/literal
  lowerings** would gain a Thera-level surface: `==`, `+`/interpolation,
  `[]`/`[]=`, and the `[k: v]` map literal are emitted by codegen straight to
  runtime natives (`eq`, `str_concat`, `stringify`,
  `list_index`/`list_set`/`map_index`, `map_new`/`map_set`) with no named Thera
  method behind them — the one category of addressable behaviour not represented
  in `sdk/std`. Operators-as-interfaces (`Eq`, `Add`, and `Indexable` below) is
  what turns those into ordinary Thera methods; revisit the exact shape then (the
  `[]` half is the _Index operator_ item).
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
  receiver is a compile error (`pkgs/cli/codegen/codegen.thera`). Small–medium,
  self-contained: desugar to a method call reusing static/`call.virtual`
  dispatch (inference resolves `a[i]` from the receiver's index method;
  codegen's two `throw` branches become method-call lowerings; List/Map keep
  their native fast path). Design leaning: a single `Indexable<K, V>` interface
  (one `get`- and one `set`-style method) rather than separate
  `Index`/`IndexSet`. Also a prerequisite for a Thera `Map` (which additionally
  needs map-literal lowering and a native↔Thera-map bridge).

### Language spec punchlist

The standing worklist for keeping the language spec — [language.md](language.md)
and its companion docs — consistent with the implementation. Populated by
periodic self-consistency reviews (the grammar pass, the 2026-07 spec pass, the
2026-07 diagnostics audit) and worked through iteratively: doc-only corrections
are applied directly and recorded below; findings that imply design or
implementation work stay open here until decided.

**Open — design/behavior follow-ups from the 2026-07 review:** none currently —
the review's follow-ups all landed, summarized in the [Changelog](#changelog):
the doc sweep, the eager-`List` + `List.iter()` bridge decision,
`thera test`/`check` LLM-output UX, `collect()`→`to_list()`, named structural
`Debug`, and the OOM/stack-overflow traps.

### Type system punchlist

Findings from the 2026-07 type-system review (a design-completeness pass over
the implemented system; every hole it found was verified empirically — each
checked clean but went wrong at runtime). Most are now closed (see _Changelog_);
what remains below is deferred with findings, or an open design call. The review
also settled the "formal treatment?" question: no lambda-calculus formalization
— the system is simple enough to specify in prose, and `Unknown`'s deliberate
leniency makes the classical soundness theorem false by construction; the spec
(language.md §Generics / §Assignability) plus the `tests/lang/` conformance
suite are the vehicle.

**Open — targeted checker fixes.** The three local, low-risk fixes from this set
are landed (see _Changelog_ → _Type-checker holes closed_); the one below is the
outlier — the spike showed it is _not_ local, so it is deferred with its
findings recorded.

- **`TypeParameter` → concrete assignability** — _deferred; spiked 2026-07._
  `fn f<T>(_ x: T) -> Int { return x; }` checks clean and traps at the call: a
  `T`-typed value flows into a concrete-typed position. The leniency is only
  needed concrete-→-`T` (instantiation, validated at call sites); a bare `T`
  source against a concrete target should be an error.

  **Spike (naive narrowing = remove the source-side `TypeParameter → true` in
  `is_assignable`): not viable.** Over the whole corpus it produced 13 new
  errors — **1 genuine hole** (the planted `fault-type-mismatch` test) and **12
  false positives** in legitimate code, in three patterns:
  - **A. Bounded `T` → its bound** (5) — `sorted<T: Ord>` passing a `T` where
    `Ord` is expected. `T: Ord` _is_ an `Ord`, but `is_assignable` has no bounds
    context.
  - **B. Type param under function contravariance** (7) —
    `xs.fold(0, (acc,x) => …)`: the lambda `(Int,T)->Int` vs `fold<A>`'s
    `(A,T)->A`. Param contravariance flips the _target_ param `A` into _source_
    position in the recursive call.
  - **C. Unbound inference param in generic args** (1) —
    `some.and_then((_n) => Option.None)` bound to `Option<Int>` → `Option<U>` vs
    `Option<Int>`; `U` should unify to `Int` but `None` pins nothing.

  **Why it can't live in `is_assignable`:** source-side `TypeParameter` leniency
  is load-bearing _inside the recursion_ — B and C arise only deep in it
  (function contravariance, generic-arg pairing), not from "using a `T` value as
  concrete." The real hole is a value whose type is _exactly_ `TypeParameter(T)`
  in a value-flow position (return / assign / arg) at the **top level**.

  **Recommended approach when revisited:** a dedicated check at the value-flow
  sites (`check_return`, `expect_type` for let/assign/args), **not** in
  `is_assignable`, that fires only when the source type is a _bare_
  `TypeParameter` (excludes B/C — their sources are `(…)->…` and `Option<U>`,
  never bare) and is **bounds-aware** — a `T: Ord` source satisfies `Ord` and
  its supers (excludes A). Bounds live in the checker's `type_param_bounds` (the
  table the unbounded-`T` method fix reads), which is why the check must be at
  the site, not in `is_assignable`. Residual false-positive risk: ~zero.

  **Why deferred:** the corpus has **zero** real instances of the hole (only the
  planted test), it can't cause memory unsafety (it traps cleanly with the
  honest `runtime type error: expected Int, found String` message — see the
  _Honest tag-mismatch traps_ changelog), and the fix needs bounds threaded to
  the value-flow checks — a materially larger, lower-payoff change than the
  other three targeted fixes (all landed). Revisit if a forcing case appears.

**Open — design decisions:**

- **Honest wording for native-argument type mismatches.** _(Runtime, follow-up
  to the tag-mismatch trap split — see \_Changelog_.)\_ The interpreter's own
  tag-checked pops now raise `Trap::TypeError` ("runtime type error: expected
  Int, found String"), but the native arg-checks (`str_contents`,
  `as_int`/`as_double`, `with_bytes`) still raise `Trap::Bug` ("internal
  error"). Converting them is blocked only on unthreading their `who` context
  param from ~100 call sites — do that, then route them through `TypeError` too
  (module-free type names, since natives have no `Module` handle).

**Deferred type-shape items:**

- **A first-class `Range` type** (deferred — no forcing function). The internal
  range cleanup landed (see _Changelog_); making `Range` a _nameable value type_
  (store, pass, return, `.contains`/`.to_list`) has no corpus demand — all range
  use is `for i in a..b`. Revisit when a feature wants ranges as values, the
  obvious one being range-based slicing (`list[2..5]`), which needs slice
  support anyway.
- **Type aliases** — **deferred indefinitely, by design.** An alias is a
  _transparent_ name (`type Fallible = Result<Void, Error>`), which adds exactly
  the indirection Thera's local-reasoning thesis is built to avoid: an LLM seeing
  `Fallible` must resolve it elsewhere. The verbosity win (the top candidate,
  `Result<Void, Error>`, is frequent but not _complex_) doesn't outweigh giving
  a reader more work; genuinely meaningful nested types are better served by a
  nominal `struct`. Recorded as a language non-goal in
  [language.md](language.md). Would need a very compelling use case to reopen.

The review's holes are all closed or deferred-with-findings above; the landed
fixes are summarized in the [Changelog](#changelog) (variance, `Never` + tail
`throw`, and the four type-checker holes).

### Diagnostics punchlist

The still-open tail of the 2026-07 diagnostics review; everything else landed —
see the Changelog's **Diagnostics review** entry for the arc summary. The
warning machinery is live: add rules one at a time, corpus-sweeping each.

- **Effect-free expression statements** (`1 + 2;`) — the last warning candidate
  from the original review.
- **Referencing a `_`-prefixed local** — the marker declares the binding
  intentionally unused (language.md §Variables), so a reference contradicts it;
  a future warning candidate (the fix is renaming the binding).
- **Did-you-mean suggestions** on `undefined name` / `no method` — cheap (edit
  distance over the known-name set), modest-but-real LLM value.
- **A semantic to decide:** qualified access through an `as _` import works
  today (the loader binds the derived namespace for unqualified imports too —
  `import std.path as _;` + `path.join(…)` compiles, and `unused-import` counts
  it as a use); either bless that in the spec or reject it.

Already tracked elsewhere, not repeated here: imported-body check scope, cascade
suppression, calling-convention enforcement, native-arg trap wording, and the
deferred bare-`TypeParameter` narrowing.

### Networking punchlist

The agreed order is **(1) per-fd routing → (2) `select` → (3) TLS**. The first two
are known gaps in the phase-4 poller that landed with the `std.http` arc (see the
Changelog's **Readiness poller** entry), and both are things a real server hits
rather than latent tidiness: the poller is correct, but not yet _scalable_ or
_cancellable_. The third finishes the client. **(1) and (2) are done**; TLS is
next.

1. **Per-fd wakeup routing.** _Done (2026-07)._ Readiness events route by socket
   handle — which already *is* the `mio::Token` — so an event wakes only the
   fibers parked on that socket instead of every socket-parked fiber. Measured on
   the 20-connection `std.net` suite: spurious retries down ~27% (`socket_accept`
   67→48, `socket_connect_finish` 68→50). That understates it — the win scales
   with connection count, which is the point: `wake_all_poll` was O(parked) per
   event, exactly the shape a server holding many idle connections hits.

   **The catch, and it is the interesting part:** the coarse wake was an
   accidental safety net. A fiber parked on a socket that *another fiber closes*
   used to be rescued by an unrelated socket's event waking everyone. With routing
   it would park forever, because a closed socket produces no more events of its
   own — a hang, not an error. So `socket_close` now explicitly wakes its waiters
   (`wake_poll_waiters`); they retry, find the handle gone, and get a closed error.
   This was confirmed the hard way: the probe hung at exactly that point when built
   without the wake. Pinned by `closing_a_socket_wakes_a_fiber_parked_on_it`.

   That also makes close-from-another-fiber the **only** cancellation mechanism
   there is until (2) lands, so it is a supported pattern rather than an edge case.

   Left coarser on purpose: fibers sharing a handle (a reader and a writer) are
   woken together, and the one whose direction didn't fire re-parks. Splitting by
   direction as well as handle would remove that second-order waste; not worth the
   state until a profile says so, since the first-order win is all in the handle.

2. **Socket timeouts.** _Done (2026-07)._ `select` landed and timeouts fell out of
   it: `fiber.select([sock, fiber.after(d)])`, or `fiber.with_timeout(work, d)`.
   A `TcpStream` is selectable on readability, probed non-destructively with mio's
   `peek` so the `read` that follows still sees the bytes.

   The runtime piece is `ParkRequest::Multi`, which lists a fiber in `blocked` +
   `timers` + `poll_blocked[h]` at once. Two safety properties hold it up, and
   **both were verified by deliberately breaking them**, since a test that passes
   either way is worthless here:
   - **Idempotent waking** (a `queued` flag behind one `make_ready` choke point).
     Without it, one fiber that sends on a channel *and* closes a socket wakes a
     selector twice before it is scheduled, and the scheduler traps —
     `scheduled a running or finished fiber`. Reachable precisely because
     `socket_close` wakes waiters during another fiber's run, unlike timers and
     poll events, which only fire from the idle loop when nothing is queued.
   - **Sweep-on-schedule** (`unlist`). Without it, a select's *losing* deadline
     stays live and fires at whatever the fiber parks on next: a later 80ms sleep
     returned in 0ms. Worse in principle — a stale wake landing on an `Await`-parked
     fiber would resume it before its syscall finished, handing back the discarded
     placeholder as the result.

   Still open, and the honest limit: **the timed-out work is not cancelled**,
   because a fiber cannot be killed. `with_timeout` bounds the wait, not the work.
   Releasing the resource is the caller's job — for a socket, close it.

Ordering: (1) and (2) are done; **(3) TLS is next**, and is now the only thing
between `std.http` and complete.

### Scheduler punchlist

Findings from a 2026-07 design review of fiber waiting/waking (the park
taxonomy, the readiness poller, `select`). The review's verdict was that the
design is sound — the two `Multi`-park invariants (idempotent waking,
sweep-on-schedule) are enforced at single choke points and mutation-tested — so
these are the gaps *around* it, not problems *in* it. None is a correctness
bug; all three grow teeth with a long-running server, which is where the
networking arc is headed.

1. **Selects with no `Progress` source still join the coarse `blocked` list.**
   A `Multi` park adds the fiber to `blocked` unconditionally, so a
   `select([sock, fiber.after(d)])` — socket + timer, no channel or join
   anywhere in it — is woken by *every* channel send/receive/close and fiber
   completion in the program, re-probes all its sources, and re-parks. That is
   the per-fd-routing problem (item 1 above) reappearing one layer up: N
   connections each select-waiting with a timeout do O(N) spurious re-probes
   per channel operation. Cheap targeted fix when a profile asks: the Thera-side
   `select` already knows whether any source returned `SelectSource.Progress`,
   so `_select_park` can take that as a flag and skip `blocked` when none did.
   The full fix is per-resource waiter lists for channels and joins (already
   promised in `Scheduler::complete`'s doc), which would retire `wake_all`'s
   thundering herd entirely.

2. **Select deadlines mix the wall clock with the monotonic clock.**
   `fiber.after` captures `time.now_millis()` (wall) and `Timer.is_ready`
   re-checks against it, but the scheduler's timers are `Instant`s (monotonic),
   so `select_park` converts wall→monotonic on every park — while `time.sleep`
   is `Instant` end-to-end. A wall-clock step forward fires select deadlines
   early; a step backward extends them (the probe loop re-parks with a
   recomputed remainder — it converges, no hang, but an NTP step is added to
   the wait). `with_timeout` semantics want monotonic throughout. The wrinkle:
   `SelectSource.Deadline` needs an *absolute* time that stays fixed across
   re-parks, so the fix is a runtime-provided monotonic clock (millis since
   program start, say) for `Timer` to capture instead of the epoch — a new
   native and a `std.time` surface decision, hence parked here.

3. **The scheduler never reclaims fibers or channels.** `fibers` is
   deliberately never compacted (stable ids), every `Done` fiber's result stays
   GC-rooted forever (`gather_scheduler_roots`), and `channels` only grows.
   Invisible in every current program, but the server pattern — one long run of
   `while true { accept; spawn(handle) }` — leaks a fiber slot plus its rooted
   result per connection served. Needs a design decision, not a patch, because
   join-ability is what blocks reclamation: a `Done` fiber can't be freed while
   a `join` might still come. Candidate shapes: make `join` one-shot and
   reclaim on it, plus a story for never-joined fire-and-forget fibers (drop
   the result on completion when no join can observe it, or an explicit
   detached spawn); refcounting `Fiber<T>` handles has been avoided so far.
   Channels want the same eventually (`close` could free the slot once
   drained). **This is the biggest of the three** — it gates calling the
   `std.http` server production-shaped.

Also noted by the review, one comment's worth of insurance: nothing enforces
that an `IoFinish` closure captures no `Value` (they aren't GC roots; all ~25
current `park_syscall` call sites capture only owned Rust data, and the
`build: FnOnce(T) -> Value` shape encourages that). Worth a sentence on the
`IoFinish` type when next touched.

## Runtime staging (longer view)

See [architecture.md](architecture.md) for the design behind each tier.

1. ~~Tree-walker POC (settle semantics); define the bytecode IR.~~ _Done._
2. ~~Tier-0 interpreter + precise non-moving mark-sweep GC.~~ _Done_ — runs real
   Thera apps with fast startup.
3. **Cranelift JIT tier** for hot functions (or trial copy-and-patch); decide
   the JIT GC-root strategy here. This is what forces the tagged→untagged
   value-representation move (interpreted and compiled frames must share a
   representation).
4. **AOT via `cranelift-object`** later — single-binary distribution; optional,
   not on the startup-critical path.

## Changelog

Brief summaries of finished arcs; design details live in
[architecture.md](architecture.md) / [language.md](language.md) and the linked
conformance specs. Newest first.

- **LSP: the workspace pull is held open — an idle server does nothing at all**
  (2026-07). The tail of the idle-CPU arc (next entry): even with an unchanged
  pull at ~18ms, the client re-issued it every 2s forever, because
  `vscode-languageclient` re-arms its workspace-pull timer after every
  *settlement* — the only lever is not settling. The spec plans for exactly this:
  clients implement partial-result progress for the workspace pull "to allow
  servers to keep the request open for a long time", and re-trigger if it closes.
  So a pull carrying a `partialResultToken` now gets its report as `$/progress`
  and **no response** (`Server.open_pull`); the request settles only on
  supersession or cancel (empty final result / `RequestCancelled`) — and
  `shutdown` supersedes an in-flight scan then settles, so the client is never
  owed a response. Idle is now genuinely zero: no timers on either side, the
  dispatch loop parked on stdin.

  Held open, the stream becomes closed files' **only** channel — verified in the
  client source: `workspace/diagnostic/refresh` re-pulls open *documents* only,
  never the workspace. So workspace-affecting changes (surface edits, closes,
  watcher events, exclude changes) now stream **delta batches**: only files whose
  diagnostics changed (partial results merge per-uri, so omission means
  unchanged — an idle workspace streams nothing), plus **retractions** (an empty
  `full`, no `resultId`) for files that left the scan — deleted, newly excluded,
  or a closed loose file — which nothing else would ever clear. Deltas diff
  against `ws_emitted` (what the workspace channel last delivered), deliberately
  not `diag_reports` (which document pulls also update): the client discards a
  closed buffer's diagnostics, so `close_document` invalidates the file's
  `ws_emitted` entry — not removes it; the entry is what marks a departed file
  as needing retraction — forcing a full re-send. A change racing the initial
  scan is covered by a `delta_pending` flag the worker drains before finishing.
  Clients that send no token (and the in-process tests) keep the
  respond-and-re-pull path unchanged.

  The follow-up (phase 2) made the pulls that *do* still happen — the initial
  one, and every re-pull for a polling client — skip even the per-file
  byte-compare when nothing changed: `input_generation` counts every input
  mutation (edit, close, watcher event, roots/exclude change — exactly the five
  entry points), the `ScanCache` is stamped with the generation its texts were
  captured under, and a matching stamp reuses in O(1). The compare stays as the
  fallback tier — it catches an edit that *reverted*, and a match there
  re-stamps. Measured on this repo: an unchanged re-pull 43ms → 13ms (the
  remainder is emit + serialize). Pinned by poisoning the cache so the two tiers
  disagree — only the generation tier can serve the marker. The clock also
  closed a latent race: `disk_files` parks across its reads, so a watcher
  eviction landing mid-build was silently overwritten by the finishing build —
  reinstating the stale text until the file's next event; the build now stores
  its cache only if the generation didn't move.

  Phase 3 closed the arc with the settle-code conformance polish: a superseded
  scan now answers with the code the diagnostic-pull spec assigns its cause —
  `RequestCancelled` (-32800) when the client cancelled that very request,
  `ServerCancelled` (-32802) with
  `DiagnosticServerCancellationData { retriggerRequest: false }` when a newer
  pull replaced it or the session is shutting down (the pre-3.17
  `ContentModified` is gone). Distinguishing the causes required tracking the
  scan's request id (`Server.scan_id`), which also fixed a latent sloppiness:
  `$/cancelRequest` used to bump the generation *blindly*, so a cancel for any
  already-completed request killed an innocent scan — cancels now match by id,
  and an unrelated one is ignored per the protocol. Behavior-neutral for
  vscode-languageclient (it re-arms its workspace timer on any settlement and
  only reads `retriggerRequest` on document pulls), so this is truthfulness for
  other clients, not observable behavior for VS Code.
- **LSP: an idle server costs ~nothing (and stops going stale)** (2026-07). An
  idle `thera lsp` sat at 40–80% CPU with the editor untouched. Not a scheduler
  spin: the server measures 0% idle and never wakes itself. The cause is that
  `vscode-languageclient`'s `pullWorkspace` re-arms `setTimeout(…, 2000)`
  unconditionally after every reply — idle or not, forever — so a pull's cost is
  paid continuously. `resultId` caching (already correct here) only saves
  re-*sending* items, never re-*computing* them; and our supersession reply
  (`ContentModified`, -32801) is swallowed by the client as a resolved default,
  so neither of the classic runaway-pull traps applied. The client's design
  simply assumes an unchanged pull is cheap. Three fixes, warm pull 2.19s → 60ms
  (~52% CPU → ~3%): (1) `fs.read_dir` — the walk stat-ed every entry to ask "file
  or directory?", which `readdir` already answers (1593ms → 255ms); (2)
  `thera.exclude` prunes subtrees during the walk rather than filtering files
  after it, and this repo excludes `runtime/target/**`; (3) a content-keyed scan
  cache — identical texts in, identical diagnostics out, so an unchanged pull
  skips checking entirely. Along the way this turned up a **pre-existing
  staleness bug**, reproduced on the prior commit: `parsed_primary` keys the parse
  cache by path and evicts only on overlay events, so a file changed on disk with
  no buffer open (a branch switch, a rebase) kept serving its first-ever parse for
  the life of the session. Fixed by registering `workspace/didChangeWatchedFiles`
  (dynamic registration only — there is no static capability) and invalidating on
  each event. With the watcher in place the scan itself is cached too (it was
  re-walking and re-reading every file each pull to rediscover what the watcher had
  already reported), leaving a warm pull at **~18ms — ~0.9% of a core**. Every
  cache invalidation was verified load-bearing by removing it and watching a test
  fail. Measurement note: the first probe polled for replies on a 50ms `sleep`,
  quantizing every timing to the next tick — it reported a flat "55ms" that hid
  both the cost and the improvement. Wait on an event, not a poll.
- **Function references** (2026-07). A named `fn` is now usable as a value —
  `apply(double, 21)`, `let f = double`, `return stringify_it` — closing a
  **spec/implementation divergence** rather than adding a feature:
  [language.md](language.md) §Functions already opened "Functions are first-class
  values" and its type table already called `(Int, String) -> Bool` "the type of
  lambdas **and function references**". Only lambdas worked; a bare `fn` name in
  value position failed in codegen with `not a local variable: double`.

  Found while building `std.http.server`, where a handler is exactly the case for
  naming a function and handing it over — `serve(addr, my_handler)` is the form
  docs/stdlib.md's own sketch showed, and it did not compile.

  Two halves, and the second mattered more than the symptom suggested:
  - **codegen** — a reference is a closure over the function's own unit with no
    captures, i.e. the same `closure.new` a lambda emits, appended to the
    local→const→global resolution chain (a name is a function reference only if it
    is nothing else, and one name space per scope means it cannot be two).
  - **inference** — `infer_ident` fell through to `Unknown`, which is lenient on
    both sides, so the reference was not merely uncompilable but **untyped**:
    `apply(takes_string, 21)` against `(Int) -> Int` type-checked and only died in
    codegen. A reference now carries its function's signature, so the mismatch is a
    proper argument-anchored error (`expected (Int) -> Int, found (String) -> Int`).
    Generic functions stay `Unknown`: `show<T: Display>` is a family, not a type,
    and choosing a member needs an instantiation the position doesn't supply.

  Pinned by `tests/lang/functions/fn_reference.thera` (the xfail written when the
  gap was found, now a passing test) and `fn_reference_reject.thera` (the typing).
  Uncovered next door, still open: only an identifier or a field may be a **call
  target** (`fns[0](10)` doesn't compile) — see _Open work → Language_.

- **Readiness poller + `std.net`** (2026-07). Fibers phase 4, and the socket
  layer under the coming `std.http`. `mio` joins as the 4th runtime dependency —
  the call was never "dep vs. no dep", since hand-rolling `kqueue`/`epoll` needs
  `libc` for the syscalls anyway: the real cost was one extra crate (`log`)
  against two unsafe backends and no windows. Sockets are **non-blocking** and so
  never touch the phase-3 worker pool — a blocking `accept` would pin one of its
  four threads indefinitely, and four would stall every other fiber's I/O.
  `EWOULDBLOCK` parks the fiber (`ParkRequest::Ready`) and the `call.native`
  re-runs on readiness: `BlockRetry`'s discipline, woken by the poller. The
  driver keeps **one** wait point (`poll()`, timer-bounded, with worker
  completions interrupting via a `Waker`), so there is no poller thread and the
  runtime stays single-threaded.

  Two findings made it smaller than budgeted. Sockets need **no readiness state**
  despite mio being edge-triggered — the usual lost-edge hazard can't occur when
  a fiber parks only *after* its syscall returned `EWOULDBLOCK`, since any
  earlier edge was stale by construction; the syscall is the ground truth, which
  promotes "attempt before parking" to a correctness rule. And because the ops
  never leave the Thera thread, sockets skip phase 3's take-out/return discipline
  entirely, so concurrent read + write on one socket from two fibers works
  (unlike a `File`). The retry does make **idempotency** a rule: `write` returns a
  *count* rather than writing all (a write-all native would re-send on retry),
  and `connect` splits into `socket_connect` + `socket_connect_finish` because
  re-issuing `connect(2)` on a pending fd reports `EALREADY`. DNS stays on the
  worker pool — blocking, but bounded.

  `std.net` is deliberately **provisional** (docs/stdlib.md § "not in core"): a
  Go-shaped `listen`/`connect`/`accept` with `TcpStream` as an ordinary
  `Reader`+`Writer`+`Closer`, carrying only what `std.http` needs — no UDP,
  deadlines, half-close, socket options, or TLS. Its first client already paid
  off: the accept loop drove the retry-on-wake shape, and exposed that **`io.copy`
  assumed writes never go short** — true of files, false of sockets, and a silent
  byte-dropping bug for any short-writing `Writer` (fixed; `io.write_all` added
  and `copy` routed through it). Open tail: _Open work → Networking punchlist_.

- **Diagnostics review — arc complete** (2026-07). The final rung of the staged
  language review (grammar → spec → type system → diagnostics), asking: do the
  diagnostics cover the language surface and prevent invalid code from being
  written? Method: inventory every diagnostic each phase can produce (~80
  parser, ~50 checker, ~25 codegen emit-time), then verify suspected holes with
  41 invalid-program probes; every new diagnostic was corpus-swept against all
  159 production files with a zero-false-positive bar. What landed (each with
  its own entry below): the **checker holes closed** — definite-return analysis
  (+ implicit `Ok(void)`), pattern arity, member uniqueness, interface
  default-method body-checking, and the emit→check promotion (for-iterables,
  index receivers, range position, non-function callees, impl targets); **unused
  `Result` as a hard error** with `let _ =` as the discard idiom (the review's
  one design call, decided by corpus survey); **same-block rebinding and
  self-imports rejected**; the **warning tier** — severity plumbing, exit-0
  policy, kebab-case rule names, `// ignore: <rule>` suppression — with four
  rules (`unused-import` incl. `as _` attribution, `unreachable-code`,
  `unreachable-arm`, `unused-variable`) and the `_`-prefix intentionally-unused
  convention spec'd; and **`thera fix` folded into `thera lint --fix`**. Decided
  along the way: hard errors stay ID-less (message + span — a `CAxxxx` code is
  context noise for LLMs); kebab-case slugs only where selection is meaningful
  (warning rules, lint rules). The sweeps themselves paid for the arc: two
  dropped-`Result` bugs, seven dead imports, and a handful of dead locals found
  and fixed in the corpus. The open tail lives in _Open work → Diagnostics
  punchlist_.

- **`unused-import` covers `as _` imports; `_`-prefix spec'd** (2026-07). The
  arc's final warning extension. An `as _` import is now attributed **by
  surface**: it is used when any name it provides occurs in the file, or when
  its derived namespace is used qualified (which works today — see the open
  wrinkle), and flagged (``unused import: nothing from `x` is referenced``)
  otherwise. No new plumbing: the loader already records every import's public
  surface — barrels flattened — in `file_namespaces` under the derived
  namespace; with no surface recorded (hermetic check, unresolved import) the
  rule stays silent. The use-walker also collects bare type-ish names now
  (`NamedType.name`, struct-literal type names, impl targets and interface
  names, super-interfaces, generic bounds), which the namespace-only attribution
  never needed. The sweep found **five genuinely dead `as _` imports** (removed)
  and one spelling fix (`lsp/workspace.thera` imported `std.path as _` but used
  it qualified — now a plain import). And language.md §Variables now specs the
  `_`-prefix convention: a leading underscore declares a local intentionally
  unused; referencing one contradicts the marker (a future warning candidate,
  tracked above). Spec `warn-unused-import` (new `as _` fixture); language.md
  §Variables, §Errors and warnings.

- **`unused-variable` warning** (2026-07). The fourth warning rule — flagged in
  the review as the false-positive-prone one, so the exemptions carry the
  design. Scope: **statement `let`s only** — parameters and pattern bindings
  (their names are often fixed by a signature or an arity) and module globals
  (cross-file consumers) are out. **`_`-prefixed names are exempt**
  (`let _hint = …`), the Rust/Dart/TS intentional-discard convention LLMs
  already know, alongside `let _ =`. The use-scan reuses the unused-import
  identifier walk — _any_ later occurrence of the name counts, including an
  assignment target and a use that actually resolves to an inner shadow — so the
  rule under-reports but never flags a referenced binding. One reverse pass per
  block keeps it O(n) and scope-correct: uses before a `let` can only refer to
  an outer binding, so an unused inner shadow is still caught. Zero hits on
  production code; the `let x = <expr under test>;` scaffolding idiom in 10
  conformance fixtures and 22 hermetic checker tests was renamed to `_`-prefixed
  form — the exemption's first dogfood. Spec `warn-unused-variable`; language.md
  §Variables, §Errors and warnings.

- **`unreachable-code` + `unreachable-arm` warnings** (2026-07). The second and
  third warning rules, both dead-code signals on the existing exit-analysis
  machinery. **`unreachable-code`**: a statement (or block tail) after one that
  always transfers control — `return`/`throw`, `break`/`continue`, an `if` whose
  branches all exit, a break-less `while true` (reusing `stmt_always_exits`, so
  it inherits its lenient direction) — reported once per block, on the first
  dead statement. **`unreachable-arm`**: a match arm no value can reach — any
  arm after a catch-all (`_` or a binding; full coverage counts the same: all
  variants matched, or both `Bool` literals), a variant already fully matched by
  an earlier arm (bare name, or a constructor whose sub-patterns all bind —
  sub-position identifiers always bind, codegen's rule), or a repeated literal
  (kind-prefixed keys; interpolated strings are never keyed). A _refutable_
  constructor arm (`Some(1)`) claims nothing, so later arms for its variant stay
  reachable — under-reports, never flags a live arm. Source matches only
  (`if let`/`let … else` fabricate their own wildcard arm). Zero corpus hits on
  production code; the two deliberately-broken fixtures the rules also caught
  now carry ignore comments. `stmt_span` moved from the parser to `ast.thera` as
  the third span accessor. Specs `warn-unreachable-code`,
  `warn-unreachable-arm`; language.md §Errors and warnings.

- **Warning-severity diagnostics + `unused-import` + `// ignore:` suppression**
  (2026-07). The diagnostic model's dormant `Severity.Warning` gained its first
  producer and full plumbing. Semantics: an error is invalid code (blocks
  `run`/`emit`/`test`, exits 1); a **warning** is legal-but-probably-a-bug —
  `thera check` and the LSP report it (`path:line:col: warning: … (<rule>)`),
  nothing gates, exit stays 0, and the summary appends `; N warnings`. Every
  gate now filters by severity (`diagnostic.error_count`), so warnings ride the
  same diagnostics list end to end. Warnings carry **kebab-case rule names** and
  are suppressable per site with `// ignore: <rule>` on the line or the line
  above — implemented as a source-reading post-filter (spans carry the file
  text), the comment side-channel's first compile-path consumer in spirit with
  no threading. First rule: **`unused-import`** — a namespace import never
  referenced (any identifier occurrence counts: qualified calls, qualified
  types; exempt: `pub import`, `as _`, and a test file's module-under-test,
  whose surface arrives bare). The corpus sweep found two genuinely dead imports
  (removed) and one design-relevant false positive (the test-file exemption,
  added); seven `tests/lang` fixtures whose imports are the _subject_ now carry
  ignore comments — the suppression mechanism's first dogfood. The conformance
  runner learned `// expect warning:`. Specs `warn-unused-import`; language.md
  §Errors and warnings.

- **Same-block rebinding + self-imports rejected** (2026-07). Two wrinkles from
  the diagnostics review. A second `let x` in the **same block** is now a check
  error
  (`` `x` is already bound in this block; rename it (an inner block may shadow) ``)
  — shadowing remains legal from any nested scope (a block, an arm, a loop
  body), a body `let` may shadow a parameter, and `_` never collides. And a
  direct **self-import** (an import path resolving back to the importing file)
  is rejected at the import decl (`a file cannot import itself`); longer cycles
  through other files stay legal. Zero corpus hits for either. Specs
  `var-same-block-rebind`, `mod-import-self`; language.md §Lexical scope,
  §Import resolution.

- **Unused `Result` is a check error; `let _ =` discard** (2026-07).
  Diagnostics-punchlist item 4, the review's one design call. A `Result` in
  statement position — `might_fail();` — silently dropped its failure (the
  errors-as-values analogue of an unchecked exception vanishing; a bare
  `testing.assert_eq(a, b);` without `?` "passed"). It is now a **hard error**
  (`unused \`Result\`: handle it (\`?\`, \`match\`, \`if let\`) or discard it
  explicitly with \`let _ = …\``), paired with the new discard idiom: `let _ =
  expr;` evaluates and discards — no binding, side effects run, an annotation still checks. Scope is deliberately **`Result`-only**: the corpus survey found dropped `Result`s were 2-for-2 genuine bugs (both in `fiber_test`, now fixed — the pipe-writer fiber asserts its write count) while dropped `Option`s were 8-for-8 idiomatic `pop()`/`remove()`effect-calls, matching Rust's must-use line. Hard-error over warning because agents chase exit codes, and pre-1.0 there is no ecosystem to break. Specs`err-unused-result`, `var-wildcard-let`; language.md §Error handling + §Variables; grammar.md `letStmt`.

- **Check/emit parity + interface default-method bodies** (2026-07).
  Diagnostics-punchlist item 3, closing the punchlist's checker holes. Interface
  **default-method bodies are now body-checked** — previously
  `check_interface_decl` validated signatures only, so a default body could
  reference undefined names, drop paths, or misuse types and still check clean
  (surfacing only at emit or runtime). Methods now route through `check_fn` with
  an interface-typed `self` (only the interface's own surface visible;
  definite-return applies), spec'd in language.md §Default methods. And the
  statically-decidable **emit-only errors moved into `check`**: a `for` iterable
  must be a range/`List`/`Iterator`-conformer (`for x in 5`), only `List`/`Map`
  are indexable (`p[0]` and `p[0] = v` on a struct; `String` keeps its tailored
  hint), a range outside a for-loop head is positional error not a value, a
  bare-name callee must be a function (`let x = 5; x(3);` — previously caught by
  _neither_ phase), and an `impl` block's target type must exist
  (`impl Display for Ghost` previously checked clean and ran). Zero corpus false
  positives; the stdlib's Iterator default methods all check clean under the new
  body pass. Specs `cf-for-iterable`, `expr-range-value`, `expr-index-receiver`,
  `expr-call-non-fn`, `iface-impl-target`, `iface-default-body`.

- **Pattern arity + member uniqueness** (2026-07). Diagnostics-punchlist item 2.
  A constructor pattern now binds exactly its variant's field count —
  `Some(a, b)` (trapped `enum.get: field 1 out of range`), `Two(a)` (silently
  bound a prefix), and a bare payload variant `Some =>` (silently ignored the
  payload) are all located check errors with a
  `match it as \`Some(_)\`` hint — and a pattern binds each name at most once (`Two(a,
  a)`). The member tier gained the one-name-space rule's analogue: duplicate
  struct fields, enum variants, type parameters, parameters (internal names
  \_and_ external labels), impl/interface method names, and struct-literal
  fields are all
  `duplicate … \`x\``errors at the second site (previously silently first- or last-wins). Corpus sweep found exactly one genuine hit — a parser test's`Assign(sp,
  _,
  _)`under-binding the 4-field`Stmt.Assign`— and zero false positives. Specs`cf-match-pattern-arity`, `type-member-unique`;
  language.md §One name space per scope (member tier), §Choosing a form (pattern
  arity).

- **Definite-return analysis + `Result<Void, _>` implicit `Ok(void)`**
  (2026-07). The top hole from the diagnostics review: a value-returning
  function with a non-returning path checked clean — falling off the end after
  `if b { return 1; }` trapped as
  `internal error (malformed bytecode): pc ran off the end` (blaming the
  compiler), a body with no `return` **silently** returned `()` into typed
  positions, and `fn step() -> Result<Void, Error>` ending in a bare `inner()?;`
  returned a raw unit that trapped at the _caller's_ match. Now: the checker
  requires every path through a value-returning function to exit
  (`return`/`throw`; a break-less `while true` counts — the scan is
  lenient-direction only), a bare `return;` in such a function is an error, and
  — the semantic half — a `Result<Void, _>` function completing normally is the
  implicit `Ok(void)` (fall-through and bare `return;` both wrap, mirroring
  implicit-`Ok` on `return <value>`), so the ceremony-free propagate-and-succeed
  shape is _correct_ rather than rejected. Codegen's epilogue also handles a
  forward jump landing past the last instruction (the `pc ran off the end`
  shape, which also bit `Void` functions ending in `if b { return; }`). Zero
  corpus false positives. Specs `fn-missing-return`, `err-implicit-ok-void`;
  language.md §Functions → Definite return, §Error handling.

- **Generic-argument variance — invariant containers, covariant read-only
  builtins** (2026-07). Type arguments were covariant everywhere, so a
  `List<Cat>` was accepted where `List<Animal>` was expected and a `Dog` written
  through the widened alias could be read back as a `Cat` (a real, if narrow,
  soundness hole — the poisoned read runs a statically-dispatched `Cat` method
  on a `Dog`). An invariance spike found the fault line exactly: the only corpus
  reliance on covariance was `Result<T, ConcreteError>` → `Result<T, Error>`
  (the error idiom), never a mutable container. So `is_assignable`'s
  same-constructor branch now partitions by variance —
  `Result`/`Option`/`Iterator` (read-only) stay **covariant**,
  `List`/`Map`/`Set` and every user generic are **invariant** — with no
  `out`/`in` annotations. The one thing that relied on container covariance, a
  polymorphic list literal, now types against context
  (`let pets: List<Animal> = [Cat…, Dog…]` checks each element against
  `Animal`). Spec `gen-variance`; language.md § Variance.

- **Divergence typing — `Never` bottom type + tail `throw`** (2026-07). `throw`/
  `return` inferred `Unknown`, so a diverging branch composed only by leaning on
  `Unknown`'s leniency (conflating "this path exits" with "type hole"). They now
  infer a real bottom type `Never` — assignable to every type, from none;
  inference-only, no surface syntax — absorbed by the arm/branch merge so
  `if c { 5 } else { throw }` is `Int`, which also shrinks the `Unknown`
  population. On the back of that, `throw` is now valid in branch-tail (value)
  position (`x = if c { a } else { throw … }`), a one-keyword parser change
  since the type machinery already absorbs it. Specs `type-never-divergence`,
  `err-throw-tail`.

- **Type-checker holes closed** (2026-07). Four check-clean-but-wrong-at-runtime
  holes from the type-system review, each fixed with zero corpus false
  positives: list/map literal tails are checked for homogeneity (`[1, 'two']` is
  now a `check` error — `type-list-homogeneous`); interface conformance compares
  the target's type arguments (`impl Box<Int>` no longer satisfies `Box<String>`
  — `iface-conformance-args`); an unbounded-`T` method call is rejected at
  `check` rather than only at emit, with `display`/`debug` staying universal
  (`gen-param-methods`); and a for-loop's range element types from the
  iterable's _syntax_ instead of an `Unknown => Int` fallback that also fired on
  genuine holes, with `Int` range bounds now enforced (`expr-range-bound`). The
  fifth hole — bare-`TypeParameter`-source assignability — was spiked and
  deferred (a 12:1 false-positive ratio for the naive narrowing; findings kept
  in _Type system punchlist_).

- **Honest tag-mismatch traps — `Trap::TypeError` split** (2026-07). A type hole
  reaching the runtime (a value whose static type the checker got wrong) now
  traps as `runtime type error: expected Int, found String` instead of
  `internal error (malformed bytecode): expected Int, found Ref(0)` — which had
  wrongly blamed the compiler. The interpreter's type-checked pops
  (`pop_int`/`field.get`/`enum.get`/`call.indirect`/`list.*`) raise a new
  `Trap::TypeError`; genuine structural malformations (stack underflow, bad
  slot) keep `Trap::Bug`/"internal error". The `found` type is named via the v3
  type/enum tables (`found Point`, not `Ref(0)`). Native arg-checks are a
  tracked follow-up (Type system punchlist). Faults in language.md.

- **Named structural `Debug` — field + variant names (bytecode v3)** (2026-07).
  The auto-derived `Debug` now renders structs by field name
  (`Point { x: 1, y: 2 }`) and user enums by variant name (`Circle(3)`,
  `Square`) instead of the old positional `Point { 1, 2 }` / `variant1`.
  Bytecode v3 threads the names into the runtime type table
  (`TypeDef.field_names`) and a new Enums section (`EnumDef`: ty + name +
  variant names); the loader still accepts v2 (names absent ⇒ positional).
  `Ordering` now names its variants too; the runtime keeps a built-in
  `Ok`/`Some` fallback for `Result`/`Option`. This is the enabling primitive for
  runtime reflection/introspection. Format in bytecode.md.

- **`thera test`/`check`/`lint` UX for LLM output** (2026-07). The analyzers stop
  emitting lines just for doing work: quiet-by-default reports (failure blocks
  only), a one-line proof-of-work summary
  (`Ran N tests for M test files; K failures.` /
  `Checked N source files; M issues found.`), `--verbose` for the classic
  per-test report, and no-argument invocations defaulting to the current
  directory. The test runner now captures the child's output and reads the
  per-test failure count from a stdout trailer (the exit code stays pass/fail
  only). Spec in language.md §The `thera` tool / §`thera test`.

- **`Iterator.collect()` renamed `to_list()`** (2026-07). The drain consumer now
  follows the `to_X` conversion convention (`Set.to_list()`, `Bytes.to_list()`,
  `to_int`/`to_double`) instead of borrowing Rust's `collect` without its
  type-directed semantics. Interface default method + all call sites renamed;
  language.md §Pipelines and stdlib.md updated, with the rationale recorded in
  the spec.

- **Eager `List` transforms + a `List.iter()` bridge** (2026-07). Settled that
  `List.map`/`filter` stay **eager** (returning a `List` — the result still
  indexes, has `len`, re-iterates, and chains), matching the dominant array
  convention (JS/Ruby/Swift/Kotlin) and avoiding a one-shot-consumption footgun;
  the lazy, fused, short-circuiting path is reached explicitly via `xs.iter()`,
  whose doc is the discoverable "when/why" home. `List.iter()` is the single
  list→`Iterator` bridge — `List.enumerate` composes as
  `self.iter().enumerate()` (the bespoke `ListEnumerateIter` is gone) and
  `iter.from_list` is a thin alias.

- **OOM + stack-overflow traps; string-indexing hint** (2026-07). Memory and
  frame-stack exhaustion are real traps now, not process aborts: the heap has a
  live-bytes ceiling (`THERA_MAX_HEAP_MB`, default 1 GiB) enforced at the
  safepoint right after a collection (`Trap::OutOfMemory` — only genuinely-live
  bytes count), an allocation past the ceiling arms a collection even below the
  adaptive threshold, and a call past the 1M-frame depth backstop raises
  `Trap::StackOverflow` (the 250k-deep recursion test still passes — the
  explicit frame stack is the point). Both messages follow the trap table in
  language.md §Runtime faults. Also: the string-indexing hint now suggests
  `.chars()` / `.slice(start, end)` instead of the retired `.graphemes()`.

- **Type-system review + spec sections** (2026-07). A design-completeness pass
  over the implemented type system (the five-shape lattice, assignability,
  generics/bounds, local bidirectional inference). Verified solid: branch/arm
  join checking, cross-type `==` rejection, function-type variance, bound
  enforcement, annotated-binding mismatches. Four holes found empirically (all
  check-clean today, trap or misbehave at runtime): unchecked list/map literal
  tails, conformance assignability ignoring the target's interface args,
  `TypeParameter`-source leniency, and covariant generic args under mutation.
  Decided against a formal (lambda-calculus) treatment — prose spec +
  conformance tests instead; language.md gained "The type system at a glance",
  **Generics**, and **Assignability** sections. The fixes have since landed (see
  the type-system entries above); the remaining design calls — the deferred
  bare-`TypeParameter` narrowing and the native-arg trap wording — stay open in
  _Type system punchlist_.

- **Language-spec self-consistency review + doc sweep** (2026-07). language.md
  and the supporting docs were cross-checked against the implementation — stdlib
  surfaces, the CLI, the runtime — with every suspect behavioral claim verified
  empirically before reporting. The confirmed-stale sections were rewritten
  (Pipelines, interpolation/`Debug`, `std.process`, `thera test` + command
  tables, Concurrency/fibers, `Map`/`Set` ordering, Style/formatter, SDK layout,
  runtime-fault conditions, `.graphemes()`, `let mut` field spelling; plus
  architecture.md's fiber banner, conformance.md's stale white-box finding, and
  overview.md's JIT tense/`call.virtual`). Verified accurate with no change
  needed: the trap-message table, the reserved-name list, the `Option`/`Result`
  combinator sets, the `std.testing` assertion table, `Args`, `Bytes`, and the
  entry-point forms. The design follow-ups it spawned (iterator consumer naming,
  lazy `List` transforms, `thera test` UX, `Trap::OutOfMemory`) have all since
  landed — see the entries above.

- **Front-end O(n²) source-slicing removed** (2026-07). `String.slice` /
  `SourceSpan.text()` rematerialized the whole string via `chars()` on every
  call, so slicing per token was quadratic in file size. Fixed in two layers:
  the hot call sites (lexer `scan_ident`, and the formatter's `space_intra_line`
  / `same_tokens` / `scan_lines` / `apply_edits`) now materialize the source's
  code points once and index that list; and `String.slice` itself is now a
  native (`str_slice`) that walks to the range's end in one O(end) pass instead
  of building a whole-string code-point list. `thera fmt` on a 110 KB file
  dropped from ~4 s to ~0.2 s (~20×) and now scales linearly. See _Stdlib_ →
  `String.slice cost` for the residual O(end) note.
- **Map-literal migration follow-ups (checker diagnostic, rendering, legacy
  sites)** (2026-07). Three tails of the migration closed. (1) **`Void`-arm
  diagnostic**: `check_void_arms` splits the `unify_arm` value-less-arm
  exemption — a _diverging_ arm (`return`/`throw`, or a block/`if`/`match` all
  of whose paths exit, per the new syntactic `expr_always_exits` view; a
  tail-less block infers `Unit` whether or not it exits) stays exempt, but a
  plain `Void` arm (`=> void` / `=> {}`) in a value-producing match is now a
  check error — it flows its unit value out and previously trapped only at the
  use site (`map.len: expected map`). Source-origin matches only (a statement
  `if let` fabricates a Unit wildcard arm by design), and a bare unbound
  `TypeParameter` reference stays lenient like `Unknown` (a match as a lambda
  body passed to a generic `fiber.spawn(() -> T)` can still bind `T = Unit`).
  Conformance: `cf-match-void-arm`. (2) **Map/Set `Display`** now follows the
  source syntax: `['x': 1]` / `[:]` (round-trips as code); `Set` renders
  `(1, 2, 3)`. (3) **Legacy `match` sites converted to `if let`** — the 28
  pre-`if let` two-arm matches, via `thera fix --only match-to-if-let --write` +
  one hand rewrite. Doing so surfaced and fixed a **position bug in the fix
  machinery**: the `if let` rewrite (an else-less `if`) was offered from _any_
  expression position but only parses as a statement or a block tail — rewriting
  a match arm body produced unparseable code. `fs_if_let` now gates it to those
  positions (also covering the LSP code action, which drives the same
  `fix_sites`); the value-preserving rules (`?`/`unwrap_or`/`map`) still apply
  anywhere.
- **Bracket map literals — `[k: v]` / `[:]`; braces are always blocks
  (language)** (2026-07). The map-literal migration completed: map literals are
  written `['a': 1]` (empty `[:]`), and a `{` in expression position is always a
  block (`{}` = empty block, value `Void`). **Decision** (2026-07-10
  grammar-review research): the brace-map form carried three pinches — any `{`
  in a match arm was a block (so `pat => {}` silently made a `Void` arm and a
  non-empty map arm couldn't be written), a map whose first key wasn't a literal
  was unwritable, and the commit heuristic itself was a rule with no
  training-corpus analogue. Bracket maps kill all three, state as one rule
  ("collections are brackets; braces are blocks" — struct instantiation keeps
  braces, disambiguated by the type name), and made the parser simpler: after
  `[`, one expression is parsed and a following `:` commits to a map — no
  heuristic, keys are unrestricted expressions. Rejected: smart-brace probing,
  empty-token-only, type-directed arm parse. **Migration**: corpus swept by a
  one-shot AST-driven rewriter (edit only the MapLit delimiter characters,
  verify by reparse) — ~330 sites, with `bootstrap/frontend.thera-bc` coming out
  byte-identical (no spans in `.thera-bc`), proving zero bytecode change; docs
  examples flipped. **Removal**: the brace form is now a targeted parse error —
  the old commit heuristic survives as the shape detector
  (`at_legacy_brace_map`), and a non-literal key is caught at the `:` after an
  expression statement; both hint "map literals are written `[k: v]`".
  Conformance: `type-map-bracket`, `type-map-brace-reject`; AST `describe`
  renders maps in bracket form. Follow-up: Map/Set runtime rendering still uses
  brace notation (see Open work).
- **`=> void` for no-result arms (idiom + lint + sweep)** (2026-07). Step 1 of
  the map-literal migration (the decided bracket-maps item above): a no-result
  match arm is written `=> void` — the explicit unit value — not `=> {}` (an
  empty block, semantically identical but ambiguous-looking, and one keystroke
  from an empty map). The corpus's ~230 `=> {}` sites were swept to `=> void`
  (string fixtures that deliberately pin the `{}` shape kept); a new per-arm
  lint rule `void-arm` flags the old spelling (source matches only; defers to
  `match-to-if-let`, whose rewrite removes the arm); language.md's _Choosing a
  form_ documents the idiom. Corpus-wide `void-arm` tally after the sweep: 0.
  (The ~28 remaining `match-to-if-let` sites — small matches predating `if let`
  / the Option combinators — are an independent follow-up.)
- **Grammar-review syntax tightenings (parser)** (2026-07). Three items from the
  2026-07 grammar review landed. (1) **Nested generics in call-position type
  args**: `looks_like_type_arg_list` is now a balanced `<`/`>` scan (over
  identifiers / `.` / `,`) keeping the same `(`/`.` follow-token commit rule, so
  `f<Result<T, E>>(…)` and `Map<String, List<Int>>.new()` parse. Function types
  in call-position type args stay unrecognized — admitting `(` would swallow
  parenthesized comparisons; annotated positions handle them fine. (2) **`,`
  required after expression-bodied `match` arms** (optional after a `{…}` arm
  and before the closing `}`) — the Rust rule, pre-empting the ambiguity
  or-/parenthesized patterns would create; the error marks the arm's end, where
  the comma belongs. Corpus impact was zero. (3) **Zero-variant enums rejected**
  (`enum Never {}` parsed and checked clean; uninhabited, and there is no
  never-type story). Conformance: `gen-call-nested-args`, `cf-match-arm-comma`,
  `type-enum-nonempty`; grammar.md updated alongside. The map-literal-vs-block
  ambiguity — the review's big design item — stays open above.
- **Workspace diagnostics — `resultId` caching + surface-gated nudge (LSP)**
  (2026-07). Two refinements on the pull-diagnostics path. (1) **Per-file
  `resultId` caching** (LSP 3.17): the server stamps each file's report with an
  opaque resultId and caches the exact rendered items it stands for; a re-pull
  that echoes the resultId (via `previousResultId` / `previousResultIds`) gets a
  light `unchanged` report for any file whose items are byte-identical, instead
  of re-sending them. Exact content comparison, not a hash — a collision would
  wrongly report `unchanged` (a stale squiggle). The cache is self-correcting
  (every decision compares current content), so no explicit invalidation is
  needed, and it is shared across the document and workspace channels (same
  content → same id). (2) **Surface-gated refresh nudge**: an edit now nudges a
  workspace re-pull only when it could alter _another_ file's diagnostics — a
  change to the file's public-surface _signature_ (`pkgs/cli/lsp/surface.thera`:
  the source with fn/method body interiors elided, since importers type-check
  against declarations, never bodies). A body-only edit — typing inside a
  function — no longer triggers a project-wide re-check; the file's own
  diagnostics still reach the editor via the client's per-document pull.
  Conservative by construction (elides less than the true surface), so it can
  only over-nudge, never miss a cross-file change. A close still nudges
  unconditionally (a loose file drops out of the report).
- **Workspace diagnostics — backgrounded on a fiber (LSP)** (2026-07). The
  `workspace/diagnostic` scan no longer runs synchronously on the request loop:
  it runs on a background fiber (`server.start_workspace_scan`) that `yield`s
  between files, so a large project's first pass no longer blocks
  hover/edits/completion. The scheduler runs the worker during the loop's stdin
  parks; the worker delivers its report through a new **outbox**
  (`pkgs/cli/lsp/outbox.thera`) — a single serialized outbound sink so the
  dispatch loop and the worker never interleave bytes of one framed message.
  `serve` installs an _async_ outbox (a writer fiber draining a channel, joined
  on exit so buffered replies flush); `handle` (the one-shot/test path) installs
  a _direct_ one and joins the worker inline, so the in-process tests stay
  synchronous. Supersession is a generation counter: a newer pull or a
  `$/cancelRequest` bumps it, and the stale worker bails with `ContentModified`
  (-32801) — the client keeps the latest (eventual consistency). Still deferred:
  per-file `resultId` caching and a smarter refresh nudge.
- **Per-file SDK resolution — cross-path core identity (loader)** (2026-07). A
  file that lives _inside_ an SDK's `std` tree now resolves its `std.*` imports
  (and the auto-imported `std.core` prelude) from **that same tree** rather than
  the configured SDK root (`loader.own_std_dir`). This fixes the
  LSP-editing-the-repo case: with the prelude resolved from an installed SDK but
  the file from the repo copy, the core types (`List<T>`, …) existed twice with
  distinct identities, so a core file's own generic methods stopped
  type-checking against their own `List<T>` and every top-level decl looked like
  it shadowed the prelude copy of itself. `thera check sdk/std` via a foreign SDK
  is now clean (was ~8 false diagnostics). Ordinary project files (not under a
  `std` tree) are unaffected — they keep resolving against the configured SDK —
  and the normal build resolves identically (fixpoint holds). Also: an
  unresolved for-loop iterable now types its element as `Unknown`, not `Int`
  (the `Int` fallback is scoped to ranges), so a genuinely unknown element no
  longer cascades into "no method X on Int".
- **Pull-only diagnostics + server-side `exclude` (LSP)** (2026-07). The server
  no longer pushes `publishDiagnostics` at all — it went **pull-only**, so open
  files and the workspace flow through the one channel
  (`textDocument/diagnostic` / `workspace/diagnostic`), and an edit's only
  proactive signal is the `workspace/diagnostic/refresh` nudge. This removes the
  push/pull duplication (a file no longer got diagnostics on two channels).
  Diagnostic filtering also moved from the VS Code extension to the server: the
  client sends its `thera.exclude` globs via `initializationOptions` (live
  changes via `workspace/didChangeConfiguration`), and the server withholds
  matching files from both reports — uniform across channels and
  client-agnostic, replacing the extension's per-channel glob middleware. A
  small workspace-relative glob matcher (`pkgs/cli/lsp/glob.thera`, `*` / `**` /
  `?`) does the matching. Closing a file now marks a change (a re-pull nudge)
  rather than clearing via push.
- **Workspace-wide diagnostics — pull model (LSP)** (2026-07). Diagnostics are
  no longer limited to open files. The server advertises a 3.17
  `diagnosticProvider` (`interFileDependencies` + `workspaceDiagnostics`) and
  answers `textDocument/diagnostic` (one document) and `workspace/diagnostic`
  (every workspace file, opened or not — a full report per file, empty items =
  clean). The workspace pull reuses the session's shared check and checked-clean
  dedup — the same `thera check <dir>` loop — so a shared import is checked once
  per pass, not once per importer, and `diagnostics.group_by_file` folds each
  file's own errors out of the closure result (the push path filtered them to
  one URI). The proactive signal is the pull model's
  `workspace/diagnostic/refresh` nudge, sent once per edit-flush to a
  refresh-capable client, which then re-pulls (the edited cone recomputes, the
  rest are checked-set hits) — so push stays for open files and pull carries the
  project. The `library_cache` is now **LRU** with a high cap (1024) instead of
  clear-all-at-32, so workspace analysis doesn't thrash it. (Backgrounding the
  workspace check on a fiber landed later — see the top of this changelog;
  `resultId` caching is still deferred.)
- **References/rename — dependency-cone pruning (LSP)** (2026-07). The
  project-wide scan no longer builds every workspace file's closure. Both
  requests now scope the expensive resolution to the target's **dependency
  cone** — its declaring file plus its transitive importers
  (`session.dependents_of`), intersected with the scan — so a file that can't
  see the declaration (a same-named identifier there is a distinct `SymbolId`)
  is skipped without a closure load. Completeness is preserved by first indexing
  the workspace's forward import edges with a cheap edges-only probe
  (`loader.import_edges` — resolves specifiers, no child
  sources/surfaces/element model; `session.index_edges` fills only files never
  loaded, so a warm request does no extra work), then reversing that graph: a
  closed, never-opened importer is still found. An edit drops the file's forward
  edges (`invalidate`) so a changed import list re-probes. Cost now scales with
  the target's reachability, not project size, with the same results as the old
  whole-project scan.
- **Session tokenization dedup — cached tokens (LSP, audit LS-D1 tail)**
  (2026-07). Tokens are now the materialized bottom rung of the analysis ladder:
  `parse_source` retains its lex on `ParsedFile.tokens` (paired with the AST by
  construction), the session carries the primary's tokens on `Closure`, and
  `ResolveCtx` hands them to the resolver. `resolve.primary_tokens` reads that
  cached tokenization instead of re-lexing — so hover/definition lex the buffer
  once per request (was twice: parse + resolve), and references/rename lex each
  scanned file once instead of once per candidate occurrence (the loop and every
  `resolve_at` inside it now share `ctx.tokens`). A cache hit is consistent with
  the request's text by construction (both flow from one `parsed_primary`);
  callers without cached tokens (hermetic tests) pass an empty list and the
  resolver lexes on demand — correct, just un-cached. Eviction is free: tokens
  ride the parse cache's existing invalidation cone.
- **Pre-rename collision check (LSP)** (2026-07). `textDocument/rename` now
  pre-flights the new name: renaming a top-level symbol onto a name already
  bound in its file's one name space — a same-file declaration, a prelude /
  `as _` bare-surface name, or a bound import namespace — is declined with an
  error response naming the clash, instead of writing an edit the checker would
  reject on the next publish. `rename.collision` reuses `find_decl_site` for the
  predicate (the same bare resolution the checker's duplicate/shadow checks
  agree with); `rename_at` returns a three-way `RenameOutcome`
  (`Edit`/`Decline`/`Collision`) the server maps to a WorkspaceEdit, a null
  result, or a `RequestFailed` error. Scoped to file-scope targets — a local
  shadows legally, so it isn't pre-checked.
- **Formatter (`thera fmt`)** (2026-07). A line-preserving formatter
  (`pkgs/cli/fmt.thera`): re-indents each line (token-only anchor stack),
  normalizes intra-line spacing (a token-driven **gap-edit** pass — rewrites
  only the whitespace between adjacent same-line tokens, so comments and lexemes
  are untouched), collapses blank runs, trims trailing whitespace. Keeps every
  author-chosen line break — no line joining/splitting. The one spacing role the
  token stream can't classify (`List<Int>` vs `a < b`) comes from a
  **generic-delimiter parser side-channel** (`ParseResult.generic_delims`, the
  `LexResult.comments` model); a round-trip guard (token equality + re-parse)
  makes "never breaks a compile" a checked invariant. No config knobs, by
  design. The corpus is a fmt fixpoint, gated by `bin/test.sh`. Philosophy (no
  config, bounded scope) in
  [architecture.md](architecture.md#the-formatter-thera-fmt).
- **Struct fields are `let`-declarations terminated by `;` — DONE.** A field is
  `let name: T;` (`let mut name: T;` for a reassignable one):
  `struct Point { let x: Int; let y: Int; }`. The `let`/`;` form reads as a
  declaration and differentiates a struct _declaration_ from a struct
  _instantiation_ — the two bodies (`{ x: … }`) were otherwise identical, told
  apart only by resolving each RHS as a type vs. a value.
- **Unified diagnostic model (audit LD15 tail)** (2026-07). Every phase — lex,
  parse, check, codegen, load — now produces one
  `Diagnostic {message, span, file, severity}` directly (new
  `pkgs/cli/diagnostic.thera`), retiring the five per-phase error structs
  (`LexError`/`ParseError`/`CheckError`/`CodegenError`/ `LoadDiagnostic`) and
  the session-level converters that mapped them. `file` is still derived from
  the span (the loader stamps an explicit file); `severity` is a three-level
  enum (`Error`/`Warning`/`Info`) so lint-style suggestions can ride the same
  model later — every compile-phase diagnostic is `Error` today, and the LSP
  severity map is its first consumer. No `phase` field (no consumer). check/
  emit/LSP are now pure renderers over a `List<Diagnostic>`.
- **Complete field identity (LSP)** (2026-07). A struct field now has full
  symbol identity, so references and rename treat it like any other declaration.
  Hover/definition on a field's declaration name, its `S { field: … }` literal
  uses, and its member accesses had already been unified onto the field's
  `FieldDef` name span (one owner-correct `SymbolId`); the remaining step was to
  stop declining field rename. `matching_spans` already resolves each occurrence
  at its own offset and keeps only those whose `SymbolId` matches, so all three
  positions collect and rewrite together — a same-named field on a different
  struct stays untouched. Removed the `is_field()` rename guard (and the
  now-dead method); check-only, no `.thera-bc` change.
- **Boundary type-annotation diagnostics** (2026-07). The "hard at the
  boundaries, soft in the center" rule (language.md, _Type annotations &
  inference_) is now enforced at all four boundaries. Struct fields were already
  required by the grammar; the checker now also flags an un-annotated **function
  parameter** (other than `self`), an omitted **return type** on a function that
  returns a value (a bare `return;`/`return void;` stays `Void`; reported once
  per function via a shared `CheckCtx` box; the check-site placement excludes
  returns inside nested lambdas for free), and an un-annotated **module-level
  `let`/`const`**. The module-level check keeps the pass-4 initializer inference
  under the hood (codegen never sees an `Unknown` global) but requires the
  annotation at the source. Corpus impact was a single migration — `std.log`'s
  `config` singleton, now `let config: Config = …`. No `.thera-bc` changes (a
  check-only error path), so the fixpoint held without a snapshot churn.
- **Un-annotated module-global type inference — resolver pass 4** (2026-07). A
  top-level `let`/`const` with no type annotation now has its type **inferred
  from its initializer** (mirroring a local `let`). Previously the resolver
  recorded a global's type from its annotation only, leaving an un-annotated
  global `Unknown`: the checker tolerated it (lenient member access on
  `Unknown`) but codegen hard-failed (`field access on non-struct value`), so
  `let config = Config { … }` type-checked yet wouldn't run. Implemented as the
  resolver's **pass 4** (`inference.infer_program_globals`, run per-program
  after the interface closure in
  `build_library`/`build_import_library`/`layer_primary`), so building a library
  yields a fully-typed one — no external caller has to run a second step, and
  the incremental cache stays correct (the base's imports are typed once at
  base-build; `layer_primary` types only the primary, honoring the frozen-base
  invariant). Making the resolver able to call inference required breaking the
  `inference → resolver` import cycle: `resolve_type_ref_in` / `resolve_opt_in`
  moved down to `scope.thera` (a layer both import), so `inference` no longer
  imports `resolver` and `resolver` now imports `inference`.
  Annotation-preserving and safe (inference degrades to `Unknown`), so no
  existing global — all annotated — changes. Unblocks the "final global struct
  with `mut` fields" mutable-singleton pattern (`std.log`'s config).
  _Fast-follow (Gap 2, open):_ a generic method on a struct's field
  (`config.filters.keys()`) still doesn't recover the field's type arguments —
  infers `List<Int>` — so it needs an annotated-local pin
  (`let m: Map<K,V> = config.filters;`); see Compiler & front-end open items.

- **`std.log` — named, per-source logging** (2026-07). Levels
  (`Debug`/`Info`/`Warn`/`Error`), named loggers with hierarchical per-source
  filtering (longest dotted-prefix wins), and Text/JSON rendering on stderr.
  Configuration (`set_level`/`set_level_for`/`set_format`/`configure_from_env`,
  the last reading a `RUST_LOG`-style `THERA_LOG` spec) is application-only
  behind a facade; libraries only ever emit. Ambient logging is the free
  functions `info`/`warn`/`debug` (plus `named(...)` for source-tagged loggers);
  its config is the one **sanctioned exception** to "no global state" —
  write-only diagnostics set once by the app — while the capability `to_writer`
  logger (own sink/level, testable) is the escape hatch. Implemented **pure
  Thera, no natives**: the config is a `let config = Config { … }` module global
  (an immutable binding whose `mut` fields mutate in place), rendering is pure
  Thera (JSON via `std.json`), and output writes through `io.stderr()`. An
  ambient `error` free function is a TODO — a top-level `error` collides with
  the prelude `error()` constructor; pending the prelude-value-shadow relaxation
  below (until then `error` is available as a `Logger` method). See
  [stdlib.md](stdlib.md) § `std.log`.

- **Semantic LSP resolution — references, rename, inferred-type navigation**
  (2026-07). `textDocument/references` and `rename` are now **semantic** — every
  candidate resolved by `SymbolId` identity across the open documents + a
  workspace scan (not by text match), so unrelated same-named symbols are never
  touched; both are registered in the server. The same resolver drives
  hover/definition on **inferred** receivers: local `let`/loop-variable types (a
  committed type-record, `session.type_at`), members on computed receivers
  (`f().x`, `xs[i].y`), struct fields, generic type parameters, and names inside
  `${…}`. Retires the parked lexical-only `references.thera`/`rename.thera`.

- **Owner-correct type resolution — `TypeId`** (2026-07). Completes the
  type-origin arc the roadmap flagged as foundational: nominal type identity is
  now `(owning library, name)` via a `TypeId {owner, name}` carried on every
  `Type` through inference, unification, and codegen's type tables (staged
  T1–T4, fixpoint-idempotent), lifting type-name uniqueness so two libraries may
  each define `Point` (conformance `mod-shared-type-name`). The preceding
  architecture-review checkpoint chose the `TypeId` struct over an interned int
  (keeps inference pure) and over a bare positional owner.

- **LSP incremental analysis engine + `type_at`** (2026-07). `thera check` and
  the LSP now share one long-lived analysis session (`session.Session` /
  `Analysis`) with a resolved-library cache + dependency-graph invalidation, so
  a keystroke re-parses only the edited file and re-checks only the affected
  libraries instead of the whole closure (batch corpus check 22.6s → 12.5s; warm
  keystroke ~5ms). The checker records each node's committed type
  (`Session.type_at`), which serves inference-at-offset and halved the checker's
  inference work.

- **Front-end audit — six-subsystem correctness sweep** (2026-07). An
  adversarial audit of `pkgs/cli/` closed whole classes of "checks clean, wrong
  at runtime" gaps: match exhaustiveness and assignment / operator / `if`-branch
  typing; value (const/global/native) owner-keying and codegen block/const
  scoping; builtin identity by `TypeId` rather than name string; canonical file
  identity + surfaced loader error paths + a unified per-file diagnostic model;
  owner-correct LSP resolution; and parser soundness (interpolation errors,
  `<`-ambiguity, brace-aware recovery).

- **Map/Set scaling — hashed, insertion-ordered** (2026-07). `Obj::Map` was a
  linear-scan, clone-on-mutate `Vec<(Value, Value)>`, so building an N-entry map
  was O(n²) (it bit an inference refactor building tens-of-thousands-entry
  maps). Now a dedicated `MapObj` (`runtime/src/map.rs`): a Vec for insertion
  order + a parallel key-hash Vec + an open-addressing index above 16 entries,
  with content-based hashing consistent with `values_eq` and mutation via
  `heap::take_obj` — O(1) get/has/insert. `Set` inherits it; insertion order is
  preserved so the fixpoint is unaffected.

- **Streaming files — `fs.open`/`fs.create` + `Seek`** (2026-06). `std.io`
  gained a `Seek` interface; `std.fs` gained `File` — a
  `Reader`/`Writer`/`Seek`/`Closer` over an OS file — so `io.lines(fs.open(p)?)`
  streams a file line by line without `read_all`. No GC finalizer yet, so
  `close()` is the caller's job. Deferred: `temp_file`, append/read-write
  `open_options`.

- **Interface default methods + Iterator adapters** (2026-06). Interface methods
  may carry a body — a _default_ an `impl` inherits (and may override), compiled
  once as a shared unit with `self` typed as the interface (no runtime change).
  First use: `Iterator<T>` gained lazy `map`/`filter`/`take` + `collect`/`count`
  as defaults, so every iterator is fluent with no `Iter<T>` wrapper; also fixed
  a lambda-arg-to-virtual-call inference bug. Spec `iface-default`; unblocks
  `io.lines`/`fs.walk`/`BufReader`.

- **Nested generic args in `impl` headers → `enumerate`** (2026-06). An `impl`
  header's `<…>` parsed type-param names only, so
  `impl Iterator<Indexed<T>> for …` didn't parse; `parse_impl_generics` now
  keeps both a TypeRef and a TypeParam view, chosen by whether `for` follows.
  Unblocked the `enumerate` adapter (`-> Iterator<Indexed<T>>`) and future
  wrapped adapters (`zip`/`flat_map`/ `chain`).

- **Iterator-backed stdlib — `io.lines`/`BufReader`, `fs.walk`, `List.pop`**
  (2026-06). First consumers of the new adapters: `io.lines(src)` yields one
  line per `next` (an `Iterator<String>`), `fs.walk(root)` is a lazy recursive
  `Iterator<String>` of descendant paths, and `List.pop() -> Option<T>` is the
  mutating companion of `last()`.

- **Module initializers — computed-once immutable globals** (2026-06). Top-level
  `let NAME[: T] = expr;` is computed once at load into a stored global slot
  (runtime `global.get`/`set`, a globals GC root, an `<init>` thunk before the
  entry; front-end does topological init with cycle detection + an
  effectful-native denylist). Immutable only; `const` tightened to manifest
  constants. First use: `std.math` `INFINITY`/`NAN`. See
  [language.md](language.md) → Module-level bindings; conformance `module-let*`,
  `const-manifest`.
- **`std.regex` — RE2 regexes over the `regex` crate** (2026-06). The runtime's
  2nd deliberate dependency (after `std.hash`): the linear-time RE2-derived
  `regex` crate — `compile`/`is_match`/`find`/`find_all`/`captures`/`replace`
  (`_all`), byte-offset `Match`, `RegexError.Syntax`. A compiled pattern lives
  in a runtime registry behind an `Int` handle, not yet freed (the benign leak
  the _Native resource finalization_ item addresses). Design:
  [stdlib.md](stdlib.md) §std.regex.
- **`std.hash` — native digests + the runtime's first external deps** (2026-06).
  `sha256`/`sha1`/`md5` (as `Bytes`) and `crc32` (as `Int`), thin wrappers over
  audited RustCrypto crates rather than reimplemented in Thera — hashing is
  crypto-adjacent. This deliberately added the runtime's first external
  dependencies (each named in its function's doc); checked against published
  vectors.

- **`std.encoding` — base64 / hex / url** (2026-06). `base64`/`hex`/`url`
  encode+decode, **pure Thera** over `Bytes`/`String` + bitwise ops (no natives,
  no lookup tables); decoding is fallible (`Result`), never a trap. RFC
  4648/3986 vectors + binary round-trip + malformed-input cases covered.
  `std.path` `normalize`/`relative` also landed.

- **Struct-definition keyword: `type Foo = { … }` → `struct Foo { … }`**
  (2026-06). Thera is nominal, but `type Foo = { … }` read as a structural alias
  (the wrong prior); structs now use the nominal keyword-name-braces form,
  rhyming with `enum`/`interface`. Purely surface — same `TypeDecl` AST,
  byte-identical re-emit — landed as a three-cycle ratchet (additive parser +
  snapshot, migrate 145 sites, remove the legacy form). Frees `type X = Y` for a
  future transparent alias.

- **LSP keystroke latency — parse cache + edit coalescing** (2026-06). A
  server-lived parse cache (keyed by path, evicted on edit) reuses the parsed
  import closure across keystrokes: **186 → 8.3 ms/edit (~22×)**. Edit
  coalescing drains a whole buffered burst before one diagnostics flush, so 100
  bunched edits ≈ the cost of 1. Next lever: caching the resolved/element-model
  closure (the incremental engine).

- **In-VM profiler + `thera check` ~7.7× faster** (2026-06). A deterministic
  instruction-budget profiler (`THERA_PROFILE`) drove a measure-then-fix pass on
  `thera check pkgs/cli` (80s): a cross-file parse cache (the `std.core` prelude
  was parsed 46× → once) plus string-constant interning took it to **~10.4s**,
  byte-identical fixpoint. Surfaced that a top-level `const` keyword map can't
  replace a `match` without load-time init — the motivation for _Module
  initializers_.

- **Unified checker/codegen inference context + a differential oracle**
  (2026-06). The checker and codegen built `infer_expr`'s context independently
  — a bug class where the two stages inferred an expression to different types
  (a runtime-trapping miscompile). A differential oracle (`THERA_INFER_ORACLE`)
  mapped every divergence to one pattern (codegen dropping the receiver's type
  args), now fixed and a permanent assert-zero guard in `bin/test.sh`;
  byte-identical fixpoint. _Open: extend the oracle to lambda units — a
  full-context attempt hung `check` (a compile-time blowup) and was reverted, to
  be redone perf-aware._

- **`Ord` interface + `std.sort`** (2026-06). Total ordering modeled on
  `Eq`/`Display`: `interface Ord { fn compare(self, other: Self) -> Ordering }`
  - `enum Ordering`, with explicit primitive impls and a `compare` arm in the
    runtime `virtual_fallback` for virtual dispatch. `std.sort` ships
    `sorted`/`sorted_desc`/`min`/`max` over `<T: Ord>` (free fns); comparison
    operators stay Int/Double-only (wiring them through `Ord` is the _Generic
    operators_ arc). Also fixed a latent gap: lifted lambdas now inherit their
    enclosing function's `type_param_bounds`. Spec `iface-ord`.

- **Bitwise operators** (2026-06). `& | ^ << >> >>> ~` on `Int` (wrapping i64),
  lexer → parser precedence → checker (Int-only) → opcodes. Let `std.random`'s
  SplitMix64 and the LEB128 / little-endian `Bytes` codecs move into pure Thera
  (the `random_mix` native is gone). Specs `expr-bitwise`/`expr-shift`.

- **Generics: static-method type args, struct/enum bounds, inference cleanup**
  (2026-06). Three solidifications: static-method owner type params recovered
  from call context (`Set.new()`) or named via receiver type args
  (`Set<String>.new()`); generic struct/enum bounds (`type Box<T: Display>`)
  enforced where a concrete arg is supplied; and the static-receiver
  classification unified in `resolve_static_receiver`. All byte-identical
  fixpoint except the added checks; generics are invariant by design. Specs
  `gen-static-*`, `generic-type-bounds`. _Open follow-ons above._

- **Resolution: `FileScope` + owner-correct value resolution (Phase 2)**
  (2026-06). Resolution moved off flat global name tables onto a per-file
  `FileScope` with `name → defining-file` origin, so value (function/const)
  resolution is owner-correct (bare to its own file, qualified within its
  library) and two libraries may share a top-level value name. Landed in eight
  fixpoint-preserving steps; also fixed a duplicate-file-loading bug that cut
  the self-compile ~11.5s → 4.3s and the bootstrap 282KB → 124KB. Spec
  `mod-shared-value-name`. (Type-name owner-correctness followed — the `TypeId`
  entry above.)

- **`#loc` caller-location + assertion source locations** (2026-06). `#loc` is a
  compiler metaconstant evaluating to a `SourceLoc`; as a default parameter
  value it captures the call site. `std.testing` assertions take
  `at: SourceLoc = #loc` and prefix failures `file:line:column:` — the same
  format `thera check` prints. Spec `expr-loc`. _Open tail above (single-hop
  limit; runtime backtraces)._
- **Total rendering — `Display`-preferred, `Debug`-fallback** (2026-06). `${x}`
  / `println(x)` are total: a value renders via its `Display` impl if present,
  else its auto-derived `Debug`, never a check error or trap.
  `List`/`Map`/`Set`/`Option`/`Result` carry `Display` impls (elements via
  `Debug`, so nested strings quote). Specs `iface-display`/`iface-debug`. _Open:
  richer structural `Debug`, primitive vtables (both above)._
- **Primitive `Display` explicit** (2026-06). `Int`/`Double`/`Bool`/`String`
  carry real `impl Display`s bound to per-type natives; the catch-all
  `stringify` native and both front-end hardcodes are gone. `display_string`
  still backs the per-type natives + `list.join` + the virtual fallback — full
  retirement waits on primitive vtables.
- **`native type` declarations for the built-ins** (2026-06).
  `Int`/`Double`/`Bool`/`String`/`List`/`Map`/`Bytes`/`BytesBuilder` have
  bodyless `native type` decls in `sdk/std/core/` — a definition + doc site, no
  codegen/runtime entry (shadows the built-in floor byte-identically). Spec
  `type-native`. _Open follow-ups above._
- **Whole-closure diagnostics — per-file origin + import parse errors**
  (2026-06). `Diagnostic` carries a `file` origin resolved from the span's
  source text, so an imported-file error prints against its own file; the loader
  parses every closure file best-effort and surfaces each file's diagnostics
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
- **`thera test` per-test stdout capture** (2026-06). Each test's output is
  buffered via the `test_capture_*` runtime natives and shown only on failure
  (or always with `--show-output`). _Open: per-test source locations,
  machine-readable output (above)._
- **Runtime tiers 0–baseline.** Tree-walker POC + bytecode IR; Tier-0 bytecode
  interpreter + precise non-moving mark-sweep GC (see Runtime staging 1–2). Plus
  the interpreter perf wins (unified value stack, `ListLen` opcode) noted under
  _Interpreter performance_.
