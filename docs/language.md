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
- **Line length:** 100 characters, as an authoring guideline. The formatter
  never reflows lines — it keeps every line break the author chose and
  normalizes only indentation and intra-line spacing (see
  [architecture.md](architecture.md) §The formatter).

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
> compile error. A field opts into reassignment with `let mut field: T;` (see
> [Structs](#structs)).

### Module-level bindings

A `let` at the top level of a file is a **module-level binding**: its
initializer runs **once**, when the program loads, and the value is stored (not
recomputed at each use). Unlike a local `let`, a module-level binding is
**immutable** — there is no top-level `let mut`. Swappable global state is
forbidden; mutable configuration is passed as a **capability value** you hold,
never a module global. Being part of the file's surface, a module-level binding
is a **boundary**: it carries a type annotation, read apart from its initializer
(see [Type annotations & inference](#type-annotations--inference)).

```hawk
let INFINITY: Double = 1.0 / 0.0;   // computed once at load, then stored
let TAU: Double = 2.0 * math.PI;    // may depend on another module global
```

`const` and module-level `let` are the two-tier story for named constants:

- **`const`** is a _manifest_ constant — its initializer must be compile-time
  evaluable, and it is **inlined** at each use site (no storage). A computed
  initializer (`const t = build()`) is a compile error that points at `let`.
- **module-level `let`** is _computed once at load_ and **stored** in a slot.

Initializers must be **pure**: literals, arithmetic, and calls to pure functions
and process-stable natives (a math constant, the path separator). Time-varying
effects (`time.now()`, file/network reads) are rejected in initializer position
— they would capture a stale, hidden snapshot at an unpredictable load-time
moment. Initializers run **eagerly** in dependency order (imports before
importers, a global before the one that uses it); an initializer-dependency
**cycle is a compile error**.

---

## Type annotations & inference

Hawk's annotation discipline is **hard at the boundaries, soft in the center**.
A declaration's _public shape_ — the types a reader sees without looking inside
— is always spelled out; the types of intermediate values _within_ a function
body are inferred. The aim is that a reader (human or LLM) never has to guess a
type that crosses a boundary, and never has to restate one an initializer
already makes obvious.

**Annotations are required at these four boundaries:**

- **Function parameters** — `fn add(a: Int, b: Int)`. The rule covers every
  function-like signature: free functions, instance and static methods, and
  interface methods (`self` is the one parameter whose type is implicit).
- **Function return types** — `-> Int`, written out (dropped only for `Void`;
  see [Functions](#functions)).
- **Struct fields** — `x: Double` (a struct literal supplies values, not types,
  so a field has nothing to infer its type from). **Enum variant payloads**
  (`Circle(Double)`) are the same kind of position and are likewise required —
  both are type positions the grammar won't let you leave blank.
- **Module-level bindings** — a top-level `let` or `const` is annotated
  (`const MAX_SCORE: Int = 100;`, `let LABELS: List<String> = [...]`). A global
  is part of the file's surface, read apart from its initializer.

**Inference fills in the center — the body of a function:**

- **Local `let` bindings** take their type from the initializer:
  `let count = items.len();` is `Int`, no annotation needed.
- **Lambda parameters** take theirs from the surrounding context — the callee's
  signature or the binding's declared type (see [Functions](#functions)).
- **Generic type arguments** are inferred at the call site: `Pair.of('a', 1)`
  yields `Pair<String, Int>` with nothing written.

```hawk
let LABELS: List<String> = ['low', 'mid', 'high'];   // boundary — annotated

fn label_widths() -> List<Int> {          // boundary — annotated
    let widths = LABELS.map(s => s.len()); // center — inferred List<Int>
    return widths;
}
```

**When inference can't decide, that is a diagnostic — never a guess.** If a
local's type is not pinned by its initializer or a later use — an empty `[]`
nothing is ever pushed to, a `None` never paired with a `Some` — the checker
reports that it needs more type information and points at the binding. The
feedback is immediate; the fix is the annotation it asks for:

```hawk
let mut ids = [];              // error: the element type is never pinned
let mut ids: List<Int> = [];   // annotate to resolve it
```

This is the same move as [immutability by default](#variables) and
[qualified cross-library names](#name-resolution--scoping): be explicit exactly
where a reader needs it, and stay out of the way everywhere else.

---

## The type system at a glance

_A descriptive summary of the type system as implemented — not additional rules.
The linked sections are normative; the corners that are deliberately or
currently loose are called out honestly and tracked in
[roadmap.md](roadmap.md)._

Every Hawk type takes one of five shapes:

| Shape          | Examples                          | Notes                                                                                                                                                                 |
| -------------- | --------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Primitive      | `Int`, `Bool`, `Void`             | five of them — see [Primitives](#primitives)                                                                                                                          |
| Named type     | `Shape`, `List<Int>`, `Option<T>` | every struct, enum, interface, and built-in; **nominal** — identity is the declaring file plus the name, so two libraries may declare the same name without colliding |
| Type parameter | the `T` in `fn first<T>(…)`       | opaque inside a generic declaration — see [Generics](#generics)                                                                                                       |
| Function type  | `(Int, String) -> Bool`           | the type of lambdas and function references — see [Functions](#functions)                                                                                             |
| Unknown        | —                                 | the checker's internal "couldn't determine" marker; never written in source                                                                                           |

**Subtyping exists in exactly three places.** A concrete type is assignable to
an interface it `impl`s; a sub-interface is assignable to the interfaces it
extends; and function types relate contravariantly in their parameters,
covariantly in their results. There is nothing else — no numeric coercion (`Int`
never silently widens to `Double`), no top type, no implicit conversions of any
kind. The full relation is specified in [Assignability](#assignability).

**Inference is local and bidirectional.** Expected types flow down (a lambda's
parameter types from the callee's signature, an enum construction's type
arguments from its context); initializer types flow up (`let n = xs.len()` is
`Int`); an underdetermined empty literal is pinned by its first use (see
[Type annotations & inference](#type-annotations--inference)). There is no
whole-program constraint solving: a type is always derivable from what's on the
page nearby, which is the property that lets a reader — human or LLM — reason
about any line with only local context.

**`Unknown` is the escape hatch, and honesty about it is policy.** An expression
the checker can't type becomes `Unknown`, which is lenient on both sides of
assignability so one inference gap never cascades into a page of false errors.
The cost is false negatives: a hole the checker doesn't see surfaces as a
runtime trap instead (the runtime stays memory-safe — every operation is
tag-checked, so a type hole can misbehave but never corrupt memory). The
standing direction is to shrink `Unknown` with targeted diagnostics rather than
reject it wholesale — see roadmap.md.

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
since it would let code split a multi-byte character in half. Work in code
points explicitly instead: `.chars()` yields the Unicode code points (as `Int`s
— `std.char` has classification helpers, and `String.from_chars` rebuilds a
string), and `.slice(start, end)` takes a code-point range, so neither can split
a character.

### Collection types

| Type        | Description                 | Example               |
| ----------- | --------------------------- | --------------------- |
| `List<T>`   | Ordered sequence            | `[1, 2, 3]`           |
| `Map<K, V>` | Key-value store             | `['a': 1, 'b': 2]`    |
| `Set<T>`    | Collection of unique values | `Set.from([1, 2, 3])` |

```hawk
let names: List<String>      = ['alice', 'bob'];
let scores: Map<String, Int> = ['alice': 10, 'bob': 7];
let tags: Set<String>        = Set.from(['cli', 'tool', 'cli']);  // {'cli', 'tool'}
```

Map literals use **brackets** — `['a': 1]`, empty `[:]` — so `{…}` always means
a block (or a struct body), map keys are unrestricted expressions, and a map
literal is valid anywhere an expression is (including a bare match-arm body).
The pre-migration brace form (`{'a': 1}`) is a parse error with a hint pointing
at the bracket syntax.

**Ordering.** As _types_, `Map` and `Set` promise keyed access and uniqueness —
not a particular ordering; code shouldn't lean on element order as part of the
abstract contract (leaving room for domain-specific implementations, e.g. a
sorted map). The **built-in** implementations do preserve **insertion order**
deterministically — iteration, `keys()`/`values()`, and `Display` all render in
the order entries were added — which keeps program output reproducible.

### Bytes

`Bytes` is the core type for raw binary data (binary I/O, HTTP bodies, the
`.hawkbc` format). It is an **immutable** byte sequence — `len`, `get` (→
`Option<Int>`), `slice`, `concat`, `to_string` (→ `Result`, UTF-8 validated),
`to_list`, plus `Bytes.empty()` / `Bytes.from_list(...)`. Build one up with the
mutable `BytesBuilder` (`write_u8` / `write_bytes` / `write_str`, the
fixed-width `write_u16/u32/u64` and `write_f64` in `_le`/`_be` endianness,
varints, then `finish()` → `Bytes`). Both live in `std.core`, so they're
available unqualified.

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
_nominal_ signal (two identically-shaped structs are distinct types). Each field
is a `let`-declaration terminated by `;` (`let name: T;`) — the form reads as a
declaration and distinguishes a struct _declaration_ from a struct
_instantiation_ (the two brace bodies are otherwise identical). Fields are
immutable by default; mark a field `let mut` to allow reassigning it after
construction (the field-level analogue of `let` vs `let mut`).

```hawk
struct Point {
    let x: Double;
    let y: Double;
}

let p = Point { x: 1.0, y: 2.0 };
println('${p.x}, ${p.y}');
p.x = 3.0;            // error: `x` is not `mut`

struct Cursor {
    let mut offset: Int;   // reassignable
    let source: String;    // immutable
}

let c = Cursor { offset: 0, source: 'abc' };
c.offset = c.offset + 1;   // ok
```

Mutability gates _which fields may be reassigned_, not sharing: a `mut` field on
a struct reached through two bindings is observed by both (heap values are
shared references — see [Variables](#variables)).

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
call site has exactly one valid form** — there is no caller-side choice, so
every call to a given function looks the same. That consistency matters for
readers (human and LLM), while still letting the author put labels where they
aid readability and drop them where they are noise.

A parameter is **labeled by default**: its name becomes the call-site label and
callers must write it. Labels make calls self-documenting — especially for
booleans and several same-typed arguments:

```hawk
fn greet(name: String, times: Int) { ... }

greet(name: 'alice', times: 3);
```

Mark a parameter **positional** with a leading `_` (read it as "the external
label is _none_"). The label is then _forbidden_ and the argument is passed by
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
> the checker is currently **more permissive** than it. Today a labeled
> parameter may _also_ be passed positionally, and labeled arguments may be
> reordered — so more than one call form compiles for the same function.
> Tightening to one canonical form (a labeled parameter's label is required;
> positional is forbidden for it), migrating the call sites that rely on the
> looseness, and the style guidance above are tracked in
> [roadmap.md](roadmap.md).

---

## Concurrency

Hawk uses a **single-threaded cooperative fiber model**. All fibers run on one
thread, multiplexed by the runtime scheduler. All I/O calls look synchronous —
there are no `async`/`await` keywords and no `Future<T>` return types. When a
fiber blocks on I/O, the runtime parks it and resumes another; the calling code
never observes the difference.

Fibers share the program's one heap, but only one fiber ever runs, and a fiber
gives up control only at well-defined **yield points** — blocking I/O, channel
operations, `join`, an explicit `fiber.yield()`. Between yield points execution
is atomic, so there are no data races and no locks: a mutex would only matter
for holding state _across_ a yield, which a one-token channel expresses on the
rare occasion it's needed. Fibers coordinate by **communicating** — a result
returned through `join()`, or values passed over a channel — not by guarding
shared state.

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

Spawning a fiber runs work concurrently on the same thread; `join()` returns its
result:

```hawk
import std.fiber;

let handle = fiber.spawn(() => fetch_user(id: 42));
// ... do other work on this fiber ...
let user = handle.join()?;
```

For streams of values (or many-to-one hand-off), a buffered **channel** connects
fibers: `fiber.channel<T>(capacity: n)` returns a `Channel<T>` whose `send`
parks the sender when the buffer is full and whose `receive` parks the receiver
when it is empty, returning `None` once the channel is closed and drained.
(`send` on a closed channel is a [runtime fault](#runtime-faults).)

This is **implemented**: `std.fiber` provides `spawn`/`join`/`yield` and
buffered channels over the cooperative scheduler; `time.sleep` parks on a
scheduler timer; and blocking filesystem, stdin, and process calls are offloaded
to a small worker-thread pool so they park only the calling fiber (no Hawk code
ever leaves the one thread). Still pending: a readiness poller for sockets (the
`std.http` scaling path) and the second-order combinators (`select`, timeouts,
cancellation) — see [roadmap.md](roadmap.md). The runtime design — fibers as
stackless coroutines over the interpreter's explicit frame stack, the scheduler,
parking, and I/O — is in [architecture.md](architecture.md) §Concurrency.

---

## Error handling

There are no exceptions. Errors are returned as `Result<T, E>`. `Error` is an
interface (`fn message(self) -> String`); the simple-case error is built with
the `error('...')` constructor (`-> Error`), and domain libraries `impl Error`
for their own enums.

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
choice the `?` can't make for you — turn an absence into an error explicitly
with `.ok_or(<error>)?`, or drop an error to an absence with `.ok()?`:

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
    let host:    String;
    let port:    Int;
    let log_dir: Option<String>;   // may be absent
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

Beyond these, `Option` carries the usual **combinators** — `map`, `and_then`,
`unwrap_or`, `unwrap_or_else` (plus `ok_or` above and `is_some`/`is_none`) — for
transforming or defaulting a value inline without a `match`. `Result` carries
the matching set (`map`, `map_err`, `and_then`, `unwrap_or`, `unwrap_or_else`,
`ok`, plus `is_ok`/`is_err`). Reach for a combinator when you want to transform
or default a value in a single expression; see
[Choosing a form](#choosing-a-form) for when to prefer it over `if let` /
`let … else` / `?` / `match`.

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
- sending on a closed channel — see [Concurrency](#concurrency)
- running out of memory: a garbage collection that still leaves more live data
  than the heap limit (1 GiB by default; the `HAWK_MAX_HEAP_MB` environment
  variable overrides it)
- runaway recursion: the call stack reaching its depth ceiling (a backstop set
  far above any legitimate depth)

Where a recoverable alternative makes sense, the API offers one alongside the
faulting form — e.g. `list.get(i)` returns `Option<T>` instead of trapping.
Reach for the checked form when absence is a normal, expected case; use indexing
when a missing element would mean a bug.

**The fault diagnostic.** A trap writes a single line to stderr of the form
`hawk: trap: <message>` and exits non-zero. The message is human-readable and
names the specifics:

| Fault                    | Message                                                                               |
| ------------------------ | ------------------------------------------------------------------------------------- |
| list index out of range  | `index out of range: the index is <i> but the length is <n>`                          |
| missing map key          | `key not found: <key>` (string keys are quoted, e.g. `'bob'`)                         |
| integer divide-by-zero   | `division by zero`                                                                    |
| send on a closed channel | `send on a closed channel`                                                            |
| out of memory            | `out of memory: the live heap is <n> MiB but the limit is <m> MiB (HAWK_MAX_HEAP_MB)` |
| runaway recursion        | `stack overflow: the call stack reached <n> frames`                                   |

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

### `break` and `continue`

Inside a loop, `break` exits the loop immediately and `continue` skips to its
next iteration. Both are statements (they produce no value) and both act on the
**innermost enclosing loop** — there are no loop labels.

```hawk
let mut total = 0;
for n in values {
    if n < 0 {
        continue;          // skip negatives
    }
    if n > 1000 {
        break;             // stop at the first large value
    }
    total = total + n;
}
```

A `break` or `continue` outside a loop is a compile error, and neither crosses a
closure boundary — a loop in an enclosing scope does not make one inside a
lambda legal. To leave an enclosing loop from deeper nesting, restructure or
`return`.

### `if let`

`if let PATTERN = SUBJECT { … }` runs the block — binding the pattern's
variables in it — only when `SUBJECT` matches `PATTERN`. It is the
**conditional-binding** form: the canonical way to act on a present `Option` (or
any single enum variant) without a full `match`.

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

`let PATTERN = SUBJECT else { … }` binds the pattern's variable for the **rest
of the block** when the subject matches, and runs the `else` block when it
doesn't. The `else` must **diverge** (end in `return` or `throw`) — that is what
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

A no-binding pattern is allowed as a pure assertion
(`let Ok(_) = r else { … };`). The binding target is a refutable (constructor)
pattern — an uppercase `Some`/`Ok`/… — which is how it is told apart from an
ordinary `let x = …`. Reach for `let … else` over `if let` when the match should
bind for the rest of the function and the failure case exits; reach for `if let`
when you act only in the present case and fall through otherwise.

> v1 limitations: the pattern binds **at most one** variable (use `match` for
> several), and the `else` block must end in a literal `return`/`throw`
> statement (one that diverges only through nested branches isn't yet
> recognized).

### Choosing a form

`Option` and `Result` can be handled several ways. Reach for the one that fits
the shape — there is **one obvious choice per situation**:

| situation                                 | use                                                           |
| ----------------------------------------- | ------------------------------------------------------------- |
| act on a present value (one variant)      | [`if let`](#if-let)                                           |
| bind for the rest of the block, else exit | [`let … else`](#let--else)                                    |
| propagate the failure to the caller       | [`?`](#error-handling)                                        |
| transform or default a value inline       | a combinator — `map` / `and_then` / `unwrap_or` / `ok_or` / … |
| genuinely choosing among ≥2 variants      | `match`                                                       |

Use `match` when you are truly branching on multiple variants. If you find
yourself writing a `_ => void` or `None => void` catch-all only to satisfy
exhaustiveness, one of the other forms is the better fit — that catch-all is the
tell.

When a genuine multi-variant `match` does have an arm with nothing to do, write
it **`=> void`** — the explicit unit value — not `=> {}`: the empty block says
"nothing here" ambiguously (accident? placeholder?), while `void` states the
intent. `hawk lint`'s `void-arm` rule flags the `=> {}` spelling.

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
`g()`; `let x = { f(); g(); }` makes `x` `Void` (the value of `g()` is
discarded). A bare trailing expression is legal **only** in expression position.

**Function bodies are not expression position** — a function still returns with
an explicit `return`, and a bare trailing expression in a function body is a
statement (the require-`;` rule), not an implicit return. This is deliberate:
the value a function produces is always marked, and the `;`-flip can never
silently change a _return_ value.

**`if` without `else`** has type `Void` (the then-branch runs for effect). An
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

let scores = ['alice': 10];
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

`List.map` and `List.filter` are **eager** — each returns a new `List`:

```hawk
let evens = nums.filter(n => n % 2 == 0);   // List<Int>
let doubled = nums.map(n => n * 2);         // List<Int>
```

For **lazy** pipelines over large or streaming sequences there is `Iterator<T>`
(a `std.core` interface): the adapters `map` / `filter` / `take` / `enumerate`
wrap without evaluating, and the consumers `collect()` (→ `List<T>`) and
`count()` drain. Iterators come from `List.enumerate()`, from `std.iter`
(`iter.from_list(xs)`, `iter.range(a, b)`), and from streaming sources like
`io.lines` and `fs.walk`:

```hawk
import std.iter;

let first_evens = iter.range(0, 1000000)
    .filter(n => n % 2 == 0)
    .take(5)
    .collect();                             // [0, 2, 4, 6, 8] — lazily
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

`as _` binds **no** prefix and instead brings the library's public names into
the file **unqualified** — the opt-in escape hatch for a library used
pervasively, where qualifying every reference would be noise. The default stays
qualified; see [Name resolution & scoping](#name-resolution--scoping) for the
full rules.

```hawk
import 'ast' as _;            // Expr, Stmt, Decl, … usable bare in this file
```

`std.core` is the **prelude**: automatically imported into every file, with its
names available **unqualified** (`Result`/`Option`/`Error`, `Eq`/`Display`/
`Debug`, `println`/…). `Result`/`Option` are ordinary prelude enums, so their
variants are constructed qualified (`Result.Ok`, `Option.None`). It is the one
unqualified import; every other library is referenced through its namespace.
`std.cli` (the `Args` argument parser) is an ordinary library — `import std.cli`
when you need it.

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
from `foo_test.hawk` and nowhere else (its public names are still reached
through the `foo` namespace, as in any other importer). The filename convention
grants the access, avoiding a general package-private axis.

Visibility and qualification are **front-end** concerns — name resolution
applies them and they are erased in `.hawkbc` (calls are by index; the bytecode
has no notion of "private" or namespaces). The precise resolution rules — bare
vs. qualified, the prelude, and the algorithm — are in
[Name resolution & scoping](#name-resolution--scoping). Qualified-only access
and `pub` privacy **are enforced**: a bare cross-library reference, a qualified
access to a non-public member, and a bare reference to a value owned by an
un-imported library are all `check` errors, namespaces are per-file, and
resolution is owner-correct for values _and_ types.

---

## Name resolution & scoping

How a name in Hawk source resolves to a declaration: lexical scope first, then
the file's own top-level declarations, the prelude, and — for another library —
its namespace. [Imports](#imports) and [Visibility](#visibility) cover
namespaces and privacy; this section adds the scope rules and the resolution
order.

### Lexical scope

Parameters and `let` bindings introduce value names, in scope from the binding
to the end of the enclosing block. `if`/`while`/`for` bodies, `match` arms, and
block expressions each open a nested scope; a binding introduced inside does not
escape it (a `match` arm's constructor pattern binds its payload within that
arm, a `for` pattern within the loop body). An inner binding may **shadow** an
outer one of the same name, and a local binding shadows any same-named top-level
or prelude value — so `f(x)` where `f` is a `let`-bound lambda or a
function-typed parameter calls the binding, never a same-named top-level
function. Inside an instance method, `self` is the receiver binding and `Self`
is its type.

### One name space per scope

A scope introduces a given name **at most once, across all declaration kinds**.
Two same-file top-level declarations of the same name collide even when their
kinds differ — `fn max` + `const max`, `fn Config` + `struct Config`,
`import std.fs;` + `fn fs` — each a duplicate-name error, exactly like a
same-kind duplicate. A top-level declaration also may not take a name the file's
**bare surface** already provides (a prelude name, or one brought in by an
`as _` import). The rationale is _one name, one meaning_: a reader never needs
the syntactic position to know which declaration a name denotes. (One exemption:
a barrel's `pub import 'error';` may bind the namespace `error` while
re-exporting that library's eponymous `fn error` — a self-referential pair
reaching the same library.)

Syntactic position still selects which _space_ a name is looked up in — a value
(functions incl. `native fn`, consts, locals), a type
(`type`/`enum`/`interface`, built-ins, type parameters), or an import namespace
— but a name is introduced into its scope only once regardless.

### Reserved type names

The type names the language itself speaks are **reserved**: user code may not
declare a `type`/`enum`/`interface` — or a type parameter — named

> `Result`, `Option`, `Ordering`, `List`, `Map`, `Set`, `String`, `Int`, `Bool`,
> `Double`, `Bytes`, `Iterator`, `Error`, `SourceLoc`, `Void`, `Eq`, `Ord`,
> `Display`, `Debug`

— a check error. These names appear in signatures (`Void`), sugar
(`?`/implicit-`Ok`, `#loc`), literals, and protocols (`for` iteration, `==`,
sorting, `${}` rendering, the structural derives, `error(...)`), so a user
redeclaration would make the reserved meaning ambiguous at every use site. The
list is deliberately _not_ the whole core surface: semantics attach to the core
types **by identity, never by name**, so utility types that merely live in
`std.core` (`BytesBuilder`, `Args`, `Indexed`, …) are ordinary names a user
library may redeclare. Value names (`fn`/`const`) are not reserved — casing
conventions keep them unambiguous.

### Resolution order

For each syntactic position, resolution tries the ordered steps and stops at the
first match; failing all steps is a located error.

- **A bare value name** (`name`, or the callee of `name(...)`): (1) an in-scope
  local binding → it; (2) a same-file top-level `fn`/`const` → it; (3) a public
  `fn`/`const` from an `as _` import → it; (4) a prelude public `fn`/`const` →
  it; else **undefined**. A bare name is _never_ resolved against a namespaced
  import — it must be qualified.
- **A qualified value** (`ns.name`): `ns` must be an import namespace of the
  current file (not shadowed by a local named `ns`), and `name` must be in
  `ns`'s public surface; it resolves to that library's `pub` declaration.
- **A bare type name** (annotation, struct literal, static receiver): (1) an
  in-scope type parameter / `Self`; (2) a same-file `type`/`enum`/`interface`;
  (3) a public type from an `as _` import; (4) a prelude public type; (5) a
  built-in (`Int`/`String`/`List`/…); else **unknown type**. (For the language's
  own types the order is unobservable — their names are reserved, so steps 2–4
  never capture one.)
- **A qualified type** (`ns.T`): as `ns.name`, resolved in the type space.
- **Members** (`recv.m(...)`, `recv.f`, `T.m(...)`, `E.V(...)`): resolved
  through the receiver or type — its static type and visible `impl`s — not a
  namespace. Interface references (an `impl I for T`, a super-interface, a
  `<T: I>` bound) resolve in their declaring file's scope by the bare-type
  algorithm, and interface **identity** is the resolved declaration (owner +
  name), so two libraries' same-named interfaces never entangle. See
  [Interfaces](#interfaces).

Qualification therefore applies to **free functions, consts, and type names** —
the things a library owns at top level. Methods and variants are selected within
an already-resolved receiver/type, not separately namespace-qualified.
Resolution is **owner-correct**: two libraries may share a top-level name
(`std.json.parse` vs `std.toml.parse`), each qualified reference dispatching to
its own library.

---

## Documentation

Documentation is written for an audience of LLMs and coding agents first. The
guiding principle is **progressive disclosure**: a reader should be able to
grasp a file, then a symbol, by reading as little as possible — one summary
sentence — and descend into detail only when they need it.

### Three comment forms

Hawk distinguishes documentation from ordinary comments lexically, so tooling
can extract one without scraping the other:

| Form  | Role             | Attaches to                                                       |
| ----- | ---------------- | ----------------------------------------------------------------- |
| `///` | **item doc**     | the declaration immediately below it                              |
| `//!` | **file doc**     | the enclosing file (sits at the top, above the first declaration) |
| `//`  | ordinary comment | nothing — an internal aside, never extracted                      |

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
extracted, an internal note may sit directly above a declaration without
becoming its documentation — the disambiguation a position-only rule (Go's "the
comment above the symbol") cannot provide.

A directory library's **barrel** `//!` header is the **package doc** — the
single thing an agent reads to understand a whole library. A recommended
`Import as:` line gives the exact import to copy. (This is the only doc
convention above the symbol level; directory overviews and generated indexes are
deferred.)

### The summary sentence

The **first sentence** of any doc (through the first `.`) is its summary. It
must:

- **stand alone** — it appears by itself in one-line contexts (a symbol index,
  editor hover, a package's table of contents), with no further lines for
  support;
- **add information beyond the name** — if the name and signature already say
  everything, write no doc at all rather than restate them. A doc that only
  echoes the signature (`/// Returns the length.` on `len(self) -> Int`) is
  worse than none.

A blank `///` line separates the summary from any further paragraphs. Functions
lead with the result as a noun phrase ("The substring of code points in
`[start, end)`."), not "This function returns…".

> **When to document.** Every `pub` symbol should carry a doc comment _unless
> its name and signature are fully self-describing_. Private symbols are
> documented only where the intent is non-obvious. Brevity is a feature: the
> goal is the shortest doc that adds something a reader couldn't get from the
> signature.

### Markdown

Doc comments are Markdown, restricted to a small, predictable subset (anything
outside it is treated as plain text):

- **Inline:** `` `code` `` and `**bold**`.
- **Links & references:** `[text](path)` is an ordinary Markdown link, used to
  cross-reference other docs. `[Symbol]` (no trailing `(…)`) is a **resolvable
  symbol reference** — a shorthand naming a declared symbol the way code does
  (`[Display]`, `[String.slice]`, `[fs.read_text]`), resolved from the
  documented file's scope. The two are not interchangeable: `` `code` `` is
  **inert text** the tooling never checks, whereas `[Symbol]` is a **checked,
  navigable reference** — doc tooling links it, and a lint flags a `[Symbol]`
  that no longer resolves (doc-rot protection). Use `[Symbol]` when you want a
  reference to be navigable and verified; use backticks for any other
  code-shaped text. Backticks always work, so the bracket form is a pure opt-in
  upgrade, never required.
- **Lists:** `-` bullets and `1.` ordered lists.
- **Code blocks:** fenced only, tagged with the language — ` ```hawk `. Indented
  code blocks are **not** supported (they force an ambiguous indent-width rule
  under the `///` prefix); a fence is delimited, needs no measuring, and is the
  form LLMs read and emit most reliably. A fence may be left **untagged** when
  its content is preformatted text that is _not_ Hawk code — a syntax table, a
  grammar fragment, or sample program output — so the `hawk` tag never falsely
  implies something is runnable.

There are **no ATX headers** (`#`, `##`) in doc comments — `#` would invite
long, sectioned docs that cut against the brevity goal, and a symbol's name is
already its title. When a longer doc genuinely needs sections, use a small fixed
set of **bold-label paragraphs** instead:

| Label          | Use                                                                               |
| -------------- | --------------------------------------------------------------------------------- |
| `**Example:**` | a usage example (usually a fenced `hawk` block)                                   |
| `**Errors:**`  | the conditions under which a `Result` returns `Err`                               |
| `**Traps:**`   | the conditions under which the call traps (see [Runtime faults](#runtime-faults)) |
| `**Note:**`    | a caveat or non-obvious consequence                                               |
| `**See:**`     | a cross-reference to a related symbol (`[Symbol]`) or doc                         |

````hawk
/// The element at `index`, or `None` if `index` is out of range.
///
/// **Example:**
/// ```hawk
/// let xs = [10, 20, 30];
/// xs.get(1);    // Some(20)
/// xs.get(9);    // None
/// ```
pub fn get(self, _ index: Int) -> Option<T> { ... }
````

### Parameters

Document parameters **in prose**, naming them in backticks (`` `index` ``) —
there is no `@param` tag vocabulary. Document a parameter only when its name and
type do not already convey its role: units, valid ranges, edge behavior, or how
it relates to another parameter. The return value is described in the summary,
not in a separate tag.

```hawk
/// The substring of code points in the half-open range `[start, end)`.
/// Indices are clamped to the string's length, so a reversed or out-of-range
/// range yields a shorter or empty string.
pub fn slice(self, _ start: Int, _ end: Int) -> String { ... }
```

> **Enforcement status.** The conventions above are adoptable in source today:
> the lexer skips every `//…` line, so `///` and `//!` already lex cleanly as
> comments. The supporting _machinery_ — attaching docs to AST nodes, surfacing
> them in LSP hover, a doc generator, formatter and lint awareness, and
> migrating the existing `//` headers in `sdk/std/` — is tracked in
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

`process.run` executes a subprocess to completion and returns
`Result<ProcessResult, ProcessError>`. `ProcessResult` has `stdout`, `stderr`
(strings), and `exit_code` (`Int`). A non-zero exit code is **data**, not an
error — the `Err` case is failing to run the command at all (executable not
found, spawn failure); `ProcessError` implements `Error`, so `?` propagates it
like any other.

```hawk
import std.process;

let out = process.run('git', args: ['status', '--short'])?;
if out.exit_code != 0 {
    throw error('git failed: ${out.stderr}');
}
println(out.stdout);
```

Two siblings cover the other spawn shapes: `process.exec` runs a child that
**inherits** the terminal (nothing captured; returns its exit code), and
`process.start` returns a `Process` handle whose `stdin`/`stdout`/`stderr` are
`std.io` `Writer`/`Reader` pipes for streaming. See [stdlib.md](stdlib.md).

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

The interface name resolves like any type name — same file, bare surface
(prelude / `as _`), or qualified through an import namespace:
`impl io.Reader for File` implements `std.io`'s `Reader`. Interface **identity**
is the resolved declaration (owner + name), not the spelling: two libraries may
each declare a `Shape`, and a conformance, bound, or interface-typed parameter
binds to the one its own file resolves — never to a same-named interface
elsewhere (see [Name resolution & scoping](#name-resolution--scoping)).

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

struct Dog { let nick: String; }

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
value at runtime. This works on both interface-typed receivers
(`fn f(a: Animal)` → `a.greet()`) and concrete ones (`Dog { … }.greet()`).

The standard `Iterator<T>` uses this: its only required method is `next`, and
the adapters (`map`/`filter`/`take`/`enumerate`) and consumers
(`collect`/`count`) are all default methods — so every iterator is fluent
without each implementer re-spelling them. See [stdlib.md](stdlib.md).

### Inherent methods

Methods that belong to a type but do not implement an interface are defined in a
plain `impl TypeName` block:

```hawk
struct Counter {
    let value: Int;
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
  messages, logging, and diagnostic output. Shows internal structure.
  Auto-derived for structs; can be overridden. The derive currently renders
  fields **positionally** (`Point { 1.0, 2.0 }` — including the field names is a
  [roadmap.md](roadmap.md) item).

Primitive types (`Int`, `Double`, `Bool`, `String`) implement both
automatically. Structs get a default `Debug` implementation; `Display` must be
implemented explicitly.

```hawk
// auto-derived Debug for a struct prints its fields (positionally):
//   Point { 1.0, 2.0 }

struct Point {
    let x: Double;
    let y: Double;
}

// explicit Display for a user-facing format
impl Display for Point {
    fn display(self) -> String {
        return '(${self.x}, ${self.y})';
    }
}
```

String interpolation (`${}`) renders with a value's `Display` when it has one
and falls back to its `Debug` otherwise — rendering is **total**, so
interpolating any value works and is never a compile error. Implement `Display`
where a type has a meaningful user-facing form; the `Debug` fallback keeps
diagnostics and quick `println` debugging frictionless.

`Eq` works the same way: `==`/`!=` use a type's explicit `impl Eq` when present,
otherwise the structural derive (primitives, and structs/enums whose fields are
all `Eq`). So `Eq` and `Debug` are **structural-by-default with explicit
override**; `Display` is always explicit (it has no meaningful default). `Ord`
(total ordering — an `impl Ord` whose `compare` returns an `Ordering`, or
built-in for primitives) follows the explicit-or-built-in pattern too and backs
sorting; see [stdlib.md](stdlib.md) (`std.sort`).

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

## Generics

Functions, methods (instance and static), structs, enums, and interfaces may
declare **type parameters** in angle brackets. There are no generic top-level
bindings and no higher-kinded parameters (no `F<T>` where `F` is itself a
parameter).

```hawk
struct Pair<A, B> {
    let first: A;
    let second: B;
}

enum MaybeBoth<T> {
    One(T),
    Both(T, T),
}

interface Container<T> {
    fn get(self, _ index: Int) -> Option<T>;
}

fn swap<A, B>(_ p: Pair<A, B>) -> Pair<B, A> {
    return Pair { first: p.second, second: p.first };
}
```

### Bounds

A type parameter may require interfaces of its instantiations: `<T: Display>`,
`+`-joined for several (`<T: Eq + Debug>`). Bounds are **enforced where the
parameter is instantiated** — at the call site for a function's type parameters,
and wherever a concrete type argument is supplied for a bounded
struct/enum/interface parameter (a struct literal, an annotation, an explicit
type argument):

```hawk
fn show_all<T: Display>(_ xs: List<T>) -> Void {
    for x in xs {
        print(x.display());
    }
}
```

Passing a `List<Plain>` where `Plain` has no `Display` impl is a check error at
the call site ("type argument does not implement `Display`"). Primitives satisfy
the built-in `Eq`/`Display`/`Debug`; structs and enums satisfy `Eq`/`Debug` via
the structural derives; anything else needs an explicit `impl` (see
[Interfaces](#interfaces)).

Inside the generic body, a **bounded** parameter exposes exactly its bounds'
methods, dispatched dynamically (see [Dispatch](#dispatch)); calling a method no
bound declares is an error. An **unbounded** `T` is opaque: a value of it can be
stored, passed, returned, compared where the context allows — and rendered,
since `display()`/`debug()` are total (every value renders via its impl or the
derived fallback). One phase wrinkle: a method call on an unbounded `T` is today
rejected at emit time rather than by `hawk check` (tracked in roadmap.md).

### Type arguments

Type arguments are normally **inferred at the use site** — from the argument
types, the receiver, and the expected type, in that priority order. The expected
type matters when a parameter appears only in the return type:
`let s: Set<Int> = Set.new();` pins `T = Int` from the annotation.

When context doesn't decide, spell the arguments explicitly — on a call
(`make<Int>(3)`) or on a static-method receiver (`Set<String>.new()`). And when
neither context nor explicit arguments pin a parameter, that is a "cannot infer
type argument" diagnostic — never a guess (the same rule as
[local inference](#type-annotations--inference)).

### Erasure

Type arguments are a compile-time construct: checked statically, absent at
runtime. A `List<Int>` and a `List<String>` are the same runtime shape, and
there is no runtime type-argument test. Bounded-parameter method calls compile
to dynamic dispatch (`call.virtual` — see [architecture.md](architecture.md)),
so generic code is one compiled body, not a per-instantiation copy.

---

## Assignability

One relation drives every typed boundary — bindings, call arguments, `return`
values, struct-literal fields: **may a value of type `S` be used where `T` is
expected?** It holds when any of these applies, and nothing else converts:

1. **Identity.** `S` and `T` are the same type: same shape, same named-type
   identity (declaring file + name), pairwise-identical type arguments.
2. **Leniency.** Either side is `Unknown` — deliberate, so an inference gap
   never produces a false error (see
   [the note above](#the-type-system-at-a-glance)). Either side is a type
   parameter — **looser than intended**: today this accepts `return x;` inside
   `fn f<T>(_ x: T) -> Int`, which traps at runtime; tightening it is tracked in
   roadmap.md.
3. **Interface conformance.** `T` is an interface and `S` `impl`s it, or `S` is
   an interface that extends `T` (transitively). _Loose corner:_ the target's
   type arguments are not yet compared, so a type whose impl is `Iterator<Int>`
   is currently accepted where `Iterator<String>` is expected (tracked in
   roadmap.md).
4. **Same named type, assignable arguments.** `List<Cat>` is accepted where
   `List<Animal>` is expected — type arguments are **covariant** today. That is
   sound for reading and unsound under mutation (pushing a `Dog` through the
   `List<Animal>` view corrupts the typing of the original binding, though never
   memory). The variance decision — leaning toward no variance annotations, with
   a special-cased read-only widening instead — is tracked in roadmap.md.
5. **Functions.** Parameters are contravariant, the result covariant: where a
   `(Cat) -> Animal` is expected, an `(Animal) -> Cat` is accepted — it handles
   every `Cat` it will be given and returns only `Animal`s. The unsafe
   directions are rejected.

Everything else is a type error. In particular there is no `Int` → `Double`
coercion (call `.to_double()`), no universal top type to erase to, and no union
or intersection types.

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

That principle shapes output defaults: `check`, `emit`, and `fmt` are silent on
success and emit only on failure — no output means no problem, and an agent's
context stays clean. (`hawk test` currently prints a full report even on
success; quieting its green path — and a `--verbose` mode for the human who
wants the detail — is tracked in [roadmap.md](roadmap.md).)

### Commands

| Command      | Description                                             |
| ------------ | ------------------------------------------------------- |
| `hawk run`   | Run a source file                                       |
| `hawk check` | Type-check without running                              |
| `hawk test`  | Run tests                                               |
| `hawk fmt`   | Format source files in place (`--check` to only report) |
| `hawk lint`  | Report non-idiomatic code shapes with a known rewrite   |
| `hawk fix`   | Apply lint rewrites (previews by default; UX is TBD)    |
| `hawk emit`  | Compile to a `.hawkbc` bytecode file                    |
| `hawk lsp`   | Start the language server                               |

### `hawk test`

`hawk test <file|dir>` runs the `@test` functions in a `*_test.hawk` file, or in
every `*_test.hawk` found under a directory. The target argument is required.
Output is a per-file report — a path header, one `ok`/`FAIL` line per test, then
a summary — with each failure's detail indented under its `FAIL` line in the
standard `path:line:column: message` diagnostic shape:

```
$ hawk test src
src/math_test.hawk
  FAIL  test_add
          src/math_test.hawk:7:5: assert_eq failed
            actual:   5
            expected: 4
  ok    test_trim

1 of 1 file had failures.
```

A passing test's captured stdout is discarded (a failing test's is shown); pass
`--show-output` to see it for passing tests too. The exit code is 0 when every
test passes, 1 when any fail or none are found — never a count. A test file that
fails to **compile** produces no results: those diagnostics go to stderr as an
operational failure (see [architecture.md](architecture.md) for the
stdout/stderr rules).

Open UX items (tracked in [roadmap.md](roadmap.md)): a quieter success mode (the
`ok` lines are tokens an agent doesn't need), a `--verbose` flag for the
opposite preference, and defaulting the target to the current directory.

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
  runtime/         ← Rust runtime: bytecode interpreter, GC, fiber scheduler
                     (builds `hawkrt`, the bare runtime)
  pkgs/
    cli/           ← Hawk front-end + CLI harness (written in Hawk)
  sdk/
    std/
      core/core.hawk        ← auto-imported prelude (barrel; re-exports its
                              siblings: interfaces, error, string, list, map,
                              set, option, result, bytes, iterator, …)
      cli/cli.hawk          ← import std.cli (barrel re-exporting args.hawk)
      fs/fs.hawk            ← import std.fs
      testing/testing.hawk  ← import std.testing (barrel: assert, clock, env)
      ...                   ← char, encoding, env, fiber, hash, io, iter, json,
                              log, math, path, process, random, regex, sort,
                              term, time
  examples/
  docs/
```

### Two binaries: `hawkrt` and `hawk`

The Rust crate builds **`hawkrt`** — the _bare runtime_: it loads and runs a
`.hawkbc` and nothing else. The SDK build takes that same binary, embeds the
compiled front-end (`frontend.hawkbc`) into it, and ships it as **`hawk`** — the
full launcher. So `hawk` is `hawkrt` + an embedded front-end: invoked on a
`.hawkbc` (or `--entry`) it behaves as the bare runtime; invoked on a subcommand
(`run`, `check`, `test`, `emit`, `fmt`, `lint`, `fix`, `lsp`) it boots its
embedded front-end. The distinction lets a `cargo build` (which yields `hawkrt`)
be unambiguously the runtime, while `hawk` is unambiguously the runtime +
front-end.

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
  `.map`/`.and_then`, represents nested absence) vs. `String?` with `?.`/`??`
  (zero boilerplate, no wrapper, but can't nest). `language.md` uses `Option<T>`
  as a placeholder; revisit once there's enough real Hawk code to judge
  friction.
- **Concurrency beyond single-threaded fibers** — the model is single-threaded
  cooperative fibers (no synchronization needed, no CPU parallelism). If
  parallelism becomes a requirement: _immutable-only sharing_ across threads
  (hard to enforce without deeper type support) or _thread-isolated heaps_
  (private heap per scheduler, communicate by copying). Deferred.
