#!/usr/bin/env bash
# The review action reads main as refs/remotes/origin/main. Git resolves a bare
# origin/main through refs/tags before refs/remotes, so a tag named origin/main
# would decide the merge base of the head check and the base every prompt and
# the addressable-line map are built from. The head and pr steps' own scripts
# run here against a clone holding such a tag.
set -uo pipefail
ROOT="$(git rev-parse --show-toplevel)/.github/claude-review"
. "$ROOT/tools/agent/test/assert.sh"
ACTION="$ROOT/review/action.yml"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

# step_run <id>: prints a step's run script from the action.
step_run () {
	python3 -I - "$ACTION" "$1" <<'PY'
import sys, yaml
for s in yaml.safe_load(open(sys.argv[1]))["runs"]["steps"]:
    if s.get("id") == sys.argv[2]:
        print(s["run"])
        sys.exit(0)
sys.exit(1)
PY
}
step_run head > "$tmp/head.sh" || { echo "FAIL: the action has no head step" >&2; exit 1; }
step_run pr > "$tmp/pr.sh" || { echo "FAIL: the action has no pr step" >&2; exit 1; }

# An origin with main and a pull request head two commits past it, I and then
# H, and the job's clone of it with a tag named origin/main on the head itself.
o="$tmp/origin.git"; w="$tmp/work"
git init -q --bare -b main "$o"
git clone -q "$o" "$tmp/seed" 2>/dev/null
(cd "$tmp/seed" && git config user.email t@example.invalid && git config user.name T \
 && printf 'base\n' > a && git add a && git commit -q -m base && git push -q origin HEAD:refs/heads/main \
 && printf 'first\n' > i && git add i && git commit -q -m first \
 && printf 'change\n' > b && git add b && git commit -q -m change && git push -q origin HEAD:refs/pull/1/head)
B=$(git -C "$o" rev-parse refs/heads/main); H=$(git -C "$o" rev-parse refs/pull/1/head)
I=$(git -C "$o" rev-parse "$H^")
git clone -q "$o" "$w"
git -C "$w" tag origin/main "$H"

# A fake gh: the pulls API reports the head and one changed file, and
# gh pr view reports main as the base.
mkdir -p "$tmp/bin"
cat > "$tmp/bin/gh" <<SH
#!/usr/bin/env bash
case "\$*" in
  *pulls/1*) echo "$H 1" ;;
  *baseRefName*) echo "main $B" ;;
  *title*) printf 'title\n\nbody\n' ;;
  *) exit 1 ;;
esac
SH
chmod +x "$tmp/bin/gh"
# A git that, when MB_LOG is set, records what each merge-base call printed.
real_git=$(command -v git)
cat > "$tmp/bin/git" <<SH
#!/usr/bin/env bash
if [ "\$1" = merge-base ] && [ -n "\${MB_LOG:-}" ]; then
  out=\$("$real_git" "\$@"); rc=\$?
  printf '%s\\n' "\$out" | tee -a "\$MB_LOG"
  exit "\$rc"
fi
exec "$real_git" "\$@"
SH
chmod +x "$tmp/bin/git"

# step <script> <env...>: runs a step's script in the clone; its outputs land in $tmp/out.
step () {
	local script="$1"; shift
	: > "$tmp/out"; : > "$tmp/env"; rm -rf "$tmp/runner"; mkdir -p "$tmp/runner"
	(cd "$w" && env PATH="$tmp/bin:$PATH" GITHUB_REPOSITORY=o/r GITHUB_OUTPUT="$tmp/out" GITHUB_ENV="$tmp/env" \
		RUNNER_TEMP="$tmp/runner" GH_TOKEN=dummy "$@" bash "$script" > "$tmp/log" 2>&1); echo $?
}

assert_eq "0" "$(step "$tmp/head.sh" IN_PR=1)" "the head step passes with a tag named origin/main on the head"
assert_contains "$(cat "$tmp/out")" "sha=$H" "and fetches the head"
case "$(cat "$tmp/out")" in *empty_diff*) empty=0;; *) empty=1;; esac
assert_exit 1 "$empty" "the tag does not make the head's diff from main empty"
git -C "$w" worktree remove --force "$tmp/runner/head"

# The tag on a commit between main and the head leaves a diff that is not
# empty, so only the merge base the step takes shows the tag was not used.
git -C "$w" tag -f origin/main "$I" >/dev/null
: > "$tmp/mb.log"
assert_eq "0" "$(step "$tmp/head.sh" IN_PR=1 MB_LOG="$tmp/mb.log")" "the head step passes with a tag named origin/main between main and the head"
assert_eq "$B" "$(cat "$tmp/mb.log")" "and takes its merge base with main, not with the tag"
git -C "$w" worktree remove --force "$tmp/runner/head"

assert_eq "0" "$(step "$tmp/pr.sh" IN_PR=1 HEAD_SHA="$H")" "the pr step passes with a tag named origin/main"
base=$(sed -n 's/^base=//p' "$tmp/out")
assert_eq "$B" "$(git -C "$w" rev-parse --verify --quiet "$base" 2>/dev/null)" "the base it outputs ($base) is main, not the tag"

pass "review-action-refs.test.sh"
