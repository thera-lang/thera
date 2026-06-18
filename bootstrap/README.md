# Bootstrap

`frontend.hawkbc` is the **checked-in self-hosting bootstrap**: the Hawk
front-end (`pkgs/cli/`) compiled to bytecode. It is the compiler that compiles
the next revision of the front-end — so the build needs only the Rust runtime,
not any external toolchain.

## How it's used

`bin/build_sdk.sh` runs this snapshot on the bare runtime (`hawkrt`) to emit a
fresh `frontend.hawkbc` from the current `pkgs/cli/` sources, embeds that into
the `hawk` binary, then **fixpoint-checks** that the freshly-built front-end
re-emits itself byte-for-byte. That replaced the old Dart bootstrap + byte
oracle.

## Updating the snapshot

After a successful `bin/build_sdk.sh` (the fixpoint passed), refresh the snapshot
so it tracks `main`:

```
cp build/frontend.hawkbc bootstrap/frontend.hawkbc
```

The snapshot only needs refreshing when a front-end change uses **new syntax**
the current snapshot can't parse — the standard self-hosting ratchet: land the
change so the *current* snapshot still compiles it, rebuild, refresh the
snapshot, then use the new syntax. Pure semantic/inference changes never need a
manual refresh (the old snapshot compiles them fine), but refreshing keeps the
bootstrap close to `main`.
