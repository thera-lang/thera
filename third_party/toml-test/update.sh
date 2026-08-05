#!/usr/bin/env bash
# Refresh the vendored toml-test snapshot from an upstream release tag.
# Usage: third_party/toml-test/update.sh v2.2.0
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: $0 <upstream tag, e.g. v2.2.0>" >&2
  exit 1
fi
tag="$1"
dir="$(cd "$(dirname "$0")" && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

curl -sL "https://github.com/toml-lang/toml-test/archive/refs/tags/${tag}.tar.gz" \
  | tar xz -C "$tmp" --strip-components=1

rm -rf "$dir/tests"
mkdir -p "$dir/tests"
(cd "$tmp/tests" && rsync -R $(cat files-toml-1.0.0 | tr '\n' ' ') "$dir/tests/")
cp "$tmp/tests/files-toml-1.0.0" "$dir/tests/"
cp "$tmp/LICENSE" "$dir/"

echo "Vendored toml-test ${tag} (the files-toml-1.0.0 subset)."
echo "Now update the version line in $(dirname "$0")/README.md and re-run:"
echo "  bin/thera.sh test sdk/std/toml/conformance_test.thera"
