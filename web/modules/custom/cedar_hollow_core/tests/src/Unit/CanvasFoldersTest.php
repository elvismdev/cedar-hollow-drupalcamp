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
   * Tests that every folder holds at least one enabled component.
   */
  public function testNoFolderIsEmptyInThePalette(): void {
    $dir = dirname(__DIR__, 3) . self::CONFIG_DIR;
    $folders = glob($dir . 'canvas.folder.*.yml');
    $this->assertNotEmpty($folders, 'Folder configuration is exported.');

    $empty = [];
    foreach ($folders as $file) {
      $folder = Yaml::decode(file_get_contents($file));
      $enabled = FALSE;
      foreach ($folder['items'] as $component_id) {
        $component = Yaml::decode(file_get_contents($dir . 'canvas.component.' . $component_id . '.yml'));
        $enabled = $enabled || $component['status'];
      }
      if (!$enabled) {
        $empty[] = $folder['name'] . ' (' . basename($file, '.yml') . ')';
      }
    }
    $this->assertSame([], $empty, 'These folders hold only disabled components.');
  }

}
