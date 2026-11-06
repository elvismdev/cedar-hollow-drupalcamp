#!/usr/bin/env bash
set -uo pipefail
ROOT="$(git rev-parse --show-toplevel)/.github/claude-review"
. "$ROOT/tools/agent/test/assert.sh"
C="$ROOT/tools/check-agent-output.sh"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
PIN=anthropics/claude-code-action@0000000000000000000000000000000000000000

# run_case <file> [dir]: sets rc and out (stdout and stderr together).
run_case() { out=$(cd "${2:-$ROOT}" && bash "$C" "$1" 2>&1); rc=$?; }
expect() { # exit_code needle message
  assert_exit "$1" "$rc" "$3"
  [ -z "$2" ] || assert_contains "$out" "$2" "$3"
}

out=$(bash "$C" 2>&1); rc=$?
expect 0 "step(s) pin both inputs off" "every claude-code-action step in the repository pins both inputs off"

wf() { # uses_value extra_with_lines
  cat <<YML
on: push
jobs:
  j:
    runs-on: ubuntu-24.04
    steps:
      - uses: $1
        with:
          prompt: x
$2
YML
}
BOTH="          show_full_output: 'false'
          display_report: \"false\""

wf "$PIN # v1" "$BOTH" > "$tmp/ok.yml"
run_case "$tmp/ok.yml"; expect 0 "1 claude-code-action step(s)" "both inputs false passes"

wf "$PIN" "          show_full_output: 'false'" > "$tmp/a.yml"
run_case "$tmp/a.yml"; expect 1 "display_report must be the string 'false'" "missing display_report fails with the rule's message"
wf "$PIN" "          display_report: 'false'" > "$tmp/b.yml"
run_case "$tmp/b.yml"; expect 1 "show_full_output must be the string 'false'" "missing show_full_output fails with the rule's message"
wf "$PIN" "          show_full_output: 'true'
          display_report: 'false'" > "$tmp/c.yml"
run_case "$tmp/c.yml"; expect 1 "found 'true'" "'true' fails"
wf "$PIN" "          show_full_output: 'false'
          display_report: false" > "$tmp/d.yml"
run_case "$tmp/d.yml"; expect 1 "found False" "a YAML boolean false fails"
printf 'on: push\njobs:\n  j:\n    runs-on: x\n    steps:\n      - uses: %s\n' "$PIN" > "$tmp/e.yml"
run_case "$tmp/e.yml"; expect 1 "must be the string 'false'" "a step with no with block fails"

# Every way of running the agent is matched.
wf "anthropics/claude-code-action/base-action@0000000000000000000000000000000000000000" "" > "$tmp/f.yml"
run_case "$tmp/f.yml"; expect 1 "must be the string 'false'" "the base-action path is matched"
wf "Anthropics/Claude-Code-Action@0000000000000000000000000000000000000000" "" > "$tmp/g.yml"
run_case "$tmp/g.yml"; expect 1 "must be the string 'false'" "the match ignores case"

# Composite actions.
cat > "$tmp/action.yml" <<YML
name: a
runs:
  using: composite
  steps:
    - uses: $PIN
      with:
        prompt: x
YML
run_case "$tmp/action.yml"; expect 1 "action step 0" "a composite step without the inputs fails"
cat > "$tmp/action.yaml" <<YML
name: a
runs:
  using: composite
  steps:
    - uses: $PIN
      with:
        show_full_output: 'false'
        display_report: 'false'
YML
run_case "$tmp/action.yaml"; expect 0 "1 claude-code-action step(s)" "a composite step with both inputs false passes"

# No step at all is refused, not read as clean.
printf 'on: push\njobs:\n  j:\n    runs-on: x\n    steps:\n      - run: echo\n' > "$tmp/none.yml"
run_case "$tmp/none.yml"; expect 1 "found no claude-code-action step" "a file with no claude-code-action step fails"

# Reusable-workflow jobs have no steps and are skipped.
printf 'on: push\njobs:\n  call:\n    uses: ./.github/workflows/x.yml\n  j:\n    runs-on: x\n    steps:\n      - uses: %s\n        with:\n          show_full_output: "false"\n          display_report: "false"\n' "$PIN" > "$tmp/reuse.yml"
run_case "$tmp/reuse.yml"; expect 0 "1 claude-code-action step(s)" "a reusable-workflow job is skipped"

# Malformed input is reported by name with exit 2, never as a traceback or a rule refusal.
printf 'a: [unclosed\n' > "$tmp/bad.yml"
run_case "$tmp/bad.yml"; expect 2 "bad.yml: cannot be parsed" "an unparseable file exits 2 and is named"
printf -- '- just\n- a list\n' > "$tmp/list.yml"
run_case "$tmp/list.yml"; expect 2 "list.yml: the document is not a mapping" "a non-mapping document exits 2"
printf 'jobs:\n  j: nope\n' > "$tmp/job.yml"
run_case "$tmp/job.yml"; expect 2 "job j is not a mapping" "a non-mapping job exits 2"
printf 'jobs:\n  j:\n    steps: nope\n' > "$tmp/steps.yml"
run_case "$tmp/steps.yml"; expect 2 "steps is not a list" "non-list steps exit 2"
printf 'jobs:\n  j:\n    steps:\n      - nope\n' > "$tmp/step.yml"
run_case "$tmp/step.yml"; expect 2 "step 0 is not a mapping" "a non-mapping step exits 2"
run_case "$tmp/missing.yml"; expect 2 "missing.yml: cannot be parsed" "a missing file exits 2"
case "$out" in *Traceback*) echo "FAIL: a traceback leaked" >&2; exit 1;; esac

# A relative path is resolved against the caller's directory.
mkdir -p "$tmp/sub"; cp "$tmp/ok.yml" "$tmp/sub/ok.yml"
run_case "ok.yml" "$tmp/sub"; expect 0 "1 claude-code-action step(s)" "a relative path resolves from the caller's directory"

# Untracked files are not scanned by default.
sed 's/display_report: .*/display_report: "true"/' "$tmp/ok.yml" > "$ROOT/../workflows/untracked-probe.yml"
out=$(bash "$C" 2>&1); rc=$?; rm -f "$ROOT/../workflows/untracked-probe.yml"
expect 0 "step(s) pin both inputs off" "an untracked workflow is not part of the default scan"

pass
