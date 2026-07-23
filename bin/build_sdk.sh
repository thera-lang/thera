#!/usr/bin/env bash
#
# Build the Thera SDK: the runtime plus the compiled front-end and the standard
# library sources. The artifact lands in build/sdk/:
#
#   build/sdk/
#     bin/thera                  ← the runtime (loads the front-end below)
#     bin/inc/frontend.thera-bc  ← the compiled front-end, loaded at runtime
#     std/                       ← stdlib sources (copied from sdk/std)
#     version                    ← <pkg-version>+<gitsha>, read back by --version
#
# Stages:
#   0. cargo build the bare runtime (skipped if it's already present — e.g. CI
#      restored it from cache; the binary is a pure function of runtime/ source)
#   1. emit frontend.thera-bc from pkgs/cli using the checked-in bootstrap snapshot
#      (bootstrap/frontend.thera-bc) run on that runtime — no external toolchain
#   2. assemble the artifact directory (one build: the front-end is loaded from
#      bin/inc/ at runtime, not embedded, so there's no second compile/relink)
#   3. fixpoint check: the assembled SDK re-emits its own front-end and the bytes
#      must match stage 1 (proves the front-end reproduces its own compiler)
#
# Self-hosting bootstrap — the snapshot compiles the next front-end; see
# bootstrap/README.md. (The old Dart bootstrap + byte oracle are retired.)
#
# A single-binary release (front-end baked in, no bin/inc/) is still possible via
# `THERA_FRONTEND_BC=<blob> cargo build --release`; this script ships the
# load-at-runtime shape so building it costs one compile, not two.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/build"
SDK="$BUILD/sdk"
FRONTEND_BC="$BUILD/frontend.thera-bc"
SNAPSHOT="$ROOT/bootstrap/frontend.thera-bc"

PROFILE="${THERA_BUILD_PROFILE:-release}"
case "$PROFILE" in
  release) CARGO_PROFILE_FLAG="--release"; TARGET_SUBDIR="release" ;;
  debug)   CARGO_PROFILE_FLAG="";          TARGET_SUBDIR="debug" ;;
  *) echo "build_sdk: unknown profile '$PROFILE' (want release|debug)" >&2; exit 2 ;;
esac

mkdir -p "$BUILD"
THERA_RT="$ROOT/runtime/target/$TARGET_SUBDIR/thera-rt"

echo "==> [0/3] building the bare runtime ($PROFILE)"
# Skip the compile when the binary is already in place — CI restores it from a
# cache keyed on runtime/ source, so an unchanged runtime needs no toolchain.
if [ -x "$THERA_RT" ]; then
  echo "    reusing $THERA_RT (already built)"
else
  ( cd "$ROOT/runtime" && cargo build $CARGO_PROFILE_FLAG )
fi

echo "==> [1/3] emitting frontend.thera-bc from the bootstrap snapshot"
"$THERA_RT" "$SNAPSHOT" emit "$ROOT/pkgs/cli/main.thera" "$FRONTEND_BC"

echo "==> [2/3] assembling build/sdk"
rm -rf "$SDK"
mkdir -p "$SDK/bin/inc"
cp "$THERA_RT" "$SDK/bin/thera"
cp "$FRONTEND_BC" "$SDK/bin/inc/frontend.thera-bc"
cp -R "$ROOT/sdk/std" "$SDK/std"
# The build stamp lives here (not baked into the binary), so `--version` reports
# the revision without the binary depending on the git SHA. Computed from git, so
# it's independent of the (possibly cached) binary.
PKG_VERSION="$(sed -n 's/^version = "\(.*\)"/\1/p' "$ROOT/runtime/Cargo.toml" | head -1)"
GIT_SHA="$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)"
VERSION="${PKG_VERSION}+${GIT_SHA}"
echo "$VERSION" > "$SDK/version"
echo "    version $VERSION"

echo "==> [3/3] fixpoint check (SDK re-emits its own front-end)"
FRONTEND_BC2="$BUILD/frontend.fixpoint.thera-bc"
time "$SDK/bin/thera" emit "$ROOT/pkgs/cli/main.thera" "$FRONTEND_BC2"
if cmp -s "$FRONTEND_BC" "$FRONTEND_BC2"; then
  echo "    ok: the SDK reproduces its own front-end byte-for-byte"
else
  echo "    FAIL: the SDK-built front-end does not reproduce itself" >&2
  echo "    ($FRONTEND_BC vs $FRONTEND_BC2)" >&2
  echo "    If pkgs/cli added new syntax, refresh bootstrap/frontend.thera-bc" >&2
  echo "    (see bootstrap/README.md)." >&2
  exit 1
fi

echo "==> done: $SDK"
