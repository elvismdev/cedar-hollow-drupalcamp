<?php

/**
 * @file
 * Creates or updates the agenda_builder Canvas code component from the theme.
 *
 * Run by scripts/build-agenda-builder.sh after esbuild has written the
 * compiled module. Exits non-zero and saves nothing if validation fails.
 */

use Drupal\canvas\Entity\JavaScriptComponent;

$source_dir = DRUPAL_ROOT . '/themes/custom/cedar_hollow/agenda-builder';
$compiled_file = '/tmp/agenda-builder.compiled.js';

$read = static function (string $path): string {
  $contents = @file_get_contents($path);
  if ($contents === FALSE) {
    fwrite(STDERR, "Cannot read $path\n");
    exit(1);
  }
  return $contents;
};

$css = $read("$source_dir/agenda-builder.css");
$values = [
  'name' => 'Agenda builder',
  'status' => TRUE,
  'props' => [
    'heading' => [
      'type' => 'string',
      'title' => 'Heading',
      'examples' => ['Build your agenda'],
    ],
  ],
  'required' => ['heading'],
  'slots' => [],
  'js' => [
    'original' => $read("$source_dir/agenda-builder.jsx"),
    'compiled' => $read($compiled_file),
  ],
  'css' => ['original' => $css, 'compiled' => $css],
  'dataDependencies' => [],
];

$component = JavaScriptComponent::load('agenda_builder') ?? JavaScriptComponent::create(['machineName' => 'agenda_builder']);
foreach ($values as $key => $value) {
  $component->set($key, $value);
}

$violations = $component->getTypedData()->validate();
if ($violations->count() > 0) {
  foreach ($violations as $violation) {
    fwrite(STDERR, $violation->getPropertyPath() . ': ' . $violation->getMessage() . "\n");
  }
  exit(1);
}

$component->save();
print 'Saved code component agenda_builder (' . strlen($values['js']['compiled']) . " bytes compiled).\n";
