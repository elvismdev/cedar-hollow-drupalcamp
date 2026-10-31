#!/usr/bin/env bash
set -uo pipefail
ROOT="$(git rev-parse --show-toplevel)/.github/claude-review"
. "$ROOT/tools/agent/test/assert.sh"
C="$ROOT/tools/review/check-trace-tools.sh"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

run () { bash "$C" "$@" 2>&1; }
rc  () { bash "$C" "$@" >/dev/null 2>&1; echo $?; }

# A call shaped as claude-code-action's execution file records it.
call () { printf '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t%s","name":"%s","input":{}}]}}' "$RANDOM" "$1"; }

# The allowed tools pass, and the count says the check read something.
printf '[{"type":"system","subtype":"init","tools":["Read","Bash"]},%s,%s,%s]' \
  "$(call Read)" "$(call Glob)" "$(call Grep)" > "$tmp/ok.json"
assert_eq "0" "$(rc "$tmp/ok.json")" "Read, Glob and Grep pass"
assert_contains "$(run "$tmp/ok.json")" "3 tool call(s)" "and the calls are counted"

# A tool listed as available but never called is not a violation: the init
# message lists Bash above, and it passed.

# Any other tool fails and is named.
printf '[%s,%s]' "$(call Read)" "$(call Bash)" > "$tmp/bash.json"
assert_eq "1" "$(rc "$tmp/bash.json")" "a Bash call fails"
assert_contains "$(run "$tmp/bash.json")" ": Bash" "and names the tool"

# Every outside name is reported, once each.
printf '[%s,%s,%s]' "$(call Write)" "$(call WebFetch)" "$(call Write)" > "$tmp/two.json"
assert_contains "$(run "$tmp/two.json")" ": WebFetch,Write" "every outside tool is named once"

# An MCP tool is outside the list too.
printf '[%s]' "$(call mcp__github__create_issue)" > "$tmp/mcp.json"
assert_eq "1" "$(rc "$tmp/mcp.json")" "an MCP tool fails"

# A call nested anywhere counts, not only at the message level.
printf '[{"type":"user","wrapper":{"deep":[{"type":"tool_use","name":"Edit"}]}}]' > "$tmp/nested.json"
assert_eq "1" "$(rc "$tmp/nested.json")" "a nested call is found"

# A call with no name cannot be shown to be allowed.
printf '[{"type":"tool_use","id":"x"}]' > "$tmp/unnamed.json"
assert_contains "$(run "$tmp/unnamed.json")" "<unnamed>" "an unnamed call fails and says so"

# No calls at all is a clean trace.
printf '[{"type":"assistant","message":{"content":[{"type":"text","text":"[]"}]}}]' > "$tmp/none.json"
assert_eq "0" "$(rc "$tmp/none.json")" "a trace with no tool calls passes"

# It fails closed on what it cannot read.
assert_eq "1" "$(rc "$tmp/absent.json")" "a missing trace fails"
: > "$tmp/empty.json"
assert_eq "1" "$(rc "$tmp/empty.json")" "an empty trace fails"
printf 'not json' > "$tmp/bad.json"
assert_eq "1" "$(rc "$tmp/bad.json")" "an unreadable trace fails"
assert_contains "$(run "$tmp/bad.json")" "not readable JSON" "and says why"

pass
