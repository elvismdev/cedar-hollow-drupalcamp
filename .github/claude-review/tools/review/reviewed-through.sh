#!/usr/bin/env bash
# Report the commit this angle's last review was posted against.
#
# A re-review that reads the whole change again finds a few more old things
# every round, which is how an agent author and an agent reviewer keep each
# other busy. Reading only what arrived since the last round is what stops it,
# and this is where that boundary comes from.
#
# Nothing is written to find it. GitHub already records the head each review was
# submitted against, as commit_id on the reviews feed, so there is no marker to
# post, to parse or to drift from the thing it describes.
#
# The recorded sha is not trusted on sight. A force-push can leave a sha the
# checkout no longer has, and a rebase or an amend leaves one that exists but is
# no longer an ancestor of the head: a diff bounded by either is computed across
# a history that was discarded, and it would silently hide commits rather than
# fail. Both fall back to a full review, which costs a round and hides nothing.
#
# Three states, printed as lines for $GITHUB_OUTPUT:
#   full         no usable prior round, so review the whole change
#   incremental  review since-sha..head
#   current      the head has already been reviewed by this angle
#
# An unreadable feed exits non-zero rather than reporting `full`, because `full`
# is a plausible outcome and the failure would never be noticed.
#
# Usage: reviewed-through.sh <pr-number> <angle> <head-sha>
set -uo pipefail

PR="${1:?usage: reviewed-through.sh <pr-number> <angle> <head-sha>}"
ANGLE="${2:?angle}"
HEAD_SHA="${3:?head sha}"
BOT="${REVIEW_BOT_LOGIN:-github-actions}"

reviews_feed() {
  if [ -n "${REVIEW_REVIEWS_CMD:-}" ]; then bash -c "$REVIEW_REVIEWS_CMD"; return; fi
  gh api "repos/${GITHUB_REPOSITORY}/pulls/${PR}/reviews" --paginate
}

set +e
feed=$(reviews_feed); frc=$?
set -e
[ "$frc" -eq 0 ] || {
  echo "reviewed-through: could not read the reviews feed for #${PR}" >&2; exit 1; }

# The newest review of THIS angle by the bot. The angles converge separately,
# so another angle's round says nothing about what this one has read.
prior=$(REVIEW_FEED="$feed" python3 - "$BOT" "$ANGLE" <<'PY'
import json, os, sys
bot, angle = sys.argv[1], sys.argv[2]
raw = os.environ.get('REVIEW_FEED', '')

# A sequence of JSON documents, not one. `gh api --paginate` merges array pages
# into a single array in the version measured here, prints one array per page
# with --jq, and nests them with --slurp, so the shape depends on a tool version
# this repository does not pin. Reading whatever arrives costs eight lines and
# removes the dependency; betting on one shape would break the review pipeline
# on the first pull request long enough to paginate.
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
    reviews = documents(raw)
except Exception as exc:
    print(f'reviewed-through: the reviews feed is not readable JSON ({exc})',
          file=sys.stderr)
    sys.exit(1)

marker = f'Claude {angle} review'
mine = []
for r in reviews:
    # Exact login, not a substring, for the same reason the gate matches
    # exactly: an app whose name merely contains the bot's is not the bot.
    login = ((r.get('user') or {}).get('login') or '')
    if login != bot and login != f'{bot}[bot]':
        continue
    if marker not in (r.get('body') or ''):
        continue
    if not r.get('commit_id'):
        continue
    mine.append((r.get('submitted_at') or '', r['commit_id']))

if not mine:
    sys.exit(0)
print(max(mine)[1])
PY
) || exit $?

if [ -z "$prior" ]; then
  echo "state=full"
  echo "since="
  echo "reviewed-through: no prior ${ANGLE} review on #${PR}, reviewing the whole change" >&2
  exit 0
fi

if ! git cat-file -e "${prior}^{commit}" 2>/dev/null; then
  echo "state=full"
  echo "since="
  echo "reviewed-through: ${prior} is not in this checkout, so it cannot bound a diff; reviewing the whole change" >&2
  exit 0
fi

if ! git merge-base --is-ancestor "$prior" "$HEAD_SHA" 2>/dev/null; then
  echo "state=full"
  echo "since="
  echo "reviewed-through: ${prior} is not an ancestor of ${HEAD_SHA}, so the history it was reviewed on was discarded; reviewing the whole change" >&2
  exit 0
fi

if [ "$(git rev-parse "$prior")" = "$(git rev-parse "$HEAD_SHA")" ]; then
  echo "state=current"
  echo "since="
  echo "reviewed-through: ${ANGLE} has already reviewed ${HEAD_SHA}" >&2
  exit 0
fi

echo "state=incremental"
echo "since=$prior"
echo "reviewed-through: ${ANGLE} last read through ${prior}, reviewing ${prior}..${HEAD_SHA}" >&2
