# Writing Thera

**What this is:** the how-to-write-Thera primer for LLMs and coding agents —
enough to write correct, idiomatic Thera cold, ordered by what first-time
writers actually get wrong. The full reference is [language.md](language.md);
the stdlib catalog is [stdlib.md](stdlib.md). When this doc and the checker
disagree, believe the checker.

## Orientation

```thera
//! One-line file doc: what this file is.

import std.fs;                            // used as `fs.…`
import 'parser';                          // sibling file parser.thera, used as `parser.…`

/// Item docs: one summary sentence first.
struct Config {
    let path: String;                     // fields: `let name: Type;` — immutable
    let mut hits: Int;                    // opt-in mutable field
    let root: Option<String>;             // no null — absence is Option
}

enum Shape {
    Circle(Double),
    Rect(Double, Double),
}

fn area(_ s: Shape) -> Double {           // `_` = positional parameter; labeled is the default
    return match s {                      // match arms use bare patterns
        Circle(r) => 3.14159 * r * r,
        Rect(w, h) => w * h,
    };
}

fn load(_ path: String) -> Result<Config, Error> {
    let text = fs.read_text(path)?;       // `?` propagates the Err
    if text.is_empty() {
        throw error('empty config: ${path}');   // throw = return Result.Err(…)
    }
    return Config { path: path, hits: 0, root: Option.None };  // implicit Ok on return
}

fn main(args: List<String>) -> Result<Int, Error> {
    let cfg = load(args.get(0).unwrap_or('config.toml'))?;
    println('loaded ${cfg.path}');        // ${} interpolation renders any value
    return Result.Ok(0);
}
```

Semicolons terminate statements. Blocks are braces. Indent 4 spaces, 100-column
lines — `thera fmt` owns line breaking, so never hand-wrap. Names: `snake_case`
functions/values, `PascalCase` types/variants, `SCREAMING_SNAKE` consts. String
literals conventionally use single quotes.

## Rules you will otherwise get wrong

Each of these is a real first-contact error, most-frequent first.

1. **Construct `Result`/`Option` qualified; match them bare.** They are ordinary
   prelude enums, not keywords.

   ```thera
   let a = Result.Ok(3);         // not Ok(3)
   let b = Option.Some('x');     // not Some('x')
   let c: Option<Int> = Option.None;
   match b { Some(s) => println(s), None => void };   // patterns stay bare
   ```

2. **Nothing wraps or converts implicitly** — with one exception: `return x;` in
   a `Result`-returning function wraps to `Ok(x)`, and a `Result<Void, _>`
   function returning normally is `Ok(void)`. Everywhere else, spell it: pass
   `Option.Some(x)` where `Option<T>` is expected, never bare `x`. There is no
   `Int` → `Double` coercion — call `.to_double()`.

3. **Don't guess an API — look it up.** The biggest error source is calling
   methods that don't exist (`n.to_string()`, `s.parse<Int>()`,
   `time.monotonic_ms()`). Conversions that do exist: `'${x}'` interpolation
   renders any value; `x.display()` / `x.debug()`; `s.to_int()` /
   `s.to_double()` (→ `Option`); `i.to_double()`. For anything else, read the
   library source (`sdk/std/<lib>/<lib>.thera`) or [stdlib.md](stdlib.md) before
   calling, and run `thera check` after a few edits, not after fifty.

4. **JSON values are not duck-typed.** `resp.field` on a `Json` value is the
   single most common check error (`field access on non-struct value`). Go
   through the accessors:

   ```thera
   let name = doc.get('user').get('name').as_string().ok_or(error('missing name'))?;
   ```

   For decoding into structs, use `json.cursor(doc)` and its
   `field(…)`/`string()`/`int()`/`opt_…()` chain — see `std.json`.

5. **`?` propagates within one family only.** An `Option` `?` needs an
   `Option`-returning function; a `Result` `?` a `Result`-returning one. Convert
   explicitly at the boundary: `opt.ok_or(error('…'))?` (absence → error),
   `res.ok()?` (error → absence).

6. **A dropped `Result` is a check error.** Handle it (`?`, `match`, `if let`)
   or discard explicitly: `let _ = fs.remove(path);`. Dropping an `Option` is
   fine.

7. **Arguments are labeled by default.** A parameter declared `name: T` must be
   called as `f(name: v)`; only `_ name: T` parameters are positional. So:
   `testing.assert_eq(actual: got, expected: want)?`,
   `process.run('git', args: […])`.

8. **Qualify everything cross-library.** `import std.fs;` then `fs.read_text(…)`
   — a bare `read_text` is an error, as is `assert_eq` without `testing.`. Only
   the prelude (`std.core`: `Result`, `Option`, `Error`, `println`, `error`,
   `String`/`List`/`Map`/`Set` methods, …) is unqualified. A directory library
   is importable only via its barrel (`import 'lexer'`, never
   `import 'lexer/token'`).

9. **Empty literals need a pinned type, and map literals use brackets.**

   ```thera
   let mut xs: List<Int> = [];               // [] alone can't infer
   let m: Map<String, Int> = ['a': 1];       // not {'a': 1}
   let empty: Map<String, Int> = [:];        // empty map is [:]
   ```

   The same applies to generic calls whose type parameter appears only in the
   return: `let s: Set<Int> = Set.new();`,
   `let cfg: Config = testing.assert_ok(r)?;`.

10. **Annotate the boundaries; let the center infer.** Function parameters,
    return types, struct fields, and module-level `let`/`const` are always
    annotated. Locals are not (`let n = xs.len();`). `const` initializers must
    be compile-time constants; a value computed once at load is a module-level
    `let` (still annotated). There is no top-level `let mut` — no mutable
    globals.

11. **Indexing traps; `.get` returns `Option`.** `xs[9]` and `m['missing']`
    abort the program. Index only when absence would be a bug; otherwise
    `xs.get(i)` / `m.get(k)` and handle the `Option`.

12. **Functions return explicitly.** No implicit tail return in a function body
    — every value-returning path ends in `return` or `throw`, and falling off
    the end is an error (except `Void` and `Result<Void, _>`). Tail expressions
    exist only in _expression_ blocks (match arms, `if` used as a value): the
    last expression without `;` is the block's value — adding a `;` there
    changes the value to `Void`.

13. **Keywords and reserved names are off-limits as identifiers.** `type` is a
    keyword — it cannot be a field, parameter, or label name anywhere (a real
    trap when mirroring JSON APIs whose payloads have a `type` field; name the
    field `kind` and map it explicitly at the decode boundary). User code may
    not declare types named `Result`, `Option`, `List`, `Error`, `Display`, …
    (the reserved list is in [language.md](language.md) §Reserved type names).
    And one name per scope: a second `let x` in the same block, or a top-level
    `fn` shadowing a prelude name, is an error.

14. **The unit type is `Void`, written `void`.** Function types spell it:
    `() -> Void`, `(Int) -> Void` — not `()` or `-> ()`. A function with nothing
    to return just omits the return type.

15. **`let … else` must bail.** The `else` block ends in a literal `return` or
    `throw` (that's what makes the binding usable below), and the pattern binds
    at most one variable.

16. **Strings are UTF-8 and not indexable.** No `s[i]`. Use `.chars()` (code
    points as `Int`s), `.slice(start, end)` (code-point indices), `.split(…)`,
    `.len()`. Escapes are a fixed set
    (`\n \t \r \b \f \v \0 \\ \' \" \$ \xNN \u{…}`) — an unknown escape like
    `\a` is an error; for regex/path literals use raw strings: `r'(\w+)@'`.
    Interpolation is `${expr}`; a literal `${` needs `\$` or a raw string.

17. **No `async`/`await`.** All I/O looks synchronous; the runtime parks the
    fiber. Concurrency is `fiber.spawn(() => work())` … `handle.join()`, and
    channels — never callbacks or futures.

## Canonical forms

For handling an `Option`/`Result`, there is one obvious form per shape:

| situation                                 | write                                                      |
| ----------------------------------------- | ---------------------------------------------------------- |
| act on a present value (one variant)      | `if let Some(x) = subject { … }`                           |
| bind for the rest of the block, else exit | `let Some(x) = subject else { throw …; };`                 |
| propagate the failure to the caller       | `expr?`                                                    |
| transform or default inline               | `.map(…)` / `.and_then(…)` / `.unwrap_or(…)` / `.ok_or(…)` |
| genuinely choosing among ≥2 variants      | `match`                                                    |

**The anti-pattern is `match`-as-guard.** A `match` with a `_ => void` (or
`None => void`) arm you wrote only to satisfy exhaustiveness is the tell that
one of the other forms fits:

```thera
// no                                        // yes
match m.get(k) {                             if let Some(v) = m.get(k) {
    Some(v) => use(v),                           use(v);
    None => void,                            }
}
```

When a genuine multi-variant `match` has a nothing-to-do arm, write it
`=> void`, not `=> {}`.

More canonical choices:

- **Iterate, don't index.** `for x in xs { … }`, `for i in 0..n { … }`, and
  `for pair in xs.enumerate() { … }` (`pair.index` / `pair.value`) replace
  `while i < xs.len()` counters.
- **Transform with combinators.** `xs.map(f)`, `.filter(p)`, `.fold(init, f)`
  for eager list work; `std.iter` / `Iterator` adapters (`.take`, lazy
  `.map`/`.filter`, then `.to_list()`) for large or streaming sequences.
- **Guard early, keep the happy path flat.** Open a function with `let … else` /
  `?` bail-outs rather than nesting the success path inside `if`s.
- **Mutation is local and rare.** Bindings are immutable by default; a `let mut`
  accumulator inside one function is fine, threading mutable state further is
  not. Note that collections are shared by reference — `let` prevents rebinding,
  not mutation through another alias.
- **Errors:** `error('message with ${context}')` for simple cases; a library
  defines an error enum with one variant per _kind_ of failure and `impl Error`
  for it. `throw` early on invalid input.
- **Tests** live beside the source as `<name>_test.thera` (which grants
  white-box access to its private names), functions marked `@test`, returning
  `Result<Void, Error>`, every assertion called with `?`:

  ```thera
  @test
  fn test_area() -> Result<Void, Error> {
      testing.assert_eq(actual: area(Shape.Circle(1.0)), expected: 3.14159)?;
  }
  ```

- **Docs:** `///` above a declaration, `//!` for the file header, `//` for
  asides (never extracted). First sentence stands alone and adds what the
  signature doesn't say — if it can't, write no doc. No `#` headers; use
  `**Example:**` / `**Errors:**` / `**Note:**` label paragraphs. Reference
  symbols as `[fs.read_text]` when you want the link checked.

## The stdlib in one screen

All stdlib imports are `import std.<name>;` and used qualified. `std.core` is
the prelude — never imported, never qualified.

| library                    | one line                                                                                                                                                       |
| -------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `core` (prelude)           | `Result`/`Option`/`Error`, `Eq`/`Ord`/`Display`/`Debug`, `println`/`eprintln`/`print`, `error(…)`, `Bytes`/`BytesBuilder`, methods on primitives & collections |
| `cli`                      | `Args`: positionals, `--flag`s, options                                                                                                                        |
| `env`                      | `args()`, `get`/`set` env vars, `exit(code)`, cwd                                                                                                              |
| `fs`                       | `read_text`/`write_text`, streaming files, `walk`, metadata                                                                                                    |
| `path`                     | pure path join/split/normalize                                                                                                                                 |
| `io`                       | `Reader`/`Writer` streaming protocol, stdin/stdout, `lines`                                                                                                    |
| `process`                  | `run` (capture), `exec` (inherit tty), `start` (pipes)                                                                                                         |
| `time`                     | `now()`, `Instant`/`Duration`, `DateTime`, `sleep`                                                                                                             |
| `fiber`                    | `spawn`/`join`/`yield`, buffered channels                                                                                                                      |
| `json`, `toml`             | parse/serialize; `json.cursor` for typed decoding                                                                                                              |
| `iter`                     | lazy `Iterator` sources: `range`, `from_list`                                                                                                                  |
| `math`, `random`, `sort`   | numerics; RNG; sorting & extrema over `Ord`                                                                                                                    |
| `regex`                    | `Regex.compile(…)?`, `is_match`/`find`/`captures`                                                                                                              |
| `encoding`, `hash`         | base64/hex/url; digests & checksums                                                                                                                            |
| `http` (+ `server`, `sse`) | HTTP(S) client, simple server, server-sent events                                                                                                              |
| `net`                      | TCP sockets                                                                                                                                                    |
| `log`, `term`, `char`      | leveled logging; terminal colors/size; code-point classification                                                                                               |
| `testing`                  | `assert`, `assert_eq`, `assert_ne`, `assert_ok`, `assert_err`                                                                                                  |

## Feedback loop

`thera check` (defaults to the whole cwd) is cheap — run it after every few
edits; its diagnostics usually name the fix. `thera test` runs `@test`
functions; `thera fmt` formats (never hand-format); `thera lint` flags
non-idiomatic shapes. In this repository the tool is
`bin/thera.sh <check|test|run|fmt> …`.

Warnings (`unused-import`, `unused-variable`, `unreachable-code`,
`unreachable-arm`) don't block but should be fixed, not suppressed; prefix a
genuinely-unused binding with `_`, and delete imports you stopped using.
