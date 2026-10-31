#!/usr/bin/env bash
# Fail while a review finding is still open on the pull request.
#
# This is the merge gate from the Claude Code team's flow: a change cannot land
# while a finding from the bug or security review is unanswered.
#
# What answers a finding: a comment by the repository owner, REVIEW_OWNER_LOGIN,
# after the finding's first comment, saying it is fixed or why it is not a
# defect. Resolving the thread does not answer it, and neither does a later
# commit outdating it: both can happen with nobody having read the finding.
#
# What never blocks: a human's own thread, a nit, and anything tagged
# pre-existing. REVIEW.md says pre-existing findings do not block, because the
# change did not introduce them and fixing them belongs in another change. An
# untagged finding is important.
#
# Machine lines for the gate, on stdout: `open=<N>`, the number of unanswered
# findings of any tag, then one `thread=<tag> <url>` for each. Exit 1 when one
# of them is important. A feed of 100 threads prints `truncated=true` and exits
# 2, so the gate can tell it from an unreadable feed.
#
# A feed that cannot be read exits 2 rather than 0. An unreadable gate reporting
# a pass is the failure this repository keeps producing, and the whole point of
# the gate is to refuse that. So does an unset REVIEW_OWNER_LOGIN, with which no
# finding could ever be answered.
#
# Usage: findings-gate.sh <pr-number>
set -uo pipefail

PR="${1:?usage: findings-gate.sh <pr-number>}"
BOT="${REVIEW_BOT_LOGIN:-github-actions}"
OWNER="${REVIEW_OWNER_LOGIN:-}"
[ -n "$OWNER" ] || { echo "findings-gate: REVIEW_OWNER_LOGIN is not set, so no finding can be answered; not reporting a pass" >&2; exit 2; }

threads_feed() {
  if [ -n "${REVIEW_THREADS_CMD:-}" ]; then bash -c "$REVIEW_THREADS_CMD"; return; fi
  gh api graphql -f query='
    query($owner:String!, $name:String!, $pr:Int!) {
      repository(owner:$owner, name:$name) {
        pullRequest(number:$pr) {
          reviewThreads(first:100) {
            nodes {
              comments(first:100){nodes{author{login} body url}}
            }
          }
        }
      }
    }' -F owner="${GITHUB_REPOSITORY%%/*}" -F name="${GITHUB_REPOSITORY##*/}" -F pr="$PR" \
    --jq '.data.repository.pullRequest.reviewThreads.nodes'
}

feed_file=$(mktemp) || { echo "findings-gate: could not create a temporary file; not reporting a pass" >&2; exit 2; }
trap 'rm -f "$feed_file"' EXIT
set +e
threads_feed > "$feed_file"; frc=$?
set -e
[ "$frc" -eq 0 ] || { echo "findings-gate: could not read the review threads; not reporting a pass" >&2; exit 2; }

# The feed travels in a file, not on stdin: `python3 -` reads its program from
# stdin, so a heredoc and a herestring cannot both be given. The first version
# of this did exactly that, which made the JSON the program and left two of this
# script's tests passing for the wrong reason. Nor in the environment: Linux
# caps one environment string at 128 KiB, which long finding bodies pass.
python3 - "$BOT" "$OWNER" "$feed_file" <<'PY' || exit $?
import json, re, sys
bot, owner = sys.argv[1], sys.argv[2]
with open(sys.argv[3], encoding='utf-8') as f:
    raw = f.read()
try:
    threads = json.loads(raw)
    if not isinstance(threads, list):
        raise ValueError('not a list of threads')
except Exception as exc:
    print(f'findings-gate: the thread feed is not readable JSON ({exc}); '
          'not reporting a pass', file=sys.stderr)
    sys.exit(2)

def severity(body):
    m = re.match(r'\s*(important|nit|pre-existing)\b', body, re.I)
    return m.group(1).lower() if m else 'important'   # untagged is treated as important

# The feed asks for 100 threads. If exactly that many come back the list may be
# truncated, and a pass computed from a truncated list is the silent miss this
# gate exists to prevent. Reported as a nit by this workflow's own review.
if len(threads) >= 100:
    print('truncated=true')
    print('findings-gate: 100 threads returned, so the list may be truncated '
          'and a pass cannot be computed from it', file=sys.stderr)
    sys.exit(2)

def login(comment):
    return ((comment.get('author') or {}).get('login') or '')

blocking, answered, reported, unanswered = [], 0, [], []
for t in threads:
    comments = ((t.get('comments') or {}).get('nodes') or [])
    if not comments:
        continue
    # Exact login, not a substring: a user or app whose name merely contains the
    # bot's would otherwise have its threads treated as review findings.
    author = login(comments[0])
    if author != bot and author != f'{bot}[bot]':
        continue
    body = (comments[0].get('body') or '').strip()
    reported.append(body)
    if any(login(c) == owner for c in comments[1:]):
        answered += 1
        continue
    tag = severity(body)
    unanswered.append((tag, comments[0].get('url') or ''))
    if tag == 'important':
        blocking.append(body)

for b in reported:
    print(f'  finding: {b.splitlines()[0][:100] if b else ""}')
print(f'findings-gate: {len(reported)} review finding(s), {answered} answered, '
      f'{len(blocking)} open and blocking')
print(f'open={len(unanswered)}')
for tag, url in unanswered:
    print(f'thread={tag} {url}')

if blocking:
    print(f'findings-gate: open findings block the merge. Fix each one or say '
          f'why it is not a defect, in a reply by {owner} on its thread.',
          file=sys.stderr)
    sys.exit(1)
PY
