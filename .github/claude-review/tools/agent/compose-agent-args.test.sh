#!/usr/bin/env bash
set -uo pipefail
ROOT="$(git rev-parse --show-toplevel)/.github/claude-review"
. "$ROOT/tools/agent/test/assert.sh"
R="$ROOT/tools/agent/compose-agent-args.sh"
NO_HUMAN="Agent,Task,ListAgents,ScheduleWakeup,SendMessage,Monitor,TaskCreate,CronCreate"
NO_WRITE="Bash,Edit,Write,MultiEdit,NotebookEdit,WebFetch,WebSearch,Skill"

# Default: no model, no directories. Both tool lists are asserted exactly.
out=$(env -u REVIEW_HEAD_DIR -u REVIEW_INPUT_DIR AGENT_TURNS_REVIEW=60 AGENT_MODEL_REVIEW='' bash "$R")
assert_eq "AGENT_ARGS_REVIEW=--setting-sources user --max-turns 60 --allowedTools Read,Glob,Grep --disallowedTools $NO_HUMAN,$NO_WRITE" \
  "$out" "default review args: allow list and deny list"
assert_eq "1" "$(printf '%s\n' "$out" | grep -c .)" "exactly one env line"
case "$out" in *"--model"*) echo "FAIL: an empty model still emitted --model" >&2; exit 1 ;; esac
case "$out" in *"--add-dir"*) echo "FAIL: unset directories still emitted --add-dir" >&2; exit 1 ;; esac

# The allow list has no command or write tool, and the deny list covers them.
allow=$(printf '%s' "$out" | sed -E 's/.*--allowedTools ([^ ]*) .*/\1/')
assert_eq "Read,Glob,Grep" "$allow" "the allow list is read-only"
for t in Bash Edit Write MultiEdit NotebookEdit WebFetch WebSearch Skill Agent Task ListAgents ScheduleWakeup; do
  assert_contains "$out" "$t" "the deny list names $t"
done

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
