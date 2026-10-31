#!/usr/bin/env bash
set -uo pipefail
ROOT="$(git rev-parse --show-toplevel)/.github/claude-review"
. "$ROOT/tools/agent/test/assert.sh"
R="$ROOT/tools/review/review-rounds.sh"

# review <login> <angle>: one review object as JSON.
review () { printf '{"user":{"login":"%s"},"body":"Claude %s review: 1 finding(s)."}' "$1" "$2"; }
count () { REVIEW_REVIEWS_CMD="$1" bash "$R" 7 "${2:-bugs}" 2>/dev/null; }
rc () { REVIEW_REVIEWS_CMD="$1" bash "$R" 7 "${2:-bugs}" >/dev/null 2>&1; echo $?; }
cmd () { printf 'printf %%s %q' "$1"; }

assert_eq "0" "$(count "$(cmd '[]')")" "no reviews is round 0"

bot=$(review 'github-actions[bot]' bugs)
assert_eq "1" "$(count "$(cmd "[$bot]")")" "a bugs review by the bot counts"
assert_eq "1" "$(count "$(cmd "[$(review github-actions bugs)]")")" "the login without the [bot] suffix counts too"
assert_eq "0" "$(count "$(cmd "[$bot]")" security)" "another angle's review does not count"

# Logins that merely contain the bot's are not the bot.
lookalikes="[$(review 'my-github-actions-app[bot]' bugs),$(review 'github-actions-impostor' bugs),$(review 'xgithub-actions[bot]' bugs)]"
assert_eq "0" "$(count "$(cmd "$lookalikes")")" "a login containing the bot's is not the bot"

# Pages printed one array each, as --paginate may.
assert_eq "3" "$(count "$(cmd "[$bot,$bot] [$bot,$(review someone bugs)]")")" "reviews across pages are all counted"

# A feed larger than one environment string may hold (128 KiB on Linux): a
# long-lived pull request reaches it, and a count that cannot run would fail
# every later round.
big=$(mktemp); trap 'rm -f "$big"' EXIT
python3 -I - "$big" <<'PY2'
import json, sys
pad = 'x' * 2048
reviews = [{"user": {"login": "github-actions[bot]"}, "body": f"Claude bugs review: {pad}"} for _ in range(70)]
reviews += [{"user": {"login": "repo-owner"}, "body": pad} for _ in range(30)]
open(sys.argv[1], 'w').write(json.dumps(reviews))
PY2
[ "$(stat -c %s "$big")" -gt 131072 ] || { echo "FAIL: the large feed fixture is under 128 KiB" >&2; exit 1; }
assert_eq "70" "$(count "cat $big")" "a feed over 128 KiB is counted"

# An unreadable feed is a failure, never round 0.
assert_eq "1" "$(rc 'exit 1')" "a failed feed exits non-zero"
assert_eq "1" "$(rc "$(cmd 'not json')")" "a feed that is not JSON exits non-zero"

pass
