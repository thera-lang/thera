# toml-test

The official TOML conformance suite, from
[toml-lang/toml-test](https://github.com/toml-lang/toml-test).

- **Version vendored:** `v2.2.0`
- **Subset:** the TOML 1.0.0 cases only — every file named by upstream's
  `tests/files-toml-1.0.0` (which is also vendored, and is what the runner
  walks), under `tests/valid/` (`.toml` + expected-value `.json` pairs) and
  `tests/invalid/` (`.toml` files a conforming parser must reject). Upstream's
  1.1 cases, Go harness, and docs are not vendored.
- **License:** MIT, in [LICENSE](LICENSE) (upstream's file, unmodified).
- **Consumed by:** `sdk/std/toml/conformance_test.thera`, which runs every
  vendored case as part of the `std.toml` test suite.

## Updating

```
third_party/toml-test/update.sh v<X.Y.Z>
```

re-fetches that upstream release and replaces `tests/` with its 1.0.0 subset.
Then update the version line above, re-run the suite
(`bin/thera.sh test sdk/std/toml/conformance_test.thera`), and commit the result
as one reviewed change — the snapshot's whole point is that an upstream change
is a visible event, not a silent drift.
