#!/usr/bin/env bash
# The review action names no_agent_ran when the reviewer step fails and leaves
# no trace. That needs the "Prove an agent ran" step to run after a failed
# agent step, which GitHub does only when its if: starts with always(), and the
# final step to read its failure as no_agent_ran.
set -uo pipefail
ROOT="$(git rev-parse --show-toplevel)/.github/claude-review"
. "$ROOT/tools/agent/test/assert.sh"
ACTION="$ROOT/review/action.yml"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

# step_field <id> <field>: prints a step's field from the action.
step_field () {
	python3 -I - "$ACTION" "$1" "$2" <<'PY'
import sys, yaml
steps = yaml.safe_load(open(sys.argv[1]))["runs"]["steps"]
for s in steps:
    if s.get("id") == sys.argv[2]:
        print(s.get(sys.argv[3], ""))
        sys.exit(0)
sys.exit(1)
PY
}

cond=$(step_field ran if); assert_exit 0 "$?" "the action has a step with id ran"
case "$cond" in
	"always() "*) ;;
	*) echo "FAIL: the ran step must run after a failed agent step (if: always() ...), got [$cond]" >&2; exit 1 ;;
esac
assert_contains "$cond" "steps.agent.outcome != 'skipped'" "and only when the agent step was attempted"

# The final step's own script, given what a failed agent with no trace leaves.
step_field result run > "$tmp/result.sh" || { echo "FAIL: the action has no result step" >&2; exit 1; }
result () {
	: > "$tmp/out"
	env -i PATH="$PATH" GITHUB_OUTPUT="$tmp/out" \
		CONCLUSIONS="success success failure failure" HEAD_CAUSE="" \
		TOOL_CHECKS="success" SCREEN="skipped" AGENT="failure" TRACE="" \
		CAPPED="0" SEEN="new" RUN="1" POST="skipped" "$@" bash "$tmp/result.sh" >/dev/null
	cat "$tmp/out"
}
out=$(result RAN=failure)
assert_contains "$out" "state=failed" "a failed agent step fails the review"
assert_contains "$out" "cause=no_agent_ran" "and with no trace the cause is no_agent_ran"

# A review run with an invalid OAuth token: the trace holds api_retry events,
# a synthetic assistant message and an error result, none of which carry the
# older "authentication_error" wording.
cat > "$tmp/trace.jsonl" <<'JSON'
{"type":"system","subtype":"api_retry","error_status":401,"error":"authentication_failed"}
{"type":"assistant","message":{"content":[{"type":"text","text":"Failed to authenticate. API Error: 401 OAuth access token is invalid."}]},"error":"authentication_failed"}
{"type":"result","subtype":"success","is_error":true,"result":"Failed to authenticate. API Error: 401 OAuth access token is invalid.","modelUsage":{}}
JSON
out=$(result RAN=success TRACE="$tmp/trace.jsonl")
assert_contains "$out" "cause=token_or_quota" "an invalid token in the trace is token_or_quota"

pass
