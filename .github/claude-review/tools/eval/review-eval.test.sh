#!/usr/bin/env bash
set -uo pipefail
ROOT="$(git rev-parse --show-toplevel)/.github/claude-review"
. "$ROOT/tools/agent/test/assert.sh"
E="$ROOT/tools/eval/review-eval.mjs"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

# A fake reviewer: the findings it reports come from REVIEW_JSON, and as a
# verifier (its prompt says VERIFYING) it answers VERDICT_JSON. FAKE_FAIL makes
# it exit non-zero, the way a CLI that could not start does.
mkdir -p "$tmp/bin"
cat > "$tmp/bin/claude" <<'SH'
#!/usr/bin/env bash
prompt=$(cat)
[ -n "${FAKE_FAIL:-}" ] && exit 3
if printf '%s' "$prompt" | grep -q VERIFYING; then body="${VERDICT_JSON:-[]}"; else body="${REVIEW_JSON:-[]}"; fi
python3 -c 'import json,sys; print(json.dumps({"type":"system","subtype":"init"})); print(json.dumps({"type":"assistant","message":{"content":[{"type":"text","text":"```json\n"+sys.argv[1]+"\n```"}]}}))' "$body"
SH
chmod +x "$tmp/bin/claude"
export PATH="$tmp/bin:$PATH"

r="$tmp/repo"; mkdir -p "$r/cases"
(cd "$r" && git init -q -b main . && git config user.email t@t && git config user.name t
 printf '# standard\n' > REVIEW.md && printf 'ok\n' > gate.sh && git add -A && git commit -q -m base
 printf 'exit 0 # fails open\n' > gate.sh && git commit -q -am "introduce the bug"
 printf 'docs\n' > README && git add README && git commit -q -m "a clean change")
bug=$(git -C "$r" rev-parse HEAD~1); clean=$(git -C "$r" rev-parse HEAD)
printf '{"name":"gate-fails-open","control":"review","introduced":"%s","fix":"x","angle":"bugs","expect_file":"gate.sh","expect_any":["fails open"]}' "$bug" > "$r/cases/001.json"
printf '{"name":"docs-only","kind":"clean","commit":"%s","angle":"bugs","why":"a README line"}' "$clean" > "$r/cases/002.json"
printf '{"name":"deterministic","control":"bash lint.sh {file}","fix":"x","file":"a"}' > "$r/cases/003.json"

# run <env assignments...> -- <args...>: the eval's exit code, output kept in $tmp/out
run() {
  local envs=()
  while [ "$1" != "--" ]; do envs+=("$1"); shift; done; shift
  (cd "$r" && env "${envs[@]}" node "$E" "$@" >"$tmp/out" 2>&1); echo $?
}

hit='[{"severity":"important","file":"gate.sh","line":1,"title":"the gate fails open"}]'
nit='[{"severity":"nit","file":"gate.sh","line":1,"title":"the gate fails open"}]'
assert_eq "0" "$(run REVIEW_JSON="$hit" -- cases --base main --no-verify --only gate-fails-open)" "a caught incident passes"
assert_eq "1" "$(run REVIEW_JSON='[]' -- cases --base main --no-verify --only gate-fails-open)" "a missed incident fails"
assert_eq "1" "$(run REVIEW_JSON="$nit" -- cases --base main --no-verify --only gate-fails-open)" "an incident reported only as a nit fails"
assert_eq "1" "$(run REVIEW_JSON="$hit" -- cases --base main --no-verify --only docs-only)" "an important finding on a clean change fails"
assert_eq "0" "$(run REVIEW_JSON="$nit" -- cases --base main --no-verify --only docs-only)" "a nit on a clean change passes"
assert_contains "$(cat "$tmp/out")" "clean cases flagged 0 of 1" "the summary counts clean cases flagged"

# With verification on, a finding two of three verifiers refute is not counted,
# and one they keep still is.
refute='[{"index":0,"verdict":"false","reason":"README only"}]'
keep='[{"index":0,"verdict":"real"}]'
assert_eq "0" "$(run REVIEW_JSON="$hit" VERDICT_JSON="$refute" -- cases --base main --only docs-only)" "a refuted finding on a clean change is dropped by the vote"
assert_eq "0" "$(run REVIEW_JSON="$hit" VERDICT_JSON="$refute" -- cases --base main --only docs-only)" "a refuted finding again"
assert_contains "$(cat "$tmp/out")" "reviewer reported 1, the vote dropped 1, 0 kept" "the log tells a refuted finding from one never reported"
assert_eq "1" "$(run REVIEW_JSON="$hit" VERDICT_JSON="$keep" -- cases --base main --only docs-only)" "and one the verifiers keep still fails it"

# The deterministic case is skipped: only the incident and the clean case run.
run REVIEW_JSON="$hit" -- cases --base main --no-verify >/dev/null
assert_contains "$(cat "$tmp/out")" "2 case(s)" "only incident and clean cases are run"

# Against a baseline, only a case that passed before and fails now regresses.
printf '{"cases":{"gate-fails-open":"fail","docs-only":"pass"}}' > "$r/baseline.json"
assert_eq "0" "$(run REVIEW_JSON='[]' -- cases --base main --no-verify --baseline baseline.json)" "a miss already in the baseline does not fail"
assert_contains "$(cat "$tmp/out")" "known     gate-fails-open" "but it is reported as known"
assert_eq "1" "$(run REVIEW_JSON="$hit" -- cases --base main --no-verify --baseline baseline.json)" "a clean case that passed before and now flags regresses"
assert_contains "$(cat "$tmp/out")" "REGRESSED docs-only" "and names the case"
assert_contains "$(cat "$tmp/out")" "improved  gate-fails-open" "while the newly caught incident is reported as improved"
printf '{"cases":{"docs-only":"pass"}}' > "$r/partial.json"
run REVIEW_JSON='[]' -- cases --base main --no-verify --baseline partial.json >/dev/null
assert_contains "$(cat "$tmp/out")" "new       gate-fails-open" "a case with no baseline entry is reported as new"
printf 'nope' > "$r/bad-baseline.json"
assert_eq "2" "$(run REVIEW_JSON='[]' -- cases --base main --no-verify --baseline bad-baseline.json)" "an unreadable baseline is refused, not ignored"

# A case that could not run is never a pass.
assert_eq "2" "$(run FAKE_FAIL=1 -- cases --base main --no-verify)" "an agent that could not run is exit 2"
assert_contains "$(cat "$tmp/out")" "could not run" "and says so"
mkdir -p "$r/empty"
assert_eq "2" "$(run X=1 -- empty --base main)" "a directory with no live cases measured nothing"
printf '{"name":"broken","kind":"clean","angle":"bugs"}' > "$r/cases/004.json"
assert_eq "2" "$(run X=1 -- cases --base main)" "a case missing its fields is refused"

pass "review-eval.test.sh"
