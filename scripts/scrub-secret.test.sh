#!/usr/bin/env bash
# scrub-secret.py runs in pantheon-nightly.yml before the public pantheon-smoke
# artifact is uploaded. Playwright writes a failed API request's call log, the
# x-pantheon-bot-bypass header value included, into error-context.md, and
# GitHub masks secrets in logs but not in artifacts. These cases plant a random
# token in the shapes Playwright writes it and check that none survives.
set -euo pipefail
# shellcheck source=../.github/claude-review/tools/agent/test/assert.sh
. "$(dirname "$0")/../.github/claude-review/tools/agent/test/assert.sh"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRUB="$ROOT/scripts/scrub-secret.py"
WORK="$(mktemp -d)"
trap 'chmod -R u+w "$WORK" 2>/dev/null || true; rm -rf "$WORK"' EXIT

[ -f "$SCRUB" ] || { echo "FAIL: $SCRUB does not exist" >&2; exit 1; }

# A token no file could contain unless it was planted, with characters that
# JSON and percent-encoding write differently from the plain value.
TOKEN="t$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')+/="
JSON_TOKEN="$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1])[1:-1])' "$TOKEN")"
URL_TOKEN="$(python3 -c 'import sys,urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$TOKEN")"

# has_token <dir>: prints each file under dir holding the token in any of the
# three spellings.
has_token() {
  grep -rlF -e "$TOKEN" -e "$JSON_TOKEN" -e "$URL_TOKEN" "$1" || true
}

fixture() { # dir
  local dir="$1"
  mkdir -p "$dir/test-results/smoke-agenda-api-returns-json-smoke" "$dir/a11y-results"
  # The shape of a real error-context.md from a failed request fixture call.
  cat > "$dir/test-results/smoke-agenda-api-returns-json-smoke/error-context.md" <<MD
# Instructions

- Following Playwright test failed.

# Test info

- Name: agenda.spec.ts >> agenda API returns JSON

# Error details

\`\`\`
Error: apiRequestContext.get: connect ECONNREFUSED 127.0.0.1:9
Call log:
  - → GET https://dev-cedar-hollow-demo.pantheonsite.io/api/agenda
    - user-agent: Playwright/1.64.1
    - deterrence-bypass: 1
    - x-pantheon-bot-bypass: $TOKEN
\`\`\`
MD
  cat > "$dir/test-results/.last-run.json" <<JSON
{
  "status": "failed",
  "failedTests": ["abc-123"],
  "headers": {"x-pantheon-bot-bypass": "$JSON_TOKEN"},
  "url": "https://example.invalid/?bypass=$URL_TOKEN&next=1"
}
JSON
  printf '[]\n' > "$dir/a11y-results/home.json"
  # A PNG header and bytes that are not UTF-8, with no token: left untouched.
  printf '\x89PNG\r\n\x1a\n\x00\xff\xfe\x01' > "$dir/test-results/smoke-agenda-api-returns-json-smoke/test-failed-1.png"
  # A trace is a zip: its entries are compressed, so the token cannot be found
  # or replaced in its bytes.
  python3 - "$dir/test-results/smoke-agenda-api-returns-json-smoke/trace.zip" "$TOKEN" <<'PY'
import sys, zipfile
with zipfile.ZipFile(sys.argv[1], "w", zipfile.ZIP_DEFLATED) as z:
    z.writestr("trace.network", ('{"name":"x-pantheon-bot-bypass","value":"%s"}\n' % sys.argv[2]) * 50)
PY
}

# Known positive: the fixture holds the token, so an empty has_token below
# means the scrubber removed it, not that the probe missed it.
fixture "$WORK/before"
found="$(has_token "$WORK/before")"
assert_contains "$found" "error-context.md" "the probe finds the token in error-context.md"
assert_contains "$found" ".last-run.json" "the probe finds the token in .last-run.json"

# 1. The token is replaced in every text file, the archive is removed, and
#    everything else is unchanged.
fixture "$WORK/a"
cp -a "$WORK/a" "$WORK/a.orig"
set +e
out="$(SECRET="$TOKEN" python3 "$SCRUB" --env SECRET "$WORK/a/test-results" "$WORK/a/a11y-results" "$WORK/a/missing" 2>&1)"
code=$?
set -e
assert_exit 0 "$code" "scrubbing succeeds: $out"
assert_eq "" "$(has_token "$WORK/a")" "no file holds the token after scrubbing"
case "$out" in *"$TOKEN"*|*"$JSON_TOKEN"*|*"$URL_TOKEN"*) echo "FAIL: the scrubber printed the token" >&2; exit 1;; esac
assert_contains "$out" "trace.zip" "the removed archive is named"
[ ! -e "$WORK/a/test-results/smoke-agenda-api-returns-json-smoke/trace.zip" ] \
  || { echo "FAIL: the trace archive was kept" >&2; exit 1; }
ctx=smoke-agenda-api-returns-json-smoke/error-context.md
assert_eq "$(sed "s|x-pantheon-bot-bypass: .*|x-pantheon-bot-bypass: [redacted]|" "$WORK/a.orig/test-results/$ctx")" \
  "$(cat "$WORK/a/test-results/$ctx")" "error-context.md is otherwise intact"
python3 - "$WORK/a/test-results/.last-run.json" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
assert data["headers"]["x-pantheon-bot-bypass"] == "[redacted]", data
assert data["url"] == "https://example.invalid/?bypass=[redacted]&next=1", data
assert data["failedTests"] == ["abc-123"], data
PY
cmp -s "$WORK/a.orig/a11y-results/home.json" "$WORK/a/a11y-results/home.json" \
  || { echo "FAIL: a clean file changed" >&2; exit 1; }
cmp -s "$WORK/a.orig/test-results/smoke-agenda-api-returns-json-smoke/test-failed-1.png" \
  "$WORK/a/test-results/smoke-agenda-api-returns-json-smoke/test-failed-1.png" \
  || { echo "FAIL: a binary file without the token changed" >&2; exit 1; }

# 2. A file the scrubber cannot rewrite fails the step, so the upload that
#    depends on it never runs.
if [ "$(id -u)" -ne 0 ]; then
  fixture "$WORK/b"
  chmod 0444 "$WORK/b/test-results/$ctx"
  chmod 0555 "$WORK/b/test-results/smoke-agenda-api-returns-json-smoke"
  set +e
  out="$(SECRET="$TOKEN" python3 "$SCRUB" --env SECRET "$WORK/b/test-results" 2>&1)"
  code=$?
  set -e
  assert_exit 1 "$code" "an unwritable file holding the token fails the scrub"
  assert_contains "$out" "error-context.md" "the failure names the file"
  case "$out" in *"$TOKEN"*) echo "FAIL: the scrubber printed the token" >&2; exit 1;; esac
else
  echo "skip: running as root, file permissions do not stop writes"
fi

# 3. No token configured: nothing to scrub, and the upload still happens.
fixture "$WORK/c"
set +e
out="$(SECRET="" python3 "$SCRUB" --env SECRET "$WORK/c/test-results" 2>&1)"
code=$?
set -e
assert_exit 0 "$code" "an empty token is not an error: $out"

# 4. A missing --env, or a variable that is not set at all (a misspelt name in
#    the workflow), is a usage error rather than a silent pass.
set +e
python3 "$SCRUB" "$WORK/c/test-results" >/dev/null 2>&1
code=$?
set -e
assert_exit 2 "$code" "--env is required"
set +e
env -u SCRUB_TEST_UNSET python3 "$SCRUB" --env SCRUB_TEST_UNSET "$WORK/c/test-results" >/dev/null 2>&1
code=$?
set -e
assert_exit 2 "$code" "an unset variable is refused"

pass scrub-secret.test.sh
