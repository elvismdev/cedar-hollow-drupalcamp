#!/usr/bin/env bash
# Names why an audit agent step ended, as one cause on stdout, so the trusted
# steps after it and the issue can say what happened. The first rule that
# holds wins:
#
#   max_turns    a result message in the trace has subtype error_max_turns.
#   usage_limit  one of the review practice's quota or authentication strings
#                appears in the final result message (the last object of type
#                result) or in the error field of an assistant message, and
#                the step did not succeed or that final result says is_error.
#                Tool results are never searched, so an agent that read a file
#                holding the strings (this script, the review action) is not
#                reported as out of quota. The strings are the ones the review
#                action's "Report the state and cause" step greps for; the
#                test runs each of that step's strings through this script, so
#                a string added there and not here fails CI.
#   time_limit   the step did not succeed and the time from its start to its
#                end reached its timeout.
#   no_agent_ran there is no trace (absent or empty), which is the only
#                evidence an agent ran, as in the review action's "Prove an
#                agent ran" step, and the time limit was not reached.
#   no_outputs   an expected output file is missing or empty.
#   ok           otherwise.
#
# The step outcome is the step's outcome, not its conclusion, so a step with
# continue-on-error that failed still reads as failure here. Only the cause is
# printed, never trace text.
#
# Usage: agent-outcome.sh <execution-file> <step-outcome> <started-epoch> \
#                         <ended-epoch> <timeout-minutes> <expected-file>...
set -euo pipefail

usage() {
  echo "usage: agent-outcome.sh <execution-file> <step-outcome> <started-epoch> <ended-epoch> <timeout-minutes> <expected-file>..." >&2
  exit 2
}

[ "$#" -ge 5 ] || usage
trace="$1" outcome="$2" started="$3" ended="$4" timeout_min="$5"
shift 5
for n in "$started" "$ended"; do
  [[ "$n" =~ ^[0-9]+$ ]] || { echo "agent-outcome: start and end must be epoch seconds" >&2; exit 2; }
done
[[ "$timeout_min" =~ ^[1-9][0-9]*$ ]] || { echo "agent-outcome: the timeout must be a positive number of minutes" >&2; exit 2; }

USAGE_LIMIT_STRINGS=(
  'authentication_error'
  'OAuth token has expired'
  'usage limit'
  'rate_limit_error'
  'authentication_failed'
  'OAuth access token is invalid'
)

have_trace=0
if [ -n "$trace" ] && [ -s "$trace" ]; then have_trace=1; fi

# From the trace, which Claude Code writes as a JSON array: the subtypes of its
# result messages, whether the final one says is_error, and the text searched
# for the strings (the final result as JSON, then each assistant message's
# error field). A trace that is not a JSON array yields none of these.
subtypes="" final_error=false searched=""
if [ "$have_trace" -eq 1 ]; then
  subtypes=$(jq -r 'if type == "array" then .[] else empty end
    | select(type == "object" and .type == "result") | .subtype // ""' "$trace" 2>/dev/null) || subtypes=""
  final_error=$(jq -r 'if type == "array" then . else [] end
    | map(select(type == "object" and .type == "result")) | last
    | if type == "object" and .is_error == true then "true" else "false" end' "$trace" 2>/dev/null) || final_error=false
  searched=$(jq -r 'if type == "array" then . else [] end
    | ((map(select(type == "object" and .type == "result")) | last | select(. != null) | tojson),
       (.[] | select(type == "object" and .type == "assistant" and has("error")) | .error | tostring))' \
    "$trace" 2>/dev/null) || searched=""
fi

cause=""
if grep -qx 'error_max_turns' <<<"$subtypes"; then
  cause=max_turns
elif [ -n "$searched" ] \
  && { [ "$outcome" != "success" ] || [ "$final_error" = "true" ]; } \
  && grep -qF "${USAGE_LIMIT_STRINGS[@]/#/-e}" <<<"$searched"; then
  cause=usage_limit
elif [ "$outcome" != "success" ] && [ $((ended - started)) -ge $((timeout_min * 60)) ]; then
  cause=time_limit
elif [ "$have_trace" -eq 0 ]; then
  cause=no_agent_ran
else
  for f in "$@"; do
    if [ ! -s "$f" ]; then cause=no_outputs; break; fi
  done
fi
echo "${cause:-ok}"
