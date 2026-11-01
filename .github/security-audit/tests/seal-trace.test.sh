#!/usr/bin/env bash
# Tests for seal-trace.sh with throwaway age keys: a trace seals to a file that
# opens, with the agents key, to exactly that trace as execution.json, and the
# printed sha256 is the sealed file's; another key cannot open it; a missing
# or empty trace fails and writes nothing.
set -euo pipefail
# shellcheck source=../../claude-review/tools/agent/test/assert.sh
. "$(dirname "$0")/../../claude-review/tools/agent/test/assert.sh"
SA="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
for k in agents other; do
  age-keygen -o "$tmp/$k.key" 2>/dev/null
  age-keygen -y "$tmp/$k.key" > "$tmp/$k.pub"
done
token=$(od -An -tx1 -N16 /dev/urandom | tr -d ' \n')
printf '[{"type":"result","note":"%s"}]\n' "$token" > "$tmp/trace.json"

sum=$(bash "$SA/seal-trace.sh" "$tmp/agents.pub" "$tmp/trace.json" "$tmp/out/sealed.age")
assert_eq "$(sha256sum "$tmp/out/sealed.age" | cut -d' ' -f1)" "$sum" "the printed sha256 is the sealed file's"
if grep -qaF "$token" "$tmp/out/sealed.age"; then echo "FAIL: the trace is readable in the sealed file" >&2; exit 1; fi
mkdir "$tmp/open"
AUDIT_AGENTS_AGE_KEY="$(grep AGE-SECRET-KEY "$tmp/agents.key")" bash "$SA/seal.sh" open AUDIT_AGENTS_AGE_KEY "$sum" "$tmp/out/sealed.age" "$tmp/open"
assert_eq "execution.json" "$(ls "$tmp/open")" "the sealed folder holds only execution.json"
cmp -s "$tmp/trace.json" "$tmp/open/execution.json" || { echo "FAIL: the opened trace differs from the trace" >&2; exit 1; }
mkdir "$tmp/other-open"
rc=0; OTHER_KEY="$(grep AGE-SECRET-KEY "$tmp/other.key")" bash "$SA/seal.sh" open OTHER_KEY "$sum" "$tmp/out/sealed.age" "$tmp/other-open" 2>/dev/null || rc=$?
[ "$rc" -ne 0 ] || { echo "FAIL: another key opened the sealed trace" >&2; exit 1; }

rc=0; bash "$SA/seal-trace.sh" "$tmp/agents.pub" "$tmp/missing.json" "$tmp/x/y.age" 2>/dev/null || rc=$?
assert_exit 1 "$rc" "a missing trace fails"
[ ! -e "$tmp/x/y.age" ] || { echo "FAIL: a sealed file was written for a missing trace" >&2; exit 1; }
: > "$tmp/empty.json"
rc=0; bash "$SA/seal-trace.sh" "$tmp/agents.pub" "$tmp/empty.json" "$tmp/x/y.age" 2>/dev/null || rc=$?
assert_exit 1 "$rc" "an empty trace fails"
rc=0; bash "$SA/seal-trace.sh" "$tmp/agents.pub" "" "$tmp/x/y.age" 2>/dev/null || rc=$?
assert_exit 1 "$rc" "an empty trace argument (no execution_file output) fails"
rc=0; bash "$SA/seal-trace.sh" "$tmp/agents.pub" 2>/dev/null || rc=$?
assert_exit 2 "$rc" "missing arguments are a usage error"
pass
