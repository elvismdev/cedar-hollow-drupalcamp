#!/usr/bin/env bash
set -uo pipefail
ROOT="$(git rev-parse --show-toplevel)/.github/claude-review"
. "$ROOT/tools/agent/test/assert.sh"
C="$ROOT/tools/check-actions.sh"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

# The real actions pass, and the check reports that it read something.
out=$(bash "$C" 2>&1); assert_exit 0 "$?" "the repository's actions pass"
assert_contains "$out" "run block(s)" "and it says how many blocks it read"

# A syntax error inside runs.steps fails: the case the workflow linter missed.
mkdir -p "$tmp/broken"
cat > "$tmp/broken/action.yml" <<'YML'
name: broken
runs:
  using: composite
  steps:
    - shell: bash
      run: |
        if then fi echo broken (
YML
(cd "$ROOT" && bash "$C" "$tmp/broken/action.yml" >/dev/null 2>&1); assert_exit 1 "$?" "a syntax error in a composite step fails"

# Expressions are not bash, so they must not read as errors.
cat > "$tmp/broken/action.yml" <<'YML'
name: expressions
runs:
  using: composite
  steps:
    - shell: bash
      env:
        X: ${{ inputs.x }}
      run: |
        echo "${{ inputs.x }}" "$X"
YML
(cd "$ROOT" && bash "$C" "$tmp/broken/action.yml" >/dev/null 2>&1); assert_exit 0 "$?" "an expression in a run block is not an error"

# A file that is not a composite action is refused rather than read as clean.
printf 'name: not-an-action\n' > "$tmp/broken/action.yml"
(cd "$ROOT" && bash "$C" "$tmp/broken/action.yml" >/dev/null 2>&1); assert_exit 1 "$?" "a file with no composite steps fails"

pass
