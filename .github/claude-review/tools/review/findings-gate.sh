#!/usr/bin/env bash
# Fail while a review finding is still open on the pull request.
#
# This is the merge gate from the Claude Code team's flow: a change cannot land
# while a finding from the bug or security review is unanswered. Answering means
# fixing it, or resolving the thread with a reason, which is also how a false
# positive is cleared.
#
# What clears a finding, and why:
#   resolved  a person read it and said so, by fixing it or giving a reason
#   outdated  a later commit changed the line, so the finding no longer applies
#             and GitHub marks the thread outdated. It clears on its own.
#
# What never blocks: a human's own thread, a nit, and anything tagged
# pre-existing. REVIEW.md says pre-existing findings do not block, because the
# change did not introduce them and fixing them belongs in another change.
#
# A feed that cannot be read exits 2 rather than 0. An unreadable gate reporting
# a pass is the failure this repository keeps producing, and the whole point of
# the gate is to refuse that.
#
# Usage: findings-gate.sh <pr-number>
set -uo pipefail

PR="${1:?usage: findings-gate.sh <pr-number>}"
BOT="${REVIEW_BOT_LOGIN:-github-actions}"

threads_feed() {
  if [ -n "${REVIEW_THREADS_CMD:-}" ]; then bash -c "$REVIEW_THREADS_CMD"; return; fi
  gh api graphql -f query='
    query($owner:String!, $name:String!, $pr:Int!) {
      repository(owner:$owner, name:$name) {
        pullRequest(number:$pr) {
          reviewThreads(first:100) {
            nodes {
              isResolved
              isOutdated
              comments(first:1) { nodes { author { login } body } }
            }
          }
        }
      }
    }' -F owner="${GITHUB_REPOSITORY%%/*}" -F name="${GITHUB_REPOSITORY##*/}" -F pr="$PR" \
    --jq '[.data.repository.pullRequest.reviewThreads.nodes[]
           | {isResolved, isOutdated,
              author: (.comments.nodes[0].author.login // ""),
              body:   (.comments.nodes[0].body // "")}]'
}

set +e
feed=$(threads_feed); frc=$?
set -e
[ "$frc" -eq 0 ] || { echo "findings-gate: could not read the review threads; not reporting a pass" >&2; exit 2; }

# The feed travels in the environment, not on stdin: `python3 -` reads its
# program from stdin, so a heredoc and a herestring cannot both be given. The
# first version of this did exactly that, which made the JSON the program and
# left two of this script's tests passing for the wrong reason.
REVIEW_FEED="$feed" python3 - "$BOT" <<'PY' || exit $?
import json, os, re, sys
bot = sys.argv[1]
raw = os.environ.get('REVIEW_FEED', '')
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
    print('findings-gate: 100 threads returned, so the list may be truncated '
          'and a pass cannot be computed from it', file=sys.stderr)
    sys.exit(2)

blocking, cleared, reported = [], 0, []
for t in threads:
    # Exact login, not a substring: a user or app whose name merely contains the
    # bot's would otherwise have its threads treated as review findings.
    author = (t.get('author') or '')
    if author != bot and author != f'{bot}[bot]':
        continue
    body = (t.get('body') or '').strip()
    reported.append(body)
    if t.get('isResolved') or t.get('isOutdated'):
        cleared += 1
        continue
    if severity(body) == 'important':
        blocking.append(body)

for b in reported:
    print(f'  finding: {b.splitlines()[0][:100]}')
print(f'findings-gate: {len(reported)} review finding(s), {cleared} cleared, '
      f'{len(blocking)} open and blocking')

if blocking:
    print('findings-gate: open findings block the merge. Fix each one, or '
          'resolve its thread with a reason, which is how a false positive is '
          'cleared.', file=sys.stderr)
    sys.exit(1)
PY
