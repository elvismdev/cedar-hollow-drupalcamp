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

# A bare origin/ revision is refused in a script and in a run block: git
# resolves it through refs/tags first, so a tag of that name would stand in for
# main. A comment, a refspec and refs/remotes/origin/main are not bare.
printf '#!/usr/bin/env bash\nmb=$(git merge-base HEAD origin/main)\n' > "$tmp/bare.sh"
out=$(cd "$ROOT" && bash "$C" "$tmp/bare.sh" 2>&1); assert_exit 1 "$?" "a script naming a bare origin/main fails"
assert_contains "$out" "bare.sh:2 names a bare origin/ revision" "and names the file and line"
printf "const base = 'origin/main';\n" > "$tmp/bare.mjs"
(cd "$ROOT" && bash "$C" "$tmp/bare.mjs" >/dev/null 2>&1); assert_exit 1 "$?" "so does a module naming one"
cat > "$tmp/broken/action.yml" <<'YML'
name: bare
runs:
  using: composite
  steps:
    - shell: bash
      run: |
        git diff --name-only "$(git merge-base FETCH_HEAD origin/main)" FETCH_HEAD
YML
(cd "$ROOT" && bash "$C" "$tmp/broken/action.yml" >/dev/null 2>&1); assert_exit 1 "$?" "a run block naming a bare origin/main fails"
cat > "$tmp/qualified.sh" <<'SH'
#!/usr/bin/env bash
# The base is origin/main, read by its full name.
mb=$(git merge-base HEAD refs/remotes/origin/main)
git fetch --no-tags origin '+refs/heads/*:refs/remotes/origin/*'
echo "$mb"
SH
(cd "$ROOT" && bash "$C" "$tmp/qualified.sh" >/dev/null 2>&1); assert_exit 0 "$?" "a comment, a refspec and refs/remotes/origin/main pass"

pass
