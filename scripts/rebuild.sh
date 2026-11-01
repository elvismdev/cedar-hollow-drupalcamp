#!/usr/bin/env bash
# Rebuilds the local site from code: configuration, then the demo content
# recipe. Destroys the local database.
#
# With no REBUILD_* variable set it runs the DDEV commands. These optional
# variables build the same site elsewhere, for example on the host's PHP with
# SQLite:
#   REBUILD_COMPOSER          Composer command (default "ddev composer").
#   REBUILD_DRUSH             Drush command (default "ddev drush").
#   REBUILD_DB_URL            Passed to site:install --db-url when set. A
#                             SQLite path relative to the docroot needs a
#                             host, as in sqlite://localhost/sites/default/files/.ht.sqlite,
#                             because Drupal drops the host part of the URL.
#   REBUILD_RECIPE_PATH       Demo content recipe (default
#                             /var/www/html/recipes/cedar_hollow_demo_content).
#   REBUILD_CONFIG_DIR        Configuration to install from and import instead
#                             of config/. The installer and the import both
#                             read the sync directory from settings, which
#                             settings.php fixes to ../config, so this writes
#                             web/sites/default/settings.local.php to point it
#                             at the directory. An existing settings.local.php
#                             is never overwritten.
#   REBUILD_SKIP_IMAGE_CHECK  1 skips check-demo-images.php.
set -euo pipefail

read -r -a composer <<< "${REBUILD_COMPOSER:-ddev composer}"
read -r -a drush <<< "${REBUILD_DRUSH:-ddev drush}"
recipe="${REBUILD_RECIPE_PATH:-/var/www/html/recipes/cedar_hollow_demo_content}"

if [ -n "${REBUILD_CONFIG_DIR:-}" ]; then
  if [ ! -d "$REBUILD_CONFIG_DIR" ]; then
    echo "rebuild.sh: REBUILD_CONFIG_DIR $REBUILD_CONFIG_DIR is not a directory" >&2
    exit 1
  fi
  config_dir="$(cd "$REBUILD_CONFIG_DIR" && pwd)"
  case "$config_dir" in
    *"'"* | *'\'*)
      echo "rebuild.sh: REBUILD_CONFIG_DIR must not contain a quote or a backslash" >&2
      exit 1
      ;;
  esac
  local_settings="$(cd "$(dirname "$0")/.." && pwd)/web/sites/default/settings.local.php"
  if [ -e "$local_settings" ]; then
    echo "rebuild.sh: $local_settings exists; REBUILD_CONFIG_DIR never overwrites it" >&2
    exit 1
  fi
  printf "<?php\n\n// Written by scripts/rebuild.sh for REBUILD_CONFIG_DIR.\n\$settings['config_sync_directory'] = '%s';\n" \
    "$config_dir" > "$local_settings"
fi

install_args=(site:install minimal --existing-config)
if [ -n "${REBUILD_DB_URL:-}" ]; then
  install_args+=("--db-url=$REBUILD_DB_URL")
fi
install_args+=(-y)

"${composer[@]}" install
"${drush[@]}" "${install_args[@]}"
"${drush[@]}" recipe "$recipe"
"${drush[@]}" deploy -y
if [ "${REBUILD_SKIP_IMAGE_CHECK:-}" != 1 ]; then
  "${drush[@]}" php:script scripts/check-demo-images.php
fi
"${drush[@]}" cr
"${drush[@]}" config:status
