#!/usr/bin/env bash
# Post one review's findings to the pull request as threads the gate can read.
#
# A finding becomes an inline comment, which creates a review thread. The gate
# then blocks the merge while any important thread is unresolved, and a person
# clears it by fixing the code or resolving the thread with a reason.
#
# Three properties this script exists to hold:
#
#   A missing or malformed findings file FAILS. The agent writing nothing is
#   indistinguishable from a clean review, and this repository has shipped that
#   mistake twice in other forms. Absence is never a pass.
#
#   An IMPORTANT finding always becomes a thread. GitHub rejects a whole review
#   when a comment points outside the diff, so a finding whose own line is not
#   addressable is attached to the nearest addressable line instead, with its
#   real location stated in the text. Putting it in the summary body instead
#   would leave it with no thread, and the gate reads threads, so it would stop
#   blocking without anyone deciding that. This workflow's own security review
#   reported that on its first run. Nits and pre-existing findings do not block,
#   so those stay in the body rather than being attached somewhere they are not.
#
#   An important finding with no addressable line anywhere fails the step. There
#   is nowhere to put a thread, and posting it where the gate cannot see it is
#   the failure this rule exists to prevent.
#
#   Nits are capped at three, because the reporting contract caps them and an
#   agent author fixes a nit rather than waving it off, which buys a round.
#
# Usage: post-findings.sh <pr-number> <angle> <findings.json> <diffmap> [head-sha]
#   diffmap   lines of "path:line" that are addressable in this diff
#   head-sha  the commit this review actually read. GitHub records it on the
#             review, and the next round reads it back to bound its own diff, so
#             letting the API stamp the head at submit time would record a push
#             that arrived mid-review as reviewed. Those commits would then be
#             skipped by every later round rather than reviewed late.
set -uo pipefail

PR="${1:?usage: post-findings.sh <pr> <angle> <findings.json> <diffmap>}"
ANGLE="${2:?angle}"
FILE="${3:?findings file}"
DIFFMAP="${4:?diffmap}"
HEAD_SHA="${5:-}"

[ -f "$FILE" ] || {
  echo "post-findings: the $ANGLE review did not write $FILE, so it either did not run or did not comply; refusing to report a clean review" >&2
  exit 1
}

payload=$(REVIEW_FILE="$FILE" REVIEW_DIFFMAP="$DIFFMAP" REVIEW_ANGLE="$ANGLE" REVIEW_HEAD="$HEAD_SHA" python3 - <<'PY'
import json, os, sys

try:
    findings = json.load(open(os.environ['REVIEW_FILE']))
    if not isinstance(findings, list):
        raise ValueError('not a JSON array')
except Exception as exc:
    print(f'post-findings: {os.environ["REVIEW_FILE"]} is not a readable JSON '
          f'array ({exc}); refusing to report a clean review', file=sys.stderr)
    sys.exit(1)

addressable = set()
try:
    for ln in open(os.environ['REVIEW_DIFFMAP']):
        ln = ln.strip()
        if ln:
            addressable.add(ln)
except FileNotFoundError:
    pass                      # no map means nothing is addressable; all go inline-free

angle = os.environ['REVIEW_ANGLE']
inline, body_only, nits = [], [], 0

for f in findings:
    sev = str(f.get('severity', 'important')).lower()
    # Anything outside the taxonomy is treated as important, matching what the
    # gate does with an untagged body. Without this a finding tagged "critical"
    # or "high" went to the summary with no thread, so the gate never saw it,
    # while the gate would have blocked on it had it been threaded. Reported as
    # a nit by this workflow's own review; it is in the silent-miss class.
    if sev not in ('important', 'nit', 'pre-existing'):
        sev = 'important'
    if sev == 'nit':
        nits += 1
        if nits > 3:
            continue          # the contract caps them; the rest are dropped
    path = str(f.get('file', '')).strip()
    line = f.get('line')
    title = str(f.get('title', '')).strip() or '(no title)'
    detail = str(f.get('detail', '')).strip()
    cls = str(f.get('class', '')).strip()
    text = f'{sev}: {title}\n\n{detail}'
    if cls:
        text += f'\n\nClass: {cls}. Fix every instance, not this line alone.'
    if path and isinstance(line, int) and f'{path}:{line}' in addressable:
        inline.append({'path': path, 'line': line, 'side': 'RIGHT', 'body': text})
        continue

    where = f'{path}:{line}' if path else 'no location given'

    if sev != 'important':
        # Does not block, so it needs no thread, and attaching it to a line it
        # is not about would be worse than leaving it in the summary.
        body_only.append(f'- **{sev}** `{where}` {title}\n  {detail}')
        continue

    # Important, and its own line is not addressable. Attach it anyway, nearest
    # first, so the gate sees a thread for it.
    same_file = sorted(a for a in addressable if a.rsplit(':', 1)[0] == path)
    fallback = (same_file or sorted(addressable))
    if not fallback:
        print('post-findings: an important finding cannot be attached to any '
              'line in this diff, and the gate reads threads, so posting it in '
              'the summary alone would stop it blocking. Refusing.',
              file=sys.stderr)
        sys.exit(1)
    fp, fl = fallback[0].rsplit(':', 1)
    inline.append({
        'path': fp, 'line': int(fl), 'side': 'RIGHT',
        'body': (f'{text}\n\nReported against `{where}`, which is not a line in '
                 'this diff. Attached here so it is answerable.'),
    })

counts = {}
for f in findings:
    s = str(f.get('severity', 'important')).lower()
    counts[s] = counts.get(s, 0) + 1

if not findings:
    summary = (f'Claude {angle} review: no issues found.\n\n'
               'A review with no findings does not mean the change is correct, '
               'only that this pass found nothing.')
else:
    head = ', '.join(f'{v} {k}' for k, v in sorted(counts.items()))
    summary = f'Claude {angle} review: {len(findings)} finding(s) ({head}).'
    if body_only:
        summary += ('\n\nNot attachable to a line in this diff:\n\n'
                    + '\n'.join(body_only))
    if nits > 3:
        summary += f'\n\n{nits - 3} further nit(s) dropped; the contract caps them at three.'

review = {'event': 'COMMENT', 'body': summary, 'comments': inline}
# Omitted rather than sent empty when unknown: GitHub rejects an empty
# commit_id and the whole review would be lost.
head = os.environ.get('REVIEW_HEAD', '').strip()
if head:
    review['commit_id'] = head
print(json.dumps(review, indent=2))
PY
) || exit 1

if [ -n "${REVIEW_POST_CMD:-}" ]; then
  printf '%s' "$payload" | bash -c "$REVIEW_POST_CMD"
else
  printf '%s' "$payload" \
    | gh api --method POST "repos/${GITHUB_REPOSITORY}/pulls/${PR}/reviews" --input -
fi
rc=$?
[ "$rc" -eq 0 ] || { echo "post-findings: posting the $ANGLE review failed" >&2; exit "$rc"; }

n=$(printf '%s' "$payload" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(len(d["comments"]))')
echo "post-findings: $ANGLE review posted, $n inline finding(s)"
