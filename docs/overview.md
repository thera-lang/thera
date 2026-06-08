# Hawk: An LLM-Native Programming Language

## A Technical Overview & Design Whitepaper

Hawk is a proof-of-concept programming language designed from the ground up to
maximize the productivity of Large Language Models (LLMs) and autonomous coding
agents. While traditional languages are optimized for human cognitive
constraints or mathematical abstraction, Hawk explores a new point in the
language design space: **optimizing for the way AI agents reason, generate, and
refactor code.**

Targeted at scripting, command-line interface (CLI) tooling, and automation,
Hawk combines strong static typing, immutability by default, errors as values,
and a tiered virtual machine runtime to deliver a predictable, fast, and
extremely agent-friendly environment.

---

## 1. What and Why: The LLM-Native Primer

Modern programming languages are shaped by human limits: we prefer short syntax
to save keystrokes, and we often favor semantic whitespace (like Python or YAML)
to enforce clean visual layout. However, as software development transitions
from human developers writing code manually to AI agents managing entire
repositories, these design choices introduce friction:

- **The Mutation Tax:** Dynamic typings and implicit mutations force an LLM to
  scan hundreds of lines backward to build a mental map of a variable's current
  state, consuming valuable attention window/token budget.
- **Structural Fragility:** Semantic whitespace is fragile. An agent injecting
  code via text-diffs is prone to off-by-one indentation errors that break
  compilation or, worse, change the program's logic silently.
- **Invisible Control Flow:** Exceptions (both checked and unchecked) create
  non-linear, invisible control flow jumps. This "spooky action at a distance"
  bypasses static analysis and forces agents to guess where errors might bubble
  up.

### The Target Space: CLI Tooling & Scripting

Hawk focuses directly on the space occupied by Python, Go, and Node.js:
scripting, system automation, and CLI tools. This target domain shapes the
platform:

1. **Batteries-Included Standard Library:** Rather than relying on a fragmented
   ecosystem of third-party packages, Hawk includes robust built-in support for
   the CLI surface (filesystem, processes, argument parsing, HTTP, JSON/YAML,
   path manipulation, and environment variables). This prevents agents from
   hallucinating API signatures of obscure external packages.
2. **Instant Startup Time:** Command-line scripts must feel instant. Hawk's
   execution model prioritizes low startup overhead, ensuring that short-lived
   utilities do not suffer from compilation or warm-up latency.
3. **Ergonomic Subprocesses:** Spawning subprocesses and piping I/O is a core
   scripting activity. Hawk makes process execution first-class, returning exit
   codes and outputs as predictable typed results.
4. **Single-Binary Distribution:** Distributing scripting tools is simplified
   via a compiled, self-contained executable, matching the deployment ergonomics
   of Go.

---

## 2. A Simple Introduction to the Language

Hawk features a clean, brace-delimited syntax that combines the safety of
functional core paradigms with the direct execution flow of imperative shells.

### Walkthrough: `wordcount.hawk`

To understand how Hawk looks and behaves, let us examine the complete
implementation of a word counting tool:

```hawk
import std.fs;
import std.cli;

type Counts = {
    lines: Int,
    words: Int,
    bytes: Int,
}

fn count(_ text: String) -> Counts {
    return Counts {
        lines: text.lines().len(),
        words: text.split_whitespace().len(),
        bytes: text.byte_len(),
    };
}

fn main(parameters: List<String>) -> Result<Int, Error> {
    let args = cli.Args.new(parameters);
    let path = args.positional(0).ok_or(Error('usage: wordcount <file>'))?;
    let text = fs.read_text(path)?;
    let c    = count(text);

    println('${c.lines}\tlines');
    println('${c.words}\twords');
    println('${c.bytes}\tbytes');

    return Result.Ok(0);
}
```

#### Line-by-Line Breakdown:

- **Lines 1–2:** `import std.fs;` and `import std.cli;` import standard library
  namespaces. In Hawk, imports are path-based. The trailing segment of the path
  (e.g., `fs` or `cli`) automatically becomes the namespace used to qualify
  public members.
- **Lines 4–8:** `type Counts = { ... }` declares a nominal struct. Struct
  fields in Hawk are immutable by default, preventing unexpected side-effects.
- **Line 10:** `fn count(_ text: String) -> Counts` defines a function. The
  leading underscore `_` in the parameter signature suppresses the call-site
  argument label. By default, Hawk parameters are named at call sites (e.g.,
  `greet(name: 'alice')`). Using `_` allows natural-reading unqualified
  arguments where the context makes the role obvious.
- **Line 18:** `fn main(parameters: List<String>) -> Result<Int, Error>` is the
  program's entry point. It receives arguments as a `List<String>` and returns a
  `Result` containing either the exit code (`Int`) or a structured `Error`.
- **Line 19:** `let args = cli.Args.new(parameters);` instantiates the
  command-line parser. Hawk variables are bound using `let` and are strictly
  immutable by default. To make a binding reassignable, the developer must
  explicitly use `let mut`.
- **Line 20:** `args.positional(0).ok_or(...)?` handles potential absence.
  `args.positional(0)` returns an `Option<String>` (which is either
  `Some(value)` or `None`). The `.ok_or()` helper converts this `Option` into a
  `Result<String, Error>`, and the postfix `?` operator propagates the error
  back to the caller if it is an `Err`.
- **Line 21:** `let text = fs.read_text(path)?;` reads the file content. Again,
  `fs.read_text` returns a `Result` and the `?` propagates any filesystem errors
  instantly.
- **Lines 24–26:** Interpolation in string literals (single quotes) is supported
  via `${}`. This interpolation requires that the interpolated variables
  implement the standard `Display` interface.

---

### Visibility, Libraries, and Barrels

Hawk uses the physical source file as its fundamental privacy boundary. Any
top-level declaration (`fn`, `type`, `enum`, `const`, `interface`) is private to
its source file unless prefixed with the `pub` keyword:

```hawk
pub fn format_date(_ d: Date) -> String { ... }   // Visible to importers
fn pad2(_ n: Int) -> String { ... }               // Private to this file
```

To aggregate a directory of related files into a single importable namespace,
Hawk uses the **barrel** pattern (a directory library):

1. An import path like `import std.cli` resolves to a file inside the standard
   library directory. If `std/cli.hawk` exists, it is loaded.
2. Otherwise, if `std/cli/` is a directory, the loader searches for the barrel
   file named after the directory: `std/cli/cli.hawk`.
3. The barrel file re-exports other sibling files in its directory using the
   `pub import` syntax:
   ```hawk
   // std/cli/cli.hawk (the barrel)
   pub import 'args';
   pub import 'parser';
   ```
   This aggregates multiple source files into a single namespace for the
   consumer while maintaining clean, file-granular compilation boundaries.

### Testing Conventions & White-Box Access

Hawk establishes first-class testing conventions directly in the language
tooling.

- Test files are co-located in the same directory using a `_test` suffix:
  `math.hawk` is tested by `math_test.hawk`.
- Test functions are annotated with `@test`, take no arguments, and return
  `Result<Void, Error>`.
- Because testing is co-located, when `math_test.hawk` imports its sibling
  `'math'`, the front-end automatically grants it **white-box access** to the
  target's private symbols. This avoids having to expose internal implementation
  details to the general public API just to write unit tests.

---

## 3. High Points of Leverage for LLM Productivity

Hawk's syntax and semantics are carefully tuned to give AI coding agents maximum
leverage, ensuring they can produce correct code, refactor easily, and avoid
common cognitive errors.

```
                      ┌─────────────────────────────────┐
                      │    LLM / Autonomous Agent       │
                      └────────────────┬────────────────┘
                                       │
            ┌──────────────────────────┼──────────────────────────┐
            ▼                          ▼                          ▼
   [Predictability]             [AST Sight]              [Diff Resilience]
   • Immutability by default    • Strong nominal typing  • Explicit braces
   • Errors as values           • High-level GC          • Namespace-bound imports
   • Single-threaded fibers     • Precision LSP query    • Single opinionated formatter
```

### I. Strong Nominal Static Typing

In Hawk, nominal types and straightforward generics act as a deterministic
boundary. When an LLM generates code, the static type-checker acts as an
immediate sanity check, pruning probabilistic hallucinations before code is run.
Because the type system is simple and nominal, it avoids complex,
turing-complete type resolution loops that exhaust context tokens and produce
multi-line, cascade error messages.

### II. Fast, Precise AST Queries (LSP Sight)

LSPs are the "eyes" of an AI agent. Hawk's toolchain is designed to expose
quick, precise Abstract Syntax Tree (AST) information. An agent can query the
compiler directly to resolve references, perform semantic renames, and evaluate
scopes. This ensures that agents can refactor codebase layouts semantically
rather than relying on brittle, error-prone regular expression replacements on
raw text.

### III. Immutability by Default

In dynamic or mutable-by-default languages, variables can change state at any
program point. For an LLM to predict execution behavior, it must scan back and
forth to track variables across multiple lines (the "multi-hop attention tax").
In Hawk, bindings are immutable by default, enforcing a single-static-assignment
style. State is transformed via pipeline flows, allowing the model to reason
about code in a purely linear fashion.

### IV. Explicit Braces (Indent-Independent Diffs)

While semantic whitespace (like Python's indentation rules) looks clean to human
eyes, it is highly problematic for coding agents. If a model generates a diff to
inject a block of code and makes an off-by-one indentation error, it either
breaks the AST or changes the nesting logic silently. Hawk enforces explicit
brace-delimited blocks (`{}`), ensuring that code structure is robust to
diff-merges regardless of minor layout variations.

### V. Explicit Errors as Values

Hawk rejects exceptions. Exceptions create implicit control flow jumps (stack
unwinding) that are invisible to the type system, making it easy for agents to
omit error-handling logic. Hawk represents expected failures explicitly as
`Result<T, E>` values. Control flow remains flat and visible, and the type
checker forces the agent to handle or explicitly propagate (via `?`) every
failure path.

### VI. Single-Threaded Fibers

Pattern-matching models fundamentally lack the temporal reasoning required to
handle multi-threaded concurrency, shared memory, and synchronization hazards
(deadlocks, data races). Hawk uses a single-threaded cooperative fiber model.
All asynchronous operations look synchronous at the language level; the runtime
automatically parks and resumes fibers when they block on I/O. Because only one
fiber executes on the thread at any time, agents write clean, concurrent code
without needing mutexes or semaphores.

### VII. Strict, Opinionated Formatter

Stylistic debates consume developer attention and create unnecessary token
variations in training and prompt context. Hawk includes a single, culturally
enforced code formatter (`hawk fmt`). By restricting the layout of code to one
standard representation, it ensures that generated code and reference prompts
match exactly, minimizing token waste and code generation divergence.

---

## 4. The Runtime Architecture

The Hawk runtime is written in Rust, engineered specifically to satisfy the CLI
domain's need for instant startup and stable execution.

```
                  ┌─────────────────────────────────────┐
                  │              bin/hawk               │
                  │  (Self-contained Rust executable)   │
                  └──────────────────┬──────────────────┘
                                     │
           ┌─────────────────────────┴─────────────────────────┐
           ▼                                                   ▼
┌──────────────────────┐                             ┌──────────────────────┐
│  Tier-0 Interpreter  │ ──[Function Call Counter]──►│  Tier-1 Cranelift JIT│
│                      │                             │                      │
│ • Tagged Value model │                             │ • Untagged Lowering  │
│ • Instant execution  │                             │ • Native Machine Code│
│ • Runs run-once code │                             │ • Hot loops / frames │
└──────────────────────┘                             └──────────────────────┘
           │                                                   │
           └─────────────────────────┬─────────────────────────┘
                                     ▼
                        ┌─────────────────────────┐
                        │   Precise Mark-Sweep    │
                        │   Garbage Collector     │
                        └─────────────────────────┘
```

### The Tiered Virtual Machine

To deliver on startup performance and steady-state execution, Hawk employs a
tiered VM pipeline:

1. **Tier-0 Bytecode Interpreter:** When a program starts, it is compiled into a
   lightweight stack-based bytecode format (`.hawkbc`) and run immediately by a
   fast loop interpreter written in Rust. Since most CLI script paths execute
   exactly once, the interpreter bypasses JIT compilation overhead, running the
   code instantly at zero compilation cost.
2. **Tier-1 Cranelift JIT:** Functions contain call counters and loop back-edge
   counters. When a block of code crosses a specific execution threshold
   (identifying it as "hot"), the Cranelift JIT compiler compiles that function
   in the background. Subsequent calls are dispatched directly to the compiled
   native machine code.
3. **Speculation-Free Lowering:** Because Hawk is statically typed and the
   bytecode retains concrete types, the Cranelift compiler performs
   straightforward, typed lowering. The VM has no need for complex speculation
   mechanisms, inline caches, or deoptimization guards, making the JIT tier
   significantly smaller and more reliable than JS or Python JITs.

### Bytecode Specification (`.hawkbc`)

The Hawk bytecode is stack-based, designed to be compact and easy to target.

- **Slot Layout:** Every local variable and operand stack slot occupies a single
  64-bit word. Raw primitives (`Int`, `Double`, `Bool`) store their bit-patterns
  directly, while reference types (`String`, structs, enums, lists) store heap
  pointers.
- **Type-Aware Ops:** Opcodes are typed (e.g., `add.i64` vs. `add.f64`). Because
  the type layout of the stack is statically known at every program point, value
  slots carry no runtime tags in their final form.
- **The Bootstrapping Tagged Option:** To simplify early development, the
  initial Tier-0 interpreter uses a tagged `Value` enum (`Int(i64)`,
  `Double(f64)`, etc.), deferring precise stackmaps. Once the instruction set
  architecture (ISA) stabilizes, it refactors to untagged slots.

### Garbage Collection Strategy

Hawk manages heap allocations using a precise, non-moving mark-sweep garbage
collector.

- **Safepoint Stackmaps:** Since bytecode slots are untagged, the compiler emits
  a bitmap (a stackmap) at every allocating operation and function call
  safepoint, identifying which local and stack slots contain heap pointers.
- **Tracing:** Tracing traverses the stack using these stackmaps, and inspects
  heap objects which carry their `TypeDef` headers to find nested references.
- **Non-Moving Guarantee:** The JIT and interpreter frames interleave on the
  execution stack. To avoid the complexity of updating references in compiled
  frames, the GC remains non-moving, allowing conservative scans of JIT frames
  where stackmap APIs are unavailable.

### Self-Hosting and the Native ABI

The `hawk` executable is a standalone binary. It contains the Hawk compiler
front-end pre-compiled to bytecode (`frontend.hawkbc`) and embedded directly
into the Rust executable via `include_bytes!`.

When running `hawk run script.hawk`, the VM runs the embedded front-end bytecode
on its interpreter to parse and compile the user script into an in-memory
`Module`, which it then executes. This bootstrap path ensures that the front-end
remains a regular Hawk program, laying the groundwork for self-hosting.

Native standard library functions are declared in Hawk via the `native fn`
syntax and bound to the runtime using the `@extern('symbol_name')` decorator.
The bytecode resolves these native symbols by name at load time (similar to
WebAssembly imports), ensuring that compiled `.hawkbc` files remain compatible
across different versions of the runtime binary.

---

## 5. Key Design Choices & Trade-offs

During the design of Hawk, several architectural junctions presented multiple
paths. The team resolved these choices based on the core goal of LLM
productivity and CLI-domain requirements:

### I. Closure Variable Capture: Shared-State vs. Snapshots

When a closure captures a variable from its enclosing scope, languages usually
choose between capture-by-value (like Java's final variable snapshot) or
capture-by-reference (like JavaScript closures).

- **The Decision:** Hawk implements **Capture by Reference / Mutable Capture**
  for captured mutable local variables.
- **The Mechanism:** To avoid pointer-tracking overhead in the VM, the front-end
  compiler performs a rewriting pass. If a mutable local variable is captured by
  a closure, the front-end boxes that local into a single-field heap cell (a
  structure reference). All reads and writes to that local in the enclosing
  scope and inside the closure are compiled as structural field access
  (`field.get`/`field.set`). The closure captures only the reference to this
  cell, keeping variables shared without introducing complex pointer-aliasing
  rules to the runtime. Immutable captures are copied by value.

### II. Interface Dispatch: Static Call Compilation

Interfaces describe type capabilities (e.g., `Display` and `Eq`). Virtual
dispatch usually requires a dynamic vtable search.

- **The Decision:** Hawk optimizes for concrete types. Today, the front-end
  compiler resolves methods statically at compile time wherever the concrete
  receiver type is known, emitting direct `call` instructions (including for
  interpolation and `==`).
- **Future JIT Devirtualization:** A dynamic vtable instruction
  (`call.interface`) is reserved for type-erased values (trait objects). When
  compiled, the Cranelift JIT devirtualizes these calls to direct or inline
  invocations wherever the receiver type can be statically proved, preserving
  compilation simplicity while maintaining peak performance.

### III. Braces vs. Significant Whitespace

- **The Decision:** Hawk explicitly chose curly braces `{}` and semicolons for
  blocks and statement boundaries.
- **The Rationale:** LLMs are excellent at writing code but struggle with
  precise structural indent formatting when applying edits. Diff engines (used
  by autonomous coding agents to insert code blocks) frequently introduce
  off-by-one whitespace errors. By using explicit brace boundaries, a line that
  is poorly indented still parses and compiles perfectly, eliminating syntactic
  fragility and preventing structural code-generation errors.

### IV. Option<T> vs. Nullable Types

- **The Decision:** Hawk completely eliminates `null`. Absence is modeled
  explicitly via the algebraic `Option<T>` enum.
- **The Rationale:** Nullable type systems (e.g., `String?` with `?.` operators)
  reduce boilerplate, but they cannot represent nested absence (e.g., an
  optional field containing an optional value, `Option<Option<T>>`).
  Furthermore, explicit enums integrate seamlessly into functional `match`
  blocks, forcing the agent to exhaustively cover the absent case.

### V. String Indexing and UTF-8 Safety

- **The Decision:** Hawk strings are stored as UTF-8, and direct integer
  indexing (e.g., `str[i]`) is forbidden.
- **The Rationale:** Direct byte or character indexing on UTF-8 strings often
  cuts emoji or multi-byte characters in half, producing corrupt string states.
  To prevent agents from writing buggy indexing logic, Hawk requires explicit
  iteration via `.chars()` (Unicode code points) or `.graphemes()`
  (user-perceived characters), making unicode safety the default.

### VI. Rejected Architectures

- **Wasmtime as the Primary Runtime:** WebAssembly sandboxing is excellent for
  isolation, but it restricts subprocess spawning (`exec`) and raw filesystem
  access. Since scripting and shelling out are core CLI needs, trying to shim
  WASI to support subprocesses was rejected as it eroded Wasm's security model
  while adding API friction.
- **LLVM as the JIT Compiler:** LLVM is a world-class optimizing compiler, but
  its compilation latency is high. For short-lived scripting utilities, the time
  spent compiling in LLVM would exceed the script's execution time. Cranelift
  was chosen because it compiles machine code orders of magnitude faster.
- **Transpilation:** Transpiling to Go or TypeScript would provide an easy
  runtime, but ceding control of the compiler pipeline would limit the ability
  to preserve static type metadata in the execution bytecode, which is the key
  feature that makes the JIT speculation-free.
