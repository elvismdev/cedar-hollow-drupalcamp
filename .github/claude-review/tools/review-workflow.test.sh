#!/usr/bin/env bash
# Structural assertions on .github/workflows/review.yml: the trigger, the
# review jobs' needs and conditions, and the gate job's if: always(). A
# fixture self-test proves the assertions pass and fail before the workflow
# exists.
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
    steps: [{run: "true"}]
  classify:
    needs: guard
    runs-on: ubuntu-24.04
    steps: [{run: "true"}]
  review-bugs:
    needs: [guard, classify]
    if: github.event.pull_request.head.repo.full_name == github.repository && !github.event.pull_request.draft
    runs-on: ubuntu-24.04
    steps: [{run: "true"}]
  review-security:
    needs: [guard, classify]
    if: \${{ github.event.pull_request.head.repo.full_name == github.repository && github.event.pull_request.draft == false }}
    runs-on: ubuntu-24.04
    steps: [{run: "true"}]
  gate:
    name: Review gate
    needs: [guard, classify, review-bugs, review-security]
$2
    runs-on: ubuntu-24.04
    steps: [{run: "true"}]
YML
}

write_fixture "$tmp/pass.yml" "    if: always()"
write_fixture "$tmp/no-always.yml" ""
write_fixture "$tmp/wrong-if.yml" "    if: success()"
sed 's/pull_request_target:/pull_request:/' "$tmp/pass.yml" > "$tmp/wrong-trigger.yml"
sed 's/needs: \[guard, classify\]/needs: [guard]/' "$tmp/pass.yml" > "$tmp/wrong-needs.yml"
sed 's/ && !github.event.pull_request.draft//' "$tmp/pass.yml" > "$tmp/no-draft.yml"

check "$tmp/pass.yml"; assert_exit 0 "$?" "passing fixture"
for f in no-always wrong-if wrong-trigger wrong-needs no-draft; do
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
