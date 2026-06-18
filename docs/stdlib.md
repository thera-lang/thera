# Standard library design

**What this is:** the design for Hawk's "batteries included" standard library —
the principles that make it self-consistent, the tiers that decide what ships in
core vs. the ecosystem, and a module-by-module catalog with representative APIs.
It is the artifact that guides future stdlib work; it describes the **target**,
not only what exists today. The _why_ behind a comprehensive stdlib is in
[overview.md](overview.md); the language surface (including interfaces and
dispatch) in [language.md](language.md).

## Why a deep stdlib

When common tasks — files, processes, JSON, HTTP, dates — are covered by the
standard library, an agent writes against **one highly-reinforced API** instead
of guessing among competing third-party packages. Every module here exists to
remove a decision: there should be one obvious way to read a file, parse JSON,
spawn a process, or make an HTTP request, and it should be in `std`.

The bar: **solid, self-consistent, and reasonably complete** for CLI tooling and
agent automation (the target domain, see [overview.md](overview.md)). The
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

   **Layout:** every library lives in its own named subdirectory —
   `sdk/std/<name>/<name>.hawk` (even single-file libs, ready to grow into a
   barrel) — with Hawk tests beside it as `<name>_test.hawk`.

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
   [overview.md](overview.md)).

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

7. **No hidden global state; effects are explicit, and ambient effects have a
   capability seam.** Sources of nondeterminism are never swappable globals.
   Each ambient capability is exposed in two layers: an **ambient free
   function** that always performs the real effect with no override hook
   (`time.now_millis`, `fs.read_text` — for the imperative shell) and an
   **opt-in capability interface** you hold and pass (`time.Clock`,
   `fs.FileSystem` — for testable logic), where the free function _is_ the
   system implementation. Some capabilities make the value-you-hold form the
   default instead (`random.Rng` has no ambient form, since reproducibility is
   the common case). This keeps the functional core pure, quarantines effects to
   the shell ([overview.md](overview.md)), and makes the test seam
   explicit rather than a global override. Full design:
   [testability.md](testability.md).

8. **Text is UTF-8; bytes are `Bytes`.** `String` is validated UTF-8; raw binary
   is the `Bytes` type (§ Core types). Conversions are explicit: `s.chars()`
   returns code points (`List<Int>`) and `s.bytes()` returns the UTF-8 encoding
   as `Bytes` (`.to_list()` for the raw 0..=255 byte values);
   `Bytes.to_string()` validates UTF-8. String offsets follow the existing
   convention: code-point counts for `len`, UTF-8 byte offsets where byte
   positions are needed.

## The tiers

| Tier          | Import          | Contents                                                                                                                       |
| ------------- | --------------- | ------------------------------------------------------------------------------------------------------------------------------ |
| **Prelude**   | none (auto)     | primitives, `List`/`Map`/`Set`, `Option`/`Result`, `Error` + `Eq`/`Display`/`Debug`/`Ord`, `println`/`print`/`eprintln`/`eprint`, `String` methods |
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

### `Bytes` — immutable byte buffer _(implemented, prelude)_

Runtime-backed opaque types in the prelude (`std.core/bytes.hawk`);
`String.bytes()` returns `Bytes` (use `.to_list()` for the raw byte values).

```
pub type Bytes = { /* opaque, runtime-backed */ }

impl Bytes {
    pub fn len(self) -> Int;
    pub fn get(self, _ i: Int) -> Option<Int>;        // 0..=255
    pub fn slice(self, _ start: Int, _ end: Int) -> Bytes;   // clamps to range
    pub fn concat(self, _ other: Bytes) -> Bytes;
    pub fn to_string(self) -> Result<String, Error>;  // validates UTF-8
    pub fn to_list(self) -> List<Int>;
    pub fn empty() -> Bytes;                           // static
    pub fn from_list(_ values: List<Int>) -> Result<Bytes, Error>;  // static; 0..=255
}

// Accumulate bytes, then freeze (the binary-writer vocabulary; write_u8 masks
// to the low 8 bits). The typed write_u16_le/be… family is a planned follow-up.
pub type BytesBuilder = { /* mutable */ }
impl BytesBuilder {
    pub fn new() -> BytesBuilder;
    pub fn write_u8(self, _ byte: Int) -> Void;
    pub fn write_bytes(self, _ data: Bytes) -> Void;
    pub fn write_str(self, _ s: String) -> Void;
    pub fn len(self) -> Int;
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

### `Error` — the common error interface _(implemented)_

```
pub interface Error {
    fn message(self) -> String;     // human-readable summary
}
```

A general-purpose error for the simple case is built with a **constructor**, not
a named type (the Go `errors.New` / Rust `anyhow!` model):

```
pub fn error(_ message: String) -> Error;   // the simple-case error / `throw` target
// return Result.Err(error('file not found'));   throw error('...');
// (a `throw 'oops'` shorthand that desugars to `error` is still planned)
```

The concrete carrier is a private implementation detail you never name —
deliberately, so the always-in-scope prelude doesn't claim a common noun like
`Message` (which would collide with user types; the prelude is the one surface
even per-namespace resolution can't disambiguate). `Error` is an interface
(`std.core/error.hawk`); domain modules define their own error enums and
`impl Error` for them, so a value `match`-able on its cause still passes where
`Result<_, Error>` is expected (`std.cli`'s `CliError` is the first example, and
`?` propagates it into an `Error`-returning caller).

> **`Error` extends `Display + Debug` (interface inheritance).** A value typed
> as the `Error` _interface_ is itself `Display` and `Debug`: interpolate it
> directly (`'${e}'`), and `assert_ok`/`assert_err` accept a `Result<_, Error>`
> (their `E: Debug` bound is satisfied). Each error type provides an explicit
> `impl Display` (`Debug` is the structural auto-derive). One cosmetic limit
> remains: an uncaught domain-enum error that bubbles all the way to `main`
> renders structurally (the runtime's top-level fallback has no `Display`
> dispatch yet) — handle errors in-program and print `e.message()` for clean
> output.

### `Duration` / `Instant` / `DateTime` — see `std.time`.

## Module catalog

Each entry: **purpose**, **key types**, **representative API** (illustrative,
not exhaustive), and **status** (`exists` / `partial` / `new`).

### `std.io` — streaming I/O foundation _(v1 implemented, pure Hawk)_

Purpose: the `Reader`/`Writer`/`Closer` interfaces, the standard streams, and
the generic combinators every other I/O module builds on. Everything streams as
`Bytes`. Implemented in pure Hawk over the interface-dispatch arc (the
combinators take interface-typed parameters); three small stream natives back
stdin/stdout/stderr.

```
pub interface Reader { fn read(self, max: Int) -> Result<Bytes, Error>; }   // empty = EOF
pub interface Writer { fn write(self, _ data: Bytes) -> Result<Int, Error>; }
pub interface Closer { fn close(self) -> Result<Void, Error>; }
pub enum IoError { Eof, Other(String) }                       // implements Error

// Standard streams (stdin: Reader, stdout/stderr: Writer).
pub fn stdin() -> Reader;  pub fn stdout() -> Writer;  pub fn stderr() -> Writer;

// Combinators over any Reader/Writer.
pub fn read_all(_ src: Reader) -> Result<Bytes, Error>;
pub fn copy(to dst: Writer, from src: Reader) -> Result<Int, Error>;

// In-memory Writer that captures output (and the test double for any Writer).
pub type StringWriter = { /* wraps a BytesBuilder */ }
impl StringWriter { fn new(); fn into_string() -> Result<String, Error>; fn into_bytes() -> Bytes; }
```

Deferred follow-ups: `io.lines(src) -> Iterator<String>` and `BufReader` (the
lazy `Iterator<T>` type now exists in `std.iter`, but these also want the
`map`/`filter` adapters, § Sequencing); streaming files (`fs.open` → a
`File: Reader + Writer + Seek + Closer`); the typed binary `BytesReader`
(`read_u8`/`read_u16_le`/…) pairing with `BytesBuilder`.

### `std.fs` — filesystem _(v1 implemented; streaming deferred)_

Purpose: files and directories. Whole-value reads for the common case; streaming
`open` is a planned v2. Paths are plain `String`s (compose with `std.path`);
directory entries are basenames (join with `path.join(dir, name)` to descend).
Every fallible call returns a per-domain `FsError` you can `match` on.

```
// Whole-value (conveniences) — implemented.
pub fn read_text(_ path: String) -> Result<String, FsError>;
pub fn write_text(_ path: String, _ text: String) -> Result<Void, FsError>;
pub fn read_bytes(_ path: String) -> Result<Bytes, FsError>;
pub fn write_bytes(_ path: String, _ data: Bytes) -> Result<Void, FsError>;

// Existence, metadata & directories — implemented.
pub fn exists(_ path: String) -> Bool;
pub fn metadata(_ path: String) -> Result<Metadata, FsError>;   // follows symlinks
pub fn list_dir(_ path: String) -> Result<List<String>, FsError>; // entry basenames
pub fn create_dir(_ path: String) -> Result<Void, FsError>;       // parent must exist
pub fn create_dir_all(_ path: String) -> Result<Void, FsError>;   // mkdir -p
pub fn remove(_ path: String) -> Result<Void, FsError>;           // file or empty dir
pub fn remove_dir_all(_ path: String) -> Result<Void, FsError>;   // recursive
pub fn rename(from src: String, to dst: String) -> Result<Void, FsError>;
pub fn copy(from src: String, to dst: String) -> Result<Void, FsError>;   // file copy
pub fn temp_dir() -> String;

pub enum FileKind { File, Dir, Symlink, Other }
pub type Metadata = { size: Int, kind: FileKind, modified_millis: Int }  // Unix mtime ms

pub enum FsError {                          // implements Error + Display
    NotFound(String), PermissionDenied(String), AlreadyExists(String),
    NotADirectory(String), IsADirectory(String), Other(String),
}

// Streaming & recursion — deferred to v2.
pub fn open(_ path: String) -> Result<File, FsError>;   // File: Reader+Writer+Seek+Closer
pub fn create(_ path: String) -> Result<File, FsError>;
pub fn walk(_ path: String) -> Iterator<String>;        // recursive
pub fn temp_file(prefix: String = 'tmp') -> Result<File, FsError>;
```

Notes: `FsError` is classified from the OS error kind — the natives tag each
error with its kind and a private helper maps it to the variant, so callers get
`NotFound`/`PermissionDenied`/etc., not just `Other`. `metadata` follows
symlinks (so `kind` reports the target; `FileKind.Symlink` awaits a future
`symlink_metadata`). `modified_millis` is Unix milliseconds, `0` when the
platform can't report it (it becomes a `DateTime` once `std.time` grows one).
The v2 streaming layer needs a `Seek` interface added to `std.io` plus
file-handle natives; `walk` is then a thin `Iterator` over `list_dir`.

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

Slash-based (POSIX-style, like Go's `path`): `'/'` is always the separator. OS
-aware handling — Windows `\`, drive letters, and a platform separator (which
can't be a compile-time `const`; it needs native backing) — is a deliberate
future task. Also deferred: `normalize` (collapse `./` `../`), `relative`, and a
variadic `join`.

### `std.env` — environment & process info _(implemented)_

Purpose: environment variables, args, working directory, exit. (Spawning is
`std.process`.)

```
pub fn get(_ name: String) -> Option<String>;
pub fn set(_ name: String, _ value: String) -> Void;
pub fn vars() -> Map<String, String>;
pub fn args() -> List<String>;          // program arguments (also passed to main)
pub fn current_dir() -> Result<String, Error>;
pub fn set_current_dir(_ path: String) -> Result<Void, Error>;
pub fn exit(_ code: Int) -> Void;       // does not return; typed Never once that lands
pub fn os() -> String;                  // 'macos' | 'linux' | 'windows' | ...

// The environment as an opt-in capability (see testability.md). The free
// functions are the ambient form of `system_env().get(...)` / `.args()`; tests
// pass `testing.fixed_env`.
pub interface Env {
    fn get(self, _ name: String) -> Option<String>;
    fn args(self) -> List<String>;
}
pub fn system_env() -> Env;
```

Note: `OS` is a function (`os()`), not a `const` — it is a runtime/platform
value, and Hawk has no load-time init to materialize a `const` from one (see
[roadmap.md](roadmap.md)). `exit` is typed `Void` until a `Never` type lands.
`Env` is the second instance of the ambient-capability pattern after
`time.Clock` (see [testability.md](testability.md)).

### `std.process` — subprocess spawning _(implemented)_

Purpose: run and stream child processes. `run` captures output to completion;
`exec` inherits this process's terminal (live output, interactive stdin) and
returns just the exit code; `start` spawns and exposes the pipes through the
`std.io` `Reader`/`Writer` protocol, so `io.read_all`/`io.copy` work against a
child's streams.

```
pub fn run(_ command: String, args: List<String> = [],
           working_dir: Option<String> = Option.None,
           env: Option<Map<String, String>> = Option.None)
    -> Result<ProcessResult, ProcessError>;   // captured stdout/stderr/exit_code

pub fn exec(...) -> Result<Int, ProcessError>;            // same args; inherits stdio, returns exit code

pub fn start(...) -> Result<Process, ProcessError>;       // same args; pipes are piped

pub type ProcessResult = { exit_code: Int, stdout: String, stderr: String }
pub type Process = { id: Int }

impl Process {
    pub fn stdin(self) -> Writer;     // child stdin, as a Writer
    pub fn stdout(self) -> Reader;    // child stdout, as a Reader
    pub fn stderr(self) -> Reader;    // child stderr, as a Reader
    pub fn close_stdin(self) -> Result<Void, ProcessError>;  // signal EOF to a filter
    pub fn wait(self) -> Result<Int, ProcessError>;
    pub fn kill(self) -> Result<Void, ProcessError>;
}

pub enum ProcessError { NotFound(String), Io(String) }   // implements Error + Display
```

Notes: `exec` is the inherit-stdio counterpart to `run` (capture) — use it to
launch a child whose console you want to share (a REPL, a pager, a subcommand
whose output should stream as it happens); it's how the Hawk CLI's `run`/`test`
drive the runtime. `run` pipes and captures; `exec` shares the parent fds and
returns only the exit code. Pipes stream `Bytes` (the `Reader`/`Writer`
currency), so writing text is `child.stdin().write(s.bytes())`. `close_stdin()`
is the explicit EOF signal a
write-then-read filter (`cat`, `grep`, `sort`) needs — without it `read_all`
deadlocks waiting on a child that's waiting on more input. `ProcessError` is
classified: a missing executable is `NotFound` (matchable), everything else is
`Io`. Errors come back from the natives kind-tagged and a private helper maps
them — the same pattern as `std.fs`.

### `std.time` — clocks, durations, dates _(implemented)_

Purpose: wall-clock and monotonic time, durations, and RFC 3339 formatting and
parsing. `Duration`/`Instant` carry nanoseconds (so `elapsed()` keeps
sub-millisecond precision); `DateTime` is Unix milliseconds, UTC. The civil-date
math and the RFC 3339 format/parse are pure Hawk; only the monotonic clock and
`sleep` need a native.

```
pub type Duration = { /* nanoseconds */ }
pub type Instant  = { /* monotonic nanos, relative to a process baseline */ }
pub type DateTime = { /* Unix milliseconds, UTC */ }

pub fn now_millis() -> Int;          // ambient wall clock, Unix millis
pub fn now() -> DateTime;            // wall clock (UTC)
pub fn monotonic() -> Instant;       // for elapsed measurement
pub fn sleep(_ d: Duration) -> Void; // blocks the thread (parks the fiber once fibers land)

// The clock as an opt-in capability (see testability.md). `now*()` is the
// ambient form of `system_clock().now*()`; tests pass `testing.fixed_clock`.
pub interface Clock { fn now_millis(self) -> Int; }
pub fn system_clock() -> Clock;

impl Duration {
    pub fn nanos / millis / seconds / minutes / hours (_ n: Int) -> Duration;   // constructors
    pub fn as_nanos / as_millis / as_seconds (self) -> Int;
    pub fn plus(self, _ other: Duration) -> Duration;   // + minus
}
impl Instant {
    pub fn elapsed(self) -> Duration;
    pub fn duration_since(self, _ earlier: Instant) -> Duration;
}
impl DateTime {
    pub fn from_unix_millis / from_unix_seconds (_ n: Int) -> DateTime;
    pub fn unix_millis / unix_seconds (self) -> Int;
    pub fn format_rfc3339(self) -> String;                          // UTC, '...Z'
    pub fn parse_rfc3339(_ s: String) -> Result<DateTime, Error>;   // accepts Z and ±HH:MM
}
```

Notes: time-zone database and locale-aware formatting are ecosystem; core ships
UTC + RFC 3339 + Unix time, which covers logging/timestamps/CLI needs.
`format_rfc3339` emits a `.sss` fraction only when the millisecond part is
non-zero; `parse_rfc3339` accepts a `Z` or `±HH:MM` zone and an optional
fractional part (keeping millisecond precision), normalizing to UTC. `sleep`
blocks the thread until cooperative fibers arrive.

### `std.fiber` — cooperative concurrency _(spawn/join/yield + channels implemented; I/O parking deferred)_

Purpose: explicit concurrency on the single thread.

```
pub type Fiber<T> = { /* handle */ }            // implemented
pub fn spawn<T>(_ work: () -> T) -> Fiber<T>;    // implemented
pub fn yield() -> Void;                          // implemented — cede the thread

impl Fiber<T> { pub fn join(self) -> T; }   // implemented — the only way to get the result out

// Channels for fiber-to-fiber handoff — implemented (buffered).
pub type Channel<T> = { /* handle */ }
pub fn channel<T>(capacity: Int = 1) -> Channel<T>;   // buffer size, clamped to >= 1
impl Channel<T> {
    pub fn send(self, _ value: T) -> Void;     // blocks while full; traps if closed
    pub fn receive(self) -> Option<T>;          // None when closed & drained
    pub fn close(self) -> Void;
}
```

**Status:** `spawn`/`join`/`yield` and **channels** run on a cooperative FIFO
scheduler — a fiber runs until it blocks (`join` on an unfinished fiber,
`send` on a full channel, `receive` on an empty one) or `yield`s, then the next
ready fiber runs; `join` is the only way to get a fiber's result out.
Deterministic scheduling, and GC keeps parked fibers' and channels' values alive.
Channels are **buffered** (capacity ≥ 1, FIFO; a closed channel drains then gives
`None`; `send` after `close` traps); true 0-capacity rendezvous is a later
refinement. Deferred: parking on real I/O — today only fiber/channel ops park
(see the I/O staging in the design). One ergonomic snag from the front end, not
fibers: a **block-body** work closure (`spawn(() => { … return x; })`) infers its
return as `Void`, so use an expression body (`spawn(() => compute())`) or a named
function until block-body lambda return inference lands (tracked in
[roadmap.md](roadmap.md)).

Notes: no mutexes/atomics — single-threaded means no data races
([language.md](language.md) §Concurrency). `select` over channels is a candidate
addition. The **runtime implementation** — fibers as stackless coroutines over
the interpreter's explicit frame stack, the scheduler, parking, GC roots across
fibers, and the I/O staging — is sketched in [architecture.md](architecture.md)
§Concurrency.

**Fibers gate the IO-heavy libraries.** The "concurrency is invisible" principle
(§ Cross-cutting #5) — blocking I/O parks the fiber instead of the thread — only
becomes real once the scheduler lands, so `std.http` and any other library that
wants concurrent, blocking-looking I/O depends on `std.fiber` first; the two
should be sequenced together (see § Sequencing). And because the fiber API is
load-bearing for that whole tier, its design should be driven by **iterative
feedback from real IO use cases** (a concurrent HTTP fetch, a server accept loop,
piping between processes) rather than fixed up front — prototype against those
clients and let them shape `spawn`/`join`/channels (and whether `select` is
needed) before freezing the surface.

### `std.math` — numeric functions _(implemented)_

Hawk has no function overloading and no implicit `Int`→`Double` coercion, so the
surface splits by a single rule: **type-preserving ops that also apply to `Int`
are methods on the numeric types; inherently-`Double` ops are `std.math`
functions.**

Methods (core prelude, on **both** `Int` and `Double`, returning their own
type):

```
n.abs()   a.min(b)   a.max(b)   x.clamp(low, high)
n.to_double()   x.to_int()   // truncates toward zero
```

`std.math` (Double; `import std.math`):

```
pub const PI: Double; pub const E: Double; pub const TAU: Double;
pub fn sqrt(_ x: Double) -> Double;   pub fn pow(_ base: Double, _ exp: Double) -> Double;
pub fn floor(_ x: Double) -> Double;  pub fn ceil(_ x: Double) -> Double;
pub fn round(_ x: Double) -> Double;  pub fn trunc(_ x: Double) -> Double;
pub fn exp(_ x: Double) -> Double;    pub fn ln(_ x: Double) -> Double;  pub fn log10(_ x: Double) -> Double;
pub fn sin(_ x: Double) -> Double;    pub fn cos(_ x: Double) -> Double; pub fn tan(_ x: Double) -> Double;
pub fn asin(_ x: Double) -> Double;   pub fn acos(_ x: Double) -> Double; pub fn atan(_ x: Double) -> Double;
pub fn atan2(_ y: Double, _ x: Double) -> Double;   pub fn hypot(_ x: Double, _ y: Double) -> Double;
```

Notes: feed an `Int` to a `std.math` function via `n.to_double()`; rounding
returns `Double` (chain `.to_int()` for an `Int`). Numeric parsing is on
`String` (prelude): `s.to_int() -> Option<Int>`,
`s.to_double() -> Option<Double>` (strict — the whole string must be the
number). Deferred: `INFINITY`/`NAN` (no literal form, and no load-time init —
would need natives).

### `std.random` — randomness _(implemented)_

```
pub type Rng = { state: Int }   // seedable, state is a visible value
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

Notes: an `Rng` value, not a global, per principle 7 (no hidden state) — the
whole state is a visible `Int` field, so `seeded(n)` is fully reproducible.
Algorithm: **SplitMix64**. The state advances in Hawk (a wrapping add of the
golden-ratio constant); the bit-mixing is a Rust native (`random_mix`) because
Hawk has no bitwise operators yet (see [roadmap.md](roadmap.md)). The mixer is
hand-rolled std-only Rust to keep the runtime dependency-free; a crate could
replace it behind the same natives. Not cryptographically secure. A higher-
quality / pure-Hawk generator waits on the bitwise-operators arc.

### `std.json` — JSON _(implemented, pure Hawk; the flagship data format)_

Purpose: parse and serialize JSON. A structural `Json` value, with a
hand-written scanner + recursive-descent parser in pure Hawk
(`sdk/std/json/json.hawk`) — the worked stand-in for self-hosting the front-end.

```
pub enum Json {
    Null, Bool(Bool), Int(Int), Double(Double), Str(String),
    Array(List<Json>), Object(Map<String, Json>),    // Object is insertion-ordered
}

// Lowercase constructors (the building API):
pub fn null() / bool(b) / int(n) / double(x) / str(s) / arr(items) / obj(fields) -> Json;

pub fn parse(_ text: String) -> Result<Json, JsonError>;
pub fn stringify(_ value: Json, pretty: Bool = false) -> String;

impl Json {
    pub fn get(self, _ key: String) -> Json;       // Object field, else Null (chainable)
    pub fn at(self, _ index: Int) -> Json;          // Array element, else Null
    pub fn as_bool / as_int / as_double / as_string (self) -> Option<...>;
    pub fn as_array(self) -> Option<List<Json>>;    // + as_object
    pub fn is_null(self) -> Bool;
}
pub enum JsonError { Syntax(String) }                // implements Error + Display
```

`Int`/`Double` are split (not a single `Number`) so integers round-trip exactly
and construct cleanly (`json.int(42)`); the parser picks the variant by syntax
(a `.`/`e`/`E` → `Double`), and `as_int`/`as_double` cross-tolerate. `get`/`at`
return `Json` (Null on miss) rather than `Option`, so navigation chains —
`root.get('user').get('name').as_string()` — which matters because Hawk's
`Option` has no `and_then` yet. Strings handle the full escape set including
`\uXXXX` with surrogate-pair combining. `JsonError` is `Syntax`-only for v1
(parse is the only fallible op; a `Type`/`Missing` variant returns with typed
`decode`).

**Encoding ergonomics — three layers.** Building a heterogeneous value needs
`Json` (Hawk has no heterogeneous map/list literal — a raw
`{ 'a': 1, 'b': true }` is a `Map`, not a `Json`, and won't pass to
`stringify`). The layers:

1. **Constructors (today):**
   `json.obj({ 'two': json.int(123), 'three': json.double(1.2) })` — container
   literals stay; only the leaves wrap.
2. **Auto-boxing (proposed — §Sequencing):** an expected-type-directed coercion
   that extends the existing implicit `Ok`-wrap to `Json`: where a `Json` is
   expected, a literal/primitive boxes into its variant (`Int`→`Json.Int`, a
   list literal→`Json.Array` recursively, a `String`-keyed map
   literal→`Json.Object`), so `let doc: Json = { 'two': 123, 'three': 1.2 }`
   just works. Encode-only; scoped to the blessed `Json` type. The most
   LLM-friendly for ad-hoc inline JSON.
3. **Reflection `encode<T>`/`decode<T>` (research-later — §Sequencing):** typed
   struct ↔ JSON with no manual wrapping, and the only path to typed
   **decoding**.

These three coexist: a named type → reflection; an ad-hoc inline blob →
auto-boxing; the constructors are the explicit fallback under both.

**The struct story is a planned priority, not just research.** Today the only
JSON↔struct path is hand-mapping through the `Json` enum (`as_*` on the way in,
constructors on the way out) — the most common real task (decode a response into
a typed struct, serialize a struct to a request body) is the most boilerplate.
Typed `encode<T>`/`decode<T>` (layer 3) is the committed direction for closing
that gap; **decode is the higher-value half** (typed parsing with
`Type`/`Missing` errors) and the harder one. It's gated on the generics strategy
(monomorphized compile-time reflection vs. today's dynamic dispatch), so it's a
deliberate arc — but the goal is explicit: a Hawk struct should round-trip to
JSON without manual wrapping. See § Sequencing #5.

**YAML/TOML/CSV are ecosystem** — this is where an agent looks first and finds
the pointer.

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

Purpose: make HTTP requests. **Client first** in core; raw sockets stay
ecosystem. A **simple HTTP server** is under consideration for core — either in
`std.http` or a sibling `std.http.server` — because lightweight servers
(webhooks, a local endpoint, a health check) are common enough in agent/CLI
tooling to be worth a built-in answer; full server *frameworks* (routing DSLs,
middleware stacks) stay ecosystem. Both client and server depend on `std.fiber`
for concurrent, blocking-looking I/O (see § `std.fiber` and § Sequencing), so
this lands after the scheduler.

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

### `std.cli` — argument parsing _(implemented, pure Hawk)_

Purpose: declarative CLI parsing with subcommands, typed options, and a
generated `--help`. The richer `Command` builder sits alongside the thin
`std.cli/args` (`Args`), which stays for raw access. **Implemented entirely in
Hawk** (`sdk/std/cli/command.hawk`).

```
pub type Command = { name, about, flags, options, positionals, subcommands }
impl Command {
    pub fn new(_ name: String) -> Command;                  // auto-registers --help/-h
    pub fn about(self, _ text: String) -> Command;
    pub fn flag(self, _ name: String, help = '', abbr = '',
                negatable = false, default = false) -> Command;   // Bool
    pub fn option(self, _ name: String, help = '', abbr = '') -> Command;  // String
    pub fn positional(self, _ name: String, help = '') -> Command;
    pub fn subcommand(self, _ cmd: Command) -> Command;
    pub fn parse(self, _ args: List<String>) -> Result<Matches, CliError>;
    pub fn help(self) -> String;                            // generated usage text
}
pub type Matches = { /* typed accessors */ }
impl Matches {
    pub fn flag(self, _ name: String) -> Bool;              // resolves negation + default
    pub fn option(self, _ name: String) -> Option<String>;
    pub fn positional(self, _ index: Int) -> Option<String>;
    pub fn positionals(self) -> List<String>;
    pub fn subcommand(self) -> Option<String>;              // selected subcommand
    pub fn matches(self) -> Option<Matches>;                // its parsed Matches
}
pub enum CliError { UnknownFlag(String), MissingValue(String),
                    UnexpectedValue(String), UnknownSubcommand(String) }
```

Names are declared **bare** (`flag('verbose')`); the parser accepts the long
form (`--verbose`), abbreviations (`-v`), `--name value` / `--name=value` for
options, and `--no-name` for `negatable` flags. `--help`/`-h` is auto-registered
but never auto-intercepted — the caller decides when to print `help()`.
`CliError` implements `Error` + `Display`, so it propagates as
`Result<_, Error>` and renders directly while callers who want the cause still
`match` on it.

**Usability follow-ups (v2).** Writing real clients (`pkgs/cli/main.hawk`,
`examples/git_branch.hawk`) showed the _parsing_ is handled, but the glue
**around** a parse — help, subcommand dispatch, errors, exit codes — is
re-implemented by every multi-command client. The library should absorb it,
roughly in priority order:

- **An opinionated entry adapter** (the headline). One call that parses and: on
  a `CliError`, prints the message + usage to stderr and signals a non-zero
  exit; on `--help`, prints the _selected_ (sub)command's help and signals exit
  0; otherwise hands back the resolved command + its `Matches`. This collapses
  the ~40 lines of identical glue every client writes (`pkgs/cli` included).
- **Selected-subcommand help.** `--help` is auto-registered but inert; a client
  must find the chosen subcommand and call _its_ `help()` (`pkgs/cli` iterates
  `subcommands` by name to do this). Add `Matches.selected_help()` /
  `Command.help_for(name)`.
- **Dispatch ergonomics.** Today: `subcommand()` (→`Option<String>`) then
  `matches()` (→`Option<Matches>`) then a string-equality ladder (no string
  match patterns). Return the selected subcommand **and** its `Matches`
  together, or support handler registration, to remove the boilerplate.
- **Required positionals + arity.** Positionals are descriptive only; a client
  hand-checks `positional(0)` and emits "expected `<file>`". Let `positional` be
  marked required, yielding an automatic `MissingPositional` (and feeding the
  generated usage); add a `TooManyArgs` for arity.
- **Command-path-aware errors.** A subcommand parse error bubbles up without
  recording which subcommand failed, so a client can only show the _top-level_
  help (`hawk run --bad` shows `hawk` usage, not `run`'s). Carry the command
  path in `CliError`.
- **Help formatting.** Column-align the name/description columns in `help()`
  (today they're space-padded, not aligned). Plus short-flag clustering (`-rf`),
  still deferred.

None are blockers — all are "remove a decision" wins. The entry adapter is the
high-leverage one; required positionals and command-path-aware errors are the
next tier.

### `std.term` — terminal _(new)_

```
pub fn is_tty() -> Bool;
pub fn size() -> Option<(Int, Int)>;      // (cols, rows); tuple syntax TBD in language
pub fn style(_ text: String, color: Color, bold: Bool = false) -> String;  // ANSI
pub enum Color { Red, Green, Yellow, Blue, Default /* … */ }
```

Notes: color helpers should no-op when `!is_tty()` so piped output stays clean.

### `std.char` — ASCII code points _(implemented, pure Hawk)_

Purpose: name the ASCII range so it never has to be rewritten from memory (the
constants are the point — they're copied by hand in languages that lack them),
plus a handful of ASCII-only predicates and case conversions over code points
(`Int`).

```
pub const SPACE: Int;  pub const LF: Int;  pub const DIGIT_0: Int;  // … the ASCII set
pub fn is_digit(_ cp: Int) -> Bool;       // + is_hex_digit/is_alpha/is_alphanumeric
pub fn is_whitespace(_ cp: Int) -> Bool;  // + is_upper/is_lower
pub fn digit_value(_ cp: Int) -> Option<Int>;
pub fn to_lower(_ cp: Int) -> Int;        // + to_upper; non-letters pass through
```

Notes: ASCII only (U+0000..U+007F). Full Unicode classification and locale-aware
case folding belong to a Unicode/ICU package, not core. Identifier predicates
(`is_ident_start`/`continue`) were removed as too source-parser-specific.

### `std.regex` — regular expressions _(removed → rebuild)_

> **Status: removed.** An early version existed in pure Hawk over `re2_*`
> natives, but those natives did not survive the Rust-runtime migration (they
> were bound by bare name and now exist nowhere), so the module was
> non-functional and has been deleted. The design below is the target for a
> rebuild. **The blocker is the engine:** the runtime is deliberately
> dependency-free, so backing this needs either a hand-rolled engine in Rust or
> a deliberate decision to take the `regex` crate (RE2-derived) as the runtime's
> first dependency — a policy call to make when this is picked back up.

Purpose: compile a pattern once, then match / find / capture / replace against
Unicode text. RE2 syntax (linear-time, no backtracking / lookaround) — see
<https://github.com/google/re2/wiki/Syntax>. Offsets in `Match` are **UTF-8 byte
positions** (matching the string-offset convention in principle 8).

```
pub type Regex = { /* opaque compiled pattern */ }
impl Regex {
    pub fn compile(_ pattern: String) -> Result<Regex, RegexError>;  // invalid pattern -> Err
    pub fn is_match(self, _ text: String) -> Bool;
    pub fn find(self, _ text: String) -> Option<Match>;              // first match
    pub fn find_all(self, _ text: String) -> List<Match>;           // all, non-overlapping
    pub fn captures(self, _ text: String) -> Option<Captures>;       // first match + groups
    pub fn replace(self, _ text: String, with replacement: String) -> String;     // first
    pub fn replace_all(self, _ text: String, with replacement: String) -> String; // all
}

pub type Match = { text: String, start: Int, end: Int }   // start inclusive, end exclusive (bytes)

pub type Captures = { /* groups: List<Option<String>> */ }
impl Captures {
    pub fn text(self) -> Option<String>;          // group 0 (the whole match)
    pub fn group(self, _ index: Int) -> Option<String>;  // None if absent / didn't participate
}

pub enum RegexError { Syntax(String) }   // implements Error + Display (mirrors JsonError)
```

Notes for the rebuild: group 0 is the full match, `1..` the numbered subgroups;
a group that did not participate in the match is `None`. `$1` / `${name}` expand
capture references in replacements. The `re2_*` native bindings and the compiled
handle stay module-private (once visibility enforcement lands). The original
`compile` returned `Result<_, Error>` with the raw native message; the rebuild
should wrap it in a proper `RegexError.Syntax` (principle 4), as `std.json`
does.

### `std.testing` — assertions _(implemented)_

`assert` / `assert_eq` / `assert_ne` / `assert_ok` / `assert_err`, plus the
`fixed_clock` / `fixed_env` test doubles. The equality assertions are generic
over `<T: Eq + Debug>` (the generics arc), rendering mismatches via the
structural `debug`. Self-tested in `testing_test.hawk`. Because `Error` extends
`Debug` (interface inheritance), `assert_ok`/`assert_err` inspect a
`Result<_, Error>` directly — the interface-typed error satisfies their
`E: Debug` bound.

## What is intentionally _not_ in core

So the boundary is explicit (and so an agent knows where to look):

- **Other config formats** — YAML, TOML, CSV → ecosystem (JSON is core).
  Deferred deliberately, but **revisit with usage feedback**: TOML in particular
  is common enough for CLI/tool config that it's the first candidate to promote
  into core if real use cases pile up. Pivot when the demand is demonstrated, not
  speculatively.
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
   dispatch ([language.md](language.md), "Deferred") are a prerequisite for
   the library's two core abstractions:
   - `io.copy(dst: Writer, src: Reader)` and any function taking a `Reader`/
     `Writer` parameter — these are interface-typed.
   - The common `Error` **interface** as a return type (`Result<T, Error>` where
     `Error` is the interface) — **done**: `Error` is now an interface, concrete
     errors `impl Error`, and `?` propagates a concrete error into an
     `Error`-returning caller (see § `Error`). `Error` extends `Display + Debug`
     (interface inheritance), so interface-typed errors interpolate (`'${e}'`)
     and work with `assert_ok`/`assert_err`.
   - Generic bound enforcement (`<T: Display>`, `<T: Eq + Debug>`) used by
     `std.testing` and generic combinators.

2. **`Bytes` core type + `Reader`/`Writer` interfaces — done (v1).** `Bytes` +
   `BytesBuilder` are runtime-backed prelude types, and `std.io` ships the
   `Reader`/`Writer`/`Closer` interfaces, `read_all`/`copy`, the standard
   streams, and `StringWriter`. Deferred: `lines`/`Iterator`, streaming files,
   the typed binary `BytesReader`.

3. **Lazy `Iterator<T>` — done (v1).** `Iterator<T>` is a **generic interface**
   in the prelude (Hawk's first),
   `pub interface Iterator<T> { fn next(self) -> Option<T>; }` — pull-based,
   `self`-mutating cursor. `std.iter` ships the `range`/`from_list` sources and
   the eager `collect`/`count` consumers, and a `for x in it` loop drives any
   iterator (the for-loop lowers to `next()`/match over `Option`, dispatched
   virtually so concrete and interface-typed iterators work alike). Landing it
   added the generic-interface machinery end to end (parser type params on
   `interface`/`impl Iface<Args> for T`, conformance substitution, and
   receiver-arg inference reused from the collection types) and filled a codegen
   gap: block-bodied match arms (`Some(v) => { … }`) compile. (Such a block then
   yielded `Unit`; expression-position **tail expressions** now make its final
   expression the value — see [language.md](language.md).)
   Deferred: `map`/`filter`/`take`/`enumerate` adapters and a fluent `Iter<T>`
   wrapper; these unblock `fs.walk`, `io.lines`, and `BufReader`.

4. **`Error` interface migration — done.** `std.core/error.hawk`'s `Error` is
   now an interface with a `Message` struct; `throw`/`?`/implicit-`Ok` needed no
   change (they pass the value through, and interface-typed `E` subsumption was
   already handled), and `std.testing` constructs `Message`. `Error` extends
   `Display + Debug` (interface inheritance), so interface-typed errors
   interpolate (`'${e}'`) and work with `assert_ok`/`assert_err` directly; each
   error type provides an explicit `impl Display` (every one already did), and
   `Debug` is the structural auto-derive.

5. **JSON encoding ergonomics.** Two independent improvements over the
   constructors (`json.obj`/`json.int`/…) that ship today, for the two distinct
   use cases — building ad-hoc inline JSON, and serializing typed data:
   - **Auto-boxing into `Json` (proposed; smaller).** Extend the existing
     expected-type-directed boxing — the implicit `Ok`-wrap (`return n` →
     `Ok(n)`) — to the blessed `Json` type. **Rule:** when the expected type is
     exactly `Json`, an expression whose type is `Int`/`Double`/`String`/`Bool`
     boxes into the matching variant; a **list literal** elaborates each element
     against `Json` and boxes to `Json.Array`; a **`String`-keyed map literal**
     boxes its values to `Json.Object`. So
     `let doc: Json = { 'two': 123, 'tags': ['a', 'b'], 'ok': true }` works.
     Scoped to literals/primitives in `Json` context (not arbitrary coercion),
     and **encode-only**. It introduces Hawk's first implicit _primitive_ boxing
     — softened by the `Ok`-wrap precedent (same mechanism, another blessed
     type) and by being lossless. Highest ergonomic-return-per-effort; the most
     LLM-friendly for inline JSON.
   - **Compile-time reflection `encode<T>`/`decode<T>` (research-later;
     bigger).** Typed struct ↔ JSON with no manual wrapping, and the only path
     to typed **decoding** (the harder, more valuable half) plus `Debug`/`Eq`
     derive. Done as _compile-time, monomorphized_ reflection
     (serde/Zig-comptime style) it carries no runtime metadata, so it stays
     AOT/tree-shake-friendly — but it entangles with the generics strategy
     (monomorphization vs today's dynamic dispatch), so it's a deliberate arc to
     research, not a quick add. Open design questions: enum→JSON representation,
     field renaming, `Option` fields, and decode-error variants
     (`Type`/`Missing` on `JsonError`).

   The two coexist (named type → reflection; ad-hoc blob → auto-boxing); the
   constructors are the explicit fallback under both. Preferred over
   macros/codegen (a last resort) — compile-time reflection is the principled
   substitute.

6. **Runtime natives.** New runtime support is needed for `std.time` (clocks),
   `std.random` (entropy), `std.http` (sockets + TLS), `std.hash`, and
   `std.fiber` (the scheduler). These are independent of the front-end arcs and
   can proceed in parallel — **except** that the **IO-heavy libraries depend on
   `std.fiber`**: `std.http` (client and the candidate server) wants
   concurrent, blocking-looking I/O, which is only "invisible" once the
   scheduler parks fibers (principle #5). So sequence `std.fiber` **before**
   `std.http`, and let real IO clients (a concurrent fetch, a server accept loop)
   drive the fiber API's design rather than fixing it up front (see
   § `std.fiber`).

7. **Visibility enforcement** ([language.md](language.md)). Some modules
   (e.g. `std.process`) have native bindings that should be module-private;
   today the language can't enforce it. Tighten when visibility lands.

8. **Top-level `const` in codegen — done.** `const`/`pub const` now compile: a
   reference (bare or namespace-qualified `ns.NAME`) inlines its initializer
   expression at the use site (codegen has no global storage). This unblocks
   `std.char`'s constants and `std.math`'s `PI`/`E`. (Note: a _platform_ value
   like a path separator is **not** a fit for `const` — it's compile-time
   inlined — so std.path stays slash-based and a native-backed separator waits
   for OS-aware paths. There is no load-time static-initializer mechanism yet.)

## Status summary

| Module       | Status  | Notes                                                                                                                                                                                                                               |
| ------------ | ------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| prelude/core | exists  | Int/Double + String parsing; `String.slice`/`List.slice` (code-point / element ranges, clamped); `Bytes`/`BytesBuilder`; `Set<T>` in Hawk over `Map`; `Error` is an interface + the `error(...)` constructor; `Iterator<T>` protocol; still want `Ord` |
| std.io       | done    | v1: `Reader`/`Writer`/`Closer` + `IoError`, `read_all`/`copy`, stdin/stdout/stderr, `StringWriter`; `lines`/`Iterator` + streaming files deferred                                                                                   |
| std.iter     | done    | v1: `Iterator<T>` (prelude) + `range`/`from_list` sources + `collect`/`count`; `for x in it` drives any iterator; adapters (`map`/`filter`/`take`) deferred                                                                         |
| std.fs       | done    | v1: read/write text+bytes, exists, metadata, list_dir, create_dir(\_all), remove(\_dir_all), rename, copy, temp_dir; classified `FsError`; streaming `File`/`open`/`walk`/`temp_file` deferred to v2                                |
| std.path     | done    | pure Hawk; `components`/`with_extension` added; normalize/relative deferred                                                                                                                                                         |
| std.env      | done    | vars/args/cwd/os/exit + `Env` capability + `testing.fixed_env`; `OS`→`os()`                                                                                                                                                         |
| std.process  | done    | `run` (capture) / `exec` (inherit stdio, exit code) / `start`; pipes are `std.io` `Reader`/`Writer` (+ `close_stdin`); classified `ProcessError`                                                                                     |
| std.time     | done    | wall + monotonic clocks, `Duration`/`Instant` (nanos), `DateTime` (Unix ms UTC) + RFC 3339 format/parse, `sleep`; `Clock` capability + `testing.fixed_clock`                                                                        |
| std.fiber    | partial | cooperative scheduler: `spawn`/`join`/`yield` + buffered `Channel<T>` (send/receive/close) over a FIFO run-queue, GC roots across fibers and channel buffers; parking on real I/O + 0-capacity rendezvous deferred                    |
| std.math     | done    | Double fns + constants; abs/min/max/clamp + to_double/to_int are Int/Double methods                                                                                                                                                 |
| std.random   | done    | SplitMix64; state is a visible Int; mix via native (bitops gap)                                                                                                                                                                     |
| std.json     | done    | pure Hawk; structural `Json` + constructors, parse/stringify, navigation; Int/Double split; auto-boxing + typed decode later                                                                                                        |
| std.encoding | new     |                                                                                                                                                                                                                                     |
| std.hash     | new     | runtime native                                                                                                                                                                                                                      |
| std.http     | new     | client only; runtime sockets + TLS                                                                                                                                                                                                  |
| std.log      | new     |                                                                                                                                                                                                                                     |
| std.cli      | done    | pure Hawk; declarative `Command`/`Matches`/`CliError` + `--help`, abbrs, negation; `Args` is the raw escape hatch. v2: entry adapter, selected-subcommand help, required positionals, command-path errors (§ std.cli)               |
| std.term     | new     |                                                                                                                                                                                                                                     |
| std.char     | done    | pure Hawk; `pub` API + ASCII scope; `is_hex_digit` added, ident predicates removed                                                                                                                                                  |
| std.regex    | removed | was pure Hawk over `re2_*` natives that didn't survive the runtime migration; deleted as non-functional — design captured above for a rebuild (needs a runtime engine: hand-rolled or the `regex` crate)                            |
| std.testing  | done    | `assert`/`assert_eq`/`assert_ne`/`assert_ok`/`assert_err` + `fixed_clock`/`fixed_env` doubles; self-tested                                                                                                                          |
