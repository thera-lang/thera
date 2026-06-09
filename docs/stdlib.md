# Standard library design

**What this is:** the design for Hawk's "batteries included" standard library —
the principles that make it self-consistent, the tiers that decide what ships in
core vs. the ecosystem, and a module-by-module catalog with representative APIs.
It is the artifact that guides future stdlib work; it describes the **target**,
not only what exists today. The _why_ behind a comprehensive stdlib is in
[guidelines.md](guidelines.md); the language surface in
[language.md](language.md); interfaces/dispatch in
[interfaces.md](interfaces.md).

## Why a deep stdlib

When common tasks — files, processes, JSON, HTTP, dates — are covered by the
standard library, an agent writes against **one highly-reinforced API** instead
of guessing among competing third-party packages. Every module here exists to
remove a decision: there should be one obvious way to read a file, parse JSON,
spawn a process, or make an HTTP request, and it should be in `std`.

The bar: **solid, self-consistent, and reasonably complete** for CLI tooling and
agent automation (the target domain, see [guidelines.md](guidelines.md) §0). The
long tail — databases, exotic formats, GUI — belongs to the package ecosystem,
but every _common_ task must have an answer in core.

## Cross-cutting principles

These hold across every module. They are what make the library predictable
enough to reduce hallucination.

1. **Tiering.** Three levels (detailed below): the **prelude** (always in
   scope), **core std** (`import std.x`), and the **ecosystem** (packages). A
   symbol's tier is part of its contract — agents should never wonder whether
   `println` needs an import (no) or whether `http` does (yes).

2. **Naming is uniform and boring.** Modules are lowercase nouns (`fs`, `http`,
   `time`). Functions and methods are `snake_case`; types are `PascalCase`;
   constants are `UPPER_SNAKE`. A module is imported and used qualified:
   `import std.fs; fs.read_text(p)`. Predicates read `is_*` / `has_*`; fallible
   constructors are `*.compile` / `*.parse` returning `Result`; checked lookups
   return `Option`. Convenience whole-value readers are `read_text` /
   `read_bytes`; their streaming counterparts are `open`.

3. **I/O is `Reader`/`Writer` underneath, whole-value on top.** Streaming is one
   protocol — the `Reader` / `Writer` / `Closer` interfaces in `std.io` (§ Core
   types). Files, process pipes, sockets, and in-memory buffers all implement
   them, so `io.copy`, `io.read_all`, and line iteration work against any
   source. Whole-value conveniences (`fs.read_text`, `fs.write_text`) are thin
   wrappers for the common case. **There is exactly one streaming abstraction.**

4. **Errors are values, per-domain enums, one common interface.** Every fallible
   function returns `Result<T, E>`. Each domain defines a small error enum
   (`FsError`, `JsonError`, `HttpError`) so callers can `match` on the cause;
   all of them implement the common `Error` interface (`§ Error`), which is the
   uniform currency at boundaries and the conventional `E` in library-agnostic
   code. No exceptions, no hidden control flow (see
   [guidelines.md](guidelines.md) §3).

5. **Concurrency is invisible.** Hawk uses single-threaded cooperative fibers
   ([language.md](language.md) §Concurrency): I/O parks the calling fiber and
   resumes another, so **stdlib I/O looks synchronous and blocking but never
   blocks the thread.** No `async`/`await`, no `Future<T>` in any signature, no
   function coloring. `std.fiber` exposes `spawn`/`join` for explicit
   concurrency; everything else just looks sequential.

6. **Immutability by default; builders for accumulation.** APIs return new
   values rather than mutating in place. Where accumulation is unavoidable
   (building a string, a byte buffer), a `*Builder` type makes the mutable scope
   explicit and local (`StringBuilder`, `BytesBuilder`).

7. **No hidden global state; effects are explicit.** Sources of nondeterminism
   are values you hold, not ambient globals: `random.Rng` is seedable and
   passed; the wall clock (`time.now`) and monotonic clock are explicit calls.
   This keeps the functional core pure and quarantines effects to the shell
   ([guidelines.md](guidelines.md) §4).

8. **Text is UTF-8; bytes are `Bytes`.** `String` is validated UTF-8; raw binary
   is the `Bytes` type (§ Core types). Conversions are explicit
   (`String.from_utf8(bytes) -> Result<String, Error>`, `s.to_bytes()`). String
   offsets follow the existing convention: code-point counts for `len`, UTF-8
   byte offsets where byte positions are needed (matching `std.regex`).

## The tiers

| Tier          | Import          | Contents                                                                                                                       |
| ------------- | --------------- | ------------------------------------------------------------------------------------------------------------------------------ |
| **Prelude**   | none (auto)     | primitives, `List`/`Map`/`Set`, `Option`/`Result`, `Error` + `Eq`/`Display`/`Debug`/`Ord`, `println`/`print`, `String` methods |
| **Core std**  | `import std.x`  | `io fs path env process time fiber math random json encoding hash http log cli term regex testing`                             |
| **Ecosystem** | package manager | databases, YAML/TOML/CSV, HTTP server, raw sockets, compression, full crypto/TLS, UUID, templating, …                          |

The line between core and ecosystem: core covers what a typical CLI tool or
agent script needs **in almost every project**. The ecosystem covers the
specialized and the long tail — but for every common task, core either provides
it or names the ecosystem answer (e.g. JSON is core; YAML/TOML are ecosystem but
called out under `std.json`).

## Core types

The shared vocabulary the modules are built from. These live in `std.core`
(prelude) or `std.io`.

### `Bytes` — immutable byte buffer _(new, prelude or std.io)_

```
pub type Bytes = { /* opaque, runtime-backed */ }

impl Bytes {
    pub fn len(self) -> Int;
    pub fn get(self, _ i: Int) -> Option<Int>;        // 0..255
    pub fn slice(self, _ start: Int, _ end: Int) -> Bytes;
    pub fn to_string(self) -> Result<String, Error>;  // validates UTF-8
    pub fn concat(self, _ other: Bytes) -> Bytes;
}

// Accumulate bytes, then freeze:
pub type BytesBuilder = { /* mutable */ }
impl BytesBuilder {
    pub fn new() -> BytesBuilder;
    pub fn push(self, _ byte: Int) -> Void;
    pub fn append(self, _ data: Bytes) -> Void;
    pub fn append_str(self, _ s: String) -> Void;
    pub fn finish(self) -> Bytes;
}
```

### `Reader` / `Writer` / `Closer` — the streaming protocol _(new, std.io)_

```
// Read up to `max` bytes. An empty `Bytes` result means end-of-stream (EOF).
pub interface Reader {
    fn read(self, max: Int) -> Result<Bytes, Error>;
}

// Write all of `data`; returns the number of bytes written.
pub interface Writer {
    fn write(self, _ data: Bytes) -> Result<Int, Error>;
}

pub interface Closer {
    fn close(self) -> Result<Void, Error>;
}
```

Chunk-returning `read` (rather than read-into-a-mutable-buffer) keeps the
protocol immutability-friendly. A blocking read is fine: it parks the fiber.

### `Error` — the common error interface _(migration from a struct)_

```
pub interface Error {
    fn message(self) -> String;     // human-readable summary
}
// Every Error is Display via its message (the interpolation/println form).
```

A general-purpose error for the simple case, and the conventional `throw`
target:

```
pub type Message = { text: String }       // implements Error + Display
// throw 'oops'  desugars to  throw Message { text: 'oops' }
```

> **Migration.** Today `std.core/error.hawk` defines `Error` as a _struct_
> `{ message: String }`, and `throw '...'` / the implicit `Ok`-wrap build it.
> This design makes `Error` an _interface_ and renames the concrete struct
> (`Message`). It is a real change touching `throw`, `?`, and `std.testing`, and
> — because returning an interface-typed `E` needs dynamic dispatch — it is
> gated on the **generics arc** (§ Sequencing). Until then, modules return their
> **concrete** domain enum (e.g. `Result<String, FsError>`).

### `Duration` / `Instant` / `DateTime` — see `std.time`.

## Module catalog

Each entry: **purpose**, **key types**, **representative API** (illustrative,
not exhaustive), and **status** (`exists` / `partial` / `new`).

### `std.io` — streaming I/O foundation _(new)_

Purpose: the `Reader`/`Writer`/`Closer` interfaces, the standard streams, and
the generic combinators every other I/O module builds on.

```
// Standard streams (stdin: Reader, stdout/stderr: Writer).
pub fn stdin() -> Reader;
pub fn stdout() -> Writer;
pub fn stderr() -> Writer;

// Combinators over any Reader/Writer.
pub fn read_all(_ src: Reader) -> Result<Bytes, Error>;
pub fn copy(to dst: Writer, from src: Reader) -> Result<Int, Error>;

// Text-oriented helpers.
pub fn lines(_ src: Reader) -> Iterator<String>;   // lazy; see Sequencing
pub type BufReader = { /* buffered, line-aware */ }
pub type StringWriter = { /* in-memory Writer -> String */ }
```

Notes: the generic combinators take **interface-typed** parameters → gated on
the generics arc. `Iterator<T>` (lazy sequence) is part of this design; see
Sequencing.

### `std.fs` — filesystem _(partial → expand)_

Purpose: files and directories. Whole-value reads for the common case; `open`
for streaming.

```
// Whole-value (conveniences).
pub fn read_text(_ path: String) -> Result<String, FsError>;     // exists
pub fn write_text(_ path: String, _ text: String) -> Result<Void, FsError>; // exists
pub fn read_bytes(_ path: String) -> Result<Bytes, FsError>;
pub fn write_bytes(_ path: String, _ data: Bytes) -> Result<Void, FsError>;

// Streaming.
pub fn open(_ path: String) -> Result<File, FsError>;            // File: Reader+Writer+Seek+Closer
pub fn create(_ path: String) -> Result<File, FsError>;

// Metadata & directories.
pub fn exists(_ path: String) -> Bool;                          // exists
pub fn metadata(_ path: String) -> Result<Metadata, FsError>;   // size, kind, modified
pub fn list_dir(_ path: String) -> Result<List<String>, FsError>; // rename of read_dir
pub fn walk(_ path: String) -> Iterator<String>;                // recursive
pub fn create_dir(_ path: String) -> Result<Void, FsError>;
pub fn create_dir_all(_ path: String) -> Result<Void, FsError>;
pub fn remove(_ path: String) -> Result<Void, FsError>;
pub fn rename(from src: String, to dst: String) -> Result<Void, FsError>;
pub fn copy(from src: String, to dst: String) -> Result<Void, FsError>;
pub fn temp_dir() -> String;
pub fn temp_file(prefix: String = 'tmp') -> Result<File, FsError>;

pub enum FsError {
    NotFound(String), PermissionDenied(String), AlreadyExists(String),
    NotADirectory(String), IsADirectory(String), Other(String),
}  // implements Error
```

Notes: `read_dir` → `list_dir` (the existing TODO). Per-domain `FsError`
replaces the current `Result<_, Error>`.

### `std.path` — pure path manipulation _(implemented, pure Hawk)_

Purpose: string-only path operations, no filesystem access. **Implemented
entirely in Hawk** on top of the `String`/`List` methods (no runtime natives) —
the worked example of stdlib-in-Hawk. Provides
`join`/`dirname`/`basename`/`stem`/`extension`/`is_absolute` plus `components`
and `with_extension`.

```
pub fn join(_ base: String, _ part: String) -> String;  // absolute `part` wins
pub fn components(_ path: String) -> List<String>;
pub fn with_extension(_ path: String, _ ext: String) -> String;
// + dirname / basename / stem / extension / is_absolute
```

Deferred: `normalize` (collapse `./` `../`), `relative`, and a variadic `join`.
A `SEPARATOR` constant waits on top-level `const` support in codegen (§
Sequencing); `'/'` is inlined for now.

### `std.env` — environment & process info _(new)_

Purpose: environment variables, args, working directory, exit. (Spawning is
`std.process`.)

```
pub fn get(_ name: String) -> Option<String>;
pub fn set(_ name: String, _ value: String) -> Void;
pub fn vars() -> Map<String, String>;
pub fn args() -> List<String>;          // program arguments (also passed to main)
pub fn current_dir() -> Result<String, Error>;
pub fn set_current_dir(_ path: String) -> Result<Void, Error>;
pub fn exit(_ code: Int) -> Never;      // see language.md if a Never type lands
pub const OS: String;                   // 'macos' | 'linux' | 'windows'
```

### `std.process` — subprocess spawning _(partial → reconcile with std.io)_

Purpose: run and stream child processes. Already has
`run`/`start`/`ProcessResult`/ `Process`. Reconcile the streaming TODOs: pipes
become `Reader`/`Writer`.

```
pub fn run(_ command: String, args: List<String> = [],
           working_dir: Option<String>, env: Option<Map<String, String>>)
    -> Result<ProcessResult, ProcessError>;   // captured stdout/stderr/exit_code (exists)

pub fn start(...) -> Result<Process, ProcessError>;  // exists

impl Process {
    pub fn stdin(self) -> Writer;     // was stdin_write
    pub fn stdout(self) -> Reader;    // was stdout_read (resolves the TODO)
    pub fn stderr(self) -> Reader;
    pub fn wait(self) -> Result<Int, ProcessError>;  // exists
    pub fn kill(self) -> Result<Void, ProcessError>; // exists
}
```

### `std.time` — clocks, durations, dates _(new)_

Purpose: wall-clock and monotonic time, durations, and formatting/parsing.

```
pub type Instant = { /* monotonic, for measuring elapsed */ }
pub type DateTime = { /* wall clock, UTC-based */ }
pub type Duration = { /* signed span */ }

pub fn now() -> DateTime;            // wall clock
pub fn monotonic() -> Instant;       // for elapsed measurement
pub fn sleep(_ d: Duration) -> Void; // parks the fiber

impl Duration {
    pub fn seconds(_ n: Int) -> Duration;   // also millis/minutes/hours
    pub fn as_millis(self) -> Int;
}
impl Instant { pub fn elapsed(self) -> Duration; }
impl DateTime {
    pub fn format_rfc3339(self) -> String;
    pub fn parse_rfc3339(_ s: String) -> Result<DateTime, Error>;
    pub fn unix_seconds(self) -> Int;
}
```

Notes: time-zone database and locale-aware formatting are ecosystem; core ships
UTC + RFC 3339 + Unix time, which covers logging/timestamps/CLI needs.

### `std.fiber` — cooperative concurrency _(new; referenced in language.md)_

Purpose: explicit concurrency on the single thread.

```
pub type Fiber<T> = { /* handle */ }
pub fn spawn<T>(_ work: () -> T) -> Fiber<T>;

impl Fiber<T> { pub fn join(self) -> T; }   // the only way to get the result out

// Channels for fiber-to-fiber handoff.
pub type Channel<T> = { }
pub fn channel<T>(capacity: Int = 0) -> Channel<T>;
impl Channel<T> {
    pub fn send(self, _ value: T) -> Void;     // parks if full
    pub fn receive(self) -> Option<T>;          // None when closed & drained
    pub fn close(self) -> Void;
}
```

Notes: no mutexes/atomics — single-threaded means no data races
([language.md](language.md) §Concurrency). `select` over channels is a candidate
addition.

### `std.math` — numeric functions _(new)_

```
pub const PI: Double; pub const E: Double;
pub fn abs(_ x: Double) -> Double;        // + Int overloads as the language allows
pub fn min(_ a: Double, _ b: Double) -> Double;
pub fn max(_ a: Double, _ b: Double) -> Double;
pub fn clamp(_ x: Double, low: Double, high: Double) -> Double;
pub fn floor(_ x: Double) -> Double;  pub fn ceil(_ x: Double) -> Double;
pub fn round(_ x: Double) -> Double;  pub fn sqrt(_ x: Double) -> Double;
pub fn pow(_ base: Double, _ exp: Double) -> Double;
// sin/cos/tan/log/exp; conversions live as Int/Double methods (e.g. n.to_double()).
```

Notes: numeric parsing (`String → Int/Double`) lives as `String` methods in the
prelude (`s.to_int() -> Option<Int>`), not here.

### `std.random` — randomness _(new)_

```
pub type Rng = { /* seedable, explicit state */ }
pub fn seeded(_ seed: Int) -> Rng;
pub fn from_entropy() -> Rng;
impl Rng {
    pub fn int(self, low: Int, high: Int) -> Int;   // [low, high)
    pub fn double(self) -> Double;                   // [0, 1)
    pub fn bool(self) -> Bool;
    pub fn choice<T>(self, _ items: List<T>) -> Option<T>;
    pub fn shuffle<T>(self, _ items: List<T>) -> List<T>;
}
```

Notes: an `Rng` value, not a global, per principle 7 (no hidden state).

### `std.json` — JSON _(new; the flagship data format)_

Purpose: parse and serialize JSON. A structural `Json` value now; typed
encode/decode once reflection/derive exists.

```
pub enum Json {
    Null, Bool(Bool), Number(Double), Str(String),
    Array(List<Json>), Object(Map<String, Json>),
}
pub fn parse(_ text: String) -> Result<Json, JsonError>;
pub fn stringify(_ value: Json, pretty: Bool = false) -> String;

impl Json {
    pub fn get(self, _ key: String) -> Option<Json>;   // Object lookup
    pub fn at(self, _ index: Int) -> Option<Json>;      // Array index
    pub fn as_string(self) -> Option<String>;           // + as_int/as_double/as_bool
}
pub enum JsonError { Syntax(String), Type(String) }     // implements Error
```

Notes: typed `decode<T>` / `encode<T>` (struct ↔ JSON) needs compile-time
reflection or a `derive`-like mechanism — **deferred** (§ Sequencing); the
structural `Json` enum is the near-term answer. **YAML/TOML/CSV are ecosystem**;
this is where an agent looks first and finds the pointer.

### `std.encoding` — base64 / hex / url _(new)_

```
// std.encoding.base64, .hex, .url — or flat functions on the barrel.
pub fn base64_encode(_ data: Bytes) -> String;
pub fn base64_decode(_ s: String) -> Result<Bytes, Error>;
pub fn hex_encode(_ data: Bytes) -> String;
pub fn hex_decode(_ s: String) -> Result<Bytes, Error>;
pub fn url_encode(_ s: String) -> String;
pub fn url_decode(_ s: String) -> Result<String, Error>;
```

### `std.hash` — non-cryptographic + common digests _(new)_

```
pub fn sha256(_ data: Bytes) -> Bytes;
pub fn sha1(_ data: Bytes) -> Bytes;
pub fn md5(_ data: Bytes) -> Bytes;
pub fn crc32(_ data: Bytes) -> Int;
```

Notes: enough for checksums and content addressing (common agent tasks). Full
crypto (signing, TLS primitives, AEAD) is ecosystem.

### `std.http` — HTTP client _(new)_

Purpose: make HTTP requests. **Client only** in core; a server and raw sockets
are ecosystem.

```
pub type Request = { method: String, url: String,
                     headers: Map<String, String>, body: Bytes }
pub type Response = { status: Int, headers: Map<String, String>, body: Bytes }

pub fn get(_ url: String, headers: Map<String, String> = {}) -> Result<Response, HttpError>;
pub fn post(_ url: String, body: Bytes, headers: Map<String, String> = {}) -> Result<Response, HttpError>;
pub fn send(_ request: Request) -> Result<Response, HttpError>;

impl Response {
    pub fn text(self) -> Result<String, Error>;
    pub fn json(self) -> Result<Json, Error>;
    pub fn is_ok(self) -> Bool;          // 2xx
}
pub enum HttpError { Connect(String), Timeout, Status(Int), Body(String) } // implements Error
```

Notes: TLS is provided by a runtime native (not reimplemented in Hawk).
Streaming bodies use `std.io.Reader`.

### `std.log` — leveled logging _(new)_

```
pub enum Level { Debug, Info, Warn, Error }
pub fn info(_ message: String) -> Void;   // + debug/warn/error
pub fn set_level(_ level: Level) -> Void;
pub fn set_output(_ w: Writer) -> Void;    // default: stderr
```

Notes: simple, structured-friendly, writes to stderr by default (stdout stays
clean for program output — a CLI convention).

### `std.cli` — argument parsing _(partial → expand; flagship for the domain)_

Purpose: declarative CLI parsing with subcommands, typed options, and generated
`--help`. Supersedes the thin `std.cli/args` (`Args`) with a richer builder
while keeping `Args` for raw access.

```
pub type Command = { /* name, options, subcommands */ }
impl Command {
    pub fn new(_ name: String) -> Command;
    pub fn flag(self, _ name: String, help: String = '') -> Command;       // Bool
    pub fn option(self, _ name: String, help: String = '') -> Command;     // String
    pub fn positional(self, _ name: String, help: String = '') -> Command;
    pub fn subcommand(self, _ cmd: Command) -> Command;
    pub fn parse(self, _ args: List<String>) -> Result<Matches, CliError>;
}
pub type Matches = { /* typed accessors */ }
impl Matches {
    pub fn flag(self, _ name: String) -> Bool;
    pub fn option(self, _ name: String) -> Option<String>;
    pub fn positional(self, _ index: Int) -> Option<String>;
}
```

Notes: rich, declarative arg parsing is one of the highest-value pieces for the
CLI domain — it both removes boilerplate and gives `--help` for free. The
existing `Args` (raw positional/flag access) stays as the low-level escape
hatch.

### `std.term` — terminal _(new)_

```
pub fn is_tty() -> Bool;
pub fn size() -> Option<(Int, Int)>;      // (cols, rows); tuple syntax TBD in language
pub fn style(_ text: String, color: Color, bold: Bool = false) -> String;  // ANSI
pub enum Color { Red, Green, Yellow, Blue, Default /* … */ }
```

Notes: color helpers should no-op when `!is_tty()` so piped output stays clean.

### `std.regex` — regular expressions _(exists)_

RE2-backed; `Regex.compile` / `is_match` / `find` / `captures` / `replace`.
Already designed; keep. (Should be made `pub` and its natives made
module-private once visibility enforcement lands.)

### `std.testing` — assertions _(exists)_

`assert` / `assert_eq` / `assert_ne` / `assert_ok` / `assert_err`. Keep. Tightly
coupled to `Eq`/`Debug` (so `assert_eq`'s `<T: Eq + Debug>` is gated on the
generics arc and `Debug` auto-derivation — § Sequencing).

## What is intentionally _not_ in core

So the boundary is explicit (and so an agent knows where to look):

- **Other config formats** — YAML, TOML, CSV → ecosystem (JSON is core).
- **HTTP server, raw TCP/UDP sockets** → ecosystem (HTTP client is core).
- **Databases / SQLite** → ecosystem.
- **Full cryptography / TLS primitives, signing** → ecosystem (digests +
  randomness are core; TLS for `http` is a runtime native).
- **Compression (gzip/zip/tar)** → ecosystem.
- **Time zones / locale formatting** → ecosystem (UTC + RFC 3339 are core).
- **UUID, templating, terminal UI** → ecosystem.

## Sequencing & dependencies

This design leans on language features not all of which exist yet. The
dependency graph, so future work lands in the right order:

1. **Generics arc (biggest unblocker).** Interface-typed values + dynamic
   dispatch ([interfaces.md](interfaces.md), "Deferred") are a prerequisite for
   the library's two core abstractions:
   - `io.copy(dst: Writer, src: Reader)` and any function taking a `Reader`/
     `Writer` parameter — these are interface-typed.
   - The common `Error` **interface** as a return type (`Result<T, Error>` where
     `Error` is the interface). Until then, modules return their **concrete**
     domain enum (`FsError`, `HttpError`, …), which works with today's
     concrete-only dispatch.
   - Generic bound enforcement (`<T: Display>`, `<T: Eq + Debug>`) used by
     `std.testing` and generic combinators.

2. **`Bytes` core type + `Reader`/`Writer` interfaces.** The foundation of
   `std.io`; everything binary (fs/process/http/hash/encoding) needs `Bytes`.
   `Bytes` itself is runtime-backed and can land before the generics arc; the
   _generic_ combinators over `Reader`/`Writer` wait for #1.

3. **Lazy `Iterator<T>`.** `fs.walk`, `io.lines`, and the `std.regex`
   `.to_list()` calls assume a lazy sequence type. Define `Iterator<T>` (likely
   an interface with `next() -> Option<T>`) — also gated on interface-typed
   values (#1) for the generic forms.

4. **`Error` interface migration.** Convert `std.core/error.hawk`'s `Error`
   struct to the `Error` interface + a `Message` struct, and rewire `throw` /
   `?` / implicit-`Ok` and `std.testing`. Gated on #1 (interface-typed `E`).

5. **Reflection / `derive` (later).** Typed `json.decode<T>` / `encode<T>`
   (struct ↔ JSON) and `Debug` auto-derivation want compile-time reflection or a
   `derive` mechanism. Until then: the structural `Json` enum and explicit
   `display`/`debug`.

6. **Runtime natives.** New runtime support is needed for `std.time` (clocks),
   `std.random` (entropy), `std.http` (sockets + TLS), `std.hash`, and
   `std.fiber` (the scheduler). These are independent of the front-end arcs and
   can proceed in parallel.

7. **Visibility enforcement** ([visibility.md](visibility.md)). Several modules
   (`std.regex`, `std.process`) have native bindings that should be
   module-private; today the language can't enforce it. Tighten when visibility
   lands.

8. **Top-level `const` in codegen.** `const`/`pub const` parse and check, but the
   code generator does not emit them — referencing a module-level constant fails
   ("not a local variable"). This blocks `std.char`'s constants, `std.math`'s
   `PI`/`E`, and `std.path`'s `SEPARATOR`. A self-contained codegen fix
   (materialize constants, or inline their literal initializers at use sites).

## Status summary

| Module       | Status  | Notes                                               |
| ------------ | ------- | --------------------------------------------------- |
| prelude/core | exists  | add `Set` file, `Ord`, `String.to_int`/`to_double`  |
| std.io       | new     | foundation; gated on `Bytes` + generics arc         |
| std.fs       | partial | expand; `read_dir`→`list_dir`; `FsError`            |
| std.path     | done    | pure Hawk; `components`/`with_extension` added; normalize/relative deferred |
| std.env      | new     |                                                     |
| std.process  | partial | reconcile pipes → `Reader`/`Writer`; `ProcessError` |
| std.time     | new     | runtime native                                      |
| std.fiber    | new     | runtime scheduler                                   |
| std.math     | new     |                                                     |
| std.random   | new     | runtime entropy                                     |
| std.json     | new     | structural now; typed decode later                  |
| std.encoding | new     |                                                     |
| std.hash     | new     | runtime native                                      |
| std.http     | new     | client only; runtime sockets + TLS                  |
| std.log      | new     |                                                     |
| std.cli      | partial | expand `Args` → declarative `Command`               |
| std.term     | new     |                                                     |
| std.regex    | exists  | make `pub`; privatize natives later                 |
| std.testing  | exists  | gated on generics arc for `<T: Eq + Debug>`         |
