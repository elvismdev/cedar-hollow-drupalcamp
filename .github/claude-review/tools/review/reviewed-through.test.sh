#!/usr/bin/env bash
set -uo pipefail
ROOT="$(git rev-parse --show-toplevel)/.github/claude-review"
. "$ROOT/tools/agent/test/assert.sh"
R="$ROOT/tools/review/reviewed-through.sh"

# A throwaway repository supplies real commits, because the decision is a git
# question as much as an API one: a sha can be recorded and still be unusable
# after a force-push or a rebase, and only git says which.
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
cd "$tmp" || exit 1
git init -q .
git config user.email t@example.invalid
git config user.name T
printf 'one\n' > f; git add f; git commit -q -m one; C1=$(git rev-parse HEAD)
printf 'two\n' >> f; git commit -q -am two; C2=$(git rev-parse HEAD)
printf 'three\n' >> f; git commit -q -am three; C3=$(git rev-parse HEAD)
# A commit on a discarded line of history: exists in the object store, is not an
# ancestor of the head. This is the shape a rebase or an amend leaves behind.
git checkout -q -b other "$C1"
printf 'other\n' >> f; git commit -q -am other; ORPHAN=$(git rev-parse HEAD)
git checkout -q master 2>/dev/null || git checkout -q main
# The base the head contains: the review job's checkout of main has it as
# origin/main.
git update-ref refs/remotes/origin/main "$C1"

BOT='github-actions[bot]'
feed () {  # <commit_id> [angle]
	printf 'printf %s' "'[{\"user\":{\"login\":\"$BOT\"},\"commit_id\":\"$1\",\"submitted_at\":\"2026-01-01T00:00:00Z\",\"body\":\"Claude ${2:-bugs} review: 1 finding(s).\"}]'"
}
run () { REVIEW_REVIEWS_CMD="$1" bash "$R" 1 "${2:-bugs}" "${3:-$C3}" 2>&1; }
rc  () { REVIEW_REVIEWS_CMD="$1" bash "$R" 1 "${2:-bugs}" "${3:-$C3}" >/dev/null 2>&1; echo $?; }

# No prior review of this angle: the whole change is new, so review all of it.
none='printf "[]"'
assert_eq "0" "$(rc "$none")" "no prior review exits 0"
assert_contains "$(run "$none")" "state=full" "no prior review asks for a full review"
assert_contains "$(run "$none")" "since=" "and names no since-sha"
assert_contains "$(run "$none")" "diff_from=" "and no diff_from"

# The ordinary re-review: the last round was posted against an earlier commit.
assert_contains "$(run "$(feed "$C2")")" "state=incremental" "a prior review on an ancestor is incremental"
assert_contains "$(run "$(feed "$C2")")" "since=$C2" "and reports that commit as the since-sha"
# With no merge from main, the clean merge of the last reviewed commit with the
# base is that commit's own tree, so the diff is the ordinary since..head one.
assert_contains "$(run "$(feed "$C2")")" "diff_from=$(git rev-parse "$C2^{tree}")" "and diffs from that commit's tree"

# A feed larger than one environment string may hold (128 KiB on Linux): every
# owner reply is a review object too, so a long-lived pull request reaches it.
python3 -I - "$tmp/big-feed.json" "$C2" <<'PY2'
import json, sys
pad = 'x' * 2048
reviews = [{"user": {"login": "repo-owner"}, "commit_id": sys.argv[2],
            "submitted_at": "2026-01-02T00:00:00Z", "body": pad} for _ in range(70)]
reviews.append({"user": {"login": "github-actions[bot]"}, "commit_id": sys.argv[2],
                "submitted_at": "2026-01-01T00:00:00Z", "body": "Claude bugs review: " + pad})
open(sys.argv[1], 'w').write(json.dumps(reviews))
PY2
[ "$(stat -c %s "$tmp/big-feed.json")" -gt 131072 ] || { echo "FAIL: the large feed fixture is under 128 KiB" >&2; exit 1; }
assert_contains "$(run "cat $tmp/big-feed.json")" "since=$C2" "a feed over 128 KiB is read and its review found"

# Nothing new since the last round. Running an agent on an empty diff invents
# findings out of nothing, so this is its own state rather than a full review.
assert_contains "$(run "$(feed "$C3")")" "state=current" "a prior review on the head means nothing new"

# A recorded sha that is not an ancestor of the head cannot bound a diff: the
# range would be computed across a discarded history. Full review instead.
assert_contains "$(run "$(feed "$ORPHAN")")" "state=full" "a non-ancestor sha falls back to a full review"
assert_contains "$(run "$(feed "$ORPHAN")")" "not an ancestor" "and says why"

# A force-push can leave a sha the checkout no longer has at all.
gone='printf "[{\"user\":{\"login\":\"github-actions[bot]\"},\"commit_id\":\"deadbeefdeadbeefdeadbeefdeadbeefdeadbeef\",\"submitted_at\":\"2026-01-01T00:00:00Z\",\"body\":\"Claude bugs review: ok\"}]"'
assert_contains "$(run "$gone")" "state=full" "a sha absent from the checkout falls back to a full review"

# The angles review separately and converge separately: a security round saying
# it read through C2 tells the bugs reviewer nothing.
assert_contains "$(run "$(feed "$C2" security)" bugs)" "state=full" "another angle's review is not this angle's"
assert_contains "$(run "$(feed "$C2" security)" security)" "since=$C2" "and its own angle is read"

# Only the bot's reviews count. A human's approval is not a review round, and
# taking its commit_id would silently shrink the next review's surface.
human='printf "[{\"user\":{\"login\":\"repo-owner\"},\"commit_id\":\"'"$C2"'\",\"submitted_at\":\"2026-01-01T00:00:00Z\",\"body\":\"Claude bugs review: looks fine\"}]"'
assert_contains "$(run "$human")" "state=full" "a human review is not a prior round"

# Newest wins, and the feed is not assumed to arrive in order.
two="printf '[{\"user\":{\"login\":\"$BOT\"},\"commit_id\":\"$C1\",\"submitted_at\":\"2026-01-02T00:00:00Z\",\"body\":\"Claude bugs review: a\"},{\"user\":{\"login\":\"$BOT\"},\"commit_id\":\"$C2\",\"submitted_at\":\"2026-01-03T00:00:00Z\",\"body\":\"Claude bugs review: b\"}]'"
assert_contains "$(run "$two")" "since=$C2" "the newest prior review wins"

# gh api --paginate prints one JSON array per page in some shapes and a single
# merged array in others: measured here, `--paginate` alone merges, `--jq` runs
# per page, and `--slurp` nests. The shape therefore depends on a tool version
# this repository does not pin, so the reader accepts a sequence of documents
# rather than betting on one of them.
pages="printf '[{\"user\":{\"login\":\"$BOT\"},\"commit_id\":\"$C1\",\"submitted_at\":\"2026-01-01T00:00:00Z\",\"body\":\"Claude bugs review: a\"}]\n[{\"user\":{\"login\":\"$BOT\"},\"commit_id\":\"$C2\",\"submitted_at\":\"2026-01-02T00:00:00Z\",\"body\":\"Claude bugs review: b\"}]'"
assert_eq "0" "$(rc "$pages")" "a feed arriving as one array per page is read"
assert_contains "$(run "$pages")" "since=$C2" "and the newest across pages wins"

# An unreadable feed must not silently become a full review: a full review is a
# plausible-looking outcome, so the failure would never be noticed.
bad='printf "not json"'
assert_eq "1" "$(rc "$bad")" "an unreadable feed fails"
assert_contains "$(run "$bad")" "not readable" "and says so"

# Updates that merge main into the branch. The base is the newest main commit
# the head contains, its merge base with origin/main, and the last reviewed
# commit merged cleanly with that base is what the head would be with no new
# work. A separate repository, so main and the branch share a file.
m="$tmp/merges"; mkdir -p "$m"; cd "$m" || exit 1
git init -q -b main .
git config user.email t@example.invalid
git config user.name T
seq 1 40 > f; git add f; git commit -q -m base
git checkout -q -b feature
sed -i 's/^1$/branch-one/' f; git commit -q -am "branch edit"; P=$(git rev-parse HEAD)
git checkout -q main
sed -i 's/^40$/main-forty/' f; git commit -q -am "main edit"; M1=$(git rev-parse HEAD)
sed -i 's/^30$/main-thirty/' f; git commit -q -am "main moves on"; M2=$(git rev-parse HEAD)
# A merge of M1 with no edits.
git checkout -q -b clean-merge "$P"; git merge -q --no-edit "$M1" >/dev/null; H1=$(git rev-parse HEAD)
# The same merge with a hand edit in it.
git checkout -q -b edited-merge "$P"; git merge -q --no-commit "$M1" >/dev/null 2>&1
sed -i 's/^20$/hand-edit/' f; git add f; git commit -q --no-edit; H2=$(git rev-parse HEAD)
# A merge whose resolution conflicts: main changed the branch's line too.
git checkout -q -b clash "$M1"; sed -i 's/^1$/main-one/' f; git commit -q -am "main edits line one"; MC=$(git rev-parse HEAD)
git checkout -q -b conflicted "$P"; git merge -q --no-edit "$MC" >/dev/null 2>&1
printf 'resolved\n' > f; git add f; git commit -q --no-edit; H3=$(git rev-parse HEAD)

git update-ref refs/remotes/origin/main "$M1"
out=$(run "$(feed "$P")" bugs "$H1")
assert_contains "$out" "state=current" "a merge from main with no edits needs no new round"

out=$(run "$(feed "$P")" bugs "$H2")
assert_contains "$out" "state=incremental" "a hand-edited merge is reviewed"
assert_contains "$out" "since=$P" "from the last reviewed commit"
T=$(git merge-tree --write-tree "$M1" "$P")
assert_contains "$out" "diff_from=$T" "with the diff taken from the clean merge"
assert_contains "$(git diff "$T" "$H2")" "+hand-edit" "a diff that holds the hand edit"
case "$(git diff "$T" "$H2")" in *main-forty*) mainc=0;; *) mainc=1;; esac
assert_exit 1 "$mainc" "and not main's change"

git update-ref refs/remotes/origin/main "$M2"
out=$(run "$(feed "$P")" bugs "$H1")
assert_contains "$out" "state=current" "main advancing after the branch's merge does not undo it"

git update-ref refs/remotes/origin/main "$MC"
out=$(run "$(feed "$P")" bugs "$H3")
assert_contains "$out" "state=full" "a merge that conflicts falls back to a full review"
assert_contains "$out" "diff_from=" "with no diff_from"

pass "reviewed-through.test.sh"
