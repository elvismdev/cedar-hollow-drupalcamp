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
# An update that only merged main into the branch is not new work. The base is
# the newest main commit the head contains, M = merge-base(head, origin/main),
# not main at run time, and T = merge-tree --write-tree M <last reviewed> is
# what the head would be with no new work. When T is the head's tree there is
# nothing to review. Otherwise the diff is taken from T, which holds the
# branch's new work and any conflict resolution but not what main brought in.
# A merge-tree that conflicts has no T, so the whole change is reviewed.
#
# Three states, printed as lines for $GITHUB_OUTPUT with since and diff_from:
#   full         no usable prior round, so review the whole change
#   incremental  review since-sha..head, with the diff taken from diff_from
#   current      the head has already been reviewed by this angle, or differs
#                from it only by a clean merge of main
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

# The feed goes to python3 in a file. Linux caps one environment string at
# 128 KiB, which a long-lived pull request's reviews feed passes.
feed_file=$(mktemp) || { echo "reviewed-through: could not create a temporary file" >&2; exit 1; }
trap 'rm -f "$feed_file"' EXIT
set +e
reviews_feed > "$feed_file"; frc=$?
set -e
[ "$frc" -eq 0 ] || {
  echo "reviewed-through: could not read the reviews feed for #${PR}" >&2; exit 1; }

# The newest review of THIS angle by the bot. The angles converge separately,
# so another angle's round says nothing about what this one has read.
prior=$(python3 - "$BOT" "$ANGLE" "$feed_file" <<'PY'
import json, sys
bot, angle = sys.argv[1], sys.argv[2]
with open(sys.argv[3], encoding='utf-8') as f:
    raw = f.read()

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
  echo "diff_from="
  echo "reviewed-through: no prior ${ANGLE} review on #${PR}, reviewing the whole change" >&2
  exit 0
fi

if ! git cat-file -e "${prior}^{commit}" 2>/dev/null; then
  echo "state=full"
  echo "since="
  echo "diff_from="
  echo "reviewed-through: ${prior} is not in this checkout, so it cannot bound a diff; reviewing the whole change" >&2
  exit 0
fi

if ! git merge-base --is-ancestor "$prior" "$HEAD_SHA" 2>/dev/null; then
  echo "state=full"
  echo "since="
  echo "diff_from="
  echo "reviewed-through: ${prior} is not an ancestor of ${HEAD_SHA}, so the history it was reviewed on was discarded; reviewing the whole change" >&2
  exit 0
fi

if [ "$(git rev-parse "$prior")" = "$(git rev-parse "$HEAD_SHA")" ]; then
  echo "state=current"
  echo "since="
  echo "diff_from="
  echo "reviewed-through: ${ANGLE} has already reviewed ${HEAD_SHA}" >&2
  exit 0
fi

M=$(git merge-base "$HEAD_SHA" origin/main) || {
  echo "reviewed-through: ${HEAD_SHA} has no merge base with origin/main" >&2; exit 1; }
set +e
T=$(git merge-tree --write-tree "$M" "$prior"); mrc=$?
set -e
case "$mrc" in
  0) ;;
  1)
    echo "state=full"
    echo "since="
    echo "diff_from="
    echo "reviewed-through: ${prior} does not merge cleanly with ${M}, so the update cannot be told apart from main's changes; reviewing the whole change" >&2
    exit 0 ;;
  *)
    echo "reviewed-through: git merge-tree ${M} ${prior} failed (exit ${mrc})" >&2
    exit 1 ;;
esac

if [ "$T" = "$(git rev-parse "${HEAD_SHA}^{tree}")" ]; then
  echo "state=current"
  echo "since="
  echo "diff_from="
  echo "reviewed-through: ${HEAD_SHA} is ${prior} merged cleanly with ${M}, with no new work" >&2
  exit 0
fi

echo "state=incremental"
echo "since=$prior"
echo "diff_from=$T"
echo "reviewed-through: ${ANGLE} last read through ${prior}, reviewing ${prior}..${HEAD_SHA} with the diff from ${T}" >&2
