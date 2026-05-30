# Hawk Language Reference

Notes:

- this is an informal working reference — not a formal spec
- the language codename is 'Hawk' (with a close alternative being 'Hawk')

---

## Style

- **Indent:** 4 spaces (no tabs).
- **Line length:** 100 characters. Soft limit — the formatter wraps where it
  improves readability but does not enforce a hard break at 100.

---

## Entry point

Every program defines a `main` function. `Args` is provided by the runtime. The
returned `Int` is used as the process exit code. An `Error` result exits with a
non-zero code and prints the error message to stderr.

```hawk
fn main(args: Args) -> Result<Int, Error> {
    // ...
    return Ok(0);
}
```

---

## Variables

Bindings are immutable by default. Use `mut` to allow reassignment.

```hawk
let x = 42;
let name = 'alice';

mut count = 0;
count = count + 1;
```

---

## Types

### Primitives

| Type          | Description                                                    | Example         |
| ------------- | -------------------------------------------------------------- | --------------- |
| `Int`         | 64-bit signed integer                                          | `42`, `-7`      |
| `Double`      | 64-bit floating-point                                          | `3.14`          |
| `Bool`        | Boolean                                                        | `true`, `false` |
| `String`      | UTF-8 text                                                     | `'hello'`       |
| `Void` / `()` | Unit type; the two names are interchangeable, following Swift. |                 |

String literals use single quotes. Interpolation uses `${}`:

```hawk
let greeting = 'Hello, ${name}!';
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
let double = x => x * 2;
let names = users.map(u => u.name);
```

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
fn flag<T>(_ name: String, default value: T) -> T { ... }

args.flag('verbose', default: false);
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

fn main(args: Args) -> Result<Int, Error> {
    let user = fetch_user(id: 1)?;          // no await needed
    println(user.name);
    return Ok(0);
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

There are no exceptions. Errors are returned as `Result<T, E>`.

```hawk
fn read_port(args: Args) -> Result<Int, Error> {
    let s = args.positional(0).ok_or('usage: serve <port>')?;
    return s.parse<Int>();
}
```

`?` propagates an `Error` to the caller. `match` handles results at a boundary:

```hawk
match read_port(args) {
    Ok(port) => println('listening on ${port}'),
    Error(e)   => println('error: ${e.message}'),
}
```

### `throw`

`throw expr` is sugar for `return Err(expr)` in a `Result`-returning function.
It is a reserved keyword — not an exception mechanism. There is no stack
unwinding; control simply returns to the caller with an `Err` value.

```hawk
fn parse_port(s: String) -> Result<Int, Error> {
    let n = s.parse<Int>()?;
    if n < 1 || n > 65535 {
        throw 'port out of range: ${n}';
    }
    return n;   // implicitly Ok(n)
}
```

---

## Option

There is no `null`. Absent values are represented explicitly as `Option<T>`,
which is either `Some(value)` or `None`. A value of type `String` is always a
string; a value that might be absent has type `Option<String>`.

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
let dir = config.log_dir.ok_or('log_dir is required')?;
```

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

Common pipeline methods (lazy; call `.to_list()` to materialise):

```hawk
let evens = nums.filter(n => n % 2 == 0).to_list();
let doubled = nums.map(n => n * 2).to_list();
```

---

## Imports

Standard library modules are imported by path. The last path segment becomes the
local prefix used to reference the module's members:

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

`std.core` and `std.args` are automatically imported into every file and do not
need to appear in an explicit import statement. `std.core` provides the
fundamental interfaces (`Eq`, `Display`, `Debug`); `std.args` provides `Args`.

### Import resolution

There are two forms of import: **stdlib** (`std.*`) and **relative file** (a
quoted path).

**Stdlib imports** resolve against the SDK's standard library directory:

```
<sdk_root>/sdk/std/<module>.hawk
```

For example, `import std.fs` resolves to `<sdk_root>/sdk/std/fs.hawk`.

**Relative file imports** resolve against the directory of the importing file:

```hawk
import 'wordcount'        // → <same dir>/wordcount.hawk
import 'util/strings'     // → <same dir>/util/strings.hawk
```

The `.hawk` extension is always implied and must not be written in the import
path. Absolute paths and `..` traversals are not supported.

---

## Native bindings (FFI)

`native fn` declares a function implemented in native code (e.g. a C library
linked into the runtime). The declaration provides the Hawk-visible signature;
the implementation is resolved at link time. Native functions have no body.

```hawk
native fn re2_compile(_ pattern: String) -> Result<NativeHandle, String>
native fn re2_is_match(_ handle: NativeHandle, _ text: String) -> Bool
```

Native functions are an implementation detail of stdlib modules. User code calls
the Hawk wrappers, not the native bindings directly.

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

`Args` is passed to `main` by the runtime. It is defined in `std.args`, which is
auto-imported. Positional arguments and named flags are both supported.

```hawk
let path    = args.positional(0).ok_or('usage: tool <path>')?;
let verbose = args.flag('verbose', default: false);
let output  = args.flag('output',  default: 'out.txt');
```

`flag` is generic: the return type is inferred from the `default` value. A
`Bool` default returns `Bool`; a `String` default returns `String`.

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
    return Ok(Response.text('ok'));
}
```

---

## Testing

Test files are co-located with the source file they test, using a `_test`
suffix: `src/foo.hawk` is tested by `src/foo_test.hawk`. The test file imports
its sibling module and has access to its exported symbols.

Test functions are marked with `@test`, take no arguments, and return
`Result<Void, Error>`. A test passes when it returns `Ok(())` and fails when it
returns `Err`. Assertions return `Result<Void, Error>` and are called with `?`
so that the first failure propagates out of the test immediately.

```hawk
// src/math_test.hawk

import std.testing;

import './math';

@test
fn test_add() -> Result<Void, Error> {
    testing.assert_eq(actual: add(2, 3), expected: 5)?;
    testing.assert_eq(actual: add(-1, 1), expected: 0)?;
    return Ok(());
}

@test
fn test_parse_config() -> Result<Void, Error> {
    let cfg = parse_config('testdata/config.toml')?;
    testing.assert_eq(actual: cfg.host, expected: 'localhost')?;
    return Ok(());
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

```
<sdk_root>/
  bin/
    hawk.sh          ← dev-mode entry point (delegates to tool/)
    hawk             ← compiled binary (distributed SDK only)
  sdk/
    std/
      core.hawk      ← auto-imported: Eq, Display, Debug
      args.hawk      ← auto-imported: Args
      fs.hawk        ← import std.fs
      process.hawk   ← import std.process
      testing.hawk   ← import std.testing
      fiber.hawk     ← import std.fiber
      regex.hawk     ← import std.regex
      ...
  tool/              ← Dart toolchain source (dev mode only)
    bin/
      hawk.dart      ← CLI entry point
    lib/sdk/
      lexer.dart
      parser.dart
      ast.dart
      checker/
      interpreter/
      lsp/
    test/
  examples/
  docs/
```

### SDK root discovery

The `hawk` binary locates the SDK root at runtime by resolving one directory
above its own location (`bin/../`). This works identically in both modes:

| Mode            | Binary location      | SDK root     |
| --------------- | -------------------- | ------------ |
| Dev (from repo) | `<repo>/bin/hawk.sh` | `<repo>/`    |
| Distributed     | `<install>/bin/hawk` | `<install>/` |

`bin/hawk.sh` is the dev-mode entry point. It sets `SDK_ROOT` to the parent of
the `bin/` directory and delegates to `dart run tool/bin/hawk.dart`. A compiled
binary (`dart compile exe`) embeds the same root-discovery logic.

The `HAWK_SDK` environment variable overrides automatic discovery for cases such
as running tests against an alternate SDK or wrapping the binary in a script.

### Standard library source files

Each `import std.<module>` statement resolves to:

```
<sdk_root>/sdk/std/<module>.hawk
```

Stdlib source files are plain Hawk source with `native fn` declarations for
functions implemented in the runtime. The toolchain parses and type-checks them
the same way it does user code.

`std.core` and `std.args` are implicitly imported and do not appear in the
resolved import graph unless explicitly re-imported with `as`.

### Distributed SDK layout

When `hawk` is compiled to a native binary
(`dart compile exe tool/bin/hawk.dart -o bin/hawk`), the `tool/` directory is no
longer needed at runtime. The distributed layout is therefore:

```
<install>/
  bin/
    hawk           ← single compiled binary
  std/             ← stdlib source files (still needed at runtime)
```
