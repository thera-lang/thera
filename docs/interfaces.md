# Interfaces & dispatch

**What this is:** the design and staged plan for Hawk interfaces — how a type
declares it satisfies an interface, how interface methods are dispatched, and
which built-in interfaces (`Eq`/`Display`/`Debug`) the language relies on. A
working plan, refined as the arc lands.

## Goal

Interfaces are real contracts: a type _conforms_ to an interface by providing
its methods, the checker verifies it, and `Eq`/`Display`/`Debug` work as
ordinary interfaces on the types that make sense — primitives included (see
[language.md](language.md) and the primitives direction in
[roadmap.md](roadmap.md)).

## The dispatch model: static now, dynamic later

The key design split. Calling an interface method on a value whose **concrete
type is known at the call site** is just method resolution + a direct `call` —
no vtable needed. Dynamic dispatch is only forced when the concrete type is
_not_ statically known, which happens in exactly two places:

1. **interface-typed values** — `fn show(x: Display)`, `List<Display>`;
2. **erased generics** — `fn dump<T: Display>(x: T)`.

Both belong to the **generics / bound-enforcement arc**, so they are deferred to
it. This arc delivers interfaces dispatched on concrete types only.

When dynamic dispatch does arrive, the recommended mechanism is
**type-id-keyed**: every runtime value already carries its concrete type
(`Obj::Struct{ty}` / `Obj::Enum{ty}`; primitives are self-identifying tags), so
a `call.virtual <selector>` op can read the receiver's type id and look up the
impl method in a module table — cheap, and a natural fit for the tagged `Value`
runtime. (The alternative, monomorphization / dictionary-passing, is heavier and
only worth it if erased generics prove too slow.)

## Conformance

`impl Interface for Type { … }` declares conformance. The element model records
the `Type → Interface` relation (today `impl ... for` parses but the
`interfaceName` is dropped — `_resolveImpl` just adds the methods to the type).
The checker verifies the impl provides **every** interface method with a
matching signature (Self-aware), and reports missing / mismatched ones.

### `Eq` / `Debug` are auto-derived structurally

A type satisfies `Eq` (and `Debug`) **automatically** when its shape supports it
— primitives, and structs/enums whose fields are all `Eq` — matching the design
in `sdk/std/core/interfaces.hawk`. `==`/`!=` keep lowering to the structural
`eq` native (and the primitive opcodes) by default. An **explicit
`impl Eq for T` overrides** the derived behavior. `Display` stays explicit (no
meaningful default).

## Interface inheritance

An interface may **extend** one or more others, declaring that any conforming
type must also satisfy those super-interfaces:

```hawk
pub interface Error: Display + Debug {
    fn message(self) -> String;
}
```

This reads "an `Error` is a `Display` and a `Debug` that additionally has
`message()`." It buys two things:

1. **A wider conformance obligation.** `impl Error for FsError` is only valid
   when `FsError` also satisfies `Display` and `Debug` — the checker requires
   the supers (transitively), reusing the same `_satisfiesBound` logic as
   generic bounds (`Debug` is satisfied by the structural auto-derive for free;
   `Display` needs an explicit `impl Display`, since it has no derive). So the
   supers are **separate impls**, not re-declarations — matching Rust's
   `trait Error: Display` model and our existing `Message` (which already
   carries both `impl Error` and `impl Display`).
2. **A wider interface type.** A value typed as the `Error` _interface_ now
   exposes the super-interfaces' methods too: `e.display()`, `e.debug()`, and
   `'${e}'`/`println(e)` all resolve, and an `Error`-typed value is **assignable
   where a `Display` or `Debug` is expected** (and satisfies a `T: Debug` bound,
   so `assert_ok`/`assert_err` accept interface-typed errors). Before this, an
   interface couldn't extend another, so bare `Error` values had to be rendered
   via `e.message()`.

**Syntax.** After the interface name (and any type params), an optional
`: Super1 + Super2 + …` clause names the super-interfaces — the same `+`-joined
form as a generic bound (`<T: Eq + Debug>`). Supers must resolve to interfaces;
the relation is acyclic (a cycle is a compile error).

**No runtime change.** Dispatch already keys on `(concrete type_id, selector)`,
and the concrete type carries its own `Display`/`Debug` rows from its separate
impls. Calling `e.display()` on an `Error`-typed `e` lowers to the existing
`call.virtual 'display'`; at runtime the receiver's concrete type (e.g.
`Message`) resolves it. Inheritance is therefore **front-end only** — the
super-interfaces' method names are flattened into the sub-interface's method set
(so lookup and `call.virtual` eligibility see them), and the conformance,
assignability, and bound-satisfaction checks walk the super relation
transitively. No default/inherited _method bodies_ — only the obligation and the
widened method set; a super method still dispatches to the concrete type's own
impl.

## How the built-ins are wired

- **`Display`** powers `${…}` interpolation and `println`. Interpolation already
  dispatches statically (codegen emits a direct `Call` to `Type.display`). The
  gap is `println`/`stringify` of a _user_ type: those are natives, and a native
  can't call a Hawk `display` method. Fix: the front-end desugars `println(x)` /
  `'${x}'` to `x.display()` (statically dispatched) and hands the finished
  `String` to a dumb native — which also dogfoods stdlib-in-Hawk.
- **`Eq`** powers `==`/`!=`. Route through an explicit `impl Eq` when present;
  otherwise the structural native / opcode (the derived default).

## Staged plan

**Stage I — Conformance tracking + checking (front-end only, no runtime).
DONE.** `impl Interface for Type` is recorded on the type element (`interfaces`
/ `implementsInterface`); the checker (`_checkConformance`) validates the impl
satisfies the interface — every method present, signatures matching with `Self`
substituted for the implementing type.

**Stage II — `Eq`/`Display` dispatched through impls on concrete types. DONE.**
Codegen records conformance (`scope.interfaceImpls`) and dispatches accordingly:

- `==`/`!=` calls a type's own `eq` when it has an explicit `impl Eq`; otherwise
  the structural `eq` native (the auto-derived default for non-primitives) or a
  typed opcode (primitives). So `Eq` is structural-by-default,
  explicit-override.
- `${…}` dispatches to a type's `display` only when it implements `Display`.
- `println`/`print` of a `Display` type render via `display` at the call site
  (the native can't upcall); primitives/String pass through to the native, which
  is their built-in `Display`. So no explicit `impl Display for Int` is needed.

**Still deferred:**

- **Generic operators** (`<T: Add>`, operators-as-traits) — arithmetic on erased
  type parameters.
- **Named arguments through a virtual call** — interface-receiver calls resolve
  arguments positionally only.
- **Richer auto-derived `debug` output** — struct field names and user-enum
  variant names aren't in the runtime's type table yet, so the structural debug
  renders them positionally (`Point { 1, 2 }`, `variant1(5)`).

## Dynamic dispatch — the arc, staged (complete)

The staged plan for dynamic dispatch and interface-typed values, now landed:
`fn show(x: Display)` and `<T: Display>` work, dispatching to the right
`display` at runtime via the type-id-keyed `call.virtual` sketched above. The
work split into a runtime layer, a front-end type-system layer, and bound
enforcement — each independently testable, ordered so a small, real end-to-end
change landed first.

### What it entails (the layers)

- **A. Runtime — a vtable and one new opcode.** Every value already carries its
  concrete type id (`Obj::Struct{ty}` / `Obj::Enum{ty}`; primitives are tags).
  Add (1) a module **dispatch table** `(type_id, selector) → fn_index`,
  serialized in `.hawkbc`; (2) an opcode `call.virtual <selector> <argc>` that
  reads the receiver's type id (the first of the `argc` args), looks up the
  impl, and calls it like `Call`. Selector = a constant-pool method-name string
  (or an interned id). Testable in isolation with hand-built bytecode.
- **B. Codegen — build the table, emit the op.** From the recorded
  `interfaceImpls` (type → interface → method units), emit one vtable row per
  `impl Interface for Type` method: `(Type's type_id, method_name) → unit`. When
  a call's **receiver has interface static type** (not a concrete type), emit
  `call.virtual name` instead of a direct `Call`.
- **C. Front-end — interface types as values.** Today an interface name appears
  only as an impl target or a (parsed, unenforced) bound. To allow `x: Display`:
  the resolver resolves an interface name in type position to an interface value
  type; `isAssignable(concrete T, interface I)` becomes "`T` implements `I`"
  (using the `interfaces` list already on each `TypeDefElement`); and on an
  interface-typed value only the interface's own methods resolve (their return
  types drive inference). This type-system change is the subtle part — bound its
  scope by starting with **function parameters only**.
- **D. Bound enforcement (the type-param half).** `fn dump<T: Display>(x: T)`:
  check at the call site that the type argument implements the bound (this is
  the deferred [type-param bound check](roadmap.md)); inside the body, a call on
  the erased `T` lowers to `call.virtual` (same mechanism as C). Reuses A/B
  entirely.
- **E. Primitives under dynamic dispatch (cross-cutting decision).** Primitives'
  `Display` is currently produced by the `stringify`/`display` native at the
  call site, not a Hawk `display` method — so they have no vtable row. To make
  `show(5)` work, either register native-backed vtable entries for primitive
  type ids, or have `call.virtual` fall back to the native for primitive
  receivers. Not needed for the first slice (user types only); decide when it's
  hit.

### Staging

1. **Stage A — runtime vtable + `call.virtual`. DONE.** A module dispatch table
   (`DispatchEntry { ty, selector, func }`), a `call.virtual <selector> <argc>`
   opcode that reads the receiver's type id and calls the matching impl, and a
   backward-compatible `.hawkbc` DISPATCH section (absent → empty). Verified
   with hand-built bytecode: `describe(x)` dispatches `x.display()` to the right
   impl by type id. Name-keyed (`selector`) in the Tier-0 draft; the durable
   slot-based `call.interface iface, slot` (see bytecode.md) comes later.
2. **Stage B — interface-typed parameters + dispatch. DONE.** An interface name
   resolves as a value type (it already did — `InterfaceType` over an
   `InterfaceElement`); `isAssignable(concrete, interface)` accepts a conforming
   type; codegen tracks interface names, builds the dispatch table from recorded
   `impl Interface for Type` methods (`buildDispatch`), and emits `call.virtual`
   for an interface-typed receiver. The Dart bytecode layer learned the
   `call.virtual` op + DISPATCH section. The end change (below) runs end to end.
3. **Stage C — more positions. DONE.** Interface-typed fields, returns, and
   `List<Display>` (heterogeneous collections, incl. a `for` loop over them) all
   dispatch — they fell out of Stage B's machinery, since dispatch keys off the
   receiver's static type and the resolver/inference already propagate interface
   types into those positions. The added work was soundness: a method **not**
   declared on the interface is rejected at compile time (was a runtime trap),
   and a non-conforming value is rejected where an interface is expected.
4. **Stage D — generics + bounds. DONE.** A method on an erased `T: Display`
   dispatches via `call.virtual` (codegen reads the unit's type-param bounds;
   inference resolves the method against the bound). Bounds are **enforced at
   call sites**: the type argument must satisfy each bound, else a compile error
   (primitives satisfy the built-in `Eq`/`Display`/`Debug` — and as of Stage E
   they dispatch too; `f<T: Display>(plain_struct)` is rejected). `Eq`/`Debug`
   are satisfied structurally (no explicit `impl` needed); other interfaces
   require one. Subsumes the old type-param-bound-enforcement gap.
5. **Stage E — built-in fallbacks: `Debug` auto-derive + primitives. DONE.** A
   `call.virtual` whose receiver has no impl row falls back to the built-in
   interfaces' structural forms in the runtime:
   - **`display`** — primitives/String render natively (so `show<T: Display>(5)`
     and `'${x}'` on an interface-typed value work; a struct reaching the
     fallback without an impl is still a trap, and the checker prevents it);
   - **`debug`** — the structural auto-derive, recursive over collections:
     strings quoted (`'Rex'`), lists/maps/sets bracketed, a struct as
     `Name { field, ... }` (positional — field names aren't in the type table),
     an enum as `Variant(field)` with Result/Option's variants named (other
     enums' variant names aren't in the runtime yet). A nested value with an
     explicit `impl Debug` renders through it;
   - **`eq`** — structural equality, so `==` on an erased `T: Eq` lowers to
     `call.virtual 'eq'` and an explicit `impl Eq` override wins at runtime
     (previously erasure silently bypassed overrides). Codegen also renders
     interface-typed / `Display`-bounded values in `${…}` and `println` via
     `call.virtual 'display'`. Plus a latent-bug fix: struct and enum type ids
     overlap numerically, so enum dispatch ids are namespaced with a high bit
     (`ENUM_DISPATCH_BASE`) on both sides of the wire.

   **This unblocks the `@test` runner:** `testing.assert_eq<T: Eq + Debug>` now
   compiles and runs — generic `!=` dispatches, and failure messages render via
   the structural `debug` (e.g. `actual: Point { 1, 2 }`). The remaining runner
   work is the runner itself (discover `@test` fns, invoke, report), not the
   language.

### The small, practical end change (Stage B deliverable)

```
interface Display { fn display(self) -> String; }

type Dog = { name: String }
impl Display for Dog { fn display(self) -> String { return 'Dog(${self.name})'; } }
type Cat = {}
impl Display for Cat { fn display(self) -> String { return 'a cat'; } }

// `x`'s concrete type is not known here — dispatched at runtime via call.virtual:
fn describe(_ x: Display) -> String { return x.display(); }

fn main() -> Int {
    println(describe(Dog { name: 'Rex' }));   // Dog(Rex)
    println(describe(Cat {}));                // a cat
    return 0;
}
```

That single slice exercises A (vtable + op), B (interface param, assignability,
emit), and nothing else — no generics, no collections, no primitives. It's the
minimal proof that dynamic dispatch works, and it's a genuinely useful
capability (`Display`-typed parameters) on its own.
