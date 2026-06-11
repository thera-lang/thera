# Testability & ambient capabilities

**What this is:** how Hawk's standard library lets you test code that depends on
ambient, nondeterministic state — the wall clock, the filesystem, the
environment, randomness — without global overrides or a parallel "test"
universe. It resolves a question principle 7 of [stdlib.md](stdlib.md) left
open: do we ship a top-level `now()` _or_ a `Clock` interface? The answer is
**both, in layers** — and the same shape applies to every ambient capability.

## The problem

Code that reads the clock, the filesystem, or the environment is hard to test:
the output depends on state the test can't control. Three common "fixes" each
have a failure mode Hawk wants to avoid:

1. **Global overrides** (a swappable `IOOverrides`-style singleton). A test
   mutates a hidden global and the code under test silently behaves differently.
   The seam is invisible in every signature — spooky action at a distance, and
   the canonical design smell. **Rejected.**

2. **Capability everywhere** (all code calls a `Clock` object instead of the
   system clock). Testable, but it taxes _every_ function with ceremony and
   forces the whole program to route around the natural stdlib call. The
   over-correction.

3. **Parallel reimplementations** (a separate in-memory filesystem package each
   project rewrites). High value, but everyone pays to build it again.

## The model: ambient default + opt-in capability

Each ambient capability is exposed at **two layers**, and the key invariant ties
them together:

> The free function **is** the system implementation of the capability, called
> ambiently. `time.now_millis()` ≡ `time.system_clock().now_millis()`.

- **Ambient free function** — `time.now_millis()`, `fs.read_text(path)`. Always
  performs the real effect. **No override hook.** This is not a smell precisely
  _because_ it can't be swapped: it's an honest, clearly-named effect you keep
  in the imperative shell (`main`, scripts, the top of a request handler).

- **Capability interface** — `time.Clock`, `fs.FileSystem`. A _value you hold
  and pass explicitly_, for the slice of logic that needs the effect threaded
  through it and that you want to test deterministically. `system_clock()` /
  `system_fs()` return the real one; a test substitutes a fake.

Crucially, the test seam is a **different, explicit path** (pass a capability),
never an override of the free function. There is no hidden global and nothing is
swapped out from under you.

### Most code should take neither

The deepest layer of [the functional core](guidelines.md#L92) reads no ambient
state at all. A function that formats a log line should **take a `DateTime`**,
not take a `Clock` and read it; a parser should **take the `String`**, not a
`FileSystem` and a path. The seam there is "pass the data in." The capability
interface is for the _orchestrating middle layer_ — the code that's still worth
unit-testing but genuinely needs to ask "what time is it?" / "what's on disk?".

So on any given call you aren't choosing between two competing APIs. You're
choosing **where in the program the effect lives**:

| Layer                  | Time                      | What it takes                  |
| ---------------------- | ------------------------- | ------------------------------ |
| Imperative shell       | `time.now_millis()`       | nothing — reads the real clock |
| Testable orchestration | `fn run(clock: Clock)`    | a `Clock` capability, threaded |
| Functional core        | `fn format(at: DateTime)` | plain data — no clock at all   |

## The asymmetry is principled

Different capabilities make a _different layer_ the default, and that's
deliberate — the default form matches what the common case actually wants, while
the alternative is always a value you pass (never a global you override):

| Capability     | Default form                           | Why                                                                                                       |
| -------------- | -------------------------------------- | --------------------------------------------------------------------------------------------------------- |
| **Random**     | `Rng` value you hold (no ambient form) | reproducibility is almost always wanted → the seedable value _is_ the common case                         |
| **Time**       | ambient `now_millis()`                 | ~95% of reads are "stamp this / measure elapsed" where the real clock is exactly right; `Clock` is opt-in |
| **Filesystem** | ambient `fs.read_text`                 | same — the real FS is the common case; `FileSystem` is opt-in                                             |
| **Env**        | ambient `env.get`                      | reads of the real environment dominate; an `Env` capability is opt-in                                     |

`random` has _no_ ambient form on purpose: an unseeded global RNG would be the
one case where the convenient default is the untestable, irreproducible one.

## Where the test doubles live

Split by usefulness:

- **Doubles that are also useful in production live beside their real library.**
  An in-memory `fs.MemoryFileSystem` is genuinely useful for sandboxing, caches,
  and testing your own tooling — not test-only — so it ships in `std.fs`
  alongside `system_fs()`.

- **Doubles that are almost purely a test affordance live in `std.testing`.** A
  frozen `testing.fixed_clock(millis)` (and later an advanceable clock) is hard
  to justify outside a test, so it lives in `std.testing`, which already depends
  on the rest of the stdlib.

The capability **interface** always lives with its real library (`time.Clock`,
`fs.FileSystem`); only the fake's _location_ varies.

## No capability bundle in the stdlib

For a deep call tree, threading `clock`, `fs`, and `env` separately is some
noise. The stdlib deliberately does **not** ship a blessed `Sys`/`Context`
struct bundling them: a bundle is one step from an ambient god-object, and which
capabilities to group is application-specific. Apps that want one define their
own context struct and thread it; the stdlib stays unopinionated and exposes
each capability as an independent interface.

## Worked example: `std.time` (the prototype)

The smallest real instance, implemented and tested:

```hawk
// std.time
@extern('time_now_millis')
pub native fn now_millis() -> Int          // the ambient effect (real clock)

pub interface Clock {                       // the capability
    fn now_millis(self) -> Int
}

type SystemClock = {}
impl Clock for SystemClock {
    fn now_millis(self) -> Int { return now_millis(); }
}
pub fn system_clock() -> Clock { return SystemClock {}; }
```

```hawk
// std.testing — the test double (test-only, so it lives here)
type FixedClock = { millis: Int }
impl Clock for FixedClock {
    fn now_millis(self) -> Int { return self.millis; }
}
pub fn fixed_clock(_ millis: Int) -> Clock { return FixedClock { millis: millis }; }
```

```hawk
// Testable logic takes the capability; the shell passes the real one,
// the test passes a fixed one.
fn deadline_passed(_ clock: Clock, _ deadline_millis: Int) -> Bool {
    return clock.now_millis() >= deadline_millis;
}

@test
fn test_logic_under_a_fixed_clock() -> Result<Void, Error> {
    let clock = testing.fixed_clock(500);
    testing.assert(deadline_passed(clock, 400))?;
    testing.assert(!deadline_passed(clock, 600))?;
    return Result.Ok(void);
}
```

This relies entirely on the interface-typed parameters + dynamic dispatch from
the [interfaces arc](interfaces.md): the `Clock` parameter dispatches through
`call.virtual` to whichever implementation was passed, including across module
boundaries (the `FixedClock` impl in `std.testing` conforms to the `Clock`
interface declared in `std.time`).

## Qualified type references

Type and interface names can be written **qualified**, matching the value-side
`ns.member` syntax: `fn run(c: time.Clock)`, `impl time.Clock for FixedClock`,
`fn pool() -> col.List<Int>`. The bare form (`Clock`) still works — imported
types share one flat namespace, so the qualifier is resolved by its base name
and carried for the author's sake (it is _not_ yet validated against the
import's actual exports; that waits on a per-namespace type table).

## Rollout

The pattern, capability by capability (all gated on the interface arc, now
done):

- **`time.Clock`** — done (the prototype above). Next: a real `DateTime`/
  `Instant`/`Duration` surface (see [stdlib.md](stdlib.md) `std.time`), and an
  advanceable test clock in `std.testing`.
- **`env.Env`** — done. An `Env` capability (`get` + `args`) over the `std.env`
  free functions, with `system_env()` and a map-backed `testing.fixed_env`. The
  second instance of the pattern; confirms it generalizes past `Clock`.
- **`fs.FileSystem`** — interface over the `std.fs` operations, `system_fs()`,
  and a `MemoryFileSystem` shipped in `std.fs`. The highest-value instance: it
  retires the "everyone reimplements an in-memory FS" problem.

In every case the ambient free functions stay as the default; the interface is
the opt-in seam; the free function remains the system implementation.
