#!/usr/bin/env bash
set -uo pipefail
ROOT="$(git rev-parse --show-toplevel)"
. "$ROOT/tools/agent/test/assert.sh"
G="$ROOT/tools/review/findings-gate.sh"

# The thread feed is injected, so every arm is exercised without a pull request.
run() { REVIEW_THREADS_CMD="$1" bash "$G" 1 2>&1; }
rc()  { REVIEW_THREADS_CMD="$1" bash "$G" 1 >/dev/null 2>&1; echo $?; }

BOT='github-actions'
none='printf "[]"'
assert_eq "0" "$(rc "$none")" "no threads is a pass"

open="printf '[{\"isResolved\":false,\"isOutdated\":false,\"author\":\"$BOT\",\"body\":\"important: a thing\"}]'"
assert_eq "1" "$(rc "$open")" "an open finding blocks"
assert_contains "$(run "$open")" "a thing" "and names it"

resolved="printf '[{\"isResolved\":true,\"isOutdated\":false,\"author\":\"$BOT\",\"body\":\"important: fixed\"}]'"
assert_eq "0" "$(rc "$resolved")" "a resolved thread does not block"

# The article's behaviour: a later commit that changes the line marks the thread
# outdated, and the finding clears on its own.
outdated="printf '[{\"isResolved\":false,\"isOutdated\":true,\"author\":\"$BOT\",\"body\":\"important: moved\"}]'"
assert_eq "0" "$(rc "$outdated")" "an outdated thread clears itself"

# A human's own comment thread is not a review finding and must not block.
human="printf '[{\"isResolved\":false,\"isOutdated\":false,\"author\":\"elvismdev\",\"body\":\"what about this\"}]'"
assert_eq "0" "$(rc "$human")" "a human thread does not block"

# Pre-existing findings are reported and never block, per REVIEW.md.
pre="printf '[{\"isResolved\":false,\"isOutdated\":false,\"author\":\"$BOT\",\"body\":\"pre-existing: old bug\"}]'"
assert_eq "0" "$(rc "$pre")" "a pre-existing finding does not block"
assert_contains "$(run "$pre")" "pre-existing" "though it is still reported"

# A nit does not block either. Only important findings do.
nit="printf '[{\"isResolved\":false,\"isOutdated\":false,\"author\":\"$BOT\",\"body\":\"nit: naming\"}]'"
assert_eq "0" "$(rc "$nit")" "a nit does not block"

# Mixed: one important among cleared ones still blocks, and the count is right.
mixed="printf '[{\"isResolved\":true,\"isOutdated\":false,\"author\":\"$BOT\",\"body\":\"important: done\"},{\"isResolved\":false,\"isOutdated\":false,\"author\":\"$BOT\",\"body\":\"important: still open\"},{\"isResolved\":false,\"isOutdated\":false,\"author\":\"$BOT\",\"body\":\"nit: minor\"}]'"
assert_eq "1" "$(rc "$mixed")" "one open important among cleared ones blocks"
assert_contains "$(run "$mixed")" "still open" "and names the one that blocks"

# A feed that cannot be read is not a pass. This is the whole class of failure
# this repository keeps finding: absence read as safety.
broken='printf "not json"'
assert_eq "2" "$(rc "$broken")" "an unreadable feed fails rather than passing"
fails='exit 7'
assert_eq "2" "$(rc "$fails")" "a feed command that fails is not a pass"

# The bot login is matched exactly, so a lookalike author's thread is not
# treated as a review finding.
look="printf '[{\"isResolved\":false,\"isOutdated\":false,\"author\":\"github-actions-helper\",\"body\":\"important: not ours\"}]'"
assert_eq "0" "$(rc "$look")" "a lookalike author does not block"

# The real app login carries a [bot] suffix and must still match.
suffixed="printf '[{\"isResolved\":false,\"isOutdated\":false,\"author\":\"github-actions[bot]\",\"body\":\"important: ours\"}]'"
assert_eq "1" "$(rc "$suffixed")" "the [bot] suffixed login still blocks"

# A feed of exactly 100 may be truncated, and a pass cannot be computed from it.
full=$(python3 -c "
import json
print(repr(json.dumps([{'isResolved':True,'isOutdated':False,'author':'github-actions','body':'nit: x'}]*100)))")
assert_eq "2" "$(rc "printf '%s' $full")" "a possibly truncated feed is not a pass"

pass
