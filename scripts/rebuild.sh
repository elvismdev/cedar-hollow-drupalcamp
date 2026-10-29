#!/usr/bin/env bash
# Rebuilds the local site from code: configuration, then the demo content
# recipe. Destroys the local database.
set -euo pipefail

ddev composer install
ddev drush site:install minimal --existing-config -y
ddev drush recipe /var/www/html/recipes/cedar_hollow_demo_content
ddev drush deploy -y
ddev drush php:script scripts/check-demo-images.php
ddev drush cr
ddev drush config:status
