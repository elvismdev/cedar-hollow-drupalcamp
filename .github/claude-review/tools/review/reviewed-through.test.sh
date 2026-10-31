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

# The ordinary re-review: the last round was posted against an earlier commit.
assert_contains "$(run "$(feed "$C2")")" "state=incremental" "a prior review on an ancestor is incremental"
assert_contains "$(run "$(feed "$C2")")" "since=$C2" "and reports that commit as the since-sha"

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
human='printf "[{\"user\":{\"login\":\"elvismdev\"},\"commit_id\":\"'"$C2"'\",\"submitted_at\":\"2026-01-01T00:00:00Z\",\"body\":\"Claude bugs review: looks fine\"}]"'
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

pass "reviewed-through.test.sh"
