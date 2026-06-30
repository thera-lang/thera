# Hawk language reference

**What this is:** the reference for Hawk's syntax and semantics, the standard
`hawk` tool, and open language-design questions. An informal working reference,
not a formal spec. The concrete syntax — keyword set, operator precedence, and
every production in EBNF — is in [grammar.md](grammar.md). For the _why_ see
[overview.md](overview.md); for how programs execute see
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

> **Enforcement status.** Immutability is enforced uniformly: reassigning a
> non-`mut` `let` or parameter, or assigning a non-`mut` struct field, is a
> compile error. A field opts into reassignment with `mut field: T` (see
> [Structs](#structs)).

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

A `Double` always renders with a decimal point, so its output is visually
distinct from an `Int`: `1.0` displays as `1.0` (not `1`), `-2.0` as `-2.0`, and
a non-integral value as itself (`3.14`). This differs from languages whose
default float formatting drops a trailing `.0`.

String literals use single quotes, and may span multiple lines. Interpolation
uses `${}`, and `+` concatenates two strings:

```hawk
let greeting = 'Hello, ${name}!';
let path = dir + '/' + name + '.hawk';
```

Strings are UTF-8 and are **not** integer-indexable — `s[i]` is disallowed,
since it would let code split a multi-byte character in half. Iterate explicitly
instead: `.chars()` yields Unicode code points, `.graphemes()` user-perceived
characters.

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

### Bytes

`Bytes` is the core type for raw binary data (binary I/O, HTTP bodies, the
`.hawkbc` format). It is an **immutable** byte sequence — `len`, `get` (→
`Option<Int>`), `slice`, `concat`, `to_string` (→ `Result`, UTF-8 validated),
`to_list`, plus `Bytes.empty()` / `Bytes.from_list(...)`. Build one up with the
mutable `BytesBuilder` (`write_u8` / `write_bytes` / `write_str`, the
little-endian `write_u32_le` / `write_u64_le` / `write_f64_le`, varints, then
`finish()` → `Bytes`). Both live in `std.core`, so they're available
unqualified.

### Open questions

- **`Char`** — single character type (like Rust's `char` or Go's `rune`)? Most
  CLI use cases are satisfied by `String`; leaving this out keeps the type
  surface smaller. Deferred.
- **`Tuple`** — anonymous fixed-size heterogeneous record, e.g. `(Int, String)`.
  Useful for multi-return but adds syntax complexity. Deferred.
- **Integer sizes** — a single `Int` (64-bit) covers most CLI needs. Explicit
  sized types (`Int32`, `Int64`) may be needed later for binary formats or FFI.

---

## Structs

Structs are nominal types, declared with the `struct` keyword and a brace body
(no `=`) — like `enum` and `interface`, and like Rust/Swift/Go, a deliberately
*nominal* signal (two identically-shaped structs are distinct types). Fields are
immutable by default; mark a field `mut` to allow reassigning it after
construction (the field-level analogue of `let` vs `let mut`).

```hawk
struct Point {
    x: Double,
    y: Double,
}

let p = Point { x: 1.0, y: 2.0 };
println('${p.x}, ${p.y}');
p.x = 3.0;            // error: `x` is not `mut`

struct Cursor {
    mut offset: Int,   // reassignable
    source: String,    // immutable
}

let c = Cursor { offset: 0, source: 'abc' };
c.offset = c.offset + 1;   // ok
```

Mutability gates *which fields may be reassigned*, not sharing: a `mut` field on a
struct reached through two bindings is observed by both (heap values are shared
references — see [Variables](#variables)).

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

By design, **the function author chooses each parameter's call form, and the
call site has exactly one valid form** — there is no caller-side choice, so every
call to a given function looks the same. That consistency matters for readers
(human and LLM), while still letting the author put labels where they aid
readability and drop them where they are noise.

A parameter is **labeled by default**: its name becomes the call-site label and
callers must write it. Labels make calls self-documenting — especially for
booleans and several same-typed arguments:

```hawk
fn greet(name: String, times: Int) { ... }

greet(name: 'alice', times: 3);
```

Mark a parameter **positional** with a leading `_` (read it as "the external
label is _none_"). The label is then *forbidden* and the argument is passed by
position — for when the call already reads unambiguously without it:

```hawk
fn println(_ msg: String) { ... }

println('hello');          // positional — reads naturally
// println(msg: 'hello');  // error — this parameter has no label
```

**Style.** Default to labeled; reach for `_` only when the label would be
redundant — typically the single "subject" argument of a call (`log(msg)`,
`read_text(path)`, `insert(item, at: index)`). Keep labels for booleans, for
multiple same-typed arguments whose order is otherwise unclear, and for any role
the name and value don't already make obvious.

Use `external internal` to give a parameter a different external label from its
internal identifier — useful when the natural label is a keyword or reads
awkwardly inside the body (`_` is just the case where the external label is
none):

```hawk
fn flag(_ name: String, default value: Bool) -> Bool { ... }

args.flag('--verbose', default: false);
```

Here `default` is the label at the call site; `value` is the name used inside
the function body (avoiding a clash with a potential `default` keyword).

> **Enforcement status.** The single-call-form model above is the design intent;
> the checker is currently **more permissive** than it. Today a labeled parameter
> may *also* be passed positionally, and labeled arguments may be reordered — so
> more than one call form compiles for the same function. Tightening to one
> canonical form (a labeled parameter's label is required; positional is
> forbidden for it), migrating the call sites that rely on the looseness, and the
> style guidance above are tracked in [roadmap.md](roadmap.md).

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

The runtime design for this — fibers as stackless coroutines over the
interpreter's explicit frame stack, the scheduler, parking, and I/O — is sketched
in [architecture.md](architecture.md) §Concurrency. A **first cut is implemented**:
`std.fiber` provides `spawn`/`join`/`yield` and buffered channels over the
cooperative scheduler. Still pending: parking on real blocking I/O (so an I/O call
transparently yields the fiber) and a readiness poller for sockets — see
[roadmap.md](roadmap.md).

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
    let s = args.positional(0).ok_or(error('usage: serve <port>'))?;
    return s.parse<Int>();
}
```

`Result<T, E>` is an ordinary enum defined in the prelude (`std.core`), with
variants `Ok(T)` and `Err(E)`. It is constructed like any enum — qualified:
`Result.Ok(value)`, `Result.Err(e)`. The `?` operator and the implicit-`Ok`
wrapping below know it by name, but it is otherwise not special.

`?` propagates a failure to the caller: `expr?` unwraps the success case
(`Ok(v)` → `v`) or returns the failure (`Err(e)`) from the enclosing function.
`match` handles results at a boundary (match patterns stay unqualified):

```hawk
match read_port(args) {
    Ok(port) => println('listening on ${port}'),
    Err(e)   => println('error: ${e.message}'),
}
```

**`?` works on `Option` too**, by the same rule — `Some(v)` → `v`, `None`
early-returns `None`:

```hawk
fn first_word(_ line: String) -> Option<String> {
    let word = line.split(' ').first()?;   // None short-circuits the function
    return Option.Some(word);
}
```

`?` propagates **within one enum family**: an `Option` `?` is valid only in an
`Option`-returning function, a `Result` `?` only in a `Result`-returning one.
Mixing them is a compile error, because converting one to the other needs a
choice the `?` can't make for you — turn an absence into an error explicitly with
`.ok_or(<error>)?`, or drop an error to an absence with `.ok()?`:

```hawk
fn load(args: Args) -> Result<Int, Error> {
    // args.first() is an Option; name the error, then propagate it
    let raw = args.first().ok_or(error('missing argument'))?;
    return raw.to_int().ok_or(error('not a number'));
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
        throw error('port out of range: ${n}');
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
struct Config {
    host:    String,
    port:    Int,
    log_dir: Option<String>,   // may be absent
}
```

Use [`if let`](#if-let) to act on a present value, `match` to handle both cases,
or `.ok_or()` to convert to a `Result` when absence should be treated as an
error:

```hawk
// act on the present case (the common one)
if let Some(dir) = config.log_dir {
    println('logging to ${dir}');
}

// handle both cases
match config.log_dir {
    Some(dir) => println('logging to ${dir}'),
    None      => println('logging disabled'),
}

// treat absence as an error and propagate with ?
let dir = config.log_dir.ok_or(error('log_dir is required'))?;
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

**The fault diagnostic.** A trap writes a single line to stderr of the form
`hawk: trap: <message>` and exits non-zero. The message is human-readable and
names the specifics:

| Fault                | Message                                                       |
| -------------------- | ------------------------------------------------------------- |
| list index out of range | `index out of range: the index is <i> but the length is <n>` |
| missing map key      | `key not found: <key>` (string keys are quoted, e.g. `'bob'`) |
| integer divide-by-zero | `division by zero`                                          |
| send on a closed channel | `send on a closed channel`                                |

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

### `if let`

`if let PATTERN = SUBJECT { … }` runs the block — binding the pattern's variables
in it — only when `SUBJECT` matches `PATTERN`. It is the **conditional-binding**
form: the canonical way to act on a present `Option` (or any single enum variant)
without a full `match`.

```hawk
// act on a present value (no `else` needed — runs for effect)
if let Some(dir) = config.log_dir {
    println('logging to ${dir}');
}

// with an else, and as a value (the value form requires `else`, like `if`)
let port = if let Some(p) = parsed { p } else { 8080 };

// else-if-let chains, and nested patterns bind at the leaves
if let Ok(n) = parse(a) {
    use(n);
} else if let Ok(m) = parse(b) {
    use(m);
}
```

It is exactly an `if` whose condition is a pattern binding: the same rules apply
(no `else` for a statement run for effect; an `else` required where the value is
used). Reach for `if let` over `match` when you care about **one** variant and
would otherwise write a `_ => {}` catch-all; reach for `match` when you are
genuinely choosing among several variants.

### `let … else`

`let PATTERN = SUBJECT else { … }` binds the pattern's variable for the **rest of
the block** when the subject matches, and runs the `else` block when it doesn't.
The `else` must **diverge** (end in `return` or `throw`) — that is what
guarantees the binding is available below. It is the **bind-or-bail guard**: the
way to pull a value out of an `Option`/`Result` and handle absence up front,
keeping the happy path un-indented.

```hawk
fn read_port(args: Args) -> Result<Int, Error> {
    let Some(arg) = args.positional(0) else {
        throw error('usage: serve <port>');
    };
    let Some(port) = arg.to_int() else {
        throw error('port must be a number');
    };
    return port;
}
```

A no-binding pattern is allowed as a pure assertion (`let Ok(_) = r else { … };`).
The binding target is a refutable (constructor) pattern — an uppercase
`Some`/`Ok`/… — which is how it is told apart from an ordinary `let x = …`.
Reach for `let … else` over `if let` when the match should bind for the rest of
the function and the failure case exits; reach for `if let` when you act only in
the present case and fall through otherwise.

> v1 limitations: the pattern binds **at most one** variable (use `match` for
> several), and the `else` block must end in a literal `return`/`throw`
> statement (one that diverges only through nested branches isn't yet
> recognized).

### Choosing a form

`Option` and `Result` can be handled several ways. Reach for the one that fits
the shape — there is **one obvious choice per situation**:

| situation                                  | use                                          |
| ------------------------------------------ | -------------------------------------------- |
| act on a present value (one variant)       | [`if let`](#if-let)                          |
| bind for the rest of the block, else exit  | [`let … else`](#let--else)                   |
| propagate the failure to the caller        | [`?`](#error-handling)                       |
| transform or default a value inline        | a combinator — `map` / `and_then` / `unwrap_or` / `ok_or` / … |
| genuinely choosing among ≥2 variants       | `match`                                      |

Use `match` when you are truly branching on multiple variants. If you find
yourself writing a `_ => {}` or `None => {}` catch-all only to satisfy
exhaustiveness, one of the other forms is the better fit — that catch-all is the
tell.

---

## Tail expressions

In **expression position**, the final expression of a block — one with no
trailing `;` — is the block's value. Because `if` and `match` arms are blocks,
they yield values too, so they can be used where a value is expected (a `let`
initializer, a `match` arm, an `if`/`else` branch, a call argument).

```hawk
// the block's last expression is its value
let label = match tok {
    Number(n) => {
        let s = format(n);
        'num: ${s}'          // ← tail; no trailing ';'
    },
    _ => 'other',
};

// if usable in value position
let max = if a > b { a } else { b };
```

**Semicolon rule.** In an expression-position block, every statement ends in `;`
_except_ a final tail expression. `let x = { f(); g() }` makes `x` the value of
`g()`; `let x = { f(); g(); }` makes `x` `Unit` (the value of `g()` is
discarded). A bare trailing expression is legal **only** in expression position.

**Function bodies are not expression position** — a function still returns with
an explicit `return`, and a bare trailing expression in a function body is a
statement (the require-`;` rule), not an implicit return. This is deliberate:
the value a function produces is always marked, and the `;`-flip can never
silently change a _return_ value.

**`if` without `else`** has type `Unit` (the then-branch runs for effect). An
`else` is required only where the `if`'s value is actually consumed —
`let x = if c { 1 }` is an error, but a side-effecting `if c { foo() }` as a
tail or statement is fine.

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

let score = scores.get('bob').ok_or(error('no score for bob'))?;
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

`as _` binds **no** prefix and instead brings the library's public names into the
file **unqualified** — the opt-in escape hatch for a library used pervasively,
where qualifying every reference would be noise. The default stays qualified; see
[scoping.md](scoping.md) for the full rules.

```hawk
import 'ast' as _;            // Expr, Stmt, Decl, … usable bare in this file
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
directory imports as one namespace. See [Visibility](#visibility).

---

## Visibility

The unit of privacy is the **physical `.hawk` source file**. Hawk has no
"module" (no multi-file unit with shared privacy); the relevant terms are a
**source file** (the privacy unit), a **library** (an importable surface — a
single file, or a directory fronted by its barrel), and a **barrel** (a library
root that re-exports its directory's files). In the common case the file _is_
the library.

A top-level declaration (`fn`, `type`, `enum`, `const`, `interface`) is
**private to its source file** unless marked `pub`. Within a file everything is
mutually visible; across files only `pub` symbols are, and only once imported.

```hawk
pub fn format_date(_ d: Date) -> String { ... }   // public API
fn pad2(_ n: Int) -> String { ... }                // file-private helper
```

- **Types expose their fields.** Making a `type`/`enum` `pub` also exposes its
  fields/variants — there is no per-field `pub`. (Mutability is the separate,
  immutable-by-default axis.)
- **Methods are exposed individually** — a method is callable cross-file only
  when it is `pub fn`.
- **`impl` blocks live wherever visibility allows** — an `impl Foo` or
  `impl Iface for Foo` may sit in any file that can see `Foo` (and the
  interface).
- **`pub import` re-exports** — it binds the namespace _and_ republishes the
  target's public symbols as part of this library's API (the basis of barrels;
  see [Imports](#imports)). A plain `import` does not re-export. If two
  re-exported files both export `format`, the **barrel** fails to compile — the
  conflict is the barrel author's, never the consumer's.

**Testing — white-box access.** A test lives beside its target as
`foo_test.hawk` and imports it normally (`import 'foo'`). The one special case
is visibility: because the names match, the test additionally sees `foo.hawk`'s
**private** top-level names as **bare** names — `internal_helper()` is callable
from `foo_test.hawk` and nowhere else (its public names are still reached through
the `foo` namespace, as in any other importer). The filename convention grants
the access, avoiding a general package-private axis.

Visibility and qualification are **front-end** concerns — name resolution
applies them and they are erased in `.hawkbc` (calls are by index; the bytecode
has no notion of "private" or namespaces). The precise resolution rules — bare vs.
qualified, the prelude, and the algorithm — are specified in
[scoping.md](scoping.md). Qualified-only access and `pub` privacy **are enforced**:
a bare cross-library reference, a qualified access to a non-public member, and a
bare reference to a value owned by an un-imported library are all `check` errors,
and namespaces are per-file. A residual tail — the same gate for bare *type*
references, plus per-library ownership of the symbol tables — is tracked in
[scoping.md](scoping.md) → Implementation gaps and [roadmap.md](roadmap.md).

---

## Documentation

Documentation is written for an audience of LLMs and coding agents first. The
guiding principle is **progressive disclosure**: a reader should be able to grasp
a file, then a symbol, by reading as little as possible — one summary sentence —
and descend into detail only when they need it.

### Three comment forms

Hawk distinguishes documentation from ordinary comments lexically, so tooling can
extract one without scraping the other:

| Form  | Role | Attaches to |
| ----- | ---- | ----------- |
| `///` | **item doc** | the declaration immediately below it |
| `//!` | **file doc** | the enclosing file (sits at the top, above the first declaration) |
| `//`  | ordinary comment | nothing — an internal aside, never extracted |

```hawk
//! std.fs — filesystem access: read and write files, list directories,
//! query metadata. All paths are POSIX (forward-slash) regardless of host.
//!
//! Import as: import std.fs;

/// The contents of the file at `path`, decoded as UTF-8.
///
/// **Errors:** returns `Err` if the file does not exist or is unreadable.
@extern('fs_read_text')
pub native fn read_text(_ path: String) -> Result<String, Error>

// internal: the native validates UTF-8 and maps errno → FsError  ← not a doc
```

A declaration's doc is the contiguous run of `///` lines directly above it; a
blank line or an ordinary `//` line ends the run. Because `//` is never
extracted, an internal note may sit directly above a declaration without becoming
its documentation — the disambiguation a position-only rule (Go's "the comment
above the symbol") cannot provide.

A directory library's **barrel** `//!` header is the **package doc** — the single
thing an agent reads to understand a whole library. A recommended `Import as:`
line gives the exact import to copy. (This is the only doc convention above the
symbol level; directory overviews and generated indexes are deferred.)

### The summary sentence

The **first sentence** of any doc (through the first `.`) is its summary. It must:

- **stand alone** — it appears by itself in one-line contexts (a symbol index,
  editor hover, a package's table of contents), with no further lines for support;
- **add information beyond the name** — if the name and signature already say
  everything, write no doc at all rather than restate them. A doc that only echoes
  the signature (`/// Returns the length.` on `len(self) -> Int`) is worse than
  none.

A blank `///` line separates the summary from any further paragraphs. Functions
lead with the result as a noun phrase ("The substring of code points in
`[start, end)`."), not "This function returns…".

> **When to document.** Every `pub` symbol should carry a doc comment *unless its
> name and signature are fully self-describing*. Private symbols are documented
> only where the intent is non-obvious. Brevity is a feature: the goal is the
> shortest doc that adds something a reader couldn't get from the signature.

### Markdown

Doc comments are Markdown, restricted to a small, predictable subset (anything
outside it is treated as plain text):

- **Inline:** `` `code` `` and `**bold**`.
- **Links & references:** `[text](path)` is an ordinary Markdown link, used to
  cross-reference other docs. `[Symbol]` (no trailing `(…)`) is a **resolvable
  symbol reference** — a shorthand naming a declared symbol the way code does
  (`[Display]`, `[String.slice]`, `[fs.read_text]`), resolved from the documented
  file's scope. The two are not interchangeable: `` `code` `` is **inert text**
  the tooling never checks, whereas `[Symbol]` is a **checked, navigable
  reference** — doc tooling links it, and a lint flags a `[Symbol]` that no longer
  resolves (doc-rot protection). Use `[Symbol]` when you want a reference to be
  navigable and verified; use backticks for any other code-shaped text. Backticks
  always work, so the bracket form is a pure opt-in upgrade, never required.
- **Lists:** `-` bullets and `1.` ordered lists.
- **Code blocks:** fenced only, tagged with the language —
  ```` ```hawk ````. Indented code blocks are **not** supported (they force an
  ambiguous indent-width rule under the `///` prefix); a fence is delimited, needs
  no measuring, and is the form LLMs read and emit most reliably. A fence may be
  left **untagged** when its content is preformatted text that is *not* Hawk code
  — a syntax table, a grammar fragment, or sample program output — so the `hawk`
  tag never falsely implies something is runnable.

There are **no ATX headers** (`#`, `##`) in doc comments — `#` would invite long,
sectioned docs that cut against the brevity goal, and a symbol's name is already
its title. When a longer doc genuinely needs sections, use a small fixed set of
**bold-label paragraphs** instead:

| Label | Use |
| ----- | --- |
| `**Example:**` | a usage example (usually a fenced `hawk` block) |
| `**Errors:**` | the conditions under which a `Result` returns `Err` |
| `**Traps:**` | the conditions under which the call traps (see [Runtime faults](#runtime-faults)) |
| `**Note:**` | a caveat or non-obvious consequence |
| `**See:**` | a cross-reference to a related symbol (`[Symbol]`) or doc |

```hawk
/// The element at `index`, or `None` if `index` is out of range.
///
/// **Example:**
/// ```hawk
/// let xs = [10, 20, 30];
/// xs.get(1);    // Some(20)
/// xs.get(9);    // None
/// ```
pub fn get(self, _ index: Int) -> Option<T> { ... }
```

### Parameters

Document parameters **in prose**, naming them in backticks (`` `index` ``) — there
is no `@param` tag vocabulary. Document a parameter only when its name and type do
not already convey its role: units, valid ranges, edge behavior, or how it relates
to another parameter. The return value is described in the summary, not in a
separate tag.

```hawk
/// The substring of code points in the half-open range `[start, end)`.
/// Indices are clamped to the string's length, so a reversed or out-of-range
/// range yields a shorter or empty string.
pub fn slice(self, _ start: Int, _ end: Int) -> String { ... }
```

> **Enforcement status.** The conventions above are adoptable in source today: the
> lexer skips every `//…` line, so `///` and `//!` already lex cleanly as
> comments. The supporting *machinery* — attaching docs to AST nodes, surfacing
> them in LSP hover, a doc generator, formatter and lint awareness, and migrating
> the existing `//` headers in `sdk/std/` — is tracked in
> [roadmap.md](roadmap.md).

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
struct NativeHandle {}   // opaque; not constructed directly in Hawk
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

    let path    = args.positional(0).ok_or(error('usage: tool <path>'))?;
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

Interfaces describe capability. A type implements one explicitly with
`impl Interface for Type`; the checker verifies the impl provides **every**
interface method with a matching signature (with `Self` read as the implementing
type), reporting any missing or mismatched.

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

### Default methods

An interface method may carry a body — a **default method**. An `impl` need not
provide it (the interface supplies the implementation), but may override it. A
default is written in terms of the interface's required methods, so one required
method can unlock a whole API:

```hawk
interface Animal {
    fn name(self) -> String;             // required

    fn greet(self) -> String {           // default, built on `name`
        return 'Hi, I am ${self.name()}';
    }
}

struct Dog { nick: String }

impl Animal for Dog {
    fn name(self) -> String { return self.nick; }
    // greet is inherited from the interface
}

struct Cat {}

impl Animal for Cat {
    fn name(self) -> String { return 'a cat'; }
    fn greet(self) -> String { return 'meow'; }   // overrides the default
}
```

Defaults dispatch dynamically, like any interface method: a call resolves to the
type's override if it has one, otherwise the interface's default. The default's
own calls to required methods (`self.name()` above) dispatch on the concrete
value at runtime. This works on both interface-typed receivers (`fn f(a: Animal)`
→ `a.greet()`) and concrete ones (`Dog { … }.greet()`).

The standard `Iterator<T>` uses this: its only required method is `next`, and the
adapters (`map`/`filter`/`take`/`enumerate`) and consumers (`collect`/`count`)
are all default methods — so every iterator is fluent without each implementer
re-spelling them. See [stdlib.md](stdlib.md).

### Inherent methods

Methods that belong to a type but do not implement an interface are defined in a
plain `impl TypeName` block:

```hawk
struct Counter {
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

struct Point {
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

`Eq` works the same way: `==`/`!=` use a type's explicit `impl Eq` when present,
otherwise the structural derive (primitives, and structs/enums whose fields are
all `Eq`). So `Eq` and `Debug` are **structural-by-default with explicit
override**; `Display` is always explicit (it has no meaningful default).

### Interface inheritance

An interface may **extend** one or more others, declaring that any conforming
type must also satisfy those super-interfaces. The `: Super1 + Super2` clause
uses the same `+`-joined form as a generic bound; supers must be interfaces and
the relation must be acyclic.

```hawk
pub interface Error: Display + Debug {
    fn message(self) -> String;
}
```

This reads "an `Error` is a `Display` and a `Debug` that additionally has
`message()`." `impl Error for FsError` is valid only when `FsError` also
satisfies `Display` and `Debug` (via their own impls — `Debug` for free from the
structural derive). A value typed as the `Error` _interface_ then also exposes
the super-interfaces' methods (`e.display()`, `'${e}'`) and is assignable where
a `Display`/`Debug` (or a `T: Debug` bound) is expected. There are no inherited
method _bodies_ — only the obligation and the widened method set.

### Dispatch

Calling an interface method on a value whose **concrete type is known at the
call site** is just a direct call — no vtable. Dynamic dispatch is used only
when the concrete type is not statically known: **interface-typed values**
(`fn show(x: Display)`, `List<Display>`) and **bounded generics**
(`fn dump<T: Display>(x: T)`, bounds enforced at call sites). The mechanism is
type-id-keyed — see [architecture.md](architecture.md).

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
(not just its `pub` ones). See [Visibility](#visibility).

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

The Rust crate builds **`hawkrt`** — the _bare runtime_: it loads and runs a
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

Decisions not yet settled. Resolved ones are documented above as the language's
behavior: `${}` interpolation, `throw`, implicit `Ok` on `return`, visibility &
libraries, interface dispatch, `Option` over nullable types, bounded generics,
and UTF-8 strings without integer indexing.

- **Package management** — is there a third-party package ecosystem for the POC
  at all, and if so, Go-style URL imports or a central registry (npm/PyPI)? The
  import _mechanism_ (namespaces, barrels) is settled; distribution is not.
- **Numeric tower** — single `Int`/`Double`, or sized types (`Int32`, `Int64`)?
  (Tracked alongside Types → Open questions.)
- **Decorator semantics** — compile-time metadata only, or runtime hooks?
- **Process spawning ergonomics** — method call (`run('git', [...])`) or a
  shell-string shorthand (`$('git status')`)? The former is safer; the latter is
  more familiar to shell scripters.
- **Streams** — how to pipe one process's stdout into another: lazy iterators?
  an explicit pipe operator?
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
