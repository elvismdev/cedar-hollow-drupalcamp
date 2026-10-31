#!/usr/bin/env bash
set -uo pipefail
ROOT="$(git rev-parse --show-toplevel)/.github/claude-review"
. "$ROOT/tools/agent/test/assert.sh"
D="$ROOT/tools/review/diff-addressable-lines.sh"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
g () { git -C "$tmp/repo" -c user.email=t@t -c user.name=t "$@"; }

# A branch that adds one file, then main moving on past the branch point with
# a change to a shared file and a file of its own.
git init -q -b main "$tmp/repo"
printf 'one\ntwo\nthree\n' > "$tmp/repo/shared.txt"
g add -A && g commit -qm base
g checkout -qb feature
printf 'branch line\n' > "$tmp/repo/feature.txt"
g add -A && g commit -qm feature
g checkout -q main
printf 'one\nTWO\nthree\n' > "$tmp/repo/shared.txt"
printf 'main only\n' > "$tmp/repo/main-only.txt"
g add -A && g commit -qm "main moves"

# The fixture is a real hazard: a two-dot diff names files the branch never touched.
two_dot=$(g diff --name-only main..feature | sort | tr '\n' ' ')
assert_eq "feature.txt main-only.txt shared.txt " "$two_dot" "the two-dot diff names main's files too"

out=$(cd "$tmp/repo" && bash "$D" main feature 2>"$tmp/err"); rc=$?
assert_exit 0 "$rc" "the map builds once main has moved past the branch point"
assert_eq "feature.txt:1" "$out" "the map names only the lines the branch added"

# Unrelated histories: no merge base, so the change cannot be bounded.
g checkout -q --orphan unrelated
g rm -rqf .
printf 'elsewhere\n' > "$tmp/repo/other.txt"
g add -A && g commit -qm unrelated
g checkout -q main
out=$(cd "$tmp/repo" && bash "$D" main unrelated 2>&1); rc=$?
assert_exit 1 "$rc" "no merge base fails"
assert_contains "$out" "no merge base" "and says why"

out=$(cd "$tmp/repo" && bash "$D" main 2>&1); rc=$?
assert_exit 2 "$rc" "a missing head argument is a usage error"

pass
