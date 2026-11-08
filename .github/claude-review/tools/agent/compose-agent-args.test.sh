#!/usr/bin/env bash
set -uo pipefail
ROOT="$(git rev-parse --show-toplevel)/.github/claude-review"
. "$ROOT/tools/agent/test/assert.sh"
R="$ROOT/tools/agent/compose-agent-args.sh"
REQUIRED_DENY="Agent Task ListAgents ScheduleWakeup SendMessage Monitor TaskCreate CronCreate Bash Edit Write MultiEdit NotebookEdit WebFetch WebSearch Skill"
# Rule lists hold * and are split on commas below, so no pathname expansion.
set -f
tmp_err=$(mktemp)
trap 'rm -f "$tmp_err"' EXIT
PARSE="$ROOT/tools/agent/test/helpers/parse-claude-args.py"
# Every review and audit line is composed with the runner's paths, which the
# deny rules are written from.
RUNNER_ENV=(HOME=/home/runner RUNNER_TEMP=/home/runner/work/_temp GITHUB_WORKSPACE=/home/runner/work/ddemo/ddemo)
# The review's path rules for RUNNER_ENV, written out: each root as itself and
# everything under it, for Read, Glob and Grep.
REVIEW_RULES="Read(//proc),Glob(//proc),Grep(//proc),Read(//proc/**),Glob(//proc/**),Grep(//proc/**),Read(//sys),Glob(//sys),Grep(//sys),Read(//sys/**),Glob(//sys/**),Grep(//sys/**),Read(//home/runner/work/ddemo/ddemo/.git),Glob(//home/runner/work/ddemo/ddemo/.git),Grep(//home/runner/work/ddemo/ddemo/.git),Read(//home/runner/work/ddemo/ddemo/.git/**),Glob(//home/runner/work/ddemo/ddemo/.git/**),Grep(//home/runner/work/ddemo/ddemo/.git/**),Read(//home/runner/.*),Glob(//home/runner/.*),Grep(//home/runner/.*),Read(//home/runner/.*/**),Glob(//home/runner/.*/**),Grep(//home/runner/.*/**),Read(//home/runner/work/_actions),Glob(//home/runner/work/_actions),Grep(//home/runner/work/_actions),Read(//home/runner/work/_actions/**),Glob(//home/runner/work/_actions/**),Grep(//home/runner/work/_actions/**),Read(//home/runner/runners),Glob(//home/runner/runners),Grep(//home/runner/runners),Read(//home/runner/runners/**),Glob(//home/runner/runners/**),Grep(//home/runner/runners/**),Read(//home/runner/actions-runner),Glob(//home/runner/actions-runner),Grep(//home/runner/actions-runner),Read(//home/runner/actions-runner/**),Glob(//home/runner/actions-runner/**),Grep(//home/runner/actions-runner/**)"

# The comma-separated value that follows a flag in an args line, without the
# single quotes around a rule list.
flag_value() { # line flag
  printf '%s\n' "$1" | sed -nE "s/.* $2 '?([^ ']*)'?( .*)?\$/\1/p"
}

# Whole-token checks on the allow and deny lists. Substring matching would let
# Task pass on TaskCreate, Agent on ListAgents and Edit on MultiEdit.
check_tool_lists() { # line ; prints a failure per line, nothing when sound
  local allow deny t
  allow=$(flag_value "$1" --allowedTools | tr ',' '\n')
  deny=$(flag_value "$1" --disallowedTools | tr ',' '\n')
  [ "$(printf '%s\n' "$allow" | sort | tr '\n' ' ')" = "Glob Grep Read " ] || echo "allow list is not exactly Read, Glob, Grep"
  for t in $REQUIRED_DENY; do
    grep -qxF -- "$t" <<<"$deny" || echo "deny list lacks $t"
  done
  for t in $allow; do
    ! grep -qxF -- "$t" <<<"$deny" || echo "$t is both allowed and denied"
  done
}

# Default: no model, no directories. Both tool lists are asserted exactly.
out=$(env -u REVIEW_HEAD_DIR -u REVIEW_INPUT_DIR "${RUNNER_ENV[@]}" AGENT_TURNS_REVIEW=60 AGENT_MODEL_REVIEW='' bash "$R")
assert_contains "$out" "AGENT_ARGS_REVIEW=--setting-sources user --strict-mcp-config --max-turns 60 --allowedTools " "default review args shape"
assert_eq "1" "$(printf '%s\n' "$out" | grep -c .)" "exactly one env line"
case "$out" in *"--model"*) echo "FAIL: an empty model still emitted --model" >&2; exit 1 ;; esac
case "$out" in *"--add-dir"*) echo "FAIL: unset directories still emitted --add-dir" >&2; exit 1 ;; esac

# The review, its verifiers and the eval run in a tree that can hold a
# .mcp.json, so no project MCP server may start: the flag is one whole token,
# present once, in every composed variant (default, model, directories).
for setup in "AGENT_MODEL_REVIEW=" "AGENT_MODEL_REVIEW=claude-opus-5" "REVIEW_HEAD_DIR=/a REVIEW_INPUT_DIR=/b"; do
  o=$(env "${RUNNER_ENV[@]}" $setup bash "$R")
  assert_eq "1" "$(printf '%s\n' "$o" | tr ' ' '\n' | grep -cxF -- --strict-mcp-config)" \
    "the review line holds --strict-mcp-config once ($setup)"
done

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
out=$(env "${RUNNER_ENV[@]}" AGENT_MODEL_REVIEW=claude-opus-5 AGENT_TURNS_REVIEW=60 bash "$R")
assert_contains "$out" "AGENT_ARGS_REVIEW=--setting-sources user --strict-mcp-config --model claude-opus-5 --max-turns 60" \
  "the pinned model lands in the args"
assert_eq "1" "$(printf '%s' "$out" | grep -c -- '--model')" "the flag appears once"

# Only the head directory.
out=$(env -u REVIEW_INPUT_DIR "${RUNNER_ENV[@]}" REVIEW_HEAD_DIR=/tmp/head bash "$R")
assert_contains "$out" '--add-dir "/tmp/head" --max-turns' "head dir only, before --max-turns"
assert_eq "1" "$(printf '%s' "$out" | grep -o -- '--add-dir' | wc -l)" "one --add-dir"

# Only the input directory.
out=$(env -u REVIEW_HEAD_DIR "${RUNNER_ENV[@]}" REVIEW_INPUT_DIR=/tmp/input bash "$R")
assert_contains "$out" '--add-dir "/tmp/input" --max-turns' "input dir only, before --max-turns"
assert_eq "1" "$(printf '%s' "$out" | grep -o -- '--add-dir' | wc -l)" "one --add-dir"

# Both, in order, each followed by a flag and never by a bare word.
out=$(env "${RUNNER_ENV[@]}" REVIEW_HEAD_DIR=/tmp/head REVIEW_INPUT_DIR=/tmp/input bash "$R")
assert_contains "$out" '--add-dir "/tmp/head" --add-dir "/tmp/input" --max-turns' "both dirs, before --max-turns"
assert_eq "2" "$(printf '%s' "$out" | grep -o -- '--add-dir' | wc -l)" "two --add-dir"

# Empty-string variables count as unset.
out=$(env "${RUNNER_ENV[@]}" REVIEW_HEAD_DIR='' REVIEW_INPUT_DIR='' bash "$R")
case "$out" in *"--add-dir"*) echo "FAIL: empty directories emitted --add-dir" >&2; exit 1 ;; esac

# No --add-dir swallows the next flag: each is followed by exactly one quoted
# value and then another flag.
for setup in "REVIEW_HEAD_DIR=/a" "REVIEW_INPUT_DIR=/b" "REVIEW_HEAD_DIR=/a REVIEW_INPUT_DIR=/b"; do
  out=$(env "${RUNNER_ENV[@]}" $setup bash "$R")
  assert_eq "0" "$(printf '%s\n' "$out" | grep -cE -- '--add-dir "[^"]*" [^-]')" \
    "an --add-dir value is followed by a flag ($setup)"
done

# The deny list is one comma-separated argument, so it cannot swallow what follows.
assert_eq "0" "$(printf '%s\n' "$out" | grep -c 'disallowedTools [^ ]* [^-]')" \
  "the deny list is one comma-separated argument"

# The path rules: the review line denies Read, Glob and Grep on the kernel's
# process and device views, the checkout's .git (where claude-code-action
# writes its token), the home's dot-files and dot-directories and the runner's
# actions and install directories, and on nothing that holds the head or the
# input directory.
out=$(env "${RUNNER_ENV[@]}" REVIEW_HEAD_DIR=/home/runner/work/_temp/head REVIEW_INPUT_DIR=/home/runner/work/_temp/review-input bash "$R")
assert_exit 0 $? "the review line composes with the runner's paths"
deny=$(flag_value "$out" --disallowedTools)
assert_eq "$(echo $REQUIRED_DENY | tr ' ' ','),$REVIEW_RULES" "$deny" "the deny list is the denied names, then exactly the review's path rules"
assert_contains "$out" "--disallowedTools '$(echo $REQUIRED_DENY | tr ' ' ',')," "the deny list is single-quoted"
for r in 'Read(//proc/**)' 'Grep(//proc/**)' 'Read(//home/runner/work/ddemo/ddemo/.git/**)' 'Grep(//home/runner/work/ddemo/ddemo/.git)' 'Read(//home/runner/.*/**)'; do
  grep -qxF -- "$r" <<<"${deny//,/$'\n'}" || { echo "FAIL: the review deny list lacks the whole token $r" >&2; exit 1; }
done
# No rule is on RUNNER_TEMP, the head, the input directory or any directory
# above them, since a deny rule beats the --add-dir that grants them.
covers() { # rule path ; true when the rule's path is the path or above it
  local p=${1#*(/}
  p=${p%)}; p=${p%/\*\*}
  case "$2/" in "$p"/*) return 0 ;; esac
  return 1
}
for r in ${deny//,/ }; do
  case "$r" in *"(//"*) ;; *) continue ;; esac
  for granted in /home/runner/work/_temp /home/runner/work/_temp/head /home/runner/work/_temp/review-input; do
    ! covers "$r" "$granted" || { echo "FAIL: $r covers $granted" >&2; exit 1; }
  done
done
case "$deny" in *_temp*) echo "FAIL: a review rule names RUNNER_TEMP" >&2; exit 1 ;; esac
# Parsed the way claude-code-action parses claude_args: the two directories,
# the three allowed tools, and every name and rule in the deny list.
parsed=$(python3 -I "$PARSE" "${out#*=}")
got=$(printf '%s' "$parsed" | python3 -I -c '
import json, sys
p = json.load(sys.stdin)
print("|".join(p["addDirs"]), ",".join(p["allowedTools"]), ",".join(p["disallowedTools"]))')
assert_eq "/home/runner/work/_temp/head|/home/runner/work/_temp/review-input Read,Glob,Grep $(echo $REQUIRED_DENY | tr ' ' ','),$REVIEW_RULES" \
  "$got" "the review line parses to its directories, Read, Glob and Grep, and the whole deny list"

# The check can fail: a rule on RUNNER_TEMP's tree or above it is caught, a
# sibling is not.
for r in 'Read(//home/runner/work/**)' 'Grep(//home/runner/work/_temp)' 'Read(//home/runner/work/_temp/head/**)'; do
  covers "$r" /home/runner/work/_temp/head || { echo "FAIL: the ancestor check missed $r" >&2; exit 1; }
done
! covers 'Read(//home/runner/work/_actions/**)' /home/runner/work/_temp/head || { echo "FAIL: the ancestor check caught a sibling" >&2; exit 1; }

# Fails closed on a runner path that is unset, relative, would end the
# quoting, or ends in or doubles a slash.
for bad in "HOME=" "HOME=home/runner" "RUNNER_TEMP=/home/runner/work/_te'mp" "GITHUB_WORKSPACE=/home/runner/work/a b" \
           "GITHUB_WORKSPACE=/home/runner/work/../x" "RUNNER_TEMP=/" "RUNNER_TEMP=/home/runner/work/_temp/" \
           "HOME=/home//runner" "GITHUB_WORKSPACE=/home/runner/work/ddemo/ddemo/" \
           $'HOME=/home/runner\n/x' $'RUNNER_TEMP=/home/runner/work/_temp\nz' $'GITHUB_WORKSPACE=\n/w'; do
  out=$(env "${RUNNER_ENV[@]}" "$bad" bash "$R" 2>/dev/null)
  rc=$?
  assert_exit 1 "$rc" "the review line refuses $bad"
  assert_eq "" "$out" "the review line prints nothing for $bad"
done
out=$(env -u GITHUB_WORKSPACE HOME=/home/runner RUNNER_TEMP=/home/runner/work/_temp bash "$R" 2>/dev/null)
assert_exit 1 $? "the review line refuses an unset GITHUB_WORKSPACE"
assert_eq "" "$out" "and prints nothing"

# A denied root that is or holds a path the reviewer needs would deny it
# everything there, since a deny rule beats the grant: a self-hosted runner
# installed at ~/actions-runner keeps its workspace and temporary directory
# inside it. The line is refused, naming the variable, rather than composed.
SELF_HOSTED=(HOME=/home/runner RUNNER_TEMP=/home/runner/actions-runner/_work/_temp GITHUB_WORKSPACE=/home/runner/actions-runner/_work/ddemo/ddemo)
for setup in "RUNNER_TEMP ${SELF_HOSTED[*]}" \
             "GITHUB_WORKSPACE HOME=/home/runner RUNNER_TEMP=/home/runner/work/_temp GITHUB_WORKSPACE=/home/runner/runners/w" \
             "GITHUB_WORKSPACE HOME=/home/runner RUNNER_TEMP=/home/runner/work/_temp GITHUB_WORKSPACE=/home/runner/.cache/w" \
             "REVIEW_HEAD_DIR ${RUNNER_ENV[*]} REVIEW_HEAD_DIR=/home/runner/.config/head" \
             "REVIEW_INPUT_DIR ${RUNNER_ENV[*]} REVIEW_INPUT_DIR=/proc" \
             "REVIEW_INPUT_DIR ${RUNNER_ENV[*]} REVIEW_INPUT_DIR=/home/runner/work/_actions/x"; do
  # shellcheck disable=SC2086
  set -- $setup
  want=$1; shift
  out=$(env "$@" bash "$R" 2>"$tmp_err")
  rc=$?
  assert_exit 1 "$rc" "the review line refuses a denied root over $want ($*)"
  assert_eq "" "$out" "and prints nothing ($*)"
  assert_contains "$(cat "$tmp_err")" "$want" "and names $want on stderr"
done
# The hosted layout with the head and input under RUNNER_TEMP composes.
env "${RUNNER_ENV[@]}" REVIEW_HEAD_DIR=/home/runner/work/_temp/head REVIEW_INPUT_DIR=/home/runner/work/_temp/review-input bash "$R" >/dev/null
assert_exit 0 $? "the hosted layout composes"

# ---------------------------------------------------------------------------
# The security audit's variables (--audit) and models (--audit-models). The
# checks above, which require Agent and Task denied, apply to the review
# variable only: every audit step but repair delegates to subagents.
PARSE_ENV="$ROOT/tools/agent/test/helpers/parse-env-file.py"
# The audit deny list: the review's NO_HUMAN and NO_WRITE names, read from the
# script, without the tools the audit agents use, then the audit-only names
# from Stage 0's tool list and the Technical Plan.
AUDIT_ONLY="CronDelete,CronList,TaskStop,TodoWrite,AskUserQuestion,EnterPlanMode,ExitPlanMode,EnterWorktree,ExitWorktree,ToolSearch,DesignSync,PushNotification,RemoteTrigger,ReportFindings,Workflow"
NO_HUMAN=$(sed -n 's/^NO_HUMAN="\(.*\)"$/\1/p' "$R")
NO_WRITE=$(sed -n 's/^NO_WRITE="\(.*\)"$/\1/p' "$R")
[ -n "$NO_HUMAN" ] && [ -n "$NO_WRITE" ] || { echo "FAIL: NO_HUMAN or NO_WRITE could not be read from the script" >&2; exit 1; }
AUDIT_DENY="$(printf '%s\n' "${NO_HUMAN//,/$'\n'}" "${NO_WRITE//,/$'\n'}" | grep -vxE 'Agent|Task|Write|Edit' | paste -sd, -),$AUDIT_ONLY"
PATH_RULES="Read(//proc),Glob(//proc),Grep(//proc),Edit(//proc),Read(//proc/**),Glob(//proc/**),Grep(//proc/**),Edit(//proc/**),Read(//sys),Glob(//sys),Grep(//sys),Edit(//sys),Read(//sys/**),Glob(//sys/**),Grep(//sys/**),Edit(//sys/**),Read(//home/runner/work/_temp),Glob(//home/runner/work/_temp),Grep(//home/runner/work/_temp),Edit(//home/runner/work/_temp),Read(//home/runner/work/_temp/**),Glob(//home/runner/work/_temp/**),Grep(//home/runner/work/_temp/**),Edit(//home/runner/work/_temp/**),Read(//home/runner/work/_actions),Glob(//home/runner/work/_actions),Grep(//home/runner/work/_actions),Edit(//home/runner/work/_actions),Read(//home/runner/work/_actions/**),Glob(//home/runner/work/_actions/**),Grep(//home/runner/work/_actions/**),Edit(//home/runner/work/_actions/**),Read(//home/runner/runners),Glob(//home/runner/runners),Grep(//home/runner/runners),Edit(//home/runner/runners),Read(//home/runner/runners/**),Glob(//home/runner/runners/**),Grep(//home/runner/runners/**),Edit(//home/runner/runners/**),Read(//home/runner/.*),Glob(//home/runner/.*),Grep(//home/runner/.*),Edit(//home/runner/.*),Read(//home/runner/.*/**),Glob(//home/runner/.*/**),Grep(//home/runner/.*/**),Edit(//home/runner/.*/**),Read(//home/runner/actions-runner),Glob(//home/runner/actions-runner),Grep(//home/runner/actions-runner),Edit(//home/runner/actions-runner),Read(//home/runner/actions-runner/**),Glob(//home/runner/actions-runner/**),Grep(//home/runner/actions-runner/**),Edit(//home/runner/actions-runner/**),Read(//home/runner/work/ddemo/ddemo/.git),Glob(//home/runner/work/ddemo/ddemo/.git),Grep(//home/runner/work/ddemo/ddemo/.git),Read(//home/runner/work/ddemo/ddemo/.git/**),Glob(//home/runner/work/ddemo/ddemo/.git/**),Grep(//home/runner/work/ddemo/ddemo/.git/**),Edit(//home/runner/work/ddemo/ddemo/**)"

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
            "AGENT_ARGS_AUDIT_POC_WRITE claude-opus-4-8 poc-write 120 yes" \
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
    grep -qxF -- "$t" <<<"${deny//,/$'\n'}" || { echo "FAIL: $name does not deny the review's $t" >&2; exit 1; }
  done
  for t in ${AUDIT_DENY//,/ }; do
    grep -qxF -- "$t" <<<"${deny//,/$'\n'}" || { echo "FAIL: $name does not deny $t" >&2; exit 1; }
  done
  for t in Read Glob Grep Write Edit; do
    ! grep -qxF -- "$t" <<<"${deny//,/$'\n'}" || { echo "FAIL: $name denies $t by name" >&2; exit 1; }
  done
  for r in ${PATH_RULES//,/ }; do
    grep -qxF -- "$r" <<<"${deny//,/$'\n'}" || { echo "FAIL: $name lacks the rule $r after parsing" >&2; exit 1; }
  done
  # Only repair denies the subagent tool, under both of its names.
  for t in Agent Task; do
    if grep -qxF -- "$t" <<<"${deny//,/$'\n'}"; then denied=yes; else denied=no; fi
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
           "HOME=/home//runner" "GITHUB_WORKSPACE=/home/runner/work/ddemo/ddemo/" \
           $'HOME=/home/runner\n/x' $'RUNNER_TEMP=/home/runner/work/_temp\nz' $'GITHUB_WORKSPACE=\n/w'; do
  out=$(env "${RUNNER_ENV[@]}" "$bad" bash "$R" --audit 2>/dev/null)
  rc=$?
  assert_exit 1 "$rc" "--audit refuses $bad"
  assert_eq "" "$out" "--audit prints nothing for $bad"
done
out=$(env -u RUNNER_TEMP HOME=/home/runner GITHUB_WORKSPACE=/w bash "$R" --audit 2>/dev/null)
assert_exit 1 $? "--audit refuses an unset RUNNER_TEMP"

# --audit-models: the step's model three times, read as the runner reads $GITHUB_ENV.
tmp=$(mktemp -d)
trap 'rm -rf "$tmp" "$tmp_err"' EXIT
for spec in "source claude-opus-5-5" "repair claude-opus-5-5" "poc_write claude-opus-4-8" \
            "poc_decide claude-opus-5-5" "cross_check claude-fable-5-1" "tie_break claude-sonnet-5-5"; do
  # shellcheck disable=SC2086
  set -- $spec
  bash "$R" --audit-models "$1" > "$tmp/env"
  assert_exit 0 $? "--audit-models $1"
  assert_eq "{\"ANTHROPIC_DEFAULT_SONNET_MODEL\": \"$2\", \"ANTHROPIC_DEFAULT_HAIKU_MODEL\": \"$2\", \"CLAUDE_CODE_SUBAGENT_MODEL\": \"$2\"}" \
    "$(python3 -I "$PARSE_ENV" "$tmp/env")" "--audit-models $1 sets the three model variables to $2"
done
# The cross-check and the tie-break each run on a model that none of the jobs
# they judge runs on (D24): source, its repair, poc-write and poc-decide.
audit_model() { bash "$R" --audit-models "$1" | sed -n 's/^CLAUDE_CODE_SUBAGENT_MODEL=//p'; }
for judge in cross_check tie_break; do
  for judged in source repair poc_write poc_decide; do
    [ "$(audit_model "$judge")" != "$(audit_model "$judged")" ] \
      || { echo "FAIL: $judge runs on the model $judged runs on" >&2; exit 1; }
  done
done
[ "$(audit_model tie_break)" != "$(audit_model cross_check)" ] \
  || { echo "FAIL: the tie-break runs on the cross-check's model" >&2; exit 1; }
bash "$R" --audit-models nope >/dev/null 2>&1
assert_exit 2 $? "--audit-models refuses an unknown step"
bash "$R" --audit-models >/dev/null 2>&1
assert_exit 2 $? "--audit-models needs a step"
bash "$R" --bogus >/dev/null 2>&1
assert_exit 2 $? "an unknown option is refused"
pass
