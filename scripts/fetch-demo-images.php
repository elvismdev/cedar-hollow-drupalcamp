<?php

/**
 * @file
 * Fetches the demo photos listed in scripts/demo-images.json from Commons.
 *
 * Run once on DDEV: ddev drush php:script scripts/fetch-demo-images.php.
 *
 * Writes <page id>.<extension> and fetched.json to DemoImages::FETCHED_DIR in
 * the web container. Commons scales renditions only to fixed steps (a request
 * between steps gets the next step up) and serves the original above
 * 1920 px. The others step down from the 2560 px box to 1920 and then
 * 1280 px, the width of the largest non-hero image style. The hero needs
 * 2304 px, which Commons only offers as the original; when the original is
 * wider or larger than the cap, the site's image toolkit scales it to 2304 px
 * wide here, the one image resized before Drupal.
 *
 * Refuses a file whose licence is outside CC0, public domain and CC BY, that
 * carries the personality-rights template, names no creator, or cannot meet
 * the size caps. Exits non-zero, listing each refusal.
 */

declare(strict_types=1);

use Drupal\cedar_hollow_core\DemoImages;

$api = 'https://commons.wikimedia.org/w/api.php';
$options = [
  'headers' => ['User-Agent' => 'CedarHollowDemo/1.0 (https://github.com/elvismdev/cedar-hollow-drupalcamp; portfolio demo)'],
  'timeout' => 120,
];
// Commons gives no licence URL for public domain files.
$public_domain_url = 'https://creativecommons.org/publicdomain/mark/1.0/';

$manifest = json_decode(file_get_contents(__DIR__ . '/demo-images.json'), TRUE, flags: JSON_THROW_ON_ERROR);
$client = \Drupal::httpClient();

/**
 * Maps a Commons LicenseShortName to a field_licence value, or NULL.
 */
$licence = static function (string $short): ?string {
  return match (TRUE) {
    in_array($short, ['CC0', 'CC0 1.0'], TRUE) => 'cc0',
    $short === 'Public domain' || str_starts_with($short, 'PD-') => 'public_domain',
    in_array($short, ['CC BY 2.0', 'CC BY 2.5', 'CC BY 3.0', 'CC BY 4.0'], TRUE) => 'cc_by',
    default => NULL,
  };
};

/**
 * Asks Commons about one file; $params add to or replace the defaults.
 */
$info = static function (int $page_id, array $params) use ($client, $options, $api): array {
  $query = $params + [
    'action' => 'query',
    'pageids' => $page_id,
    'format' => 'json',
    'formatversion' => 2,
    'prop' => 'imageinfo|templates|info',
    'inprop' => 'url',
    'tlnamespace' => 10,
    'tllimit' => 'max',
    'iiprop' => 'url|size|extmetadata|timestamp|mime',
  ];
  $response = $client->get($api, $options + ['query' => $query]);
  return json_decode((string) $response->getBody(), TRUE, flags: JSON_THROW_ON_ERROR)['query']['pages'][0];
};

if (!is_dir(DemoImages::FETCHED_DIR)) {
  mkdir(DemoImages::FETCHED_DIR, 0775, TRUE);
}
$fetched = [];
$refused = [];
$total = 0;
foreach ($manifest as $entry) {
  $id = $entry['commons_page_id'];
  $hero = $entry['use'] === 'hero';
  $page = $info($id, ['iiurlwidth' => 2560, 'iiurlheight' => 2560]);
  $image = $page['imageinfo'][0];
  $meta = $image['extmetadata'];
  $short = $meta['LicenseShortName']['value'] ?? '';
  $templates = array_column($page['templates'] ?? [], 'title');

  $value = $licence($short);
  if ($value === NULL) {
    $refused[] = "$id: licence '$short' is not CC0, public domain or CC BY";
    continue;
  }
  if (in_array('Template:Personality rights', $templates, TRUE)) {
    $refused[] = "$id: carries the personality-rights template";
    continue;
  }
  if ($hero && ($image['width'] < DemoImages::HERO_WIDTH || $image['width'] <= $image['height'])) {
    $refused[] = "$id: the hero must be landscape and at least " . DemoImages::HERO_WIDTH . ' px wide';
    continue;
  }
  // A new revision may carry a different licence or photo, so it is not
  // downloaded until the manifest is updated after reading it again.
  if ($entry['revision_timestamp'] !== $image['timestamp']) {
    $refused[] = "$id: Commons revision {$image['timestamp']} differs from the manifest's {$entry['revision_timestamp']}; read the licence again";
    continue;
  }

  // Museum uploads name the required attribution in Attribution, not Artist.
  $creator = trim(html_entity_decode(strip_tags($meta['Artist']['value'] ?? $meta['Attribution']['value'] ?? ''), ENT_QUOTES | ENT_HTML5));
  // A user link carries "(talk · contribs)" after the name.
  $creator = trim(preg_replace('/\s*\(talk\s*·\s*contribs\)$/u', '', $creator));
  // "Own work" means the first uploader made the photo.
  if (strcasecmp($creator, 'own work') === 0) {
    $first = $info($id, [
      'prop' => 'imageinfo',
      'iiprop' => 'user',
      'iilimit' => 1,
      'iidir' => 'newer',
    ]);
    $creator = preg_replace('/~commonswiki$/', '', $first['imageinfo'][0]['user'] ?? '');
  }
  if ($creator === '') {
    $refused[] = "$id: Commons names no creator or attribution";
    continue;
  }

  $cap = $hero ? DemoImages::HERO_CAP : DemoImages::CAP;
  $body = (string) $client->get($hero ? $image['url'] : $image['thumburl'], $options)->getBody();
  if ($hero && ($image['width'] > DemoImages::HERO_WIDTH || strlen($body) > $cap)) {
    $original = DemoImages::FETCHED_DIR . "/$id.original";
    // The toolkit keeps the original's type, so the copy has no extension.
    $scaled_path = DemoImages::FETCHED_DIR . "/$id.scaled";
    file_put_contents($original, $body);
    $scaled = \Drupal::service('image.factory')->get($original);
    $scaled->scale(DemoImages::HERO_WIDTH);
    $saved = $scaled->save($scaled_path);
    unlink($original);
    if (!$saved) {
      $refused[] = "$id: the image toolkit could not scale the hero";
      continue;
    }
    $body = file_get_contents($scaled_path);
    unlink($scaled_path);
  }
  foreach ($hero ? [] : [1920, 1280] as $step) {
    if (strlen($body) <= $cap) {
      break;
    }
    $smaller = $info($id, ['iiurlwidth' => $step])['imageinfo'][0];
    $body = (string) $client->get($smaller['thumburl'], $options)->getBody();
  }
  if (strlen($body) > $cap) {
    $refused[] = sprintf('%d: %d KB is over the %d KB cap', $id, intdiv(strlen($body), 1024), intdiv($cap, 1024));
    continue;
  }
  [$width, $height] = getimagesizefromstring($body);
  $extension = $image['mime'] === 'image/png' ? 'png' : 'jpg';
  file_put_contents(DemoImages::FETCHED_DIR . "/$id.$extension", $body);
  $total += strlen($body);
  $fetched[$id] = [
    'file' => "$id.$extension",
    'source_url' => $page['fullurl'],
    'creator' => $creator,
    'licence' => $value,
    'licence_url' => ($meta['LicenseUrl']['value'] ?? '') ?: ($value === 'public_domain' ? $public_domain_url : ''),
    'width' => $width,
    'height' => $height,
    'bytes' => strlen($body),
    'revision_timestamp' => $image['timestamp'],
  ];
  printf("%-10d %-14s %5d KB  %dx%d  %s\n", $id, $value, intdiv(strlen($body), 1024), $width, $height, $entry['use']);
  usleep(250000);
}
if ($total > DemoImages::TOTAL_CAP) {
  $refused[] = sprintf('the total of %d KB is over the %d KB cap', intdiv($total, 1024), intdiv(DemoImages::TOTAL_CAP, 1024));
}
file_put_contents(DemoImages::FETCHED_DIR . '/fetched.json', json_encode($fetched, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE) . "\n");
printf("%d fetched, %d KB in total\n", count($fetched), intdiv($total, 1024));
if ($refused) {
  fwrite(STDERR, "Refused:\n  " . implode("\n  ", $refused) . "\n");
  exit(1);
}
