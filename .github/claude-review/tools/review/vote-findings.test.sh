#!/usr/bin/env bash
set -uo pipefail
ROOT="$(git rev-parse --show-toplevel)/.github/claude-review"
. "$ROOT/tools/agent/test/assert.sh"
V="$ROOT/tools/review/vote-findings.mjs"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

cat > "$tmp/c.json" <<'J'
[{"severity":"important","file":"a.ts","line":1,"title":"real bug"},
 {"severity":"nit","file":"b.ts","line":2,"title":"style only"},
 {"severity":"important","file":"c.ts","line":3,"title":"disputed"}]
J
printf '[{"index":0,"verdict":"real"},{"index":1,"verdict":"style","reason":"naming"},{"index":2,"verdict":"false","reason":"guarded at c.ts:1"}]' > "$tmp/v1.json"
printf '[{"index":0,"verdict":"real"},{"index":1,"verdict":"style"},{"index":2,"verdict":"real"}]' > "$tmp/v2.json"
printf '[{"index":0,"verdict":"false"},{"index":1,"verdict":"false"},{"index":2,"verdict":"false","reason":"guarded"}]' > "$tmp/v3.json"

out=$(node "$V" "$tmp/c.json" "$tmp/kept.json" "$tmp/dropped.json" 3 "$tmp/v1.json" "$tmp/v2.json" "$tmp/v3.json" 2>&1)
assert_eq "0" "$?" "a vote over three verdict files succeeds"
kept=$(python3 -c 'import json,sys; print(",".join(f["title"] for f in json.load(open(sys.argv[1]))))' "$tmp/kept.json")
assert_eq "real bug" "$kept" "a finding is dropped when two of three refute it, kept otherwise"
dropped=$(python3 -c 'import json,sys; print(",".join(f["title"] for f in json.load(open(sys.argv[1]))))' "$tmp/dropped.json")
assert_eq "style only,disputed" "$dropped" "and the dropped ones are recorded, style counting as a refutation"
assert_contains "$out" "3 candidate(s), 1 kept, 2 dropped" "the log gives the counts"
assert_contains "$(cat "$tmp/dropped.json")" "guarded" "a dropped finding carries the verifiers' reasons"

# The job log is public and is written before the secret screen, so it carries
# counts only: no title, file or reason an agent wrote.
for agent_text in "style only" "disputed" "b.ts" "c.ts" "naming" "guarded"; do
  case "$out" in *"$agent_text"*) echo "FAIL: the log repeats agent-written text [$agent_text]" >&2; exit 1;; esac
done
assert_contains "$out" "refutations behind the dropped: 3 false, 2 style" "the reasons are given in aggregate"

# A verifier that failed or answered nothing readable is a vote to keep: a
# broken verifier must never be able to hide a real bug.
printf 'not json' > "$tmp/bad.json"
node "$V" "$tmp/c.json" "$tmp/k2.json" "$tmp/d2.json" 3 "$tmp/v3.json" "$tmp/bad.json" "$tmp/absent.json" >/dev/null 2>&1
assert_eq "0" "$?" "missing and unreadable verdict files do not fail the vote"

# An unreadable verdict file is not quoted either: a JSON parse error carries a
# snippet of the text it failed on.
printf 'agent-wrote-this {' > "$tmp/bad2.json"
out2=$(node "$V" "$tmp/c.json" "$tmp/k3.json" "$tmp/d3.json" 3 "$tmp/bad2.json" 2>&1)
case "$out2" in *agent-wrote-this*) echo "FAIL: a parse error repeats the verdict file's text" >&2; exit 1;; esac
assert_eq "3" "$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))))' "$tmp/k2.json")" "and one refutation out of three keeps everything"

# Verdicts are matched by index, and an index that names no candidate, or a
# verdict that is not one of the three words, counts for nothing.
printf '[{"index":7,"verdict":"false"},{"index":0,"verdict":"maybe"}]' > "$tmp/odd.json"
node "$V" "$tmp/c.json" "$tmp/k3.json" "$tmp/d3.json" 3 "$tmp/odd.json" "$tmp/odd.json" "$tmp/odd.json" >/dev/null 2>&1
assert_eq "3" "$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))))' "$tmp/k3.json")" "an unknown index or verdict refutes nothing"

# The candidates file is the reviewer's output and must be readable: losing it
# would post nothing and read as a clean review.
node "$V" "$tmp/none.json" "$tmp/k4.json" "$tmp/d4.json" 3 >/dev/null 2>&1
assert_eq "1" "$?" "a missing candidates file fails"

# With verification off the candidates pass through unchanged.
node "$V" "$tmp/c.json" "$tmp/k5.json" "$tmp/d5.json" 0 >/dev/null 2>&1
assert_eq "3" "$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))))' "$tmp/k5.json")" "zero verifiers keeps every candidate"

pass "vote-findings.test.sh"
