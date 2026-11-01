#!/usr/bin/env bash
# Picks the security-audit issue by the one rule that reading the prior state
# and publishing share, so both always land on the same issue: the oldest open
# issue labelled security-audit, otherwise the newest closed one (oldest and
# newest by creation). Only an issue opened by github-actions[bot], the
# account the report job posts as with GITHUB_TOKEN, counts: a labelled issue
# anyone else opened is ignored as if absent, even when it is the oldest open
# one, so a hand-made issue can neither feed an old state marker to the next
# run nor receive the report. Pull requests, which the issues API also
# returns, are skipped. A label that does not exist yet matches nothing.
#
# Prints the issue number, or nothing when there is no such issue, in which
# case the publishing step creates one. Exits 1 when GitHub cannot be read,
# since an unreadable answer is not "no issue".
#
# Usage: find-audit-issue.sh <owner/repo>      (needs gh with issues: read)
set -euo pipefail

LABEL=security-audit
AUTHOR='github-actions[bot]'

[ "$#" -eq 1 ] || { echo "usage: find-audit-issue.sh <owner/repo>" >&2; exit 2; }
repo="$1"
[[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || { echo "find-audit-issue: the repository must be owner/name" >&2; exit 2; }

first_issue() { # state direction
  local pages
  pages="$(gh api --paginate "repos/$repo/issues?labels=$LABEL&state=$1&sort=created&direction=$2&per_page=100")" || {
    echo "find-audit-issue: could not list $1 issues in $repo" >&2; return 1; }
  jq -rn --arg author "$AUTHOR" '[inputs | .[]
    | select((has("pull_request") | not) and .user.login == $author) | .number] | first // empty' <<<"$pages"
}

number="$(first_issue open asc)"
[ -n "$number" ] || number="$(first_issue closed desc)"
[ -z "$number" ] || [[ "$number" =~ ^[1-9][0-9]*$ ]] || { echo "find-audit-issue: unexpected issue number" >&2; exit 1; }
printf '%s\n' "$number"
