#!/usr/bin/env bash
#
# Run the Thera test suite (self-hosted; no external toolchain):
#   - the Rust runtime's cargo tests
#   - the front-end's own @test suite (pkgs/cli)
#   - the standard library's @test suite (sdk/std)
#   - CLI/diagnostic behavior guards, language conformance, and examples
#
# Each `thera` invocation uses the launcher in $THERA_LAUNCHER, defaulting to the
# dev front-end via bin/thera.sh (recompiled from the current pkgs/cli). CI sets
# THERA_LAUNCHER to the prebuilt, self-contained build/sdk/bin/thera so the shards
# need no toolchain and no per-shard rebuild.
#
# Usage: test.sh [group...]
#   With no args, runs every group (the full local suite). Named groups run
#   just those, in the given order — this is how CI shards the work in parallel:
#     cargo frontend stdlib checks conformance examples

set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
THERA="${THERA_LAUNCHER:-$ROOT/bin/thera.sh}"
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

# CLI/diagnostic behavior guards + whole-corpus invariants.
#
# The process-level guards (LSP transport, profiler determinism, stream split,
# fmt --check semantics, diagnostic attribution) live in a self-hosted Thera
# program that shells out to the launcher — see tests/integration_runner.thera.
# The corpus invariants below stay here so they read as named CI steps.
phase_checks() {
  echo "==> integration guards (tests/integration_runner.thera)"
  "$THERA" run "$ROOT/tests/integration_runner.thera" "$THERA" || fail=1

  echo "==> check (corpus type-checks; any error fails the build)"
  # The whole corpus must type-check. `thera check` exits non-zero on any error
  # (warnings only inform), so the exit code is the gate — this subsumes the old
  # bare-reference guard (bare cross-library refs are `check` errors). See
  # docs/language.md. We always echo check's output so warnings stay visible even
  # when they don't gate; a `--fatal-warnings` flag is a planned fast-follow.
  chk_out="$("$THERA" check pkgs/cli sdk/std examples 2>/dev/null)"; chk_code=$?
  if [ -n "$chk_out" ]; then
    printf '%s\n' "$chk_out" | sed 's/^/       /'
  fi
  if [ "$chk_code" -eq 0 ]; then
    echo "  ok   corpus type-checks (exit 0)"
  else
    echo "  FAIL corpus has errors; run: thera check pkgs/cli sdk/std examples"
    fail=1
  fi

  echo "==> fmt --check (corpus stays canonically formatted)"
  # The whole corpus is kept formatted; `fmt --check` lists any file that would
  # change and exits non-zero. A drift fails the build with the fix command.
  fmt_out="$("$THERA" fmt --check pkgs/cli sdk/std examples bench 2>/dev/null)"; fmt_code=$?
  if [ "$fmt_code" -eq 0 ] && [ -z "$fmt_out" ]; then
    echo "  ok   corpus is a fmt fixpoint"
  else
    echo "  FAIL these files need formatting; run: thera fmt pkgs/cli sdk/std examples bench"
    printf '%s\n' "$fmt_out" | sed 's/^/         /'
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
