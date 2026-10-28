<?php

/**
 * @file
 * Authors the demo content that recipes/cedar_hollow_demo_content ships.
 *
 * Run with `ddev drush php:script scripts/seed-demo-content.php`, then export
 * with scripts/export-demo-content.sh. It deletes existing tracks, speakers,
 * sessions, registrations, menu links and Canvas pages first, so it only runs
 * on a local site. Every Canvas page is validated before it is saved.
 */

use Drupal\canvas\Entity\Component;
use Drupal\canvas\Entity\Page;
use Drupal\menu_link_content\Entity\MenuLinkContent;
use Drupal\node\Entity\Node;
use Drupal\taxonomy\Entity\Term;

const TIME_ZONE = 'America/New_York';

$etm = \Drupal::entityTypeManager();
$uuid = \Drupal::service('uuid');

// Start from an empty slate.
foreach (['registration', 'registration_settings', 'canvas_page', 'menu_link_content'] as $type) {
  $storage = $etm->getStorage($type);
  $storage->delete($storage->loadMultiple());
}
$nodes = $etm->getStorage('node');
$nodes->delete($nodes->loadMultiple());
$terms = $etm->getStorage('taxonomy_term');
$terms->delete($terms->loadByProperties(['vid' => 'track']));

$tracks = [];
foreach (['Front end', 'Back end', 'Site building'] as $weight => $name) {
  $term = Term::create(['vid' => 'track', 'name' => $name, 'weight' => $weight]);
  $term->save();
  $tracks[$name] = $term;
}

$speakers = [];
foreach ([
  'Ana Calder' => 'Builds component libraries for university sites.',
  'Ben Okafor' => 'Works on caching and performance for large Drupal sites.',
  'Chloe Marsh' => 'Runs a small agency that ships sites from Storybook first.',
  'Dev Raman' => 'Maintains configuration and deployment tooling.',
  'Elena Ruiz' => 'Leads accessibility reviews for public sector sites.',
  'Femi Adeyemi' => 'Builds event and membership features on Drupal.',
  'Grace Lindqvist' => 'Trains content teams on page building.',
  'Hugo Tanaka' => 'Writes front-end tooling and CSS architecture guides.',
] as $name => $bio) {
  $speaker = Node::create([
    'type' => 'speaker',
    'title' => $name,
    'body' => ['value' => "$bio This speaker is fictional.", 'format' => 'plain_text'],
    'status' => 1,
    'path' => ['alias' => '/speakers/' . strtolower(str_replace(' ', '-', $name))],
  ]);
  $speaker->save();
  $speakers[$name] = $speaker;
}

// [title, day, start, end, room, track, speakers, capacity, summary].
$sessions = [
  ['Theming with SDC', 'fri', '10:00', '10:45', 'Hall A', 'Front end', ['Ana Calder'], 1, 'Build components once and use them in Storybook, Twig templates and Canvas.'],
  ['Caching render arrays', 'fri', '10:15', '11:00', 'Hall B', 'Back end', ['Ben Okafor'], 40, 'Cache tags, contexts and max-age, and how to see them in response headers.'],
  ['Storybook for Drupal themes', 'fri', '11:15', '12:00', 'Hall A', 'Front end', ['Chloe Marsh'], 40, 'Render Twig components in Storybook with the same CSS Drupal loads.'],
  ['Recipes in practice', 'fri', '11:30', '12:15', 'Hall B', 'Site building', ['Dev Raman'], 40, 'Package a feature as a recipe and apply it to a fresh site.'],
  ['Entity Registration for events', 'fri', '13:30', '14:15', 'Hall A', 'Back end', ['Femi Adeyemi'], 40, 'Capacity, wait lists and confirmation messages with Entity Registration.'],
  ['Accessible forms in Drupal', 'fri', '14:30', '15:15', 'Hall B', 'Front end', ['Elena Ruiz'], 40, 'Labels, errors and focus in Form API, checked with a screen reader.'],
  ['Canvas for site builders', 'sat', '09:00', '09:45', 'Hall A', 'Site building', ['Grace Lindqvist'], 40, 'Assemble landing pages from theme components in Drupal Canvas.'],
  ['Preprocess hooks without the mess', 'sat', '09:30', '10:15', 'Hall B', 'Back end', ['Ben Okafor', 'Hugo Tanaka'], 40, 'Keep templates thin by preparing values in object-oriented hooks.'],
  ['Cascade layers and BEM', 'sat', '10:30', '11:15', 'Hall A', 'Front end', ['Hugo Tanaka'], 40, 'Order theme CSS with cascade layers instead of specificity.'],
  ['Configuration and deploys on Pantheon', 'sat', '10:30', '11:15', 'Hall B', 'Back end', ['Dev Raman'], 40, 'Move configuration from local to Dev, Test and Live with drush deploy.'],
  ['Views and exposed filters', 'sat', '13:00', '13:45', 'Hall A', 'Site building', ['Grace Lindqvist'], 40, 'Build filtered listings with Views and Better Exposed Filters.'],
  ['Closing panel', 'sat', '14:00', '14:45', 'Atrium', 'Site building', ['Ana Calder', 'Femi Adeyemi', 'Elena Ruiz'], 40, 'What the camp learned, and what to build next.'],
];
$dates = ['fri' => '2027-03-12', 'sat' => '2027-03-13'];
$host_handler = $etm->getHandler('node', 'registration_host_entity');
$settings_storage = $etm->getStorage('registration_settings');
foreach ($sessions as [$title, $day, $start, $end, $room, $track, $names, $capacity, $summary]) {
  $from = new DateTimeImmutable("{$dates[$day]} $start", new DateTimeZone(TIME_ZONE));
  $to = new DateTimeImmutable("{$dates[$day]} $end", new DateTimeZone(TIME_ZONE));
  $node = Node::create([
    'type' => 'session',
    'title' => $title,
    'body' => ['value' => $summary, 'summary' => $summary, 'format' => 'plain_text'],
    'field_day' => $day,
    'field_room' => $room,
    'field_track' => $tracks[$track],
    'field_speakers' => array_map(fn($name) => $speakers[$name], $names),
    'field_session_time' => [
      'value' => $from->getTimestamp(),
      'end_value' => $to->getTimestamp(),
      'duration' => ($to->getTimestamp() - $from->getTimestamp()) / 60,
      'timezone' => TIME_ZONE,
    ],
    'field_registration' => ['registration_type' => 'attendee'],
    'status' => 1,
    'path' => ['alias' => '/sessions/' . strtolower(trim(preg_replace('/[^a-z0-9]+/i', '-', $title), '-'))],
  ]);
  $node->save();
  $settings = $settings_storage->loadSettingsForHostEntity($host_handler->createHostEntity($node));
  $settings->set('status', TRUE);
  $settings->set('capacity', $capacity);
  $settings->set('registration_waitlist_enable', TRUE);
  $settings->save();
}

$links = [
  ['main', 'Home', 'internal:/'],
  ['main', 'Sessions', 'internal:/sessions'],
  ['main', 'Agenda', 'internal:/agenda'],
  ['main', 'About', 'internal:/about'],
  ['main', 'Try Canvas', 'internal:/try-canvas'],
  ['footer', 'Site map', 'internal:/sitemap'],
  ['footer', 'Log in', 'internal:/user/login'],
];
foreach ($links as $weight => [$menu, $title, $uri]) {
  MenuLinkContent::create(['menu_name' => $menu, 'title' => $title, 'link' => ['uri' => $uri], 'weight' => $weight])->save();
}

/**
 * Builds a Canvas component tree item.
 *
 * @param array $children
 *   Child items keyed by slot name.
 */
$item = function (string $component, array $inputs = [], array $children = []) use (&$item, $uuid): array {
  $entity = Component::load($component);
  if (!$entity || !$entity->status()) {
    throw new RuntimeException("Canvas component $component is missing or disabled.");
  }
  return [
    'uuid' => $uuid->generate(),
    'component_id' => $component,
    'component_version' => $entity->getActiveVersion(),
    'inputs' => $inputs,
    'children' => $children,
  ];
};

// Flattens nested items into Canvas's list of items with parent_uuid and slot.
$flatten = function (array $items, ?string $parent = NULL, ?string $slot = NULL) use (&$flatten): array {
  $flat = [];
  foreach ($items as $entry) {
    $children = $entry['children'];
    unset($entry['children']);
    if ($parent) {
      $entry['parent_uuid'] = $parent;
      $entry['slot'] = $slot;
    }
    $flat[] = $entry;
    foreach ($children as $child_slot => $slot_items) {
      $flat = array_merge($flat, $flatten($slot_items, $entry['uuid'], $child_slot));
    }
  }
  return $flat;
};

$track_cards = array_map(
  fn(Term $term) => $item('sdc.cedar_hollow.card', [
    'heading' => $term->label(),
    'url' => '/sessions?field_track_target_id=' . $term->id(),
    'eyebrow' => 'Track',
  ]),
  array_values($tracks),
);

$skills = ['Twig', 'Template suggestions', 'Preprocess hooks', 'Single Directory Components', 'Storybook', 'Drupal Canvas', 'Recipes', 'Views', 'Accessibility', 'Pantheon'];

$pages = [
  ['Welcome to Cedar Hollow DrupalCamp', '/home', [
    $item('sdc.cedar_hollow.page-section', ['width' => 'wide'], ['content' => [
      $item('sdc.cedar_hollow.callout', [
        'heading' => '12 and 13 March 2027',
        'teaser' => '<p>Two days of sessions on front end, back end and site building, with seats you can claim and an agenda you can plan.</p>',
        'cta_text' => 'Browse sessions',
        'cta_url' => '/sessions',
        'cta_variant' => 'primary',
        'layout' => 'stacked',
        'style' => 'default',
      ]),
      $item('sdc.cedar_hollow.button', ['text' => 'Build your agenda', 'url' => '/agenda', 'variant' => 'secondary']),
    ]]),
    $item('sdc.cedar_hollow.page-section', ['heading' => 'Three tracks', 'width' => 'wide'], ['content' => [
      $item('sdc.cedar_hollow.card-grid', ['columns' => '3'], ['items' => $track_cards]),
    ]]),
  ]],
  ['Agenda', '/agenda', [
    $item('sdc.cedar_hollow.page-section', ['width' => 'wide'], ['content' => [
      $item('js.agenda_builder', ['heading' => 'Build your agenda']),
    ]]),
  ]],
  ['About this demo', '/about', [
    $item('sdc.cedar_hollow.two-column', ['ratio' => '60-40'], [
      'primary' => [
        $item('sdc.cedar_hollow.callout', [
          'heading' => 'How this site is built',
          'teaser' => '<p>The theme is the Surface theme carried to Drupal 11 Single Directory Components, so the same components render in Storybook, in Twig templates and in this page builder. Sessions, the listing and the sign-up form are themed with template suggestions and preprocess hooks. Seats come from Entity Registration.</p>',
          'layout' => 'stacked',
          'style' => 'default',
        ]),
        $item('sdc.cedar_hollow.callout', [
          'heading' => 'This is a demo',
          'teaser' => '<p>Cedar Hollow DrupalCamp is a fictional event. Mail is logged, never sent.</p>',
          'layout' => 'stacked',
          'style' => 'default',
        ]),
      ],
      'secondary' => array_merge(
        [$item('sdc.cedar_hollow.title', ['text' => 'Skills shown', 'level' => '2'])],
        array_map(fn($skill) => $item('sdc.cedar_hollow.tag', ['label' => $skill]), $skills),
      ),
    ]),
  ]],
  ['Try Canvas here', '/try-canvas', [
    $item('sdc.cedar_hollow.page-section', ['width' => 'narrow'], ['content' => [
      $item('sdc.cedar_hollow.title', ['text' => 'Edit this page', 'level' => '2']),
      $item('sdc.cedar_hollow.callout', [
        'heading' => 'Reviewers may change this page',
        'teaser' => '<p>Log in with the demo editor account, open this page in Canvas, and add or rearrange components from the theme.</p>',
        'layout' => 'stacked',
        'style' => 'default',
      ]),
    ]]),
  ]],
];

foreach ($pages as [$title, $alias, $tree]) {
  $page = Page::create([
    'title' => $title,
    'status' => TRUE,
    'path' => ['alias' => $alias],
    'components' => $flatten($tree),
  ]);
  $violations = $page->validate();
  if ($violations->count()) {
    foreach ($violations as $violation) {
      fwrite(STDERR, "$title: " . $violation->getPropertyPath() . ': ' . $violation->getMessage() . "\n");
    }
    exit(1);
  }
  $page->save();
}

print count($sessions) . ' sessions, ' . count($speakers) . ' speakers, ' . count($tracks) . ' tracks, ' . count($pages) . " Canvas pages.\n";
