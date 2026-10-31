#!/usr/bin/env bash
# Classify a pull request's risk tier as High or Normal.
#
# High when the highest ticked Risk box in the body is High, when 3000 or more
# paths changed (the pulls files API stops there, so a High path may be missing
# from the list), or when any changed path, new or previous name, matches the
# list below. Otherwise Normal, including when no box is ticked: a declared Low
# or Medium never lowers what the paths say.
#
# Patterns are matched with bash `[[ $path == $pattern ]]`, where `*` also
# matches `/`, so `.github/**` covers everything under `.github/`.
#
# Output, for $GITHUB_OUTPUT: `tier=High|Normal`, then `reason=` with the box,
# the path count, or the first matching path and its pattern.
#
# A missing input file exits 2: a tier computed from nothing would be Normal.
#
# Usage: risk-tier.sh <changed-paths-file> <body-file>
set -uo pipefail

HIGH_PATTERNS=(
  '.github/**'
  '.claude/**'
  'REVIEW.md'
  'AGENTS.md'
  'composer.json'
  'composer.lock'
  'pantheon.yml'
  'phpcs.xml.dist'
  'phpstan.neon*'
  'web/themes/custom/cedar_hollow/stylelint.config.mjs'
  'web/themes/custom/cedar_hollow/package*.json'
  'web/themes/custom/cedar_hollow/.storybook/**'
  'tests/package*.json'
  'tests/playwright.config.*'
  'scripts/check_*.py'
  'scripts/npm-audit-check.mjs'
  'scripts/npm-audit-exceptions.json'
  'scripts/rebuild.sh'
  'web/sites/**'
  'web/modules/custom/**/*.routing.yml'
  'web/modules/custom/**/*.permissions.yml'
  'config/user.role.*'
  'config/filter.format.*'
  'config/system.site.yml'
  '*.install'
  '**/*.install'
  '**/*.post_update.php'
  '**/*.deploy.php'
)
PATH_LIMIT=3000

PATHS_FILE="${1:?usage: risk-tier.sh <changed-paths-file> <body-file>}"
BODY_FILE="${2:?usage: risk-tier.sh <changed-paths-file> <body-file>}"
[ -r "$PATHS_FILE" ] || { echo "risk-tier: cannot read the changed paths file $PATHS_FILE" >&2; exit 2; }
[ -r "$BODY_FILE" ] || { echo "risk-tier: cannot read the body file $BODY_FILE" >&2; exit 2; }

# The highest ticked box, with HTML comments removed first so the template's
# commented examples never count.
declared=$(python3 - "$BODY_FILE" <<'PY'
import re, sys
with open(sys.argv[1], encoding='utf-8', errors='replace') as f:
    body = f.read()
body = re.sub(r'<!--.*?(?:-->|\Z)', '', body, flags=re.S)
rank = {'Low': 1, 'Medium': 2, 'High': 3}
ticked = re.findall(r'^\s*[-*]\s*\[[xX]\]\s*(Low|Medium|High)\b', body, flags=re.M)
print(max(ticked, key=rank.get) if ticked else '')
PY
) || { echo "risk-tier: could not read the Risk boxes" >&2; exit 2; }

if [ "$declared" = "High" ]; then
  echo "tier=High"
  echo "reason=declared Risk: High"
  exit 0
fi

paths=()
while IFS= read -r line || [ -n "$line" ]; do
  [ -n "$line" ] && paths+=("$line")
done < "$PATHS_FILE"

if [ "${#paths[@]}" -ge "$PATH_LIMIT" ]; then
  echo "tier=High"
  echo "reason=${#paths[@]} paths changed"
  exit 0
fi

for path in "${paths[@]}"; do
  for pattern in "${HIGH_PATTERNS[@]}"; do
    # shellcheck disable=SC2053 # the pattern is matched as a glob on purpose
    if [[ $path == $pattern ]]; then
      echo "tier=High"
      echo "reason=path $path matches $pattern"
      exit 0
    fi
  done
done

echo "tier=Normal"
echo "reason=no High path among ${#paths[@]}, declared Risk: ${declared:-none}"
