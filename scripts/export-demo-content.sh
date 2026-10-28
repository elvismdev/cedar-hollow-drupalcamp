#!/usr/bin/env bash
# Exports the local demo content into recipes/cedar_hollow_demo_content.
#
# Author or change content locally first (scripts/seed-demo-content.php), then
# run this. The content directory is replaced, not merged.
set -euo pipefail

DIR=/var/www/html/recipes/cedar_hollow_demo_content/content
ddev exec rm -rf "$DIR"
ddev drush content:export taxonomy_term --bundle=track --dir="$DIR"
ddev drush content:export node --dir="$DIR"
ddev drush content:export menu_link_content --dir="$DIR"
ddev drush content:export canvas_page --dir="$DIR"
