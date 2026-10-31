#!/usr/bin/env bash
set -uo pipefail
ROOT="$(git rev-parse --show-toplevel)/.github/claude-review"
. "$ROOT/tools/agent/test/assert.sh"
G="$ROOT/tools/review/findings-gate.sh"

# The thread feed is injected, so every arm is exercised without a pull request.
export REVIEW_OWNER_LOGIN=repo-owner
run() { REVIEW_THREADS_CMD="$1" bash "$G" 1 2>&1; }
rc()  { REVIEW_THREADS_CMD="$1" bash "$G" 1 >/dev/null 2>&1; echo $?; }

BOT='github-actions'
# thread <resolved> <outdated> <first author> <first body> [reply author] [reply body]
# One thread as the query returns it, its first comment's url derived from its body.
node () {
	local reply=""
	[ -n "${5:-}" ] && reply=",{\"author\":{\"login\":\"$5\"},\"body\":\"${6:-done}\",\"url\":\"https://example.invalid/r\"}"
	printf '{"isResolved":%s,"isOutdated":%s,"comments":{"nodes":[{"author":{"login":"%s"},"body":"%s","url":"https://example.invalid/%s"}%s]}}' \
		"$1" "$2" "$3" "$4" "$(printf '%s' "$4" | tr -c 'a-z0-9' '-')" "$reply"
}
feed () { local IFS=,; printf 'printf %%s %q' "[$*]"; }

none='printf "[]"'
assert_eq "0" "$(rc "$none")" "no threads is a pass"
assert_contains "$(run "$none")" "open=0" "and prints open=0"

open=$(feed "$(node false false "$BOT" "important: a thing")")
assert_eq "1" "$(rc "$open")" "an open finding blocks"
assert_contains "$(run "$open")" "a thing" "and names it"

# Only a reply from the repository owner answers a thread. Resolving it or a
# later commit outdating it is not an answer: either can happen with nobody
# having read the finding.
resolved=$(feed "$(node true false "$BOT" "important: fixed")")
assert_eq "1" "$(rc "$resolved")" "a resolved thread with no reply stays open"
outdated=$(feed "$(node false true "$BOT" "important: moved")")
assert_eq "1" "$(rc "$outdated")" "an outdated thread with no reply stays open"
answered=$(feed "$(node false false "$BOT" "important: answered" repo-owner "fixed in the next commit")")
assert_eq "0" "$(rc "$answered")" "an owner reply answers it"
answered_resolved=$(feed "$(node true true "$BOT" "important: answered" repo-owner "false positive")")
assert_eq "0" "$(rc "$answered_resolved")" "an owner reply answers a resolved, outdated thread too"
other=$(feed "$(node false false "$BOT" "important: not answered" someone-else "looks fine")")
assert_eq "1" "$(rc "$other")" "a reply by anyone else does not answer it"
self=$(feed "$(node false false "$BOT" "important: not answered" "github-actions[bot]" "still there")")
assert_eq "1" "$(rc "$self")" "nor does a later comment by the bot"

# The owner's own comment thread is not a review finding and must not block.
human=$(feed "$(node false false repo-owner "what about this")")
assert_eq "0" "$(rc "$human")" "a human thread does not block"

# Pre-existing findings are reported and never block, per REVIEW.md.
pre=$(feed "$(node false false "$BOT" "pre-existing: old bug")")
assert_eq "0" "$(rc "$pre")" "a pre-existing finding does not block"
assert_contains "$(run "$pre")" "pre-existing" "though it is still reported"

# A nit does not block either. Only important findings do, and an untagged
# finding is important.
nit=$(feed "$(node false false "$BOT" "nit: naming")")
assert_eq "0" "$(rc "$nit")" "a nit does not block"
untagged=$(feed "$(node false false "$BOT" "this drops the error")")
assert_eq "1" "$(rc "$untagged")" "an untagged finding is important"

# Mixed: one important among answered ones still blocks, and the count is right.
mixed=$(feed "$(node false false "$BOT" "important: done" repo-owner "fixed")" \
	"$(node false false "$BOT" "important: still open")" \
	"$(node false false "$BOT" "nit: minor")")
assert_eq "1" "$(rc "$mixed")" "one open important among answered ones blocks"
assert_contains "$(run "$mixed")" "still open" "and names the one that blocks"

# Machine lines for the gate: the number of unanswered findings, and each one's
# tag and url. Answered threads and human threads are not listed.
out=$(run "$(feed "$(node false false "$BOT" "important: done" repo-owner "fixed")" \
	"$(node false false "$BOT" "important: still open")" \
	"$(node true false "$BOT" "nit: minor")" \
	"$(node false false repo-owner "a question")")")
assert_contains "$out" $'\nopen=2\n' "open counts the unanswered findings"
assert_contains "$out" "thread=important https://example.invalid/important--still-open" "each open thread is listed with its tag and url"
assert_contains "$out" "thread=nit https://example.invalid/nit--minor" "including a nit"
assert_eq "2" "$(printf '%s\n' "$out" | grep -c '^thread=')" "and only the open ones"

# A feed that cannot be read is not a pass. This is the whole class of failure
# this repository keeps finding: absence read as safety.
broken='printf "not json"'
assert_eq "2" "$(rc "$broken")" "an unreadable feed fails rather than passing"
fails='exit 7'
assert_eq "2" "$(rc "$fails")" "a feed command that fails is not a pass"

# With no owner login nothing could ever answer a thread, so that is refused
# rather than reported as open findings.
assert_eq "2" "$(env -u REVIEW_OWNER_LOGIN REVIEW_THREADS_CMD="$none" bash "$G" 1 >/dev/null 2>&1; echo $?)" "no owner login is refused"

# The bot login is matched exactly, so a lookalike author's thread is not
# treated as a review finding.
look=$(feed "$(node false false github-actions-helper "important: not ours")")
assert_eq "0" "$(rc "$look")" "a lookalike author does not block"

# The real app login carries a [bot] suffix and must still match.
suffixed=$(feed "$(node false false "github-actions[bot]" "important: ours")")
assert_eq "1" "$(rc "$suffixed")" "the [bot] suffixed login still blocks"

# A feed of exactly 100 may be truncated, and a pass cannot be computed from it.
hundred=()
for _ in $(seq 100); do hundred+=("$(node false false "$BOT" "nit: x")"); done
assert_eq "2" "$(rc "$(feed "${hundred[@]}")")" "a possibly truncated feed is not a pass"

# The query asks for what the reader uses, in the same shape as
# prior-findings.sh's query.
grep -q 'comments(first:100){nodes{author{login} body url}}' "$G"
assert_exit 0 "$?" "the query selects each comment's author, body and url"

pass
