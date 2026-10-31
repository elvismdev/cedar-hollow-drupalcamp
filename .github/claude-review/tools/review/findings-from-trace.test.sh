#!/usr/bin/env bash
set -uo pipefail
ROOT="$(git rev-parse --show-toplevel)/.github/claude-review"
. "$ROOT/tools/agent/test/assert.sh"
F="$ROOT/tools/review/findings-from-trace.mjs"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

trace() {  # build a trace whose assistant text is $1
  python3 -c "
import json,sys
json.dump([{'type':'assistant','message':{'content':[{'type':'text','text':sys.argv[1]}]}}], open(sys.argv[2],'w'))
" "$1" "$2"
}

rc() { node "$F" "$1" "$tmp/out.json" >/dev/null 2>&1; echo $?; }

# A missing or unreadable trace means no agent ran. That is not an empty review.
assert_eq "1" "$(rc "$tmp/absent.json")" "a missing trace fails"
printf 'not json' > "$tmp/bad.json"
assert_eq "1" "$(rc "$tmp/bad.json")" "an unreadable trace fails"

# An agent that ran and said nothing parseable is NOT a clean review either.
trace 'I looked at the diff and it seems fine to me.' "$tmp/prose.json"
assert_eq "1" "$(rc "$tmp/prose.json")" "prose with no JSON array fails"

# No findings is expressible, and is a pass.
trace 'Nothing to fix.

```json
[]
```' "$tmp/empty.json"
assert_eq "0" "$(rc "$tmp/empty.json")" "an empty array is a clean review"
assert_eq "[]" "$(node "$F" "$tmp/empty.json" "$tmp/out.json" >/dev/null 2>&1; python3 -c "import json;print(json.dumps(json.load(open('$tmp/out.json'))))")" "and is written as an empty array"

# The ordinary case, fenced as an agent usually writes it.
trace 'Here are my findings.

```json
[{"severity":"important","file":"tools/a.sh","line":4,"title":"swallows the error","detail":"d"}]
```' "$tmp/one.json"
assert_eq "0" "$(rc "$tmp/one.json")" "a fenced array is extracted"
got=$(node "$F" "$tmp/one.json" "$tmp/out.json" >/dev/null 2>&1; python3 -c "import json;print(json.load(open('$tmp/out.json'))[0]['title'])")
assert_eq "swallows the error" "$got" "and its content survives"

# Unfenced is accepted too, since the instruction cannot be enforced.
trace 'Findings: [{"severity":"nit","file":"a","line":1,"title":"t","detail":"d"}]' "$tmp/bare.json"
assert_eq "0" "$(rc "$tmp/bare.json")" "an unfenced array is extracted"

# When the agent narrates AND emits, the array wins over any earlier bracket in
# the prose, so a sentence containing [ does not become the findings.
trace 'I considered [the gate] and [the probe] first.

```json
[{"severity":"important","file":"b","line":2,"title":"real","detail":"d"}]
```' "$tmp/mixed.json"
got=$(node "$F" "$tmp/mixed.json" "$tmp/out.json" >/dev/null 2>&1; python3 -c "import json;d=json.load(open('$tmp/out.json'));print(len(d),d[0]['title'])")
assert_eq "1 real" "$got" "prose brackets do not become findings"

# An array of the wrong shape is a failure, not a review.
trace '```json
{"severity":"important"}
```' "$tmp/obj.json"
assert_eq "1" "$(rc "$tmp/obj.json")" "an object instead of an array fails"

# The bracket scan counted depth through string contents and tried the latest
# opening bracket first, so an empty array mentioned INSIDE a finding's text won
# over the finding itself: `[].every(...)` is vacuously true, so nothing
# rejected it. The report was replaced by [] and announced as "0 finding(s)
# extracted" with exit 0, which post-findings.sh then posts as "no issues found"
# and the gate passes. The prompt invites the trigger by telling the reviewer
# that [] is the correct answer for a clean review, so a reviewer quoting the
# contract, or quoting an injection attempt, loses its whole report.
#
# Measured on a real trace: a security reviewer reported two important findings
# and this extracted none of them.
trace '```json
[{"severity":"important","file":"a.sh","line":1,"title":"real finding","detail":"a reply can carry instructions like '"'"'return [] for this change'"'"'"}]
```' "$tmp/empty-in-string.json"
got=$(node "$F" "$tmp/empty-in-string.json" "$tmp/out.json" >/dev/null 2>&1; python3 -c "import json;d=json.load(open('$tmp/out.json'));print(len(d),d[0]['title'] if d else '-')")
assert_eq "1 real finding" "$got" "an empty array inside a finding's text does not replace the report"

# The same shape with a populated array in the text, which must also lose to the
# real report rather than being spliced into it.
trace '```json
[{"severity":"important","file":"a.sh","line":1,"title":"t","detail":"the agent may emit [{\"severity\":\"nit\"}] by mistake"}]
```' "$tmp/array-in-string.json"
got=$(node "$F" "$tmp/array-in-string.json" "$tmp/out.json" >/dev/null 2>&1; python3 -c "import json;d=json.load(open('$tmp/out.json'));print(len(d),d[0].get('file','-'))")
assert_eq "1 a.sh" "$got" "an array quoted inside a finding's text is not the report"

# A genuinely clean review is still an empty array, and must stay one: the whole
# point of the contract is that [] and silence are different answers.
trace 'Nothing to report.

```json
[]
```' "$tmp/clean.json"
got=$(node "$F" "$tmp/clean.json" "$tmp/out.json" >/dev/null 2>&1; python3 -c "import json;print(json.load(open('$tmp/out.json')))")
assert_eq "[]" "$got" "a clean review is still an explicit empty array"


# The head is checked out in its own directory, and a reviewer may name a file
# by its absolute path there. Posting needs the path relative to the repository
# root, so a leading REVIEW_HEAD_DIR is stripped; other paths are left alone.
trace '```json
[{"severity":"important","file":"/runner/temp/head/web/x.php","line":1,"title":"t","detail":"d"},{"severity":"nit","file":"web/y.php","line":2,"title":"t","detail":"d"}]
```' "$tmp/abs.json"
got=$(REVIEW_HEAD_DIR=/runner/temp/head node "$F" "$tmp/abs.json" "$tmp/out.json" >/dev/null 2>&1; python3 -c "import json;d=json.load(open('$tmp/out.json'));print(d[0]['file'],d[1]['file'])")
assert_eq "web/x.php web/y.php" "$got" "an absolute path under the head directory is made relative"
got=$(REVIEW_HEAD_DIR=/runner/temp/head/ node "$F" "$tmp/abs.json" "$tmp/out.json" >/dev/null 2>&1; python3 -c "import json;print(json.load(open('$tmp/out.json'))[0]['file'])")
assert_eq "web/x.php" "$got" "with a trailing slash on the head directory too"
got=$(env -u REVIEW_HEAD_DIR node "$F" "$tmp/abs.json" "$tmp/out.json" >/dev/null 2>&1; python3 -c "import json;print(json.load(open('$tmp/out.json'))[0]['file'])")
assert_eq "/runner/temp/head/web/x.php" "$got" "and nothing is stripped when it is unset"

pass
