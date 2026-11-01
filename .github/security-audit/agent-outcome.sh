#!/usr/bin/env bash
# Names why an audit agent step ended, as one cause on stdout, so the trusted
# steps after it and the issue can say what happened. The first rule that
# holds wins:
#
#   max_turns    a result message in the trace has subtype error_max_turns.
#   usage_limit  the trace holds one of the review practice's quota or
#                authentication strings, and the step did not succeed or its
#                result says is_error. The strings are the ones the review
#                action's "Report the state and cause" step greps for; the
#                test runs each of that step's strings through this script, so
#                a string added there and not here fails CI. The gate keeps an
#                agent that merely quotes one of them in a successful run from
#                being reported as out of quota.
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

# The subtypes and is_error flags of the trace's result messages, which Claude
# Code writes. A trace that is not a JSON array yields none.
results=""
if [ "$have_trace" -eq 1 ]; then
  results=$(jq -r 'if type == "array" then .[] else empty end
    | select(type == "object" and .type == "result")
    | "\(.subtype // "") \(.is_error // false)"' "$trace" 2>/dev/null) || results=""
fi

cause=""
if grep -q '^error_max_turns ' <<<"$results"; then
  cause=max_turns
elif [ "$have_trace" -eq 1 ] \
  && { [ "$outcome" != "success" ] || grep -q ' true$' <<<"$results"; } \
  && grep -qF "${USAGE_LIMIT_STRINGS[@]/#/-e}" "$trace"; then
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
