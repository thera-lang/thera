#!/usr/bin/env bash
#
# Run the whole Hawk test suite (self-hosted; no external toolchain):
#   - the Rust runtime's cargo tests
#   - the front-end's own @test suite (pkgs/cli)
#   - the standard library's @test suite (sdk/std)
#   - every example runs, with a few output regressions pinned
#
# Each `hawk` invocation uses the dev front-end via bin/hawk.sh.

set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
HAWK="$ROOT/bin/hawk.sh"
fail=0

echo "==> cargo test (runtime)"
( cd runtime && cargo test --quiet ) || fail=1

echo "==> hawk test pkgs/cli (front-end)"
"$HAWK" test pkgs/cli || fail=1

echo "==> hawk test sdk/std (stdlib)"
"$HAWK" test sdk/std || fail=1

echo "==> lsp transport (end-to-end over a pipe)"
# Drive the real `hawk lsp` process through stdin/stdout the way an editor does:
# a single Content-Length-framed `initialize`, then EOF (the server exits). This
# exercises the actual stdout transport — the in-process server @tests use a
# StringWriter and so can't catch a framing/flushing regression (e.g. the
# line-buffered-stdout bug where only the header reached the client). The body
# carries "capabilities", so finding it proves the full message arrived.
lsp_body='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{}}}'
lsp_out="$(printf 'Content-Length: %d\r\n\r\n%s' "${#lsp_body}" "$lsp_body" | "$HAWK" lsp 2>/dev/null)"
if printf '%s' "$lsp_out" | grep -q '"capabilities"'; then
  echo "  ok   initialize handshake returns capabilities"
else
  echo "  FAIL lsp initialize: no framed response body received"; fail=1
fi

echo "==> check diagnostics stream (stdout, not stderr)"
# `hawk check`'s product is its diagnostics (it emits no artifact), so they go to
# stdout — like `hawk test` and like linters (eslint/ruff/mypy). Assert that a
# diagnostic lands on stdout and not stderr, so the convention can't regress.
# (See docs/architecture.md, "The CLI: commands and output streams".)
chk_dir="$(mktemp -d)"
printf 'fn f() -> Int { return missing; }\n' > "$chk_dir/bad.hawk"
chk_out="$("$HAWK" check "$chk_dir/bad.hawk" 2>/dev/null)"
chk_err="$("$HAWK" check "$chk_dir/bad.hawk" 2>&1 1>/dev/null)"
if printf '%s' "$chk_out" | grep -q 'undefined name: missing' \
   && ! printf '%s' "$chk_err" | grep -q 'undefined name: missing'; then
  echo "  ok   diagnostics on stdout, not stderr"
else
  echo "  FAIL check diagnostics stream (stdout='$chk_out')"; fail=1
fi
rm -rf "$chk_dir"

echo "==> qualified-reference guard (corpus stays at 0 bare cross-library refs)"
# The whole corpus is qualified-only: every reference to another library's public
# name goes through `ns.name` (or an explicit `import '…' as _;`). This is now
# enforced — `check` reports a "bare reference to …" error for each violation —
# so a regression fails the build outright; this guard keeps the count explicit
# (and the message clear). See docs/scoping.md.
bare_refs="$("$HAWK" check pkgs/cli sdk/std examples 2>/dev/null \
  | grep -c 'bare reference to')"
if [ "$bare_refs" -eq 0 ]; then
  echo "  ok   0 bare cross-library references"
else
  echo "  FAIL $bare_refs bare cross-library reference(s); run: hawk check pkgs/cli sdk/std examples"
  fail=1
fi

echo "==> language conformance (tests/lang)"
# Spec-conformance tests: each tests/lang/**/*.hawk pins a documented language
# feature via embedded `//!` directives + `// expect…` comments. The harness
# (a Hawk program) shells back to `hawk` per test and compares. xfail tests that
# unexpectedly pass (XPASS) fail the suite. See tests/lang/README.md.
"$HAWK" run tests/lang_runner.hawk "$HAWK" "$ROOT/tests/lang" "$ROOT/docs/conformance.md" || fail=1

echo "==> examples"
# Pin the output of a few representative examples (the rest must just run).
check_out() {
  local file="$1" expected="$2"
  local got
  got="$("$HAWK" run "$file" 2>&1)"
  if [ "$got" = "$expected" ]; then
    echo "  ok   $file"
  else
    echo "  FAIL $file"; echo "--- expected ---"; echo "$expected"; echo "--- got ---"; echo "$got"; fail=1
  fi
}
check_out examples/fibers.hawk $'sum of squares 1..5 = 55\nconsumed 10 values, sum = 55'
check_out examples/list_hof.hawk $'20\n40\n60\nbig: 2\ntotal: 21'

# Every other example must at least run cleanly. wordcount needs a file argument;
# gc_stress is a manual perf harness; *_test.hawk are test files.
for f in examples/*.hawk; do
  case "$f" in
    *_test.hawk|*fibers.hawk|*list_hof.hawk|*gc_stress.hawk) continue ;;
    *wordcount.hawk) "$HAWK" run "$f" examples/wordcount.hawk >/dev/null 2>&1 ;;
    *) "$HAWK" run "$f" >/dev/null 2>&1 ;;
  esac
  if [ $? -eq 0 ]; then echo "  ok   $f"; else echo "  FAIL $f"; fail=1; fi
done

echo
if [ "$fail" -eq 0 ]; then echo "ALL TESTS PASSED"; else echo "SOME TESTS FAILED"; fi
exit "$fail"
