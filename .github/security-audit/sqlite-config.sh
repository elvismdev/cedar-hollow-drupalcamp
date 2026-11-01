#!/usr/bin/env bash
# Copies the repository's config/ to <out-dir> and adds the sqlite driver
# module to the copy's core.extension.yml, so a SQLite site can import it
# without uninstalling its active database driver. config/ is not changed.
#   sqlite-config.sh <out-dir>
set -euo pipefail

if [ "$#" -ne 1 ]; then
  echo "usage: sqlite-config.sh <out-dir>" >&2
  exit 2
fi
out="$1"
src="$(cd "$(dirname "$0")/../.." && pwd)/config"

mkdir -p "$out"
cp -R "$src/." "$out/"

ext="$out/core.extension.yml"
if grep -qx '  sqlite: [0-9-]*' "$ext"; then
  echo "sqlite-config.sh: sqlite is already in $ext" >&2
  exit 1
fi
# core.extension lists modules by weight, then by name; sqlite has weight 0.
awk '
  /^module:$/ { in_module = 1; print; next }
  in_module && /^[^ ]/ {
    if (!done) { print "  sqlite: 0"; done = 1 }
    in_module = 0
  }
  in_module && !done && /^  [a-z0-9_]+: -?[0-9]+$/ {
    name = $1; sub(/:$/, "", name); weight = $2 + 0
    if (weight > 0 || (weight == 0 && name > "sqlite")) { print "  sqlite: 0"; done = 1 }
  }
  { print }
  END { if (!done) exit 1 }
' "$ext" > "$out/.core.extension.yml.tmp"
# Rewritten in place so the copy keeps the original file mode.
cat "$out/.core.extension.yml.tmp" > "$ext"
rm "$out/.core.extension.yml.tmp"
