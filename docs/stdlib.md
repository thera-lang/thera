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
agent automation (the target domain, see [overview.md](overview.md)). The long
tail — databases, exotic formats, GUI — belongs to the package ecosystem, but
every _common_ task must have an answer in core.

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
   protocol — the `Reader` / `Writer` / `Closer` / `Seek` interfaces in `std.io`
   (§ Core types). Files, process pipes, sockets, and in-memory buffers all
   implement them, so `io.copy`, `io.read_all`, and `io.lines` work against any
   source. Whole-value conveniences (`fs.read_text`, `fs.write_text`) are thin
   wrappers for the common case. **There is exactly one streaming abstraction.**

4. **Errors are values, per-domain enums, one common interface.** Every fallible
   function returns `Result<T, E>`. Each domain defines a small error enum
   (`FsError`, `JsonError`, `HttpError`) so callers can `match` on the cause;
   all of them implement the common `Error` interface (`§ Error`), which is the
   uniform currency at boundaries and the conventional `E` in library-agnostic
   code. No exceptions, no hidden control flow (see [overview.md](overview.md)).

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
   system implementation (`time.now_millis()` ≡ `system_clock().now_millis()`).
   Some capabilities make the value-you-hold form the default instead
   (`random.Rng` has no ambient form, since reproducibility is the common case).
   The test seam is a **separate, explicit path** — you pass a fake capability,
   never override the free function — so nothing is swapped from under you. Most
   code should take **neither**: the functional core takes plain data
   (`fn format(at: DateTime)`, not a `Clock` it reads); the capability is only
   for the orchestrating middle layer that genuinely needs the effect yet is
   still worth unit-testing. Test doubles live by usefulness — a
   production-useful one beside its real library (`fs.MemoryFileSystem`), a
   test-only one in `std.testing` (`testing.fixed_clock`) — while the interface
   itself always lives with the real library. The stdlib ships **no capability
   bundle** (`Sys`/`Context`): that is one step from an ambient god-object and
   is application-specific, so apps thread their own. This keeps the functional
   core pure ([overview.md](overview.md)) and the test seam explicit rather than
   a global override.

8. **Text is UTF-8; bytes are `Bytes`.** `String` is validated UTF-8; raw binary
   is the `Bytes` type (§ Core types). Conversions are explicit: `s.chars()`
   returns code points (`List<Int>`) and `s.bytes()` returns the UTF-8 encoding
   as `Bytes` (`.to_list()` for the raw 0..=255 byte values);
   `Bytes.to_string()` validates UTF-8. String offsets follow the existing
   convention: code-point counts for `len`, UTF-8 byte offsets where byte
   positions are needed.

## The tiers

| Tier          | Import          | Contents                                                                                                                                           |
| ------------- | --------------- | -------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Prelude**   | none (auto)     | primitives, `List`/`Map`/`Set`, `Option`/`Result`, `Error` + `Eq`/`Display`/`Debug`/`Ord`, `println`/`print`/`eprintln`/`eprint`, `String` methods |
| **Core std**  | `import std.x`  | `io iter fs path env process time fiber math random sort json encoding hash http log cli term char regex testing`                                  |
| **Ecosystem** | package manager | databases, YAML/TOML/CSV, HTTP server _frameworks_ (a simple server is core), raw sockets (a provisional `std.net` backs `std.http`), compression, full crypto/TLS, UUID, templating, … |

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
pub struct Bytes { let /* opaque; let runtime-backed */; }

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
// to the low 8 bits). The fixed-width and LEB128 writers are pure Hawk over
// write_u8 + bitwise ops.
pub struct BytesBuilder { let /* mutable */; }
impl BytesBuilder {
    pub fn new() -> BytesBuilder;
    pub fn write_u8(self, _ byte: Int) -> Void;
    pub fn write_bytes(self, _ data: Bytes) -> Void;
    pub fn write_str(self, _ s: String) -> Void;
    pub fn len(self) -> Int;
    pub fn finish(self) -> Bytes;
    // Fixed-width integers/floats, little- and big-endian:
    pub fn write_u16_le / write_u32_le / write_u64_le (self, _ v: Int) -> Void;
    pub fn write_u16_be / write_u32_be / write_u64_be (self, _ v: Int) -> Void;
    pub fn write_f64_le / write_f64_be (self, _ d: Double) -> Void;
    // LEB128 varints (mirror the runtime's serialize.rs):
    pub fn write_uvarint / write_ivarint (self, _ v: Int) -> Void;
}

// Read a Bytes back — the reader counterpart to BytesBuilder. A forward cursor
// (mut pos); each read advances and returns None at/over the end, so a truncated
// stream is a clean None, not a trap. The integer decoders are exact inverses of
// the writers above (a written value round-trips). Pure Hawk over Bytes.get.
pub struct BytesReader { let /* mutable cursor over a Bytes */; }
impl BytesReader {
    pub fn new(_ data: Bytes) -> BytesReader;
    pub fn remaining(self) -> Int;
    pub fn is_empty(self) -> Bool;
    pub fn read_u8(self) -> Option<Int>;
    pub fn read_bytes(self, _ n: Int) -> Option<Bytes>;
    pub fn read_u32_le / read_u64_le (self) -> Option<Int>;
    pub fn read_uvarint / read_ivarint (self) -> Option<Int>;
}
```

### `Reader` / `Writer` / `Closer` / `Seek` — the streaming protocol _(std.io)_

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
not exhaustive), and **status** in its heading (`implemented` / `partial` /
`new`). This catalog is the single source of truth for module status.

### `std.io` — streaming I/O foundation _(implemented, pure Hawk)_

Purpose: the `Reader`/`Writer`/`Closer`/`Seek` interfaces, the standard streams,
line iteration, and the generic combinators every other I/O module builds on.
Everything streams as `Bytes`. Implemented in pure Hawk over the
interface-dispatch arc (the combinators take interface-typed parameters); small
stream natives back stdin/stdout/stderr.

```
pub interface Reader { fn read(self, max: Int) -> Result<Bytes, Error>; }   // empty = EOF
pub interface Writer { fn write(self, _ data: Bytes) -> Result<Int, Error>; }
pub interface Closer { fn close(self) -> Result<Void, Error>; }
pub enum SeekFrom { Start(Int), Current(Int), End(Int) }
pub interface Seek { fn seek(self, _ to: SeekFrom) -> Result<Int, Error>; }   // new offset
pub enum IoError { Eof, Other(String) }                       // implements Error

// Standard streams (stdin: Reader, stdout/stderr: Writer).
pub fn stdin() -> Reader;  pub fn stdout() -> Writer;  pub fn stderr() -> Writer;

// Combinators over any Reader/Writer; line iteration over any Reader.
pub fn read_all(_ src: Reader) -> Result<Bytes, Error>;
pub fn copy(to dst: Writer, from src: Reader) -> Result<Int, Error>;
pub fn lines(_ src: Reader) -> BufReader;   // BufReader: Iterator<String> (+ read_line/error)

// In-memory Reader/Writer (test doubles for any Reader/Writer).
pub fn from_string(_ s: String) -> Reader;  pub fn from_bytes(_ data: Bytes) -> Reader;
pub struct StringWriter { let /* wraps a BytesBuilder */; }
impl StringWriter { fn new(); fn into_string() -> Result<String, Error>; fn into_bytes() -> Bytes; }
```

`io.lines` and `BufReader` are **done**: `lines(src)` returns a `BufReader` — a
`Reader` wrapper that buffers and yields a line per `next`, so it is an
`Iterator<String>`. `for line in io.lines(f)` and
`io.lines(f).filter(…) .map(…).to_list()` both drive it;
`read_line() -> Result<Option<String>, Error>` is the honest primitive
(iteration treats a read error as end-of-stream and stashes it for `.error()`).
Lines split on `\n`, a trailing `\r` (CRLF) strips, and a final unterminated
line is still yielded. `io.from_string`/`from_bytes` provide an in-memory
`Reader` (the read-side double, symmetric with `StringWriter`).

`fs.walk` and streaming files (`fs.open`/`fs.create` → a
`File: Reader + Writer + Seek + Closer`) both landed on the back of this — see §
`std.fs`. (The typed binary `BytesReader` pairing with `BytesBuilder` now exists
in the prelude — see § Core types — with the typed `read_u16_le`/be family still
a follow-up.)

### `std.iter` — lazy iteration _(implemented, pure Hawk)_

Purpose: the sources that seed the `Iterator<T>` protocol. `Iterator<T>` itself
is a generic interface in the **prelude** (`fn next(self) -> Option<T>`), with
the `map`/`filter`/`take`/`enumerate` adapters and the `to_list`/`count`
consumers shipping as **interface default methods** — so any iterator is fluent
without an import, and `for x in it` drives any iterator. `std.iter` holds only
the two sources:

```
pub fn range(_ start: Int, _ end: Int) -> Iterator<Int>;   // [start, end)
pub fn from_list<T>(_ items: List<T>) -> Iterator<T>;
```

So `iter.range(0, 10).filter((n) => n % 2 == 0).map((n) => n * n).to_list()`
runs entirely off the prelude protocol; `std.iter` just supplies the seeds.

### `std.fs` — filesystem _(implemented, incl. streaming files)_

Purpose: files and directories. Whole-value reads for the common case; streaming
`open`/`create` for line-by-line or large files. Paths are plain `String`s
(compose with `std.path`); directory entries are basenames (join with
`path.join(dir, name)` to descend). Every fallible call returns a per-domain
`FsError` you can `match` on.

```
// Whole-value (conveniences) — implemented.
pub fn read_text(_ path: String) -> Result<String, FsError>;
pub fn write_text(_ path: String, _ text: String) -> Result<Void, FsError>;
pub fn read_bytes(_ path: String) -> Result<Bytes, FsError>;
pub fn write_bytes(_ path: String, _ data: Bytes) -> Result<Void, FsError>;

// Existence, metadata & directories — implemented.
pub fn exists(_ path: String) -> Bool;
pub fn metadata(_ path: String) -> Result<Metadata, FsError>;          // follows symlinks
pub fn symlink_metadata(_ path: String) -> Result<Metadata, FsError>;  // does not follow
pub fn list_dir(_ path: String) -> Result<List<String>, FsError>; // entry basenames
pub fn create_dir(_ path: String) -> Result<Void, FsError>;       // parent must exist
pub fn create_dir_all(_ path: String) -> Result<Void, FsError>;   // mkdir -p
pub fn remove(_ path: String) -> Result<Void, FsError>;           // file or empty dir
pub fn remove_dir_all(_ path: String) -> Result<Void, FsError>;   // recursive
pub fn rename(from src: String, to dst: String) -> Result<Void, FsError>;
pub fn copy(from src: String, to dst: String) -> Result<Void, FsError>;   // file copy
pub fn temp_dir() -> String;

pub enum FileKind { File, Dir, Symlink, Other }
pub struct Metadata { let size: Int; let kind: FileKind; let modified: Option<time.DateTime>; }

pub enum FsError {                          // implements Error + Display
    NotFound(String), PermissionDenied(String), AlreadyExists(String),
    NotADirectory(String), IsADirectory(String), Other(String),
}

// Recursive traversal — implemented.
pub fn walk(_ path: String) -> WalkIter;   // WalkIter: Iterator<String> of full descendant paths

// Streaming files — implemented.
pub fn open(_ path: String) -> Result<File, FsError>;     // read handle
pub fn create(_ path: String) -> Result<File, FsError>;   // write handle (truncates)
pub fn temp_file(prefix: String = 'tmp') -> Result<File, FsError>;  // new, unique, read+write
// File: Reader + Writer + Seek + Closer over a runtime handle, plus `path()`;
// close it when done.
```

Notes: `FsError` is classified from the OS error kind — the natives tag each
error with its kind and a private helper maps it to the variant, so callers get
`NotFound`/`PermissionDenied`/etc., not just `Other`. `metadata` follows
symlinks (so `kind` reports the target); `symlink_metadata` inspects the link
itself (`FileKind.Symlink`). `modified` is an `Option<time.DateTime>` — `None`
when the platform can't report a last-modified time (no misleading `1970`
sentinel). `temp_file` creates a uniquely-named file in `temp_dir()` and opens
it read+write, atomically (never clobbers an existing file); read `File.path()`
to locate it — temp files are not auto-deleted, so `fs.remove(f.path())` when
done. `walk` is a thin `Iterator` over `list_dir`/`symlink_metadata` (a lazy
`WalkIter` yielding every descendant path, directories before their contents;
symlinks are not followed, so a link cycle can't loop; an unreadable directory
is skipped and the first failure kept for `.error()`). `open`/`create` return a
`File` — a handle implementing `std.io`'s `Reader`/`Writer`/`Seek`/ `Closer` —
so `io.lines(fs.open(p)?)` streams a file line by line without loading it whole,
and `seek` (via `io.SeekFrom`) moves the cursor. `open` is read-only, `create`
write-only-truncating; the OS enforces the mode. The handle lives in a runtime
registry; **`close()` when done** — there are no GC finalizers, so an unclosed
file leaks its descriptor until the process exits.

### `std.path` — pure path manipulation _(implemented, pure Hawk)_

Purpose: string-only path operations, no filesystem access. **Implemented
entirely in Hawk** (the worked example of stdlib-in-Hawk; one native,
`env.os()`, backs the separator). Provides
`join`/`join_all`/`dirname`/`basename`/`stem`/`extension`/`is_absolute` plus
`components`, `with_extension`, and the OS boundary (`separator`/`to_native`/
`from_native`).

```
pub fn join(_ base: String, _ part: String) -> String;  // absolute `part` wins
pub fn join_all(_ segments: List<String>) -> String;    // n-ary join (no variadics)
pub fn components(_ path: String) -> List<String>;
pub fn with_extension(_ path: String, _ ext: String) -> String;
pub fn normalize(_ path: String) -> String;             // lexical clean (`.`/`..`/`//`)
pub fn relative(from base: String, to target: String) -> Result<String, Error>;
// + dirname / basename / stem / extension / is_absolute

pub let separator: String;                  // host separator, computed once at load
pub fn to_native(_ p: String) -> String;    // slash -> host form (for display/interop)
pub fn from_native(_ p: String) -> String;  // host form -> slash
```

Slash-based (POSIX-style, like Go's `path`): `'/'` is always the separator, so
manipulation is **deterministic on every platform**. The OS boundary is
explicit, not implicit: `separator` is the host path separator — a **module
initializer** (it can't be a compile-time `const`; [language.md](language.md))
computed once from `env.os()` — and `to_native`/`from_native` translate at a
display or interop boundary (the filesystem natives accept `/` everywhere, so
most code never needs them). Full OS-native path _parsing_ (Windows drive
letters, UNC) is deliberately out of scope — keep application logic in slash
form. `normalize` (Go `path.Clean`), `relative` (Go `filepath.Rel`), and the
n-ary `join_all` (Hawk has no variadics) are all in.

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

// The environment as an opt-in capability (§ Cross-cutting #7). The free
// functions are the ambient form of `system_env().get(...)` / `.args()`; tests
// pass `testing.fixed_env`.
pub interface Env {
    fn get(self, _ name: String) -> Option<String>;
    fn args(self) -> List<String>;
}
pub fn system_env() -> Env;
```

Note: `OS` is a function (`os()`), not a `const` — it is a runtime/platform
value. Module initializers now exist ([language.md](language.md)), but an
_effectful_ native like `os()` is excluded from initializer position, so
capturing it once into a global awaits the process-stable-ambient-native phase
(see the roadmap). `exit` is typed `Void` until a `Never` type lands. `Env` is
the second instance of the ambient-capability pattern after `time.Clock` (§
Cross-cutting #7).

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

pub struct ProcessResult { let exit_code: Int; let stdout: String; let stderr: String; }
pub struct Process { let id: Int; }

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
is the explicit EOF signal a write-then-read filter (`cat`, `grep`, `sort`)
needs — without it `read_all` deadlocks waiting on a child that's waiting on
more input. `ProcessError` is classified: a missing executable is `NotFound`
(matchable), everything else is `Io`. Errors come back from the natives
kind-tagged and a private helper maps them — the same pattern as `std.fs`.

### `std.time` — clocks, durations, dates _(implemented)_

Purpose: wall-clock and monotonic time, durations, and RFC 3339 formatting and
parsing. `Duration`/`Instant` carry nanoseconds (so `elapsed()` keeps
sub-millisecond precision); `DateTime` is Unix milliseconds, UTC. The civil-date
math and the RFC 3339 format/parse are pure Hawk; only the monotonic clock and
`sleep` need a native.

```
pub struct Duration { let /* nanoseconds */; }
pub struct Instant { let /* monotonic nanos; let relative to a process baseline */; }
pub struct DateTime { let /* Unix milliseconds; let UTC */; }

pub fn now_millis() -> Int;          // ambient wall clock, Unix millis
pub fn now() -> DateTime;            // wall clock (UTC)
pub fn monotonic() -> Instant;       // for elapsed measurement
pub fn sleep(_ d: Duration) -> Void; // parks the fiber on a scheduler timer (other fibers run meanwhile)

// The clock as an opt-in capability (§ Cross-cutting #7). `now*()` is the
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
parks the calling fiber on a scheduler timer rather than blocking the thread, so
other fibers run during the sleep; with nothing else runnable the driver sleeps
the thread until the deadline, so a single-fiber program still waits the full
span (§ `std.fiber`).

### `std.fiber` — cooperative concurrency _(spawn/join/yield + channels implemented; I/O parking deferred)_

Purpose: explicit concurrency on the single thread.

```
pub struct Fiber<T> { let /* handle */; }            // implemented
pub fn spawn<T>(_ work: () -> T) -> Fiber<T>;    // implemented
pub fn yield() -> Void;                          // implemented — cede the thread

impl Fiber<T> { pub fn join(self) -> T; }   // implemented — the only way to get the result out

// Channels for fiber-to-fiber handoff — implemented (buffered).
pub struct Channel<T> { let /* handle */; }
pub fn channel<T>(capacity: Int = 1) -> Channel<T>;   // buffer size, clamped to >= 1
impl Channel<T> {
    pub fn send(self, _ value: T) -> Void;     // blocks while full; traps if closed
    pub fn receive(self) -> Option<T>;          // None when closed & drained
    pub fn close(self) -> Void;
}
```

**Status:** `spawn`/`join`/`yield` and **channels** run on a cooperative FIFO
scheduler — a fiber runs until it blocks (`join` on an unfinished fiber, `send`
on a full channel, `receive` on an empty one) or `yield`s, then the next ready
fiber runs; `join` is the only way to get a fiber's result out. Deterministic
scheduling, and GC keeps parked fibers' and channels' values alive. Channels are
**buffered** (capacity ≥ 1, FIFO; a closed channel drains then gives `None`;
`send` after `close` traps); true 0-capacity rendezvous is a later refinement.
`time.sleep` also parks — on a scheduler timer — so other fibers run while a
fiber sleeps. Blocking **syscalls** park too: the `fs` ops (path ops, `open`/
`create`, and `File` read/write/seek), `stdin` read, and `std.process`
(`run`/`exec`/`wait` + pipe I/O) run on a worker-thread pool (the worker returns
owned data; the `Value` is built back on the Hawk thread), so a slow read never
stalls the other fibers — and one fiber can feed a child's stdin while another
drains its stdout. Only fast, effectively-non-blocking calls stay inline
(`fs.exists`, `process.start`/`kill`/`close_stdin`).

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
should be sequenced together (see § Sequencing). That parking now covers every
blocking family: timers, the `fs`/`process` syscalls (a worker pool), and
**sockets** (a readiness poller — see roadmap.md phase 4, and the provisional
`std.net`). And because the fiber API is
load-bearing for that whole tier, its design should be driven by **iterative
feedback from real IO use cases** (a concurrent HTTP fetch, a server accept
loop, piping between processes) rather than fixed up front — prototype against
those clients and let them shape `spawn`/`join`/channels (and whether `select`
is needed) before freezing the surface. The first such client has landed: the
accept loop in `std.net`'s tests drove `ParkRequest::Ready`'s retry-on-wake shape
(and, in passing, exposed that `io.copy` assumed writes never go short — true of
files, false of sockets). It also sharpened the case for **`select`**: a socket
has no timeout without it.

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
pub let INFINITY: Double; pub let NAN: Double;   // module initializers (no literal form)
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
number). `INFINITY`/`NAN` have no literal form, so they are **module
initializers** (`pub let`, computed once at load — [language.md](language.md));
they were the driving use case for that feature.

### `std.random` — randomness _(implemented)_

```
pub struct Rng { let state: Int; }   // seedable, state is a visible value
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
Algorithm: **SplitMix64**, now **pure Hawk** — both the state advance (a
wrapping add of the golden-ratio constant) and the bit-mixing finalizer (`^` /
`>>>` over the bitwise operators, which have since landed). Only
`from_entropy`'s seed is a native (it reads the system clock). Not
cryptographically secure.

### `std.sort` — sorting & extrema over `Ord` _(implemented, pure Hawk)_

Purpose: order a `List<T>` and pick extrema, generic over the `Ord` interface
(`Ord`/`Ordering` live in the prelude). Pure Hawk over `List.sort` and
`Ord.compare`.

```
pub fn sorted<T: Ord>(_ xs: List<T>) -> List<T>;        // ascending, stable
pub fn sorted_desc<T: Ord>(_ xs: List<T>) -> List<T>;   // descending
pub fn min<T: Ord>(_ xs: List<T>) -> Option<T>;         // None if empty
pub fn max<T: Ord>(_ xs: List<T>) -> Option<T>;
```

These are the `Ord`-driven counterparts to `List.sort(less)` (which takes an
explicit comparator); they work for any element type with an `impl Ord` (the
primitives included). Living in their own module keeps the common names
`sorted`/`min`/`max` qualified rather than in the prelude.

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
`Json` (Hawk has no heterogeneous map/list literal — a raw `['a': 1, 'b': true]`
is a `Map`, not a `Json`, and won't pass to `stringify`). The layers:

1. **Constructors (today):**
   `json.obj(['two': json.int(123), 'three': json.double(1.2)])` — container
   literals stay; only the leaves wrap.
2. **Auto-boxing (proposed — §Sequencing):** an expected-type-directed coercion
   that extends the existing implicit `Ok`-wrap to `Json`: where a `Json` is
   expected, a literal/primitive boxes into its variant (`Int`→`Json.Int`, a
   list literal→`Json.Array` recursively, a `String`-keyed map
   literal→`Json.Object`), so `let doc: Json = ['two': 123, 'three': 1.2]` just
   works. Encode-only; scoped to the blessed `Json` type. The most LLM-friendly
   for ad-hoc inline JSON.
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
JSON without manual wrapping. See § Sequencing #1.

**YAML/TOML/CSV are ecosystem** — this is where an agent looks first and finds
the pointer.

### `std.encoding` — base64 / hex / url _(implemented, pure Hawk)_

Flat functions on the one module. The binary codecs take/return `Bytes`; the URL
codec works on text. Decoding is fallible — malformed input is a `Result.Err`,
never a trap.

```
pub fn base64_encode(_ data: Bytes) -> String;          // RFC 4648, `+/`, `=`-padded
pub fn base64_decode(_ s: String) -> Result<Bytes, Error>;
pub fn hex_encode(_ data: Bytes) -> String;             // lowercase
pub fn hex_decode(_ s: String) -> Result<Bytes, Error>; // case-insensitive
pub fn url_encode(_ s: String) -> String;               // RFC 3986 percent-encoding
pub fn url_decode(_ s: String) -> Result<String, Error>;
```

Notes: pure Hawk over `Bytes`/`String` + the bitwise operators (no natives, no
lookup tables — an arithmetic char mapping keeps each codec self-contained).
base64 is the standard `+/` alphabet with `=` padding (decode rejects a bad
length, non-alphabet character, or misplaced padding). `url_encode` uses RFC
3986 _component_ encoding — the unreserved set `A-Z a-z 0-9 - _ . ~` passes
through, everything else is `%XX` (uppercase) of the UTF-8 bytes, so a space is
`%20` (**not** `+`); `url_decode` treats `+` literally (its inverse) and
validates the result is UTF-8. A URL-safe base64 (`-_`) variant is a candidate
addition.

### `std.hash` — common digests + checksum _(implemented, native)_

```
pub fn sha256(_ data: Bytes) -> Bytes;   // 32 bytes; the secure default
pub fn sha1(_ data: Bytes) -> Bytes;     // 20 bytes; legacy/checksum only
pub fn md5(_ data: Bytes) -> Bytes;      // 16 bytes; legacy/checksum only
pub fn crc32(_ data: Bytes) -> Int;      // CRC-32 (IEEE 802.3), 0..=2^32-1
```

Notes: enough for checksums and content addressing (common agent tasks); render
a digest with `std.encoding` (`hex_encode`/`base64_encode`). Full crypto
(signing, TLS primitives, AEAD) stays ecosystem.

**Backed by audited Rust crates, not reimplemented in Hawk** — hashing is
crypto-adjacent and wants battle-tested code: the RustCrypto `sha2` / `sha1` /
`md-5` crates and `crc32fast` (IEEE 802.3, the zip/gzip/PNG variant). These are
the **runtime's first external dependencies**, taken deliberately for this
best-of-breed case; the crate backing each function is named in its doc comment.
**Security:** `sha256` is the secure default; `sha1` and `md5` are broken for
collision resistance (checksums / legacy interop only); `crc32` is an integrity
checksum, not a hash.

### `std.http` / `std.http.server` — HTTP client + simple server

_Status: the **wire codec** and the **server** are implemented; the **client** and
TLS are not yet. `std.net` (provisional) carries both._

Purpose: make HTTP requests (the client) and answer them (a simple server). Both
are **core**; raw sockets and full server _frameworks_ stay ecosystem. Both
depend on `std.fiber` for concurrent, blocking-looking I/O (see § `std.fiber`
and § Sequencing), so this lands after the scheduler.

The **client** lives in `std.http`; the **simple server** is a sibling,
`std.http.server` (sharing `Request`/`Response`/`HttpError`, a separate import
so "the server is its own surface" stays explicit). Lightweight servers — a
webhook receiver, a local endpoint, a health check — are common enough in
agent/CLI tooling to deserve a built-in answer. **The line: bind + handle (a
handler function, plus a tiny built-in path matcher) is core; routing DSLs,
middleware stacks, and enterprise servers are ecosystem.** The server can land
**plaintext-HTTP/1.1 first** — a simple server's TLS is usually terminated
upstream (a reverse proxy), so it is _not_ gated on the client's TLS native and
can ship alongside or ahead of it. Its accept loop is also one of the real I/O
clients that should **drive** the `std.fiber` API design before that surface is
frozen (see § `std.fiber`).

```
pub struct Request { let method: String; let url: String;
                     let headers: Map<String, String>; let body: Bytes; }
pub struct Response { let status: Int; let headers: Map<String, String>; let body: Bytes; }

pub fn get(_ url: String, headers: Map<String, String> = [:]) -> Result<Response, HttpError>;
pub fn post(_ url: String, body: Bytes, headers: Map<String, String> = [:]) -> Result<Response, HttpError>;
pub fn send(_ request: Request) -> Result<Response, HttpError>;

impl Response {
    pub fn text(self) -> Result<String, Error>;
    pub fn json(self) -> Result<Json, Error>;
    pub fn is_ok(self) -> Bool;          // 2xx
}
pub enum HttpError { Connect(String), Timeout, Status(Int), Body(String),
                     Protocol(String) }   // implements Error
```

Notes: TLS is provided by a runtime native (not reimplemented in Hawk).
Streaming bodies use `std.io.Reader`.

**The simple server (`std.http.server`).** One fiber per connection over the
scheduler; the handler is an ordinary function returning a `Response`. Errors
are values — return a 4xx/5xx `Response`, or propagate an `Error` the server
renders as 500.

```
// A handler is `(Request) -> Result<Response, Error>`, written out at each use:
// Hawk has no type aliases, so there is no `Handler` name. And a *named* fn is
// not usable as a value today, so callers wrap: `serve(addr, (r) => handle(r))`
// — an implementation gap against language.md §Functions, tracked in roadmap.md.

pub fn serve(_ addr: String, _ handler: …) -> Result<Void, HttpError>;  // blocks; accept loop
pub fn serve_listener(_ listener: net.TcpListener, _ handler: …) -> Result<Void, HttpError>;
pub fn serve_connection(_ conn: net.TcpStream, _ handler: …) -> Void;

// Response constructors for the common cases. Free functions, since the client's
// `Response.text()`/`.json()` are *readers* (Hawk has no overloading), so
// building a Response is named distinctly from reading one.
pub fn text(_ status: Int, _ body: String) -> Response;
pub fn json(_ status: Int, _ value: Json) -> Response;
pub fn empty(_ status: Int) -> Response;             // a 204, or a 3xx whose `location` says it all

// A tiny built-in matcher (method + path) so a webhook / health-check needs no
// third-party router. Anything richer (path params, middleware) is ecosystem.
pub struct Router { let /* method+path table */; }
impl Router {
    pub fn new() -> Router;
    pub fn route(self, _ method: String, _ path: String, _ handler: …) -> Router;
    pub fn into_handler(self) -> …;           // fold the table into one handler for `serve`
}
pub fn path_of(_ url: String) -> String;      // `/a/b?q=1` -> `/a/b`
```

Notes: depends on `std.fiber` (accept loop + one fiber per connection) and the
same sockets as the client (`std.net`); plaintext-HTTP/1.1 first (TLS terminated
upstream), with a TLS-terminating variant a later add. The accept loop was a
named driver for the fiber API (§ `std.fiber`), and duly drove it.

As-built notes, none of them visible from the sketch above:

- **Keep-alive** is on by default, per HTTP/1.1; only an explicit `connection:
  close` ends a connection. An HTTP/1.0 client (whose default is the opposite) is
  safe under that rule anyway, because every response the codec writes carries a
  `content-length` — so a 1.0 client frames the response without waiting for EOF
  and just closes, which the serve loop reads as a clean end-of-stream.
- **`serve` cannot be stopped.** It blocks until bind or accept fails; stopping it
  needs cancellation, which needs `select` (§ Networking punchlist). This is why
  `serve_listener` exists — bind `:0`, read the port back, *then* serve — and it
  is what tests use.
- **The `Router` distinguishes 404 from 405.** A path that exists under another
  verb gets a 405 with an `allow` header rather than a 404: "no such thing" and
  "wrong verb" are different answers, and the distinction is worth the few lines
  even in a matcher this small. Routes match the path only — matching the query
  string would make every route depend on parameter order.
- **A malformed request gets a 400 and the connection closes** — once framing is
  untrustworthy there is no way to find the start of the next request. An
  over-long body is the exception the client can act on, and gets a 413.

### `std.log` — named, per-source logging _(implemented)_

Purpose: diagnostic logging good enough that a common CLI tool, agent, or
library never reaches for a third-party logger — while explicitly ceding the
industrial tier (high-throughput servers wanting sampling, routing, async sinks)
to purpose-built ecosystem infra. Two failures of the naïve "global logger with
one level" shape drive the design, both learned from Go/Rust/Python: a **single
coarse level toggle** is useless once one dependency is noisy, and **third-party
libraries emit on their own schedule** — into your output, at their own volume.
The answer all three languages converged on, and the shape here, is **named
loggers with per-source level filtering, behind a facade only the application
configures.**

```
pub enum Level { Debug, Info, Warn, Error }   // Trace addable

// The Logger a source-tagged logger hands back — all four levels as methods.
pub interface Logger {
    fn debug(self, _ msg: String) -> Void;   // + info / warn / error
}

// Ambient — the zero-ceremony form: log through the process logger (an empty
// source, gated only by the default level). `log.info('starting up')`.
pub fn debug(_ msg: String) -> Void;   // + info / warn
// `error` pending: a top-level `error` fn collides with the prelude `error()`
// constructor; until that rule is relaxed (tracked in roadmap.md), log an
// ambient error via `log.named('').error(...)`. Errors are methods on `Logger`,
// so a named logger already has all four levels.

// A source-tagged logger: `named(...)` tags records so levels tune per-source.
// A pure constructor, so one-per-module is the idiom:
//   let logger = log.named('myapp.db')    // an ordinary module-level `let`
pub fn named(_ name: String) -> Logger;

// A self-contained Logger you hold and pass — the capability form. Its own sink,
// level, and format; ignores the global config. Point it at a `StringWriter` to
// capture output in a test, or a file `Writer` to log elsewhere.
pub fn to_writer(_ name: String, _ sink: io.Writer, _ min_level: Level, _ format: Format) -> Logger;

// Would a record at `level` from `name` pass the global filter? Guards an
// expensive message before building it.
pub fn enabled(_ name: String, _ level: Level) -> Bool;

// Application-only configuration — call ONCE from `main`; a library MUST NOT.
pub enum Format { Text, Json }              // Text for a TTY; Json = one object per line, for machines
pub fn set_level(_ level: Level) -> Void;                        // default threshold (default Info)
pub fn set_level_for(_ prefix: String, _ level: Level) -> Void;  // per-source override
pub fn set_format(_ f: Format) -> Void;
pub fn configure_from_env(_ var: String = 'HAWK_LOG') -> Void;   // 'info,myapp.db=debug,http=warn'
```

**Per-source filtering is the headline** (the coarse-toggle fix). A record from
`log.named('http.client')` resolves its threshold by the most specific matching
prefix — `http.client`, then `http`, then the global default — so a noisy
dependency goes quiet with `set_level_for('http', Level.Warn)` (or
`HAWK_LOG=info,http=warn`, no recompile) while your own `myapp=debug` stays
loud. This is Python's hierarchical loggers / Rust's `RUST_LOG` + `EnvFilter`,
minus the ceremony. Reading the filter map from an **env var** is the key
ergonomic: what's noisy is _data, not code_, so tuning it never edits a source
file.

**The facade discipline** (the third-party-noise fix). Libraries call only
`log.named(...).info(...)` — they **emit, never configure**; the `set_*`
functions are application-only, called once at startup, and a library that calls
them is misbehaving (convention today — visibility can't yet enforce it, §
Sequencing #3). This is Rust's `log`-facade split (a library depends on the
facade; the binary picks the sink) and it's what stops a dependency hijacking
your output. Because the default sink is **stderr**, program output on stdout
stays clean — a library "logging" via `println` is exactly the bug std.log
removes.

**Reconciling with principle 7 (no hidden global state) — a deliberate, narrow
exception.** Principle 7 forbids swappable globals that are _sources of
nondeterminism read by program logic_ (clocks, randomness, env), where a
silently-swapped value changes what the program computes. Logging config is the
opposite: **write-only diagnostic output, set once by the application, never
read back into logic.** Threading a `Logger` through every call depth purely for
diagnostics is the wrong trade — which is why every capability-conscious
ecosystem (Rust included) still makes logging a global facade. So `std.log`
keeps ambient logging (the `info`/`warn`/`debug` free functions and
`named(...)`, § Cross-cutting #7's layer-1 form) plus **one sanctioned setter
surface** for its config: it is the single ambient with a setter, precisely
because its state is diagnostics, not logic. The **capability escape hatch**
still stands for code that wants it — `Logger` is an ordinary value, and
`to_writer` builds a self-contained one (own sink, own level, ignores the global
config) that a testable middle layer takes as a parameter (layer 2); point it at
a `StringWriter` and a test asserts on the emitted records with no global
override. That is the exception; for logging the global facade is the right
default.

**Structured fields — planned, sequenced after JSON auto-boxing.** Modern
practice (Go `slog`) is key-value records, not bare strings — valuable for an
agent-facing language whose logs are often re-parsed, and the `Json` format
already emits one object per line. But call-side fields
(`logger.info('query done', ['rows': 42, 'ms': 12])`) want the same
expected-type-directed auto-boxing JSON encoding needs (§ Sequencing #1) rather
than a second heterogeneous-map path; until that lands the message is a plain
interpolated string. Sequenced after it, not before.

**Implementation — pure Hawk, no natives.** Level resolution, prefix filtering,
and Text/JSON rendering (the JSON via `std.json`, so messages escape correctly)
are all Hawk. The mutable config is a Hawk global: `let config = Config { … }`
with `mut` fields — the binding is an immutable module initializer (computed
once), but the struct it points at mutates in place, so `set_level` etc. need no
mutable global or native cell. Output reuses `std.io`: the ambient logger writes
through `io.stderr()` and _discards_ the `Result` (so a broken stderr pipe drops
the record rather than trapping — logging never crashes its caller), the same
path the `to_writer` sink takes. (Landing this drove the front-end fix that
infers an un-annotated module global's type from its initializer — see
[roadmap.md](roadmap.md) changelog; before it, `config`'s type was `Unknown` and
member access failed in codegen.) A _global_ `set_output` to redirect the
ambient sink to an arbitrary `Writer` is deferred — it would mean holding a Hawk
value in the config as a GC root — and `to_writer` already covers the
custom-sink and capture cases.

**Out of scope → ecosystem / DIY** (the industrial tier): async / non-blocking
sinks, sampling and rate-limiting, log rotation, multi-destination routing,
network / syslog / journald sinks, and span / trace correlation. Core stops at
named loggers + per-source filtering + text/JSON on stderr; a server that
outgrows that builds or brings its own.

### `std.cli` — argument parsing _(implemented, pure Hawk)_

Purpose: declarative CLI parsing with subcommands, typed options, and a
generated `--help`. The richer `Command` builder sits alongside the thin
`std.cli/args` (`Args`), which stays for raw access. **Implemented entirely in
Hawk** (`sdk/std/cli/command.hawk`).

```
pub struct Command { name, about, flags, options, positionals, subcommands }   // field types elided
impl Command {
    pub fn new(_ name: String) -> Command;                  // auto-registers --help/-h
    pub fn about(self, _ text: String) -> Command;
    pub fn flag(self, _ name: String, help = '', abbr = '',
                negatable = false, default = false) -> Command;   // Bool
    pub fn option(self, _ name: String, help = '', abbr = '') -> Command;  // String
    pub fn positional(self, _ name: String, help = '') -> Command;
    pub fn subcommand(self, _ cmd: Command) -> Command;
    pub fn parse(self, _ args: List<String>) -> Result<Matches, CliError>;
    pub fn run(self, _ argv: List<String>) -> Action;       // opinionated entry adapter
    pub fn help(self) -> String;                            // generated usage text
    pub fn help_for(self, _ name: String) -> String;        // a subcommand's help
}
pub struct Matches { let /* typed accessors */; }
impl Matches {
    pub fn flag(self, _ name: String) -> Bool;              // resolves negation + default
    pub fn option(self, _ name: String) -> Option<String>;
    pub fn positional(self, _ index: Int) -> Option<String>;
    pub fn positionals(self) -> List<String>;
    pub fn subcommand(self) -> Option<String>;              // selected subcommand
    pub fn matches(self) -> Option<Matches>;                // its parsed Matches
    pub fn selected(self) -> Option<Selection>;             // the two together
}
pub struct Selection { let name: String; let matches: Matches; }
pub enum Action { Proceed(Matches), Exit(Int) }             // run's outcome

pub struct CliError { let /* kind + command path */; }
impl CliError {
    pub fn kind(self) -> CliErrorKind;                      // the cause (matchable)
    pub fn command_path(self) -> List<String>;              // where it failed ([] = root)
}
pub enum CliErrorKind { UnknownFlag(String), MissingValue(String),
                        UnexpectedValue(String), UnknownSubcommand(String) }
```

Names are declared **bare** (`flag('verbose')`); the parser accepts the long
form (`--verbose`), abbreviations (`-v`), `--name value` / `--name=value` for
options, and `--no-name` for `negatable` flags. `--help`/`-h` is auto-registered
but never auto-intercepted by `parse` — the caller (or `run`) decides when to
print help. `CliError` implements `Error` + `Display`, so it propagates as
`Result<_, Error>` and renders directly while callers who want the cause still
`match` on `.kind()`.

**The `run` entry adapter.** `parse` is the mechanism; `run` is the opinionated
policy that collapses the glue every multi-command client used to re-implement.
One call parses `argv` and: on a parse error prints `name: <message>` and the
**failing** (sub)command's help to stderr → `Exit(2)` (command-path-aware, via
`CliError.command_path`); on `--help` prints the selected (sub)command's help to
stdout → `Exit(0)`; on a bare no-command invocation of a command that has
subcommands prints help to stderr → `Exit(1)`; otherwise `Proceed(matches)`, and
the client dispatches, typically `match matches.selected() { Some(sel) => … }`.
A client wanting a different stdout/stderr or exit-code policy uses `parse`
directly. `pkgs/cli/main.hawk` is the reference client — its `main` is now the
adapter plus a subcommand switch (the ~40 lines of parse/help/error glue are
gone).

**Still deferred.** Short-flag clustering (`-rf` → `-r -f`) — a "remove a
decision" win, not a blocker.

### `std.term` — terminal _(implemented)_

```
pub fn is_tty() -> Bool;                   // is stdout an interactive terminal?
pub fn size() -> Option<TermSize>;         // None when stdout is not a terminal
pub struct TermSize { let cols: Int; let rows: Int; }

pub fn style(_ text: String, color: Color, bold: Bool = false) -> String;  // ANSI, TTY-gated
pub fn paint(_ text: String, color: Color, bold: Bool = false) -> String;  // ANSI, always
pub enum Color { Black, Red, Green, Yellow, Blue, Magenta, Cyan, White, Default }
```

Notes: `style` no-ops (returns `text` unchanged) when `!is_tty()`, so piped
output stays clean; `paint` is the pure primitive that always emits the codes
(for a forced `--color=always`, or building a string you gate yourself). Since
tuples aren't in the language, `size` returns a small `TermSize` struct rather
than an `(Int, Int)` — the same call as `List.enumerate`'s `Indexed`. `is_tty`
rides on Rust's `std::io::IsTerminal`; `size` is the runtime's **3rd deliberate
dependency** (`terminal_size`, portable across unix + windows). The `term_size`
native returns the raw `[cols, rows]` pair and the Hawk layer assembles
`TermSize`, so the native never hardcodes a struct type-id (the `std.regex`
ABI).

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

### `std.regex` — regular expressions _(implemented)_

> **Status: implemented** (the runtime's **2nd deliberate dependency**, after
> `std.hash`). Backed by the Rust team's `regex` crate (RE2-derived) — the same
> "take a vetted, best-of-breed crate" call. A compiled pattern lives in a
> runtime-held registry (the `std.process` handle pattern); Hawk holds an opaque
> `Int` handle inside `Regex`. The earlier pure-Hawk version over `re2_*`
> natives that didn't survive the runtime migration has been replaced wholesale.

Compile a pattern once, then match / find / capture / replace against Unicode
text. RE2 syntax (linear-time, no backtracking / lookaround) — see
<https://github.com/google/re2/wiki/Syntax>. Offsets in `Match` are **UTF-8 byte
positions** (the string-offset convention, principle 8); slice them out with the
companion `String.byte_slice`.

```
pub struct Regex { let /* opaque handle to the compiled pattern */; }
impl Regex {
    pub fn compile(_ pattern: String) -> Result<Regex, RegexError>;  // invalid pattern -> Err
    pub fn is_match(self, _ text: String) -> Bool;
    pub fn find(self, _ text: String) -> Option<Match>;              // first match
    pub fn find_all(self, _ text: String) -> List<Match>;           // all, non-overlapping
    pub fn captures(self, _ text: String) -> Option<Captures>;       // first match + groups
    pub fn replace(self, _ text: String, with replacement: String) -> String;     // first
    pub fn replace_all(self, _ text: String, with replacement: String) -> String; // all
}

pub struct Match { let text: String; let start: Int; let end: Int; }   // start inclusive, end exclusive (bytes)

pub struct Captures { let /* groups: List<Option<String>> */; }
impl Captures {
    pub fn text(self) -> Option<String>;                 // group 0 (the whole match)
    pub fn group(self, _ index: Int) -> Option<String>;  // None if absent / didn't participate
    pub fn len(self) -> Int;                             // group count, including group 0
}

pub enum RegexError { Syntax(String) }   // implements Error + Display (mirrors JsonError)
```

Group 0 is the full match, `1..` the numbered subgroups; a group that did not
participate is `None`. Replacements expand `$1` / `$name`; **note** the braced
`${1}` form collides with Hawk's own `${…}` string interpolation, so use the
bare `$1` form in a Hawk literal. A compile syntax error is a
`RegexError.Syntax` (principle 4), as `std.json` does. The compiled handle is
module-private. (The ABI: natives return byte-offset `List<Int>`s and the Hawk
layer assembles `Match`/`Captures` via `String.byte_slice` — so the natives
never hardcode a struct type-id.)

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
  into core if real use cases pile up. Pivot when the demand is demonstrated,
  not speculatively.
- **HTTP server _frameworks_ (routing DSLs, middleware stacks), raw TCP/UDP
  sockets** → ecosystem. The HTTP _client_ and a _simple_ server (`std.http` /
  `std.http.server` — bind + handle + a tiny path matcher) **are core**; see §
  `std.http`.

  A **provisional** `std.net` does exist — TCP `listen`/`accept`/`connect` plus a
  `TcpStream` that is a `Reader`+`Writer`+`Closer` — but only as the layer
  `std.http` is built on, and only as much of it as HTTP needs (no UDP, no
  deadlines, no half-close, no socket options, no TLS). It is documented in its
  own module header as expected to change, and is **not** a committed surface:
  treat it as internal until this entry says otherwise. Promoting it is the
  natural pivot if the demand shows up — and the demand to watch for is specific,
  because natives are bound by name in the runtime with **no FFI path for
  third-party packages**: until `std.net` is committed, "other network protocols
  → ecosystem" is aspirational, since nobody outside this repo can build a
  WebSocket, Redis, or Postgres client without it. The first real non-HTTP
  protocol need is the forcing function; the same "pivot when demonstrated, not
  speculatively" rule as TOML above applies.
- **Databases / SQLite** → ecosystem.
- **Full cryptography / TLS primitives, signing** → ecosystem (digests +
  randomness are core; TLS for `http` is a runtime native).
- **Compression (gzip/zip/tar)** → ecosystem.
- **Time zones / locale formatting** → ecosystem (UTC + RFC 3339 are core).
- **UUID, templating, terminal UI** → ecosystem.

## Sequencing & dependencies

This design leans on language features not all of which exist yet — this is the
forward-looking dependency graph, so future work lands in the right order. The
big early unblockers have all **landed** and no longer gate anything: the
generics arc (interface-typed values + dynamic dispatch, so `io.copy`, the
`Error` interface as a return type, and `<T: Eq + Debug>` bounds all work), the
`Bytes` core type with the `Reader`/`Writer`/`Seek` interfaces, the lazy
`Iterator<T>` protocol (the v1 interface + the v2 adapters/consumers as default
methods), the `Error` interface migration, and top-level `const` codegen. What
remains:

1. **JSON encoding ergonomics.** Two independent improvements over the
   constructors (`json.obj`/`json.int`/…) that ship today, for the two distinct
   use cases — building ad-hoc inline JSON, and serializing typed data:
   - **Auto-boxing into `Json` (proposed; smaller).** Extend the existing
     expected-type-directed boxing — the implicit `Ok`-wrap (`return n` →
     `Ok(n)`) — to the blessed `Json` type. **Rule:** when the expected type is
     exactly `Json`, an expression whose type is `Int`/`Double`/`String`/`Bool`
     boxes into the matching variant; a **list literal** elaborates each element
     against `Json` and boxes to `Json.Array`; a **`String`-keyed map literal**
     boxes its values to `Json.Object`. So
     `let doc: Json = ['two': 123, 'tags': ['a', 'b'], 'ok': true]` works.
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

2. **`std.http`.** The clock, entropy, hash, and scheduler natives have all
   landed (`std.time`, `std.random`, `std.hash`, and `std.fiber`'s
   `spawn`/`join`/`yield` + channels), and so has the parking this tier waited
   on: `std.time`'s `sleep` and the blocking `fs`/`process` syscalls park on a
   worker pool, and **sockets park on a readiness poller** (roadmap phase 4), so
   blocking-looking socket I/O is now genuinely "invisible" (principle #5). The
   provisional `std.net` sits on top of that.

   What remains is **`std.http`** itself (client + simple server, both committed
   to core). The order to build it in, and why:
   - **The wire codec first** — `Request`/`Response`, status codes, and HTTP/1.1
     framing (`Content-Length`, chunked). Pure Hawk over `io.Reader`/`Writer`, so
     it unit-tests against `Bytes`/`StringWriter` with no sockets at all.
   - **Then the server**, which is not gated on TLS (terminated upstream) and
     writes the harder half of that codec — parsing an untrusted request is
     strictly harder than serializing one. Its accept loop is also the named
     driver for the fiber API (§ `std.fiber`).
   - **Then the plaintext client**, which is the codec's mirror image and can be
     tested hermetically against the server in-process (spawn a listener fiber,
     fetch from it, join) — a loop that only exists in this order.
   - **Then TLS**, the separable increment, and the only part needing a new
     runtime native.

   Layout: `std.http` is the **client** plus the public types, as a barrel over
   private `wire`/`client` siblings (the `std.core` pattern); `std.http.server`
   imports the `wire` sibling directly, so it never pulls in the client or TLS.
   `wire` is the shared third library — it just isn't a third public name, since
   the namespace is the last dotted segment and `http.get(url)` should stay the
   spelling of the most-written line in the surface.

   One correction to the sketch in § `std.http` above: `headers: Map<String,
   String>` models neither the case-insensitivity of header names nor the headers
   that legitimately repeat. Rather than grow a bespoke header type, **normalize**
   to what `Map` represents well — lowercase names on parse, repeats comma-joined
   — and document it. (`Set-Cookie` is the one header that cannot be comma-joined;
   it needs a carve-out.)

3. **Visibility enforcement** ([language.md](language.md)). Some modules (e.g.
   `std.process`) have native bindings that should be module-private; today the
   language can't enforce it. Tighten when visibility lands.
