#!/usr/bin/env bash
# A stand-in for gh in the audit's tests: it answers from fixture files in
# $FIX and logs every call to $FIX/calls.log, so no test touches the network.
# Tests copy it into a directory on PATH as gh.
#
#   gh api [--paginate] <path>   prints $FIX/<key>.json, where <key> is <path>
#                                with / ? & = turned into _; with no such file
#                                it fails as gh does on a 404 (the error body on
#                                stdout, "HTTP 404" on stderr), and with a
#                                <key>.500 file as on a server error.
#   gh run list ...              prints the runs in $FIX/run_list.json (newest
#                                first), keeping only those whose conclusion
#                                equals --status when it names a conclusion,
#                                and at most --limit of them; or fails like a
#                                server error when $FIX/run_list.500 exists.
#   gh run download <run> ... -D <dir>
#                                copies $FIX/download-<run>/ into <dir>, or
#                                fails when there is no such directory.
set -euo pipefail
echo "gh $*" >> "$FIX/calls.log"

server_error() { echo "gh: Server Error (HTTP 500)" >&2; exit 1; }

case "${1:-} ${2:-}" in
  "api "*)
    shift
    [ "$1" = --paginate ] && shift
    key="$(printf '%s' "$1" | tr '/?&=' '____')"
    [ ! -e "$FIX/$key.500" ] || server_error
    if [ ! -e "$FIX/$key.json" ]; then
      echo '{"message":"Not Found","status":"404"}'
      echo "gh: Not Found (HTTP 404)" >&2
      exit 1
    fi
    cat "$FIX/$key.json"
    ;;
  "run list")
    [ ! -e "$FIX/run_list.500" ] || server_error
    status="" limit=20 prev=""
    for a in "$@"; do
      [ "$prev" = --status ] && status="$a"
      [ "$prev" = --limit ] && limit="$a"
      prev="$a"
    done
    jq -c --arg status "$status" --argjson limit "$limit" '
      if ($status | IN("", "completed")) then . else map(select(.conclusion == $status)) end
      | .[:$limit]' "$FIX/run_list.json"
    ;;
  "run download")
    run="$3" dir="" prev=""
    for a in "$@"; do
      [ "$prev" = -D ] && dir="$a"
      prev="$a"
    done
    [ -d "$FIX/download-$run" ] || { echo "no valid artifacts found to download" >&2; exit 1; }
    cp -a "$FIX/download-$run/." "$dir/"
    ;;
  *)
    echo "fake gh: unexpected call: $*" >&2
    exit 3
    ;;
esac
