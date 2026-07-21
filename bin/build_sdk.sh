#!/usr/bin/env bash
#
# Build the binary Hawk SDK: the runtime with the compiled front-end embedded,
# plus the standard library sources. The artifact lands in build/sdk/:
#
#   build/sdk/
#     bin/hawk    ← bare runtime + embedded frontend.hawkbc
#     std/        ← stdlib sources (copied from sdk/std)
#     version     ← <pkg-version>+<gitsha>
#
# Stages:
#   0. emit frontend.hawkbc from pkgs/cli using the checked-in bootstrap snapshot
#      (bootstrap/frontend.hawkbc) run on the bare runtime — no external toolchain
#   1. cargo build the runtime with that blob embedded (HAWK_FRONTEND_BC)
#   2. assemble the artifact directory
#   3. fixpoint check: the built SDK re-emits its own front-end and the bytes must
#      match stage 0 (proves the front-end reproduces its own compiler)
#
# Self-hosting bootstrap — the snapshot compiles the next front-end; see
# bootstrap/README.md. (The old Dart bootstrap + byte oracle are retired.)

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/build"
SDK="$BUILD/sdk"
FRONTEND_BC="$BUILD/frontend.hawkbc"
SNAPSHOT="$ROOT/bootstrap/frontend.hawkbc"

PROFILE="${HAWK_BUILD_PROFILE:-release}"
case "$PROFILE" in
  release) CARGO_PROFILE_FLAG="--release"; TARGET_SUBDIR="release" ;;
  debug)   CARGO_PROFILE_FLAG="";          TARGET_SUBDIR="debug" ;;
  *) echo "build_sdk: unknown profile '$PROFILE' (want release|debug)" >&2; exit 2 ;;
esac

mkdir -p "$BUILD"

echo "==> [0/3] emitting frontend.hawkbc from the bootstrap snapshot"
# A bare runtime (no embedded front-end) to run the snapshot on.
( cd "$ROOT/runtime" && cargo build $CARGO_PROFILE_FLAG )
HAWKRT="$ROOT/runtime/target/$TARGET_SUBDIR/hawkrt"
"$HAWKRT" "$SNAPSHOT" emit "$ROOT/pkgs/cli/main.thera" "$FRONTEND_BC"

echo "==> [1/3] building runtime with the front-end embedded ($PROFILE)"
( cd "$ROOT/runtime" && HAWK_FRONTEND_BC="$FRONTEND_BC" cargo build $CARGO_PROFILE_FLAG )

echo "==> [2/3] assembling build/sdk"
rm -rf "$SDK"
mkdir -p "$SDK/bin"
cp "$ROOT/runtime/target/$TARGET_SUBDIR/hawkrt" "$SDK/bin/hawk"
cp -R "$ROOT/sdk/std" "$SDK/std"
VERSION="$("$SDK/bin/hawk" --version | sed 's/^hawk //')"
echo "$VERSION" > "$SDK/version"
echo "    version $VERSION"

echo "==> [3/3] fixpoint check (SDK re-emits its own front-end)"
FRONTEND_BC2="$BUILD/frontend.fixpoint.hawkbc"
time "$SDK/bin/hawk" emit "$ROOT/pkgs/cli/main.thera" "$FRONTEND_BC2"
if cmp -s "$FRONTEND_BC" "$FRONTEND_BC2"; then
  echo "    ok: the SDK reproduces its own front-end byte-for-byte"
else
  echo "    FAIL: the SDK-built front-end does not reproduce itself" >&2
  echo "    ($FRONTEND_BC vs $FRONTEND_BC2)" >&2
  echo "    If pkgs/cli added new syntax, refresh bootstrap/frontend.hawkbc" >&2
  echo "    (see bootstrap/README.md)." >&2
  exit 1
fi

echo "==> done: $SDK"
