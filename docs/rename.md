# Hawk → Thera rename

The language is renamed **Hawk → Thera** (after the Antikythera mechanism). This
tracks the staged mechanical rename. Historical references (changelogs, old
design-note prose quoting the era) stay unchanged.

## Naming map

| Old | New |
| --- | --- |
| `.hawk` (source) | `.thera` |
| `.hawkbc` (bytecode) | `.thera-bc` |
| `hawk` (SDK CLI) | `thera` |
| `hawkrt` (bare runtime binary) | `thera-rt` |
| `hawk` (Rust crate) | `thera` |
| `b"HAWK"` (bytecode magic) | `b"THERA"` |
| `HAWK_*` (env vars) | `THERA_*` |
| `hawk` / `source.hawk` (editor language id / scope) | `thera` / `source.thera` |

## Stages

Each stage lands separately, gated by `cargo test`/`clippy`/`fmt`,
`bin/test.sh`, and the `build_sdk.sh` fixpoint. Stages 1–3 are ordered (the
checked-in bootstrap snapshot's loader hard-codes the source extension, so the
extension change follows the standard self-hosting ratchet); 4–6 are
independent.

- [x] **1. Dual-extension support.** The toolchain resolves both `.thera` and
  `.hawk` (preferring `.thera`): loader resolution/barrels/`_test` detection,
  `check`/`test`/`fmt`/`lint` directory scans, LSP workspace scan + file
  watchers, conformance harness. Refresh `bootstrap/frontend.hawkbc`.
  Transitional sites are marked `hawk→thera transition` for the stage-3 sweep.
- [x] **2. Rename sources.** `git mv` all `*.hawk` → `*.thera`; update the
  `*.hawk` find patterns and `main.hawk` paths in `bin/*.sh`; refresh the
  snapshot (embedded source paths change).
- [x] **3. Drop `.hawk`; bytecode rename.** Remove the `.hawk` fallbacks
  (sweep the transition markers). Rename `.hawkbc` → `.thera-bc`
  (`bootstrap/frontend.thera-bc`, scripts, help text). Magic: decoder accepts
  `HAWK` and `THERA`, encoder emits `THERA`, rebuild + refresh snapshot, then
  drop `HAWK` acceptance.
- [x] **4. Tool / crate / env renames.** `bin/hawk.sh` → `bin/thera.sh`; SDK
  launcher `bin/hawk` → `bin/thera`; CLI usage text; Rust crate `hawk` →
  `thera` and binary `hawkrt` → `thera-rt`; `HAWK_*` → `THERA_*` env vars
  (clean cut, no compat aliases).
- [x] **5. VS Code extension.** Language id/scope, `.thera` association,
  `hawk.*` commands/settings → `thera.*`, syntax/snippet file renames, README;
  verify the LSP server side against the new language id.
- [x] **6. Docs & org.** Prose sweep of `docs/`, `README.md`, `CLAUDE.md`,
  `AGENTS.md`, code comments, `.github` profile. Create `thera-lang/thera` and
  `thera-lang/thera-ext` GitHub repos and wire up remotes.
