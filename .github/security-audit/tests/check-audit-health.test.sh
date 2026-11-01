#!/usr/bin/env bash
# Tests for check-audit-health.sh against fake-gh.sh: the workflow states
# active and disabled_inactivity, a 404, no completed run, a run 41 days old,
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
run_days_ago() { # days
  jq -n --arg t "$(date -u -d "$1 days ago" +%Y-%m-%dT%H:%M:%SZ)" '[{createdAt: $t}]' > "$FIX/run_list.json"
}
check() { RC=0; OUT="$(bash "$CHECK" "$@" 2>&1)" || RC=$?; }
no_warning() { # message
  case "$OUT" in *"::warning"*) echo "FAIL: $1 (warned: $OUT)" >&2; exit 1;; esac
}

# Active with a recent run: no warning.
new_fixture healthy active
run_days_ago 3
check "$REPO"
assert_exit 0 "$RC" "a healthy audit exits 0"
no_warning "a healthy audit is not warned about"
assert_contains "$OUT" "3 days ago" "the last run's age is reported"
assert_contains "$(cat "$FIX/calls.log")" "gh api repos/$REPO/actions/workflows/security-audit.yml --jq .state" "the state is read from the workflow"
assert_contains "$(cat "$FIX/calls.log")" "gh run list -R $REPO --workflow security-audit.yml --branch main --status completed --limit 1 --json createdAt" "the last completed run on main is read from run history"

# A run 39 days old is within the limit.
new_fixture recent active
run_days_ago 39
check "$REPO"
no_warning "a run 39 days old is within the limit"

# Disabled for inactivity: warned, still exits 0.
new_fixture disabled disabled_inactivity
run_days_ago 3
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

# Active but no completed run on main: warned.
new_fixture norun active
check "$REPO"
assert_exit 0 "$RC" "no completed run exits 0"
assert_contains "$OUT" "::warning" "no completed run is warned about"
assert_contains "$OUT" "no completed run on main" "the warning says there is no completed run"

# A run 41 days old: warned.
new_fixture stale active
run_days_ago 41
check "$REPO"
assert_exit 0 "$RC" "a stale run exits 0"
assert_contains "$OUT" "::warning" "a run 41 days old is warned about"
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
new_fixture bad-time active
echo '[{"createdAt": "not a time"}]' > "$FIX/run_list.json"
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
