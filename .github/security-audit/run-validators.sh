#!/usr/bin/env bash
# Runs the vendored skill's two validators on <dir>/findings.json and
# <dir>/coverage-ledger.json. Their output can quote record text, so it goes
# only to <dir>/validator-errors.txt, which the repair agent reads and the
# hand-off seals; stderr gets the exit codes and the count of ERROR lines.
# stdout is one line, validators=pass or validators=fail, ready to append to
# $GITHUB_OUTPUT. A validator that fails to run counts as failing.
#   run-validators.sh <dir>
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"

[ "$#" -eq 1 ] && [ -d "$1" ] || { echo "usage: run-validators.sh <dir>" >&2; exit 2; }
dir="$1"
errors="$dir/validator-errors.txt"
f=0 l=0
node "$HERE/skill/validate-findings.cjs" "$dir/findings.json" > "$errors" 2>&1 || f=$?
node "$HERE/skill/validate-coverage-ledger.cjs" "$dir/coverage-ledger.json" >> "$errors" 2>&1 || l=$?
count=$(grep -c '^ERROR' "$errors")
echo "validate-findings exit $f, validate-coverage-ledger exit $l, ${count:-0} error line(s)" >&2
if [ "$f" -eq 0 ] && [ "$l" -eq 0 ]; then echo "validators=pass"; else echo "validators=fail"; fi
