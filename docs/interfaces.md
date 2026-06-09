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

**Stage I — Conformance tracking + checking (front-end only, no runtime). DONE.**
`impl Interface for Type` is recorded on the type element (`interfaces` /
`implementsInterface`); the checker (`_checkConformance`) validates the impl
satisfies the interface — every method present, signatures matching with `Self`
substituted for the implementing type.

**Stage II — `Eq`/`Display` dispatched through impls on concrete types. DONE.**
Codegen records conformance (`scope.interfaceImpls`) and dispatches accordingly:
- `==`/`!=` calls a type's own `eq` when it has an explicit `impl Eq`; otherwise
  the structural `eq` native (the auto-derived default for non-primitives) or a
  typed opcode (primitives). So `Eq` is structural-by-default, explicit-override.
- `${…}` dispatches to a type's `display` only when it implements `Display`.
- `println`/`print` of a `Display` type render via `display` at the call site
  (the native can't upcall); primitives/String pass through to the native, which
  is their built-in `Display`. So no explicit `impl Display for Int` is needed.

**Deferred:**
- **`Debug` auto-derivation** — no structural `debug` yet. Its only use
  (`assert_eq`/`assert_ne` in `std.core/testing`) is generic (`<T: Eq + Debug>`),
  so it needs dynamic dispatch anyway; pick it up with the generics arc (or as a
  structural `debug` native if a concrete need appears first).
- **The generics arc (separate):** dynamic dispatch (`call.virtual` + runtime
  type-id table), interface-typed values (`fn show(x: Display)`, `List<Display>`),
  generic bound enforcement (`<T: Display>` — see `docs/roadmap.md`), and generic
  operators (`<T: Add>`, operators-as-traits).

## Dynamic dispatch — the next arc, staged

Scoping for adding dynamic dispatch and interface-typed values. The end goal:
`fn show(x: Display)` and `<T: Display>` work, dispatching to the right `display`
at runtime. The mechanism is the type-id-keyed `call.virtual` already sketched
above. The work splits into a runtime layer, a front-end type-system layer, and
bound enforcement — each independently testable, ordered so a small, real
end-to-end change lands first.

### What it entails (the layers)

- **A. Runtime — a vtable and one new opcode.** Every value already carries its
  concrete type id (`Obj::Struct{ty}` / `Obj::Enum{ty}`; primitives are tags). Add
  (1) a module **dispatch table** `(type_id, selector) → fn_index`, serialized in
  `.hawkbc`; (2) an opcode `call.virtual <selector> <argc>` that reads the
  receiver's type id (the first of the `argc` args), looks up the impl, and calls
  it like `Call`. Selector = a constant-pool method-name string (or an interned
  id). Testable in isolation with hand-built bytecode.
- **B. Codegen — build the table, emit the op.** From the recorded
  `interfaceImpls` (type → interface → method units), emit one vtable row per
  `impl Interface for Type` method: `(Type's type_id, method_name) → unit`. When a
  call's **receiver has interface static type** (not a concrete type), emit
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
  check at the call site that the type argument implements the bound (this is the
  deferred [type-param bound check](roadmap.md)); inside the body, a call on the
  erased `T` lowers to `call.virtual` (same mechanism as C). Reuses A/B entirely.
- **E. Primitives under dynamic dispatch (cross-cutting decision).** Primitives'
  `Display` is currently produced by the `stringify`/`display` native at the call
  site, not a Hawk `display` method — so they have no vtable row. To make
  `show(5)` work, either register native-backed vtable entries for primitive type
  ids, or have `call.virtual` fall back to the native for primitive receivers.
  Not needed for the first slice (user types only); decide when it's hit.

### Staging

1. **Stage A — runtime vtable + `call.virtual`.** No front-end changes; verify
   with hand-built bytecode that a virtual call dispatches on type id.
2. **Stage B — interface-typed parameters + dispatch.** Front-end allows an
   interface name as a *parameter* type; `isAssignable` accepts a conforming
   concrete type; codegen builds the vtable and emits `call.virtual`. **This is
   the small, practical end change** (below).
3. **Stage C — more positions.** Interface-typed fields, returns, and
   `List<Display>` (heterogeneous collections) — same dispatch, more places an
   interface type is allowed.
4. **Stage D — generics + bounds.** `<T: Display>` bound checking at call sites +
   erased-generic dispatch via `call.virtual`. Subsumes type-param bound
   enforcement.
5. **Stage E — `Debug` auto-derive.** A structural `debug` reachable under
   dynamic dispatch unblocks generic `assert_eq`/`assert_ne`, a prerequisite for
   the `@test` runner actually running tests.

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
minimal proof that dynamic dispatch works, and it's a genuinely useful capability
(`Display`-typed parameters) on its own.
