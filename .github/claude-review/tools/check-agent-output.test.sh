#!/usr/bin/env bash
set -uo pipefail
ROOT="$(git rev-parse --show-toplevel)/.github/claude-review"
. "$ROOT/tools/agent/test/assert.sh"
C="$ROOT/tools/check-agent-output.sh"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
PIN=anthropics/claude-code-action@0000000000000000000000000000000000000000

# The repository's own workflows and actions pass, and the check says how many steps it read.
out=$(bash "$C" 2>&1); assert_exit 0 "$?" "every claude-code-action step in the repository pins both inputs off"
assert_contains "$out" "step(s)" "and it says how many steps it read"

run_case() { (cd "$ROOT" && bash "$C" "$1" >/dev/null 2>&1); }

# Workflow step with both inputs 'false' passes.
cat > "$tmp/wf.yml" <<YML
on: push
jobs:
  j:
    runs-on: ubuntu-24.04
    steps:
      - uses: $PIN # v1
        with:
          prompt: x
          show_full_output: 'false'
          display_report: "false"
YML
run_case "$tmp/wf.yml"; assert_exit 0 "$?" "a workflow step with both inputs false passes"

# Workflow step missing either input fails.
sed "/display_report/d" "$tmp/wf.yml" > "$tmp/wf-a.yml"
run_case "$tmp/wf-a.yml"; assert_exit 1 "$?" "a workflow step without display_report fails"
sed "/show_full_output/d" "$tmp/wf.yml" > "$tmp/wf-b.yml"
run_case "$tmp/wf-b.yml"; assert_exit 1 "$?" "a workflow step without show_full_output fails"

# A value other than the string false fails, including the boolean false and 'true'.
sed "s/show_full_output: 'false'/show_full_output: 'true'/" "$tmp/wf.yml" > "$tmp/wf-c.yml"
run_case "$tmp/wf-c.yml"; assert_exit 1 "$?" "show_full_output 'true' fails"
sed "s/display_report: \"false\"/display_report: false/" "$tmp/wf.yml" > "$tmp/wf-d.yml"
run_case "$tmp/wf-d.yml"; assert_exit 1 "$?" "display_report as a YAML boolean fails"

# A step with no with: block fails.
cat > "$tmp/wf-e.yml" <<YML
on: push
jobs:
  j:
    runs-on: ubuntu-24.04
    steps:
      - uses: $PIN # v1
YML
run_case "$tmp/wf-e.yml"; assert_exit 1 "$?" "a step with no with block fails"

# Composite action steps are covered.
cat > "$tmp/action.yml" <<YML
name: a
runs:
  using: composite
  steps:
    - uses: $PIN # v1
      with:
        prompt: x
YML
run_case "$tmp/action.yml"; assert_exit 1 "$?" "a composite action step without the inputs fails"
cat > "$tmp/action.yml" <<YML
name: a
runs:
  using: composite
  steps:
    - uses: $PIN # v1
      with:
        show_full_output: 'false'
        display_report: 'false'
YML
run_case "$tmp/action.yml"; assert_exit 0 "$?" "a composite action step with both inputs false passes"

# A file with no such step is refused rather than read as clean.
printf 'on: push\njobs:\n  j:\n    runs-on: x\n    steps:\n      - run: echo\n' > "$tmp/none.yml"
run_case "$tmp/none.yml"; assert_exit 1 "$?" "a file with no claude-code-action step fails"

pass
