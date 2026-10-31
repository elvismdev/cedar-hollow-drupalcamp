#!/usr/bin/env bash
# Print "path:line" for every line a review comment can attach to.
#
# GitHub rejects an entire review when one comment points at a line outside the
# diff, so post-findings.sh needs to know which lines are addressable. Only
# added and context lines on the RIGHT side qualify.
#
# Exits 1 when a non-empty diff yields no addressable lines, because an empty
# map is indistinguishable from a parse failure and would silently push every
# finding into the summary.
#
# GitHub validates review comments against the pull request's merge-base
# diff, so the map is built from the merge base of base and head. A two-dot
# base..head diff would also name every line the base changed after the branch
# point, and a finding anchored there makes GitHub reject the review.
#
# Usage: diff-addressable-lines.sh <base-ref> <head-ref>
set -uo pipefail
[ "$#" -eq 2 ] || { echo "usage: diff-addressable-lines.sh <base-ref> <head-ref>" >&2; exit 2; }
base="$1"; head="$2"

mb=$(git merge-base "$base" "$head") && [ -n "$mb" ] || {
  echo "diff-addressable-lines: no merge base between ${base} and ${head}, so the change cannot be bounded" >&2; exit 1; }
diff=$(git diff --unified=0 "${mb}..${head}") || { echo "diff-addressable-lines: git diff failed" >&2; exit 1; }

printf '%s' "$diff" | python3 -c '
import re, sys
path = None
out = []
for line in sys.stdin:
    if line.startswith("+++ b/"):
        path = line[6:].rstrip("\n")
        continue
    if line.startswith("+++ /dev/null"):
        path = None
        continue
    m = re.match(r"^@@ -\S+ \+(\d+)(?:,(\d+))? @@", line)
    if m and path:
        start = int(m.group(1))
        count = 1 if m.group(2) is None else int(m.group(2))
        for n in range(start, start + count):
            out.append(f"{path}:{n}")
print("\n".join(out))
' > /tmp/.addressable.$$ || { rm -f /tmp/.addressable.$$; echo "diff-addressable-lines: parse failed" >&2; exit 1; }

n=$(grep -c . /tmp/.addressable.$$ || true)
if [ -n "$diff" ] && [ "$n" -eq 0 ]; then
  rm -f /tmp/.addressable.$$
  echo "diff-addressable-lines: the diff is not empty but no line is addressable; treating that as a parse failure rather than a map with nothing in it" >&2
  exit 1
fi
cat /tmp/.addressable.$$; rm -f /tmp/.addressable.$$
