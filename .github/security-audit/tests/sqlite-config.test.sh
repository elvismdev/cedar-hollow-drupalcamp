#!/usr/bin/env bash
# Tests for sqlite-config.sh: the copy differs from config/ only by the added
# sqlite line, in sorted position, and config/ itself is unchanged.
set -euo pipefail
# shellcheck source=../../claude-review/tools/agent/test/assert.sh
. "$(dirname "$0")/../../claude-review/tools/agent/test/assert.sh"
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
SCRIPT="$ROOT/.github/security-audit/sqlite-config.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

tree_sum() { # dir: hash of every file's path, mode and content
  (cd "$1" && find . -type f -print0 | sort -z | xargs -0 stat -c '%n %a' | sha256sum
   cd "$1" && find . -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum) | sha256sum | cut -d' ' -f1
}

before="$(tree_sum "$ROOT/config")"
bash "$SCRIPT" "$WORK/copy"
assert_eq "$before" "$(tree_sum "$ROOT/config")" "config/ is unchanged"

# The only difference is one added line in core.extension.yml.
rc=0
diff -r "$ROOT/config" "$WORK/copy" > "$WORK/diff.txt" || rc=$?
assert_exit 1 "$rc" "the copy differs from config/"
assert_eq "1" "$(grep -c '^diff ' "$WORK/diff.txt" || true)" "exactly one file differs"
assert_contains "$(head -n1 "$WORK/diff.txt")" "core.extension.yml" "the differing file is core.extension.yml"
assert_eq "> sqlite: 0" "$(grep '^[<>]' "$WORK/diff.txt" | tr -s ' ')" "the difference is the added sqlite line only"
assert_eq "$(find "$ROOT/config" -type f | wc -l)" "$(find "$WORK/copy" -type f | wc -l)" "same number of files"
assert_eq "$(stat -c %a "$ROOT/config/core.extension.yml")" "$(stat -c %a "$WORK/copy/core.extension.yml")" "core.extension.yml keeps its mode"

# The module list stays sorted by weight, then name.
awk '/^module:$/{m=1;next} m&&/^[^ ]/{m=0} m{sub(/:/,"");print $2, $1}' "$WORK/copy/core.extension.yml" > "$WORK/modules.txt"
assert_eq "$(LC_ALL=C sort -k1,1n -k2,2 "$WORK/modules.txt")" "$(cat "$WORK/modules.txt")" "module list is sorted by weight, then name"
assert_contains "$(cat "$WORK/modules.txt")" "0 sqlite" "sqlite is in the module list with weight 0"

pass sqlite-config.test.sh
