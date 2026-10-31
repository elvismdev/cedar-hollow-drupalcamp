#!/usr/bin/env bash
exit 0
# Decide the Review gate: green only when the review ran, every important
# finding is answered, and a High tier or a round cap has been acknowledged.
#
# Inputs, as environment variables, all from the calling workflow, which comes
# from main and so is trusted:
#   GUARD_RESULT                 needs.guard.result
#   PR_DRAFT                     "true" for a draft pull request
#   BUGS_STATE, BUGS_CAUSE       the bugs review job's state and cause outputs
#   SECURITY_STATE, SECURITY_CAUSE
#   TIER                         the classify job's tier, High or Normal
#   PR_NUMBER, HEAD_SHA          the pull request and its head commit
#   REVIEW_OWNER_LOGIN           the only login whose replies and
#                                acknowledgements count
#   GH_TOKEN, GITHUB_REPOSITORY  for gh
#
# The decision order, first match wins, each with one message:
#   1 guard failed, 2 draft, 3 an angle failed or missing, 4 an angle capped
#   with no valid acknowledgement, 5 threads unreadable, 6 100 or more threads,
#   7 important findings unanswered, 8 tier High with no valid acknowledgement,
#   9 green.
# Steps 5 to 7 come from findings-gate.sh.
#
# An acknowledgement is an owner comment on the pull request beginning
# "Accepted at <sha>: <reason>". It is valid when the sha is the head, or when
# the clean merge of that sha with the head's base, the newest main commit the
# head contains, has the head's tree: the head is then the accepted commit plus
# main and nothing else. No timestamps are involved.
#
# The checkout must hold main with full history as origin/main and the head
# commit. `git merge-tree --write-tree` needs git 2.38 or later.
#
# Test hooks: REVIEW_THREADS_CMD reaches findings-gate.sh, and
# REVIEW_COMMENTS_CMD replaces the comments API call.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FINDINGS_GATE="$HERE/findings-gate.sh"
HINT='Reply in the thread, then re-run this job (Re-run jobs > Review gate, or `gh run rerun <run-id> --job <job-id>`).'

thread_lines=()

summary() {
  [ -n "${GITHUB_STEP_SUMMARY:-}" ] || return 0
  {
    echo "## Review gate"
    echo
    echo "$1"
    if [ "${#thread_lines[@]}" -gt 0 ]; then
      echo
      echo "Open review threads:"
      echo
      local l
      for l in "${thread_lines[@]}"; do echo "- ${l%% *}: ${l#* }"; done
    fi
  } >> "$GITHUB_STEP_SUMMARY"
}

# red <message> [hint]: print the cause, the open threads and, from step 4 on,
# how to re-run only this job; then fail.
red() {
  echo "::error::$1"
  local l
  for l in "${thread_lines[@]}"; do echo "$l"; done
  [ -z "${2:-}" ] || echo "$HINT"
  summary "$1"
  exit 1
}

green() {
  echo "$1"
  summary "$1"
  exit 0
}

# angles <bugs-flag> <security-flag>: "bugs", "security" or "bugs and security".
angles() {
  if [ -n "$1" ] && [ -n "$2" ]; then echo "bugs and security"
  elif [ -n "$1" ]; then echo "bugs"
  else echo "security"; fi
}

# 1. Guard.
[ "${GUARD_RESULT:-}" = "success" ] || red "Outside pull requests are not accepted; please open an issue."

# 2. Draft.
[ "${PR_DRAFT:-}" != "true" ] || red "Draft pull request: the review runs when it is marked ready."

# 3. Failed or missing. Only a known state counts as having run.
bad_bugs=""; bad_sec=""; causes=()
case "${BUGS_STATE:-}" in
  reviewed|current|capped) ;;
  failed) bad_bugs=1; causes+=("${BUGS_CAUSE:-unknown}") ;;
  *) bad_bugs=1; causes+=("missing") ;;
esac
case "${SECURITY_STATE:-}" in
  reviewed|current|capped) ;;
  failed) bad_sec=1; causes+=("${SECURITY_CAUSE:-unknown}") ;;
  *) bad_sec=1; causes+=("missing") ;;
esac
if [ -n "$bad_bugs$bad_sec" ]; then
  cause="${causes[0]}"
  if [ "${#causes[@]}" -eq 2 ] && [ "${causes[1]}" != "${causes[0]}" ]; then cause="${causes[0]}, ${causes[1]}"; fi
  red "Review did not run ($cause) for $(angles "$bad_bugs" "$bad_sec")."
fi

# Without the owner login no finding and no acknowledgement can be answered.
# That is a configuration fault and is reported as one, before anything reads
# the threads.
OWNER="${REVIEW_OWNER_LOGIN:-}"
[ -n "$OWNER" ] || red "REVIEW_OWNER_LOGIN is not set, so no finding or acknowledgement can be answered; the gate cannot decide."

HEAD_SHA="${HEAD_SHA:-}"
SHORT_HEAD="${HEAD_SHA:0:7}"

comments_feed() {
  if [ -n "${REVIEW_COMMENTS_CMD:-}" ]; then bash -c "$REVIEW_COMMENTS_CMD"; return; fi
  gh api "repos/${GITHUB_REPOSITORY}/issues/${PR_NUMBER}/comments" --paginate
}

# acknowledged: exit 0 when an owner comment acknowledges the head. Reads the
# comments only when called, so a pull request needing no acknowledgement does
# not depend on that feed.
ack_state=""
acknowledged() {
  [ -n "$ack_state" ] || check_ack
  [ "$ack_state" = "valid" ]
}

# check_ack: set ack_state to valid or none, in this shell so that red() exits
# the script.
check_ack() {
  local head frc shas sha full base tree head_tree
  head=$(git rev-parse --verify --quiet "${HEAD_SHA}^{commit}") ||
    red "The pull request head ${HEAD_SHA:-(none)} is not in this checkout; the gate cannot decide." hint
  # The feed goes to python3 in a file. Linux caps one environment string at
  # 128 KiB, which a long-lived pull request's comments feed passes. Not local:
  # the trap reads it when the script exits.
  feed_file=$(mktemp) || red "Pull request comments could not be read." hint
  trap 'rm -f "$feed_file"' EXIT
  comments_feed > "$feed_file"; frc=$?
  [ "$frc" -eq 0 ] || red "Pull request comments could not be read." hint
  shas=$(python3 - "$OWNER" "$feed_file" <<'PY'
import json, re, sys
owner = sys.argv[1]
with open(sys.argv[2], encoding='utf-8') as f:
    raw = f.read()

# `gh api --paginate` may print one array per page, so read a sequence of JSON
# documents rather than exactly one.
def documents(text):
    dec, out, i, n = json.JSONDecoder(), [], 0, len(text)
    while i < n:
        while i < n and text[i].isspace():
            i += 1
        if i >= n:
            break
        value, i = dec.raw_decode(text, i)
        out.extend(value if isinstance(value, list) else [value])
    return out

try:
    comments = documents(raw)
except Exception as exc:
    print(f'gate-decide: the comments feed is not readable JSON ({exc})', file=sys.stderr)
    sys.exit(2)
for c in comments:
    if ((c.get('user') or {}).get('login') or '') != owner:
        continue
    m = re.match(r'Accepted at ([0-9a-f]{7,40}):', c.get('body') or '')
    if m:
        print(m.group(1))
PY
  ) || red "Pull request comments could not be read." hint
  ack_state="none"
  [ -n "$shas" ] || return 0
  head_tree=$(git rev-parse "${head}^{tree}")
  base=$(git merge-base "$head" origin/main) || base=""
  while IFS= read -r sha; do
    full=$(git rev-parse --verify --quiet "${sha}^{commit}") || continue
    if [ "$full" = "$head" ]; then ack_state="valid"; return 0; fi
    [ -n "$base" ] || continue
    tree=$(git merge-tree --write-tree "$base" "$full" 2>/dev/null) || continue
    if [ "$tree" = "$head_tree" ]; then ack_state="valid"; return 0; fi
  done <<< "$shas"
}

# 4. Round cap.
cap_bugs=""; cap_sec=""
[ "${BUGS_STATE:-}" != "capped" ] || cap_bugs=1
[ "${SECURITY_STATE:-}" != "capped" ] || cap_sec=1
if [ -n "$cap_bugs$cap_sec" ] && ! acknowledged; then
  red "Round cap reached for $(angles "$cap_bugs" "$cap_sec")." hint
fi

# 5 to 7. The review threads. findings-gate.sh's stderr stays in the log: it
# names why the threads could not be read and carries no thread text.
gate_out=$(bash "$FINDINGS_GATE" "${PR_NUMBER:-}"); grc=$?
important=0
while IFS= read -r line; do
  case "$line" in
    thread=*)
      thread_lines+=("${line#thread=}")
      case "$line" in thread=important\ *) important=$((important + 1)) ;; esac ;;
  esac
done <<< "$gate_out"
case "$grc" in
  0|1) ;;
  2)
    if printf '%s\n' "$gate_out" | grep -qx 'truncated=true'; then
      red "100 or more review threads; the gate cannot decide." hint
    fi
    red "Review threads could not be read." hint ;;
  *) red "Review threads could not be read." hint ;;
esac
if [ "$important" -gt 0 ]; then
  red "$important important findings unanswered." hint
fi
if [ "$grc" -ne 0 ]; then
  red "Review threads could not be read." hint
fi

# 8. Risk tier. Anything other than Normal, a missing tier included, needs the
# acknowledgement.
if [ "${TIER:-}" != "Normal" ] && ! acknowledged; then
  red "High risk: waiting for 'Accepted at ${SHORT_HEAD}:'." hint
fi

# 9.
green "Review gate passed."
