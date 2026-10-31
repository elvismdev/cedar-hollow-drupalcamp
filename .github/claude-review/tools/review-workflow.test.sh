#!/usr/bin/env bash
# Structural assertions on .github/workflows/review.yml: the trigger, the
# review jobs' needs and conditions, the gate job's if: always(), and that
# every actions/checkout step in the guard, classify, review and gate jobs
# checks out main with persist-credentials: false (full history in the review
# jobs). Under pull_request_target a checkout of the pull request head, or one
# that leaves the token in .git/config, hands the agents untrusted code or the
# token. A fixture self-test proves the assertions pass and fail before the
# workflow exists.
set -uo pipefail
ROOT="$(git rev-parse --show-toplevel)"
. "$ROOT/.github/claude-review/tools/agent/test/assert.sh"
WORKFLOW="$ROOT/.github/workflows/review.yml"

# check <workflow file>: prints each failed assertion, exits 1 if any failed.
check () {
	python3 -I - "$1" <<'PY'
import re, sys, yaml

with open(sys.argv[1]) as f:
    wf = yaml.safe_load(f)
errors = []

# PyYAML reads the bare key "on" as the boolean True.
trigger = wf.get(True, wf.get("on"))
if isinstance(trigger, str):
    events = [trigger]
elif isinstance(trigger, list):
    events = trigger
elif isinstance(trigger, dict):
    events = list(trigger)
else:
    events = []
if events != ["pull_request_target"]:
    errors.append("trigger must be pull_request_target only, got %r" % (events,))

jobs = wf.get("jobs") or {}
for name in ("review-bugs", "review-security"):
    job = jobs.get(name)
    if job is None:
        errors.append("job %s is missing" % name)
        continue
    needs = job.get("needs")
    if needs != ["guard", "classify"]:
        errors.append("%s needs must be [guard, classify], got %r" % (name, needs))
    cond = re.sub(r"\s+", " ", str(job.get("if", "")))
    if not re.search(r"head\.repo\.full_name\s*==\s*github\.repository", cond):
        errors.append("%s if: must require head repository == github.repository" % name)
    if not re.search(r"(!\s*github\.event\.pull_request\.draft|pull_request\.draft\s*==\s*false)", cond):
        errors.append("%s if: must require the pull request not to be a draft" % name)

gates = [j for j in jobs.values() if isinstance(j, dict) and j.get("name") == "Review gate"]
if len(gates) != 1:
    errors.append("expected exactly one job named 'Review gate', found %d" % len(gates))
else:
    cond = re.sub(r"[\s${}]", "", str(gates[0].get("if", "")))
    if cond != "always()":
        errors.append("Review gate if: must be always(), got %r" % gates[0].get("if"))

# Every checkout in these jobs takes main: no ref other than main, and no
# expression naming the pull request head in any of its inputs.
HEAD_REF = re.compile(r"pull_request\.head|head_ref|refs/pull/|merge_commit_sha")
checked = {n: jobs.get(n) for n in ("guard", "classify", "review-bugs", "review-security")}
for key, job in jobs.items():
    if isinstance(job, dict) and job.get("name") == "Review gate":
        checked[key] = job
for name, job in checked.items():
    if not isinstance(job, dict):
        continue
    checkouts = [st for st in (job.get("steps") or [])
                 if isinstance(st, dict) and str(st.get("uses", "")).startswith("actions/checkout@")]
    if name.startswith("review-") and not checkouts:
        errors.append("%s must check out main" % name)
    for st in checkouts:
        w = st.get("with")
        if not isinstance(w, dict):
            w = {}
        ref = w.get("ref")
        if ref is not None and str(ref) not in ("main", "refs/heads/main"):
            errors.append("%s checkout ref must be main or absent, got %r" % (name, ref))
        for k, v in w.items():
            if HEAD_REF.search(str(v)):
                errors.append("%s checkout input %s names the pull request head: %r" % (name, k, v))
        if str(w.get("persist-credentials")).lower() != "false":
            errors.append("%s checkout must set persist-credentials: false" % name)
        if name.startswith("review-") and str(w.get("fetch-depth")) != "0":
            errors.append("%s checkout must set fetch-depth: 0" % name)

# The pull request body reaches no step through env:. The runner passes env to
# the shell as environment strings, which Linux caps at 128 KiB each, and a
# body can pass that; it is read from the event file instead.
for name, job in jobs.items():
    if not isinstance(job, dict):
        continue
    for st in (job.get("steps") or []):
        env = st.get("env") if isinstance(st, dict) else None
        for k, v in (env or {}).items():
            if re.search(r"pull_request\.body", str(v)):
                errors.append("%s step env %s carries the pull request body" % (name, k))

for e in errors:
    print("FAIL: " + e, file=sys.stderr)
sys.exit(1 if errors else 0)
PY
}

tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

# write_fixture <path> <gate if line>
write_fixture () {
	cat > "$1" <<YML
name: Review
on:
  pull_request_target:
    types: [opened, synchronize, reopened, ready_for_review]
    branches: [main]
jobs:
  guard:
    runs-on: ubuntu-24.04
    steps:
      - uses: actions/checkout@v7
        with:
          ref: main
          persist-credentials: false
  classify:
    needs: guard
    runs-on: ubuntu-24.04
    steps:
      - uses: actions/checkout@v7
        with:
          persist-credentials: false # classify-persist
  review-bugs:
    needs: [guard, classify]
    if: github.event.pull_request.head.repo.full_name == github.repository && !github.event.pull_request.draft
    runs-on: ubuntu-24.04
    steps:
      - uses: actions/checkout@v7
        with:
          fetch-depth: 0 # bugs-depth
          persist-credentials: false
  review-security:
    needs: [guard, classify]
    if: \${{ github.event.pull_request.head.repo.full_name == github.repository && github.event.pull_request.draft == false }}
    runs-on: ubuntu-24.04
    steps:
      - uses: actions/checkout@v7
        with:
          fetch-depth: 0 # security-depth
          persist-credentials: false
  gate:
    name: Review gate
    needs: [guard, classify, review-bugs, review-security]
$2
    runs-on: ubuntu-24.04
    steps:
      - uses: actions/checkout@v7
        with:
          fetch-depth: 0
          persist-credentials: false # gate-persist
YML
}

write_fixture "$tmp/pass.yml" "    if: always()"
write_fixture "$tmp/no-always.yml" ""
write_fixture "$tmp/wrong-if.yml" "    if: success()"
sed 's/pull_request_target:/pull_request:/' "$tmp/pass.yml" > "$tmp/wrong-trigger.yml"
sed 's/needs: \[guard, classify\]/needs: [guard]/' "$tmp/pass.yml" > "$tmp/wrong-needs.yml"
sed 's/ && !github.event.pull_request.draft//' "$tmp/pass.yml" > "$tmp/no-draft.yml"
# A review job that checks out the pull request head.
sed 's/^\( *\)fetch-depth: 0 # bugs-depth$/\1fetch-depth: 0\n\1ref: ${{ github.event.pull_request.head.sha }}/' "$tmp/pass.yml" > "$tmp/head-ref.yml"
# A job naming the head repository in another checkout input.
sed 's/^\( *\)persist-credentials: false # classify-persist$/\1persist-credentials: false\n\1repository: ${{ github.event.pull_request.head.repo.full_name }}/' "$tmp/pass.yml" > "$tmp/head-repo.yml"
# The gate's checkout keeping persist-credentials at its default.
sed '/persist-credentials: false # gate-persist$/d' "$tmp/pass.yml" > "$tmp/no-persist.yml"
# A step taking the pull request body through env:.
sed 's/^\( *\)persist-credentials: false # classify-persist$/\1persist-credentials: false\n      - env:\n          PR_BODY: ${{ github.event.pull_request.body }}\n        run: true/' "$tmp/pass.yml" > "$tmp/body-env.yml"
# A review job with a shallow checkout.
sed '/fetch-depth: 0 # security-depth$/d' "$tmp/pass.yml" > "$tmp/shallow.yml"

check "$tmp/pass.yml"; assert_exit 0 "$?" "passing fixture"
for f in no-always wrong-if wrong-trigger wrong-needs no-draft head-ref head-repo no-persist shallow body-env; do
	out=$(check "$tmp/$f.yml" 2>&1); code=$?
	assert_exit 1 "$code" "fixture $f must fail"
	assert_contains "$out" "FAIL:" "fixture $f names its failure"
done

if [ ! -f "$WORKFLOW" ]; then
	echo "review.yml not present yet; skipping"
	exit 0
fi
check "$WORKFLOW"; assert_exit 0 "$?" "review.yml assertions"
pass
