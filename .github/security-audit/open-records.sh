#!/usr/bin/env bash
# Opens the sealed run records named in poc-run's record map into one folder.
#   open-records.sh <identity-env-name> <record-map> <sealed-dir> <out-dir>
# <record-map> is poc-run's records output, a JSON object from record name
# (poc-run-<n>-<a|b>) to the sha256 of <sealed-dir>/<name>.age. Only the
# records in the map are opened, each with seal.sh open, which checks its
# sha256 first, and each must hold exactly one regular file, <name>.json,
# which is moved into <out-dir>. A malformed map entry, a sha256 mismatch, a
# record that does not open, or any other content exits 1 with the record's
# name only; nothing it holds is printed.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"

[ "$#" -eq 4 ] || { echo "usage: open-records.sh <identity-env-name> <record-map> <sealed-dir> <out-dir>" >&2; exit 2; }
key="$1" map="$2" sealed="$3" out="$4"
[ -d "$sealed" ] && [ -d "$out" ] || { echo "open-records: the sealed and output folders must exist" >&2; exit 2; }
entries=$(jq -r 'if type == "object" then to_entries[] | "\(.key) \(.value)" else error("not an object") end' <<<"$map") \
  || { echo "open-records: the record map is not a JSON object" >&2; exit 1; }

opened=0
while read -r name sum; do
  [ -n "$name" ] || continue
  if ! [[ "$name" =~ ^poc-run-[1-9][0-9]*-[ab]$ && "$sum" =~ ^[0-9a-f]{64}$ ]]; then
    echo "open-records: malformed entry in the run record map" >&2
    exit 1
  fi
  dir=$(mktemp -d)
  if ! bash "$HERE/seal.sh" open "$key" "$sum" "$sealed/$name.age" "$dir"; then
    rm -rf "$dir"
    echo "open-records: $name did not open" >&2
    exit 1
  fi
  if [ "$(find "$dir" -mindepth 1 -printf '%P\n')" != "$name.json" ] || [ -L "$dir/$name.json" ] || [ ! -f "$dir/$name.json" ]; then
    rm -rf "$dir"
    echo "open-records: $name does not hold exactly one regular file $name.json" >&2
    exit 1
  fi
  mv "$dir/$name.json" "$out/"
  rmdir "$dir"
  opened=$((opened + 1))
done <<<"$entries"
echo "open-records: $opened run record(s) opened"
