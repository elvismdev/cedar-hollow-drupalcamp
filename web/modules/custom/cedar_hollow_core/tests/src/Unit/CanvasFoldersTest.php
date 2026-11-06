<?php

declare(strict_types=1);

namespace Drupal\Tests\cedar_hollow_core\Unit;

use Drupal\Component\Serialization\Yaml;
use Drupal\Tests\UnitTestCase;
use PHPUnit\Framework\Attributes\Group;

/**
 * Tests the exported Canvas palette folders.
 */
#[Group('cedar_hollow_core')]
final class CanvasFoldersTest extends UnitTestCase {

  /**
   * The exported configuration directory, relative to this module.
   */
  private const CONFIG_DIR = '/../../../../config/';

  /**
   * Tests that every component folder holds at least one enabled component.
   *
   * This checks the exported configuration only. Canvas creates a component's
   * folder whenever the component is newly created (Component::postSave()), so
   * a fresh install from configuration brings a deleted folder back; the
   * deletion holds on an existing site.
   */
  public function testNoFolderIsEmptyInThePalette(): void {
    $dir = dirname(__DIR__, 3) . self::CONFIG_DIR;
    $folders = glob($dir . 'canvas.folder.*.yml');
    $this->assertNotEmpty($folders, 'Folder configuration is exported.');

    $empty = [];
    foreach ($folders as $file) {
      $folder = Yaml::decode(file_get_contents($file));
      if (($folder['configEntityTypeId'] ?? NULL) !== 'component') {
        continue;
      }
      $enabled = FALSE;
      foreach ($folder['items'] ?? [] as $component_id) {
        $component_file = $dir . 'canvas.component.' . $component_id . '.yml';
        $this->assertFileExists($component_file, sprintf('Folder %s lists component %s, which is exported.', $folder['name'], $component_id));
        $component = Yaml::decode(file_get_contents($component_file));
        $enabled = $enabled || !empty($component['status']);
      }
      if (!$enabled) {
        $empty[] = $folder['name'] . ' (' . basename($file, '.yml') . ')';
      }
    }
    $this->assertSame([], $empty, 'These folders hold only disabled components.');
  }

}
