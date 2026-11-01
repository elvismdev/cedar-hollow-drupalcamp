#!/usr/bin/env bash
# Tests for rebuild.sh with stub tools that record their arguments: the
# default form runs exactly the DDEV commands, and the REBUILD_* form runs the
# host tools against a SQLite database and a configuration copy.
set -euo pipefail
# shellcheck source=../.github/claude-review/tools/agent/test/assert.sh
. "$(dirname "$0")/../.github/claude-review/tools/agent/test/assert.sh"
SRC="$(cd "$(dirname "$0")" && pwd)/rebuild.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# A project tree holding a copy of rebuild.sh, so the test never touches this
# checkout's web/sites/default.
new_project() { # dir
  mkdir -p "$1/scripts" "$1/web/sites/default" "$1/vendor/bin" "$1/stubs"
  cp "$SRC" "$1/scripts/rebuild.sh"
  # Each stub writes one line: its name, then each argument in brackets.
  for tool in ddev composer drush; do
    cat > "$1/stubs/$tool" <<'STUB'
#!/usr/bin/env bash
{ printf '%s' "$(basename "$0")"; printf ' [%s]' "$@"; printf '\n'; } >> "$STUB_LOG"
if [ "$(basename "$0")" = composer ]; then
  echo "COMPOSER=${COMPOSER-<unset>}" >> "$STUB_ENV_LOG"
fi
exit 0
STUB
    chmod +x "$1/stubs/$tool"
  done
  ln -s ../../stubs/drush "$1/vendor/bin/drush"
}

# Default form: today's commands, byte for byte.
new_project "$WORK/default"
export STUB_LOG="$WORK/default.log" STUB_ENV_LOG="$WORK/default-env.log"
(cd "$WORK/default" && env -u COMPOSER -u REBUILD_COMPOSER -u REBUILD_DRUSH -u REBUILD_DB_URL \
  -u REBUILD_RECIPE_PATH -u REBUILD_CONFIG_DIR -u REBUILD_SKIP_IMAGE_CHECK \
  PATH="$WORK/default/stubs:$PATH" bash scripts/rebuild.sh)
expected_default="ddev [composer] [install]
ddev [drush] [site:install] [minimal] [--existing-config] [-y]
ddev [drush] [recipe] [/var/www/html/recipes/cedar_hollow_demo_content]
ddev [drush] [deploy] [-y]
ddev [drush] [php:script] [scripts/check-demo-images.php]
ddev [drush] [cr]
ddev [drush] [config:status]"
assert_eq "$expected_default" "$(cat "$STUB_LOG")" "default form runs today's commands"
assert_eq "0" "$(find "$WORK/default/web/sites/default" -type f | wc -l | tr -d ' ')" "default form writes no settings file"

# SQLite form with a configuration copy.
new_project "$WORK/sqlite"
mkdir "$WORK/config-copy"
export STUB_LOG="$WORK/sqlite.log" STUB_ENV_LOG="$WORK/sqlite-env.log"
(cd "$WORK/sqlite" && env -u COMPOSER PATH="$WORK/sqlite/stubs:$PATH" \
  REBUILD_COMPOSER=composer REBUILD_DRUSH=vendor/bin/drush \
  REBUILD_DB_URL=sqlite://localhost/sites/default/files/.ht.sqlite \
  REBUILD_RECIPE_PATH=../recipes/cedar_hollow_demo_content \
  REBUILD_CONFIG_DIR="$WORK/config-copy" REBUILD_SKIP_IMAGE_CHECK=1 \
  bash scripts/rebuild.sh)
expected_sqlite="composer [install]
drush [site:install] [minimal] [--existing-config] [--db-url=sqlite://localhost/sites/default/files/.ht.sqlite] [-y]
drush [recipe] [../recipes/cedar_hollow_demo_content]
drush [deploy] [-y]
drush [cr]
drush [config:status]"
assert_eq "$expected_sqlite" "$(cat "$STUB_LOG")" "SQLite form runs the host tools with the REBUILD_* values"
assert_eq "COMPOSER=<unset>" "$(cat "$STUB_ENV_LOG")" "composer sees no COMPOSER variable"
local_settings="$WORK/sqlite/web/sites/default/settings.local.php"
[ -f "$local_settings" ] || { echo "FAIL: settings.local.php was not written" >&2; exit 1; }
assert_contains "$(cat "$local_settings")" "\$settings['config_sync_directory'] = '$WORK/config-copy';" \
  "settings.local.php points the sync directory at the copy"
# The written file must be valid PHP that sets exactly that value.
if command -v php >/dev/null 2>&1; then
  assert_eq "$WORK/config-copy" "$(php -r '$settings = []; include $argv[1]; echo $settings["config_sync_directory"];' "$local_settings")" \
    "settings.local.php sets the sync directory when included"
else
  echo "SKIP: php not installed, settings.local.php not evaluated"
fi

# An existing settings.local.php is never overwritten.
new_project "$WORK/existing"
echo "<?php // kept" > "$WORK/existing/web/sites/default/settings.local.php"
export STUB_LOG="$WORK/existing.log"
: > "$STUB_LOG"
rc=0
(cd "$WORK/existing" && PATH="$WORK/existing/stubs:$PATH" REBUILD_COMPOSER=composer \
  REBUILD_DRUSH=vendor/bin/drush REBUILD_CONFIG_DIR="$WORK/config-copy" bash scripts/rebuild.sh) 2>/dev/null || rc=$?
[ "$rc" -ne 0 ] || { echo "FAIL: an existing settings.local.php was accepted" >&2; exit 1; }
assert_eq "<?php // kept" "$(cat "$WORK/existing/web/sites/default/settings.local.php")" "existing settings.local.php is unchanged"
assert_eq "" "$(cat "$STUB_LOG")" "no tool ran when settings.local.php already existed"

# A configuration directory that does not exist is refused before any tool runs.
new_project "$WORK/missing"
export STUB_LOG="$WORK/missing.log"
: > "$STUB_LOG"
rc=0
(cd "$WORK/missing" && PATH="$WORK/missing/stubs:$PATH" REBUILD_COMPOSER=composer \
  REBUILD_DRUSH=vendor/bin/drush REBUILD_CONFIG_DIR="$WORK/no-such-dir" bash scripts/rebuild.sh) 2>/dev/null || rc=$?
[ "$rc" -ne 0 ] || { echo "FAIL: a missing configuration directory was accepted" >&2; exit 1; }
assert_eq "" "$(cat "$STUB_LOG")" "no tool ran for a missing configuration directory"

pass rebuild.test.sh
