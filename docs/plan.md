# Aero: POC Plan

## Target domain: CLI tooling

Aero targets the same space as Python, Go, and Node — scripting, automation, and
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

```aero
// First-class process execution — returns Result<Output, ProcessError>
fn get_branch() -> Result<String, Error> {
    let out = run("git", ["rev-parse", "--abbrev-ref", "HEAD"])?;
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

```aero
// Nominal struct types; fields immutable by default
type User = {
    id: Int,
    name: String,
    email: String,
}

// Functions have explicit return types
fn greet(user: User) -> String {
    "Hello, ${user.name}!"
}

// let = immutable binding; mut = mutable
fn double(x: Int) -> Int {
    let result = x * 2;
    result
}
```

### Errors as values

```aero
// Result<T, E> is the only error mechanism — no exceptions
fn parse_id(s: String) -> Result<Int, ParseError> {
    s.parse<Int>()
}

// ? propagates the error to the caller (like Rust's ?)
fn fetch_user(id: Int) -> Result<User, Error> {
    let resp = http.get("/users/${id}")?;
    json.decode<User>(resp.body)
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

```aero
// Data pipelines: transform instead of mutate
fn active_names(users: List<User>) -> List<String> {
    users
        .filter(u => u.active)
        .map(u => u.name.trim())
        .sort()
}
```

### Concurrency (fiber model)

All I/O looks synchronous. No `async`/`await`, no `Future<T>`. The runtime
parks the current fiber when a call blocks and resumes it when I/O completes.

```aero
// fetch_user may block on a network call — the signature doesn't say so.
// No async annotation, no await at the call site.
fn load_dashboard(user_id: Int) -> Result<Dashboard, Error> {
    let user  = fetch_user(user_id)?;
    let posts = fetch_posts(user.id)?;
    return Ok(Dashboard { user, posts });
}
```

### Inline metadata (decorators)

```aero
// Architectural intent sits next to the function signature
@route("GET", "/api/users/{id}")
async fn get_user(req: Request) -> Result<Response, Error> {
    let id   = req.params.get("id")?.parse<Int>()?;
    let user = await fetch_user(id)?;
    Ok(Response.json(user))
}
```

### Composition over inheritance

```aero
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

Once the language semantics are settled, generating TypeScript from the Aero AST
is a natural next step:

- TypeScript shares nearly all of Aero's intended properties (static types,
  async/await, no raw pointers).
- The generated code is readable and auditable.
- V8's JIT gives real-world performance for free.
- It avoids designing a GC, memory model, or instruction set before the language
  is stable.

LLVM or a custom VM would make sense for a v1.0 release, but not during the POC.

---

## Implementation language

The parser, type-checker, interpreter, and LSP will all be written in the same
host language. Criteria:

- Fast iteration (good REPL or test cycle)
- Strong parser ecosystem
- Comfortable to bootstrap from (i.e., aero eventually reimplements its own
  tools — the host language should be a style the aero team knows well)
- Good LSP / tooling support for the implementation itself

| Language       | Parser ecosystem            | Iteration speed | Bootstrap path      | Notes                                         |
| -------------- | --------------------------- | --------------- | ------------------- | --------------------------------------------- |
| **TypeScript** | Chevrotain, nearley, peg.js | Fast            | Transpile TS→Aero   | Strong match; many LLMs also know TS well     |
| **Dart**       | petitparser, built_parser   | Fast            | Transpile Dart→Aero | Good if team already uses Dart; pub ecosystem |
| Python         | lark, PLY, parsimonious     | Fast            | Awkward             | Best for throw-away prototypes                |
| Rust           | pest, nom, chumsky          | Slow iteration  | Natural             | Right choice for a production compiler        |
| Go             | participle, pigeon          | Medium          | Natural             | Simple, fast compile                          |

**Recommendation: TypeScript for the POC; Rust for a production compiler.**

TypeScript lets you write the parser, AST, type-checker, and interpreter
quickly, run them with `ts-node` or Bun, and get a working end-to-end pipeline
in days rather than weeks. The generated-TypeScript backend also closes the
loop: the Aero compiler is itself a TypeScript program that emits TypeScript.

When the language design stabilises and bootstrap becomes the goal, rewriting
the compiler in Rust (or in Aero itself) is the natural path.

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
   the Aero AST; run it with Bun.
7. **Formatter** — single opinionated pretty-printer (like `gofmt`).

---

## Open design questions

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

In a function returning `Result<T, Error>`, a bare `return foo` auto-promotes
to `return Ok(foo)`. Explicit `return Ok(foo)` remains valid. This makes the
happy path read like a non-Result function.

**2. `throw` as sugar for `return Err(...)`**

`throw expr` in a `Result`-returning function desugars to `return Err(expr)`.
No stack unwinding, no exceptions — purely a shorthand for the error return
path. The keyword is familiar to developers but takes on entirely new,
value-based semantics.

Combined with `?` for propagation, a full example:

```aero
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

This is an alternative (or complement) to `?` that some find more readable.
Aero currently uses `?`; `catch` as an inline default handler is worth
considering as an additional form.

### Option types vs. nullable type system

This decision is deferred. The tradeoffs:

**Option types** (`Option<T>` = `Some(value)` | `None`) treat absence as a
data structure. Best suited to functional/correctness-focused languages (Rust,
Haskell, Swift, Scala).

- Pro: can represent nested absence (`Option<Option<T>>`); composes naturally
  with `.map()`, `.filter()`, `.flat_map()` pipelines.
- Con: requires explicit unwrapping or pattern matching everywhere; may carry
  allocation overhead unless the compiler optimizes it away (e.g. Rust's null
  pointer optimization).

**Nullable type systems** (`String?` vs `String`) treat absence as a compile-time
type state with zero runtime cost. Best suited to pragmatic, multi-paradigm
languages prioritising velocity (Kotlin, TypeScript, C#, Dart).

- Pro: zero boilerplate; clean ergonomics via `?.`, `??`, and compiler
  smart-casts; no wrapper overhead at runtime.
- Con: cannot represent nested absence (`String??` flattens to `String?`);
  relies on built-in operators rather than general-purpose library structures.

The current language.md documents `Option<T>` as a placeholder. Once there is
enough real Aero code to judge which approach creates less friction in practice,
this should be revisited.

## Future Considerations

### Backend options

For a language requiring near-instantaneous startup times, clean toolchain
integration, and powerful tiering capabilities, the two frontrunners provide
distinct architectural advantages:

#### 1. The WebAssembly (Wasm) Ecosystem

This route treats Wasm as your primary target format, using an existing runtime
like Wasmtime as your execution engine.

- **The Pipeline:** Frontend $\rightarrow$ Wasm Bytecode $\rightarrow$ Wasmtime.
- **Startup Speed:** Exceptional. Wasm runtimes are highly optimized for
  sub-millisecond initialization.
- **CLI Capability:** Solved via **WASI (Wasm System Interface)**, which
  provides capability-based access to the host file system, environment
  variables, and standard I/O without the sandboxing causing user friction.
- **FFI Story:** Highly mature using the **Wasm Component Model** and `.wit`
  files, which auto-generate the type-safe binding glue between the host and
  your application.
- **Engineering Lift:** **Lowest.** Your self-hosted frontend only needs to emit
  standard stack-based bytecode. The runtime handles all architecture-specific
  JIT/AOT machine code compilation automatically.

#### 2. Direct Cranelift Integration

This route bypasses Wasm entirely, treating Cranelift as a low-level, native
code-generation library directly inside your compiler binaries.

- **The Pipeline:** Frontend $\rightarrow$ Cranelift IR $\rightarrow$ Machine
  Code (JIT/AOT).
- **Startup Speed:** Very fast. Cranelift is explicitly architected to
  prioritize blazing-fast compilation speed over deep optimization loops.
- **CLI Capability:** Absolute. Because Cranelift generates raw native machine
  code directly on the host, your compiled binaries run natively without any
  sandbox constraints or capability mappings.
- **FFI Story:** Standard native FFI. You handle raw system ABI calls (like
  standard C calling conventions) directly through Cranelift IR register
  assignments.
- **Engineering Lift:** **Moderate to High.** Your frontend must map its logic
  to a register-based, Single Static Assignment (SSA) IR structure, and you are
  responsible for managing the execution memory and runtime environment
  yourself.

---

#### The Recommended Hybrid

If you want the best of both worlds, the dominant industry pattern is to **emit
Wasm bytecode first**.

Because Wasmtime uses Cranelift under the hood as its primary JIT engine,
targeting Wasm allows you to instantly tap into the sandboxed CLI toolchain,
mature FFI, and sub-millisecond startup times of the Wasm ecosystem, while
_inheriting_ Cranelift's fast native machine code generation completely for
free.

This approach keeps your self-hosted frontend incredibly lightweight, letting
you focus on language syntax and semantics rather than low-level backend code
generation.
