# Hawk language reference

**What this is:** the reference for Hawk's syntax and semantics, the standard
`hawk` tool, and open language-design questions. An informal working reference,
not a formal spec. The concrete syntax — keyword set, operator precedence, and
every production in EBNF — is in [grammar.md](grammar.md). For the _why_ see
[guidelines.md](guidelines.md); for how programs execute see
[bytecode.md](bytecode.md) and [architecture.md](architecture.md).

---

## Style

- **Indent:** 4 spaces (no tabs).
- **Line length:** 100 characters. Soft limit — the formatter wraps where it
  improves readability but does not enforce a hard break at 100.

---

## Entry point

Every program defines a `main` function. It receives the program arguments as a
`List<String>`; the returned `Int` is the process exit code. An `Error` result
exits non-zero and prints the error message to stderr. For flag/positional
parsing, import `std.cli` and wrap the arguments in `Args`.

```hawk
import std.cli;

fn main(parameters: List<String>) -> Result<Int, Error> {
    let args = cli.Args.new(parameters);
    // ...
    return Result.Ok(0);
}
```

`main` may also be written with no parameters (`fn main() -> …`) when it doesn't
need the arguments.

---

## Variables

Bindings are immutable by default. Use `mut` to allow reassignment.

```hawk
let x = 42;
let name = 'alice';

let mut count = 0;
count = count + 1;
```

`let` vs `mut` controls whether a _binding_ can be reassigned — it says nothing
about the value itself. Heap values (`String`, `List`, `Map`, `Set`, structs,
enums) are **shared references**: assigning or passing one copies the reference,
not the object, so two bindings to the same mutable collection observe each
other's changes. Immutability is enforced by the type system — struct fields are
immutable by default and `let` prevents rebinding — rather than by copying
values.

---

## Types

### Primitives

| Type     | Description                                                 | Example         |
| -------- | ----------------------------------------------------------- | --------------- |
| `Int`    | 64-bit signed integer                                       | `42`, `-7`      |
| `Double` | 64-bit floating-point                                       | `3.14`          |
| `Bool`   | Boolean                                                     | `true`, `false` |
| `String` | UTF-8 text                                                  | `'hello'`       |
| `Void`   | Unit type — one value, written `void` (like `true`/`false`) | `void`          |

String literals use single quotes, and may span multiple lines. Interpolation
uses `${}`, and `+` concatenates two strings:

```hawk
let greeting = 'Hello, ${name}!';
let path = dir + '/' + name + '.hawk';
```

### Collections

| Type        | Description                           | Example               |
| ----------- | ------------------------------------- | --------------------- |
| `List<T>`   | Ordered sequence                      | `[1, 2, 3]`           |
| `Map<K, V>` | Key-value store                       | `{'a': 1, 'b': 2}`    |
| `Set<T>`    | Unordered collection of unique values | `Set.from([1, 2, 3])` |

```hawk
let names: List<String>      = ['alice', 'bob'];
let scores: Map<String, Int> = {'alice': 10, 'bob': 7};
let tags: Set<String>        = Set.from(['cli', 'tool', 'cli']);  // {'cli', 'tool'}
```

### Open questions

- **`Char`** — single character type (like Rust's `char` or Go's `rune`)? Most
  CLI use cases are satisfied by `String`; leaving this out keeps the type
  surface smaller. Deferred.
- **`Bytes`** — raw byte sequence, needed for binary I/O and HTTP bodies. Likely
  a stdlib type (`std.bytes`) rather than a built-in primitive.
- **`Tuple`** — anonymous fixed-size heterogeneous record, e.g. `(Int, String)`.
  Useful for multi-return but adds syntax complexity. Deferred.
- **Integer sizes** — a single `Int` (64-bit) covers most CLI needs. Explicit
  sized types (`Int32`, `Int64`) may be needed later for binary formats or FFI.

---

## Structs

Structs are nominal types. Fields are immutable by default.

```hawk
type Point = {
    x: Double,
    y: Double,
}

let p = Point { x: 1.0, y: 2.0 };
println('${p.x}, ${p.y}');
```

---

## Functions

```hawk
fn add(a: Int, b: Int) -> Int {
    return a + b;
}
```

Functions with no meaningful return value omit the return type annotation; it
defaults to `Void`. The two forms below are equivalent:

```hawk
fn log(_ msg: String) -> Void { println(msg); }
fn log(_ msg: String)         { println(msg); }
```

Functions are first-class values. Lambdas use `=>`:

```hawk
let names = users.map(u => u.name);             // single parameter
let sum = nums.fold(0, (acc, n) => acc + n);    // parenthesized, multiple
```

A function-typed value is written `(T1, T2) -> R` (the zero-argument form is
`() -> R`), so lambdas can be passed to and returned from functions:

```hawk
fn apply(f: (Int) -> Int, _ x: Int) -> Int { return f(x); }

fn adder(by: Int) -> (Int) -> Int {
    return n => n + by;          // captures `by`; returned as a closure
}
```

**Parameter types.** A lambda parameter's type comes from its annotation, or —
when omitted — from the surrounding context: the parameter type of the function
or method it's passed to, a `let` binding's declared type, or the enclosing
function's return type. The bare single-parameter form `n => …` is shorthand for
`(n) => …`. When neither an annotation nor the context determines a parameter's
type, that's an error (the compiler does not guess) — add an annotation:

```hawk
nums.map(n => n * 10);            // n: Int — from map's (T) -> U signature
let double = (x: Int) => x * 2;   // no context here, so x is annotated
```

A lambda may **capture** variables from its enclosing scope (including `self`
inside a method). An immutable binding is captured **by value** (capturing a
reference value — a struct/list/`self` — still observes mutations to the object
it points at). A captured `mut` local is **shared**: the closure and the
enclosing scope see each other's reassignments, because the frontend boxes
captured `mut` locals into a heap cell and closes over the cell (see
[bytecode.md](bytecode.md)). See `examples/closures.hawk`.

### Named parameters

Parameters are named at call sites by default. The parameter name in the
definition becomes the external label:

```hawk
fn greet(name: String, times: Int) { ... }

greet(name: 'alice', times: 3);
```

Use `_` before the parameter name to suppress the label at the call site. This
is appropriate when the type or context makes the argument's role obvious:

```hawk
fn println(_ msg: String) { ... }

println('hello');   // no label — reads naturally
```

Use `external internal` to give a parameter a different external label from its
internal identifier. This is useful when the natural label is a keyword or reads
awkwardly as a variable name inside the function body:

```hawk
fn flag(_ name: String, default value: Bool) -> Bool { ... }

args.flag('--verbose', default: false);
```

Here `default` is the label at the call site; `value` is the name used inside
the function body (avoiding a clash with a potential `default` keyword).

---

## Concurrency

Hawk uses a **single-threaded cooperative fiber model**. All fibers run on one
thread, multiplexed by the runtime scheduler. All I/O calls look synchronous —
there are no `async`/`await` keywords and no `Future<T>` return types. When a
fiber blocks on I/O, the runtime parks it and resumes another; the calling code
never observes the difference.

Because only one fiber runs at a time, there is no shared mutable state between
concurrent fibers and no need for synchronization primitives (mutexes,
semaphores, channels). This avoids the deadlock and data-race hazards of a
multi-threaded model while keeping the programming model simple.

```hawk
// These two functions look identical at the type level.
// fetch_user may park the fiber on a network call; double does not.
// The caller treats them the same way.

fn double(_ x: Int) -> Int {
    return x * 2;
}

fn fetch_user(id: Int) -> Result<User, Error> {
    let resp = http.get('/users/${id}')?;   // may park the fiber
    return json.decode<User>(resp.body);
}

fn main() -> Result<Int, Error> {
    let user = fetch_user(id: 1)?;          // no await needed
    println(user.name);
    return Result.Ok(0);
}
```

Spawning a fiber runs work concurrently on the same thread. Results are returned
via `join()` — the only way to get data out of a fiber:

```hawk
import std.fiber;

let handle = fiber.spawn(() => fetch_user(id: 42));
// ... do other work on this fiber ...
let user = handle.join()?;
```

**Fallback:** if the fiber runtime proves too costly to implement in the POC,
the language will fall back to explicit `async`/`await`. In that model,
functions that perform I/O are marked `async` and callers use `await` — the
traditional colored-function approach. The goal is to avoid this.

---

## Error handling

There are no exceptions. Errors are returned as `Result<T, E>`. `Error` is an
interface (`fn message(self) -> String`); the simple-case error is built with
the `error('...')` constructor (`-> Error`), and domain modules `impl Error` for
their own enums. The `throw '...'` shorthand shown below is still planned sugar
for `throw error('...')`; today write the `error('...')` call explicitly.

```hawk
fn read_port(args: Args) -> Result<Int, Error> {
    let s = args.positional(0).ok_or(Error('usage: serve <port>'))?;
    return s.parse<Int>();
}
```

`Result<T, E>` is an ordinary enum defined in the prelude (`std.core`), with
variants `Ok(T)` and `Err(E)`. It is constructed like any enum — qualified:
`Result.Ok(value)`, `Result.Err(e)`. The `?` operator and the implicit-`Ok`
wrapping below know it by name, but it is otherwise not special.

`?` propagates an `Error` to the caller. `match` handles results at a boundary
(match patterns stay unqualified):

```hawk
match read_port(args) {
    Ok(port) => println('listening on ${port}'),
    Err(e)   => println('error: ${e.message}'),
}
```

### `throw`

`throw expr` is sugar for `return Result.Err(expr)` in a `Result`-returning
function. It is a reserved keyword — not an exception mechanism. There is no
stack unwinding; control simply returns to the caller with an `Err` value.

```hawk
fn parse_port(s: String) -> Result<Int, Error> {
    let n = s.parse<Int>()?;
    if n < 1 || n > 65535 {
        throw Error('port out of range: ${n}');
    }
    return n;   // implicitly Result.Ok(n)
}
```

---

## Option

There is no `null`. Absent values are represented explicitly as `Option<T>`,
which is either `Some(value)` or `None`. A value of type `String` is always a
string; a value that might be absent has type `Option<String>`.

Like `Result`, `Option` is an ordinary prelude enum, constructed qualified:
`Option.Some(value)`, `Option.None`.

```hawk
type Config = {
    host:    String,
    port:    Int,
    log_dir: Option<String>,   // may be absent
}
```

Use `match` to unwrap, or `.ok_or()` to convert to a `Result` when absence
should be treated as an error:

```hawk
match config.log_dir {
    Some(dir) => println('logging to ${dir}'),
    None      => println('logging disabled'),
}

// treat absence as an error and propagate with ?
let dir = config.log_dir.ok_or(Error('log_dir is required'))?;
```

---

## Runtime faults

`Result` and `Option` model _expected_ conditions — a file might be missing, a
parse might fail — and they appear in the type signature so the caller is forced
to deal with them. A **runtime fault** is the opposite: an unrecoverable
programmer error signalling that the code's contract was violated. A fault
**traps** — it immediately aborts the program with a diagnostic and a non-zero
exit code.

Faults are not values. They have no type, cannot be returned, cannot be
propagated with `?`, and cannot be caught — there is no exception mechanism to
catch them. The only correct response to a fault is to fix the code.

Conditions that trap:

- indexing past the end of a list, or with a missing map key (`list[i]`,
  `map[key]`) — see [Collections](#collections)
- integer divide-by-zero
- exhausting memory or the call stack

Where a recoverable alternative makes sense, the API offers one alongside the
faulting form — e.g. `list.get(i)` returns `Option<T>` instead of trapping.
Reach for the checked form when absence is a normal, expected case; use indexing
when a missing element would mean a bug.

> Integer overflow does **not** trap: `Int` arithmetic wraps around (two's
> complement). Divide-by-zero is the trapping case above.

---

## Control flow

```hawk
// if / else
if x > 0 {
    println('positive');
} else {
    println('non-positive');
}

// for-in loop
for item in items {
    println(item);
}

// range
for i in 0..10 {
    println('${i}');
}
```

---

## Collections

```hawk
let nums: List<Int> = [1, 2, 3];
let first = nums[0];
let len   = nums.len();
```

### Indexing vs. `get`

Indexing with `[]` asserts the element is present. `list[i]` and `map[key]`
return the element directly; if the index is out of range or the key is absent,
the program **traps** (see [Runtime faults](#runtime-faults)).

```hawk
let nums = [1, 2, 3];
let x = nums[0];          // 1
let y = nums[9];          // traps — index out of range

let scores = {'alice': 10};
let a = scores['alice'];  // 10
let b = scores['bob'];    // traps — missing key
```

`.get()` is the checked alternative: it returns `Option<T>`, so absence is a
value you handle rather than a fault. Use it whenever a missing element is a
normal, expected case.

```hawk
match nums.get(9) {
    Some(n) => println('got ${n}'),
    None    => println('out of range'),
}

let score = scores.get('bob').ok_or(Error('no score for bob'))?;
```

Both `List` and `Map` follow the same rule: `[]` traps on absence, `.get()`
returns `Option`.

### Pipelines

Common pipeline methods (lazy; call `.to_list()` to materialise):

```hawk
let evens = nums.filter(n => n % 2 == 0).to_list();
let doubled = nums.map(n => n * 2).to_list();
```

---

## Imports

Libraries are imported by path. The last path segment becomes the namespace used
to reference the library's public members:

```hawk
import std.fs;
import std.process;

let text = fs.read_text('config.toml')?;
```

Use `as` to give the import an explicit prefix. This is useful when the default
segment is ambiguous, conflicts with a local name, or you want a shorter alias:

```hawk
import std.testing as testing;
import std.fs as fs;

testing.assert_eq(actual: result, expected: 5)?;
```

`std.core` is the **prelude**: automatically imported into every file, with its
names available **unqualified** (`Result`/`Option`/`Error`, `Eq`/`Display`/
`Debug`, `println`/…). `Result`/`Option` are ordinary prelude enums, so their
variants are constructed qualified (`Result.Ok`, `Option.None`). It is the one
unqualified import; every other library is referenced through its namespace.
`std.cli` (the `Args` argument parser, and the home of process execution) is an
ordinary library — `import std.cli` when you need it.

### Import resolution

There are two forms of import: **stdlib** (`std.*`) and **relative file** (a
quoted path).

**Stdlib imports** resolve against the SDK's standard library directory. Its
exact location differs between the in-repo and distributed layouts (see
[SDK layout](#sdk-layout)):

```
in-repo:      <repo>/sdk/std/<lib>
distributed:  <install>/std/<lib>
```

Each library is then resolved as a file or a directory barrel (below): `std.fs`
resolves to `std/fs/fs.hawk`, `std.cli` to `std/cli/cli.hawk`.

**Relative file imports** resolve against the directory of the importing file:

```hawk
import 'wordcount'        // → <same dir>/wordcount.hawk
import 'util/strings'     // → <same dir>/util/strings.hawk
```

The `.hawk` extension is always implied and must not be written in the import
path. Absolute paths and `..` traversals are not supported.

**A path may resolve to a file or to a directory.** For a path `P` (after
anchoring as above): if `P.hawk` exists it is the library; otherwise, if `P/` is
a directory, the library is its **barrel** file `P/<last>.hawk` (named after the
directory). Having both `P.hawk` and a `P/` directory is an error.

```hawk
import 'wordcount'  // → wordcount.hawk        (single-file library)
import std.cli      // → std/cli/cli.hawk      (directory library, via its barrel)
```

A barrel re-exports its directory's files with `pub import`, so a whole
directory imports as one namespace. See [visibility.md](visibility.md).

---

## Visibility

A top-level declaration (`fn`, `type`, `enum`, `const`, `interface`) is
**private to its source file** unless marked `pub`. The physical `.hawk` file is
the privacy boundary; within a file everything is mutually visible, and across
files only `pub` symbols are — once imported.

```hawk
pub fn format_date(_ d: Date) -> String { ... }   // public API
fn pad2(_ n: Int) -> String { ... }                // file-private
```

A `pub` type exposes its fields; `impl` methods are exposed individually
(`pub fn`). A file can `pub import` another file to re-export its public symbols
— the basis of barrels. Sibling `_test.hawk` files get white-box access to their
target's private symbols. The full model — barrels, the `<dirname>.hawk`
convention, the test rule, and terminology (a source file vs. a library) — is in
[visibility.md](visibility.md).

---

## Native bindings (FFI)

`native fn` declares a function implemented in native code (e.g. a C library
linked into the runtime). The declaration provides the Hawk-visible signature;
the implementation is resolved at link time. Native functions have no body.

The `@extern('<symbol>')` decorator names the runtime native the function binds
to (the runtime's native table is a flat namespace, so stdlib symbols are
module-prefixed to stay unique). Without it, the binding defaults to the
function's own name.

```hawk
@extern('fs_read_text')
pub native fn read_text(_ path: String) -> Result<String, Error>
```

Native functions are an implementation detail of stdlib libraries. User code
calls the Hawk wrappers (e.g. `fs.read_text`), not the native bindings directly.

An opaque type wraps a native handle whose internal layout is managed by the
runtime. Declare it as an empty struct:

```hawk
type NativeHandle = {}   // opaque; not constructed directly in Hawk
```

---

## Process execution

`process.run` executes a subprocess and returns `Result<Output, Error>`.
`Output` has `stdout`, `stderr` (strings), and `exit_code` (Int).

```hawk
import std.process;

let out = process.run('git', args: ['status', '--short'])?;
println(out.stdout);
```

A non-zero exit code is returned as an `Error` by default.

---

## Command-line arguments

The runtime passes `main` its arguments as a `List<String>`. `std.cli` provides
`Args`, which wraps that list and supports positional arguments and named flags.
Construct it explicitly:

```hawk
import std.cli;

fn main(parameters: List<String>) -> Result<Int, Error> {
    let args = cli.Args.new(parameters);

    let path    = args.positional(0).ok_or(Error('usage: tool <path>'))?;
    let verbose = args.flag('--verbose', default: false);
    let output  = args.option('--output').unwrap_or('out.txt');
    // ...
    return Result.Ok(0);
}
```

`flag` tests for a boolean switch — `--verbose` (and, planned, its
`--no-verbose` negation) — and returns `Bool`. `option` reads a valued option —
`--output=path` (or `--output path`) — and returns `Option<String>`; pair it
with `unwrap_or` for a default.

---

## Interfaces

Interfaces describe capability. Structs implement them explicitly. No
inheritance — composition is preferred.

```hawk
interface Greet {
    fn greet(self) -> String;
}

impl Greet for User {
    fn greet(self) -> String {
        return 'Hello, ${self.name}!';
    }
}
```

### Inherent methods

Methods that belong to a type but do not implement an interface are defined in a
plain `impl TypeName` block:

```hawk
type Counter = {
    value: Int,
}

impl Counter {
    fn increment(self) -> Counter {
        return Counter { value: self.value + 1 };
    }

    fn reset(self) -> Counter {
        return Counter { value: 0 };
    }
}

let c = Counter { value: 0 }.increment().increment();
println('${c.value}');   // 2
```

A type may have any number of `impl` blocks — one for inherent methods and one
per interface implemented.

### Static methods

Functions in an `impl` block that take no `self` parameter are static methods,
called on the type name rather than an instance:

```hawk
impl Regex {
    fn compile(_ pattern: String) -> Result<Regex, Error> { ... }  // static
    fn is_match(self, _ text: String) -> Bool { ... }              // instance
}

let re = Regex.compile('[0-9]+')?;   // static call
re.is_match('abc123');               // instance call
```

### Display and Debug

Two standard interfaces handle string conversion. Both are defined in `std.core`
and available everywhere without an explicit import.

- **`Display`** — user-facing representation. Used by string interpolation
  (`${value}`) and `println`. Opt-in; implement when the type has a meaningful
  human-readable form.
- **`Debug`** — developer-facing representation. Used by assertion failure
  messages, logging, and diagnostic output. Shows internal structure (field
  names and values). Auto-derived for structs; can be overridden.

Primitive types (`Int`, `Double`, `Bool`, `String`) implement both
automatically. Structs get a default `Debug` implementation that prints all
fields; `Display` must be implemented explicitly.

```hawk
// auto-derived Debug for a struct prints all fields:
//   Point { x: 1.0, y: 2.0 }

type Point = {
    x: Double,
    y: Double,
}

// explicit Display for a user-facing format
impl Display for Point {
    fn display(self) -> String {
        return '(${self.x}, ${self.y})';
    }
}
```

String interpolation (`${}`) requires `Display`. Attempting to interpolate a
type that does not implement `Display` is a compile error.

---

## Decorators / annotations

Decorators attach metadata to a function. They are evaluated at compile time.

```hawk
@route('GET', '/healthz')
fn healthz(req: Request) -> Result<Response, Error> {
    return Result.Ok(Response.text('ok'));
}
```

---

## Testing

Test files are co-located with the source file they test, using a `_test`
suffix: `src/foo.hawk` is tested by `src/foo_test.hawk`. The test imports its
sibling through the normal import process, and — because the names match — that
import additionally gets **white-box** access to the target's _private_ symbols
(not just its `pub` ones). See
[visibility.md](visibility.md#testing-white-box-access).

Test functions are marked with `@test`, take no arguments, and return
`Result<Void, Error>`. A test passes when it returns `Result.Ok(void)` and fails
when it returns `Err`. Assertions return `Result<Void, Error>` and are called
with `?` so that the first failure propagates out of the test immediately.

```hawk
// src/math_test.hawk

import std.testing;

import 'math';

@test
fn test_add() -> Result<Void, Error> {
    testing.assert_eq(actual: math.add(2, 3), expected: 5)?;
    testing.assert_eq(actual: math.add(-1, 1), expected: 0)?;
    return Result.Ok(void);
}

@test
fn test_parse_config() -> Result<Void, Error> {
    let cfg = math.parse_config('testdata/config.toml')?;
    testing.assert_eq(actual: cfg.host, expected: 'localhost')?;
    return Result.Ok(void);
}
```

### Assertions

Assertions live in `std.testing` and are plain functions — not built-in
statements. They cannot be silently disabled by a compiler flag or build mode.
Each returns `Result<Void, Error>`; call with `?` to propagate failures.

| Function                                      | Behaviour                     |
| --------------------------------------------- | ----------------------------- |
| `testing.assert(condition)`                   | Fails if condition is false   |
| `testing.assert(condition, message: 'msg')`   | Fails with a custom message   |
| `testing.assert_eq(actual: a, expected: b)`   | Fails if values are not equal |
| `testing.assert_ne(actual: a, unexpected: b)` | Fails if values are equal     |
| `testing.assert_ok(result)` → inner value     | Fails if result is Err        |
| `testing.assert_err(result)`                  | Fails if result is Ok         |

---

## The `hawk` tool

The `hawk` command-line tool is the primary interface for working with Hawk
programs. Its **primary design goal is to be useful to LLMs**; its secondary
goal is to be useful to humans.

That principle shapes output defaults: commands are silent on success and emit
only on failure. This keeps LLM context clean — no output means no problem.
Verbose mode is available when a human wants more detail.

### Commands

| Command      | Description                    |
| ------------ | ------------------------------ |
| `hawk run`   | Run a source file              |
| `hawk test`  | Run tests                      |
| `hawk check` | Type-check without running     |
| `hawk fmt`   | Format source files in place   |
| `hawk build` | Compile to a standalone binary |

### `hawk test`

Discovers and runs all `*_test.hawk` files reachable from the current directory
(or a given path).

**Default mode (LLM-optimised):** silent on success; prints only failures. Exit
code is 0 if all tests pass, non-zero otherwise. An LLM can run `hawk test` and
treat any output as a signal requiring attention.

**Verbose mode (`--verbose`):** prints a summary line (tests run, passed,
failed) and one line per test executed.

```
$ hawk test                          # silent — all passed
$ hawk test                          # one failure
FAIL src/math_test.hawk::test_add
  assert_eq failed: got 4, expected 5
  at src/math_test.hawk:6

$ hawk test --verbose
src/math_test.hawk::test_add         ok
src/math_test.hawk::test_add_neg     ok
src/util_test.hawk::test_trim        ok
3 passed, 0 failed
```

Additional flags:

- `hawk test <path>` — run tests under a specific file or directory
- `hawk test --filter <pattern>` — run only tests whose name matches

---

## SDK layout

The SDK exists in two forms: the **in-repo** development layout and the
**distributed** layout produced by the build. They differ mainly in where the
standard library lives; only a little infrastructure (the test harness, SDK-root
discovery) needs to know about the difference.

### In-repo layout

```
<repo>/
  bin/             ← dev-mode entry point scripts
  runtime/         ← Rust runtime: bytecode interpreter, GC, Cranelift JIT
                     (builds `hawkrt`, the bare runtime)
  pkgs/
    cli/           ← Hawk front-end + CLI harness (written in Hawk)
  sdk/
    std/
      core/core.hawk        ← auto-imported prelude (barrel; re-exports below)
        core/interfaces.hawk    Eq, Display, Debug
        core/error.hawk         Error
        core/string.hawk        String.* static/native helpers
        core/list.hawk          List.* helpers
        core/map.hawk           Map.* helpers
      cli/cli.hawk          ← import std.cli (barrel re-exporting args.hawk)
        cli/args.hawk
      fs/fs.hawk            ← import std.fs
      testing/testing.hawk  ← import std.testing
      ...                   ← (process, regex, … as they land)
  examples/
  docs/
```

### Two binaries: `hawkrt` and `hawk`

The Rust crate builds **`hawkrt`** — the *bare runtime*: it loads and runs a
`.hawkbc` and nothing else. The SDK build takes that same binary, embeds the
compiled front-end (`frontend.hawkbc`) into it, and ships it as **`hawk`** — the
full launcher. So `hawk` is `hawkrt` + an embedded front-end: invoked on a
`.hawkbc` (or `--entry`) it behaves as the bare runtime; invoked on a subcommand
(`run`, `check`, `test`, `emit`, `lsp`) it boots its embedded front-end. The
distinction lets a `cargo build` (which yields `hawkrt`) be unambiguously the
runtime, while `hawk` is unambiguously the runtime + front-end.

### Distributed layout

The build bundles the compiled `hawk` binary with the standard library source.
The `std/` directory moves to the top level — there is no `sdk/` wrapper:

```
<install>/
  bin/
    hawk           ← bare runtime + embedded front-end
  std/             ← stdlib source files (still needed at runtime)
  version          ← SDK version stamp (e.g. 0.1.0+<gitsha>)
```

### SDK root discovery

The `hawk` binary locates the SDK root at runtime by resolving one directory
above its own executable location (`bin/../`), then falling back to a walk
upward from the current directory (the in-repo dev case). The stdlib directory
beneath that root is the one place the two layouts diverge — `std_root` accepts
either `<root>/std` (distributed) or `<root>/sdk/std` (in-repo):

| Mode        | Binary / entry point | SDK root     | stdlib dir        |
| ----------- | -------------------- | ------------ | ----------------- |
| In-repo     | `<repo>/bin/…`       | `<repo>/`    | `<repo>/sdk/std/` |
| Distributed | `<install>/bin/hawk` | `<install>/` | `<install>/std/`  |

Discovery is location-based (no environment variable): the binary finds its SDK
from where it lives, so an installed `hawk` works from any working directory.

### Standard library source files

Stdlib libraries ship as plain Hawk source with `native fn` declarations for
functions implemented in the runtime, each a directory library
(`std/<lib>/<lib>.hawk`, e.g. `std/fs/fs.hawk`). The front-end parses and
type-checks them the same way it does user code.

`std.core` is implicitly imported and does not appear in the resolved import
graph unless explicitly re-imported with `as`. Every other `std.*` library
(including `std.cli`) is imported explicitly.

---

## Open design questions

Decisions not yet settled. (Resolved ones — `${}` interpolation, `throw`,
implicit `Ok` on `return` — are documented above as the language's behavior.)

- **Strings & Unicode.** Strings are stored UTF-8. The plan: make `char` a
  32-bit Unicode scalar, and forbid integer indexing on strings — force explicit
  iteration via `.chars()` (code points) or `.graphemes()` (user-perceived
  characters) so code never slices an emoji in half. `Char` as a distinct type
  is still open (see Types → Open questions above).
- ~~**Visibility / access control**~~ — _decided._ The source file is the
  privacy boundary; `pub` exposes a symbol; directories aggregate through a
  `<dirname>.hawk` barrel; sibling `_test.hawk` files get white-box access. See
  [visibility.md](visibility.md).
- ~~**Library / import system**~~ — _decided (mechanism)._ Explicit imports;
  each binds a namespace (the trailing path segment) accessed qualified, with
  `std.core` the unqualified prelude. See [visibility.md](visibility.md). Still
  open: a **package manager** — Go-style URL imports or a central registry
  (npm/PyPI) — and whether third-party packages exist at all for the POC.
- **Generics** — parametric only, or constraints/bounds from day one?
- **Numeric tower** — single `Int`/`Double`, or sized types (`Int32`, `Int64`)?
- ~~**Interface dispatch**~~ — _decided._ The concrete type is known at every
  call site today, so the frontend resolves statically and emits a direct `call`
  (covers `Display`/`Eq`). A per-type vtable (`call.interface`) is added only
  when Hawk gains type-erased interface values; the JIT devirtualizes when it
  knows the type. See [bytecode.md](bytecode.md).
- **Decorator semantics** — compile-time metadata only, or runtime hooks?
- **Process spawning ergonomics** — method call (`run('git', [...])`) or a
  shell-string shorthand (`$('git status')`)? The former is safer; the latter is
  more familiar to shell scripters.
- **Streams** — how to pipe one process's stdout into another: lazy iterators?
  an explicit pipe operator?
- **Script mode** — should `main` be optional for simple one-file scripts, the
  way Python and Node allow top-level statements?
- **Inline error handling (`catch`)** — Hawk uses `?` to propagate. A Zig-style
  `expr catch fallback` / `expr catch |e| { ... }` as an inline default handler
  is worth considering as an additional form.
- **`Option` vs. a nullable type system** — `Option<T>` (composes with
  `.map`/`.flat_map`, represents nested absence) vs. `String?` with `?.`/`??`
  (zero boilerplate, no wrapper, but can't nest). `language.md` uses `Option<T>`
  as a placeholder; revisit once there's enough real Hawk code to judge
  friction.
- **Concurrency beyond single-threaded fibers** — the model is single-threaded
  cooperative fibers (no synchronization needed, no CPU parallelism). If
  parallelism becomes a requirement: _immutable-only sharing_ across threads
  (hard to enforce without deeper type support) or _thread-isolated heaps_
  (private heap per scheduler, communicate by copying). Deferred.
