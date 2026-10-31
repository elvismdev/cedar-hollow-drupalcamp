#!/usr/bin/env bash
# PostToolUse (Edit|Write|MultiEdit): checks theme CSS with stylelint and
# scripts/check_css.py, and component templates and definitions with
# scripts/check_hierarchy.py. Exit 2 with the output on stderr is a violation;
# every other outcome exits 0.
set -uo pipefail

THEME=web/themes/custom/cedar_hollow
STYLELINT_BIN=${STYLELINT_BIN:-npx --no stylelint}
read -r -a stylelint <<< "$STYLELINT_BIN"

cd "${CLAUDE_PROJECT_DIR:?}" || exit 0
file=$(jq -r '.tool_input.file_path // empty')
[ -n "$file" ] || exit 0
rel=${file#"$CLAUDE_PROJECT_DIR"/}

case "$rel" in
  "$THEME"/components/*.css | "$THEME"/components/*/*.css | "$THEME"/components/*/*/*.css | \
  "$THEME"/css/*.css | "$THEME"/css/*/*.css | "$THEME"/agenda-builder/*.css | "$THEME"/agenda-builder/*/*.css)
    [ -f "$rel" ] || exit 0
    report=""
    violation=0
    skipped=0

    if (cd "$THEME" && "${stylelint[@]}" --version >/dev/null 2>&1); then
      out=$(cd "$THEME" && "${stylelint[@]}" "${rel#"$THEME"/}" 2>&1)
      if [ $? -eq 2 ]; then
        violation=1
        report+="$out"$'\n'
      fi
    else
      skipped=1
    fi

    out=$(python3 scripts/check_css.py "$rel" 2>&1)
    if [ $? -eq 1 ]; then
      violation=1
      report+="$out"$'\n'
    fi

    if [ "$violation" -eq 1 ]; then
      printf '%s' "$report" >&2
      exit 2
    fi
    if [ "$skipped" -eq 1 ]; then
      echo '{"systemMessage": "CSS hook: stylelint skipped (run npm ci in the theme); check_css.py ran"}'
    fi
    exit 0
    ;;
  "$THEME"/components/*.twig | "$THEME"/components/*/*.twig | "$THEME"/components/*/*/*.twig | \
  "$THEME"/components/*.component.yml | "$THEME"/components/*/*.component.yml | "$THEME"/components/*/*/*.component.yml)
    out=$(python3 scripts/check_hierarchy.py "$THEME/components" 2>&1)
    if [ $? -eq 1 ]; then
      printf '%s\n' "$out" >&2
      exit 2
    fi
    exit 0
    ;;
esac
exit 0
