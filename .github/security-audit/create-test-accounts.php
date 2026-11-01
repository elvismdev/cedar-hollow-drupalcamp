<?php

/**
 * @file
 * Creates the security audit's test accounts and writes their credentials.
 *
 * Usage: drush php:script create-test-accounts.php <output-path>
 *
 * Creates audit_authenticated, with no role beyond authenticated, and
 * audit_editor, with the demo_editor role. Each gets a 32-character password
 * from random_bytes(). Writes
 * {"accounts": [{"name": "...", "roles": ["..."], "password": "..."}]}
 * to <output-path>, where roles are the account's roles as Drupal reports
 * them. Fails before creating anything when the demo_editor role is missing.
 */

declare(strict_types=1);

use Drupal\user\Entity\Role;
use Drupal\user\Entity\User;

/**
 * The arguments after the script path, from drush php:script.
 *
 * @var array<int, string> $extra
 */
if (count($extra) !== 1 || $extra[0] === '') {
  throw new \InvalidArgumentException('Usage: drush php:script create-test-accounts.php <output-path>');
}
$output_path = $extra[0];

if (Role::load('demo_editor') === NULL) {
  throw new \RuntimeException('The demo_editor role does not exist, so audit_editor cannot be created.');
}

$accounts = [];
foreach (['audit_authenticated' => [], 'audit_editor' => ['demo_editor']] as $name => $roles) {
  // 24 random bytes are exactly 32 base64 characters, made URL-safe.
  $password = strtr(base64_encode(random_bytes(24)), '+/', '-_');
  $account = User::create([
    'name' => $name,
    'mail' => $name . '@example.invalid',
    'pass' => $password,
    'status' => 1,
    'roles' => $roles,
  ]);
  $account->save();
  $accounts[] = [
    'name' => $name,
    'roles' => $account->getRoles(),
    'password' => $password,
  ];
}

$json = json_encode(['accounts' => $accounts], JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES | JSON_THROW_ON_ERROR);
if (file_put_contents($output_path, $json . "\n") === FALSE) {
  throw new \RuntimeException("Could not write $output_path.");
}
