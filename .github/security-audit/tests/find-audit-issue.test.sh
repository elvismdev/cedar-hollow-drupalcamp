#!/usr/bin/env bash
# Tests for find-audit-issue.sh, the issue rule shared by reading the prior
# state and publishing, against fake-gh.sh.
set -euo pipefail
# shellcheck source=../../claude-review/tools/agent/test/assert.sh
. "$(dirname "$0")/../../claude-review/tools/agent/test/assert.sh"
TESTS="$(cd "$(dirname "$0")" && pwd)"
FIND="$TESTS/../find-audit-issue.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
REPO=example/repo
mkdir -p "$WORK/bin"
cp "$TESTS/fake-gh.sh" "$WORK/bin/gh"
chmod +x "$WORK/bin/gh"
export PATH="$WORK/bin:$PATH"

OPEN_KEY="repos_example_repo_issues_labels_security-audit_state_open_sort_created_direction_asc_per_page_100"
CLOSED_KEY="repos_example_repo_issues_labels_security-audit_state_closed_sort_created_direction_desc_per_page_100"
new_fixture() {
  FIX="$WORK/fix-$1"
  mkdir -p "$FIX"
  export FIX
  echo '[]' > "$FIX/$OPEN_KEY.json"
  echo '[]' > "$FIX/$CLOSED_KEY.json"
  : > "$FIX/calls.log"
}
find_issue() { RC=0; OUT="$(bash "$FIND" "$REPO" 2>/dev/null)" || RC=$?; }

# The oldest open issue, across pages and past a pull request; the closed
# list is not consulted.
new_fixture open
printf '[{"number": 1, "pull_request": {}}]\n[{"number": 3}, {"number": 5}]\n' > "$FIX/$OPEN_KEY.json"
echo '[{"number": 9}]' > "$FIX/$CLOSED_KEY.json"
find_issue
assert_eq "3" "$OUT" "the oldest open issue is picked, across pages and past a pull request"
assert_contains "$(cat "$FIX/calls.log")" "gh api --paginate repos/$REPO/issues?labels=security-audit&state=open&sort=created&direction=asc&per_page=100" "open issues are listed oldest first"
case "$(cat "$FIX/calls.log")" in *"state=closed"*) echo "FAIL: closed issues were listed although an open one exists" >&2; exit 1;; esac

# With no open issue, the newest closed one.
new_fixture closed
echo '[{"number": 12, "pull_request": {}}, {"number": 9}, {"number": 4}]' > "$FIX/$CLOSED_KEY.json"
find_issue
assert_eq "9" "$OUT" "the newest closed issue is picked when none is open"
assert_contains "$(cat "$FIX/calls.log")" "state=closed&sort=created&direction=desc" "closed issues are listed newest first"

# No issue, or only pull requests: nothing, so publishing creates one.
new_fixture none
find_issue
assert_exit 0 "$RC" "no issue is not an error"
assert_eq "" "$OUT" "no issue prints nothing"
new_fixture prs
echo '[{"number": 2, "pull_request": {}}]' > "$FIX/$OPEN_KEY.json"
find_issue
assert_eq "" "$OUT" "pull requests are never the audit issue"

# A list that cannot be read fails rather than reads as "no issue".
new_fixture error
: > "$FIX/$OPEN_KEY.500"
find_issue
assert_exit 1 "$RC" "an issue list that cannot be read fails"
assert_eq "" "$OUT" "a failed list prints nothing"

rc=0; bash "$FIND" "not a repo" >/dev/null 2>&1 || rc=$?
assert_exit 2 "$rc" "a malformed repository is refused"

pass find-audit-issue.test.sh
