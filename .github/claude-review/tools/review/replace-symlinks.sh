#!/usr/bin/env bash
# Replace every symlink under a directory with a regular file naming its target.
#
# The pull request head is checked out as data, and git materialises a symlink
# the change adds as a real link. The reviewer reads the changed files, and its
# Read tool follows links, so a link to the workspace's .git/config or to /proc
# would let it read outside the head without any instruction to do so. Each
# link becomes a file whose content is "symlink to: <target>", the target as
# written and never resolved, so the reviewer still sees what the change adds
# and no head path leads anywhere else.
#
# find does not follow links, so a link to a directory is replaced, not entered.
#
# Usage: replace-symlinks.sh <dir>
set -euo pipefail

DIR="${1:?usage: replace-symlinks.sh <dir>}"
[ -d "$DIR" ] || { echo "replace-symlinks: '$DIR' is not a directory" >&2; exit 1; }

n=0
while IFS= read -r -d '' link; do
  target=$(readlink -- "$link")
  rm -f -- "$link"
  printf 'symlink to: %s\n' "$target" > "$link"
  n=$((n + 1))
done < <(find "$DIR" -type l -print0)

# Checked again rather than trusted: a link left behind is the one this exists to remove.
left=$(find "$DIR" -type l -print -quit)
[ -z "$left" ] || { echo "replace-symlinks: a symlink is still present after replacement" >&2; exit 1; }
echo "replace-symlinks: replaced ${n} symlink(s) with files naming their targets"
