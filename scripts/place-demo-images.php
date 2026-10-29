<?php

/**
 * @file
 * Puts the demo images on a site.
 *
 * Creates the media with their focal points, references and embeds them,
 * and creates the hero block content and the credits link.
 *
 * Run with: drush php:script scripts/place-demo-images.php (from web/ on
 * Pantheon: ../scripts/place-demo-images.php).
 *
 * Idempotent: on a site that already has everything it changes nothing.
 * Media missing from the site is created from the files fetch-demo-images.php
 * wrote to DemoImages::FETCHED_DIR; media the content recipe already
 * imported is used as it is. Nodes are found by path alias and speaker name,
 * not UUID, so this works on DDEV, a rebuilt site and Pantheon alike.
 */

declare(strict_types=1);

use Drupal\block_content\Entity\BlockContent;
use Drupal\cedar_hollow_core\DemoImages;
use Drupal\Component\Utility\Html;
use Drupal\file\Entity\File;
use Drupal\media\Entity\Media;
use Drupal\media\MediaInterface;
use Drupal\menu_link_content\Entity\MenuLinkContent;
use Drupal\node\NodeInterface;

// Fixed so the hero placement config and every site agree on them.
$hero_block_uuid = '6f0b1a52-2c47-4c1e-9d0a-3b8f6a1c7e21';
$credits_link_uuid = 'b3d4e8a1-5f62-4a9b-8c17-2e9f0d4a6b53';
$embed_view_modes = ['16:9' => 'embed_wide', '3:2' => 'embed_photo'];

$manifest = json_decode(file_get_contents(__DIR__ . '/demo-images.json'), TRUE, flags: JSON_THROW_ON_ERROR);
$etm = \Drupal::entityTypeManager();
$repository = \Drupal::service('entity.repository');
$changes = [];

/**
 * Loads the media item for a manifest entry, creating it if it is missing.
 */
$media_for = static function (array $entry) use ($repository, &$changes): MediaInterface {
  $media = $repository->loadEntityByUuid('media', $entry['uuid']);
  if ($media instanceof MediaInterface) {
    return $media;
  }
  static $fetched;
  $fetched ??= json_decode(file_get_contents(DemoImages::FETCHED_DIR . '/fetched.json'), TRUE, flags: JSON_THROW_ON_ERROR);
  $source = $fetched[$entry['commons_page_id']] ?? throw new \RuntimeException("{$entry['commons_page_id']} was not fetched; run fetch-demo-images.php first.");

  $file_system = \Drupal::service('file_system');
  $directory = DemoImages::FILES_DIR;
  $file_system->prepareDirectory($directory, $file_system::CREATE_DIRECTORY);
  $uri = $file_system->copy(DemoImages::FETCHED_DIR . '/' . $source['file'], DemoImages::FILES_DIR . '/' . $source['file'], $file_system::EXISTS_REPLACE);
  $file = File::create(['uri' => $uri, 'status' => 1]);
  $file->save();

  $media = Media::create([
    'uuid' => $entry['uuid'],
    'bundle' => 'image',
    'name' => preg_replace('/^File:|\.[^.]+$/', '', $entry['commons_title']),
    'status' => 1,
    'field_media_image' => [
      'target_id' => $file->id(),
      'alt' => $entry['alt'],
      'width' => $source['width'],
      'height' => $source['height'],
    ],
    'field_source_url' => $source['source_url'],
    'field_creator' => $source['creator'],
    'field_licence' => $source['licence'],
    'field_licence_url' => $source['licence_url'],
    'field_verified' => !empty($entry['reviewed']),
  ]);
  $violations = $media->validate();
  if (count($violations) > 0) {
    $messages = array_map(static fn($violation) => $violation->getPropertyPath() . ': ' . strip_tags((string) $violation->getMessage()), iterator_to_array($violations));
    throw new \RuntimeException("{$entry['commons_title']} is invalid: " . implode('; ', $messages));
  }
  $media->save();

  $focal_point = \Drupal::service('focal_point.manager');
  $crop = $focal_point->getCropEntity($file, 'focal_point');
  $focal_point->saveCropEntity((float) $entry['focal']['x'], (float) $entry['focal']['y'], (int) $source['width'], (int) $source['height'], $crop);
  $changes[] = "created media {$media->label()}";
  return $media;
};

/**
 * Finds the node an entry targets: a session by alias or a speaker by name.
 */
$target_for = static function (array $entry) use ($etm): NodeInterface {
  if ($entry['use'] === 'speaker') {
    $nodes = $etm->getStorage('node')->loadByProperties(['type' => 'speaker', 'title' => $entry['target']]);
    $node = reset($nodes);
  }
  else {
    $path = \Drupal::service('path_alias.manager')->getPathByAlias($entry['target']);
    $node = preg_match('#^/node/(\d+)$#', $path, $match) ? $etm->getStorage('node')->load($match[1]) : NULL;
  }
  return $node instanceof NodeInterface ? $node : throw new \RuntimeException("No node for {$entry['target']}.");
};

/**
 * Converts a plain-text body to session_html paragraphs.
 */
$to_html = static function (string $text): string {
  $paragraphs = preg_split('/\R{2,}/', trim($text));
  return implode("\n", array_map(static fn($paragraph) => '<p>' . nl2br(Html::escape($paragraph), FALSE) . '</p>', $paragraphs));
};

$hero = NULL;
foreach ($manifest as $entry) {
  $media = $media_for($entry);
  if ($entry['use'] === 'hero') {
    $hero = $media;
    continue;
  }
  $node = $target_for($entry);

  if ($entry['use'] !== 'embed') {
    if ((int) $node->get('field_image')->target_id !== (int) $media->id()) {
      $node->set('field_image', $media->id())->save();
      $changes[] = "attached {$media->label()} to {$node->label()}";
    }
    continue;
  }

  $body = $node->get('body')->first()?->getValue() ?? ['value' => '', 'summary' => ''];
  if (str_contains($body['value'], $entry['uuid'])) {
    continue;
  }
  if (($body['format'] ?? NULL) !== 'session_html') {
    $body['value'] = $to_html($body['value']);
    $body['format'] = 'session_html';
  }
  $embed = sprintf(
    '<drupal-media data-entity-type="media" data-entity-uuid="%s" data-view-mode="%s" data-caption="%s"></drupal-media>',
    $entry['uuid'],
    $embed_view_modes[$entry['ratio']],
    Html::escape($entry['caption']),
  );
  $end = strpos($body['value'], '</p>');
  $body['value'] = $end === FALSE ? $embed . $body['value'] : substr_replace($body['value'], "\n" . $embed, $end + 4, 0);
  $node->set('body', $body)->save();
  $changes[] = "embedded {$media->label()} in {$node->label()}";
}

if ($hero && !$repository->loadEntityByUuid('block_content', $hero_block_uuid)) {
  BlockContent::create([
    'uuid' => $hero_block_uuid,
    'type' => 'hero',
    'info' => 'Front page hero',
    'field_media' => $hero->id(),
  ])->save();
  $changes[] = 'created the hero block content';
}

if (!$repository->loadEntityByUuid('menu_link_content', $credits_link_uuid)) {
  MenuLinkContent::create([
    'uuid' => $credits_link_uuid,
    'menu_name' => 'footer',
    'title' => 'Image credits',
    'link' => ['uri' => 'internal:/credits'],
    'weight' => 4,
  ])->save();
  $changes[] = 'created the Image credits footer link';
}

echo $changes ? implode("\n", $changes) . "\n" : "Nothing to change.\n";
