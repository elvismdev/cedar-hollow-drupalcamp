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
#        compose-agent-args.sh --audit | --audit-models <step>   (the security audit's steps, below)
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

# ---------------------------------------------------------------------------
# The security audit's agent steps (.github/security-audit). They read, write
# their own output directory and, except the repair step, delegate to
# subagents, so they get their own lists:
#
#   compose-agent-args.sh --audit                prints the six AGENT_ARGS_AUDIT_* lines
#   compose-agent-args.sh --audit-models <step>  prints that step's three model lines
#
# --audit reads HOME, RUNNER_TEMP and GITHUB_WORKSPACE to write the runner's
# paths into the deny rules, and prints nothing (exit 1) when one is unset,
# relative, ends in or doubles a slash, or holds a character outside
# [A-Za-z0-9._/-], since every rule list is single-quoted and a path must not
# end that quoting.
#
# Measured in the audit's Stage 0 spike (Claude Code 2.1.316, -p):
#   - the subagent tool is listed as Task and its calls appear as Agent, so
#     neither name is in AUDIT_DENY and both are allowed;
#   - an Edit(//...) allow rule permits Write, a Write(//...) rule permits no
#     write, and denying Edit by name blocks Write: so the write allow rule
#     and the write path denials are Edit rules, and Edit is never denied by
#     name;
#   - a leading // marks an absolute path in a rule, and a deny rule beats an
#     allow rule.

AUDIT_ROOT="/mnt/audit"

# The session's tools other than Read, Glob, Grep, Write, Edit and the
# subagent tool: the review's NO_HUMAN and NO_WRITE lists without the tools
# the audit agents use, plus the rest of Stage 0's recorded tool list and the
# names the Technical Plan denies that this version did not list (TodoWrite,
# AskUserQuestion, EnterPlanMode, ExitPlanMode), kept so a version that brings
# one back still has it denied.
AUDIT_ONLY="CronDelete,CronList,TaskStop,TodoWrite,AskUserQuestion,EnterPlanMode,ExitPlanMode,EnterWorktree,ExitWorktree,ToolSearch,DesignSync,PushNotification,RemoteTrigger,ReportFindings,Workflow"
AUDIT_DENY="$(printf '%s\n' "${NO_HUMAN//,/$'\n'}" "${NO_WRITE//,/$'\n'}" | grep -vxE 'Agent|Task|Write|Edit' | paste -sd, -),$AUDIT_ONLY"

# step  job  model  max-turns  subagents
AUDIT_STEPS="source source claude-opus-5-5 400 yes
repair source claude-opus-5-5 40 no
poc_write poc-write claude-opus-5-5 120 yes
poc_decide poc-decide claude-opus-5-5 80 yes
cross_check cross-check claude-fable-5-1 150 yes
tie_break cross-check claude-sonnet-5-5 40 yes"

audit_step() { # step ; prints "job model turns subagents", fails for an unknown step
  printf '%s\n' "$AUDIT_STEPS" | awk -v s="$1" '$1 == s { print $2, $3, $4, $5; found = 1 } END { exit !found }'
}

audit_path_ok() { # value
  case "$1" in /*) ;; *) return 1 ;; esac
  [ "$1" != "/" ] || return 1
  printf '%s' "$1" | grep -qE '^[A-Za-z0-9._/-]+$' || return 1
  case "/$1/" in */../*|*/./*) return 1 ;; esac
  # A trailing or doubled slash would shift a derived path: ${RUNNER_TEMP%/*}
  # of /home/runner/work/_temp/ is _temp itself, not its parent.
  case "$1" in */|*//*) return 1 ;; esac
}

# One rule per tool for each denied root. $1 is the tools, the rest the
# absolute paths (each starting with /, so "/" plus it is the // form).
audit_rules() { # tools path...
  local tools="$1" t p out=""
  shift
  for p in "$@"; do
    for t in $tools; do out="$out,$t(/$p)"; done
  done
  printf '%s' "${out#,}"
}

audit_args() { # step
  local spec job model turns subagents in out allow deny work
  spec=$(audit_step "$1") || return 1
  read -r job model turns subagents <<<"$spec"
  in="$AUDIT_ROOT/$job/in"
  out="$AUDIT_ROOT/$job/out"
  work="${RUNNER_TEMP%/*}"
  # The roots no agent reads or writes: the kernel's views of processes and
  # devices, the runner's temporary, actions and runner directories, and
  # every dot-file and dot-directory in the runner's home.
  local roots=('/proc/**' '/sys/**' "$RUNNER_TEMP/**" "$work/_actions/**" "$HOME/runners/**" "$HOME/.*" "$HOME/.*/**")
  deny="$AUDIT_DENY"
  allow="Read,Glob,Grep"
  if [ "$subagents" = yes ]; then
    allow="$allow,Agent,Task"
  else
    deny="$deny,Agent,Task"
  fi
  allow="$allow,Edit(/$out/**)"
  deny="$deny,$(audit_rules "Read Glob Grep Edit" "${roots[@]}")"
  deny="$deny,$(audit_rules "Read Glob Grep" "$GITHUB_WORKSPACE/.git/**")"
  # Each denied directory as itself too, so a Glob or Grep given the folder
  # as its path is refused rather than left to whether X/** matches X.
  deny="$deny,$(audit_rules "Read Glob Grep" /proc /sys "$RUNNER_TEMP" "$work/_actions" "$HOME/runners" "$GITHUB_WORKSPACE/.git")"
  deny="$deny,$(audit_rules "Edit" "$GITHUB_WORKSPACE/**")"
  printf "%s --strict-mcp-config %s%s%s--max-turns %s --allowedTools '%s' --disallowedTools '%s'" \
    "$BASE" "$(model_flag "$model")" "$(dir_flag "$in")" "$(dir_flag "$out")" "$turns" "$allow" "$deny"
}

if [ "${1:-}" = "--audit-models" ]; then
  [ "$#" -eq 2 ] || { echo "usage: compose-agent-args.sh --audit-models <step>" >&2; exit 2; }
  if ! spec=$(audit_step "$2"); then
    echo "compose-agent-args: unknown audit step" >&2
    exit 2
  fi
  read -r _ model _ _ <<<"$spec"
  printf 'ANTHROPIC_DEFAULT_SONNET_MODEL=%s\nANTHROPIC_DEFAULT_HAIKU_MODEL=%s\nCLAUDE_CODE_SUBAGENT_MODEL=%s\n' \
    "$model" "$model" "$model"
  exit 0
fi

if [ "${1:-}" = "--audit" ]; then
  [ "$#" -eq 1 ] || { echo "usage: compose-agent-args.sh --audit" >&2; exit 2; }
  for v in HOME RUNNER_TEMP GITHUB_WORKSPACE; do
    if ! audit_path_ok "${!v:-}"; then
      echo "compose-agent-args: $v must be an absolute path of [A-Za-z0-9._/-] with no . or .. segment and no trailing or doubled slash" >&2
      exit 1
    fi
  done
  lines=""
  for step in source repair poc_write poc_decide cross_check tie_break; do
    line=$(audit_args "$step") || { echo "compose-agent-args: could not compose $step" >&2; exit 1; }
    name="AGENT_ARGS_AUDIT_$(printf '%s' "$step" | tr '[:lower:]' '[:upper:]')"
    lines="$lines$name=$line"$'\n'
  done
  printf '%s' "$lines"
  exit 0
fi

[ "$#" -eq 0 ] || { echo "usage: compose-agent-args.sh [--audit | --audit-models <step>]" >&2; exit 2; }

printf 'AGENT_ARGS_REVIEW=%s\n' \
  "$(args "${AGENT_MODEL_REVIEW:-}" "${AGENT_TURNS_REVIEW:-60}" "$TOOLS_READ")"
