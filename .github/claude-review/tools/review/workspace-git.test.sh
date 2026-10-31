#!/usr/bin/env bash
set -uo pipefail
ROOT="$(git rev-parse --show-toplevel)/.github/claude-review"
. "$ROOT/tools/agent/test/assert.sh"
W="$ROOT/tools/review/workspace-git.sh"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

# A workspace that is a real repository, as the trusted checkout of main is.
export GITHUB_WORKSPACE="$tmp/ws" RUNNER_TEMP="$tmp/rt"
mkdir -p "$RUNNER_TEMP"
git init -q "$GITHUB_WORKSPACE"
printf 'x\n' > "$GITHUB_WORKSPACE/a.txt"
git -C "$GITHUB_WORKSPACE" add a.txt
git -C "$GITHUB_WORKSPACE" -c user.email=t@t -c user.name=t commit -qm one
sha=$(git -C "$GITHUB_WORKSPACE" rev-parse HEAD)

run () { bash "$W" "$@" 2>&1; }
rc  () { bash "$W" "$@" >/dev/null 2>&1; echo $?; }

# hide moves .git out of the workspace, so git finds no repository there and
# claude-code-action has nowhere to write its token.
assert_eq "0" "$(rc hide)" "hide succeeds"
[ ! -e "$GITHUB_WORKSPACE/.git" ] || { echo "FAIL: .git is still in the workspace" >&2; exit 1; }
[ -d "$RUNNER_TEMP/workspace-git" ] || { echo "FAIL: .git was not moved" >&2; exit 1; }
if git -C "$GITHUB_WORKSPACE" rev-parse --git-dir >/dev/null 2>&1; then
  echo "FAIL: git still finds a repository in the workspace" >&2; exit 1; fi
# What claude-code-action does: it fails, and nothing reaches a config.
if git -C "$GITHUB_WORKSPACE" config user.name bot >/dev/null 2>&1; then
  echo "FAIL: git config succeeded with .git away" >&2; exit 1; fi
assert_eq "1" "$(rc hide)" "hiding twice fails rather than nesting"

# check passes while .git is away and its config holds no token.
assert_eq "0" "$(rc check)" "check passes on a clean hide"

# check fails when a token reached the moved config, and prints neither the
# token nor a path.
token="ghs_$(head -c 12 /dev/urandom | od -An -tx1 | tr -d ' \n')"
git --git-dir="$RUNNER_TEMP/workspace-git" remote add origin "https://x-access-token:${token}@github.com/o/r.git"
assert_eq "1" "$(rc check)" "check fails when the config holds an access token"
out=$(run check)
case "$out" in *"$token"*|*"$tmp"*) echo "FAIL: check printed the token or a path" >&2; exit 1;; esac
assert_contains "$out" "access token" "and says why"
git --git-dir="$RUNNER_TEMP/workspace-git" remote remove origin

# check fails when a .git appeared in the workspace while the agent ran.
mkdir "$GITHUB_WORKSPACE/.git"
assert_eq "1" "$(rc check)" "check fails when the workspace has a .git again"
assert_contains "$(run check)" "has a .git" "and says why"
# restore refuses to overwrite it.
assert_eq "1" "$(rc restore)" "restore refuses to overwrite a .git in the workspace"
rmdir "$GITHUB_WORKSPACE/.git"

# restore puts it back, and git works again on the same commit.
assert_eq "0" "$(rc restore)" "restore succeeds"
assert_eq "$sha" "$(git -C "$GITHUB_WORKSPACE" rev-parse HEAD)" "git reads the same repository again"
[ ! -e "$RUNNER_TEMP/workspace-git" ] || { echo "FAIL: the moved copy is still there" >&2; exit 1; }
assert_eq "1" "$(rc restore)" "restoring with nothing moved fails"

# check fails when nothing was moved.
assert_eq "1" "$(rc check)" "check fails when .git was never moved"

# A workspace without .git cannot be hidden, and an unknown action is refused.
mv "$GITHUB_WORKSPACE/.git" "$tmp/aside"
assert_eq "1" "$(rc hide)" "hiding a workspace with no .git fails"
assert_eq "2" "$(rc other)" "an unknown action is a usage error"

pass
