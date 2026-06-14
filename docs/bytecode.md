# Hawk bytecode

**What this is:** the spec for Hawk's bytecode — the stable IR that the
front-end emits, the interpreter runs, and the Cranelift JIT will lower from —
plus the serialized `.hawkbc` format. Iterate freely; the Tier-0 interpreter and
the format already implement much of this (see [roadmap.md](roadmap.md) for
status). The motivating rationale for a tiered VM and our own bytecode is in
[architecture.md](architecture.md).

## Design priorities

In order (per the project's stated criteria):

1. **Simplicity of implementation** — the Tier-0 interpreter should be a small,
   obvious dispatch loop.
2. **Simplicity of targeting** — easy to emit from the Hawk frontend, and easy
   to lower to Cranelift IR.
3. **Performance** — fast enough to run real CLI work in the interpreter, and a
   clean path to native code for hot functions.
4. **Compactness of bytecode** - it is useful - but not critical - that the
   persistent, encoded form of the bytecode is compact

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
| `Void`             | _no slot_ — produces and consumes nothing    | —    |
| `String`           | pointer to heap object                       | yes  |
| `List`/`Map`/`Set` | pointer to heap object                       | yes  |
| struct             | pointer to heap object                       | yes  |
| enum (`Result`, …) | pointer to heap object (tag word + payload)  | yes  |
| closure / fn value | pointer to heap object (code ptr + captures) | yes  |

Uniform slot width keeps the interpreter and the stackmap scheme simple. Whether
a slot is a reference is **statically known** at every program point from the
types the frontend tracked, so we never tag values at runtime.

**Heap objects have reference semantics.** A slot that holds a pointer is a
_shared_ reference to a heap object (String, List, Map, Set, struct, enum,
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
describe the _first cut_, not permanent constraints.

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

A module is the durable artifact; this is its logical shape (the wire encoding
is in [Serialized format](#serialized-format) below):

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

## Serialized format

The wire form draws on Wasm (the container) and the JVM `.class` file (the
constant pool), but borrows neither instruction set nor type model — those carry
Hawk's types, which is the whole reason for rolling our own. We take the
_ideas_, not the encodings.

**Two layers.** The _wire form_ (on disk / embedded in the `hawk` binary)
optimizes for compactness; the _executable form_ is the in-memory `Module`
(`Vec<Instr>`) the interpreter already runs. The loader **decodes** the wire
form into a `Module` in one linear pass — cheap relative to process startup, and
it keeps absolute-index jump targets working with no fixups. Interpreting the
wire bytes in place (à la Lua/CPython) would force fixed-width instructions and
resolved byte offsets; deferred unless startup profiling ever justifies it.

**Trusted input.** Unlike Wasm/JVM, our bytecode is produced by our own
front-end and bundled into the SDK, so the loader does only lightweight
integrity checks (magic, version, section lengths) — no verifier. Revisit if we
ever load third-party bytecode.

**Container** — a header then a sequence of length-prefixed sections, so a
loader can skip sections it does not understand (forward compatibility, and a
home for optional debug info):

```
Header:   magic "HAWK" + format version
Section:  id (u8) + byte_length (varint) + payload     // unknown ids skipped
  Types     : struct/enum layouts (TypeDef); EnumNew's field_count moves here
  Functions : per fn { name, param_count, local_count, max_stack, code }
  Entry     : index of main
  Constants : (later) dedup'd strings / f64 / large ints — a compaction step
  Debug?    : (later) source file + line table — optional, skippable
```

**Instruction encoding.**

- Opcode = 1 byte.
- Operands use **LEB128 varints** (unsigned for indices/lengths, signed for
  `i64` immediates) — small values cost one byte. `f64` is 8 raw bytes.
- Multi-byte fixed fields are little-endian.
- v0 **inlines constants** in the instruction stream (a string literal carries
  its bytes; `const.f64` carries 8 bytes). A module-global **constant pool**
  (the JVM idea: dedup + reference by index) is a later compaction step, hence
  the deferred Constants section above.

The [disassembler](#) is the round-trip oracle: `encode → decode` must produce
an identical `Module` (compared directly or via disassembly).

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

| Op      | Operands    | Stack | Notes                             |
| ------- | ----------- | ----- | --------------------------------- |
| `load`  | `slot: u16` | `→ v` | params and locals share the array |
| `store` | `slot: u16` | `v →` | for `mut` bindings / SSA spills   |

`load`/`store` move 64 bits regardless of type — no suffix needed. The slot's
ref-ness is recorded in the function's stackmap, not the opcode.

> **Captures: implemented — closure conversion.** The frontend does _closure
> conversion_: each lambda lowers to a plain top-level function whose **leading
> parameters are its captured variables**, followed by the lambda's own
> parameters. Capture reads are then ordinary `load`s of those leading slots —
> no env struct, no `field.get` indirection, no `load.capture` opcode. The
> closure _value_ is `{ func, captures }`; `closure.new func, captures` pops the
> captured values and bundles them, and `call.indirect` builds the callee frame
> as `captures ++ args`. See [Calls](#calls) and
> [How key features lower](#how-key-language-features-lower).
>
> An immutable capture (and `self`, which is a reference, so capture still
> observes its field mutations) is taken **by value**. A captured `mut` local is
> **boxed** into a one-field heap cell (an ordinary 1-field struct): the binding
> wraps its value in the cell, reads become `field.get 0`, writes `field.set 0`,
> and the closure captures the _cell reference_ — so the enclosing scope and the
> closure observe each other's writes. Only `mut` locals that are actually
> captured are boxed; others stay plain. The one genuinely new runtime piece is
> the closure value plus `call.indirect`; free-variable analysis and boxing are
> frontend lowering over existing opcodes (`struct.new` / `field.get` /
> `field.set`).

### Arithmetic, comparison, logic

| Op group      | Ops                                                  |
| ------------- | ---------------------------------------------------- |
| int arith     | `add.i64 sub.i64 mul.i64 div.i64 mod.i64 neg.i64`    |
| float arith   | `add.f64 sub.f64 mul.f64 div.f64 neg.f64`            |
| int bitwise   | `and.i64 or.i64 xor.i64 bnot.i64 shl.i64 shr.i64 ushr.i64` |
| int compare   | `eq.i64 ne.i64 lt.i64 le.i64 gt.i64 ge.i64` → `bool` |
| float compare | `eq.f64 ne.f64 lt.f64 le.f64 gt.f64 ge.f64` → `bool` |
| bool          | `not` (→ bool)                                       |
| convert       | `i64.to_f64  f64.to_i64`                             |

`&&` / `||` short-circuit, so the frontend lowers them to branches — there is no
`and`/`or` opcode (`and.i64`/`or.i64` are *bitwise*). `==` on strings/structs
dispatches to `Eq` (a method call), not `eq.i64`.

`add.i64`/`sub.i64`/`mul.i64` **wrap** on overflow (two's complement); they do
not trap. `div.i64`/`mod.i64` trap on a zero divisor and otherwise truncate
toward zero (Rust i64 semantics).

The bitwise ops act on the two's-complement `i64`. `bnot.i64` is unary
(complement). The shifts mask the amount to `0..=63`: `shl.i64` left-shifts
(wrapping), `shr.i64` is **arithmetic** (sign-preserving), `ushr.i64` is
**logical** (zero-fill). These back the `& | ^ ~ << >> >>>` operators.

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
| `call.indirect`  | `argc: u8`                        | `fnval argN..arg0 → ret?` | call a closure/fn value         |
| `call.interface` | `iface: u32, slot: u16, argc: u8` | `recv argN..arg0 → ret?`  | dynamic dispatch via vtable     |
| `call.virtual`   | `selector: u32, argc: u8`         | `recv argN..arg0 → ret?`  | draft dynamic dispatch (below)  |
| `call.native`    | `nat: u32, argc: u8`              | `argN..arg0 → ret?`       | `native fn` / runtime intrinsic |

Arguments are pushed left-to-right; the callee pops `argc` slots. Named
parameters are resolved to positions by the frontend — the bytecode is purely
positional. A `Void` return pushes nothing.

> **Interface dispatch: direct calls now, vtable later.** Hawk knows the
> concrete type at every method call site today, so the frontend **resolves
> statically and emits a direct `call`** — including `Display` in `${…}`
> interpolation and `Eq` for `==`. `call.interface` (per-type vtable) is added
> only when Hawk gains _type-erased interface values_ (trait objects); at that
> point the bytecode carries `call.interface` and the JIT **devirtualizes** to a
> direct/inlined call wherever it can prove the concrete type. So we never need
> a frontend monomorphisation pass. Until then `call.interface` is
> reserved/unused.
>
> **Draft realization — `call.virtual`.** The Tier-0 interpreter implements
> dynamic dispatch as `call.virtual <selector> <argc>`: the receiver is the
> first of the `argc` args, and its concrete type id selects the impl from a
> module **dispatch table** (`(type_id, selector) → func`, a backward-compatible
> `.hawkbc` section). It is **name-keyed** (selector = method-name string)
> rather than `iface`/`slot`-indexed — simpler for the draft; the slot-based
> `call.interface` is the durable form. Struct ids index the type table and enum
> ids are namespaced with a high bit (`ENUM_DISPATCH_BASE`) since the two spaces
> overlap numerically. A **miss** (no row, or a receiver with no dispatch id —
> primitives, strings, collections) falls back to the built-in interfaces'
> structural forms: native `display` (primitives/String), the recursive
> structural `debug` (the `Debug` auto-derive), and structural `eq`. See
> docs/interfaces.md ("Dynamic dispatch — the arc, staged").

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
| `list.get`    | —                         | `ref idx → v`          | `list[i]` read; traps if OOB   |
| `list.set`    | —                         | `ref idx v →`          | `list[i] = v`; traps if OOB    |
| `closure.new` | `func: u32, captures: u8` | `capN..cap0 → ref`     | binds captured slots           |

`list.get`/`list.set` are the faulting list-element load/store — primitives
(like `field.get`/`field.set`) so the JIT can lower them inline and elide bounds
checks in counted loops. `Map`/`Set` literals, `Map` indexing (a keyed lookup),
and most other collection operations are runtime calls (`call.native`), not core
opcodes — keeps the ISA small.

**Fixed variant tags.** `Result` and `Option` are ordinary enums (defined in
`std.core`), but with a pinned variant ordering that all bytecode producers must
use: `Result` → `Ok = 0`, `Err = 1`; `Option` → `Some = 0`, `None = 1`. They
also occupy **reserved type ids** — `Result = 0`, `Option = 1` (user enums start
at 2) — so the runtime can recognize them: a `Result`-returning `main` maps `Ok`
to the exit code, and `Option`'s native methods key on its type id. The `?` and
`match` lowerings below depend on the tag values.

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

**Closures / lambdas** — the frontend collects the lambda's free variables (the
enclosing locals it references) and lifts it to a plain top-level function whose
leading parameters are those captures, followed by the lambda's own parameters.
Capture reads are ordinary `load`s of the leading slots. At the lambda site the
captured values are pushed and `closure.new func, captures` bundles them into a
`{ func, captures }` value; a call through that value uses `call.indirect`,
which prepends the captures to the call arguments to form the callee's frame. An
immutable capture is by value; a captured `mut` local is boxed into a one-field
cell so writes are shared (see [Locals](#locals)). `call.indirect` carries no
signature operand — the callee's arity is checked at the frame boundary like a
direct `call`.

**String interpolation** — for a user type, `${v}` calls the `Display` method as
a statically resolved direct `call` (the concrete type is known at the site);
for a primitive (`Int`/`Double`/`Bool`, whose `Display` is built in), it calls a
stringify intrinsic (`call.native`). The pieces are then joined with a
`str_concat` intrinsic (`call.native`).

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

Resolved: **closure capture** — closure conversion with captures as the lifted
function's leading locals; `closure.new` / `call.indirect` implemented, with
immutable captures by value and captured `mut` locals boxed into one-field
cells. And **interface dispatch** (static resolution → direct `call` now; vtable
`call.interface` only once type-erased interface values exist, devirtualized by
the JIT).

- **Encoding details** — fixed-width vs. LEB128; the exact module file layout.
- **`switch.tag`** jump table for fast `match`.
- **Constant-pool dedup / interning** policy for strings.
- **Fiber yield points** — where the interpreter checks for cooperative
  rescheduling (likely at back-edges and blocking `call.native`s).
- **Stackmap representation** — bitmap vs. ranges; per-safepoint vs. per-block.
- **Globals / module-level state** — whether CLI programs need them at all.
- **Tail calls** — useful for the eventual self-hosted compiler; not yet.
- **Container format** - instead of inventing a new container format wholesale,
  we may look at existing formats; for example, could we use the wasm format?
  Or, a custom format inspired by it?
