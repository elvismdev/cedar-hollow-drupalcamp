#!/usr/bin/env bash
# Tests for agent-outcome.sh, one fixture per cause, with traces shaped as
# claude-code-action's execution file records them.
set -euo pipefail
# shellcheck source=../../claude-review/tools/agent/test/assert.sh
. "$(dirname "$0")/../../claude-review/tools/agent/test/assert.sh"
O="$(cd "$(dirname "$0")/.." && pwd)/agent-outcome.sh"
ACTION="$(cd "$(dirname "$0")/../.." && pwd)/claude-review/review/action.yml"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# The step started at T0; a 30-minute timeout ends at T0 + 1800.
T0=1700000000
cause () { bash "$O" "$@" 2>/dev/null || echo "exit $?"; }

echo '{}' > "$tmp/findings.json"
echo '{}' > "$tmp/ledger.json"
OUTPUTS=("$tmp/findings.json" "$tmp/ledger.json")

cat > "$tmp/clean.json" <<'JSON'
[{"type":"system","subtype":"init","tools":["Read"]},
 {"type":"assistant","message":{"content":[{"type":"text","text":"done"}]}},
 {"type":"result","subtype":"success","is_error":false,"modelUsage":{}}]
JSON
assert_eq "ok" "$(cause "$tmp/clean.json" success "$T0" $((T0 + 600)) 30 "${OUTPUTS[@]}")" "a clean run with its outputs is ok"

cat > "$tmp/turns.json" <<'JSON'
[{"type":"system","subtype":"init","tools":["Read"]},
 {"type":"result","subtype":"error_max_turns","is_error":true,"modelUsage":{}}]
JSON
assert_eq "max_turns" "$(cause "$tmp/turns.json" failure "$T0" $((T0 + 600)) 30 "${OUTPUTS[@]}")" "error_max_turns is max_turns"
assert_eq "max_turns" "$(cause "$tmp/turns.json" failure "$T0" $((T0 + 1800)) 30 "$tmp/absent")" "and it wins over the time limit and missing outputs"

# The invalid-token run the review practice measured: api_retry events, a
# synthetic message and an error result whose subtype is still success.
cat > "$tmp/token.json" <<'JSON'
[{"type":"system","subtype":"api_retry","error_status":401,"error":"authentication_failed"},
 {"type":"assistant","message":{"content":[{"type":"text","text":"Failed to authenticate. API Error: 401 OAuth access token is invalid."}]},"error":"authentication_failed"},
 {"type":"result","subtype":"success","is_error":true,"result":"Failed to authenticate. API Error: 401 OAuth access token is invalid.","modelUsage":{}}]
JSON
assert_eq "usage_limit" "$(cause "$tmp/token.json" failure "$T0" $((T0 + 60)) 30 "$tmp/absent")" "an invalid token is usage_limit"
assert_eq "usage_limit" "$(cause "$tmp/token.json" success "$T0" $((T0 + 60)) 30 "$tmp/absent")" "and so it is when the step succeeded but the result is an error"

cat > "$tmp/quota.json" <<'JSON'
[{"type":"assistant","message":{"content":[{"type":"text","text":"working"}]}},
 {"type":"result","subtype":"success","is_error":true,"result":"Claude AI usage limit reached","modelUsage":{}}]
JSON
assert_eq "usage_limit" "$(cause "$tmp/quota.json" failure "$T0" $((T0 + 60)) 30 "${OUTPUTS[@]}")" "a reached usage limit is usage_limit"

# An agent that only quotes one of the strings, in a run that succeeded, is not.
cat > "$tmp/quoted.json" <<'JSON'
[{"type":"assistant","message":{"content":[{"type":"text","text":"The handler maps rate_limit_error to a 429."}]}},
 {"type":"result","subtype":"success","is_error":false,"modelUsage":{}}]
JSON
assert_eq "ok" "$(cause "$tmp/quoted.json" success "$T0" $((T0 + 60)) 30 "${OUTPUTS[@]}")" "a quoted string in a successful run is ok"

# Only the final result and assistant error fields are searched, never tool
# results: a failed step whose agent read a file holding the strings (this
# script or the review action) is classed by its other evidence.
cat > "$tmp/read-strings.json" <<'JSON'
[{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t1","name":"Read","input":{"file_path":"/w/agent-outcome.sh"}}]}},
 {"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":"'authentication_error' 'usage limit' 'rate_limit_error' 'OAuth access token is invalid'"}]}},
 {"type":"assistant","message":{"content":[{"type":"text","text":"still auditing"}]}}]
JSON
assert_eq "time_limit" "$(cause "$tmp/read-strings.json" failure "$T0" $((T0 + 1800)) 30 "${OUTPUTS[@]}")" "strings in a tool result are not usage_limit: a timed-out step is time_limit"
assert_eq "no_outputs" "$(cause "$tmp/read-strings.json" failure "$T0" $((T0 + 60)) 30 "$tmp/absent")" "and a step that stopped early without outputs is no_outputs"
cat > "$tmp/errfield.json" <<'JSON'
[{"type":"assistant","message":{"content":[{"type":"text","text":"x"}]},"error":"rate_limit_error"},
 {"type":"result","subtype":"success","is_error":false,"modelUsage":{}}]
JSON
assert_eq "usage_limit" "$(cause "$tmp/errfield.json" failure "$T0" $((T0 + 60)) 30 "${OUTPUTS[@]}")" "an assistant error field alone is usage_limit in a failed step"
# is_error is read from the final result only.
cat > "$tmp/earlier-error.json" <<'JSON'
[{"type":"result","subtype":"success","is_error":true,"result":"usage limit","modelUsage":{}},
 {"type":"result","subtype":"success","is_error":false,"result":"done","modelUsage":{}}]
JSON
assert_eq "ok" "$(cause "$tmp/earlier-error.json" success "$T0" $((T0 + 60)) 30 "${OUTPUTS[@]}")" "an earlier result's is_error and text do not make a successful step usage_limit"

# Every quota and authentication string the review action greps for is one
# here too: each, alone in a failed run's final result, is usage_limit.
mapfile -t strings < <(python3 -I - "$ACTION" <<'PY'
import re, sys, yaml
steps = yaml.safe_load(open(sys.argv[1]))["runs"]["steps"]
run = next(s["run"] for s in steps if s.get("id") == "result")
block = re.search(r"grep -qF(.*?)\"\$TRACE\"", run, re.S).group(1)
for s in re.findall(r"-e '([^']+)'", block):
    print(s)
PY
)
[ "${#strings[@]}" -ge 6 ] || { echo "FAIL: read only ${#strings[@]} strings from the review action" >&2; exit 1; }
for s in "${strings[@]}"; do
  jq -n --arg t "$s" '[{"type":"result","subtype":"success","is_error":false,"result":$t}]' > "$tmp/s.json"
  assert_eq "usage_limit" "$(cause "$tmp/s.json" failure "$T0" $((T0 + 60)) 30 "${OUTPUTS[@]}")" "the review action's string [$s] is usage_limit"
done

# Time: a failed step that ran to its timeout.
assert_eq "time_limit" "$(cause "$tmp/clean.json" failure "$T0" $((T0 + 1800)) 30 "${OUTPUTS[@]}")" "a failed step at its timeout is time_limit"
assert_eq "time_limit" "$(cause "$tmp/absent.json" failure "$T0" $((T0 + 1805)) 30 "${OUTPUTS[@]}")" "with no trace it is still time_limit"
assert_eq "ok" "$(cause "$tmp/clean.json" success "$T0" $((T0 + 1900)) 30 "${OUTPUTS[@]}")" "a step that succeeded is not time_limit"

# No trace, before the time limit.
assert_eq "no_agent_ran" "$(cause "$tmp/absent.json" failure "$T0" $((T0 + 1799)) 30 "${OUTPUTS[@]}")" "no trace is no_agent_ran"
: > "$tmp/empty.json"
assert_eq "no_agent_ran" "$(cause "$tmp/empty.json" success "$T0" $((T0 + 60)) 30 "${OUTPUTS[@]}")" "an empty trace is no_agent_ran even when the step succeeded"
assert_eq "no_agent_ran" "$(cause "" failure "$T0" $((T0 + 60)) 30 "${OUTPUTS[@]}")" "no execution file at all is no_agent_ran"

# Outputs.
assert_eq "no_outputs" "$(cause "$tmp/clean.json" success "$T0" $((T0 + 60)) 30 "$tmp/findings.json" "$tmp/absent")" "a missing expected output is no_outputs"
: > "$tmp/blank.json"
assert_eq "no_outputs" "$(cause "$tmp/clean.json" success "$T0" $((T0 + 60)) 30 "$tmp/blank.json")" "an empty expected output is no_outputs"
assert_eq "ok" "$(cause "$tmp/clean.json" success "$T0" $((T0 + 60)) 30)" "with no expected outputs a clean run is ok"

# A failed step that matches no other cause is never ok.
assert_eq "agent_failed" "$(cause "$tmp/clean.json" failure "$T0" $((T0 + 60)) 30 "${OUTPUTS[@]}")" "a failed step with its outputs, a short run and no quota string is agent_failed"
assert_eq "agent_failed" "$(cause "$tmp/clean.json" cancelled "$T0" $((T0 + 60)) 30 "${OUTPUTS[@]}")" "a cancelled step is not ok either"
assert_eq "no_outputs" "$(cause "$tmp/clean.json" failure "$T0" $((T0 + 60)) 30 "$tmp/absent")" "a failed step missing an output is still no_outputs"

# Arguments.
assert_eq "exit 2" "$(cause "$tmp/clean.json" success "$T0" $((T0 + 60)))" "a missing timeout is a usage error"
assert_eq "exit 2" "$(cause "$tmp/clean.json" success "$T0" later 30)" "an end that is not epoch seconds is a usage error"
assert_eq "exit 2" "$(cause "$tmp/clean.json" success "$T0" $((T0 + 60)) 0)" "a zero timeout is a usage error"

pass
