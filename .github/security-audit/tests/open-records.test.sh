#!/usr/bin/env bash
# Tests for open-records.sh with throwaway age keys: mapped records open into
# the output folder; a sha256 mismatch, a malformed name, a record sealed to
# another key, a record holding another file or two files, and a map that is
# not an object each fail; a record not in the map is never opened.
set -euo pipefail
# shellcheck source=../../claude-review/tools/agent/test/assert.sh
. "$(dirname "$0")/../../claude-review/tools/agent/test/assert.sh"
SA="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
age-keygen -o "$tmp/agents.key" 2>/dev/null
age-keygen -o "$tmp/other.key" 2>/dev/null
age-keygen -y "$tmp/agents.key" > "$tmp/agents.pub"
age-keygen -y "$tmp/other.key" > "$tmp/other.pub"
export AUDIT_AGENTS_AGE_KEY; AUDIT_AGENTS_AGE_KEY="$(grep AGE-SECRET-KEY "$tmp/agents.key")"
mkdir "$tmp/sealed"

seal_record() { # name pub [file-name...]: seals a folder holding the named files
  local name="$1" pub="$2" dir; shift 2
  dir="$(mktemp -d)"
  for f in "${@:-$name.json}"; do echo "{\"stdout\": \"$f\"}" > "$dir/$f"; done
  bash "$SA/seal.sh" seal "$pub" "$dir" "$tmp/sealed/$name.age"
  rm -rf "$dir"
}
run() { # map: runs into a fresh output folder, sets RC
  rm -rf "$tmp/out"; mkdir "$tmp/out"
  RC=0; bash "$SA/open-records.sh" AUDIT_AGENTS_AGE_KEY "$1" "$tmp/sealed" "$tmp/out" > "$tmp/stdout" 2> "$tmp/stderr" || RC=$?
}

a=$(seal_record poc-run-1-a "$tmp/agents.pub")
b=$(seal_record poc-run-1-b "$tmp/agents.pub")
seal_record poc-run-2-a "$tmp/agents.pub" > /dev/null
run "{\"poc-run-1-a\": \"$a\", \"poc-run-1-b\": \"$b\"}"
assert_exit 0 "$RC" "mapped records open"
assert_eq "poc-run-1-a.json
poc-run-1-b.json" "$(ls "$tmp/out")" "only the mapped records are opened, each as its own file"
run '{}'
assert_exit 0 "$RC" "an empty map opens nothing"
assert_eq "" "$(ls "$tmp/out")" "an empty map leaves the folder empty"

run "{\"poc-run-1-a\": \"$b\"}"
assert_exit 1 "$RC" "a sha256 that is not the record's fails"
run "{\"../x\": \"$a\"}"
assert_exit 1 "$RC" "a malformed record name fails"
assert_contains "$(cat "$tmp/stderr")" "malformed entry" "the malformed entry is named as such"
o=$(seal_record poc-run-3-a "$tmp/other.pub")
run "{\"poc-run-3-a\": \"$o\"}"
assert_exit 1 "$RC" "a record sealed to another key fails"
w=$(seal_record poc-run-4-a "$tmp/agents.pub" other.json)
run "{\"poc-run-4-a\": \"$w\"}"
assert_exit 1 "$RC" "a record holding another file fails"
t=$(seal_record poc-run-5-a "$tmp/agents.pub" poc-run-5-a.json extra.json)
run "{\"poc-run-5-a\": \"$t\"}"
assert_exit 1 "$RC" "a record holding two files fails"
run '["poc-run-1-a"]'
assert_exit 1 "$RC" "a map that is not an object fails"
rc=0; bash "$SA/open-records.sh" AUDIT_AGENTS_AGE_KEY '{}' 2>/dev/null || rc=$?
assert_exit 2 "$rc" "missing arguments are a usage error"
pass
