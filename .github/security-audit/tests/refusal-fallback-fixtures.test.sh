#!/usr/bin/env bash
# Runs every trace in fixtures/refusal-fallback through check-agent-run.sh and
# merge-records.py count, the two readers of Claude Code's refusal fallback
# event, and requires both to accept exactly the fallback models that
# expected.json lists for it: the run check by the line it prints for each
# fallback model used, count by what it records under refusal_fallback. A
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

  helper=$(jq -r --arg n "$name" '.helpers[$n] // ""' "$FIX/expected.json")
  helper_args=()
  if [ -n "$helper" ]; then helper_args=(--helper "$helper"); fi
  check=$(bash "$SA/check-agent-run.sh" poc-write "$f" "Read,Glob,Grep" /mnt/audit/poc-write/out "$tmp/fp" "$PINNED" ${helper:+"$helper"} 2>&1 || true)
  by_check=$(sed -n 's/^check-agent-run: the poc-write step ran on the refusal fallback model \(.*\)$/\1/p' <<<"$check" \
    | jq -Rsc 'split("\n") | map(select(length > 0)) | sort')

  state="$tmp/state-$name"
  mkdir -p "$state"
  echo '[]' > "$state/findings.json"
  echo '[]' > "$state/coverage-ledger.json"
  echo '{"run_id": "1"}' > "$state/run-metadata.json"
  python3 -I "$SA/merge-records.py" --state "$state" count --job poc-write --cap 12 --trace "$f" --model "$PINNED" "${helper_args[@]}" >/dev/null
  by_count=$(jq -c '[.refusal_fallback[].fallback_model] | sort' "$state/trusted-meta.json")

  assert_eq "$want" "$by_check" "$name: the run check accepts the expected fallback models"
  assert_eq "$want" "$by_count" "$name: count records the expected fallback models"
  assert_eq "$by_check" "$by_count" "$name: the run check and count agree"
done
[ "$count" -ge 11 ] || { echo "FAIL: only $count fixture(s) were read" >&2; exit 1; }
pass "refusal-fallback-fixtures.test.sh ($count fixtures)"
