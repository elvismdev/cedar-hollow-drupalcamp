<?php

/**
 * @file
 * Checks that the demo images in the content export reached the site intact.
 *
 * Run after a rebuild: drush php:script scripts/check-demo-images.php.
 *
 * Fails, listing each problem, when an exported Image media item or crop is
 * missing or its crop moved, an exported file is not in public://, an
 * original breaks the size caps, or a 16_9_640 derivative is not a 640x360
 * AVIF.
 */

declare(strict_types=1);

use Drupal\cedar_hollow_core\DemoImages;
use Drupal\Component\Serialization\Yaml;
use Drupal\image\Entity\ImageStyle;

$export = __DIR__ . '/../recipes/cedar_hollow_demo_content/content';

$repository = \Drupal::service('entity.repository');
$failures = [];

/**
 * Returns the default values of every exported entity of a type.
 */
$exported = static function (string $type) use ($export): array {
  $entities = [];
  foreach (glob("$export/$type/*.yml") as $file) {
    $data = Yaml::decode(file_get_contents($file));
    $entities[$data['_meta']['uuid']] = $data;
  }
  return $entities;
};

$media = array_filter($exported('media'), static fn($data) => $data['_meta']['bundle'] === 'image');
foreach (array_keys($media) as $uuid) {
  if (!$repository->loadEntityByUuid('media', $uuid)) {
    $failures[] = "media $uuid is missing";
  }
}

foreach ($exported('crop') as $uuid => $data) {
  $crop = $repository->loadEntityByUuid('crop', $uuid);
  if (!$crop) {
    $failures[] = "crop $uuid is missing";
    continue;
  }
  foreach (['x', 'y', 'width', 'height'] as $key) {
    $expected = $data['default'][$key][0]['value'] ?? NULL;
    if ($expected !== NULL && (int) $crop->get($key)->value !== (int) $expected) {
      $failures[] = "crop $uuid has $key {$crop->get($key)->value}, expected $expected";
    }
  }
}

$manifest = json_decode(file_get_contents(__DIR__ . '/demo-images.json'), TRUE, flags: JSON_THROW_ON_ERROR);
$hero_file = NULL;
foreach ($manifest as $entry) {
  if ($entry['use'] === 'hero') {
    $hero_file = $repository->loadEntityByUuid('media', $entry['uuid'])?->get('field_media_image')->entity?->getFileUri();
  }
}

$total = 0;
$sample = NULL;
foreach ($exported('file') as $data) {
  $uri = $data['default']['uri'][0]['value'];
  if (!str_starts_with($uri, DemoImages::FILES_DIR . '/')) {
    continue;
  }
  if (!file_exists($uri)) {
    $failures[] = "$uri is missing";
    continue;
  }
  $bytes = filesize($uri);
  $total += $bytes;
  $cap = $uri === $hero_file ? DemoImages::HERO_CAP : DemoImages::CAP;
  if ($bytes > $cap) {
    $failures[] = sprintf('%s is %d KB, over its %d KB cap', $uri, intdiv($bytes, 1024), intdiv($cap, 1024));
  }
  $sample ??= $uri;
}
if ($total > DemoImages::TOTAL_CAP) {
  $failures[] = sprintf('the originals total %d KB, over the %d KB cap', intdiv($total, 1024), intdiv(DemoImages::TOTAL_CAP, 1024));
}

if ($sample) {
  $style = ImageStyle::load('16_9_640');
  $derivative = $style->buildUri($sample);
  if (!file_exists($derivative)) {
    $style->createDerivative($sample, $derivative);
  }
  $size = @getimagesize($derivative);
  if (!$size || $size['mime'] !== 'image/avif' || $size[0] !== 640 || $size[1] !== 360) {
    $failures[] = "$derivative is not a 640x360 AVIF";
  }
}
else {
  $failures[] = 'no demo image files in the export';
}

if ($failures) {
  fwrite(STDERR, "Demo image check failed:\n  " . implode("\n  ", $failures) . "\n");
  exit(1);
}
printf("Demo images OK: %d media, %d KB of originals.\n", count($media), intdiv($total, 1024));
