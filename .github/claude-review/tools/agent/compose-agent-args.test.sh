#!/usr/bin/env bash
set -uo pipefail
ROOT="$(git rev-parse --show-toplevel)/.github/claude-review"
. "$ROOT/tools/agent/test/assert.sh"
R="$ROOT/tools/agent/compose-agent-args.sh"
REQUIRED_DENY="Agent Task ListAgents ScheduleWakeup SendMessage Monitor TaskCreate CronCreate Bash Edit Write MultiEdit NotebookEdit WebFetch WebSearch Skill"

# The comma-separated value that follows a flag in an args line.
flag_value() { # line flag
  printf '%s\n' "$1" | sed -nE "s/.* $2 ([^ ]*).*/\1/p"
}

# Whole-token checks on the allow and deny lists. Substring matching would let
# Task pass on TaskCreate, Agent on ListAgents and Edit on MultiEdit.
check_tool_lists() { # line ; prints a failure per line, nothing when sound
  local allow deny t
  allow=$(flag_value "$1" --allowedTools | tr ',' '\n')
  deny=$(flag_value "$1" --disallowedTools | tr ',' '\n')
  [ "$(printf '%s\n' "$allow" | sort | tr '\n' ' ')" = "Glob Grep Read " ] || echo "allow list is not exactly Read, Glob, Grep"
  for t in $REQUIRED_DENY; do
    printf '%s\n' "$deny" | grep -qxF -- "$t" || echo "deny list lacks $t"
  done
  for t in $allow; do
    ! printf '%s\n' "$deny" | grep -qxF -- "$t" || echo "$t is both allowed and denied"
  done
}

# Default: no model, no directories. Both tool lists are asserted exactly.
out=$(env -u REVIEW_HEAD_DIR -u REVIEW_INPUT_DIR AGENT_TURNS_REVIEW=60 AGENT_MODEL_REVIEW='' bash "$R")
assert_contains "$out" "AGENT_ARGS_REVIEW=--setting-sources user --max-turns 60 --allowedTools " "default review args shape"
assert_eq "1" "$(printf '%s\n' "$out" | grep -c .)" "exactly one env line"
case "$out" in *"--model"*) echo "FAIL: an empty model still emitted --model" >&2; exit 1 ;; esac
case "$out" in *"--add-dir"*) echo "FAIL: unset directories still emitted --add-dir" >&2; exit 1 ;; esac

# Both lists, checked by whole token.
problems=$(check_tool_lists "$out")
assert_eq "" "$problems" "allow list is exactly Read,Glob,Grep; every deny name is a whole token; no overlap"

# The check can fail: crafted lines with an emptied deny list, a missing name
# that only substring matching would find, and an allowed tool also denied.
bad=$(check_tool_lists "x --allowedTools Read,Glob,Grep --disallowedTools ")
[ -n "$bad" ] || { echo "FAIL: an emptied deny list passed the check" >&2; exit 1; }
bad=$(check_tool_lists "x --allowedTools Read,Glob,Grep --disallowedTools Agent,Task,ListAgents,ScheduleWakeup,SendMessage,Monitor,CronCreate,Bash,Edit,Write,NotebookEdit,WebFetch,WebSearch,Skill,TaskCreate,MultiEdit,Extra")
assert_eq "" "$bad" "a complete deny list in another order passes"
bad=$(check_tool_lists "x --allowedTools Read,Glob,Grep --disallowedTools ListAgents,TaskCreate,MultiEdit,ScheduleWakeup,SendMessage,Monitor,CronCreate,Bash,Write,NotebookEdit,WebFetch,WebSearch,Skill")
case "$bad" in *"lacks Agent"*"lacks Task"*"lacks Edit"*) ;; *) echo "FAIL: substring-only matches passed the check" >&2; exit 1 ;; esac
bad=$(check_tool_lists "x --allowedTools Read,Glob,Grep,Bash --disallowedTools $(echo $REQUIRED_DENY | tr ' ' ',')")
[ -n "$bad" ] || { echo "FAIL: an extra allowed tool passed the check" >&2; exit 1; }

# A pinned model appears once.
out=$(AGENT_MODEL_REVIEW=claude-opus-5 AGENT_TURNS_REVIEW=60 bash "$R")
assert_contains "$out" "AGENT_ARGS_REVIEW=--setting-sources user --model claude-opus-5 --max-turns 60" \
  "the pinned model lands in the args"
assert_eq "1" "$(printf '%s' "$out" | grep -c -- '--model')" "the flag appears once"

# Only the head directory.
out=$(env -u REVIEW_INPUT_DIR REVIEW_HEAD_DIR=/tmp/head bash "$R")
assert_contains "$out" '--add-dir "/tmp/head" --max-turns' "head dir only, before --max-turns"
assert_eq "1" "$(printf '%s' "$out" | grep -o -- '--add-dir' | wc -l)" "one --add-dir"

# Only the input directory.
out=$(env -u REVIEW_HEAD_DIR REVIEW_INPUT_DIR=/tmp/input bash "$R")
assert_contains "$out" '--add-dir "/tmp/input" --max-turns' "input dir only, before --max-turns"
assert_eq "1" "$(printf '%s' "$out" | grep -o -- '--add-dir' | wc -l)" "one --add-dir"

# Both, in order, each followed by a flag and never by a bare word.
out=$(REVIEW_HEAD_DIR=/tmp/head REVIEW_INPUT_DIR=/tmp/input bash "$R")
assert_contains "$out" '--add-dir "/tmp/head" --add-dir "/tmp/input" --max-turns' "both dirs, before --max-turns"
assert_eq "2" "$(printf '%s' "$out" | grep -o -- '--add-dir' | wc -l)" "two --add-dir"

# Empty-string variables count as unset.
out=$(REVIEW_HEAD_DIR='' REVIEW_INPUT_DIR='' bash "$R")
case "$out" in *"--add-dir"*) echo "FAIL: empty directories emitted --add-dir" >&2; exit 1 ;; esac

# No --add-dir swallows the next flag: each is followed by exactly one quoted
# value and then another flag.
for setup in "REVIEW_HEAD_DIR=/a" "REVIEW_INPUT_DIR=/b" "REVIEW_HEAD_DIR=/a REVIEW_INPUT_DIR=/b"; do
  out=$(env $setup bash "$R")
  assert_eq "0" "$(printf '%s\n' "$out" | grep -cE -- '--add-dir "[^"]*" [^-]')" \
    "an --add-dir value is followed by a flag ($setup)"
done

# The deny list is one comma-separated argument, so it cannot swallow what follows.
assert_eq "0" "$(printf '%s\n' "$out" | grep -c 'disallowedTools [^ ]* [^-]')" \
  "the deny list is one comma-separated argument"
pass
