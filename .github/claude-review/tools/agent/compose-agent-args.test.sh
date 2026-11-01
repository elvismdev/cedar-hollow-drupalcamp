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

# ---------------------------------------------------------------------------
# The security audit's variables (--audit) and models (--audit-models). The
# checks above, which require Agent and Task denied, apply to the review
# variable only: every audit step but repair delegates to subagents.
# Rule lists hold * and are split on commas below, so no pathname expansion.
set -f
PARSE="$ROOT/tools/agent/test/helpers/parse-claude-args.py"
PARSE_ENV="$ROOT/tools/agent/test/helpers/parse-env-file.py"
RUNNER_ENV=(HOME=/home/runner RUNNER_TEMP=/home/runner/work/_temp GITHUB_WORKSPACE=/home/runner/work/ddemo/ddemo)
# The audit deny list: the review's NO_HUMAN and NO_WRITE names, read from the
# script, without the tools the audit agents use, then the audit-only names
# from Stage 0's tool list and the Technical Plan.
AUDIT_ONLY="CronDelete,CronList,TaskStop,TodoWrite,AskUserQuestion,EnterPlanMode,ExitPlanMode,EnterWorktree,ExitWorktree,ToolSearch,DesignSync,PushNotification,RemoteTrigger,ReportFindings,Workflow"
NO_HUMAN=$(sed -n 's/^NO_HUMAN="\(.*\)"$/\1/p' "$R")
NO_WRITE=$(sed -n 's/^NO_WRITE="\(.*\)"$/\1/p' "$R")
[ -n "$NO_HUMAN" ] && [ -n "$NO_WRITE" ] || { echo "FAIL: NO_HUMAN or NO_WRITE could not be read from the script" >&2; exit 1; }
AUDIT_DENY="$(printf '%s\n' "${NO_HUMAN//,/$'\n'}" "${NO_WRITE//,/$'\n'}" | grep -vxE 'Agent|Task|Write|Edit' | paste -sd, -),$AUDIT_ONLY"
PATH_RULES="Read(//proc/**),Glob(//proc/**),Grep(//proc/**),Edit(//proc/**),Read(//sys/**),Glob(//sys/**),Grep(//sys/**),Edit(//sys/**),Read(//home/runner/work/_temp/**),Glob(//home/runner/work/_temp/**),Grep(//home/runner/work/_temp/**),Edit(//home/runner/work/_temp/**),Read(//home/runner/work/_actions/**),Glob(//home/runner/work/_actions/**),Grep(//home/runner/work/_actions/**),Edit(//home/runner/work/_actions/**),Read(//home/runner/runners/**),Glob(//home/runner/runners/**),Grep(//home/runner/runners/**),Edit(//home/runner/runners/**),Read(//home/runner/.*),Glob(//home/runner/.*),Grep(//home/runner/.*),Edit(//home/runner/.*),Read(//home/runner/.*/**),Glob(//home/runner/.*/**),Grep(//home/runner/.*/**),Edit(//home/runner/.*/**),Read(//home/runner/work/ddemo/ddemo/.git/**),Glob(//home/runner/work/ddemo/ddemo/.git/**),Grep(//home/runner/work/ddemo/ddemo/.git/**),Read(//proc),Glob(//proc),Grep(//proc),Read(//sys),Glob(//sys),Grep(//sys),Read(//home/runner/work/_temp),Glob(//home/runner/work/_temp),Grep(//home/runner/work/_temp),Read(//home/runner/work/_actions),Glob(//home/runner/work/_actions),Grep(//home/runner/work/_actions),Read(//home/runner/runners),Glob(//home/runner/runners),Grep(//home/runner/runners),Read(//home/runner/work/ddemo/ddemo/.git),Glob(//home/runner/work/ddemo/ddemo/.git),Grep(//home/runner/work/ddemo/ddemo/.git),Edit(//home/runner/work/ddemo/ddemo/**)"

# The exact line for one step, quoting included.
expected_audit() { # name model job turns subagents(yes|no)
  local allow="Read,Glob,Grep" deny="$AUDIT_DENY"
  if [ "$5" = yes ]; then allow="$allow,Agent,Task"; else deny="$deny,Agent,Task"; fi
  printf "%s=--setting-sources user --strict-mcp-config --model %s --add-dir \"/mnt/audit/%s/in\" --add-dir \"/mnt/audit/%s/out\" --max-turns %s --allowedTools '%s,Edit(//mnt/audit/%s/out/**)' --disallowedTools '%s,%s'" \
    "$1" "$2" "$3" "$3" "$4" "$allow" "$3" "$deny" "$PATH_RULES"
}

audit=$(env "${RUNNER_ENV[@]}" bash "$R" --audit)
assert_exit 0 $? "--audit composes"
assert_eq "AGENT_ARGS_AUDIT_SOURCE AGENT_ARGS_AUDIT_REPAIR AGENT_ARGS_AUDIT_POC_WRITE AGENT_ARGS_AUDIT_POC_DECIDE AGENT_ARGS_AUDIT_CROSS_CHECK AGENT_ARGS_AUDIT_TIE_BREAK " \
  "$(printf '%s\n' "$audit" | cut -d= -f1 | tr '\n' ' ')" "--audit prints the six variables in order"

audit_line() { printf '%s\n' "$audit" | grep "^$1="; }
for spec in "AGENT_ARGS_AUDIT_SOURCE claude-opus-5-5 source 400 yes" \
            "AGENT_ARGS_AUDIT_REPAIR claude-opus-5-5 source 40 no" \
            "AGENT_ARGS_AUDIT_POC_WRITE claude-opus-5-5 poc-write 120 yes" \
            "AGENT_ARGS_AUDIT_POC_DECIDE claude-opus-5-5 poc-decide 80 yes" \
            "AGENT_ARGS_AUDIT_CROSS_CHECK claude-fable-5-1 cross-check 150 yes" \
            "AGENT_ARGS_AUDIT_TIE_BREAK claude-sonnet-5-5 cross-check 40 yes"; do
  # shellcheck disable=SC2086
  set -- $spec
  name=$1 model=$2 job=$3 turns=$4 subs=$5
  line=$(audit_line "$name")
  assert_eq "$(expected_audit "$name" "$model" "$job" "$turns" "$subs")" "$line" "$name is exactly the expected string"

  # Parsed the way claude-code-action parses claude_args.
  parsed=$(python3 -I "$PARSE" "${line#*=}")
  got=$(printf '%s' "$parsed" | python3 -I -c '
import json, sys
p = json.load(sys.stdin)
f = p["flags"]
print(f.get("model"), f.get("max-turns"), f.get("setting-sources"), "strict-mcp-config" in f and f["strict-mcp-config"] is None,
      "|".join(p["addDirs"]), sorted(f))')
  assert_eq "$model $turns user True /mnt/audit/$job/in|/mnt/audit/$job/out ['max-turns', 'model', 'setting-sources', 'strict-mcp-config']" \
    "$got" "$name parses to its model, turns, settings, MCP flag and two directories, no --add-dir swallowing a flag"

  allow=$(printf '%s' "$parsed" | python3 -I -c 'import json,sys; print(",".join(json.load(sys.stdin)["allowedTools"]))')
  deny=$(printf '%s' "$parsed" | python3 -I -c 'import json,sys; print(",".join(json.load(sys.stdin)["disallowedTools"]))')
  want_allow="Read,Glob,Grep"
  [ "$subs" = yes ] && want_allow="$want_allow,Agent,Task"
  assert_eq "$want_allow,Edit(//mnt/audit/$job/out/**)" "$allow" "$name allows exactly its tools and its output directory"
  for t in ${NO_HUMAN//,/ } ${NO_WRITE//,/ }; do
    case "$t" in Agent|Task|Write|Edit) continue ;; esac
    printf '%s\n' "${deny//,/$'\n'}" | grep -qxF -- "$t" || { echo "FAIL: $name does not deny the review's $t" >&2; exit 1; }
  done
  for t in ${AUDIT_DENY//,/ }; do
    printf '%s\n' "${deny//,/$'\n'}" | grep -qxF -- "$t" || { echo "FAIL: $name does not deny $t" >&2; exit 1; }
  done
  for t in Read Glob Grep Write Edit; do
    ! printf '%s\n' "${deny//,/$'\n'}" | grep -qxF -- "$t" || { echo "FAIL: $name denies $t by name" >&2; exit 1; }
  done
  for r in ${PATH_RULES//,/ }; do
    printf '%s\n' "${deny//,/$'\n'}" | grep -qxF -- "$r" || { echo "FAIL: $name lacks the rule $r after parsing" >&2; exit 1; }
  done
  # Only repair denies the subagent tool, under both of its names.
  for t in Agent Task; do
    if printf '%s\n' "${deny//,/$'\n'}" | grep -qxF -- "$t"; then denied=yes; else denied=no; fi
    if [ "$subs" = yes ]; then want=no; else want=yes; fi
    assert_eq "$want" "$denied" "$name denies $t only if it is the repair step"
  done
  # No --add-dir is followed by a bare word.
  assert_eq "0" "$(printf '%s\n' "$line" | grep -cE -- '--add-dir "[^"]*" [^-]')" "$name: each --add-dir is followed by a flag"
done

# The parser itself: an unquoted rule list loses the words after a space,
# and a bare word after --add-dir is swallowed as a directory.
parsed=$(python3 -I "$PARSE" "--add-dir /a stray --max-turns 3 --allowedTools 'Read,Edit(//x/**)'")
assert_eq '["/a", "stray"]' "$(printf '%s' "$parsed" | python3 -I -c 'import json,sys; print(json.dumps(json.load(sys.stdin)["addDirs"]))')" \
  "the parser shows a bare word swallowed by --add-dir"
assert_eq '["Read", "Edit(//x/**)"]' "$(printf '%s' "$parsed" | python3 -I -c 'import json,sys; print(json.dumps(json.load(sys.stdin)["allowedTools"]))')" \
  "the parser keeps a quoted rule whole"
# A flag seen bare and later with values takes those values, as the action
# does, instead of failing on the bare one.
parsed=$(python3 -I "$PARSE" "--allowedTools --model m --allowedTools 'Read,Glob' --add-dir --max-turns 2 --add-dir /a")
assert_exit 0 $? "the parser accepts a bare flag repeated with values"
assert_eq '["Read", "Glob"] ["/a"]' "$(printf '%s' "$parsed" | python3 -I -c 'import json,sys; p=json.load(sys.stdin); print(json.dumps(p["allowedTools"]), json.dumps(p["addDirs"]))')" \
  "a bare flag repeated with values keeps the values"

# Fails closed on a runner path that is unset, relative, would end the
# quoting, or ends in or doubles a slash (which would shift the _actions rule).
for bad in "HOME=" "HOME=home/runner" "RUNNER_TEMP=/home/runner/work/_te'mp" "GITHUB_WORKSPACE=/home/runner/work/a b" \
           "GITHUB_WORKSPACE=/home/runner/work/../x" "RUNNER_TEMP=/" "RUNNER_TEMP=/home/runner/work/_temp/" \
           "HOME=/home//runner" "GITHUB_WORKSPACE=/home/runner/work/ddemo/ddemo/"; do
  out=$(env "${RUNNER_ENV[@]}" "$bad" bash "$R" --audit 2>/dev/null)
  rc=$?
  assert_exit 1 "$rc" "--audit refuses $bad"
  assert_eq "" "$out" "--audit prints nothing for $bad"
done
out=$(env -u RUNNER_TEMP HOME=/home/runner GITHUB_WORKSPACE=/w bash "$R" --audit 2>/dev/null)
assert_exit 1 $? "--audit refuses an unset RUNNER_TEMP"

# --audit-models: the step's model three times, read as the runner reads $GITHUB_ENV.
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
for spec in "source claude-opus-5-5" "repair claude-opus-5-5" "poc_write claude-opus-5-5" \
            "poc_decide claude-opus-5-5" "cross_check claude-fable-5-1" "tie_break claude-sonnet-5-5"; do
  # shellcheck disable=SC2086
  set -- $spec
  bash "$R" --audit-models "$1" > "$tmp/env"
  assert_exit 0 $? "--audit-models $1"
  assert_eq "{\"ANTHROPIC_DEFAULT_SONNET_MODEL\": \"$2\", \"ANTHROPIC_DEFAULT_HAIKU_MODEL\": \"$2\", \"CLAUDE_CODE_SUBAGENT_MODEL\": \"$2\"}" \
    "$(python3 -I "$PARSE_ENV" "$tmp/env")" "--audit-models $1 sets the three model variables to $2"
done
bash "$R" --audit-models nope >/dev/null 2>&1
assert_exit 2 $? "--audit-models refuses an unknown step"
bash "$R" --audit-models >/dev/null 2>&1
assert_exit 2 $? "--audit-models needs a step"
bash "$R" --bogus >/dev/null 2>&1
assert_exit 2 $? "an unknown option is refused"
pass
