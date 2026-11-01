#!/usr/bin/env bash
# Warns when the monthly security audit has stopped running. GitHub disables a
# scheduled workflow after a period of repository inactivity and only emails
# about it; push events are not disabled that way, so CI on main runs this.
#
# It reads the workflow's state and its run history, never the audit issue's
# update time, which anyone can change by commenting:
#   gh api repos/<repo>/actions/workflows/security-audit.yml --jq .state
#   gh run list -R <repo> --workflow security-audit.yml --branch main \
#     --status completed --limit 10 --json databaseId,createdAt,conclusion
#   gh run view <id> -R <repo> --json jobs     (per run, newest first)
# A run counts as an audit only when its job named report, the job that
# publishes, concluded success, whatever the run's own conclusion: a run
# that ended after prepare on a Saturday other than the first skips report
# and concludes success, and a run whose report published an incomplete
# audit after another job failed concludes failure. It reads the newest
# completed runs on main one at a time and stops at the first that
# qualifies, inspecting at most 10.
#
# While the workflow file has no schedule trigger the audit runs only when
# dispatched, so the age check is skipped with a ::notice:: instead of a
# warning. The file is .github/workflows/security-audit.yml in this checkout,
# or AUDIT_WORKFLOW_FILE; one that cannot be read is warned about and the
# age is still checked.
#
# It prints a ::warning:: annotation when the state is not active, when none
# of those runs is an audit whose report succeeded, or when the newest such
# audit started more than 40 days ago (first Saturdays can be 35 days apart).
# A workflow that does not exist (a 404) is "not yet set up" and only noted.
# Anything it cannot read is warned about too.
#
# It always exits 0, so it never stops a deploy.
#
# Usage: check-audit-health.sh <owner/repo>     (GH_TOKEN with actions: read)
set -euo pipefail

WORKFLOW=security-audit.yml
WORKFLOW_FILE="${AUDIT_WORKFLOW_FILE:-$(cd "$(dirname "$0")/../workflows" 2>/dev/null && pwd)/$WORKFLOW}"
MAX_AGE_DAYS=40
MAX_RUNS=10
REPORT_JOB=report

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

# PyYAML reads the bare key on as True.
scheduled="$(python3 -I -c '
import sys, yaml
wf = yaml.safe_load(open(sys.argv[1]))
on = wf.get(True, wf.get("on")) if isinstance(wf, dict) else None
events = [on] if isinstance(on, str) else list(on or [])
print("yes" if "schedule" in events else "no")' "$WORKFLOW_FILE" 2>/dev/null)" || scheduled=""
case "$scheduled" in
  no)
    echo "::notice title=Security audit::$WORKFLOW has no schedule yet, so the age of its last audit is not checked"
    exit 0
    ;;
  yes) ;;
  *) warn "could not read the triggers of $WORKFLOW_FILE; checking the age of the last audit anyway" ;;
esac

rc=0
runs="$(gh run list -R "$repo" --workflow "$WORKFLOW" --branch main --status completed --limit "$MAX_RUNS" --json databaseId,createdAt,conclusion 2>"$err")" || rc=$?
if [ "$rc" -ne 0 ]; then
  warn "could not read the run history of $WORKFLOW in $repo"
  exit 0
fi
candidates="$(jq -r --argjson max "$MAX_RUNS" 'if type == "array" then .[:$max][] else empty end
  | select((.databaseId | type) == "number")
  | "\(.databaseId) \(.createdAt // "")"' <<<"$runs" 2>/dev/null)" || candidates=""
created=""
while read -r id when; do
  [ -n "$id" ] || continue
  rc=0
  jobs="$(gh run view "$id" -R "$repo" --json jobs 2>"$err" </dev/null)" || rc=$?
  if [ "$rc" -ne 0 ]; then
    warn "could not read the jobs of run $id of $WORKFLOW in $repo"
    exit 0
  fi
  report="$(jq -r --arg job "$REPORT_JOB" '[.jobs[]? | select(.name == $job) | .conclusion] | first // ""' <<<"$jobs" 2>/dev/null)" || report=""
  if [ "$report" = success ]; then created="$when"; break; fi
done <<<"$candidates"
if [ -z "$created" ]; then
  warn "none of the last $MAX_RUNS completed runs of $WORKFLOW on main has a successful $REPORT_JOB job"
  exit 0
fi
started="$(date -u -d "$created" +%s 2>/dev/null)" || started=""
if [ -z "$started" ]; then
  warn "could not read the time of the last audit run of $WORKFLOW"
  exit 0
fi
age=$(( $(date -u +%s) - started ))
age_days=$(( age / 86400 ))
if [ "$age" -gt $(( MAX_AGE_DAYS * 86400 )) ]; then
  warn "the last audit run of $WORKFLOW on main whose report succeeded started $age_days days ago, more than $MAX_AGE_DAYS"
else
  echo "check-audit-health: $WORKFLOW is $state; last audit run on main whose report succeeded started $age_days days ago"
fi
exit 0
