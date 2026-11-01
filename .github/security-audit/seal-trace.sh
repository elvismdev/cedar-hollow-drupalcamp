#!/usr/bin/env bash
# Seals one agent step's execution trace to an age recipient, as a folder
# holding execution.json, so it can be uploaded for the owner without being
# readable in the public artifact list. Prints the sealed file's sha256.
#   seal-trace.sh <recipient-file> <trace> <out>
# Fails when the trace is missing or empty, since there is nothing to keep.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"

[ "$#" -eq 3 ] || { echo "usage: seal-trace.sh <recipient-file> <trace> <out>" >&2; exit 2; }
recipient="$1" trace="$2" out="$3"
[ -n "$trace" ] && [ -s "$trace" ] || { echo "seal-trace: no execution trace to seal" >&2; exit 1; }
dir=$(mktemp -d)
trap 'rm -rf "$dir"' EXIT
cp "$trace" "$dir/execution.json"
mkdir -p "$(dirname "$out")"
bash "$HERE/seal.sh" seal "$recipient" "$dir" "$out"
