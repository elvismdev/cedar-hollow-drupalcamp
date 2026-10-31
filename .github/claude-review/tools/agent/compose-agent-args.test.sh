#!/usr/bin/env bash
set -uo pipefail
ROOT="$(git rev-parse --show-toplevel)"; . "$ROOT/tools/agent/test/assert.sh"
R="$ROOT/tools/agent/compose-agent-args.sh"

# The default: no model pinned anywhere. This must reproduce, byte for byte, the
# argument string every run before this change used, or the change is not a
# no-op and every prior measurement stops applying.
out=$(AGENT_TURNS_REPRODUCE=80 AGENT_TURNS_FIX=90 AGENT_TURNS_REVIEW=60 \
      AGENT_MODEL_REPRODUCE='' AGENT_MODEL_FIX='' AGENT_MODEL_REVIEW='' bash "$R")
assert_contains "$out" \
  "AGENT_ARGS_REPRODUCE=--setting-sources user --max-turns 80 --allowedTools Bash,Read,Glob,Grep,Edit,Write,Skill,mcp__wp-devdocs" \
  "reproduce args unchanged when no model is pinned"
assert_contains "$out" \
  "AGENT_ARGS_FIX=--setting-sources user --max-turns 90 --allowedTools Bash,Read,Glob,Grep,Edit,Write,Skill,mcp__wp-devdocs" \
  "fix args unchanged when no model is pinned"
assert_contains "$out" \
  "AGENT_ARGS_REVIEW=--setting-sources user --max-turns 60 --allowedTools Bash,Read,Glob,Grep,Skill" \
  "review args unchanged when no model is pinned"
case "$out" in *"--model"*) echo "FAIL: an empty model still emitted --model" >&2; exit 1 ;; esac

# A pinned model appears once, in the right phase, and nowhere else.
out=$(AGENT_TURNS_REPRODUCE=80 AGENT_TURNS_FIX=90 AGENT_TURNS_REVIEW=60 \
      AGENT_MODEL_REVIEW=claude-opus-5 bash "$R")
assert_contains "$out" "AGENT_ARGS_REVIEW=--setting-sources user --model claude-opus-5 --max-turns 60" \
  "the pinned review model lands in the review args"
assert_eq "1" "$(printf '%s' "$out" | grep -c -- '--model')" "the flag appears in exactly one phase"
case "$out" in *"AGENT_ARGS_FIX=--setting-sources user --model"*) echo "FAIL: review's model leaked into fix" >&2; exit 1 ;; esac

# Every phase pinned, each with its own value.
out=$(AGENT_MODEL_REPRODUCE=m1 AGENT_MODEL_FIX=m2 AGENT_MODEL_REVIEW=m3 bash "$R")
assert_contains "$out" "--model m1 " "reproduce takes its own model"
assert_contains "$out" "--model m2 " "fix takes its own model"
assert_contains "$out" "--model m3 " "review takes its own model"

# The review phase never gets write tools, whatever else is configured.
out=$(AGENT_MODEL_REVIEW=anything bash "$R")
rev=$(printf '%s\n' "$out" | grep '^AGENT_ARGS_REVIEW=')
case "$rev" in *Edit*|*Write*) echo "FAIL: the review phase was given write tools" >&2; exit 1 ;; esac

# Output is consumable as $GITHUB_ENV lines: one KEY=VALUE per line, no blanks.
assert_eq "3" "$(printf '%s\n' "$out" | grep -c '^AGENT_ARGS_[A-Z]*=')" "three env lines"
assert_eq "3" "$(printf '%s\n' "$out" | grep -c .)" "and nothing else"

# Every phase denies the tools that assume a human or a live session. Run
# 33679825065 spent 25 turns and produced nothing because the reproduce agent
# spawned subagents and waited for notifications that a workflow_dispatch run
# never delivers, and the step still reported success.
out=$(AGENT_TURNS_REPRODUCE=180 AGENT_TURNS_FIX=90 AGENT_TURNS_REVIEW=60 bash "$ROOT/tools/agent/compose-agent-args.sh")
for phase in REPRODUCE FIX REVIEW; do
  line=$(printf '%s\n' "$out" | grep "^AGENT_ARGS_${phase}=")
  assert_contains "$line" "--disallowedTools" "$phase denies something"
  for t in Agent Task ListAgents ScheduleWakeup; do
    assert_contains "$line" "$t" "$phase denies $t"
  done
done

# The deny list must not swallow the flags after it. --disallowedTools is
# variadic, so an unquoted space-separated list would eat --max-turns; measured
# against the CLI, which read a following prompt as further tool names.
assert_eq "0" "$(printf '%s\n' "$out" | grep -c 'disallowedTools [^ ]* [^-]')" \
  "the deny list is one comma-separated argument, not a space-separated list"
pass

