#!/usr/bin/env bash
set -uo pipefail
ROOT="$(git rev-parse --show-toplevel)/.github/claude-review"
. "$ROOT/tools/agent/test/assert.sh"
R="$ROOT/tools/review/replace-symlinks.sh"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

# A file outside the head holding a value only this run knows, standing in for
# the workspace's .git/config.
canary="canary-$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')"
mkdir -p "$tmp/outside" && printf '%s\n' "$canary" > "$tmp/outside/config"

# A head checked out from a commit that adds links, the way the review action
# checks it out: git worktree add materialises them as symlinks.
git init -q "$tmp/repo"
(
  cd "$tmp/repo" || exit 1
  mkdir -p docs nested/deep
  printf 'plain\n' > docs/plain.md
  ln -s "$tmp/outside/config" docs/notes.md
  ln -s ../../docs/plain.md nested/deep/rel.md
  ln -s "$tmp/outside" linkdir
  ln -s /nonexistent/target dangling
  git add -A && git -c user.email=t@t -c user.name=t commit -qm links
)
git -C "$tmp/repo" worktree add -q --detach "$tmp/head" HEAD
head="$tmp/head"

# Before: reading the head follows the link out of it.
assert_eq "$canary" "$(cat "$head/docs/notes.md")" "the fixture's link reaches outside the head"

out=$(bash "$R" "$head" 2>&1); rc=$?
assert_exit 0 "$rc" "replacing the links succeeds"
assert_contains "$out" "4 symlink(s)" "and says how many it replaced"

# After: no link is left, and no head path reaches the canary.
assert_eq "" "$(find "$head" -type l)" "no symlink is left in the head"
if grep -rqF "$canary" "$head"; then echo "FAIL: a head path still reaches outside the head" >&2; exit 1; fi

# Each link became a regular file naming its target, unresolved.
assert_eq "symlink to: $tmp/outside/config" "$(cat "$head/docs/notes.md")" "an absolute link names its target"
assert_eq "symlink to: ../../docs/plain.md" "$(cat "$head/nested/deep/rel.md")" "a relative link names its target as written"
assert_eq "symlink to: $tmp/outside" "$(cat "$head/linkdir")" "a link to a directory becomes a file"
assert_eq "symlink to: /nonexistent/target" "$(cat "$head/dangling")" "a dangling link becomes a file"
[ -f "$head/docs/notes.md" ] || { echo "FAIL: the replacement is not a regular file" >&2; exit 1; }

# Regular files and what lies outside the head are untouched.
assert_eq "plain" "$(cat "$head/docs/plain.md")" "a regular file is unchanged"
assert_eq "$canary" "$(cat "$tmp/outside/config")" "the link's target is unchanged"
[ -L "$tmp/repo/docs/notes.md" ] || { echo "FAIL: a link outside the given directory was replaced" >&2; exit 1; }

# A head with no links is fine; a missing directory fails.
out=$(bash "$R" "$head" 2>&1); assert_exit 0 "$?" "a head with no links passes"
assert_contains "$out" "0 symlink(s)" "and reports none"
bash "$R" "$tmp/absent" >/dev/null 2>&1; assert_exit 1 "$?" "a missing directory fails"

pass
