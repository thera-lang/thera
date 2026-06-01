# Hawk: POC Plan

## Target domain: CLI tooling

Hawk targets the same space as Python, Go, and Node — scripting, automation, and
CLI tools. This shapes the entire stack:

- **Standard library must cover the CLI surface first:** filesystem, processes,
  stdin/stdout/stderr, env vars, argument parsing, path manipulation, JSON/YAML,
  HTTP. These are what CLI authors reach for constantly, and they need to come
  from the stdlib to avoid hallucinated third-party APIs.
- **Startup time matters.** Python and Node pay a noticeable cold-start cost;
  Go's single-binary model is the gold standard here. The eventual production
  backend should produce a native binary or use a fast VM (Bun, Deno, or
  native). The POC AST interpreter can ignore this for now.
- **Process spawning is a first-class operation.** Shelling out to other tools
  is the core activity of CLI code. The language should make this ergonomic and
  safe (capturing stdout/stderr, propagating exit codes as `Result`).
- **Single-binary distribution.** Go won the CLI space largely because
  `go build` produces one self-contained executable. The production build target
  should do the same.

### CLI-specific syntax ideas

```hawk
// First-class process execution — returns Result<Output, ProcessError>
fn get_branch() -> Result<String, Error> {
    let out = run('git', args: ['rev-parse', '--abbrev-ref', 'HEAD'])?;
    return out.stdout.trim()
}

// Argument parsing via stdlib (no third-party flags package needed)
fn main(args: Args) -> Result<(), Error> {
    let name = args.flag("name", default: "world");
    let verbose = args.flag("verbose", default: false);
    println("Hello, ${name}!");
    return ()
}

// File system — idiomatic, stdlib-native
fn read_config(path: Path) -> Result<Config, Error> {
    let text = fs.read_text(path)?;
    toml.decode<Config>(text)
}

// Environment variables
fn db_url() -> Result<String, Error> {
    return env.get("DATABASE_URL")  // returns Result; missing var is an error
}
```

---

## What the language looks like

The guidelines converge on a syntax that feels like a blend of Rust, Swift, and
Go — statically typed, brace-scoped, with errors as values and immutability by
default.

### Basic types and functions

```hawk
// Nominal struct types; fields immutable by default
type User = {
    id: Int,
    name: String,
    email: String,
}

// let = immutable binding; mut = mutable
fn double(x: Int) -> Int {
    let result = x * 2;
    return result
}
```

### Errors as values

```hawk
// Result<T, E> is the only error mechanism — no exceptions
fn parse_id(s: String) -> Result<Int, ParseError> {
    return s.parse<Int>()
}

// ? propagates the error to the caller (like Rust's ?)
fn fetch_user(id: Int) -> Result<User, Error> {
    let resp = http.get("/users/${id}")?;
    return json.decode<User>(resp.body)
}

// match on the result at the boundary
fn handle(id: Int) {
    match fetch_user(id) {
        Ok(user) => log.info("got ${user.name}"),
        Err(e)   => log.error(e.message),
    }
}
```

### Immutability and pipelines

```hawk
// Data pipelines: transform instead of mutate
fn active_names(users: List<User>) -> List<String> {
    return users
        .filter(u => u.active)
        .map(u => u.name.trim())
        .sort()
}
```

### Concurrency (fiber model)

All I/O looks synchronous. No `async`/`await`, no `Future<T>`. The runtime parks
the current fiber when a call blocks and resumes it when I/O completes.

```hawk
// fetch_user may block on a network call — the signature doesn't say so.
// No async annotation, no await at the call site.
fn load_dashboard(user_id: Int) -> Result<Dashboard, Error> {
    let user  = fetch_user(user_id)?;
    let posts = fetch_posts(user.id)?;
    return Ok(Dashboard { user, posts });
}
```

### Inline metadata (decorators)

```hawk
// Architectural intent sits next to the function signature
@route("GET", "/api/users/{id}")
async fn get_user(req: Request) -> Result<Response, Error> {
    let id   = req.params.get("id")?.parse<Int>()?;
    let user = await fetch_user(id)?;
    Ok(Response.json(user))
}
```

### Composition over inheritance

```hawk
// Interfaces (traits) describe capability; no class hierarchy
interface Serializable {
    fn to_json(self) -> String;
}

// Structs implement interfaces explicitly
impl Serializable for User {
    fn to_json(self) -> String {
        json.encode(self)
    }
}
```

---

## Backend options

For the POC the priority is iteration speed, not performance.

| Option                           | Complexity | Speed         | Good for POC?         |
| -------------------------------- | ---------- | ------------- | --------------------- |
| **Tree-walking AST interpreter** | Low        | Slow          | ✅ Best fit           |
| Custom bytecode VM               | Medium     | Medium        | Possible              |
| Transpile → TypeScript           | Low–Medium | Fast (V8 JIT) | ✅ Strong alternative |
| Transpile → C                    | Medium     | Fast          | Later stage           |
| LLVM IR                          | High       | Fastest       | Not yet               |

**Recommendation: start with a tree-walking AST interpreter.**

It has no dependencies, the code is easy to read and debug, and it keeps the
feedback loop fast. The interpreter walks the parsed AST directly; no codegen
step.

**Stage 2 backend: transpile to TypeScript.**

Once the language semantics are settled, generating TypeScript from the Hawk AST
is a natural next step:

- TypeScript shares nearly all of Hawk's intended properties (static types,
  async/await, no raw pointers).
- The generated code is readable and auditable.
- V8's JIT gives real-world performance for free.
- It avoids designing a GC, memory model, or instruction set before the language
  is stable.

LLVM or a custom VM would make sense for a v1.0 release, but not during the POC.

> Note: the table above concerns the POC. The eventual production runtime — a
> tiered VM (bytecode interpreter → Cranelift JIT) — is described under
> [Future Considerations → Backend options](#backend-options-1).

---

## Implementation language

The parser, type-checker, interpreter, and LSP will all be written in the same
host language. Criteria:

- Fast iteration (good REPL or test cycle)
- Strong parser ecosystem
- Comfortable to bootstrap from (i.e., hawk eventually reimplements its own
  tools — the host language should be a style the hawk team knows well)
- Good LSP / tooling support for the implementation itself

| Language       | Parser ecosystem            | Iteration speed | Bootstrap path      | Notes                                         |
| -------------- | --------------------------- | --------------- | ------------------- | --------------------------------------------- |
| **TypeScript** | Chevrotain, nearley, peg.js | Fast            | Transpile TS→Hawk   | Strong match; many LLMs also know TS well     |
| **Dart**       | petitparser, built_parser   | Fast            | Transpile Dart→Hawk | Good if team already uses Dart; pub ecosystem |
| Python         | lark, PLY, parsimonious     | Fast            | Awkward             | Best for throw-away prototypes                |
| Rust           | pest, nom, chumsky          | Slow iteration  | Natural             | Right choice for a production compiler        |
| Go             | participle, pigeon          | Medium          | Natural             | Simple, fast compile                          |

**Decision: Dart for the POC; Rust for a production compiler.**

Dart was chosen over TypeScript for the POC:

- Team familiarity means faster iteration
- `dart compile exe` produces a single native binary, directly mirroring Hawk's
  own distribution goal
- Dart 3's sealed classes and exhaustive switch are a natural fit for AST-heavy
  compiler code
- The bootstrap path (Dart → rewrite in Hawk) is as clean as any alternative

The toolchain lives in `tool/`; see `docs/phases.md` for the implementation plan
and milestones.

When the language design stabilises and bootstrap becomes the goal, rewriting
the compiler in Rust (or in Hawk itself) is the natural path.

---

## Stage 1 milestones (POC)

1. **Language spec (this doc + examples)** — agree on surface syntax and
   semantics before writing code.
2. **Lexer + parser → AST** (TypeScript, Chevrotain or hand-written recursive
   descent). Target: parse the code samples above without errors.
3. **Type-checker** — resolve nominal types, check function signatures, catch
   Result/non-Result mismatches.
4. **Tree-walking interpreter** — execute the AST. Support: let/mut bindings,
   functions, Result propagation with `?`, basic collections, `match`.
5. **REPL** — interactive read-eval-print loop for rapid experimentation.
6. **TypeScript emitter (optional POC stretch)** — emit valid TypeScript from
   the Hawk AST; run it with Bun.
7. **Formatter** — single opinionated pretty-printer (like `gofmt`).

---

## Open design questions

- **Concurrency: beyond single-threaded fibers** — the current model is
  single-threaded cooperative fibers: simple, no synchronization needed, but no
  CPU parallelism. Two directions worth revisiting if parallelism becomes a
  requirement:
  - _Immutable-only sharing:_ allow multiple threads, but fibers may only share
    immutable values across thread boundaries. Limitation: an immutable variable
    reference does not guarantee an immutable object graph, so this is harder to
    enforce than it appears without deeper type-system support.
  - _Thread-isolated heaps:_ multiple threads each run their own fiber scheduler
    with a private heap; no shared memory between threads. Threads communicate
    only by passing serialized/copied values. Removes the need for
    synchronization primitives while enabling CPU parallelism. Unclear what the
    right problem domain is for this vs. the simpler single-threaded model;
    deferred.
- **Visibility / access control** — how are public vs. private symbols
  distinguished? Options include: a `pub` keyword on declarations (Rust style),
  a naming convention (leading `_` = private, Go style), an explicit `export`
  list at the bottom of a file (ES module style), or a separate interface file.
  This is needed to hide implementation details such as `native fn` bindings and
  internal helper types from the public API of a module. Unresolved.
- **Module / package system** — file-per-module (Go style) or explicit `import`
  declarations?
- **Generics** — parametric only, or do we need constraints/bounds from day 1?
- **Numeric tower** — single `Int`/`Float` or sized types (`Int32`, `Int64`)?
- **String interpolation** — `"Hello, ${name}"` or a separate `fmt` function?
- **Interface dispatch** — static (monomorphisation) or dynamic (vtable)?
- **Decorator semantics** — compile-time metadata only, or runtime hooks?
- **Process spawning ergonomics** — method call (`run("git", [...])`) or a
  shell-string shorthand (`$("git status")`)? The former is safer (no shell
  injection); the latter is more familiar to shell scripters.
- **Streams** — how does the language handle piping stdout of one process into
  another? Lazy iterators? An explicit pipe operator?
- **Script mode** — should `main` be optional for simple one-file scripts, the
  way Python and Node allow top-level statements?
- **Package manager** — Go-style URL imports, or a central registry (npm/PyPI
  style)? Relevant early because stdlib scope decisions depend on it.

### Error ergonomics: implicit Result promotion and `throw`

Two related ideas for reducing boilerplate in `Result`-returning functions:

**1. Implicit `Ok` wrapping on `return`**

In a function returning `Result<T, Error>`, a bare `return foo` auto-promotes to
`return Ok(foo)`. Explicit `return Ok(foo)` remains valid. This makes the happy
path read like a non-Result function.

**2. `throw` as sugar for `return Err(...)`**

`throw expr` in a `Result`-returning function desugars to `return Err(expr)`. No
stack unwinding, no exceptions — purely a shorthand for the error return path.
The keyword is familiar to developers but takes on entirely new, value-based
semantics.

Combined with `?` for propagation, a full example:

```hawk
fn parse_port(s: String) -> Result<Int, Error> {
    let n = s.parse<Int>()?;               // propagate parse error
    if n < 1 || n > 65535 {
        throw 'port out of range: ${n}';   // return Err(...)
    }
    return n;                              // return Ok(n)
}
```

Open questions: Does explicit `return Ok(foo)` still work (almost certainly
yes)? How does this interact with `Result<Result<T,E>, E>` return types? Is
`throw` the right keyword, or something else (e.g. `fail`, `raise`)?

### Error ergonomics: Zig-style `try` / `catch` keywords

Zig repurposes `try` and `catch` as purely value-based syntax over error types,
with no exceptions or stack unwinding:

- `try expr` — propagate error to caller (equivalent to `?`)
- `expr catch fallback` — evaluate to `fallback` if `expr` is an error
- `expr catch |e| { ... }` — handle the error inline

This is an alternative (or complement) to `?` that some find more readable. Hawk
currently uses `?`; `catch` as an inline default handler is worth considering as
an additional form.

### Option types vs. nullable type system

This decision is deferred. The tradeoffs:

**Option types** (`Option<T>` = `Some(value)` | `None`) treat absence as a data
structure. Best suited to functional/correctness-focused languages (Rust,
Haskell, Swift, Scala).

- Pro: can represent nested absence (`Option<Option<T>>`); composes naturally
  with `.map()`, `.filter()`, `.flat_map()` pipelines.
- Con: requires explicit unwrapping or pattern matching everywhere; may carry
  allocation overhead unless the compiler optimizes it away (e.g. Rust's null
  pointer optimization).

**Nullable type systems** (`String?` vs `String`) treat absence as a
compile-time type state with zero runtime cost. Best suited to pragmatic,
multi-paradigm languages prioritising velocity (Kotlin, TypeScript, C#, Dart).

- Pro: zero boilerplate; clean ergonomics via `?.`, `??`, and compiler
  smart-casts; no wrapper overhead at runtime.
- Con: cannot represent nested absence (`String??` flattens to `String?`);
  relies on built-in operators rather than general-purpose library structures.

The current language.md documents `Option<T>` as a placeholder. Once there is
enough real Hawk code to judge which approach creates less friction in practice,
this should be revisited.

## Future Considerations

### Backend options

This concerns the eventual _production_ runtime — how a real Hawk app executes,
not the POC tree-walking interpreter. Priorities, in order:

1. **Fast startup**, measured as _source/IR → running_, not just AOT process
   launch. A short-lived CLI tool should feel instant.
2. **Reasonable steady-state performance** — good enough for real work; not a
   goal to beat C.
3. **Mature, broad toolchain** — fewer codegen bugs, and support for the chips
   people actually ship CLI tools to.
4. **Managed memory** — a GC, without having to invent a world-class one up
   front.

#### Direction: a tiered VM (bytecode interpreter → Cranelift JIT)

The chosen path is to own the execution pipeline: compile Hawk to our own
bytecode, run it immediately in a fast interpreter, and JIT only the hot code to
native via Cranelift.

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
  stdlib. A compile step (a subcommand, or invoked implicitly for
  `hawk run foo.hawk`) produces bytecode. This runtime is a **Rust** component,
  aligning with the planned production-compiler-in-Rust trajectory.
- **The interpreter tier earns its place for the CLI domain.** A CLI tool
  starts, does bounded work, and exits — most code paths run _once_. A
  JIT-everything design pays compile latency on first call with no steady-state
  to amortize it against; the interpreter runs that code immediately at zero
  compile cost, and Cranelift is spent only on genuine hot loops.
- **Static typing is the key simplifier.** The complexity in V8/SpiderMonkey/
  PyPy comes from _speculation_: hidden classes, inline caches, type feedback,
  and deoptimization. Hawk's bytecode carries concrete types, so the JIT does
  straight-line typed lowering with no guards and no deopt — roughly 80% of what
  makes a tiered VM hard simply does not apply.

#### The bytecode: our own, stack-based

- **Stack-based**, for a trivial frontend (no register allocation) and a simple
  interpreter. The classic choice (JVM, CPython, Wasm).
- **Stack form does not impede the JIT.** Lowering stack bytecode to Cranelift's
  SSA IR is a standard transform — reconstruct SSA values by abstractly
  interpreting the operand stack at compile time. This is exactly how Wasmtime
  lowers (stack-based) Wasm into Cranelift, so the whole
  frontend-emits-stack-code → Cranelift-builds-SSA path has a production
  precedent.
- **Roll our own rather than reuse Wasm/JVM/CPython bytecode.** Every
  off-the-shelf option discards Hawk's static types in a usable form (Wasm GC's
  data model is also immature and awkward), forcing an impedance-mismatch
  re-encoding _and_ losing the type info that keeps the JIT speculation-free. A
  bytecode that carries Hawk's types is both easier to target and easier to
  lower. A register-based bytecode is a later optimization (fewer dispatches per
  op), deferred.
- **The bytecode is the durable artifact**; Cranelift IR is ephemeral, generated
  from hot bytecode at JIT time and discarded. Shipping pre-compiled bytecode
  removes parse + type-check from the startup path.

#### Garbage collection

The two-tier stack (interpreter and JIT frames interleaved) is what makes root
finding interesting.

- **Start with our own precise, non-moving mark-sweep, interpreter-only.** We
  control the value stack and the typed bytecode says exactly what is a pointer,
  so precise roots are easy — and it is a satisfying build.
- **When the Cranelift tier lands**, JIT frames need roots too: either emit
  Cranelift safepoints/stackmaps (precise, but the stackmap API is fiddly and
  has historically been in flux), or keep interpreter roots precise and
  **conservatively scan JIT frames** (a known hybrid, less work). The hybrid
  forces the GC to stay **non-moving**.
- **Boehm (bdwgc) is the zero-effort escape hatch** — conservative across both
  tiers, no stack maps anywhere (the Crystal playbook) — if GC is not where we
  want to spend effort.
- **Constraint on the future:** non-moving is plenty for v1, but a
  moving/generational GC later requires _full_ precision including the JIT, so
  avoid baking in conservative-everywhere if generational is a someday-goal.

#### Options considered and rejected

- **Wasmtime as the runtime.** The Wasm sandbox fights Hawk's central use case:
  subprocess spawning and broad filesystem access are exactly what it restricts,
  and WASI has no mature subprocess/exec API — so shelling out (see the `git`
  example above) would require hand-written host shims, eroding the sandbox's
  value while adding friction. The Component Model `.wit` story is mature for
  host↔guest _binding composition_, not for calling arbitrary native libraries.
  And we would be betting memory management on Wasmtime's Wasm GC, its newest
  and least battle-tested subsystem (GCs also take years to mature in
  _performance_, not just correctness). Emitting Wasm as a _secondary_ target
  for browser or plugin sandboxing remains fine later — just not the primary CLI
  runtime.
- **LLVM as the JIT.** LLVM is a re-targetable _optimizing_ pipeline; compile
  latency is high by design — the wrong tool for a fast-startup JIT. (Cranelift
  exists precisely because Wasmtime needed acceptable code at a fraction of
  LLVM's compile time.)
- **Transpiling to another platform** (Go, TypeScript, C). A reasonable analysis
  — Go in particular maps the fiber model onto goroutines almost for free — but
  it cedes ownership of the execution pipeline, which is the part of this
  project worth building.

#### Alternative JIT engines (for the Tier 1 slot)

Cranelift is the mature default (Rust, battle-tested in Wasmtime; targets
x86-64, aarch64, riscv64, s390x — modern desktop/server, though not 32-bit or
embedded). Two interesting alternatives, decidable later since the bytecode is
the stable interface:

- **Copy-and-patch compilation** (CPython 3.13's experimental JIT). Precompile
  per-opcode "stencils" at build time; at runtime, codegen is essentially
  `memcpy` + patching immediates — far faster than even Cranelift, with code
  quality between interpreter and optimizing JIT, and a smaller runtime
  dependency. Best fit for minimizing source→running latency.
- **MIR** (Makarov's lightweight JIT IR) — fast compilation, ~70% of `gcc -O2`
  output at a fraction of the compile time. C-based, lighter than Cranelift,
  less mature.

#### Staged path

1. **Dart POC tree-walker** (already the plan) — settle semantics.
2. **Define the bytecode** — the stable IR / distribution format; statically
   typed, so compact and untagged.
3. **Rust runtime: bytecode interpreter + precise non-moving mark-sweep GC.**
   This alone runs real Hawk apps with fast startup, and may handle most
   short-lived CLI work without ever tiering up.
4. **Add the Cranelift JIT tier** for hot functions (or trial copy-and-patch);
   decide JIT root strategy here.
5. **AOT via `cranelift-object`** later — single-binary distribution and
   self-hosting — optional, not on the startup-critical path.

#### Execution pipeline

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
  takes effect on the *next* call — the in-flight invocation finishes in the
  interpreter (no on-stack replacement to start; OSR is deferred).
- **Counters at calls *and* loop back-edges.** Call counts miss a hot loop
  inside one long-running function; a back-edge counter catches those. For
  run-once CLI code, calls dominate — which is why only genuine hot loops tier
  up.
- **The value-representation boundary** is the main latent refactor: the JIT
  wants the untagged, typed values the format already carries, while the Tier-0
  interpreter starts with a tagged `Value`. When the JIT lands, interpreted and
  compiled frames must share a representation, so the JIT tier is what forces
  the tagged→untagged move (and it is entangled with precise GC roots).

#### Persistence and bootstrap

`bin/hawk` is the Rust runtime (interpreter + JIT + GC) with an **embedded
`frontend.hawkbc`** (the front-end, compiled to bytecode, `include_bytes!`'d in).
`hawk run foo.hawk` runs that embedded front-end *on our own interpreter*; it
parses `foo.hawk`, emits a `Module`, and runs it. The front-end is just another
Hawk program riding the runtime — the self-hosting endgame.

This means the **native-function table is an ABI**: every `native fn` in
`sdk/std/` maps to a runtime native, and persisted bytecode references them.
Natives are bound **by name, resolved at load** (Wasm-style imports), not by
baked index — so bytecode stays robust across runtime versions and a separate
emitter (the Dart front-end) need not hard-code an index table. The names live
in the constant pool.

Three long-term arcs get us there:

1. **Interpreter runs `.hawkbc`** — decode → `Module` → run; needs an
   entry/args convention and a real native/stdlib surface.
2. **Dart front-end emits `.hawkbc`** — the linchpin. It adds a *bytecode
   emitter backend* (alongside its tree-walker) targeting our exact
   format/opcodes/native-ABI. This is what runs real Hawk programs on the Rust
   runtime *and* the bootstrap compiler that produces the first
   `frontend.hawkbc`.
3. **Hawk front-end emits `.hawkbc`** — self-hosting; bootstrapped by arc 2
   compiling the Hawk-written front-end the first time.

The Dart toolchain must therefore be maintained — parsing current Hawk and
emitting bytecode — until the Hawk front-end can compile itself.
