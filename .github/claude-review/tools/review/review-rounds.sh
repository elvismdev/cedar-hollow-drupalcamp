#!/usr/bin/env bash
# Count the reviews one angle has already posted on a pull request.
#
# A review counts when its author is the bot, by exact login, and its body names
# the angle ("Claude <angle> review"). The login is matched exactly, as
# reviewed-through.sh and findings-gate.sh do: an app whose name merely contains
# the bot's is not the bot, and counting its reviews would spend this angle's
# rounds.
#
# An unreadable feed exits non-zero rather than printing 0, because 0 is a
# plausible count and would hand out a fresh round on every failure.
#
# Usage: review-rounds.sh <pr-number> <angle>   (prints the count)
set -uo pipefail

PR="${1:?usage: review-rounds.sh <pr-number> <angle>}"
ANGLE="${2:?usage: review-rounds.sh <pr-number> <angle>}"
BOT="${REVIEW_BOT_LOGIN:-github-actions}"

reviews_feed() {
  if [ -n "${REVIEW_REVIEWS_CMD:-}" ]; then bash -c "$REVIEW_REVIEWS_CMD"; return; fi
  gh api "repos/${GITHUB_REPOSITORY}/pulls/${PR}/reviews" --paginate
}

# The feed goes to python3 in a file. Linux caps one environment string at
# 128 KiB, which a long-lived pull request's reviews feed passes.
feed_file=$(mktemp) || { echo "review-rounds: could not create a temporary file" >&2; exit 1; }
trap 'rm -f "$feed_file"' EXIT
reviews_feed > "$feed_file" || {
  echo "review-rounds: could not read the reviews feed for #${PR}" >&2; exit 1; }

python3 - "$BOT" "$ANGLE" "$feed_file" <<'PY'
import json, sys
bot, angle = sys.argv[1], sys.argv[2]
with open(sys.argv[3], encoding='utf-8') as f:
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
    reviews = documents(raw)
except Exception as exc:
    print(f'review-rounds: the reviews feed is not readable JSON ({exc})', file=sys.stderr)
    sys.exit(1)

marker = f'Claude {angle} review'
count = 0
for r in reviews:
    login = ((r.get('user') or {}).get('login') or '')
    if login != bot and login != f'{bot}[bot]':
        continue
    if marker in (r.get('body') or ''):
        count += 1
print(count)
PY
