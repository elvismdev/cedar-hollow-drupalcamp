#!/usr/bin/env bash
set -uo pipefail
ROOT="$(git rev-parse --show-toplevel)/.github/claude-review"
. "$ROOT/tools/agent/test/assert.sh"
K="$ROOT/tools/review/keep-trace.sh"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

mktrace () { printf '%s\n' "$2" > "$tmp/$1"; printf '%s' "$tmp/$1"; }
# Reported as a word rather than through $?, which shellcheck rightly flags
# after a condition and which reads worse besides.
kept () { if [ -s "$1" ]; then echo yes; else echo no; fi; }

run () { bash "$K" "$@" 2>&1; }
rc  () { bash "$K" "$@" >/dev/null 2>&1; echo $?; }

# The ordinary case: a trace and the findings taken from it are both kept, and
# the sha they belong to travels with them. Without the sha an archived review
# cannot be matched to the commit it judged.
export REVIEW_SECRETS_JSON='{"github_token":"placeholder-long-enough-value"}'
t=$(mktrace ok.json '{"type":"assistant"}')
printf '[]' > "$tmp/findings.json"
out="$tmp/out1"
assert_eq "0" "$(rc "$out" bugs abc1234 "$t" "$tmp/findings.json")" "a clean trace is kept"
assert_eq "yes" "$(kept "$out/trace-bugs.json")" "the trace is there"
assert_eq "yes" "$(kept "$out/findings-bugs.json")" "the findings are there"
assert_eq "abc1234" "$(cat "$out/reviewed-bugs.sha")" "and the sha it judged"

# An absent trace is the silent-skip path: claude-code-action exits success
# having run no agent, so nothing to archive means nothing to audit and the
# step must say so rather than upload an empty directory.
assert_eq "1" "$(rc "$tmp/out2" bugs abc1234 "$tmp/nope.json")" "a missing trace fails"
assert_contains "$(run "$tmp/out3" bugs abc1234 "$tmp/nope.json")" "cannot be audited" "and says why"

# An empty file is not a trace either.
: > "$tmp/empty.json"
assert_eq "1" "$(rc "$tmp/out4" bugs abc1234 "$tmp/empty.json")" "an empty trace fails"

# The control that matters, and the shape it has to have.
#
# The agent step receives every secret it is given, and a canary in this
# repository showed GITHUB_TOKEN readable from agent Bash. Screening one named
# secret leaves every other one it holds unscreened, so the trace is compared
# against all of them, taken from the secrets context rather than enumerated by
# hand: a secret added to the repository later is then covered without anyone
# remembering this file.
#
# Values come from urandom per run. A fixed string could be matched by something
# already in the fixture and the check would pass for the wrong reason.
a="ghs_$(od -An -tx1 -N20 /dev/urandom | tr -d ' \n')"
b="sk-ant-oat01-$(od -An -tx1 -N24 /dev/urandom | tr -d ' \n')"
secrets_json=$(python3 -c '
import json, sys
print(json.dumps({"github_token": sys.argv[1], "CLAUDE_CODE_OAUTH_TOKEN": sys.argv[2]}))' "$a" "$b")

export REVIEW_SECRETS_JSON="$secrets_json"

leaky_a=$(mktrace leak-a.json "{\"text\":\"the env says $a\"}")
assert_eq "1" "$(rc "$tmp/out5" bugs abc1234 "$leaky_a")" "a trace carrying the first secret is refused"
# The refusal must NAME the secret. Its first real firing on a pull request
# could not be told apart from a false positive, because "one of this job's
# secrets matched" names nothing to rotate and nothing to judge. The name is
# safe to print; the value never is.
out_a=$(run "$tmp/out6" bugs abc1234 "$leaky_a")
assert_contains "$out_a" "github_token" "the refusal names the secret that matched"
case "$out_a" in *"$a"*) leaked=0;; *) leaked=1;; esac
assert_eq "1" "$leaked" "and never prints its value"
assert_eq "no" "$(kept "$tmp/out5/trace-bugs.json")" "and nothing is left behind to upload"

# The second secret independently, or the control would pass by only ever
# comparing the first one in the list.
leaky_b=$(mktrace leak-b.json "{\"text\":\"and $b\"}")
assert_eq "1" "$(rc "$tmp/out7" bugs abc1234 "$leaky_b")" "a trace carrying the second secret is refused too"

# The allowed direction, with the same secrets set. One direction alone would
# only prove that something failed.
clean=$(mktrace clean.json '{"text":"no secrets here"}')
assert_eq "0" "$(rc "$tmp/out8" bugs abc1234 "$clean")" "a trace without any of them is kept"
assert_contains "$(run "$tmp/out9" bugs abc1234 "$clean")" "2 secret" "and says how many it compared"

# Screen-only mode, which the review job runs before posting: every file given
# is screened in place, and nothing is copied or archived. The secret is planted
# in the last file, a summary, so a screen of only the trace would miss it.
printf '[]' > "$tmp/screen-findings.json"
summary=$(mktrace screen-summary.json "{\"summary\":\"posted $b\"}")
assert_eq "1" "$(REVIEW_SCREEN_ONLY=1 rc "$tmp/screen1" bugs abc1234 "$clean" "$tmp/screen-findings.json" "$summary")" "screen-only refuses a secret in any given file"
out_s=$(REVIEW_SCREEN_ONLY=1 run "$tmp/screen2" bugs abc1234 "$clean" "$tmp/screen-findings.json" "$summary")
assert_contains "$out_s" "CLAUDE_CODE_OAUTH_TOKEN" "and names the secret"
case "$out_s" in *"$b"*) leaked=0;; *) leaked=1;; esac
assert_eq "1" "$leaked" "without printing it"
assert_eq "yes" "$(kept "$summary")" "and leaves the screened file where it was"
assert_eq "0" "$(REVIEW_SCREEN_ONLY=1 rc "$tmp/screen3" bugs abc1234 "$clean" "$tmp/screen-findings.json")" "screen-only passes files without a secret"
if [ -e "$tmp/screen1" ] || [ -e "$tmp/screen2" ] || [ -e "$tmp/screen3" ]; then copied=yes; else copied=no; fi
assert_eq "no" "$copied" "and copies nothing in either direction"
assert_eq "1" "$(REVIEW_SCREEN_ONLY=1 rc "$tmp/screen4" bugs abc1234 "$clean" "$tmp/absent.json")" "a given file that is missing is a refusal"

# A short secret value would match almost any trace. Skipped rather than
# refused, and the count is reported so the skip is not silent.
REVIEW_SECRETS_JSON=$(python3 -c '
import json, sys
print(json.dumps({"tiny": "1", "real": sys.argv[1]}))' "$a")
export REVIEW_SECRETS_JSON
assert_eq "0" "$(rc "$tmp/out10" bugs abc1234 "$clean")" "a value too short to match safely is skipped"
assert_contains "$(run "$tmp/out11" bugs abc1234 "$clean")" "too short" "and the skip is reported"

# A multi-line secret is several patterns, and a blank line among them matches
# EVERY line under GNU grep, which is what the runner and every script here use.
# Unfiltered, one PEM with a blank line in it would refuse every archive and
# fail every review job. Measured on grep 3.7: an empty pattern beside real ones
# returns 0 against a file sharing none of them. The local interactive shell
# wraps ugrep, which returns 1 for the same input and hid this.
REVIEW_SECRETS_JSON=$(python3 -c '
import json
key = "-----BEGIN OPENSSH PRIVATE KEY-----\nAAAAlongbase64lineone\n\nBBBBlongbase64linetwo\n-----END OPENSSH PRIVATE KEY-----"
print(json.dumps({"WPE_SSHG_KEY_PRIVATE": key}))')
export REVIEW_SECRETS_JSON
assert_eq "0" "$(rc "$tmp/out17" bugs abc1234 "$clean")" "a multi-line secret with a blank line does not refuse every trace"

# And the same key is still caught when the trace carries one of its real lines,
# so the filtering did not disarm the control.
carries=$(mktrace carries.json '{"text":"leaked AAAAlongbase64lineone here"}')
assert_eq "1" "$(rc "$tmp/out18" bugs abc1234 "$carries")" "a line of that key in the trace is still refused"

REVIEW_SECRETS_JSON="$secrets_json"
export REVIEW_SECRETS_JSON

# The trace is JSON, so a secret containing a quote, a backslash or a newline
# appears in it ESCAPED. Comparing only the raw value misses exactly the secrets
# most likely to contain such characters, which includes every PEM.
#
# The fixtures are built by a heredoc rather than python3 -c: these values exist
# to carry quotes and backslashes, and threading them through three levels of
# shell quoting is how the first attempt at this test broke.
python3 - "$tmp" <<'FIXTURE'
import json, pathlib, sys
out = pathlib.Path(sys.argv[1])
quoted = 'abc"def-long-enough'
slashed = 'x\\y-long-enough-value'
(out / 'secrets.json').write_text(json.dumps({'QUOTED': quoted, 'BACKSLASHED': slashed}))
# Each value as it appears INSIDE a JSON string, which is its only form in a trace.
(out / 'esc-q.json').write_text(json.dumps({'text': f'leaked {quoted} here'}))
(out / 'esc-b.json').write_text(json.dumps({'text': f'leaked {slashed} here'}))
# And a file that is not JSON at all, where the raw form is what appears.
(out / 'esc-raw.json').write_text(f'plain text with {quoted} in it')
FIXTURE
REVIEW_SECRETS_JSON=$(cat "$tmp/secrets.json")
export REVIEW_SECRETS_JSON

assert_eq "1" "$(rc "$tmp/out19" bugs abc1234 "$tmp/esc-q.json")" "a quoted secret is caught in its escaped form"
assert_contains "$(run "$tmp/out20" bugs abc1234 "$tmp/esc-q.json")" "QUOTED" "and named"
assert_eq "1" "$(rc "$tmp/out21" bugs abc1234 "$tmp/esc-b.json")" "a backslashed secret is caught in its escaped form"
assert_eq "1" "$(rc "$tmp/out22" bugs abc1234 "$tmp/esc-raw.json")" "and the raw form is still caught where the file is not JSON"

REVIEW_SECRETS_JSON="$secrets_json"
export REVIEW_SECRETS_JSON

# A grep that ERRORS is not a grep that found nothing. Exit 2 falling through to
# "clean" would archive an unchecked trace, which is this repository's own
# failure class aimed at its own control.
REVIEW_SECRETS_JSON="$secrets_json"
export REVIEW_SECRETS_JSON
# A path the glob picks up but grep cannot read. Both runs need their own copy,
# because the refusal removes the directory it was given.
mkdir -p "$tmp/out12/decoy.json" "$tmp/out13/decoy.json"
assert_eq "1" "$(rc "$tmp/out12" bugs abc1234 "$clean")" "a check that could not run is a refusal"
assert_contains "$(run "$tmp/out13" bugs abc1234 "$clean")" "could not be run" "and says the check failed rather than passed"

# Fail closed. A control whose inputs are missing has not run, and the upload
# step runs next: exiting 0 there publishes an unscreened trace.
unset REVIEW_SECRETS_JSON
assert_eq "1" "$(rc "$tmp/out14" bugs abc1234 "$clean")" "no secrets to compare is a refusal, not a pass"
assert_contains "$(run "$tmp/out15" bugs abc1234 "$clean")" "nothing to compare" "and says so"

export REVIEW_SECRETS_JSON='not json'
assert_eq "1" "$(rc "$tmp/out16" bugs abc1234 "$clean")" "an unreadable secrets context is a refusal"

pass "keep-trace.test.sh"
