# Aero Language Reference

Notes:

- this is an informal working reference — not a formal spec
- the language codename is 'Aero' (with a close alternative being 'Hawk')

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

```aero
fn main(args: Args) -> Result<Int, Error> {
    // ...
    return Ok(0);
}
```

---

## Variables

Bindings are immutable by default. Use `mut` to allow reassignment.

```aero
let x = 42;
let name = 'alice';

mut count = 0;
count = count + 1;
```

---

## Types

### Primitives

| Type     | Description                     | Example         |
| -------- | ------------------------------- | --------------- |
| `Int`    | 64-bit signed integer           | `42`, `-7`      |
| `Double` | 64-bit floating-point           | `3.14`          |
| `Bool`   | Boolean                         | `true`, `false` |
| `String` | UTF-8 text                      | `'hello'`       |
| `()`     | Unit type (absence of a value)  |                 |

String literals use single quotes. Interpolation uses `${}`:

```aero
let greeting = 'Hello, ${name}!';
```

### Collections

| Type        | Description                           | Example                             |
| ----------- | ------------------------------------- | ----------------------------------- |
| `List<T>`   | Ordered sequence                      | `[1, 2, 3]`                         |
| `Map<K, V>` | Key-value store                       | `{'a': 1, 'b': 2}`                  |
| `Set<T>`    | Unordered collection of unique values | `Set.from([1, 2, 3])`               |

```aero
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

```aero
type Point = {
    x: Float,
    y: Float,
}

let p = Point { x: 1.0, y: 2.0 };
println('${p.x}, ${p.y}');
```

---

## Functions

```aero
fn add(a: Int, b: Int) -> Int {
    return a + b;
}
```

Functions are first-class values. Lambdas use `=>`:

```aero
let double = x => x * 2;
let names = users.map(u => u.name);
```

---

## Concurrency

Aero targets a **fiber-based (colorless) concurrency model**. All I/O calls look
synchronous — there are no `async`/`await` keywords and no `Future<T>` return
types. When a fiber blocks on I/O, the runtime parks it and switches to another;
the calling code never observes the difference.

```aero
// These two functions look identical at the type level.
// fetch_user may block on a network call; double does not.
// The caller treats them the same way.

fn double(x: Int) -> Int {
    return x * 2;
}

fn fetch_user(id: Int) -> Result<User, Error> {
    let resp = http.get('/users/${id}')?;   // may park the fiber
    return json.decode<User>(resp.body);
}

fn main(args: Args) -> Result<Int, Error> {
    let user = fetch_user(1)?;              // no await needed
    println(user.name);
    return Ok(0);
}
```

Spawning a fiber runs work concurrently. Fibers are lightweight and cheap:

```aero
import std.fiber;

let handle = fiber.spawn(() => fetch_user(42));
// ... do other work ...
let user = handle.join()?;
```

**Fallback:** if the fiber runtime proves too costly to implement in the POC,
the language will fall back to explicit `async`/`await`. In that model,
functions that perform I/O are marked `async` and callers use `await` — the
traditional colored-function approach. The goal is to avoid this.

---

## Error handling

There are no exceptions. Errors are returned as `Result<T, E>`.

```aero
fn read_port(args: Args) -> Result<Int, Error> {
    let s = args.positional(0).ok_or('usage: serve <port>')?;
    return s.parse<Int>();
}
```

`?` propagates an `Error` to the caller. `match` handles results at a boundary:

```aero
match read_port(args) {
    Ok(port) => println('listening on ${port}'),
    Error(e)   => println('error: ${e.message}'),
}
```

---

## Option

There is no `null`. Absent values are represented explicitly as `Option<T>`,
which is either `Some(value)` or `None`. A value of type `String` is always a
string; a value that might be absent has type `Option<String>`.

```aero
type Config = {
    host:    String,
    port:    Int,
    log_dir: Option<String>,   // may be absent
}
```

Use `match` to unwrap, or `.ok_or()` to convert to a `Result` when absence
should be treated as an error:

```aero
match config.log_dir {
    Some(dir) => println('logging to ${dir}'),
    None      => println('logging disabled'),
}

// treat absence as an error and propagate with ?
let dir = config.log_dir.ok_or('log_dir is required')?;
```

---

## Control flow

```aero
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

```aero
let nums: List<Int> = [1, 2, 3];
let first = nums[0];
let len   = nums.len();
```

Common pipeline methods (lazy; call `.to_list()` to materialise):

```aero
let evens = nums.filter(n => n % 2 == 0).to_list();
let doubled = nums.map(n => n * 2).to_list();
```

---

## Imports

Standard library modules are imported by path. Imported names are used as
qualified identifiers.

```aero
import std.fs;
import std.process;

let text = fs.read_text('config.toml')?;
```

---

## Process execution

`process.run` executes a subprocess and returns `Result<Output, Error>`.
`Output` has `stdout`, `stderr` (strings), and `exit_code` (Int).

```aero
import std.process;

let out = process.run('git', ['status', '--short'])?;
println(out.stdout);
```

A non-zero exit code is returned as an `Error` by default.

---

## Command-line arguments

`Args` is passed to `main`. Positional arguments and named flags are both
supported.

```aero
let path    = args.positional(0).ok_or('usage: tool <path>')?;
let verbose = args.flag('verbose', default: false);
let output  = args.flag('output',  default: 'out.txt');
```

---

## Interfaces

Interfaces describe capability. Structs implement them explicitly.

```aero
interface Display {
    fn display(self) -> String;
}

impl Display for Point {
    fn display(self) -> String {
        return '(${self.x}, ${self.y})';
    }
}
```

No inheritance. Composition is preferred.

---

## Decorators / annotations

Decorators attach metadata to a function. They are evaluated at compile time.

```aero
@route('GET', '/healthz')
fn healthz(req: Request) -> Result<Response, Error> {
    return Ok(Response.text('ok'));
}
```
