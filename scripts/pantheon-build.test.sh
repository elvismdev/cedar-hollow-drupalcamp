#!/usr/bin/env bash
# pantheon.yml must have no frontend_build. The theme's only build is
# Storybook, and Pantheon's frontend build writes under the web/ docroot, which
# is served on the Drupal origin. A built Storybook preview accepts story
# updates by postMessage from any origin, so a page on another site could run
# script on the Drupal origin with a signed-in visitor's session. Storybook is
# published to GitHub Pages by .github/workflows/storybook-pages.yml instead.
set -euo pipefail
# shellcheck source=../.github/claude-review/tools/agent/test/assert.sh
. "$(dirname "$0")/../.github/claude-review/tools/agent/test/assert.sh"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Prints each line of the file that opens a top-level frontend_build key.
frontend_build_keys() { # pantheon.yml
  grep -nE "^[\"']?frontend_build[\"']?[[:space:]]*:" "$1" || true
}

# Known positive: the configuration that built Storybook on Pantheon, so an
# empty result below means the check read the file, not that it missed the key.
cat > "$WORK/pantheon.yml" <<'YAML'
api_version: 1
php_version: 8.3
frontend_build:
  enabled: true
  paths:
    - path: web/themes/custom/cedar_hollow
      node_version: 22
      build_command: build
YAML
assert_contains "$(frontend_build_keys "$WORK/pantheon.yml")" "3:frontend_build:" \
  "the check finds a frontend_build key"

assert_eq "" "$(frontend_build_keys "$ROOT/pantheon.yml")" "pantheon.yml has no frontend_build"

pass pantheon-build.test.sh
