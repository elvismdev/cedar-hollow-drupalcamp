#!/usr/bin/env bash
# Tests for fetch-prior-state.sh against fake-gh.sh, which serves fixture
# files and logs every call; nothing here touches the network.
set -euo pipefail
# shellcheck source=../../claude-review/tools/agent/test/assert.sh
. "$(dirname "$0")/../../claude-review/tools/agent/test/assert.sh"
TESTS="$(cd "$(dirname "$0")" && pwd)"
FETCH="$TESTS/../fetch-prior-state.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
REPO=example/repo

mkdir -p "$WORK/bin"
cp "$TESTS/fake-gh.sh" "$WORK/bin/gh"
chmod +x "$WORK/bin/gh"
export PATH="$WORK/bin:$PATH"

OPEN_KEY="repos_example_repo_issues_labels_security-audit_state_open_sort_created_direction_asc_per_page_100"
CLOSED_KEY="repos_example_repo_issues_labels_security-audit_state_closed_sort_created_direction_desc_per_page_100"
WORKFLOW=.github/workflows/security-audit.yml
RUN=9001

new_fixture() { # name: a fresh fixture directory with no issues at all
  FIX="$WORK/fix-$1"
  mkdir -p "$FIX"
  export FIX
  echo '[]' > "$FIX/$OPEN_KEY.json"
  echo '[]' > "$FIX/$CLOSED_KEY.json"
  : > "$FIX/calls.log"
}
issue_with_body() { # number body
  jq -n --argjson n "$1" --arg body "$2" '{number: $n, body: $body}' > "$FIX/repos_example_repo_issues_$1.json"
}
marker_body() { # run_id sha256
  printf 'Audit header\n\n<!-- security-audit-state {"run_id": "%s", "sha256": "%s", "fingerprints": ["fp-1", "fp-2"]} -->\n' "$1" "$2"
}
run_json() { # run path branch event
  jq -n --argjson id "$1" --arg path "$2" --arg branch "$3" --arg event "$4" \
    '{id: $id, path: $path, head_branch: $branch, event: $event, repository: {full_name: "example/repo"}}' \
    > "$FIX/repos_example_repo_actions_runs_$1.json"
}
artifacts_json() { # run expired
  jq -n --argjson expired "$2" '{total_count: 1, artifacts: [{id: 77, name: "audit-state", expired: $expired}]}' \
    > "$FIX/repos_example_repo_actions_runs_$1_artifacts_name_audit-state.json"
}
state_artifact() { # run: a sealed-looking state file; prints its sha256
  mkdir -p "$FIX/download-$1"
  head -c 512 /dev/urandom > "$FIX/download-$1/audit-state.age"
  sha256sum "$FIX/download-$1/audit-state.age" | cut -d' ' -f1
}
good_prior() { # a complete, valid prior state; sets SUM
  SUM="$(state_artifact "$RUN")"
  echo '[{"user": {"login": "github-actions[bot]"}, "number": 3}]' > "$FIX/$OPEN_KEY.json"
  issue_with_body 3 "$(marker_body "$RUN" "$SUM")"
  run_json "$RUN" "$WORKFLOW" main schedule
  artifacts_json "$RUN" false
}
fetch() { # out-dir: runs fetch-prior-state, sets OUT and RC
  RC=0
  OUT="$(bash "$FETCH" "$REPO" "$1" 2>"$WORK/stderr")" || RC=$?
}
field() { grep "^$1=" <<<"$OUT" | cut -d= -f2-; }
empty_after() { # out-dir message: nothing at all is left under out-dir
  local left
  left="$(find "$1" -mindepth 1 2>/dev/null)"
  [ -z "$left" ] || { echo "FAIL: $2 left files under the output directory: $left" >&2; exit 1; }
}
no_download() { # message
  case "$(cat "$FIX/calls.log")" in *"run download"*) echo "FAIL: $1 downloaded an artifact" >&2; exit 1;; esac
}

# A valid prior state is found, checked and left sealed in the output directory.
new_fixture good
good_prior
fetch "$WORK/out-good"
assert_exit 0 "$RC" "a valid prior state is fetched"
assert_eq "true" "$(field found)" "a valid prior state is found"
assert_eq "$RUN" "$(field run_id)" "the run id is the marker's"
assert_eq "$SUM" "$(field sha256)" "the sha256 is the marker's"
assert_eq "$WORK/out-good/audit-state.age" "$(field state)" "the state path is printed"
assert_eq "$SUM" "$(sha256sum "$WORK/out-good/audit-state.age" | cut -d' ' -f1)" "the state file is the artifact"
assert_eq "audit-state.age
marker.json" "$(ls "$WORK/out-good")" "the output directory holds only the state and the marker"
assert_eq '["fp-1","fp-2"]' "$(jq -c .fingerprints "$WORK/out-good/marker.json")" "the marker is saved with its fingerprints"
assert_contains "$(cat "$FIX/calls.log")" "gh run download $RUN -R $REPO -n audit-state -D $WORK/out-good/download." "the download names the run, repository and artifact"

# The marker exactly as render-issue.py writes it is read, so a change to
# the renderer's marker format fails here.
new_fixture renderer
good_prior
renderer_body="$(python3 -I - "$TESTS/../render-issue.py" "$SUM" "$RUN" <<'PYTHON'
import importlib.util, sys, types
spec = importlib.util.spec_from_file_location("render_issue", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
args = types.SimpleNamespace(state_sha256=sys.argv[2], run_id=sys.argv[3])
run = types.SimpleNamespace(state_ok=True, args=args, marker_fingerprints=lambda: ["fp-a", "fp/b:1"])
print("Header\n" + "\n".join(module.marker(run)))
PYTHON
)"
issue_with_body 3 "$renderer_body"
fetch "$WORK/out-renderer"
assert_eq "true" "$(field found)" "the renderer's own marker is read"
assert_eq '["fp-a","fp/b:1"]' "$(jq -c .fingerprints "$WORK/out-renderer/marker.json")" "the renderer's fingerprints are kept"

# No issue at all: not found, nothing downloaded, no marker.
new_fixture none
fetch "$WORK/out-none"
assert_exit 0 "$RC" "no issue is not an error"
assert_eq "false" "$(field found)" "no issue means no prior run"
assert_eq "" "$(field marker)" "no issue means no marker"
no_download "no issue"

# The marker names a run on a branch: not found, its artifact never read.
new_fixture branch
good_prior
run_json "$RUN" "$WORKFLOW" audit/try schedule
fetch "$WORK/out-branch"
assert_exit 0 "$RC" "a run on a branch is not an error"
assert_eq "false" "$(field found)" "a run on a branch is not a prior run"
assert_contains "$(cat "$WORK/stderr")" "a branch other than main" "the branch is named as the reason"
assert_eq "$WORK/out-branch/marker.json" "$(field marker)" "the marker is still saved for its fingerprints"
no_download "a run on a branch"

# The marker names a run of another workflow: not found, never read.
new_fixture other
good_prior
run_json "$RUN" .github/workflows/ci.yml main workflow_dispatch
fetch "$WORK/out-other"
assert_eq "false" "$(field found)" "a run of another workflow is not a prior run"
assert_contains "$(cat "$WORK/stderr")" "another workflow" "the workflow is named as the reason"
no_download "a run of another workflow"

# A run started by another event: not found, never read.
new_fixture event
good_prior
run_json "$RUN" "$WORKFLOW" main push
fetch "$WORK/out-event"
assert_eq "false" "$(field found)" "a push run is not a prior run"
no_download "a push run"

# A run that no longer exists: not found.
new_fixture deleted
good_prior
rm "$FIX/repos_example_repo_actions_runs_$RUN.json"
fetch "$WORK/out-deleted"
assert_exit 0 "$RC" "a deleted run is not an error"
assert_eq "false" "$(field found)" "a deleted run is not a prior run"
no_download "a deleted run"

# A hash mismatch fails, and the state is not left in the output directory.
new_fixture mismatch
good_prior
head -c 512 /dev/urandom > "$FIX/download-$RUN/audit-state.age"
fetch "$WORK/out-mismatch"
assert_exit 1 "$RC" "a hash mismatch fails"
assert_contains "$(cat "$WORK/stderr")" "sha256 mismatch" "the mismatch is reported"
assert_eq "" "$OUT" "a hash mismatch prints no outputs"
empty_after "$WORK/out-mismatch" "a hash mismatch"

# An artifact that holds anything besides audit-state.age fails.
new_fixture extra
good_prior
echo extra > "$FIX/download-$RUN/other.txt"
fetch "$WORK/out-extra"
assert_exit 1 "$RC" "an artifact with an extra file fails"
assert_eq "" "$OUT" "an artifact with an extra file prints no outputs"
empty_after "$WORK/out-extra" "an artifact with an extra file"

# A download that fails exits 1 and leaves nothing behind.
new_fixture no-download
good_prior
rm -rf "$FIX/download-$RUN"
fetch "$WORK/out-no-download"
assert_exit 1 "$RC" "a failed download fails"
assert_eq "" "$OUT" "a failed download prints no outputs"
empty_after "$WORK/out-no-download" "a failed download"

# The artifacts list for the run is a 404 (the run is gone): not found.
new_fixture artifacts-404
good_prior
rm "$FIX/repos_example_repo_actions_runs_${RUN}_artifacts_name_audit-state.json"
fetch "$WORK/out-artifacts-404"
assert_exit 0 "$RC" "an artifacts list 404 is not an error"
assert_eq "false" "$(field found)" "an artifacts list 404 means no prior run"
no_download "an artifacts list 404"

# The artifacts list cannot be read: fails, leaving nothing behind.
new_fixture artifacts-500
good_prior
: > "$FIX/repos_example_repo_actions_runs_${RUN}_artifacts_name_audit-state.500"
fetch "$WORK/out-artifacts-500"
assert_exit 1 "$RC" "an artifacts list that cannot be read fails"
assert_eq "" "$OUT" "an artifacts list that cannot be read prints no outputs"
empty_after "$WORK/out-artifacts-500" "an unreadable artifacts list"
no_download "an unreadable artifacts list"

# An expired artifact: not found, nothing downloaded.
new_fixture expired
good_prior
artifacts_json "$RUN" true
fetch "$WORK/out-expired"
assert_exit 0 "$RC" "an expired artifact is not an error"
assert_eq "false" "$(field found)" "an expired artifact means no prior run"
assert_eq "$RUN" "$(field run_id)" "the marker's run id is still printed"
no_download "an expired artifact"

# No marker, two markers, or a malformed one: not found.
for body in "an issue body with no marker" \
            "$(marker_body "$RUN" "$(printf '%064d' 0)")$(marker_body "$RUN" "$(printf '%064d' 0)")" \
            '<!-- security-audit-state {"run_id": "9001", "sha256": "ABC", "fingerprints": []} -->' \
            '<!-- security-audit-state {"run_id": "9001", "sha256": "'"$(printf '%064d' 0)"'", "fingerprints": [], "extra": 1} -->' \
            '<!-- security-audit-state {"run_id": 9001, "sha256": "'"$(printf '%064d' 0)"'", "fingerprints": []} -->' \
            '<!-- security-audit-state not json -->'; do
  new_fixture malformed
  good_prior
  issue_with_body 3 "$body"
  rm -rf "$WORK/out-malformed"
  fetch "$WORK/out-malformed"
  assert_exit 0 "$RC" "a body without one valid marker is not an error"
  assert_eq "false" "$(field found)" "a body without one valid marker means no prior run"
  assert_eq "" "$(field marker)" "a body without one valid marker saves no marker"
  case "$(cat "$FIX/calls.log")" in *"actions/runs"*) echo "FAIL: a run was looked up without a valid marker" >&2; exit 1;; esac
done

# An older labelled issue opened by someone else is ignored: its marker is
# never read, and the bot's issue is used.
new_fixture human-issue
good_prior
echo '[{"user": {"login": "someone"}, "number": 2}, {"user": {"login": "github-actions[bot]"}, "number": 3}]' > "$FIX/$OPEN_KEY.json"
issue_with_body 2 "$(marker_body 1 "$(printf '%064d' 0)")"
fetch "$WORK/out-human-issue"
assert_eq "true" "$(field found)" "the bot's issue is used past an older one by another user"
assert_eq "$RUN" "$(field run_id)" "the marker comes from the bot's issue"
case "$(cat "$FIX/calls.log")" in *"issues/2"*) echo "FAIL: the other user's issue was read" >&2; exit 1;; esac
new_fixture human-only
good_prior
echo '[{"user": {"login": "someone"}, "number": 3}]' > "$FIX/$OPEN_KEY.json"
fetch "$WORK/out-human-only"
assert_eq "false" "$(field found)" "a labelled issue by another user alone means no prior run"
no_download "an issue by another user"

# GitHub errors other than a 404 fail rather than read as "no prior run".
new_fixture error
good_prior
: > "$FIX/repos_example_repo_actions_runs_$RUN.500"
fetch "$WORK/out-error"
assert_exit 1 "$RC" "a server error fails"
new_fixture list-error
: > "$FIX/$OPEN_KEY.500"
fetch "$WORK/out-list-error"
assert_exit 1 "$RC" "an issue list that cannot be read fails"
new_fixture closed-list-error
: > "$FIX/$CLOSED_KEY.500"
fetch "$WORK/out-closed-list-error"
assert_exit 1 "$RC" "a closed issue list that cannot be read fails"
assert_eq "" "$OUT" "a closed issue list that cannot be read prints no outputs"
assert_contains "$(cat "$FIX/calls.log")" "state=closed" "the closed list was the one that failed"
empty_after "$WORK/out-closed-list-error" "an unreadable closed issue list"

# A non-empty output directory is refused before any call.
new_fixture nonempty
good_prior
mkdir -p "$WORK/out-nonempty" && echo x > "$WORK/out-nonempty/left.txt"
fetch "$WORK/out-nonempty"
assert_exit 2 "$RC" "a non-empty output directory is refused"
assert_eq "" "$(cat "$FIX/calls.log")" "nothing is called for a non-empty output directory"

# The issue rule picks the oldest open issue, skipping pull requests, and the
# marker is read from that issue only.
new_fixture rule-open
good_prior
printf '[{"user": {"login": "github-actions[bot]"}, "number": 1, "pull_request": {}}]\n[{"user": {"login": "github-actions[bot]"}, "number": 3}, {"user": {"login": "github-actions[bot]"}, "number": 5}]\n' > "$FIX/$OPEN_KEY.json"
echo '[{"user": {"login": "github-actions[bot]"}, "number": 9}]' > "$FIX/$CLOSED_KEY.json"
issue_with_body 5 "$(marker_body 1 "$(printf '%064d' 0)")"
issue_with_body 9 "$(marker_body 1 "$(printf '%064d' 0)")"
fetch "$WORK/out-rule-open"
assert_eq "true" "$(field found)" "the prior state is read from the oldest open issue"
assert_contains "$(cat "$FIX/calls.log")" "gh api repos/$REPO/issues/3" "issue 3's body is the one read"
case "$(cat "$FIX/calls.log")" in *"issues/5"*|*"issues/9"*) echo "FAIL: another issue's body was read" >&2; exit 1;; esac

rc=0; bash "$FETCH" "$REPO" >/dev/null 2>&1 || rc=$?
assert_exit 2 "$rc" "fetch-prior-state refuses a missing output directory argument"

pass fetch-prior-state.test.sh
