#!/usr/bin/env bash
# Needs git 2.38 or later for `git merge-tree --write-tree`; run it in DDEV or CI.
set -uo pipefail
ROOT="$(git rev-parse --show-toplevel)/.github/claude-review"
. "$ROOT/tools/agent/test/assert.sh"
G="$ROOT/tools/review/gate-decide.sh"

# A throwaway repository supplies real commits for the acknowledgement check:
# whether an earlier commit plus a merge from main is the head is a git
# question, answered here by git rather than by a stub.
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
cd "$tmp" || exit 1
git init -q -b main .
git config user.email t@example.invalid
git config user.name T
printf 'base\n' > a; git add a; git commit -q -m base; B0=$(git rev-parse HEAD)
git checkout -q -b topic
printf 'work\n' > b; git add b; git commit -q -m work; A1=$(git rev-parse HEAD)
git checkout -q main
printf 'main moved\n' > c; git add c; git commit -q -m moved; B1=$(git rev-parse HEAD)
git checkout -q topic
git merge -q --no-edit main; H2=$(git rev-parse HEAD)
printf 'edit\n' >> b; git commit -q -am edit; H3=$(git rev-parse HEAD)
# The gate's checkout of main has it as origin/main.
git update-ref refs/remotes/origin/main "$B1"
: "$B0"

SUMMARY="$tmp/summary.md"
# The green defaults; each case overrides what it is about.
export GUARD_RESULT=success PR_DRAFT=false \
	BUGS_STATE=reviewed BUGS_CAUSE='' SECURITY_STATE=reviewed SECURITY_CAUSE='' \
	TIER=Normal PR_NUMBER=1 HEAD_SHA="$A1" REVIEW_OWNER_LOGIN=repo-owner \
	REVIEW_THREADS_CMD='printf "[]"' REVIEW_COMMENTS_CMD='printf "[]"' \
	GITHUB_STEP_SUMMARY="$SUMMARY"
run () { : > "$SUMMARY"; env "$@" bash "$G" 2>&1; }
rc ()  { env "$@" bash "$G" >/dev/null 2>&1; echo $?; }

# feed <cmd for printf> of review threads: thread <first author> <body> [reply author]
thread () {
	local reply=""
	[ -n "${3:-}" ] && reply=",{\"author\":{\"login\":\"$3\"},\"body\":\"done\",\"url\":\"https://example.invalid/r\"}"
	printf '{"comments":{"nodes":[{"author":{"login":"%s"},"body":"%s","url":"https://example.invalid/%s"}%s]}}' \
		"$1" "$2" "$(printf '%s' "$2" | tr -c 'a-z0-9' '-')" "$reply"
}
threads () { local IFS=,; printf 'printf %%s %q' "[$*]"; }
# comments <login> <body> ... : the pull request's issue comments.
comments () {
	local out="" sep=""
	while [ "$#" -ge 2 ]; do out+="$sep{\"user\":{\"login\":\"$1\"},\"body\":\"$2\"}"; sep=,; shift 2; done
	printf 'printf %%s %q' "[$out]"
}

BOT='github-actions[bot]'
open_important=$(threads "$(thread "$BOT" "important: drops the error")")
hundred=(); for _ in $(seq 100); do hundred+=("$(thread "$BOT" "nit: x")"); done
too_many=$(threads "${hundred[@]}")
unreadable='printf "not json"'

# 9. Green.
out=$(run)
assert_contains "$out" "Review gate passed." "all reviewed, Normal and no threads is green"
assert_eq "0" "$(rc)" "and exits 0"
assert_eq "0" "$(rc BUGS_STATE=current SECURITY_STATE=current)" "current angles are green too"

# 1. Guard failed.
out=$(run GUARD_RESULT=failure)
assert_contains "$out" "Outside pull requests are not accepted; please open an issue." "a failed guard"
assert_eq "1" "$(rc GUARD_RESULT=failure)" "is red"
assert_contains "$(run GUARD_RESULT=failure PR_DRAFT=true BUGS_STATE=failed)" "Outside pull requests" "the guard comes before every other step"

# 2. Draft.
out=$(run PR_DRAFT=true BUGS_STATE= SECURITY_STATE= TIER=)
assert_contains "$out" "Draft pull request: the review runs when it is marked ready." "a draft, with its skipped review jobs"
assert_eq "1" "$(rc PR_DRAFT=true BUGS_STATE= SECURITY_STATE=)" "is red"
assert_contains "$(run PR_DRAFT=true BUGS_STATE=failed BUGS_CAUSE=infrastructure)" "Draft pull request" "the draft comes before a failed review"

# 3. Failed or missing.
assert_contains "$(run BUGS_STATE=failed BUGS_CAUSE=token_or_quota)" "Review did not run (token_or_quota) for bugs." "a failed bugs angle"
assert_contains "$(run SECURITY_STATE=failed SECURITY_CAUSE=tool_violation)" "Review did not run (tool_violation) for security." "a failed security angle"
assert_contains "$(run BUGS_STATE=failed BUGS_CAUSE=infrastructure SECURITY_STATE=failed SECURITY_CAUSE=infrastructure)" \
	"Review did not run (infrastructure) for bugs and security." "both angles failed is \"bugs and security\""
assert_contains "$(run BUGS_STATE=)" "Review did not run (missing) for bugs." "an empty state is missing"
assert_contains "$(run BUGS_STATE= SECURITY_STATE=)" "Review did not run (missing) for bugs and security." "and both empty is both"
assert_contains "$(run BUGS_STATE=failed BUGS_CAUSE=no_agent_ran SECURITY_STATE=)" \
	"Review did not run (no_agent_ran, missing) for bugs and security." "different causes are both named"
assert_eq "1" "$(rc BUGS_STATE=)" "a missing angle is red"
assert_contains "$(run BUGS_STATE=failed BUGS_CAUSE=empty_diff SECURITY_STATE=capped)" "Review did not run" "a failed angle comes before a capped one"

# 4. Capped, with no acknowledgement.
out=$(run BUGS_STATE=capped)
assert_contains "$out" "Round cap reached for bugs." "one angle capped with the other reviewed"
assert_eq "1" "$(rc BUGS_STATE=capped)" "is red"
assert_contains "$(run BUGS_STATE=capped SECURITY_STATE=capped)" "Round cap reached for bugs and security." "both capped"
assert_contains "$(run SECURITY_STATE=capped REVIEW_THREADS_CMD="$unreadable")" "Round cap reached for security." "the cap comes before the threads"

# The owner login must be set before the threads or an acknowledgement are read,
# and its absence is a configuration fault, not unreadable threads.
out=$(run REVIEW_OWNER_LOGIN=)
assert_contains "$out" "REVIEW_OWNER_LOGIN is not set" "an unset owner login is named"
case "$out" in *"Review threads could not be read."*) echo "FAIL: an unset owner login is reported as unreadable threads" >&2; exit 1;; esac
assert_eq "1" "$(rc REVIEW_OWNER_LOGIN=)" "and is red"

# 5. Threads unreadable.
assert_contains "$(run REVIEW_THREADS_CMD="$unreadable")" "Review threads could not be read." "an unreadable feed"
assert_contains "$(run REVIEW_THREADS_CMD='exit 3')" "Review threads could not be read." "a failing feed command"
assert_eq "1" "$(rc REVIEW_THREADS_CMD="$unreadable")" "is red"

# 6. 100 or more threads.
assert_contains "$(run REVIEW_THREADS_CMD="$too_many")" "100 or more review threads; the gate cannot decide." "100 threads"
assert_eq "1" "$(rc REVIEW_THREADS_CMD="$too_many" TIER=High)" "is red"

# 7. Important findings unanswered: the count is of important threads, not of
# every open thread.
mixed=$(threads "$(thread "$BOT" "important: one")" "$(thread "$BOT" "this is untagged")" \
	"$(thread "$BOT" "nit: naming")" "$(thread "$BOT" "pre-existing: old")" \
	"$(thread "$BOT" "important: answered" repo-owner)")
out=$(run REVIEW_THREADS_CMD="$mixed")
assert_contains "$out" "2 important findings unanswered." "two important threads among four open"
assert_contains "$out" "important https://example.invalid/important--one" "each open thread's tag and link is printed"
assert_contains "$out" "nit https://example.invalid/nit--naming" "including a nit"
assert_contains "$out" "Reply in the thread, then re-run this job (Re-run jobs > Review gate, or \`gh run rerun <run-id> --job <job-id>\`)." "then the re-run hint"
summary=$(cat "$SUMMARY")
assert_contains "$summary" "2 important findings unanswered." "the cause goes to the step summary"
assert_contains "$summary" "https://example.invalid/important--one" "with the thread list"
assert_contains "$summary" "pre-existing" "and each thread's tag"
assert_contains "$(run REVIEW_THREADS_CMD="$open_important" TIER=High)" "1 important findings unanswered." "findings come before the High tier"
assert_contains "$(run REVIEW_THREADS_CMD="$(threads "$(thread "$BOT" "nit: naming")")")" "Review gate passed." "an open nit alone is green"

# 8. High, with no acknowledgement.
out=$(run TIER=High)
assert_contains "$out" "High risk: waiting for 'Accepted at ${A1:0:7}:'." "a High tier waits for an acknowledgement"
assert_eq "1" "$(rc TIER=High)" "and is red"
assert_eq "1" "$(rc TIER=)" "a missing tier is treated as High"

# The acknowledgement.
ack_head=$(comments repo-owner "Accepted at $A1: reviewed the workflow change")
assert_eq "0" "$(rc TIER=High REVIEW_COMMENTS_CMD="$ack_head")" "an acknowledgement for the head clears High"
assert_eq "0" "$(rc BUGS_STATE=capped REVIEW_COMMENTS_CMD="$ack_head")" "and the round cap"
ack_short=$(comments repo-owner "Accepted at ${A1:0:7}: short sha")
assert_eq "0" "$(rc TIER=High REVIEW_COMMENTS_CMD="$ack_short")" "a short sha is expanded"
not_owner=$(comments someone-else "Accepted at $A1: me too")
assert_eq "1" "$(rc TIER=High REVIEW_COMMENTS_CMD="$not_owner")" "an acknowledgement by anyone else does not count"
quoted=$(comments repo-owner "I will write Accepted at $A1: later")
assert_eq "1" "$(rc TIER=High REVIEW_COMMENTS_CMD="$quoted")" "nor does one not at the start of the comment"
unknown=$(comments repo-owner "Accepted at deadbee: not a commit here")
assert_eq "1" "$(rc TIER=High REVIEW_COMMENTS_CMD="$unknown")" "nor one for a sha this checkout lacks"
assert_eq "1" "$(rc TIER=High HEAD_SHA="$H2" REVIEW_COMMENTS_CMD="$(comments repo-owner "Accepted at $B0: the base")")" "nor one for an unrelated commit"
assert_eq "0" "$(rc TIER=High REVIEW_COMMENTS_CMD="$(comments repo-owner "Accepted at deadbee: no" repo-owner "Accepted at $A1: yes")")" "any valid one among several counts"

# An earlier commit acknowledged, then main merged in: the head is that commit
# plus main, so the acknowledgement still holds.
assert_eq "0" "$(rc TIER=High HEAD_SHA="$H2" REVIEW_COMMENTS_CMD="$ack_head")" "an acknowledgement before a clean merge from main is valid"
# The same, then an edit: new work nobody accepted.
assert_eq "1" "$(rc TIER=High HEAD_SHA="$H3" REVIEW_COMMENTS_CMD="$ack_head")" "the same followed by an edit is invalid"
assert_contains "$(run TIER=High HEAD_SHA="$H3" REVIEW_COMMENTS_CMD="$ack_head")" "High risk: waiting for 'Accepted at ${H3:0:7}:'." "and asks for the new head"

# Comments that cannot be read are not "no acknowledgement".
assert_contains "$(run TIER=High REVIEW_COMMENTS_CMD='exit 4')" "Pull request comments could not be read." "an unreadable comments feed is named"
assert_eq "1" "$(rc TIER=High REVIEW_COMMENTS_CMD='printf "not json"')" "and is red"
assert_eq "0" "$(rc REVIEW_COMMENTS_CMD='exit 4')" "but is not read when nothing needs an acknowledgement"

# A head this checkout lacks cannot be acknowledged.
assert_contains "$(run TIER=High HEAD_SHA=deadbeefdeadbeefdeadbeefdeadbeefdeadbeef REVIEW_COMMENTS_CMD="$ack_head")" "is not in this checkout" "a missing head is named"

pass
