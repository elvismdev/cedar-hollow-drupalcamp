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

# An unreadable feed is a failure, never round 0.
assert_eq "1" "$(rc 'exit 1')" "a failed feed exits non-zero"
assert_eq "1" "$(rc "$(cmd 'not json')")" "a feed that is not JSON exits non-zero"

pass
