#!/usr/bin/env bash
# The --claude_args string for each phase, as KEY=VALUE lines for $GITHUB_ENV.
#
# This is shell rather than a GitHub expression on purpose. The conditional
# model flag can be written as
#
#   ${{ env.AGENT_MODEL_FIX && format('--model {0} ', env.AGENT_MODEL_FIX) || '' }}
#
# and that form can only be verified by GitHub's own evaluator. act could not
# run it on this machine, and shipping an expression whose truthiness rules were
# reasoned about rather than executed is how a flag silently reaches every phase
# or none. Here the logic is testable, and compose-agent-args.test.sh tests it.
#
# It also puts the argument string in ONE place. It was five literals, and a
# flag added to four of them and missed on the fifth is invisible until a run
# behaves differently in one phase.
#
# Usage: compose-agent-args.sh            (reads AGENT_* from the environment)
set -uo pipefail

# Per phase, because the phases do different work. Review has no Edit or Write:
# a reviewer that can change the diff it is reviewing is not a reviewer.
TOOLS_WRITE="Bash,Read,Glob,Grep,Edit,Write,Skill,mcp__wp-devdocs"
TOOLS_READ="Bash,Read,Glob,Grep,Skill"

# --setting-sources user on every phase. Each agent step is a fresh session that
# would otherwise read .claude/settings.json out of the checkout, which a
# previous phase can have committed to.
BASE="--setting-sources user"

# `--model X ` with a trailing space, or nothing at all. Empty means the action's
# default, which is what every run so far used.
model_flag() { # env-value
  [ -n "${1:-}" ] || return 0
  printf -- '--model %s ' "$1"
}

# Tools that assume a human or a live session, denied on every phase.
#
# Run 33679825065 is why. The reproduce agent spawned two subagents, called
# ScheduleWakeup, and ended its turn with "Both exploration agents are still
# investigating. I'll pause here and wait for their completion notifications
# before proceeding." Nothing in a workflow_dispatch run delivers such a
# notification, so it parked: 25 turns, $1.08, no commit, no report, and the
# action exited is_error:false so the step reported success.
#
# --allowedTools alone did not prevent it. That list named Bash, Read, Glob,
# Grep, Edit, Write, Skill and mcp__wp-devdocs, and the agent used Agent,
# ListAgents and ScheduleWakeup anyway, so these have to be denied by name.
#
# Verified before being relied on. Every name here is one the CLI recognises: it
# warns "matches no known tool" for a typo and warned for none of these. And the
# mechanism was canaried both directions on Bash, which is the only tool cheap
# enough to test destructively: allowed, the command ran and printed its output;
# denied, the tool was genuinely absent and the model said so rather than
# inventing the result. --disallowedTools also wins over --allowedTools for the
# same name.
NO_HUMAN="Agent,Task,ListAgents,ScheduleWakeup,SendMessage,Monitor,TaskCreate,CronCreate"

args() { # model turns tools
  printf '%s %s--max-turns %s --allowedTools %s --disallowedTools %s' \
    "$BASE" "$(model_flag "$1")" "$2" "$3" "$NO_HUMAN"
}

printf 'AGENT_ARGS_REPRODUCE=%s\n' \
  "$(args "${AGENT_MODEL_REPRODUCE:-}" "${AGENT_TURNS_REPRODUCE:-80}" "$TOOLS_WRITE")"
printf 'AGENT_ARGS_FIX=%s\n' \
  "$(args "${AGENT_MODEL_FIX:-}" "${AGENT_TURNS_FIX:-90}" "$TOOLS_WRITE")"
printf 'AGENT_ARGS_REVIEW=%s\n' \
  "$(args "${AGENT_MODEL_REVIEW:-}" "${AGENT_TURNS_REVIEW:-60}" "$TOOLS_READ")"
