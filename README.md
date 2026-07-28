# Thera

**An LLM-native programming language.**

Most languages were shaped by human constraints — terse syntax to save
keystrokes, significant whitespace for visual cleanliness, exceptions to keep
the happy path uncluttered. Those tradeoffs read differently when the code is
being written, reviewed, and patched by an agent. Thera is a language that
optimizes for the way LLMs read and write code: strong static typing, errors as
values, immutability by default, explicit braces, an opinionated formatter, and
a deep standard library.

It aims at the space Python, Go, and Node.js occupy — scripting, CLI tooling,
and automation — on top of a Rust bytecode VM with fast startup, garbage
collection, and cooperative fibers. The front-end is itself written in Thera and
self-hosts.

The name is a nod to the
[Antikythera mechanism](https://en.wikipedia.org/wiki/Antikythera_mechanism).

## An example

```thera
import std.cli;
import std.fs;

struct Counts {
    let lines: Int;
    let words: Int;
    let bytes: Int;
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
    let path = args.positional(0).ok_or('usage: wordcount <file>')?;
    let text = fs.read_text(path)?;
    let c = count(text);

    println('${c.lines}\tlines');
    println('${c.words}\twords');
    println('${c.bytes}\tbytes');

    return Result.Ok(0);
}
```

Things worth noticing: `let` bindings are immutable unless you write `let mut`.
Fallible calls return `Result<T, E>` and propagate with a postfix `?` — there
are no exceptions, so every failure path is visible in the signature. Absence is
`Option<T>`; there is no `null`. Parameters are labeled at the call site by
default (`process.run('git', args: [...])`), and a leading `_` drops the label
where a parameter's role is obvious. String interpolation (`${}`) renders any
value: `Display` falls back to a derived `Debug`.

More in [examples/](examples/) — closures, enums, structs, fibers, JSON, and a
couple of small but real CLIs.

## Why these choices

Each of Thera's design choices is aimed at a specific way agents lose accuracy.

**Static types prune hallucinations.** A nominal, deliberately simple type
system acts as an immediate check on generated code, and it avoids the
Turing-complete type-level puzzles that produce cascading, context-devouring
error messages.

**Errors as values keep control flow linear.** Exceptions are invisible jumps
that bypass the type system, which makes it easy to omit handling entirely.
`Result<T, E>` plus `?` puts every failure path in the signature and on the
page.

**Immutability by default removes the multi-hop attention tax.** When a binding
can change anywhere, predicting behavior means scanning back and forth across
the function. Immutable-by-default bindings let code be read once, top to
bottom.

**Braces survive bad diffs.** An off-by-one indentation error in a generated
patch is at best a syntax error and at worst a silent logic change.
Brace-delimited blocks are robust to layout drift, and `thera fmt` tidies the
indentation afterward.

**One formatter, no options.** A single canonical layout means generated code
and reference code match, review never argues about style, and no tokens are
spent on formatting decisions.

**A deep standard library beats a fragmented ecosystem.** Agents hallucinate the
APIs of obscure packages; they know the ones that ship with the language.

**No metaprogramming.** No macros, no aggressive operator overloading — what the
code says is what it does, for the reader and for static analysis alike.

## The runtime

The runtime is written in Rust and tuned for the instant startup CLI tools need.

**Bytecode is the unit of execution.** Source compiles to a compact stack-based
format (`.thera-bc`) with a constant pool and natives bound by name at load.
Bytecode serializes to disk, so compilation and execution are separable, and a
compiled artifact stays compatible across runtime builds.

**Tier 0 is a bytecode interpreter that starts instantly.** Most CLI code runs
exactly once, so there is nothing to gain from compiling it first. Programs
start executing immediately, with no warm-up.

**Tier 1 is a Cranelift JIT (planned).** Call and back-edge counters will
promote hot functions to native code. Because Thera is statically typed and the
bytecode retains concrete types, lowering is straightforward: no speculation, no
inline caches, no deopt guards — a much smaller and more reliable JIT than the
ones JS and Python need.

**Precise, non-moving mark-sweep GC.** Stackmaps at allocation and call
safepoints identify which slots hold pointers; heap objects carry type headers
for nested references. The collector stays non-moving so that interpreted and
(eventually) JIT-compiled frames can interleave freely.

**Self-hosted.** The `thera` binary is the Rust runtime; the compiler front-end
— lexer, parser, resolver, checker, inference, codegen, plus the CLI and
language server — is an ordinary Thera program compiled to bytecode.

## Batteries included

The standard library covers the CLI surface directly, so a script rarely needs a
third-party package: `std.fs`, `std.path`, `std.process`, `std.env`, `std.io`,
`std.cli`, `std.json`, `std.http` (client + a simple server), `std.net`,
`std.time`, `std.math`, `std.random`, `std.sort`, `std.iter`, `std.regex`,
`std.encoding`, `std.hash`, `std.log`, `std.term`, and `std.testing`. Testing is
a first-class convention rather than a framework: `math_test.thera` sits next to
`math.thera`, `@test` functions are discovered by `thera test`, and a test file
gets white-box access to its target's private symbols.

**Fibers, so there is no async/sync split.** Concurrency is cooperative and
single-threaded: `spawn`, `join`, `yield`, and channels. Blocking operations
park the fiber and the scheduler runs another; I/O looks synchronous at the
language level, and there is exactly one version of every API.

```thera
let handles: List<fiber.Fiber<Int>> = [];
for x in xs {
    handles.push(fiber.spawn(() => square(x)));
}
let mut total = 0;
for h in handles {
    total += h.join();
}
```

No function is colored `async`, nothing needs `await`, and because only one
fiber runs at a time, there are no data races, mutexes, or locks to reason
about.

## Tooling

`thera` is a single binary — `run`, `check`, `emit`, `test`, `fmt`, `lint`
(`--fix` applies the rewrites), and `lsp`. Every diagnostic — type errors, build
failures, test assertions — is one line of `path:line:column: message`, so an
agent parses compiler output and test output with the same rule. The language
server serves hover, definition, references, rename, and completion from the
same analysis engine `check` uses.

## Status

The language is under active development: real CLI programs compile and run end
to end, the front-end self-hosts and reproduces itself byte-for-byte, and the
language core (closures, enums, structs, generics, interfaces with dynamic
dispatch, fibers and channels) is implemented.

Items on the roadmap include the JIT tier, TLS for the HTTP client, and
continued stdlib breadth.

The design docs:

- [docs/overview.md](docs/overview.md) — the full design rationale
- [docs/language.md](docs/language.md) — the language reference
- [docs/architecture.md](docs/architecture.md) — the runtime
- [docs/roadmap.md](docs/roadmap.md) — where things stand
- [docs/toc.md](docs/toc.md) — all the design docs
