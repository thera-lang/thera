# Language conformance tests

These tests pin Hawk's **specification** (the `docs/` reference), as distinct from
the `*_test.hawk` suites in `pkgs/cli` and `sdk/std`, which test the
implementation behaviorally. A conformance test asserts what a documented
language feature *should* do — including features the implementation does not yet
provide (see [xfail](#expected-failures-xfail)).

Each test is a real `.hawk` file whose expectations live in comments, so the test
and its oracle are a single artifact you can also just run by hand
(`hawk run <file>` / `hawk check <file>`). They are grouped into subdirectories
by spec area (`expressions/`, `control_flow/`, `errors/`, …).

The harness is [`tests/lang_runner.hawk`](../lang_runner.hawk); `bin/test.sh`
runs it.

## Directives

A leading `//!` comment block configures the test:

```
//! spec: language.md#tail-expressions   the spec section this test pins
//! mode: run                            run+match stdout, or check+match diagnostics
//! xfail: <reason>                       (optional) the test is expected to fail
```

- **`spec:`** — the doc anchor this test pins (feeds the coverage report).
- **`mode:`** — `run` (compile + execute, compare stdout) or `check` (type-check
  only, compare diagnostics). Optional: a file with `// expect error:` lines
  defaults to `check`, otherwise `run`.
- **`xfail:`** — see below. A reason is required.

## Inline expectations

Anchored to the line they appear on:

```hawk
println('${1 + 2}');     // expect: 3                  (run)   one ordered stdout line
let x = if c { 1 };      // expect error: missing else  (check)  diagnostic on this line, message contains the text
let y = nums[9];         // expect trap: out of range    (run)   the program traps; stderr contains the text
```

- **`run`** mode compares the ordered `// expect:` list against the program's
  stdout (exactly, line for line). With `// expect trap:` lines it instead
  requires a non-zero exit and the trap text on stderr.
- **`check`** mode requires every `// expect error:` to match a diagnostic on its
  line **and** every emitted diagnostic to be expected — a surprise error fails
  the test.

## Expected failures (xfail)

`xfail` lets the spec run ahead of the implementation: write the test the spec
implies, mark it `xfail` with the reason, and the gap becomes a tracked signal.

| State                              | Outcome  | Suite |
| ---------------------------------- | -------- | ----- |
| `xfail`, fails as expected         | `XFAIL`  | green |
| `xfail`, **unexpectedly passes**   | `XPASS`  | red   |
| not `xfail`, fails                 | `FAIL`   | red   |

An `XPASS` fails the suite on purpose: it means the feature landed, so the
`//! xfail:` marker should be deleted and the test promoted to required.

## Support files (multi-file tests)

A `.hawk` file with **no `//!` directive block** is treated as a *support file*,
not a test: the harness skips running it directly. This is how a multi-file test
(e.g. an import or white-box-visibility test) ships the library it imports — the
test file carries the `//!` header and `import`s its sibling support file.

## Running

```
hawk run tests/lang_runner.hawk <hawk-cmd> <test-root> [coverage-map]
```

`<hawk-cmd>` is the `hawk` launcher under test (`bin/hawk.sh` in the dev tree);
`<test-root>` is this directory. `bin/test.sh` wires this up.

## Coverage report

Pass the coverage map ([docs/conformance.md](../../docs/conformance.md)) as the
optional third argument and the harness diffs the `//! spec:` IDs the tests cite
against the IDs registered in the map:

```
coverage: 70/72 spec IDs have a test
  untested (2): entry-main-err, vis-whitebox-test
```

- **untested** registered IDs are informational (some are intentionally unpinned).
- An ID a test cites that is **not** registered in the map (a typo or a missing
  map entry) is an error and fails the run — keeping citations and the map in
  sync.
