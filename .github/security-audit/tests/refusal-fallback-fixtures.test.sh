#!/usr/bin/env bash
# Runs every trace in fixtures/refusal-fallback through check-agent-run.sh and
# merge-records.py count, the two readers of Claude Code's refusal fallback
# and automatic compaction events, and requires both to accept exactly the
# fallback models that expected.json lists under accepted and the compaction
# models it lists under compaction: the run check by the line it prints for
# each model, count by what it records under refusal_fallback and compaction.
# A fixture named in expected.json's jobs runs as that job instead of
# poc-write; for the cross-check and tie-break, which run with the fallback
# off, both must report the same refusals with no fallback as refusals lists
# them: main:<index>:<category> for the main loop, subagent:<agent id>:<index>:
# <category> for a subagent, where index is the message's position in the
# trace's top-level array, and "not given" for a category off the pattern. A
# fixture named in expected.json's helpers runs both with that helper model,
# which neither treats as a fallback.
set -euo pipefail
# shellcheck source=../../claude-review/tools/agent/test/assert.sh
. "$(dirname "$0")/../../claude-review/tools/agent/test/assert.sh"
SA="$(cd "$(dirname "$0")/.." && pwd)"
FIX="$SA/tests/fixtures/refusal-fallback"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# A workspace and fingerprint as the run check needs them.
export GITHUB_WORKSPACE="$tmp/repo" HOME="$tmp/home"
git init -q "$GITHUB_WORKSPACE"
git -C "$GITHUB_WORKSPACE" -c user.email=ci@example.invalid -c user.name=CI commit -q --allow-empty -m init
mkdir -p "$HOME/.claude"
unset AUDIT_INPUT_DIR
bash "$SA/check-agent-run.sh" --fingerprint "$tmp/fp" >/dev/null
PINNED=$(jq -r .pinned "$FIX/expected.json")

count=0
for f in "$FIX"/*.json; do
  name=$(basename "$f" .json)
  [ "$name" != expected ] || continue
  count=$((count + 1))
  want=$(jq -c --arg n "$name" '.accepted[$n] | sort' "$FIX/expected.json")
  [ "$want" != null ] || { echo "FAIL: $name has no entry in expected.json" >&2; exit 1; }
  want_c=$(jq -c --arg n "$name" '.compaction[$n] | sort' "$FIX/expected.json")
  [ "$want_c" != null ] || { echo "FAIL: $name has no compaction entry in expected.json" >&2; exit 1; }

  want_r=$(jq -c --arg n "$name" '.refusals[$n] | sort' "$FIX/expected.json")
  [ "$want_r" != null ] || { echo "FAIL: $name has no refusals entry in expected.json" >&2; exit 1; }
  job=$(jq -r --arg n "$name" '.jobs[$n] // "poc-write"' "$FIX/expected.json")

  helper=$(jq -r --arg n "$name" '.helpers[$n] // ""' "$FIX/expected.json")
  helper_args=()
  if [ -n "$helper" ]; then helper_args=(--helper "$helper"); fi
  check=$(bash "$SA/check-agent-run.sh" "$job" "$f" "Read,Glob,Grep,Agent" "/mnt/audit/$job/out" "$tmp/fp" "$PINNED" ${helper:+"$helper"} 2>&1 || true)
  by_check=$(sed -n "s/^check-agent-run: the $job step ran on the refusal fallback model \(.*\)\$/\1/p" <<<"$check" \
    | jq -Rsc 'split("\n") | map(select(length > 0)) | sort')
  c_check=$(sed -n "s/^check-agent-run: the $job step's context was summarised by the compaction model \(.*\)\$/\1/p" <<<"$check" \
    | jq -Rsc 'split("\n") | map(select(length > 0)) | sort')
  r_check=$( { sed -n "s/^check-agent-run: the $job step's request was refused with no fallback (main loop, message \([0-9]*\)), category \(.*\)\$/main:\1:\2/p" <<<"$check"
               sed -n "s/^check-agent-run: .*(agent id \(.*\)) was refused with no fallback (message \([0-9]*\)), category \(.*\); its entry is never merged\$/subagent:\1:\2:\3/p" <<<"$check"; } \
    | jq -Rsc 'split("\n") | map(select(length > 0)) | sort')

  state="$tmp/state-$name"
  mkdir -p "$state"
  echo '[]' > "$state/findings.json"
  echo '[]' > "$state/coverage-ledger.json"
  echo '{"run_id": "1"}' > "$state/run-metadata.json"
  python3 -I "$SA/merge-records.py" --state "$state" count --job "$job" --cap 12 --trace "$f" --model "$PINNED" "${helper_args[@]}" >/dev/null
  by_count=$(jq -c '[.refusal_fallback[].fallback_model] | sort' "$state/trusted-meta.json")
  c_count=$(jq -c '[.compaction[].compaction_model] | sort' "$state/trusted-meta.json")
  r_count=$(jq -c '[(.classifier_refusals // [])[] | if .where == "main" then "main:\(.index):\(.category // "not given")"
                    else "subagent:\(.agent_id):\(.index):\(.category // "not given")" end] | sort' "$state/trusted-meta.json")

  assert_eq "$want" "$by_check" "$name: the run check accepts the expected fallback models"
  assert_eq "$want" "$by_count" "$name: count records the expected fallback models"
  assert_eq "$by_check" "$by_count" "$name: the run check and count agree"
  assert_eq "$want_c" "$c_check" "$name: the run check accepts the expected compaction models"
  assert_eq "$want_c" "$c_count" "$name: count records the expected compaction models"
  assert_eq "$want_r" "$r_check" "$name: the run check reports the expected refusals with no fallback"
  assert_eq "$want_r" "$r_count" "$name: count records the expected refusals with no fallback"
done
[ "$count" -ge 24 ] || { echo "FAIL: only $count fixture(s) were read" >&2; exit 1; }
pass "refusal-fallback-fixtures.test.sh ($count fixtures)"
