#!/usr/bin/env bash
# Compiles the agenda builder and saves it as the Canvas code component.
#
# The JSX in the theme is the only source. esbuild turns it into the ES module
# Canvas runs (its import map points `react` at Preact), and
# sync-agenda-builder.php stores both versions in the code component. Export
# configuration afterwards with `ddev drush config:export -y`.
set -euo pipefail

THEME=web/themes/custom/cedar_hollow
COMPILED=/tmp/agenda-builder.compiled.js

ddev exec -d "/var/www/html/$THEME" npx esbuild agenda-builder/agenda-builder.jsx \
  --format=esm --jsx=automatic --jsx-import-source=react --outfile="$COMPILED" --log-level=warning
ddev drush php:script scripts/sync-agenda-builder.php
