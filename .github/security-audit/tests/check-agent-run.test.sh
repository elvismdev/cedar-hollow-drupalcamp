#!/usr/bin/env bash
# Tests for check-agent-run.sh, with hand-written traces shaped as
# claude-code-action's execution file records them: a JSON array of the
# messages Claude Code prints, a subagent's messages carrying the id of the
# subagent call in parent_tool_use_id.
set -euo pipefail
# shellcheck source=../../claude-review/tools/agent/test/assert.sh
. "$(dirname "$0")/../../claude-review/tools/agent/test/assert.sh"
C="$(cd "$(dirname "$0")/.." && pwd)/check-agent-run.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# A checkout and a home of its own, so the fingerprint watches only these.
WS="$tmp/repo"
git init -q "$WS"
echo "a" > "$WS/tracked.txt"
git -C "$WS" add tracked.txt
git -C "$WS" -c user.email=ci@example.invalid -c user.name=CI commit -q -m init
export GITHUB_WORKSPACE="$WS"
export HOME="$tmp/home"
mkdir -p "$HOME/.claude/hooks"
echo '{"hooks":{"Stop":[]},"permissions":{"deny":["Bash"]},"theme":"dark"}' > "$HOME/.claude/settings.json"
echo "# memory" > "$HOME/.claude/CLAUDE.md"
echo "exit 0" > "$HOME/.claude/hooks/stop.sh"
unset AUDIT_INPUT_DIR

OUT=/mnt/audit/job/out
TOOLS="Read,Glob,Grep,Write,Edit,Agent,Task"
M=claude-test-model
H=claude-test-helper
FP="$tmp/fp"
bash "$C" --fingerprint "$FP" >/dev/null

# Message builders. A top-level message has a null parent; a subagent's
# message carries its subagent call's id.
msg () { # parent-or-null name input-json
  local parent=null
  if [ "$1" != null ]; then parent="\"$1\""; fi
  printf '{"type":"assistant","parent_tool_use_id":%s,"message":{"model":"%s","content":[{"type":"tool_use","id":"t%s","name":"%s","input":%s}]}}' \
    "$parent" "$M" "$RANDOM$RANDOM" "$2" "$3"
}
top () { msg null "$1" "$2"; }
sub () { msg "$1" "$2" "$3"; }
# agent <call-id> <description> [run_in_background] [result]: the subagent
# call and, unless result is "none", its tool_result holding a foreground
# report (or the result text given), as two messages.
agent () {
  printf '{"type":"assistant","parent_tool_use_id":null,"message":{"model":"%s","content":[{"type":"tool_use","id":"%s","name":"Agent","input":{"description":"%s","prompt":"p","subagent_type":"general-purpose","run_in_background":%s}}]}}' \
    "$M" "$1" "$2" "${3:-false}"
  if [ "${4:-}" != none ]; then
    printf ',{"type":"user","parent_tool_use_id":null,"message":{"content":[{"type":"tool_result","tool_use_id":"%s","content":[{"type":"text","text":"%s"}]}]}}' \
      "$1" "${4:-Done: read the files and wrote the entry.}"
  fi
}
result () { # model...
  local usage="" m
  for m in "$@"; do usage="$usage${usage:+,}\"$m\":{\"inputTokens\":1}"; done
  printf '{"type":"result","subtype":"success","is_error":false,"modelUsage":{%s}}' "$usage"
}
INIT='{"type":"system","subtype":"init","tools":["Agent","Edit","Glob","Grep","Read","Write"]}'
# trace <file> <message>...: an array of the messages given.
trace () { local f="$1"; shift; local IFS=,; printf '[%s]' "$*" > "$f"; }

run () { local job="$1" t="$2"; shift 2; bash "$C" "$job" "$t" "$TOOLS" "$OUT" "$FP" "$M" "$@" 2>&1 || true; }
rc () { local job="$1" t="$2"; shift 2; bash "$C" "$job" "$t" "$TOOLS" "$OUT" "$FP" "$M" "$@" >/dev/null 2>&1; echo $?; }

# The parts of a clean source run: the top-level agent reads the checkout and
# writes the shared files, one subagent reads and writes its own scratch.
CLEAN=(
  "$INIT"
  "$(top Read "{\"file_path\":\"$WS/tracked.txt\"}")"
  "$(top Write "{\"file_path\":\"$OUT/run-metadata.json\",\"content\":\"{}\"}")"
  "$(top Write "{\"file_path\":\"$OUT/agents/h01/scratch/.keep\",\"content\":\"\"}")"
  "$(agent ta1 "agent-id: h01 hunt the agenda")"
  "$(sub ta1 Grep "{\"pattern\":\"x\",\"path\":\"$WS\",\"glob\":\"*.php\"}")"
  "$(sub ta1 Read "{\"file_path\":\"$OUT/agents/h01/scratch/.keep\"}")"
  "$(sub ta1 Write "{\"file_path\":\"$OUT/agents/h01/scratch/entry.json\",\"content\":\"{}\"}")"
  "$(top Write "{\"file_path\":\"$OUT/findings.json\",\"content\":\"[]\"}")"
  "$(top Edit "{\"file_path\":\"$OUT/coverage-ledger.json\",\"old_string\":\"a\",\"new_string\":\"b\",\"replace_all\":false}")"
)

trace "$tmp/clean.json" "${CLEAN[@]}" "$(result "$M")"

# A foreground subagent hands its report back with SubagentHandback, a call
# that carries its parent id. With SubagentHandback in the allowed tools, as
# the workflow passes it, a subagent whose only call is its handback counts as
# attributed; a handback with another field, or with the tool not allowed,
# fails the run check.
HANDBACK_TOOLS="$TOOLS,SubagentHandback"
hb_rc () { bash "$C" source "$2" "$1" "$OUT" "$FP" "$M" >/dev/null 2>&1; echo $?; }
trace "$tmp/hb.json" "$INIT" "$(agent tb1 "agent-id: h02 report back")" \
  "$(sub tb1 SubagentHandback '{"message":"read nothing, found nothing"}')" "$(result "$M")"
assert_eq "0" "$(hb_rc "$HANDBACK_TOOLS" "$tmp/hb.json")" "a subagent whose only call is its SubagentHandback is attributed and passes"
assert_eq "1" "$(hb_rc "$TOOLS" "$tmp/hb.json")" "a SubagentHandback fails when the allowed tools leave it out"
trace "$tmp/hb-extra.json" "$INIT" "$(agent tb1 "agent-id: h02 report back")" \
  "$(sub tb1 SubagentHandback "{\"message\":\"x\",\"file_path\":\"$OUT/findings.json\"}")" "$(result "$M")"
assert_eq "1" "$(hb_rc "$HANDBACK_TOOLS" "$tmp/hb-extra.json")" "a SubagentHandback with a field other than message fails"
out=$(run source "$tmp/clean.json")
assert_eq "0" "$(rc source "$tmp/clean.json")" "a clean trace passes"
assert_contains "$out" "1 subagent call(s), 3 subagent tool call(s)" "and the subagent's calls are bound to it"
assert_contains "$out" "the run check passed" "and the check says it passed"

trace "$tmp/helper.json" "${CLEAN[@]}" "$(result "$M" "$H")"
assert_eq "0" "$(rc source "$tmp/helper.json" "$H")" "an allowlisted helper model passes"
assert_eq "1" "$(rc source "$tmp/helper.json")" "the same helper without the allowlist fails"

# Tools outside the allowed set, in the agent and in a subagent.
trace "$tmp/t.json" "${CLEAN[@]}" "$(top Bash '{"command":"id"}')" "$(result "$M")"
assert_eq "1" "$(rc source "$tmp/t.json")" "an agent Bash call fails"
assert_contains "$(run source "$tmp/t.json")" "Bash call 10: tool not allowed" "and is named by position"
trace "$tmp/t.json" "${CLEAN[@]}" "$(sub ta1 Bash '{"command":"id"}')" "$(result "$M")"
assert_eq "1" "$(rc source "$tmp/t.json")" "a subagent Bash call fails"

# The run check judges what happened, not the run_in_background value asked
# for: a call asking for the background whose subagent ran in the foreground,
# with its calls in the trace, passes.
for flag in true '"false"' '"yes"'; do
  trace "$tmp/t.json" "${CLEAN[@]}" "$(agent ta2 "agent-id: h02 hunt" "$flag")" "$(sub ta2 Read "{\"file_path\":\"$WS/tracked.txt\"}")" "$(result "$M")"
  assert_eq "0" "$(rc source "$tmp/t.json")" "run_in_background $flag with a foreground subagent and its calls passes"
done
# A subagent call whose result is an async launch ran in the background, even
# after some of its calls reached the trace. A launch is a plain string or a
# single text block that starts with the text in async-launch.txt; a report
# that quotes the phrase elsewhere passes.
LAUNCH="$(cat "$(dirname "$C")/async-launch.txt")"
launch_trace () { # result-json
  trace "$tmp/t.json" "${CLEAN[@]}" "$(agent ta2 "agent-id: h02 hunt" false none)" "$(sub ta2 Read "{\"file_path\":\"$WS/tracked.txt\"}")" \
    "{\"type\":\"user\",\"parent_tool_use_id\":null,\"message\":{\"content\":[{\"type\":\"tool_result\",\"tool_use_id\":\"ta2\",\"content\":$1}]}}" "$(result "$M")"
}
launch_trace "[{\"type\":\"text\",\"text\":\"$LAUNCH successfully. agentId: a1b2\"}]"
assert_eq "1" "$(rc source "$tmp/t.json")" "a subagent call whose result is an async launch block fails, though calls are attributed"
assert_contains "$(run source "$tmp/t.json")" "Agent call" "the refusal names the call"
assert_contains "$(run source "$tmp/t.json")" "(agent id h02) returned an async launch" "and the agent id"
launch_trace "\"$LAUNCH successfully. agentId: a1b2\""
assert_eq "1" "$(rc source "$tmp/t.json")" "an async launch as a plain string fails"
launch_trace "[{\"type\":\"text\",\"text\":\"Read tracked.txt. The file mentions $LAUNCH successfully in a log line.\"}]"
assert_eq "0" "$(rc source "$tmp/t.json")" "a report quoting the launch text mid-text passes"
launch_trace "[{\"type\":\"text\",\"text\":\"Summary first.\"},{\"type\":\"text\",\"text\":\"$LAUNCH successfully.\"}]"
assert_eq "0" "$(rc source "$tmp/t.json")" "a report of several blocks is not a launch"
launch_trace "[{\"type\":\"text\",\"text\":\"Read tracked.txt; nothing found.\"}]"
assert_eq "0" "$(rc source "$tmp/t.json")" "a subagent call whose result is the subagent's report passes"
# A subagent the safety classifier interrupted is reported, not refused, even
# with no calls; the other rules still apply to its calls in the trace, and a
# launch still fails.
INTERRUPTION="$(cat "$(dirname "$C")/classifier-interruption.txt")"
trace "$tmp/t.json" "${CLEAN[@]}" "$(agent ta2 "agent-id: h02 hunt" false "$INTERRUPTION")" "$(result "$M")"
assert_eq "0" "$(rc source "$tmp/t.json")" "an interrupted subagent with no calls passes"
assert_contains "$(run source "$tmp/t.json")" "(agent id h02) was interrupted by the safety classifier" "and is reported by call and agent id"
trace "$tmp/t.json" "$INIT" "$(agent ta2 "agent-id: h02 hunt" false "$INTERRUPTION")" "$(result "$M")"
assert_eq "0" "$(rc source "$tmp/t.json")" "a run whose only subagent was interrupted passes"
trace "$tmp/t.json" "${CLEAN[@]}" "$(agent ta2 "agent-id: h02 hunt" false "$INTERRUPTION")" "$(sub ta2 Read "{\"file_path\":\"$WS/tracked.txt\"}")" "$(result "$M")"
assert_eq "0" "$(rc source "$tmp/t.json")" "an interrupted subagent with allowed calls passes"
trace "$tmp/t.json" "${CLEAN[@]}" "$(agent ta2 "agent-id: h02 hunt" false "$INTERRUPTION")" "$(sub ta2 Bash '{"command":"id"}')" "$(result "$M")"
assert_eq "1" "$(rc source "$tmp/t.json")" "an interrupted subagent's refused call still fails the run"
trace "$tmp/t.json" "${CLEAN[@]}" "$(agent ta2 "agent-id: h02 hunt" false "Done, though the log quoted $INTERRUPTION.")" "$(result "$M")"
assert_eq "1" "$(rc source "$tmp/t.json")" "a report only quoting the interruption is not one, so a subagent with no calls still fails"
launch_trace "[{\"type\":\"text\",\"text\":\"$LAUNCH successfully. agentId: a1b2\"}]"
assert_eq "1" "$(rc source "$tmp/t.json")" "an async launch still fails alongside the interruption rule"
# A subagent call with no result cannot be shown to have finished.
trace "$tmp/t.json" "${CLEAN[@]}" "$(agent ta2 "agent-id: h02 hunt" false none)" "$(sub ta2 Read "{\"file_path\":\"$WS/tracked.txt\"}")" "$(result "$M")"
assert_eq "1" "$(rc source "$tmp/t.json")" "a subagent call with no result fails"
assert_contains "$(run source "$tmp/t.json")" "has no result in the trace" "and says why"
# Background subagents, as Claude Code records them happening.
trace "$tmp/t.json" "${CLEAN[@]}" "$(agent ta2 "agent-id: h02 hunt" true)" '{"type":"system","subtype":"task_started","tool_use_id":"ta2","is_backgrounded":true}' "$(sub ta2 Read "{\"file_path\":\"$WS/tracked.txt\"}")" "$(result "$M")"
assert_eq "1" "$(rc source "$tmp/t.json")" "a call whose task_started event is backgrounded fails, whatever it asked for"
trace "$tmp/t.json" "${CLEAN[@]}" "$(agent ta2 "agent-id: h02 hunt" true)" "$(result "$M")"
assert_eq "1" "$(rc source "$tmp/t.json")" "a subagent whose calls are missing from the trace fails"
trace "$tmp/t.json" "${CLEAN[@]}" '{"type":"system","subtype":"task_started","tool_use_id":"ta1","is_backgrounded":true}' "$(result "$M")"
assert_eq "1" "$(rc source "$tmp/t.json")" "a task_started event marked backgrounded fails"
trace "$tmp/t.json" "${CLEAN[@]}" '{"type":"result","subtype":"success","modelUsage":{},"subagent_stats":{"spawned":1,"started_in_background":1}}'
assert_eq "1" "$(rc source "$tmp/t.json")" "a background count in subagent_stats fails"

# Write paths, checked by check-trace-tools.sh with the output root.
write_fails () { # path message
  trace "$tmp/t.json" "${CLEAN[@]}" "$(top Write "{\"file_path\":\"$1\",\"content\":\"x\"}")" "$(result "$M")"
  assert_eq "1" "$(rc source "$tmp/t.json")" "$2"
}
write_fails "/mnt/audit/job/in/x.json" "a Write outside the output root fails"
write_fails "$WS/tracked.txt" "a Write into the checkout fails"
write_fails "agents/h01/scratch/x.json" "a Write with a relative path fails"
write_fails "$OUT/agents/h01/../h01/scratch/x.json" "a Write with .. fails even when it stays inside"

# Grep globs: any glob in a folder below the checkout's top level, the
# extension-shaped rule with no path or at the top level.
trace "$tmp/t.json" "${CLEAN[@]}" "$(sub ta1 Grep "{\"pattern\":\"x\",\"path\":\"$WS/web\",\"glob\":\"!**/node_modules/**\"}")" "$(result "$M")"
assert_eq "0" "$(rc source "$tmp/t.json")" "a negated Grep glob in a checkout subfolder passes"
trace "$tmp/t.json" "${CLEAN[@]}" "$(sub ta1 Grep '{"pattern":"x","glob":"!**/node_modules/**"}')" "$(result "$M")"
assert_eq "1" "$(rc source "$tmp/t.json")" "the same glob with no path fails"

# Subagent writes: only its own scratch, and never a shared or combined file.
sub_write () { # path expected-rc message [label]
  trace "$tmp/t.json" "${CLEAN[@]}" "$(sub ta1 Write "{\"file_path\":\"$1\",\"content\":\"x\"}")" "$(result "$M")"
  assert_eq "$2" "$(rc source "$tmp/t.json")" "$3"
  if [ -n "${4:-}" ]; then assert_contains "$(run source "$tmp/t.json")" "$4" "$3 says why"; fi
}
sub_write "$OUT/notes.md" 1 "a subagent writing outside its scratch fails" "outside its own agents/<id>/scratch/"
sub_write "$OUT/agents/h01/artifacts/a.json" 1 "a subagent writing its parent-owned artifacts fails"
sub_write "$OUT/agents/h01/scratch/deep/poc.php" 0 "a subagent writing deeper in its own scratch passes"
sub_write "$OUT/agents/h02/scratch/entry.json" 1 "a declared agent id that disagrees with the written path fails" "outside its own agents/<id>/scratch/"
sub_write "$OUT/findings.json" 1 "a subagent writing findings.json fails" "writes a shared or combined file"
sub_write "$OUT/coverage-ledger.json" 1 "a subagent writing the ledger fails" "writes a shared or combined file"
sub_write "$OUT/run-metadata.json" 1 "a subagent writing run-metadata.json fails" "writes a shared or combined file"
sub_write "$OUT/agents/h01/scratch/findings.json" 1 "a subagent writing findings.json inside its own scratch fails" "writes a shared or combined file"
sub_write "$OUT/cross-check.json" 1 "a subagent writing a combined file fails" "writes a shared or combined file"
sub_write "$OUT/agents/h01/scratch/cross-check.json" 1 "a subagent writing a combined file in its scratch fails" "writes a shared or combined file"
trace "$tmp/t.json" "${CLEAN[@]}" "$(sub ta1 Edit "{\"file_path\":\"$OUT/run-metadata.json\",\"old_string\":\"a\",\"new_string\":\"b\"}")" "$(result "$M")"
assert_eq "1" "$(rc source "$tmp/t.json")" "a subagent editing run-metadata.json fails"

# merge-records.py's trusted outputs: no agent writes them, the top-level
# agent included, wherever they are.
for f in trusted-meta.json tie-break-inputs.json select.json list.json; do
  trace "$tmp/t.json" "${CLEAN[@]}" "$(top Write "{\"file_path\":\"$OUT/$f\",\"content\":\"{}\"}")" "$(result "$M")"
  assert_eq "1" "$(rc source "$tmp/t.json")" "the top-level agent writing $f fails"
  assert_contains "$(run source "$tmp/t.json")" "trusted outputs" "and says why for $f"
done
trace "$tmp/t.json" "${CLEAN[@]}" "$(top Edit "{\"file_path\":\"$OUT/state/list.json\",\"old_string\":\"a\",\"new_string\":\"b\"}")" "$(result "$M")"
assert_eq "1" "$(rc cross-check "$tmp/t.json")" "a top-level Edit of list.json in a subdirectory fails"
trace "$tmp/t.json" "${CLEAN[@]}" "$(sub ta1 Write "{\"file_path\":\"$OUT/agents/h01/scratch/trusted-meta.json\",\"content\":\"{}\"}")" "$(result "$M")"
assert_eq "1" "$(rc source "$tmp/t.json")" "a subagent writing trusted-meta.json in its own scratch fails"
# The state files: the source job's agents (source and repair) write them;
# in every later job no agent does, the top-level one included.
for f in findings.json coverage-ledger.json run-metadata.json disputed.json audit-history.json; do
  trace "$tmp/t.json" "$INIT" "$(top Write "{\"file_path\":\"$OUT/$f\",\"content\":\"[]\"}")" "$(result "$M")"
  assert_eq "0" "$(rc source "$tmp/t.json")" "in source, the top-level agent writing $f passes"
  for job in poc-write poc-decide cross-check; do
    assert_eq "1" "$(rc "$job" "$tmp/t.json")" "in $job (cross-check covers the tie-break step), the top-level agent writing $f fails"
  done
  assert_contains "$(run poc-decide "$tmp/t.json")" "state file outside the source job" "and says why for $f"
  trace "$tmp/t.json" "$INIT" "$(top Edit "{\"file_path\":\"$OUT/sub/$f\",\"old_string\":\"a\",\"new_string\":\"b\"}")" "$(result "$M")"
  assert_eq "1" "$(rc cross-check "$tmp/t.json")" "in cross-check, a top-level Edit of $f in a subdirectory fails"
done
# The clean run for the later jobs: without the top-level writes under
# agents/ and of the state files, which only the source job's agents make.
CLEAN_POC=("${CLEAN[@]:0:2}" "${CLEAN[@]:4:4}")
assert_eq "0" "$(trace "$tmp/t.json" "${CLEAN_POC[@]}" "$(result "$M")"; rc poc-write "$tmp/t.json")" "the later jobs' clean baseline passes in poc-write"
# In poc-write the top-level agent writes nothing under agents/.
trace "$tmp/t.json" "${CLEAN_POC[@]}" "$(top Write "{\"file_path\":\"$OUT/agents/h01/scratch/poc.php\",\"content\":\"x\"}")" "$(result "$M")"
assert_eq "1" "$(rc poc-write "$tmp/t.json")" "in poc-write, a top-level write under agents/ fails"
assert_contains "$(run poc-write "$tmp/t.json")" "the top-level agent writes under agents/" "and says why"
assert_eq "0" "$(rc poc-decide "$tmp/t.json")" "in poc-decide, the same top-level write passes"
trace "$tmp/t.json" "${CLEAN_POC[@]}" "$(top Write "{\"file_path\":\"$OUT/poc-manifest.json\",\"content\":\"{}\"}")" "$(result "$M")"
assert_eq "0" "$(rc poc-write "$tmp/t.json")" "in poc-write, the top-level agent writing poc-manifest.json passes"

# Attribution: each subagent call declares one valid, unique id.
attr () { # description message
  trace "$tmp/t.json" "${CLEAN[@]}" "$(agent ta2 "$1")" "$(sub ta2 Read "{\"file_path\":\"$WS/tracked.txt\"}")" "$(result "$M")"
  assert_eq "1" "$(rc source "$tmp/t.json")" "$2"
}
attr "hunt with no id" "a subagent call with no agent id fails"
attr "agent-id: H02 hunt" "an agent id outside the canonical form fails"
attr "agent-id: h02 and agent-id: h03" "two declared agent ids fail"
attr "agent-id: h01 again" "a second subagent with the same id fails"
# The id token is ASCII only: after "agent-id:" only spaces or tabs.
attr "agent-id:$(printf '\xef\xbb\xbf')h1 hunt" "an id after a U+FEFF binds no id and fails"
attr "agent-id:$(printf '\xc2\xa0')h1 hunt" "an id after a no-break space binds no id and fails"
attr "agent-id: h1$(printf '\xc3\xa9') hunt" "an id running into a non-ASCII letter binds no id and fails"
trace "$tmp/t.json" "${CLEAN[@]}" "$(agent ta2 'agent-id:\th02 hunt')" "$(sub ta2 Read "{\"file_path\":\"$WS/tracked.txt\"}")" "$(result "$M")"
assert_eq "0" "$(rc source "$tmp/t.json")" "an id after a tab binds"
trace "$tmp/t.json" "${CLEAN[@]}" "$(sub tz9 Read "{\"file_path\":\"$WS/tracked.txt\"}")" "$(result "$M")"
assert_eq "1" "$(rc source "$tmp/t.json")" "a call whose parent is no subagent call fails"
assert_contains "$(run source "$tmp/t.json")" "cannot be attributed" "and says why"
# The other name of the subagent tool binds the same way.
trace "$tmp/t.json" "$INIT" "$(top Task '{"description":"agent-id: v1 verify","prompt":"p"}' | sed 's/"id":"t[0-9]*"/"id":"tk1"/')" \
  "$(sub tk1 Write "{\"file_path\":\"$OUT/agents/v1/scratch/entry.json\",\"content\":\"{}\"}")" \
  '{"type":"user","parent_tool_use_id":null,"message":{"content":[{"type":"tool_result","tool_use_id":"tk1","content":"Done."}]}}' "$(result "$M")"
assert_eq "0" "$(rc cross-check "$tmp/t.json")" "a Task call binds its subagent like an Agent call"

# Isolation: in poc-write a subagent may not reach another agent's directory.
iso () { # job tool input expected-rc message
  trace "$tmp/t.json" "${CLEAN_POC[@]}" "$(sub ta1 "$2" "$3")" "$(result "$M")"
  assert_eq "$4" "$(rc "$1" "$tmp/t.json")" "$5"
}
OTHER="$OUT/agents/h02/scratch/poc.php"
iso poc-write Read "{\"file_path\":\"$OTHER\"}" 1 "in poc-write, a subagent reading the other script's directory fails"
iso poc-decide Read "{\"file_path\":\"$OTHER\"}" 0 "in poc-decide, the same read passes"
iso source Read "{\"file_path\":\"$OTHER\"}" 0 "in source, the same read passes"
iso poc-write Read "{\"file_path\":\"$OUT/agents/h01/scratch/poc.php\"}" 0 "in poc-write, a subagent reading its own directory passes"
iso poc-write Read "{\"file_path\":\"$OUT/select.json\"}" 0 "in poc-write, a subagent reading a top-level file passes"
iso poc-write Grep "{\"pattern\":\"x\",\"path\":\"$OUT/agents\"}" 1 "in poc-write, a subagent Grep over agents/ fails"
iso poc-write Grep "{\"pattern\":\"x\",\"path\":\"$OUT\"}" 1 "in poc-write, a subagent Grep over the output root fails"
iso poc-write Glob "{\"pattern\":\"agents/*/scratch/poc.php\",\"path\":\"$OUT\"}" 1 "in poc-write, a subagent Glob across agents fails"
iso poc-write Glob "{\"pattern\":\"../h02/scratch/*\",\"path\":\"$OUT/agents/h01\"}" 1 "in poc-write, a subagent Glob climbing to another agent fails"
iso poc-write Glob "{\"pattern\":\"scratch/*/../../../h02/scratch/poc.php\",\"path\":\"$OUT/agents/h01\"}" 1 "in poc-write, a subagent Glob climbing after a wildcard fails"
assert_contains "$(run poc-write "$tmp/t.json")" "cannot be judged" "and says its reach cannot be judged"
# Brace groups are expanded before judging, so a brace-spelled .. is a ..
H01="$OUT/agents/h01"

# In poc-decide and cross-check a subagent may not reach the directory of
# another subagent declared in the same trace; other directories stay open.
IN=/mnt/audit/job/in
TWO=("${CLEAN_POC[@]}" "$(agent ta2 "agent-id: h02 decide item 2")"
     "$(sub ta2 Write "{\"file_path\":\"$OUT/agents/h02/scratch/entry.json\",\"content\":\"{}\"}")")
peer () { # job tool input expected-rc message
  trace "$tmp/t.json" "${TWO[@]}" "$(sub ta1 "$2" "$3")" "$(result "$M")"
  assert_eq "$4" "$(AUDIT_INPUT_DIR="$IN" rc "$1" "$tmp/t.json")" "$5"
}
for job in poc-decide cross-check; do
  peer "$job" Read "{\"file_path\":\"$OUT/agents/h02/scratch/entry.json\"}" 1 "in $job, a subagent reading another declared subagent's entry fails"
  peer "$job" Glob "{\"pattern\":\"*.json\",\"path\":\"$OUT/agents/h02/scratch\"}" 1 "in $job, a subagent Glob in another declared subagent's directory fails"
  peer "$job" Grep "{\"pattern\":\"x\",\"path\":\"$OUT\"}" 1 "in $job, a subagent Grep over the output root reaches the other subagent and fails"
  peer "$job" Glob "{\"pattern\":\"agents/*/scratch/entry.json\",\"path\":\"$OUT\"}" 1 "in $job, a subagent Glob across agents/ fails"
  peer "$job" Read "{\"file_path\":\"$OUT/agents/h01/scratch/entry.json\"}" 0 "in $job, a subagent reading its own directory passes"
  peer "$job" Read "{\"file_path\":\"$OUT/agents/hunter-x/scratch/notes.md\"}" 0 "in $job, a subagent reading an undeclared (source job) agent's directory passes"
  peer "$job" Read "{\"file_path\":\"$IN/scripts/agents/poc-1-a/scratch/poc.php\"}" 0 "in $job, a subagent reading poc-write's script passes"
  peer "$job" Read "{\"file_path\":\"$IN/records/poc-run-1-a.json\"}" 0 "in $job, a subagent reading a run record passes"
  peer "$job" Grep "{\"pattern\":\"x\",\"path\":\"$OUT/findings.json\"}" 0 "in $job, a subagent Grep of findings.json passes"
done
trace "$tmp/t.json" "${TWO[@]}" "$(sub ta1 Read "{\"file_path\":\"$OUT/agents/h02/scratch/entry.json\"}")" "$(result "$M")"
assert_contains "$(run cross-check "$tmp/t.json")" "another agent's agents/<id>/" "and says why"
assert_eq "0" "$(rc source "$tmp/t.json")" "in source, the same read passes"
# With one subagent declared, a Grep over the output root reaches no other.
iso poc-decide Grep "{\"pattern\":\"x\",\"path\":\"$OUT\"}" 0 "in poc-decide, a lone subagent's Grep over the output root passes"

# A subagent in a later job writing a state or shared file inside its own
# scratch fails.
for job in poc-decide cross-check; do
  trace "$tmp/t.json" "${CLEAN_POC[@]}" "$(sub ta1 Write "{\"file_path\":\"$OUT/agents/h01/scratch/findings.json\",\"content\":\"[]\"}")" "$(result "$M")"
  assert_eq "1" "$(rc "$job" "$tmp/t.json")" "in $job, a subagent writing findings.json in its own scratch fails"
done
iso poc-write Glob "{\"pattern\":\"{.,}./h02/scratch/*\",\"path\":\"$H01\"}" 1 "in poc-write, {.,}./h02 from agents/h01 fails"
assert_contains "$(run poc-write "$tmp/t.json")" "reads another agent's" "and is judged as ../h02"
iso poc-write Glob "{\"pattern\":\".{.,}/h02/scratch/*\",\"path\":\"$H01\"}" 1 "in poc-write, .{.,}/h02 from agents/h01 fails"
iso poc-write Glob "{\"pattern\":\"../{h01,h02}/scratch/*\",\"path\":\"$H01\"}" 1 "in poc-write, a brace group naming another agent fails"
iso poc-write Glob "{\"pattern\":\"{scratch,artifacts}/*.php\",\"path\":\"$H01\"}" 0 "in poc-write, a brace group inside its own directory passes"
iso poc-write Glob "{\"pattern\":\"scratch/*/{.,}./{.,}./h02/*\",\"path\":\"$H01\"}" 1 "in poc-write, a brace-spelled .. after a wildcard fails"
iso poc-write Grep "{\"pattern\":\"x\",\"path\":\"$H01\",\"glob\":\"{.,}./h02/**\"}" 1 "in poc-write, a Grep glob with a brace-spelled .. fails"
iso poc-write Grep "{\"pattern\":\"x\",\"path\":\"$H01\",\"glob\":\"*.{php,inc}\"}" 0 "in poc-write, a Grep glob with an extension brace group passes"
iso poc-write Glob "{\"pattern\":\"{scratch/*\",\"path\":\"$H01\"}" 1 "in poc-write, an unbalanced brace fails closed"
iso poc-write Glob "{\"pattern\":\"scratch}/*\",\"path\":\"$H01\"}" 1 "in poc-write, a stray closing brace fails closed"
iso poc-write Glob "{\"pattern\":\"{scratch,{a,b}}/*\",\"path\":\"$H01\"}" 0 "in poc-write, a nested brace group inside its own directory passes"
iso poc-write Glob "{\"pattern\":\"{scratch,{.,{.,}.}/h02}/*\",\"path\":\"$H01\"}" 1 "in poc-write, a nested brace-spelled .. to another agent fails"
iso poc-write Glob "{\"pattern\":\"{..}/h02/scratch/*\",\"path\":\"$H01\"}" 1 "in poc-write, a literal {..} group is judged as .. and fails"
iso poc-decide Glob "{\"pattern\":\"{.,}./h02/scratch/*\",\"path\":\"$H01\"}" 0 "in poc-decide, the brace-spelled read passes"
iso poc-write Glob "{\"pattern\":\"scratch/*.php\",\"path\":\"$OUT/agents/h01\"}" 0 "in poc-write, a subagent Glob in its own directory passes"
iso poc-decide Grep "{\"pattern\":\"x\",\"path\":\"$OUT/agents\"}" 0 "in poc-decide, a subagent Grep over agents/ passes"

# Models.
trace "$tmp/t.json" "${CLEAN[@]}" "$(result "$M" claude-other-model)"
assert_eq "1" "$(rc source "$tmp/t.json")" "an unexpected model in modelUsage fails"
assert_contains "$(run source "$tmp/t.json")" "other than the pinned model" "and says why"
case "$(run source "$tmp/t.json")" in *claude-other-model*) echo "FAIL: a model name reached the log" >&2; exit 1;; esac
trace "$tmp/t.json" "${CLEAN[@]}" "$(top Read "{\"file_path\":\"$WS/tracked.txt\"}" | sed "s/$M/claude-other-model/")" "$(result "$M")"
assert_eq "1" "$(rc source "$tmp/t.json")" "an unexpected model on an assistant message fails"
trace "$tmp/t.json" "${CLEAN[@]}" '{"type":"assistant","parent_tool_use_id":null,"message":{"model":"<synthetic>","content":[]}}' "$(result "$M")"
assert_eq "0" "$(rc source "$tmp/t.json")" "Claude Code's own synthetic message is not a model"

# Subagents used, none of their calls in the trace.
trace "$tmp/t.json" "$INIT" "$(agent ta1 "agent-id: h01 hunt")" "$(result "$M")"
assert_eq "1" "$(rc source "$tmp/t.json")" "subagent use with no subagent calls in the trace fails"
assert_contains "$(run source "$tmp/t.json")" "none of their tool calls" "and says why"
trace "$tmp/t.json" "${CLEAN[@]}" "$(agent ta2 "agent-id: h02 hunt")" "$(result "$M")"
assert_eq "1" "$(rc source "$tmp/t.json")" "one subagent with no calls fails even when another has calls"
assert_contains "$(run source "$tmp/t.json")" "Agent call 10: started a subagent with no tool calls" "and names that subagent call"
trace "$tmp/t.json" "$INIT" '{"type":"result","subtype":"success","modelUsage":{},"subagent_stats":{"spawned":2,"started_in_background":0}}'
assert_eq "1" "$(rc source "$tmp/t.json")" "a spawned count with no subagent calls fails"
trace "$tmp/t.json" "$INIT" "$(top Read "{\"file_path\":\"$WS/tracked.txt\"}")" "$(result "$M")"
assert_eq "0" "$(rc source "$tmp/t.json")" "a run with no subagents at all passes"

# The job folder holding in/ and out/ is a read root only while it holds
# nothing else on disk. Glob 3 of audit run 41347206214 was pattern **/* with
# that folder as its path.
JOB_DIR="$tmp/audit/source"
mkdir -p "$JOB_DIR/in" "$JOB_DIR/out"
jobdir_rc () { AUDIT_INPUT_DIR="${JD_IN-$JOB_DIR/in}" bash "$C" source "$tmp/jd.json" "$TOOLS" "$JOB_DIR/out" "$FP" "$M" >/dev/null 2>&1; echo $?; }
trace "$tmp/jd.json" "$INIT" "$(top Glob "{\"pattern\":\"**/*\",\"path\":\"$JOB_DIR\"}")" "$(result "$M")"
assert_eq "0" "$(jobdir_rc)" "a Glob of the job folder holding only in and out passes"
JD_IN="" ; assert_eq "1" "$(jobdir_rc)" "the job folder is no root when AUDIT_INPUT_DIR is unset"
JD_IN="$tmp/elsewhere/in" ; assert_eq "1" "$(jobdir_rc)" "the job folder is no root when AUDIT_INPUT_DIR is another job's in"
JD_IN="$JOB_DIR/in/" ; assert_eq "1" "$(jobdir_rc)" "the job folder is no root when AUDIT_INPUT_DIR is not exactly <job>/in"
unset JD_IN
touch "$JOB_DIR/extra"
assert_eq "1" "$(jobdir_rc)" "a Glob of the job folder fails once it holds anything else"
rm "$JOB_DIR/extra"
rmdir "$JOB_DIR/in"
assert_eq "1" "$(jobdir_rc)" "a Glob of the job folder fails when in/ is missing"
mkdir "$JOB_DIR/in"
mv "$JOB_DIR/in" "$tmp/real-in" && ln -s "$tmp/real-in" "$JOB_DIR/in"
assert_eq "1" "$(jobdir_rc)" "a Glob of the job folder fails when in/ is a link"
rm "$JOB_DIR/in" && mv "$tmp/real-in" "$JOB_DIR/in"
trace "$tmp/jd.json" "$INIT" "$(top Glob "{\"pattern\":\"**/*\",\"path\":\"$tmp/audit\"}")" "$(result "$M")"
assert_eq "1" "$(jobdir_rc)" "a Glob of the folder above the job folder still fails"
trace "$tmp/jd.json" "$INIT" "$(top Glob "{\"pattern\":\"**/*\",\"path\":\"$JOB_DIR\"}")" "$(result "$M")"
assert_eq "1" "$(bash "$C" source "$tmp/jd.json" "$TOOLS" "$OUT" "$FP" "$M" >/dev/null 2>&1; echo $?)" \
  "a Glob of another job folder is not made a root by this one"

# The fingerprint: the checkout and the watched parts of ~/.claude.
assert_eq "0" "$(rc source "$tmp/clean.json")" "unchanged state passes"
echo "b" >> "$WS/tracked.txt"
assert_eq "1" "$(rc source "$tmp/clean.json")" "a change to a tracked file fails"
assert_contains "$(run source "$tmp/clean.json")" "changed while the agent ran: status" "and names what changed"
git -C "$WS" checkout -q -- tracked.txt
echo "new" > "$WS/untracked.txt"
assert_eq "1" "$(rc source "$tmp/clean.json")" "a new untracked file fails"
rm "$WS/untracked.txt"
git -C "$WS" -c user.email=ci@example.invalid -c user.name=CI commit -q --allow-empty -m moved
assert_contains "$(run source "$tmp/clean.json")" "changed while the agent ran: head" "a moved HEAD fails"
bash "$C" --fingerprint "$FP" >/dev/null

settings_case () { # json expected-rc message
  local saved; saved=$(cat "$HOME/.claude/settings.json")
  echo "$1" > "$HOME/.claude/settings.json"
  assert_eq "$2" "$(rc source "$tmp/clean.json")" "$3"
  echo "$saved" > "$HOME/.claude/settings.json"
}
settings_case '{"hooks":{"Stop":[{"hooks":[]}]},"permissions":{"deny":["Bash"]},"theme":"dark"}' 1 "a changed hooks key fails"
settings_case '{"hooks":{"Stop":[]},"permissions":{"deny":[]},"theme":"dark"}' 1 "a changed permissions key fails"
settings_case '{"hooks":{"Stop":[]},"permissions":{"deny":["Bash"]},"theme":"light"}' 1 "a change to any other key fails"
settings_case '{"hooks":{"Stop":[]},"permissions":{"deny":["Bash"]},"theme":"dark","apiKeyHelper":"/tmp/x"}' 1 "an added apiKeyHelper fails"
settings_case '{"hooks":{"Stop":[]},"permissions":{"deny":["Bash"]},"theme":"dark","enableAllProjectMcpServers":true}' 0 "adding enableAllProjectMcpServers passes"
settings_case '{"theme":"dark", "permissions":{"deny":["Bash"]},  "hooks":{"Stop":[]}}' 0 "reordering the keys passes"
settings_case 'not json' 1 "a settings file that no longer parses fails"
# claude-code-action creates settings.json holding only
# enableAllProjectMcpServers when none exists before the agent step.
saved=$(cat "$HOME/.claude/settings.json")
rm "$HOME/.claude/settings.json"
bash "$C" --fingerprint "$FP" >/dev/null
echo '{"enableAllProjectMcpServers":true}' > "$HOME/.claude/settings.json"
assert_eq "0" "$(rc source "$tmp/clean.json")" "a settings.json created holding only enableAllProjectMcpServers passes"
echo '{"enableAllProjectMcpServers":true,"env":{"NODE_OPTIONS":"--require /tmp/x"}}' > "$HOME/.claude/settings.json"
assert_eq "1" "$(rc source "$tmp/clean.json")" "a settings.json created with env fails"
echo '{"enableAllProjectMcpServers":true,"hooks":{"Stop":[]}}' > "$HOME/.claude/settings.json"
assert_eq "1" "$(rc source "$tmp/clean.json")" "a settings.json created with hooks fails"
echo '{"permissions":{"allow":["Bash"]}}' > "$HOME/.claude/settings.json"
assert_eq "1" "$(rc source "$tmp/clean.json")" "a settings.json created with permissions fails"
echo "$saved" > "$HOME/.claude/settings.json"
bash "$C" --fingerprint "$FP" >/dev/null
echo "# changed" > "$HOME/.claude/CLAUDE.md"
assert_eq "1" "$(rc source "$tmp/clean.json")" "a changed ~/.claude/CLAUDE.md fails"
echo "# memory" > "$HOME/.claude/CLAUDE.md"
mkdir -p "$HOME/.claude/agents" && echo "x" > "$HOME/.claude/agents/new.md"
assert_eq "1" "$(rc source "$tmp/clean.json")" "a new file in ~/.claude/agents fails"
rm -r "$HOME/.claude/agents"
assert_eq "0" "$(rc source "$tmp/clean.json")" "restored state passes again"

# The fingerprint fails closed: what it cannot read is an error, never a
# stable value that compares equal before and after.
fp_rc () { bash "$C" --fingerprint "$tmp/fp2" >/dev/null 2>&1; echo $?; }
mkdir -p "$tmp/not-a-repo"
assert_eq "1" "$(GITHUB_WORKSPACE="$tmp/not-a-repo" fp_rc)" "--fingerprint fails on a workspace that is not a git repository"
assert_eq "no" "$([ -e "$tmp/fp2" ] && echo yes || echo no)" "and writes no fingerprint"
mkdir -p "$WS/sub"
assert_eq "1" "$(GITHUB_WORKSPACE="$WS/sub" fp_rc)" "--fingerprint fails on a folder below a repository's top"
rmdir "$WS/sub"
assert_eq "1" "$(GITHUB_WORKSPACE="" fp_rc)" "--fingerprint fails with no workspace"
assert_eq "1" "$(GITHUB_WORKSPACE="$tmp/not-a-repo" rc source "$tmp/clean.json")" "the comparison fails when the workspace is not a repository"
saved=$(cat "$HOME/.claude/settings.json")
echo 'not json' > "$HOME/.claude/settings.json"
assert_eq "1" "$(fp_rc)" "--fingerprint fails when settings.json does not parse"
assert_contains "$(run source "$tmp/clean.json")" "could not be taken again" "and the comparison fails"
echo "$saved" > "$HOME/.claude/settings.json"
# A git that refuses (as it does on a directory of dubious ownership) for
# status only, after HEAD was read.
mkdir -p "$tmp/bin"
real_git=$(command -v git)
printf '#!/usr/bin/env bash\nfor a in "$@"; do if [ "$a" = status ]; then echo "fatal: detected dubious ownership" >&2; exit 128; fi; done\nexec %q "$@"\n' "$real_git" > "$tmp/bin/git"
chmod +x "$tmp/bin/git"
assert_eq "1" "$(PATH="$tmp/bin:$PATH" fp_rc)" "--fingerprint fails when git status refuses"
assert_eq "1" "$(PATH="$tmp/bin:$PATH" rc source "$tmp/clean.json")" "and so does the comparison"
assert_eq "0" "$(rc source "$tmp/clean.json")" "the real state still passes"

# No value written by the agent reaches the log.
canary="zq$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')"
trace "$tmp/t.json" "${CLEAN[@]}" "$(agent ta2 "agent-id: $canary")" "$(sub ta2 Write "{\"file_path\":\"$OUT/agents/$canary/x\",\"content\":\"$canary\"}")" \
  "$(sub ta1 Write "{\"file_path\":\"$OUT/$canary.json\",\"content\":\"x\"}")" "$(result "$M")"
out=$(run poc-write "$tmp/t.json")
assert_contains "$out" "the run check failed" "the canary trace fails"
case "$out" in *"$canary"*) echo "FAIL: an agent-written value reached the log" >&2; exit 1;; esac

# It fails closed.
assert_eq "1" "$(rc source "$tmp/absent.json")" "a missing trace fails"
printf 'not json' > "$tmp/bad.json"
assert_eq "1" "$(rc source "$tmp/bad.json")" "an unreadable trace fails"
assert_eq "1" "$(bash "$C" source "$tmp/clean.json" "$TOOLS" "$OUT" "$tmp/no-fp" "$M" >/dev/null 2>&1; echo $?)" "a missing fingerprint fails"
assert_eq "2" "$(rc review "$tmp/clean.json")" "an unknown job is a usage error"
assert_eq "2" "$(bash "$C" source "$tmp/clean.json" >/dev/null 2>&1; echo $?)" "missing arguments are a usage error"

pass
