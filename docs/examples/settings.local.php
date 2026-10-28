<?php

/**
 * @file
 * Local development settings. Copy to web/sites/default/settings.local.php.
 *
 * Loads local.services.yml (Twig debug on). Both files are ignored by git and
 * never reach Pantheon.
 */

$settings['container_yamls'][] = __DIR__ . '/local.services.yml';
