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
