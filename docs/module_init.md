# Module initializers

**What this is:** the design for **module-level variables** — top-level `let`
bindings whose initializer runs once, at load, into a stored global slot — and
the **module initializer** that evaluates them. It is the principled replacement
for "there is no load-time init," which several stdlib items are blocked on. For
the language surface see [language.md](language.md); for the stdlib items this
unblocks see [stdlib.md](stdlib.md); for the runtime/bytecode mechanics see
[bytecode.md](bytecode.md).

> **Status: design (not yet implemented).** Today top-level `const` **inlines**
> its initializer at every use site (codegen has no global storage), so a
> computed `const TABLE = build()` rebuilds the table per reference. There is no
> mechanism to compute a value once and store it. This doc specifies one. Tracked
> in [roadmap.md](roadmap.md).

## Motivation

A handful of real, already-hit items have one shared root cause — **no way to
compute a value once and keep it**:

- **Lookup tables.** `std.hash`'s CRC32 table (256 entries) and
  `std.encoding`'s base64 alphabet/decode tables want to be built once. With
  `const` they would be **rebuilt at every use site** (the inlining footgun); a
  module-level `let` builds them once.
- **`std.math` `INFINITY` / `NAN`** — no literal form, can't be a `const`.
- **`std.path` platform separator** — a runtime/platform value, can't be a
  compile-time `const`.
- **Derived constants** — `TAU = 2 * PI` should be stored, not recomputed.
- **Front-end dogfood** — a top-level keyword `Map` for the lexer's
  `keyword_kind` (it can't be a `const` today, for the same inlining reason).

The feature is small in mechanism and pays for itself in code we are about to
write (`std.encoding`, `std.hash`).

## Surface

A top-level **immutable** binding with a runtime-computed initializer:

```hawk
let CRC32_TABLE: List<Int> = build_crc32_table();   // computed once, stored
let TAU: Double = 2.0 * math.PI;                     // derived from another global
```

Two deliberate restrictions:

1. **Immutable only.** There is **no** top-level `let mut`. Swappable global
   state is exactly what the stdlib's "no hidden global state" principle forbids
   (see [stdlib.md](stdlib.md) §Cross-cutting #7); mutable module config stays a
   **capability value** you hold and pass (`time.Clock`, `env.Env`, a future
   `log.Logger`), never a module global. See § Tension.
2. **`const` vs `let` — a two-tier story.**
   - **`const`** is a *manifest* constant: its initializer must be compile-time
     evaluable, and it is **inlined** at use sites (today's behavior, no
     storage). A computed initializer (`const TABLE = build()`) should become a
     **compile error** that points at `let`.
   - **module `let`** is *computed once at load* and **stored** in a global slot,
     referenced by index.

## Which initializer expressions

The mechanics are easy; the **policy on what an initializer may do** is the design
decision, because Hawk has no effect system to enforce purity precisely. The rule:

- **Pure expressions** — literals, arithmetic, string ops, calls to pure Hawk
  functions, and **pure natives** (a deterministic `path_separator()`, a math
  constant) — are the target. Zero tension.
- **Time-varying effects** — `time.now()`, `fs.read_*`, sockets — are
  **forbidden in initializers**. They would capture a stale, hidden snapshot at
  an unpredictable load-time moment.

Because there is no effect system, this is enforced by **convention plus a cheap
denylist**: the checker rejects calls to a small set of known time-varying
natives from initializer position. That catches the worst footguns without a full
purity analysis. (A real effect/purity system, if it ever lands, would subsume
the denylist.)

Process-stable ambient values (the OS, the path separator) are the one genuinely
useful "effectful" case — but they are *constant for the process lifetime*, so
they are modeled as **pure-per-run natives** and allowed.

## When it runs — eager, topological, cycles are errors

The whole import closure links into one `.hawkbc`, and the linker has the full
import DAG, so initialization is resolved at **compile/link time**, not at
runtime:

- **Eager and topological.** Initializers run once, before `main`, in dependency
  order: `std.core` (the prelude) first, then imported modules in topological
  order, then the entry module, then `main()`.
- **Within a module**, globals are ordered by their own dependency DAG (a later
  global may reference an earlier one; the linker reorders).
- **An initializer-dependency cycle is a compile error** — located precisely,
  the way Hawk diagnoses rather than guesses. This is *distinct* from an import
  cycle, which stays legal as long as the modules' **initializers** don't form a
  cycle.

This choice keeps the runtime simple: because order is fixed at link time, a
global access is a plain slot read — there is **no per-access "is it initialized
yet" guard** (the cost a lazy, on-first-use scheme like Dart's would pay), and no
static-init-order fiasco (the cost an unordered eager scheme like C++'s pays).

## Implementation

### Front-end

- **Parser** — accept top-level `let NAME[: Type] = expr;` (reject top-level
  `let mut`).
- **Resolver / checker** — a module-level `let` introduces a global binding
  (type from annotation or inferred from the initializer); references (bare and
  `ns.NAME`) resolve to a global slot. Reject computed `const`; reject
  denylisted effectful calls in initializer position; reject initializer
  cycles.
- **Codegen / linker** — assign each module `let` a global slot index; compile a
  reference to `global.get <idx>`; emit a single **program-init thunk** that, in
  the resolved topological order, evaluates each initializer and `global.set`s
  its slot.

Because Hawk links everything into one artifact, a single program-init thunk is
simpler than per-module init bookkeeping in the bytecode.

### Runtime / bytecode

- **A globals vector**, sized from a new `global_count` in the module header.
- **Two opcodes:** `global.get <u32>` and `global.set <u32>` (`set` only emitted
  inside the init thunk). See [bytecode.md](bytecode.md).
- **Load order:** allocate the globals vector → run the program-init thunk → run
  the entry (`main`).
- **GC:** the globals vector is a new permanent **root set** (today the roots are
  the frame stack).

### Self-hosting

This is a codegen change, so it needs the usual **two-cycle fixpoint reconverge**
(the bootstrap snapshot compiles the new front-end, which must re-emit itself
byte-for-byte). The front-end may then *use* module `let` itself (the keyword
map), which is a clean dogfood of the feature.

## Tension with "no hidden global state"

Principle 7 ([stdlib.md](stdlib.md) §Cross-cutting) forbids **swappable,
effectful** global state — a global you can reassign to inject a fake, a hidden
effectful input a signature doesn't reveal. Module initializers do **not**
reintroduce that, provided they stay immutable. The tension is a spectrum:

| Initializer | Tension | Verdict |
| ----------- | ------- | ------- |
| Immutable + **pure** (literals, tables, derived constants) | None — it is "`const`, computed once." | ✅ the target |
| Immutable + **process-stable ambient** (OS, separator) | Mild — captured once, constant for the run. | ✅ allow deliberately |
| Immutable + **time-varying effect** (clock, fs, net at load) | Real — a stale, hidden, load-time snapshot. | ❌ forbid (denylist) |
| **Mutable** module globals (`let mut`) | Direct conflict — the swappable global #7 exists to forbid. | ❌ not supported |

The decisive point: **immutable globals are not swappable**, so they can't be the
"mutate a global to fake it" seam, and the only residual risk is the
*initializer's* effects — handled by keeping initializers pure (denylist).

This sharpens, rather than weakens, the principle, and it resolves the `std.log`
question (see [stdlib.md](stdlib.md) §`std.log`): module-init does **not** bless a
log singleton, because logging wants *mutable* swappable level/output — the
forbidden quadrant. Logging stays a capability value (`Logger`). The line:
**computed-once immutable globals → module `let`; swappable config → capability
value.**

## Phasing

- **Phase 1.** Immutable module `let`, pure initializers (Hawk functions + pure
  natives), eager topo init, dependency-cycle = compile error, tighten `const` to
  manifest constants. Unlocks tables (`std.encoding`/`std.hash`),
  `INFINITY`/`NAN`, derived constants, the keyword map.
- **Phase 2 (if needed).** A narrow, deliberate allowance for process-stable
  ambient natives (the path separator), provided as pure-per-run natives.
- **Out of scope, by design.** Mutable module globals — swappable config stays
  capability-valued.
