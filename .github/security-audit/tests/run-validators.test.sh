#!/usr/bin/env bash
# Tests for run-validators.sh: valid records pass, an invalid record fails,
# a missing file fails, the validators' text goes only to
# validator-errors.txt (never stdout or stderr), and stdout is exactly the
# one validators= line.
set -euo pipefail
# shellcheck source=../../claude-review/tools/agent/test/assert.sh
. "$(dirname "$0")/../../claude-review/tools/agent/test/assert.sh"
SA="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

echo '[]' > "$tmp/findings.json"
echo '[]' > "$tmp/coverage-ledger.json"
out=$(bash "$SA/run-validators.sh" "$tmp" 2> "$tmp/err")
assert_eq "validators=pass" "$out" "valid records pass"
assert_contains "$(cat "$tmp/err")" "validate-findings exit 0, validate-coverage-ledger exit 0, 0 error line(s)" "stderr gives the exit codes and the count"

# A record whose text must not reach the log.
echo '[{"verdict": "confirmed", "fingerprint": "F-1", "title": "LEAKTITLE7f3a"}]' > "$tmp/findings.json"
out=$(bash "$SA/run-validators.sh" "$tmp" 2> "$tmp/err")
assert_eq "validators=fail" "$out" "an invalid record fails"
case "$out$(cat "$tmp/err")" in *LEAKTITLE7f3a*) echo "FAIL: record text reached stdout or stderr" >&2; exit 1;; esac
assert_contains "$(cat "$tmp/validator-errors.txt")" "ERROR" "the validators' errors are in validator-errors.txt"

rm "$tmp/coverage-ledger.json"
echo '[]' > "$tmp/findings.json"
out=$(bash "$SA/run-validators.sh" "$tmp" 2>/dev/null)
assert_eq "validators=fail" "$out" "a missing ledger fails"

rc=0; bash "$SA/run-validators.sh" 2>/dev/null || rc=$?
assert_exit 2 "$rc" "no folder is a usage error"
pass
