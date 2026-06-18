#!/usr/bin/env bash
#
# Dev entry for the Hawk front-end (self-hosted; no external toolchain).
#
# Compiles the *current* pkgs/cli with the checked-in bootstrap snapshot
# (bootstrap/frontend.hawkbc) and runs the result on the bare runtime — so your
# in-progress front-end changes are what runs. The compiled dev front-end is
# cached in build/ and rebuilt only when pkgs/cli or sdk/std changes.
#
# Run from inside the repo (SDK-root discovery walks up from the cwd). For an
# installed, location-independent build, use `bin/build_sdk.sh` → build/sdk/.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HAWKRT="$ROOT/runtime/target/debug/hawkrt"
SNAPSHOT="$ROOT/bootstrap/frontend.hawkbc"
DEVFE="$ROOT/build/dev-frontend.hawkbc"

# The bare runtime.
if [ ! -x "$HAWKRT" ]; then
  ( cd "$ROOT/runtime" && cargo build >&2 )
fi

# (Re)build the dev front-end when any front-end/stdlib source is newer than it.
mkdir -p "$ROOT/build"
if [ ! -f "$DEVFE" ] || \
   [ -n "$(find "$ROOT/pkgs/cli" "$ROOT/sdk/std" -name '*.hawk' -newer "$DEVFE" -print -quit 2>/dev/null)" ]; then
  ( cd "$ROOT" && "$HAWKRT" "$SNAPSHOT" emit pkgs/cli/main.hawk "$DEVFE" ) >&2
fi

exec "$HAWKRT" "$DEVFE" "$@"
