#!/usr/bin/env bash
# Fetches the previous audit run's sealed state, trusting nothing but the
# state marker the report job writes into the audit issue and GitHub's own
# record of the run that marker names.
#
#   1. The issue is the one find-audit-issue.sh picks, the rule publishing
#      uses. Its body must hold exactly one marker,
#      <!-- security-audit-state {"run_id": "...", "sha256": "...", "fingerprints": [...]} -->,
#      with a run id, a lowercase sha256 and a list of fingerprints.
#   2. The run it names must be a run of .github/workflows/security-audit.yml
#      in this repository, on main, started by schedule or workflow_dispatch.
#      Otherwise nothing is downloaded, so an artifact uploaded by any other
#      run or workflow is never read.
#   3. That run's audit-state artifact must exist and not be expired. It is
#      downloaded with gh run download <run_id> -n audit-state, and must hold
#      exactly one regular file, audit-state.age, whose sha256 equals the
#      marker's. A mismatch, or any other content, exits 1 and fails the job.
#
# No issue, no marker, a malformed marker, a run that fails step 2, a deleted
# run, and a missing or expired artifact all mean "no prior run": found=false,
# exit 0. A valid marker is written to <out-dir>/marker.json even when the
# state is not found, because the renderer lists its fingerprints as "not
# re-checked this run". Any GitHub error other than a 404 exits 1, because an
# unreadable answer is not "no prior run".
#
# Prints, ready to append to $GITHUB_OUTPUT:
#   found=true|false
#   run_id=<id>            empty when no valid marker was read
#   sha256=<hex>           empty when no valid marker was read
#   state=<path>           <out-dir>/audit-state.age when found, else empty
#   marker=<path>          <out-dir>/marker.json when a valid marker was read
# The state is still sealed; seal.sh open <key> <sha256> <state> <dir> opens it.
#
# Usage: fetch-prior-state.sh <owner/repo> <out-dir>
#        (needs gh with issues: read and actions: read)
set -euo pipefail

WORKFLOW_PATH=.github/workflows/security-audit.yml
ARTIFACT=audit-state
STATE_FILE=audit-state.age
HERE="$(cd "$(dirname "$0")" && pwd)"

[ "$#" -eq 2 ] || { echo "usage: fetch-prior-state.sh <owner/repo> <out-dir>" >&2; exit 2; }
repo="$1" out_dir="$2"
[[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || { echo "fetch-prior-state: the repository must be owner/name" >&2; exit 2; }
mkdir -p "$out_dir"
[ -z "$(ls -A "$out_dir")" ] || { echo "fetch-prior-state: $out_dir is not empty" >&2; exit 2; }

run_id="" sha256="" marker_path="" download=""
# On every exit the download directory is removed, so a refused artifact never
# stays under <out-dir>; on a failure the saved marker goes too, leaving
# <out-dir> empty.
cleanup() {
  local rc=$?
  [ -z "$download" ] || rm -rf "$download"
  [ "$rc" -eq 0 ] || [ -z "$marker_path" ] || rm -f "$marker_path"
}
trap cleanup EXIT
result() { # found state
  printf 'found=%s\nrun_id=%s\nsha256=%s\nstate=%s\nmarker=%s\n' "$1" "$run_id" "$sha256" "$2" "$marker_path"
  exit 0
}
not_found() { echo "fetch-prior-state: no prior run: $1" >&2; result false ""; }

# gh api with its stdout kept only on success: on an HTTP error gh prints the
# error body to stdout too. Exit 4 on a 404, 1 on any other failure.
api() {
  local err out rc=0
  err="$(mktemp)"
  out="$(gh api "$@" 2>"$err")" || rc=$?
  if [ "$rc" -ne 0 ]; then
    if grep -q 'HTTP 404' "$err"; then rm -f "$err"; return 4; fi
    echo "fetch-prior-state: gh api $1 failed: $(head -c 300 "$err")" >&2
    rm -f "$err"
    return 1
  fi
  rm -f "$err"
  printf '%s' "$out"
}

issue="$(bash "$HERE/find-audit-issue.sh" "$repo")"
[ -n "$issue" ] || not_found "no security-audit issue"

issue_json="$(api "repos/$repo/issues/$issue")" || {
  rc=$?; [ "$rc" -eq 4 ] && not_found "issue $issue is gone"; exit 1; }
body="$(jq -r '.body // ""' <<<"$issue_json")"

# The marker, validated in full; anything else yields no marker.
marker="$(jq -cRs '
  [scan("<!-- security-audit-state (\\{[^\\n]*?\\}) -->")] as $found
  | if ($found | length) != 1 then empty else
      ($found[0][0] | try fromjson catch empty)
      | select(type == "object" and (keys == ["fingerprints", "run_id", "sha256"]))
      | select((.run_id | type) == "string" and (.run_id | test("^[1-9][0-9]{0,19}$")))
      | select((.sha256 | type) == "string" and (.sha256 | test("^[0-9a-f]{64}$")))
      | select((.fingerprints | type) == "array" and (.fingerprints | all(type == "string")))
    end' <<<"$body")"
[ -n "$marker" ] || not_found "issue $issue has no valid state marker"

run_id="$(jq -r .run_id <<<"$marker")"
sha256="$(jq -r .sha256 <<<"$marker")"
marker_path="$out_dir/marker.json"
printf '%s\n' "$marker" > "$marker_path"

run="$(api "repos/$repo/actions/runs/$run_id")" || {
  rc=$?; [ "$rc" -eq 4 ] && not_found "run $run_id no longer exists"; exit 1; }
origin="$(jq -r --arg repo "$repo" --arg path "$WORKFLOW_PATH" '
  if .repository.full_name != $repo then "another repository"
  elif .path != $path then "another workflow"
  elif .head_branch != "main" then "a branch other than main"
  elif (.event | IN("schedule", "workflow_dispatch") | not) then "an event other than schedule or workflow_dispatch"
  else "ok" end' <<<"$run")"
[ "$origin" = ok ] || not_found "the marker names run $run_id of $origin"

artifacts="$(api "repos/$repo/actions/runs/$run_id/artifacts?name=$ARTIFACT")" || {
  rc=$?; [ "$rc" -eq 4 ] && not_found "run $run_id no longer exists"; exit 1; }
live="$(jq -r --arg name "$ARTIFACT" '[.artifacts[] | select(.name == $name and .expired == false)] | length' <<<"$artifacts")"
[ "$live" -ge 1 ] || not_found "run $run_id has no unexpired $ARTIFACT artifact"

download="$(mktemp -d "$out_dir/download.XXXXXX")"
gh run download "$run_id" -R "$repo" -n "$ARTIFACT" -D "$download" || {
  echo "fetch-prior-state: could not download $ARTIFACT from run $run_id" >&2; exit 1; }

entries="$(find "$download" -mindepth 1 -printf '%P\n')"
if [ "$entries" != "$STATE_FILE" ] || [ -L "$download/$STATE_FILE" ] || [ ! -f "$download/$STATE_FILE" ]; then
  echo "fetch-prior-state: $ARTIFACT from run $run_id does not hold exactly one regular file $STATE_FILE" >&2
  exit 1
fi
actual="$(sha256sum "$download/$STATE_FILE" | cut -d' ' -f1)"
if [ "$actual" != "$sha256" ]; then
  echo "fetch-prior-state: sha256 mismatch for $ARTIFACT from run $run_id (marker $sha256, artifact $actual)" >&2
  exit 1
fi
mv "$download/$STATE_FILE" "$out_dir/$STATE_FILE"
result true "$out_dir/$STATE_FILE"
