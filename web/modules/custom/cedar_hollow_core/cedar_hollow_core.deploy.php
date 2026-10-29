<?php

/**
 * @file
 * Deploy hooks for cedar_hollow_core, run by `drush deploy`.
 */

declare(strict_types=1);

use Drupal\cedar_hollow_core\SessionBody;
use Drupal\registration\RegistrationSettingsStorage;

/**
 * Sets the demo's one full session to a single seat with the wait list on.
 *
 * Every other session takes capacity 40 and the wait list from the
 * Registration field's default value. Registration settings are not shipped
 * as default content because they store their session's node ID, which
 * changes when the content is imported, so the session is found by UUID.
 */
function cedar_hollow_core_deploy_full_session_capacity(): string {
  $uuid = 'f3638cc1-9ff2-47d9-993a-335b30ad624c';
  $etm = \Drupal::entityTypeManager();
  $nodes = $etm->getStorage('node')->loadByProperties(['uuid' => $uuid]);
  $node = reset($nodes);
  if (!$node) {
    return "No session with UUID $uuid; nothing changed.";
  }
  $host = $etm->getHandler('node', 'registration_host_entity')->createHostEntity($node);
  $storage = $etm->getStorage('registration_settings');
  if (!$storage instanceof RegistrationSettingsStorage) {
    return 'Registration settings storage is not available; nothing changed.';
  }
  $settings = $storage->loadSettingsForHostEntity($host);
  $settings->set('status', TRUE);
  $settings->set('capacity', 1);
  $settings->set('registration_waitlist_enable', TRUE);
  $settings->save();
  return 'Set "' . $node->label() . '" to capacity 1 with the wait list on.';
}

/**
 * Converts session bodies stored in another text format to session_html.
 *
 * The session body field allows only session_html. A body in any other
 * format makes the editor pick a format before saving, which reads the
 * plain text as HTML and loses its paragraphs.
 */
function cedar_hollow_core_deploy_session_body_format(): string {
  $storage = \Drupal::entityTypeManager()->getStorage('node');
  $ids = $storage->getQuery()
    ->accessCheck(FALSE)
    ->condition('type', 'session')
    ->condition('body.format', SessionBody::FORMAT, '<>')
    ->execute();
  foreach ($storage->loadMultiple($ids) as $node) {
    $body = $node->get('body')->first()->getValue();
    $body['value'] = SessionBody::fromPlainText($body['value']);
    $body['format'] = SessionBody::FORMAT;
    $node->set('body', $body)->save();
  }
  return sprintf('Converted %d session bodies to %s.', count($ids), SessionBody::FORMAT);
}

/**
 * Gives demo images owned by anonymous to the administrator.
 *
 * The image script ran under Drush as anonymous, so the media it created
 * had no owner, unlike the demo's nodes, which belong to user 1.
 */
function cedar_hollow_core_deploy_demo_media_owner(): string {
  $storage = \Drupal::entityTypeManager()->getStorage('media');
  $ids = $storage->getQuery()
    ->accessCheck(FALSE)
    ->condition('bundle', 'image')
    ->condition('uid', 0)
    ->execute();
  foreach ($storage->loadMultiple($ids) as $media) {
    $media->setOwnerId(1)->save();
  }
  return sprintf('Gave %d image media items to user 1.', count($ids));
}
