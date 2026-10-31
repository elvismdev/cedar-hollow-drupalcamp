#!/usr/bin/env bash
set -uo pipefail
ROOT="$(git rev-parse --show-toplevel)/.github/claude-review"
. "$ROOT/tools/agent/test/assert.sh"
P="$ROOT/tools/review/post-findings.sh"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

# The API call is captured instead of made, so the payload is asserted on.
run() { REVIEW_POST_CMD="cat > $tmp/payload.json" bash "$P" 1 bugs "$1" "$tmp/diffmap" 2>&1; }
rc()  { REVIEW_POST_CMD="cat > $tmp/payload.json" bash "$P" 1 bugs "$1" "$tmp/diffmap" >/dev/null 2>&1; echo $?; }

printf 'tools/a.php:10\ntools/a.php:11\ntools/b.php:5\n' > "$tmp/diffmap"

# An absent findings file means the agent did not run or did not comply. That
# must fail: it is indistinguishable from a clean review otherwise.
assert_eq "1" "$(rc "$tmp/missing.json")" "a missing findings file fails"
assert_contains "$(run "$tmp/missing.json")" "did not write" "and says why"

# Malformed is the same class.
printf 'not json' > "$tmp/bad.json"
assert_eq "1" "$(rc "$tmp/bad.json")" "a malformed findings file fails"

# Nothing to fix is a result, stated plainly.
printf '[]' > "$tmp/none.json"
assert_eq "0" "$(rc "$tmp/none.json")" "an empty array is a pass"
run "$tmp/none.json" >/dev/null 2>&1
assert_contains "$(cat "$tmp/payload.json")" "no issues" "and the posted body says so plainly"

# A finding on a line that is in the diff becomes an inline thread, carrying its
# severity as the first word so the gate can read it.
cat > "$tmp/one.json" <<'J'
[{"severity":"important","file":"tools/a.php","line":10,"title":"swallows the error","detail":"a 403 reads as a grant"}]
J
assert_eq "0" "$(rc "$tmp/one.json")" "a valid finding posts"
pl=$(cat "$tmp/payload.json")
assert_contains "$pl" "tools/a.php" "the payload names the file"
assert_contains "$pl" "important: swallows the error" "severity leads the body"
assert_contains "$pl" '"line": 10' "the line is carried"

# A finding whose line is not in the diff must not be lost, and must not make
# GitHub reject the whole review. It moves to the summary.
cat > "$tmp/off.json" <<'J'
[{"severity":"important","file":"tools/a.php","line":999,"title":"off the diff","detail":"d"},
 {"severity":"nit","file":"tools/b.php","line":5,"title":"in the diff","detail":"d"}]
J
assert_eq "0" "$(rc "$tmp/off.json")" "a finding off the diff still posts"
pl=$(cat "$tmp/payload.json")
assert_contains "$pl" "off the diff" "the off-diff finding survives"
assert_contains "$pl" "in the diff" "and the inline one is still inline"
# An important finding MUST become a thread wherever it lands, or the gate never
# sees it and it silently stops blocking. Reported by this workflow's own
# security review on its first run.
n=$(python3 -c "import json;print(len(json.load(open('$tmp/payload.json')).get('comments',[])))")
assert_eq "2" "$n" "the off-diff important finding is still attached to a line"
got=$(python3 -c "
import json;d=json.load(open('$tmp/payload.json'))
print([c for c in d['comments'] if 'off the diff' in c['body']][0]['body'].count('tools/a.php:999'))")
assert_eq "1" "$got" "and its real location is stated in the comment"

# A nit that cannot be attached stays in the body: nits do not block, so no
# thread is needed and a fabricated location would be worse than none.
cat > "$tmp/offnit.json" <<'J'
[{"severity":"nit","file":"tools/zz.php","line":42,"title":"stray nit","detail":"d"}]
J
assert_eq "0" "$(rc "$tmp/offnit.json")" "an unattachable nit posts"
n=$(python3 -c "import json;print(len(json.load(open('$tmp/payload.json')).get('comments',[])))")
assert_eq "0" "$n" "and stays in the body rather than being attached elsewhere"

# No addressable line at all plus an important finding: there is nowhere to put
# a thread, so this fails rather than posting a finding the gate cannot see.
: > "$tmp/emptymap"
cat > "$tmp/imp.json" <<'J'
[{"severity":"important","file":"tools/a.php","line":10,"title":"nowhere to put it","detail":"d"}]
J
REVIEW_POST_CMD="cat > $tmp/payload.json" bash "$P" 1 bugs "$tmp/imp.json" "$tmp/emptymap" >/dev/null 2>&1
assert_exit 1 "$?" "an important finding with no addressable line fails loudly"

# More than three nits is padding; the contract caps them and so does this.
python3 -c "
import json
json.dump([{'severity':'nit','file':'tools/b.php','line':5,'title':f'nit {i}','detail':'d'} for i in range(6)], open('$tmp/nits.json','w'))"
assert_eq "0" "$(rc "$tmp/nits.json")" "many nits still posts"
n=$(python3 -c "import json;print(sum(1 for c in json.load(open('$tmp/payload.json')).get('comments',[]) if c['body'].startswith('nit')))")
assert_eq "3" "$n" "nits are capped at three"

# A severity outside the taxonomy must be threaded, not quietly dropped into
# the body where the gate cannot see it.
cat > "$tmp/crit.json" <<'J'
[{"severity":"critical","file":"tools/a.php","line":10,"title":"unknown severity","detail":"d"}]
J
assert_eq "0" "$(rc "$tmp/crit.json")" "an unknown severity posts"
n=$(python3 -c "import json;print(len(json.load(open('$tmp/payload.json')).get('comments',[])))")
assert_eq "1" "$n" "and is attached to a line so the gate sees it"
assert_contains "$(cat "$tmp/payload.json")" "important: unknown severity" "treated as important"


# The review is submitted against the commit it actually read, not against
# whatever the head happens to be when the API call lands. The next round reads
# this commit_id to bound its diff, so a stamp taken at submit time would record
# a push that arrived mid-review as reviewed, and those commits would then be
# skipped by every later round: silently never reviewed by anyone.
SHA=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
REVIEW_POST_CMD="cat > $tmp/payload.json" bash "$P" 1 bugs "$tmp/none.json" "$tmp/diffmap" "$SHA" >/dev/null 2>&1
assert_contains "$(cat "$tmp/payload.json")" "\"commit_id\": \"$SHA\"" "the posted review carries the reviewed sha"

# Without one the field is omitted rather than sent empty: GitHub rejects an
# empty commit_id, and the whole review would be lost.
REVIEW_POST_CMD="cat > $tmp/payload.json" bash "$P" 1 bugs "$tmp/none.json" "$tmp/diffmap" >/dev/null 2>&1
case "$(cat "$tmp/payload.json")" in *commit_id*) cid=0;; *) cid=1;; esac
assert_exit 1 "$cid" "and no commit_id is sent when none is given"

pass
