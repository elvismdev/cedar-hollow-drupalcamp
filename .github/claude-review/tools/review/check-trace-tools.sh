#!/usr/bin/env bash
# Fail when an agent's execution trace shows a tool other than Read, Glob or Grep.
#
# The review and verification agents are allowed those three tools and every
# other tool is denied by name, because an allow-list alone did not stop an
# agent using other tools. This reads what the agent actually called, so a deny
# list that missed a name, or a flag that stopped reaching the agent, fails the
# job instead of passing silently.
#
# Every object in the trace whose type is "tool_use" is a call, wherever it is
# nested. A call with no name is reported as <unnamed> and fails: a call that
# cannot be identified cannot be shown to be allowed.
#
# Fails closed: a missing, empty or unreadable trace exits non-zero. The caller
# decides whether an absent trace means there is nothing to check.
#
# Usage: check-trace-tools.sh <trace.json>
set -uo pipefail

TRACE="${1:?usage: check-trace-tools.sh <trace.json>}"
ALLOWED='["Read","Glob","Grep"]'

[ -s "$TRACE" ] || {
  echo "check-trace-tools: no trace at '$TRACE', so the tools the agent used cannot be checked" >&2
  exit 1
}

calls=$(jq -r --argjson allowed "$ALLOWED" '
  [.. | objects | select(.type? == "tool_use") | (.name // "<unnamed>") | tostring]
  | {total: length, outside: (unique | map(select(. as $n | $allowed | index($n) | not)))}
  | "\(.total) \(.outside | join(","))"' "$TRACE") || {
  echo "check-trace-tools: '$TRACE' is not readable JSON, so the tools the agent used cannot be checked" >&2
  exit 1
}

read -r total outside <<<"$calls"
if [ -n "${outside:-}" ]; then
  echo "check-trace-tools: the agent used a tool outside Read, Glob and Grep: ${outside}" >&2
  exit 1
fi
echo "check-trace-tools: ${total} tool call(s), all Read, Glob or Grep"
