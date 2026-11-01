#!/usr/bin/env bash
# Tests for check-audit-health.sh against fake-gh.sh: the workflow states
# active and disabled_inactivity, a 404, no audit run, an audit 41 days old,
# quiet runs whose report job was skipped, a run whose report job failed, a
# failed run whose report succeeded, a schedule whose recent runs all failed,
# and errors, each exiting 0.
set -euo pipefail
# shellcheck source=../../claude-review/tools/agent/test/assert.sh
. "$(dirname "$0")/../../claude-review/tools/agent/test/assert.sh"
TESTS="$(cd "$(dirname "$0")" && pwd)"
CHECK="$TESTS/../check-audit-health.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
REPO=example/repo
mkdir -p "$WORK/bin"
cp "$TESTS/fake-gh.sh" "$WORK/bin/gh"
chmod +x "$WORK/bin/gh"
export PATH="$WORK/bin:$PATH"

# fake-gh.sh prints a fixture as it stands, so the state fixture holds what
# gh prints after --jq .state.
STATE_KEY=repos_example_repo_actions_workflows_security-audit.yml
new_fixture() { # name state
  FIX="$WORK/fix-$1"
  mkdir -p "$FIX"
  export FIX
  : > "$FIX/calls.log"
  echo "$2" > "$FIX/$STATE_KEY.json"
  echo '[]' > "$FIX/run_list.json"
}
when() { date -u -d "$1 days ago" +%Y-%m-%dT%H:%M:%SZ; }
# runs <days>:<run conclusion>:<report job conclusion>...: the run history,
# newest first, each run with a jobs list where report concluded as given.
runs() {
  local id=100 spec days conclusion report list='[]'
  for spec in "$@"; do
    IFS=: read -r days conclusion report <<<"$spec"
    id=$((id + 1))
    list="$(jq -c --argjson id "$id" --arg t "$(when "$days")" --arg c "$conclusion" \
      '. + [{databaseId: $id, createdAt: $t, conclusion: $c}]' <<<"$list")"
    jq -n --arg r "$report" '{jobs: [{name: "prepare", conclusion: "success"},
      {name: "report", conclusion: $r}]}' > "$FIX/run_view_$id.json"
  done
  printf '%s\n' "$list" > "$FIX/run_list.json"
}
check() { RC=0; OUT="$(bash "$CHECK" "$@" 2>&1)" || RC=$?; }
no_warning() { # message
  case "$OUT" in *"::warning"*) echo "FAIL: $1 (warned: $OUT)" >&2; exit 1;; esac
}
views() { grep -c "gh run view" "$FIX/calls.log" || true; }

# Active with a recent audit: no warning.
new_fixture healthy active
runs 3:success:success
check "$REPO"
assert_exit 0 "$RC" "a healthy audit exits 0"
no_warning "a healthy audit is not warned about"
assert_contains "$OUT" "3 days ago" "the last audit's age is reported"
assert_contains "$(cat "$FIX/calls.log")" "gh api repos/$REPO/actions/workflows/security-audit.yml --jq .state" "the state is read from the workflow"
assert_contains "$(cat "$FIX/calls.log")" "gh run list -R $REPO --workflow security-audit.yml --branch main --status completed --limit 10 --json databaseId,createdAt,conclusion" "completed runs on main of any conclusion are read from run history"
assert_contains "$(cat "$FIX/calls.log")" "gh run view 101 -R $REPO --json jobs" "the run's jobs are read"

# An audit 39 days old is within the limit.
new_fixture recent active
runs 39:success:success
check "$REPO"
no_warning "an audit 39 days old is within the limit"

# A real audit 10 days ago with quiet runs after it: no warning, and it stops
# at the first run that qualifies.
new_fixture quiet-after-audit active
runs 1:success:skipped 3:success:skipped 10:success:success 40:success:success
check "$REPO"
no_warning "a real audit 10 days ago with quiet runs after it"
assert_contains "$OUT" "10 days ago" "the real audit's age is reported, not a quiet run's"
assert_eq "3" "$(views)" "it stops reading jobs at the first run that qualifies"

# Recent quiet runs and an old real audit 60 days ago: warned.
new_fixture quiet-old-audit active
runs 2:success:skipped 9:success:skipped 16:success:skipped 60:success:success
check "$REPO"
assert_exit 0 "$RC" "quiet runs over an old audit exit 0"
assert_contains "$OUT" "::warning" "quiet runs over an audit 60 days old are warned about"
assert_contains "$OUT" "60 days ago" "the warning gives the real audit's age"

# A run whose report job failed does not count.
new_fixture report-failed active
runs 2:success:failure 50:success:success
check "$REPO"
assert_contains "$OUT" "::warning" "a run whose report failed does not count"
assert_contains "$OUT" "50 days ago" "the age is the last audit whose report succeeded"
new_fixture only-quiet active
runs 2:success:skipped 9:success:failure
check "$REPO"
assert_contains "$OUT" "has a successful report job" "only quiet runs and a failed report are warned about"

# A schedule whose runs all failed in report: they do not count.
new_fixture failing active
runs 2:failure:failure 30:failure:failure 60:success:success
check "$REPO"
assert_contains "$OUT" "60 days ago" "runs whose report failed do not count"
assert_eq "3" "$(views)" "the jobs of failed runs are read too"

# A run that concluded failure but whose report succeeded is an audit.
new_fixture failed-run-good-report active
runs 2:failure:success 60:success:success
check "$REPO"
no_warning "a failed run whose report succeeded counts as an audit"
assert_contains "$OUT" "2 days ago" "its age is the failed run's"

# At most 10 runs are inspected.
new_fixture bounded active
specs=()
for d in 1 2 3 4 5 6 7 8 9 10 11 12; do specs+=("$d:success:skipped"); done
runs "${specs[@]}" 13:success:success
check "$REPO"
assert_contains "$OUT" "::warning" "no audit within the 10 runs inspected is warned about"
assert_eq "10" "$(views)" "at most 10 runs are inspected"

# Disabled for inactivity: warned, still exits 0.
new_fixture disabled disabled_inactivity
runs 3:success:success
check "$REPO"
assert_exit 0 "$RC" "a disabled workflow exits 0"
assert_contains "$OUT" "::warning" "a disabled workflow is warned about"
assert_contains "$OUT" "disabled_inactivity" "the warning names the state"

# A 404: not yet set up, no warning.
new_fixture missing active
rm "$FIX/$STATE_KEY.json"
check "$REPO"
assert_exit 0 "$RC" "a missing workflow exits 0"
no_warning "a missing workflow is not warned about"
assert_contains "$OUT" "not yet set up" "a missing workflow is noted as not yet set up"
case "$(cat "$FIX/calls.log")" in *"run list"*) echo "FAIL: run history was read for a missing workflow" >&2; exit 1;; esac

# Active but no successful run on main: warned.
new_fixture norun active
check "$REPO"
assert_exit 0 "$RC" "no successful run exits 0"
assert_contains "$OUT" "::warning" "no successful run is warned about"

# An audit 41 days old: warned.
new_fixture stale active
runs 41:success:success
check "$REPO"
assert_exit 0 "$RC" "a stale audit exits 0"
assert_contains "$OUT" "::warning" "an audit 41 days old is warned about"
assert_contains "$OUT" "41 days ago" "the warning gives the age"

# Errors reading GitHub are warned about and still exit 0.
new_fixture state-error active
rm "$FIX/$STATE_KEY.json"
: > "$FIX/$STATE_KEY.500"
check "$REPO"
assert_exit 0 "$RC" "a state that cannot be read exits 0"
assert_contains "$OUT" "::warning" "a state that cannot be read is warned about"
new_fixture runs-error active
: > "$FIX/run_list.500"
check "$REPO"
assert_exit 0 "$RC" "run history that cannot be read exits 0"
assert_contains "$OUT" "::warning" "run history that cannot be read is warned about"
new_fixture jobs-error active
runs 3:success:success
: > "$FIX/run_view_101.500"
check "$REPO"
assert_exit 0 "$RC" "jobs that cannot be read exit 0"
assert_contains "$OUT" "could not read the jobs of run 101" "jobs that cannot be read are warned about"
new_fixture bad-time active
runs 3:success:success
jq '.[0].createdAt = "not a time"' "$FIX/run_list.json" > "$FIX/t.json" && mv "$FIX/t.json" "$FIX/run_list.json"
check "$REPO"
assert_exit 0 "$RC" "an unreadable run time exits 0"
assert_contains "$OUT" "::warning" "an unreadable run time is warned about"

# A missing or malformed argument is warned about and exits 0.
check
assert_exit 0 "$RC" "no argument exits 0"
assert_contains "$OUT" "::warning" "no argument is warned about"
check "not a repo"
assert_exit 0 "$RC" "a malformed repository exits 0"

pass check-audit-health.test.sh
