#!/usr/bin/env bash
#
# Run the Thera test suite (self-hosted; no external toolchain):
#   - the Rust runtime's cargo tests
#   - the front-end's own @test suite (pkgs/cli)
#   - the standard library's @test suite (sdk/std)
#   - CLI/diagnostic behavior guards, language conformance, and examples
#
# Each `thera` invocation uses the dev front-end via bin/thera.sh.
#
# Usage: test.sh [group...]
#   With no args, runs every group (the full local suite). Named groups run
#   just those, in the given order — this is how CI shards the work in parallel:
#     cargo frontend stdlib checks conformance examples

set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
THERA="$ROOT/bin/thera.sh"
fail=0

phase_cargo() {
  echo "==> cargo test (runtime)"
  ( cd runtime && cargo test --quiet ) || fail=1
}

phase_frontend() {
  echo "==> thera test pkgs/cli (front-end)"
  "$THERA" test pkgs/cli || fail=1
}

phase_stdlib() {
  echo "==> thera test sdk/std (stdlib)"
  "$THERA" test sdk/std || fail=1
}

# CLI, diagnostic, and corpus-invariant guards (fast checks, one dev front-end).
phase_checks() {
  echo "==> lsp transport (end-to-end over a pipe)"
  # Drive the real `thera lsp` process through stdin/stdout the way an editor does:
  # a single Content-Length-framed `initialize`, then EOF (the server exits). This
  # exercises the actual stdout transport — the in-process server @tests use a
  # StringWriter and so can't catch a framing/flushing regression (e.g. the
  # line-buffered-stdout bug where only the header reached the client). The body
  # carries "capabilities", so finding it proves the full message arrived.
  lsp_body='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{}}}'
  lsp_out="$(printf 'Content-Length: %d\r\n\r\n%s' "${#lsp_body}" "$lsp_body" | "$THERA" lsp 2>/dev/null)"
  if printf '%s' "$lsp_out" | grep -q '"capabilities"'; then
    echo "  ok   initialize handshake returns capabilities"
  else
    echo "  FAIL lsp initialize: no framed response body received"; fail=1
  fi

  echo "==> profiler (THERA_PROFILE: deterministic, present)"
  # The in-VM profiler is an always-shipping runtime feature, gated by the
  # THERA_PROFILE env var, that prints a per-function table to stderr at run end.
  # Its headline property for agents is *determinism* — instruction-budget
  # sampling, not wall-clock — so two runs of the same program must produce a
  # byte-identical profile. (See docs/roadmap.md, "Profiling Thera code".)
  prof_dir="$(mktemp -d)"
  printf 'fn main() -> Int { let mut s = 0; let mut i = 0; while i < 5000 { s = s + i; i = i + 1; } return s; }\n' > "$prof_dir/p.thera"
  prof1="$(THERA_PROFILE=1 "$THERA" run "$prof_dir/p.thera" 2>&1 1>/dev/null)"
  prof2="$(THERA_PROFILE=1 "$THERA" run "$prof_dir/p.thera" 2>&1 1>/dev/null)"
  if printf '%s' "$prof1" | grep -q 'thera profile' && [ "$prof1" = "$prof2" ]; then
    echo "  ok   profile emitted and byte-identical across runs"
  else
    echo "  FAIL profiler (present=$(printf '%s' "$prof1" | grep -c 'thera profile'), deterministic=$([ "$prof1" = "$prof2" ] && echo y || echo n))"; fail=1
  fi
  rm -rf "$prof_dir"

  echo "==> check diagnostics stream (stdout, not stderr)"
  # `thera check`'s product is its diagnostics (it emits no artifact), so they go to
  # stdout — like `thera test` and like linters (eslint/ruff/mypy). Assert that a
  # diagnostic lands on stdout and not stderr, so the convention can't regress.
  # (See docs/architecture.md, "The CLI: commands and output streams".)
  chk_dir="$(mktemp -d)"
  printf 'fn f() -> Int { return missing; }\n' > "$chk_dir/bad.thera"
  chk_out="$("$THERA" check "$chk_dir/bad.thera" 2>/dev/null)"
  chk_err="$("$THERA" check "$chk_dir/bad.thera" 2>&1 1>/dev/null)"
  if printf '%s' "$chk_out" | grep -q 'undefined name: missing' \
     && ! printf '%s' "$chk_err" | grep -q 'undefined name: missing'; then
    echo "  ok   diagnostics on stdout, not stderr"
  else
    echo "  FAIL check diagnostics stream (stdout='$chk_out')"; fail=1
  fi
  rm -rf "$chk_dir"

  echo "==> fmt --check (read-only; lists unformatted files, exit 1)"
  # `thera fmt --check` must not modify files, list the ones needing formatting on
  # stdout, and exit 0 (all formatted) / 1 (some need formatting) — the CI /
  # pre-commit contract. (See docs/roadmap.md, "Formatter (thera fmt)".)
  fmt_dir="$(mktemp -d)"
  printf 'fn f() {\n    x();\n}\n' > "$fmt_dir/clean.thera"
  printf 'fn g() {\ny();\n}\n' > "$fmt_dir/dirty.thera"
  cp "$fmt_dir/dirty.thera" "$fmt_dir/dirty.orig"
  "$THERA" fmt --check "$fmt_dir/clean.thera" >/dev/null 2>&1; clean_code=$?
  dirty_out="$("$THERA" fmt --check "$fmt_dir/dirty.thera" 2>/dev/null)"; dirty_code=$?
  if [ "$clean_code" -eq 0 ] && [ "$dirty_code" -eq 1 ] \
     && printf '%s' "$dirty_out" | grep -q 'dirty.thera' \
     && diff -q "$fmt_dir/dirty.thera" "$fmt_dir/dirty.orig" >/dev/null; then
    echo "  ok   fmt --check: clean=0, dirty=1 (listed), file untouched"
  else
    echo "  FAIL fmt --check (clean=$clean_code dirty=$dirty_code out='$dirty_out')"; fail=1
  fi
  rm -rf "$fmt_dir"

  # The tree itself must stay a fmt fixpoint — `fmt --check` over the whole corpus
  # must report nothing. Guards against unformatted code landing (the CI gate).
  tree_out="$("$THERA" fmt --check pkgs/cli sdk/std examples bench 2>/dev/null)"; tree_code=$?
  if [ "$tree_code" -eq 0 ] && [ -z "$tree_out" ]; then
    echo "  ok   fmt --check: corpus is a fixpoint"
  else
    echo "  FAIL fmt --check: unformatted files:"; printf '%s\n' "$tree_out"; fail=1
  fi

  echo "==> diagnostic attribution (imported-file error names the import)"
  # An error in an imported file must be attributed to *that* file, not the
  # entrypoint that triggered the compile — a diagnostic span carries source text,
  # not a path, so the reporter resolves the owning file. (See docs/roadmap.md,
  # "Whole-closure diagnostics with per-file origin".)
  att_dir="$(mktemp -d)"
  printf 'pub fn greet(_ n: String) -> String { return n.frobnicate(); }\n' > "$att_dir/helper.thera"
  printf "import 'helper';\nfn main() -> Int { println(helper.greet('hi')); return 0; }\n" > "$att_dir/app.thera"
  att_out="$("$THERA" run "$att_dir/app.thera" 2>&1)"; att_code=$?
  if printf '%s' "$att_out" | grep -q 'helper.thera:.*frobnicate' \
     && ! printf '%s' "$att_out" | grep -q 'app.thera:.*frobnicate' \
     && [ "$att_code" -ne 0 ]; then
    echo "  ok   imported-file error attributed to the import (exit $att_code)"
  else
    echo "  FAIL diagnostic attribution (out='$att_out', code=$att_code)"; fail=1
  fi
  # A *parse* error in an imported file must be surfaced (not dropped into a
  # misleading downstream error under exit 0) and attributed to the import.
  printf 'pub fn greet(_ n: String) -> String {\n    let x = ;\n    return n;\n}\n' > "$att_dir/helper.thera"
  pe_out="$("$THERA" check "$att_dir/app.thera" 2>&1)"; pe_code=$?
  if printf '%s' "$pe_out" | grep -q 'helper.thera:2:.*unexpected token' && [ "$pe_code" -ne 0 ]; then
    echo "  ok   imported-file parse error surfaced + attributed (exit $pe_code)"
  else
    echo "  FAIL imported parse error (out='$pe_out', code=$pe_code)"; fail=1
  fi
  rm -rf "$att_dir"

  echo "==> qualified-reference guard (corpus stays at 0 bare cross-library refs)"
  # The whole corpus is qualified-only: every reference to another library's public
  # name goes through `ns.name` (or an explicit `import '…' as _;`). This is now
  # enforced — `check` reports a "bare reference to …" error for each violation —
  # so a regression fails the build outright; this guard keeps the count explicit
  # (and the message clear). See docs/language.md.
  bare_refs="$("$THERA" check pkgs/cli sdk/std examples 2>/dev/null \
    | grep -c 'bare reference to')"
  if [ "$bare_refs" -eq 0 ]; then
    echo "  ok   0 bare cross-library references"
  else
    echo "  FAIL $bare_refs bare cross-library reference(s); run: thera check pkgs/cli sdk/std examples"
    fail=1
  fi

  echo "==> fmt guard (corpus stays canonically formatted)"
  # The whole corpus is kept formatted; `thera fmt --check` lists any file that would
  # change and exits non-zero. A drift fails the build with the fix command. See
  # docs/roadmap.md, "Formatter (thera fmt)".
  unformatted="$("$THERA" fmt --check pkgs/cli sdk/std examples 2>/dev/null)"; fmt_code=$?
  if [ "$fmt_code" -eq 0 ]; then
    echo "  ok   corpus is formatted"
  else
    echo "  FAIL these files need formatting; run: thera fmt pkgs/cli sdk/std examples"
    printf '%s\n' "$unformatted" | sed 's/^/         /'
    fail=1
  fi

  echo "==> inference-context oracle (codegen and checker build identical InferCtx)"
  # A divergence between the inference context codegen builds and the one the
  # checker builds is the root of the bug class where the two stages infer the same
  # expression to different types. The oracle (THERA_INFER_ORACLE, in codegen)
  # compares them per unit; this guard asserts the whole front-end stays at zero
  # divergences. See docs/roadmap.md (Owner-correct ... / the oracle commit).
  oracle_tmp="$(mktemp)"
  oracle_diverged="$(THERA_INFER_ORACLE=1 "$THERA" emit pkgs/cli/main.thera "$oracle_tmp" 2>&1 \
    | grep -oE '[0-9]+/[0-9]+ non-lambda' | head -1 | cut -d/ -f1)"
  rm -f "$oracle_tmp"
  if [ "${oracle_diverged:-1}" -eq 0 ]; then
    echo "  ok   0 units with divergent inference context"
  else
    echo "  FAIL $oracle_diverged unit(s) diverge; run: THERA_INFER_ORACLE=1 thera emit pkgs/cli/main.thera /tmp/x.thera-bc"
    fail=1
  fi
}

phase_conformance() {
  echo "==> language conformance (tests/lang)"
  # Spec-conformance tests: each tests/lang/**/*.thera pins a documented language
  # feature via embedded `//!` directives + `// expect…` comments. The harness
  # (a Thera program) shells back to `thera` per test and compares. xfail tests that
  # unexpectedly pass (XPASS) fail the suite. See tests/lang/README.md.
  "$THERA" run tests/lang_runner.thera "$THERA" "$ROOT/tests/lang" "$ROOT/docs/conformance.md" || fail=1
}

phase_examples() {
  echo "==> examples"
  # Pin the output of a few representative examples (the rest must just run).
  check_out() {
    local file="$1" expected="$2"
    local got
    got="$("$THERA" run "$file" 2>&1)"
    if [ "$got" = "$expected" ]; then
      echo "  ok   $file"
    else
      echo "  FAIL $file"; echo "--- expected ---"; echo "$expected"; echo "--- got ---"; echo "$got"; fail=1
    fi
  }
  check_out examples/fibers.thera $'sum of squares 1..5 = 55\nconsumed 10 values, sum = 55'
  check_out examples/list_hof.thera $'20\n40\n60\nbig: 2\ntotal: 21'

  # Every other example must at least run cleanly. wordcount needs a file argument;
  # *_test.thera are test files.
  for f in examples/*.thera; do
    case "$f" in
      *_test.thera|*fibers.thera|*list_hof.thera) continue ;;
      *wordcount.thera) "$THERA" run "$f" examples/wordcount.thera >/dev/null 2>&1 ;;
      *) "$THERA" run "$f" >/dev/null 2>&1 ;;
    esac
    if [ $? -eq 0 ]; then echo "  ok   $f"; else echo "  FAIL $f"; fail=1; fi
  done

  # Benchmarks (bench/) are manual perf harnesses; just check they run cleanly.
  for f in bench/*.thera; do
    "$THERA" run "$f" >/dev/null 2>&1
    if [ $? -eq 0 ]; then echo "  ok   $f"; else echo "  FAIL $f"; fail=1; fi
  done
}

# No args = the full local suite; otherwise run just the named groups (CI shards).
groups=("$@")
if [ "${#groups[@]}" -eq 0 ]; then
  groups=(cargo frontend stdlib checks conformance examples)
fi
for g in "${groups[@]}"; do
  case "$g" in
    cargo)       phase_cargo ;;
    frontend)    phase_frontend ;;
    stdlib)      phase_stdlib ;;
    checks)      phase_checks ;;
    conformance) phase_conformance ;;
    examples)    phase_examples ;;
    *) echo "test.sh: unknown group '$g' (want: cargo frontend stdlib checks conformance examples)" >&2; fail=1 ;;
  esac
done

echo
if [ "$fail" -eq 0 ]; then echo "ALL TESTS PASSED"; else echo "SOME TESTS FAILED"; fi
exit "$fail"
