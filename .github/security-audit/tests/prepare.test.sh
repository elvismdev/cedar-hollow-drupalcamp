#!/usr/bin/env bash
# Tests for prepare.sh: the first-Saturday rule, publish defaulting to true,
# each canary's jobs with publish forced to false, refused arguments, and the
# keys of run-metadata.json.
set -euo pipefail
# shellcheck source=../../claude-review/tools/agent/test/assert.sh
. "$(dirname "$0")/../../claude-review/tools/agent/test/assert.sh"
PREPARE="$(cd "$(dirname "$0")/.." && pwd)/prepare.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

export GITHUB_RUN_ID=4242 GITHUB_REPOSITORY=example/repo
GITHUB_SHA="$(printf '%040d' 7 | tr 0 a)"
export GITHUB_SHA
ALL='["prepare","source","build-site","poc-write","poc-run","poc-decide","cross-check","report"]'

run() { bash "$PREPARE" "$@"; }
field() { grep "^$1=" <<<"$2" | cut -d= -f2-; }

out="$(run 2026-11-07 schedule "" "" "$WORK/a")"
assert_eq "go=true
publish=true
canary=none
run_jobs=$ALL" "$out" "a schedule on day 7 runs every job and publishes"

out="$(run 2026-11-08 schedule "" "" "$WORK/b")"
assert_eq "false" "$(field go "$out")" "a schedule on day 8 does not run"
out="$(run 2026-11-28 schedule "" "" "$WORK/b")"
assert_eq "false" "$(field go "$out")" "a schedule on day 28 does not run"
out="$(run 2026-11-01 schedule "" "" "$WORK/b")"
assert_eq "true" "$(field go "$out")" "a schedule on day 1 runs"

out="$(run 2026-11-21 workflow_dispatch true none "$WORK/c")"
assert_eq "true" "$(field go "$out")" "a dispatch runs on any day"
assert_eq "true" "$(field publish "$out")" "a dispatch with publish true publishes"
assert_eq "$ALL" "$(field run_jobs "$out")" "a dispatch without a canary runs every job"

out="$(run 2026-11-21 workflow_dispatch "" none "$WORK/c")"
assert_eq "true" "$(field publish "$out")" "an empty publish means true"
out="$(run 2026-11-21 workflow_dispatch false none "$WORK/c")"
assert_eq "false" "$(field publish "$out")" "publish false is kept"
out="$(run 2026-11-21 workflow_dispatch false "" "$WORK/c")"
assert_eq "none" "$(field canary "$out")" "an empty canary means none"

# Each canary gives its table row's jobs and forces publish to false.
while read -r canary jobs; do
  out="$(run 2026-11-21 workflow_dispatch true "$canary" "$WORK/d")"
  assert_eq "true" "$(field go "$out")" "canary $canary runs"
  assert_eq "false" "$(field publish "$out")" "canary $canary forces publish to false"
  assert_eq "$canary" "$(field canary "$out")" "canary $canary is named"
  assert_eq "$jobs" "$(field run_jobs "$out")" "canary $canary runs its table row's jobs"
  jq -e 'type == "array" and all(type == "string")' <<<"$(field run_jobs "$out")" >/dev/null \
    || { echo "FAIL: run_jobs for $canary is not a JSON list of strings" >&2; exit 1; }
done <<'ROWS'
denied-read ["prepare","source"]
denied-write ["prepare","source"]
subagent-bash ["prepare","source"]
subagent-findings-write ["prepare","source"]
script-isolation ["prepare","source","build-site","poc-write"]
sandbox-secrets ["prepare","source","build-site","poc-write","poc-run"]
reopen-records ["prepare","source","build-site","poc-write","poc-run"]
ROWS

# Refused arguments: exit 2, nothing on stdout, no run-metadata.json.
refused() { # message args...
  local msg="$1" rc=0 stdout
  shift
  rm -rf "$WORK/r"
  stdout="$(run "$@" "$WORK/r" 2>/dev/null)" || rc=$?
  assert_exit 2 "$rc" "$msg"
  assert_eq "" "$stdout" "$msg prints no outputs"
  [ ! -e "$WORK/r/run-metadata.json" ] || { echo "FAIL: $msg wrote run-metadata.json" >&2; exit 1; }
}
refused "an unknown canary" 2026-11-21 workflow_dispatch true not-a-canary
refused "an unknown publish value" 2026-11-21 workflow_dispatch yes none
refused "an unknown event" 2026-11-21 push "" ""
refused "a canary on a schedule" 2026-11-07 schedule "" denied-read
refused "an impossible date" 2026-02-31 schedule "" ""
refused "a date in another format" 11/07/2026 schedule "" ""
GITHUB_SHA=main refused "a source_ref that is not a sha" 2026-11-21 workflow_dispatch true none
GITHUB_RUN_ID="" refused "a missing run id" 2026-11-21 workflow_dispatch true none
rc=0; run 2026-11-21 workflow_dispatch true >/dev/null 2>&1 || rc=$?
assert_exit 2 "$rc" "four arguments are refused"

# run-metadata.json has exactly the keys and values of Technical Plan section 1.
run 2026-11-07 schedule "" "" "$WORK/m" >/dev/null
expected="$(jq -n --arg sha "$GITHUB_SHA" '{
  run_id: "4242", repo: "example/repo", target: "main", source_ref: $sha,
  profile: "standard",
  scope_paths: ["web/modules/custom", "web/themes/custom", "config/", "recipes/", "scripts/",
                ".github/workflows", ".github/claude-review", "tests/"],
  budget: 60, execution_policy: "sandboxed-source-and-local-only", companions: [],
  prior_run_paths: [],
  shared_file_owners: {"findings.json": "top-level", "coverage-ledger.json": "top-level",
                       "run-metadata.json": "top-level"},
  usage: {}, run_status: "in_progress"}')"
assert_eq "true" "$(jq --argjson e "$expected" '. == $e' "$WORK/m/run-metadata.json")" "run-metadata.json has the section 1 keys and values"

# merge-records.py reads the run id from this file when it creates trusted-meta.json.
assert_eq "4242" "$(python3 -I -c 'import json,sys; print(int(json.load(open(sys.argv[1]))["run_id"]))' "$WORK/m/run-metadata.json")" "run_id reads as a number"

pass prepare.test.sh
