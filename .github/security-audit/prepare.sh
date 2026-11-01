#!/usr/bin/env bash
# Decides whether this audit run goes ahead and which jobs it runs, and writes
# the run-metadata.json the skill requires before delegation. The prepare job
# has no secrets, so nothing here needs one.
#
#   go       true on a workflow_dispatch; on a schedule, true only when the day
#            of the month is 7 or less, so the weekly cron runs on the first
#            Saturday only and every other Saturday ends quietly.
#   publish  the dispatch input, where an empty value (as on a schedule) means
#            true; any canary forces it to false.
#   canary   the dispatch input, where an empty value means none.
#   run_jobs the jobs this run needs as a JSON list: every job on a normal run,
#            and the Stage 4 canary table's row on a canary run.
#
# Prints one key=value line each for go, publish, canary and run_jobs, in that
# order, ready to append to $GITHUB_OUTPUT. Every invalid argument is refused
# with exit status 2 before anything is written.
#
# run-metadata.json takes run_id, repo and source_ref from the runner's
# GITHUB_RUN_ID, GITHUB_REPOSITORY and GITHUB_SHA. prior_run_paths starts
# empty: the source job's trusted step that opens the prior state fills it in.
#
# Usage: prepare.sh <date YYYY-MM-DD> <event> <publish> <canary> <out-dir>
set -euo pipefail

usage() {
  echo "usage: prepare.sh <date YYYY-MM-DD> <event> <publish> <canary> <out-dir>" >&2
  exit 2
}
fail() { echo "prepare: $1" >&2; exit 2; }

[ "$#" -eq 5 ] || usage
date_arg="$1" event="$2" publish="$3" canary="$4" out_dir="$5"

ALL_JOBS='["prepare","source","build-site","poc-write","poc-run","poc-decide","cross-check","report"]'

[[ "$date_arg" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] \
  && [ "$(date -u -d "$date_arg" +%F 2>/dev/null)" = "$date_arg" ] || fail "the date must be a real YYYY-MM-DD date"
day=$((10#${date_arg:8:2}))

case "$publish" in
  ""|true) publish=true ;;
  false) ;;
  *) fail "publish must be true, false or empty" ;;
esac

[ -n "$canary" ] || canary=none
case "$canary" in
  none) run_jobs="$ALL_JOBS" ;;
  denied-read|denied-write|subagent-bash|subagent-findings-write)
    run_jobs='["prepare","source"]' ;;
  script-isolation)
    run_jobs='["prepare","source","build-site","poc-write"]' ;;
  sandbox-secrets|reopen-records)
    run_jobs='["prepare","source","build-site","poc-write","poc-run"]' ;;
  *) fail "unknown canary" ;;
esac
[ "$canary" = none ] || publish=false

case "$event" in
  workflow_dispatch) go=true ;;
  schedule)
    # A schedule carries no inputs, so a canary here means miswired inputs.
    [ "$canary" = none ] || fail "a scheduled run cannot carry a canary"
    if [ "$day" -le 7 ]; then go=true; else go=false; fi
    ;;
  *) fail "the event must be schedule or workflow_dispatch" ;;
esac

run_id="${GITHUB_RUN_ID:-}" repo="${GITHUB_REPOSITORY:-}" source_ref="${GITHUB_SHA:-}"
[[ "$run_id" =~ ^[1-9][0-9]{0,19}$ ]] || fail "GITHUB_RUN_ID is not a run id"
[[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || fail "GITHUB_REPOSITORY is not owner/name"
[[ "$source_ref" =~ ^[0-9a-f]{40}$ ]] || fail "GITHUB_SHA is not a commit sha"

mkdir -p "$out_dir"
jq -n --arg run_id "$run_id" --arg repo "$repo" --arg source_ref "$source_ref" '{
  run_id: $run_id,
  repo: $repo,
  target: "main",
  source_ref: $source_ref,
  profile: "standard",
  scope_paths: ["web/modules/custom", "web/themes/custom", "config/", "recipes/", "scripts/",
                ".github/workflows", ".github/claude-review", "tests/"],
  budget: 60,
  execution_policy: "sandboxed-source-and-local-only",
  companions: [],
  prior_run_paths: [],
  shared_file_owners: {"findings.json": "top-level", "coverage-ledger.json": "top-level",
                       "run-metadata.json": "top-level"},
  usage: {},
  run_status: "in_progress"
}' > "$out_dir/run-metadata.json"

printf 'go=%s\npublish=%s\ncanary=%s\nrun_jobs=%s\n' "$go" "$publish" "$canary" "$run_jobs"
