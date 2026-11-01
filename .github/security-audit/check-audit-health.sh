#!/usr/bin/env bash
# Warns when the monthly security audit has stopped running. GitHub disables a
# scheduled workflow after a period of repository inactivity and only emails
# about it; push events are not disabled that way, so CI on main runs this.
#
# It reads the workflow's state and its run history, never the audit issue's
# update time, which anyone can change by commenting:
#   gh api repos/<repo>/actions/workflows/security-audit.yml --jq .state
#   gh run list -R <repo> --workflow security-audit.yml --branch main \
#     --status success --limit 1 --json createdAt,conclusion
# and prints a ::warning:: annotation when the state is not active, when there
# is no successful run on main, or when the last one started more than 40 days
# ago (first Saturdays can be 35 days apart). Only runs whose conclusion is
# success count, so a schedule whose runs keep failing is warned about too. A workflow that does not exist
# (a 404) is "not yet set up" and only noted. Anything it cannot read is
# warned about too.
#
# It always exits 0, so it never stops a deploy.
#
# Usage: check-audit-health.sh <owner/repo>     (GH_TOKEN with actions: read)
set -euo pipefail

WORKFLOW=security-audit.yml
MAX_AGE_DAYS=40

warn() { echo "::warning title=Security audit::$1"; }

if [ "$#" -ne 1 ] || [[ ! "$1" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
  warn "check-audit-health.sh needs one owner/repo argument; the audit's health was not checked"
  exit 0
fi
repo="$1"
err="$(mktemp)"
trap 'rm -f "$err"' EXIT

rc=0
state="$(gh api "repos/$repo/actions/workflows/$WORKFLOW" --jq .state 2>"$err")" || rc=$?
if [ "$rc" -ne 0 ]; then
  if grep -q 'HTTP 404' "$err"; then
    echo "check-audit-health: $WORKFLOW is not yet set up in $repo"
  else
    warn "could not read the state of $WORKFLOW in $repo"
  fi
  exit 0
fi
if [ "$state" != active ]; then
  warn "$WORKFLOW is not active (state: ${state:-unknown}); re-enable it in the repository's Actions settings"
fi

rc=0
runs="$(gh run list -R "$repo" --workflow "$WORKFLOW" --branch main --status success --limit 1 --json createdAt,conclusion 2>"$err")" || rc=$?
if [ "$rc" -ne 0 ]; then
  warn "could not read the run history of $WORKFLOW in $repo"
  exit 0
fi
created="$(jq -r 'if type == "array" and length > 0 and .[0].conclusion == "success" then (.[0].createdAt // "") else "" end' <<<"$runs" 2>/dev/null)" || created=""
if [ -z "$created" ]; then
  warn "$WORKFLOW has no successful run on main"
  exit 0
fi
started="$(date -u -d "$created" +%s 2>/dev/null)" || started=""
if [ -z "$started" ]; then
  warn "could not read the time of the last successful run of $WORKFLOW"
  exit 0
fi
age=$(( $(date -u +%s) - started ))
age_days=$(( age / 86400 ))
if [ "$age" -gt $(( MAX_AGE_DAYS * 86400 )) ]; then
  warn "the last successful run of $WORKFLOW on main started $age_days days ago, more than $MAX_AGE_DAYS"
else
  echo "check-audit-health: $WORKFLOW is $state; last successful run on main started $age_days days ago"
fi
exit 0
