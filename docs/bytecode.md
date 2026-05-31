# Hawk Bytecode (rough spec)

Status: **draft / iterate as we go.** This describes the first cut of Hawk's
bytecode — the stable IR that the frontend emits, the interpreter runs, and the
Cranelift JIT lowers from. See `docs/plan.md` → "The bytecode: our own,
stack-based" for the motivating rationale.

## Design priorities

In order (per the project's stated criteria):

1. **Simplicity of implementation** — the Tier-0 interpreter should be a small,
   obvious dispatch loop.
2. **Simplicity of targeting** — easy to emit from the Hawk frontend, and easy
   to lower to Cranelift IR.
3. **Performance** — fast enough to run real CLI work in the interpreter, and a
   clean path to native code for hot functions.

A few consequences fall out of these directly:

- **Stack-based.** No register allocation in the frontend; trivial interpreter.
- **Typed and untagged.** Each instruction knows the type it operates on
  (`add.i64` vs `add.f64`). Operand-stack slots carry no runtime tag. This is
  what lets the JIT do straight-line typed lowering with no guards or deopt, and
  what keeps the on-disk format compact. The cost is that the GC needs
  _stackmaps_ to find roots (see [GC](#garbage-collection)) — deferred until we
  actually have a GC.
- **Reducible control flow by construction.** Control flow is flat (jumps to
  byte offsets), but because it is only ever emitted from Hawk's structured
  constructs (`if`/`for`/`match`/`?`), the resulting CFG is always reducible —
  which is what makes SSA reconstruction in the JIT tractable. This is a
  documented _invariant the frontend must uphold_, not something the format
  enforces yet.

## Value model

One value = one **64-bit slot** on the operand stack and in the locals array.

| Hawk type          | Slot contents                                | Ref? |
| ------------------ | -------------------------------------------- | ---- |
| `Int`              | i64                                          | no   |
| `Double`           | f64 (bit-pattern in the slot)                | no   |
| `Bool`             | i64, 0 or 1                                  | no   |
| `Void` / `()`      | _no slot_ — produces and consumes nothing    | —    |
| `String`           | pointer to heap object                       | yes  |
| `List`/`Map`/`Set` | pointer to heap object                       | yes  |
| struct             | pointer to heap object                       | yes  |
| enum (`Result`, …) | pointer to heap object (tag word + payload)  | yes  |
| closure / fn value | pointer to heap object (code ptr + captures) | yes  |

Uniform slot width keeps the interpreter and the stackmap scheme simple. Whether
a slot is a reference is **statically known** at every program point from the
types the frontend tracked, so we never tag values at runtime.

**Heap objects have reference semantics.** A slot that holds a pointer is a
*shared* reference to a heap object (String, List, Map, Set, struct, enum,
closure); copying the slot copies the pointer, not the object. Immutability is
enforced by the type system (`let` bindings, immutable struct fields), not by
copying — so two bindings to the same `mut` collection observe each other's
mutations. This is the Dart/Python model, chosen over Swift-style value
semantics for implementation simplicity.

> **Bootstrapping decision:** the _durable_ design is untagged (above) — a
> tagged `Value` enum defeats the typed-JIT rationale and bloats the format. But
> the **first** Tier-0 interpreter will deliberately start with a tagged `Value`
> enum: simpler to stand up and debug, and it sidesteps stackmaps before the GC
> exists. We refactor to untagged slots once the ISA stabilizes. The bytecode
> format itself stays untagged either way — only the interpreter's in-memory
> value differs.

## The first interpreter (Tier 0): nailed-down decisions

These pin down the draft interpreter so it can be built without guessing. They
describe the *first cut*, not permanent constraints.

- **Bytecode representation:** the draft runs an in-memory Rust
  `enum Instruction` (a `Vec<Instruction>` per function), **not** the serialized
  byte format. This defers all encoding questions (fixed-width vs. LEB128,
  operand widths) until there is a frontend emitting bytecode.
- **Tagged `Value` with a `Unit` variant:** `Int(i64)`, `Double(f64)`,
  `Bool(bool)`, `Unit`, and a `Ref` to a heap object. `Unit` represents
  `Void`/`()`, so every call yields exactly one stack value and the dispatch
  loop has no "did this push or not" special-casing.
- **Heap objects:** shared references (see reference semantics above). The draft
  may use `Rc<RefCell<…>>`; the eventual GC replaces this with a managed heap.
- **Calling convention:** the caller pushes args left-to-right; `call` moves the
  top `argc` slots into the callee's `locals[0..argc]`; the callee's return
  value is pushed onto the caller's operand stack (a `Void` function pushes
  `Unit`).
- **Equality** (`==`, `Eq`) is **structural** for strings, structs, enums, and
  collections — by content, never by identity.
- **Integer overflow wraps** (two's complement). Not a trap. Divide-by-zero
  still traps. `/` and `%` follow Rust i64 semantics (truncate toward zero).
- **Intrinsics:** `call.native <index>` resolves against a small Rust function
  table. The draft ships `println`, a primitive-stringify helper (for `${int}`
  etc.), and `str_concat` (for interpolation) — enough to write observable test
  programs without a stdlib.
- **Enum tag numbering is fixed:** `Result` → `Ok = 0`, `Err = 1`; `Option` →
  `Some = 0`, `None = 1`. Hand-written bytecode, the `?`/`match` lowering, and
  the future frontend must all agree on this.
- **Scope of the first draft:** `Int`/`Double`/`Bool`/`Unit`, locals,
  arithmetic/comparison, control flow, direct `call` + `return`, enums (so
  `Result`/`Option`/`match`/`?` work), and `println`. **Deferred:** collections,
  closures, interface dispatch, string methods, GC, fibers, and the JIT.

## Container format (a compiled module)

A module is the durable artifact. Rough shape (encoding TBD — likely a simple
length-prefixed binary; could start as a Rust enum tree / `bincode` for the
POC):

```
Module
  constants   : [Const]        // i64, f64, and string literals
  types       : [TypeDef]      // struct + enum layouts
  functions   : [Function]
  globals?    : [Global]       // deferred; CLI code mostly needs none
  entry       : FuncRef        // main

TypeDef
  Struct { fields: [SlotKind] }            // SlotKind tells GC which are refs
  Enum   { variants: [[SlotKind]] }        // payload layout per variant

Function
  name        : Str
  param_count : u16
  local_count : u16             // includes params; locals are slots [0, local_count)
  max_stack   : u16             // operand-stack depth; lets us preallocate
  code        : [u8]            // the instruction stream
  stackmaps?  : [Stackmap]      // ref-bitmaps at safepoints; deferred (see GC)
```

`SlotKind` is just `{ Value, Ref }` for now — enough for the GC to scan. It can
grow into richer type info later if the JIT wants it.

## Instruction encoding

- Opcode = 1 byte.
- Operands = fixed-width (`u8`/`u16`/`u32`/`i64` as noted per op). Simple to
  decode; we trade compactness for a dead-simple decoder. LEB128 / immediate
  packing is a later optimization.
- Constants that don't fit an immediate (all `f64`, strings, large `i64`) live
  in the constant pool and are referenced by `u32` index.

This describes the eventual serialized format. The first interpreter skips it
and runs an in-memory `enum Instruction` instead (see
[The first interpreter](#the-first-interpreter-tier-0-nailed-down-decisions)).

## Instruction set

Typed opcodes use a `.i64` / `.f64` suffix. Suffixes are shown collapsed below;
each is a distinct opcode.

### Constants

| Op           | Operands   | Stack    | Notes                     |
| ------------ | ---------- | -------- | ------------------------- |
| `const.i64`  | `imm: i64` | `→ i64`  | small ints inline         |
| `const.f64`  | `k: u32`   | `→ f64`  | from constant pool        |
| `const.bool` | `b: u8`    | `→ bool` | 0 / 1                     |
| `const.str`  | `k: u32`   | `→ ref`  | interned string from pool |

### Locals

| Op             | Operands    | Stack | Notes                                   |
| -------------- | ----------- | ----- | --------------------------------------- |
| `load`         | `slot: u16` | `→ v` | params and locals share the array       |
| `store`        | `slot: u16` | `v →` | for `mut` bindings / SSA spills          |
| `load.capture` | `idx: u16`  | `→ v` | read a value captured by the closure     |

`load`/`store` move 64 bits regardless of type — no suffix needed. The slot's
ref-ness is recorded in the function's stackmap, not the opcode.

`load.capture` reads from the captured-values array of the *currently executing
closure* (populated by `closure.new`); it is the only way a closure body
reaches a captured variable, since `load` addresses only params and locals.

> **Captures: two designs, decision deferred.** Either (A) closures stay a
> runtime concept — `closure.new` builds a `{ func, captures[] }` object and the
> body reads them with `load.capture` (shown here); or (B) the frontend does
> *closure conversion*, lowering each lambda to a plain function that takes a
> synthesized environment struct as a parameter, so captures are ordinary
> `field.get`s and `load.capture` disappears. (A) is simplest for the
> interpreter (no frontend pass); (B) is more uniform for the Cranelift tier.
> Closures are out of the draft scope, so we keep `load.capture` as the
> interpreter-era stand-in and decide between A and B — along with the rule for
> capturing reassignable `mut` bindings — when closures actually land.

### Arithmetic, comparison, logic

| Op group      | Ops                                                  |
| ------------- | ---------------------------------------------------- |
| int arith     | `add.i64 sub.i64 mul.i64 div.i64 mod.i64 neg.i64`    |
| float arith   | `add.f64 sub.f64 mul.f64 div.f64 neg.f64`            |
| int compare   | `eq.i64 ne.i64 lt.i64 le.i64 gt.i64 ge.i64` → `bool` |
| float compare | `eq.f64 ne.f64 lt.f64 le.f64 gt.f64 ge.f64` → `bool` |
| bool          | `not` (→ bool)                                       |
| convert       | `i64.to_f64  f64.to_i64`                             |

`&&` / `||` short-circuit, so the frontend lowers them to branches — there is no
`and`/`or` opcode. `==` on strings/structs dispatches to `Eq` (a method call),
not `eq.i64`. Bitwise ops on `Int` are deferred until the language exposes them.

`add.i64`/`sub.i64`/`mul.i64` **wrap** on overflow (two's complement); they do
not trap. `div.i64`/`mod.i64` trap on a zero divisor and otherwise truncate
toward zero (Rust i64 semantics).

### Stack manipulation

| Op    | Stack     | Notes                                  |
| ----- | --------- | -------------------------------------- |
| `pop` | `v →`     | discard an expression-statement result |
| `dup` | `v → v v` | used by `?` lowering and chained calls |

### Control flow

Offsets are signed byte deltas from the _start of the next_ instruction.

| Op              | Operands   | Stack    | Notes                                   |
| --------------- | ---------- | -------- | --------------------------------------- |
| `jump`          | `off: i32` | —        | unconditional                           |
| `jump_if_true`  | `off: i32` | `bool →` |                                         |
| `jump_if_false` | `off: i32` | `bool →` |                                         |
| `return`        | —          | `[v] →`  | returns top slot, or nothing for `Void` |

A `switch.tag` (jump table on an enum tag) is an obvious later addition for fast
`match`; initially `match` lowers to `enum.tag` + a comparison/branch chain.

### Calls

| Op               | Operands                          | Stack                     | Notes                           |
| ---------------- | --------------------------------- | ------------------------- | ------------------------------- |
| `call`           | `func: u32, argc: u8`             | `argN..arg0 → ret?`       | direct call to a known function |
| `call.indirect`  | `sig: u32, argc: u8`              | `fnval argN..arg0 → ret?` | call a closure/fn value         |
| `call.interface` | `iface: u32, slot: u16, argc: u8` | `recv argN..arg0 → ret?`  | dynamic dispatch via vtable     |
| `call.native`    | `nat: u32, argc: u8`              | `argN..arg0 → ret?`       | `native fn` / runtime intrinsic |

Arguments are pushed left-to-right; the callee pops `argc` slots. Named
parameters are resolved to positions by the frontend — the bytecode is purely
positional. A `Void` return pushes nothing.

> Interface dispatch (static monomorphisation vs. dynamic vtable) is still an
> open language question. The format supports dynamic dispatch via
> `call.interface`; if the frontend monomorphises, it just emits `call` instead
> and `call.interface` goes unused.

### Aggregates & heap allocation

These are the GC _allocation safepoints_.

| Op            | Operands                  | Stack                  | Notes                          |
| ------------- | ------------------------- | ---------------------- | ------------------------------ |
| `struct.new`  | `type: u32`               | `fieldN..field0 → ref` | field count comes from TypeDef |
| `field.get`   | `idx: u16`                | `ref → v`              |                                |
| `field.set`   | `idx: u16`                | `ref v →`              | for `mut` fields; rare         |
| `enum.new`    | `type: u32, variant: u16` | `fieldN..field0 → ref` | writes the tag + payload       |
| `enum.tag`    | —                         | `ref → i64`            | variant index, for `match`/`?` |
| `enum.get`    | `idx: u16`                | `ref → v`              | extract a payload field        |
| `list.new`    | `count: u32`              | `vN..v0 → ref`         | list literal `[a, b, c]`       |
| `closure.new` | `func: u32, captures: u8` | `capN..cap0 → ref`     | binds captured slots           |

`Map`/`Set` literals and most collection operations are runtime calls
(`call.native`), not core opcodes — keeps the ISA small.

**Fixed variant tags.** `Result` and `Option` are ordinary enums with a pinned
variant ordering that all bytecode producers must use: `Result` → `Ok = 0`,
`Err = 1`; `Option` → `Some = 0`, `None = 1`. The `?` and `match` lowerings
below depend on these values.

## How key language features lower

These desugar in the frontend; the ISA stays minimal.

**`?` propagation** — given `let x = expr?;` where `expr : Result<T, E>`:

```
<eval expr>          // → ref (a Result)
dup
enum.tag             // → i64
const.i64 1          // tag of Err
eq.i64
jump_if_false  Lok
  // Err path: value is already the Result we want to return
  return
Lok:
enum.get 0           // unwrap Ok payload → T
store x
```

**`throw e`** in a `Result<T,E>` function → `enum.new Result, Err` then
`return`. **Implicit `Ok` wrapping** on a bare `return v` →
`enum.new Result, Ok` then `return`.

**`match`** — `enum.tag`, then a branch chain (later: `switch.tag`); each arm
uses `enum.get` to bind payload fields.

**`for x in 0..n`** — standard counter: a local, `lt.i64` test, `jump_if_false`
out, body, `add.i64` increment, `jump` back. Iterating collections goes through
an iterator protocol implemented as runtime calls.

**Closures / lambdas** — `closure.new` captures the needed slots; the call site
uses `call.indirect`.

**String interpolation** — for a user type, `${v}` calls the `Display` method
(`call.interface` or a resolved `call`); for a primitive (`Int`/`Double`/`Bool`,
whose `Display` is built in), it calls a stringify intrinsic (`call.native`).
The pieces are then joined with a `str_concat` intrinsic (`call.native`).

## Garbage collection

Deferred — the first interpreter can run bounded CLI work without collecting.
When the GC lands (precise, non-moving mark-sweep, per the plan):

- **Roots** are the live operand-stack slots and locals that are refs. Because
  the bytecode is typed, the compiler emits a **stackmap** at each safepoint
  (every `call.*` and every allocating op) — a bitmap over
  `[locals ++ live stack]` marking which slots are refs. This is the
  `Function.stackmaps` field left as a stub above.
- **Heap object headers** carry their `TypeDef` so the GC can trace fields
  (`SlotKind` per field).
- Non-moving is mandated by the eventual hybrid JIT-frame scanning; the format
  does not assume object addresses are stable-and-relocatable.

## Lowering to Cranelift (Tier 1)

The bytecode → Cranelift IR path is a standard _abstract stack interpretation_,
the same transform Wasmtime uses for Wasm:

1. Build the CFG from the jump targets (reducible by construction — see design
   priorities).
2. Walk each block, maintaining a compile-time **abstract operand stack** of
   Cranelift SSA `Value`s. `const.*` pushes an `iconst`/`f64const`; `add.i64`
   pops two and pushes `iadd`; `load`/`store` map to Cranelift variables; `call`
   becomes a Cranelift `call`; etc.
3. Block params / phi nodes reconstruct values that flow across joins.

Because every opcode is typed, each maps to a single Cranelift instruction with
no type guards — the speculation-free property the plan is built around.

## Open questions / deferred

- **Encoding details** — fixed-width vs. LEB128; the exact module file layout.
- **`switch.tag`** jump table for fast `match`.
- **Constant-pool dedup / interning** policy for strings.
- **Fiber yield points** — where the interpreter checks for cooperative
  rescheduling (likely at back-edges and blocking `call.native`s).
- **Stackmap representation** — bitmap vs. ranges; per-safepoint vs. per-block.
- **Globals / module-level state** — whether CLI programs need them at all.
- **Tail calls** — useful for the eventual self-hosted compiler; not yet.
