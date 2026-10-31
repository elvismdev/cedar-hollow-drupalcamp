#!/usr/bin/env bash
# The --claude_args string for the review phase, as KEY=VALUE lines for $GITHUB_ENV.
#
# This is shell rather than a GitHub expression on purpose. The conditional
# model flag can be written as
#
#   ${{ env.AGENT_MODEL_REVIEW && format('--model {0} ', env.AGENT_MODEL_REVIEW) || '' }}
#
# and that form can only be verified by GitHub's own evaluator. act could not
# run it on this machine, and shipping an expression whose truthiness rules were
# reasoned about rather than executed is how a flag silently reaches the run
# or not. Here the logic is testable, and compose-agent-args.test.sh tests it.
#
# It also puts the argument string in ONE place.
#
# Usage: compose-agent-args.sh            (reads AGENT_* and REVIEW_*_DIR from the environment)
set -uo pipefail

# The review agent reads and searches; it never runs commands or edits. A
# reviewer that can change the diff it is reviewing is not a reviewer.
TOOLS_READ="Read,Glob,Grep"

# --setting-sources user. The agent step is a fresh session that would
# otherwise read .claude/settings.json out of the checkout under review.
BASE="--setting-sources user"

# `--model X ` with a trailing space, or nothing at all. Empty means the action's
# default, which is what every run so far used.
model_flag() { # env-value
  [ -n "${1:-}" ] || return 0
  printf -- '--model %s ' "$1"
}

# Tools that assume a human or a live session, denied by name. An agent in a
# workflow run that spawns subagents or schedules a wakeup waits for
# notifications nothing delivers, and the step still reports success.
# --allowedTools alone does not prevent this, so these are denied explicitly.
# --disallowedTools wins over --allowedTools for the same name.
NO_HUMAN="Agent,Task,ListAgents,ScheduleWakeup,SendMessage,Monitor,TaskCreate,CronCreate"

# Tools the review must not have at all, whatever else is configured.
NO_WRITE="Bash,Edit,Write,MultiEdit,NotebookEdit,WebFetch,WebSearch,Skill"

# --add-dir values are quoted single arguments, emitted only when the variable
# is set and placed before --max-turns. --add-dir is variadic, so a following
# flag is only safe because exactly one directory precedes it.
dir_flag() { # env-value
  [ -n "${1:-}" ] || return 0
  printf -- '--add-dir "%s" ' "$1"
}

args() { # model turns tools
  printf '%s %s%s%s--max-turns %s --allowedTools %s --disallowedTools %s,%s' \
    "$BASE" "$(model_flag "$1")" "$(dir_flag "${REVIEW_HEAD_DIR:-}")" \
    "$(dir_flag "${REVIEW_INPUT_DIR:-}")" "$2" "$3" "$NO_HUMAN" "$NO_WRITE"
}

printf 'AGENT_ARGS_REVIEW=%s\n' \
  "$(args "${AGENT_MODEL_REVIEW:-}" "${AGENT_TURNS_REVIEW:-60}" "$TOOLS_READ")"
