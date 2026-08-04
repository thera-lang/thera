#!/usr/bin/env bash
#
# Canonically format the repo's markdown — every tracked `*.md`.
#
#   bin/fmt_docs.sh           rewrite in place
#   bin/fmt_docs.sh --check   report what isn't formatted; change nothing, exit 1
#
# The format itself is `.prettierrc` (`proseWrap: always`, `printWidth: 80`),
# which has been the intended shape since the first commit — this script is just
# the one obvious way to apply it, so that hand-wrapping prose is never anybody's
# job. Reformatting is whole-file, so expect it to tidy lines you didn't touch;
# that is fine and preferable to leaving the tree half-formatted (see CLAUDE.md
# § Working conventions).
#
# Deliberately *not* wired into `bin/test.sh`. The build's defining property is
# that it needs no external toolchain, and prettier needs node — so markdown
# formatting stays a convention you run, not a gate that can fail a build on a
# machine with no npm. `--check` exists for anyone who wants it in CI anyway.
set -euo pipefail

# Pinned, so the canonical format is a function of the config and this version
# rather than of whatever `npx` happens to have cached.
readonly PRETTIER='prettier@3.9.6'

cd "$(dirname "$0")/.."

mode='--write'
if [[ ${1:-} == '--check' ]]; then
    mode='--check'
elif [[ $# -gt 0 ]]; then
    echo "usage: $(basename "$0") [--check]" >&2
    exit 2
fi

# Tracked files only: no build output, no scratch notes, nothing ignored.
files=()
while IFS= read -r f; do files+=("$f"); done < <(git ls-files '*.md')
if [[ ${#files[@]} -eq 0 ]]; then
    echo 'no markdown files found' >&2
    exit 1
fi

exec npx --yes "$PRETTIER" "$mode" "${files[@]}"
