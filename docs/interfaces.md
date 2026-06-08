# Interfaces & dispatch

**What this is:** the design and staged plan for Hawk interfaces — how a type
declares it satisfies an interface, how interface methods are dispatched, and
which built-in interfaces (`Eq`/`Display`/`Debug`) the language relies on. A
working plan, refined as the arc lands.

## Goal

Interfaces are real contracts: a type *conforms* to an interface by providing its
methods, the checker verifies it, and `Eq`/`Display`/`Debug` work as ordinary
interfaces on the types that make sense — primitives included (see
[language.md](language.md) and the primitives direction in
[roadmap.md](roadmap.md)).

## The dispatch model: static now, dynamic later

The key design split. Calling an interface method on a value whose **concrete
type is known at the call site** is just method resolution + a direct `call` — no
vtable needed. Dynamic dispatch is only forced when the concrete type is *not*
statically known, which happens in exactly two places:

1. **interface-typed values** — `fn show(x: Display)`, `List<Display>`;
2. **erased generics** — `fn dump<T: Display>(x: T)`.

Both belong to the **generics / bound-enforcement arc**, so they are deferred to
it. This arc delivers interfaces dispatched on concrete types only.

When dynamic dispatch does arrive, the recommended mechanism is **type-id-keyed**:
every runtime value already carries its concrete type (`Obj::Struct{ty}` /
`Obj::Enum{ty}`; primitives are self-identifying tags), so a `call.virtual
<selector>` op can read the receiver's type id and look up the impl method in a
module table — cheap, and a natural fit for the tagged `Value` runtime. (The
alternative, monomorphization / dictionary-passing, is heavier and only worth it
if erased generics prove too slow.)

## Conformance

`impl Interface for Type { … }` declares conformance. The element model records
the `Type → Interface` relation (today `impl ... for` parses but the
`interfaceName` is dropped — `_resolveImpl` just adds the methods to the type).
The checker verifies the impl provides **every** interface method with a matching
signature (Self-aware), and reports missing / mismatched ones.

### `Eq` / `Debug` are auto-derived structurally

A type satisfies `Eq` (and `Debug`) **automatically** when its shape supports it —
primitives, and structs/enums whose fields are all `Eq` — matching the design in
`sdk/std/core/interfaces.hawk`. `==`/`!=` keep lowering to the structural `eq`
native (and the primitive opcodes) by default. An **explicit `impl Eq for T`
overrides** the derived behavior. `Display` stays explicit (no meaningful default).

## How the built-ins are wired

- **`Display`** powers `${…}` interpolation and `println`. Interpolation already
  dispatches statically (codegen emits a direct `Call` to `Type.display`). The
  gap is `println`/`stringify` of a *user* type: those are natives, and a native
  can't call a Hawk `display` method. Fix: the front-end desugars `println(x)` /
  `'${x}'` to `x.display()` (statically dispatched) and hands the finished
  `String` to a dumb native — which also dogfoods stdlib-in-Hawk.
- **`Eq`** powers `==`/`!=`. Route through an explicit `impl Eq` when present;
  otherwise the structural native / opcode (the derived default).

## Staged plan

**Stage I — Conformance tracking + checking (front-end only, no runtime).**
Record `impl Interface for Type` in the element model; the checker validates the
impl satisfies the interface (all methods, matching signatures, `Self`). Replace
the ad-hoc "has a `display` method" interpolation check with real `Display`
conformance. Foundation for everything; low risk.

**Stage II — `Eq`/`Display`/`Debug` as real interfaces on concrete types.**
Define them canonically; auto-derive `Eq`/`Debug` structurally with explicit
`impl` override; implement `Display` for the primitives and built-ins that make
sense. Route `==`/`!=` and `${…}` through the impl when one exists. Fix
`println`/`stringify` of user types via the `.display()` desugaring above.

**Deferred to the generics arc (separate):** dynamic dispatch (`call.virtual` +
runtime type-id table), interface-typed values (`fn show(x: Display)`,
`List<Display>`), generic bound enforcement (`<T: Display>` — see
`docs/roadmap.md`), and generic operators (`<T: Add>`, operators-as-traits).
