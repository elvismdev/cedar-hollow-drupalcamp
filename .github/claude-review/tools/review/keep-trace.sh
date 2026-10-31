#!/usr/bin/env bash
# Keep a reviewer's execution trace, so a posted review can be audited later.
#
# The trace is the only record of what the reviewer actually said. Everything on
# the pull request is downstream of it: the summary, the threads, the gate's
# verdict. When the extractor silently replaced a report with an empty array,
# the pull request showed "no issues found" and nothing anywhere contradicted
# it. That defect is fixed; the reason it went unnoticed was that the evidence
# was discarded at the end of the job.
#
# Kept beside the findings the workflow extracted from it, and the sha it
# judged, because the audit question is whether those three agree.
#
# One refusal: a trace holding any secret the job holds. The agent is given Bash
# and passwordless sudo, and a canary showed GITHUB_TOKEN readable from agent
# Bash, so a trace that captured a secret must not become a downloadable
# artifact that outlives the job. The caller passes every secret the job holds,
# and only those: a secret that never reaches the runner cannot be in the trace,
# and sending one here only to screen for it would put it within the agent's
# reach.
#
# It fails CLOSED. Missing or unreadable inputs, a value too short to compare,
# and a grep that errors are all refusals, because the upload step runs next and
# an exit 0 here publishes whatever was not checked. A control that cannot run
# must never read like one that passed.
#
# Usage: keep-trace.sh <out-dir> <angle> <head-sha> <trace> [findings.json]
#        REVIEW_SECRETS_JSON  a JSON object of every secret the job holds, name to value
set -uo pipefail

OUT="${1:?usage: keep-trace.sh <out-dir> <angle> <head-sha> <trace> [findings.json]}"
ANGLE="${2:?angle}"
HEAD_SHA="${3:?head sha}"
TRACE="${4:?trace}"
FINDINGS="${5:-}"

if [ ! -s "$TRACE" ]; then
	echo "keep-trace: no execution trace at '$TRACE', so this review cannot be audited later. An agent that did not run is not a clean review." >&2
	exit 1
fi

mkdir -p "$OUT" || exit 1
cp "$TRACE" "$OUT/trace-${ANGLE}.json" || exit 1
[ -n "$FINDINGS" ] && [ -s "$FINDINGS" ] && cp "$FINDINGS" "$OUT/findings-${ANGLE}.json"
printf '%s\n' "$HEAD_SHA" > "$OUT/reviewed-${ANGLE}.sha"

refuse () {
	rm -rf "$OUT"
	echo "keep-trace: $1" >&2
	exit 1
}

# Every secret value, written to a pattern file so none reaches a command line
# or the process list.
#
# Filtered LINE BY LINE, not per value. A multi-line secret such as an SSH key
# becomes several patterns, and a blank line among them matches every line under
# GNU grep, which is what the runner uses: one key with a blank line in it would
# refuse every archive and fail every review. Measured on grep 3.7, after the
# same probe under this machine's ugrep wrapper returned the opposite answer.
#
# Filtering per line also keeps the control sharp rather than blunting it: the
# long base64 lines of a key are still patterns, while its BEGIN and END markers
# are dropped, and those are not secret.
MIN_SECRET_LENGTH=8
pats=$( mktemp -d )
counts=$( REVIEW_PATS="$pats" python3 - <<'PY'
import json, os, pathlib, sys
raw = os.environ.get('REVIEW_SECRETS_JSON', '')
if not raw.strip():
    print('MISSING')
    sys.exit(0)
try:
    secrets = json.loads(raw)
    if not isinstance(secrets, dict):
        raise ValueError('not an object')
except Exception as exc:
    print(f'UNREADABLE {exc}')
    sys.exit(0)

# Filtered LINE BY LINE, not per value. A multi-line secret such as an SSH key
# becomes several patterns, and a blank line among them matches every line under
# GNU grep, which is what the runner uses: one key with a blank line in it would
# refuse every archive and fail every review. Measured on grep 3.7, after the
# same probe under this machine's ugrep wrapper returned the opposite answer.
#
# Filtering per line also keeps the control sharp rather than blunting it: every
# long line of a key stays a pattern of its own. The BEGIN and END markers
# survive the length filter and are patterns too, which costs nothing: they are
# not secret, and a trace containing one carries the body as well.
#
# Each line is also matched in the form a JSON string would hold it. The trace
# IS JSON, so a value containing a quote, a backslash or a tab appears escaped
# in it and a raw comparison misses exactly the secrets most likely to contain
# those. Both forms are kept, because not every file an agent reads is JSON.
kept, short = {}, 0
for name, value in secrets.items():
    if not isinstance(value, str):
        continue
    for line in value.splitlines():
        line = line.strip()
        if not line:
            continue
        if len(line) < 8:
            short += 1
            continue
        forms = [line]
        escaped = json.dumps(line)[1:-1]
        if escaped != line:
            forms.append(escaped)
        kept.setdefault(name, []).extend(forms)

# One pattern file per secret NAME, so a match can be reported by name. A single
# combined file can only answer "something matched", which names nothing to
# rotate and nothing to judge: a true leak and a false positive would be
# indistinguishable, and the first real refusal of this control was exactly that
# situation. The name is safe to print; the value never is.
outdir = pathlib.Path(os.environ['REVIEW_PATS'])
outdir.mkdir(parents=True, exist_ok=True)
names = 0
for name, lines in kept.items():
    names += 1
    (outdir / f'{names}.pat').write_text('\n'.join(lines) + '\n')
    (outdir / f'{names}.name').write_text(name)
print(f'OK {names} {sum(len(v) for v in kept.values())} {short}')
PY
) || { rm -rf "$pats"; refuse "the secrets context could not be read, so the trace was not checked"; }

case "$counts" in
	MISSING)
		rm -rf "$pats"
		refuse "nothing to compare the trace against (REVIEW_SECRETS_JSON is empty), so it was not checked" ;;
	UNREADABLE*)
		rm -rf "$pats"
		refuse "the secrets context is not readable JSON (${counts#UNREADABLE }), so the trace was not checked" ;;
esac

read -r _ n_secrets n_patterns n_short <<<"$counts"
if [ "${n_secrets:-0}" -eq 0 ]; then
	rm -rf "$pats"
	refuse "no secret long enough to compare against (minimum ${MIN_SECRET_LENGTH} characters), so the trace was not checked"
fi

# grep's three statuses are three different answers. 0 is a match, 1 is a clean
# trace, and anything else means the check did not run: an unreadable file, or a
# glob left unexpanded. Reading that third case as "clean" would archive an
# unchecked trace, which is exactly the failure this control exists to prevent.
#
# One pass per secret, so a match names the secret. That is what makes the
# refusal actionable: it says which credential to rotate, and it lets a false
# positive be recognised as one, which a bare "something matched" cannot.
hits=""
for f in "$pats"/*.pat; do
	name=$( cat "${f%.pat}.name" )
	set +e
	grep -qFf "$f" "$OUT"/*.json
	grc=$?
	set -e
	case "$grc" in
		0) hits="$hits $name" ;;
		1) ;;
		*) rm -rf "$pats"; refuse "the secret check could not be run for ${name} (grep exited ${grc}), so nothing was archived" ;;
	esac
done
rm -rf "$pats"

if [ -n "$hits" ]; then
	refuse "the trace contains the value of:${hits}. Nothing was archived. Rotate it if it is a credential and find what the agent read it from; if the value is not actually secret, stop passing it as one."
fi

echo "keep-trace: kept $( ls "$OUT" | tr '\n' ' ' )for ${ANGLE} at ${HEAD_SHA}, checked against ${n_secrets} secret(s) as ${n_patterns} pattern(s), ${n_short} line(s) too short to compare"
