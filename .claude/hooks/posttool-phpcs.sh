#!/usr/bin/env bash
# PostToolUse (Edit|Write|MultiEdit): runs PHPCS on a changed file that the
# ruleset in phpcs.xml.dist covers. Exit 2 with the report on stderr is a
# violation; every other outcome exits 0, with a systemMessage when PHPCS
# could not run.
set -uo pipefail

DDEV_BIN=${DDEV_BIN:-ddev}
PHPCS_BIN=${PHPCS_BIN:-vendor/bin/phpcs}

cd "${CLAUDE_PROJECT_DIR:?}" || exit 0
file=$(jq -r '.tool_input.file_path // empty')
[ -n "$file" ] || exit 0
rel=${file#"$CLAUDE_PROJECT_DIR"/}

covered=$(python3 -I - "$rel" <<'PY'
import sys
import xml.etree.ElementTree as ET

rel = sys.argv[1]
try:
    root = ET.parse("phpcs.xml.dist").getroot()
except (OSError, ET.ParseError):
    sys.exit(0)
extensions = []
for arg in root.findall("arg"):
    if arg.get("name") == "extensions":
        extensions = (arg.get("value") or "").split(",")
if rel.rsplit(".", 1)[-1] not in extensions or "." not in rel:
    sys.exit(0)
for entry in root.findall("file"):
    path = (entry.text or "").strip().rstrip("/")
    if path and (rel == path or rel.startswith(path + "/")):
        print("yes")
        break
PY
)
[ "$covered" = "yes" ] || exit 0

if "$DDEV_BIN" describe -j 2>/dev/null | jq -e '.raw.status=="running"' >/dev/null 2>&1; then
  output=$("$DDEV_BIN" exec vendor/bin/phpcs --report=full "$rel" 2>&1)
elif command -v "$PHPCS_BIN" >/dev/null 2>&1; then
  output=$("$PHPCS_BIN" "$rel" 2>&1)
else
  echo '{"systemMessage": "PHPCS hook skipped: no ddev or vendor/bin/phpcs"}'
  exit 0
fi
status=$?

case "$status" in
  0) exit 0 ;;
  1|2)
    printf '%s\n' "$output" >&2
    exit 2
    ;;
  *)
    printf '{"systemMessage": "PHPCS hook could not run (exit %s)"}\n' "$status"
    exit 0
    ;;
esac
