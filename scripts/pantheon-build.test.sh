#!/usr/bin/env bash
# Pantheon's frontend build must not build Storybook. Everything under web/ is
# served on the Drupal origin, and a built Storybook preview accepts story
# updates by postMessage from any origin, so a page on another site could run
# script on the Drupal origin with a signed-in visitor's session. Storybook is
# published to GitHub Pages by .github/workflows/storybook-pages.yml instead.
set -euo pipefail
# shellcheck source=../.github/claude-review/tools/agent/test/assert.sh
. "$(dirname "$0")/../.github/claude-review/tools/agent/test/assert.sh"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Prints one line for each enabled frontend_build path whose build script runs
# a Storybook build, and nothing when none does.
storybook_builds() { # project root
  python3 - "$1" <<'PY'
import json, pathlib, re, sys, yaml
root = pathlib.Path(sys.argv[1])
doc = yaml.safe_load((root / "pantheon.yml").read_text()) or {}
build = doc.get("frontend_build") or {}
if build.get("enabled"):
    for entry in build.get("paths") or []:
        path = entry["path"]
        command = entry.get("build_command", "build")
        scripts = json.loads((root / path / "package.json").read_text()).get("scripts", {})
        script = scripts.get(command, "")
        if re.search(r"storybook\s+build|build-storybook", script):
            print(f"{path}: build_command {command} runs '{script}'")
PY
}

# Known positive: the configuration that built Storybook on Pantheon, so an
# empty result below means the check read the files, not that it missed them.
mkdir -p "$WORK/positive/web/themes/custom/cedar_hollow"
cat > "$WORK/positive/pantheon.yml" <<'YAML'
api_version: 1
frontend_build:
  enabled: true
  paths:
    - path: web/themes/custom/cedar_hollow
      node_version: 22
      build_command: build
YAML
echo '{"scripts": {"build": "storybook build -o storybook"}}' > "$WORK/positive/web/themes/custom/cedar_hollow/package.json"
assert_contains "$(storybook_builds "$WORK/positive")" "web/themes/custom/cedar_hollow: build_command build" \
  "the check finds a frontend build that runs storybook build"

found="$(storybook_builds "$ROOT")"
assert_eq "" "$found" "pantheon.yml's frontend build does not build Storybook into the docroot"

pass pantheon-build.test.sh
