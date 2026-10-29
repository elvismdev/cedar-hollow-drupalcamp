<?php

declare(strict_types=1);

namespace Drupal\Tests\cedar_hollow_core\Functional;

use Drupal\Core\Entity\Entity\EntityFormDisplay;
use Drupal\file\Entity\File;
use Drupal\media\Entity\Media;
use Drupal\media\MediaInterface;
use PHPUnit\Framework\Attributes\Group;
use PHPUnit\Framework\Attributes\RunTestsInSeparateProcesses;

/**
 * Image media cannot be saved without an open licence on record.
 *
 * The licence rules are field validation, which save() does not run, so the
 * test asserts validation results and the form display Media Library builds
 * its upload form from.
 */
#[Group('cedar_hollow_core')]
#[RunTestsInSeparateProcesses]
final class MediaLicenceTest extends SessionTestBase {

  private const LICENCE_FIELDS = ['field_source_url', 'field_creator', 'field_licence', 'field_licence_url'];

  /**
   * Tests that missing or closed licences fail validation.
   */
  public function testLicenceValidation(): void {
    $media = $this->createImageMedia([]);
    $paths = $this->violationPaths($media);
    foreach (self::LICENCE_FIELDS as $field) {
      $this->assertContains($field, $paths, "$field is required.");
    }

    $media = $this->createImageMedia([
      'field_source_url' => 'https://commons.wikimedia.org/wiki/File:Example.jpg',
      'field_creator' => 'Example creator',
      'field_licence' => 'cc_by_sa',
      'field_licence_url' => 'https://creativecommons.org/licenses/by-sa/4.0/',
    ]);
    $this->assertSame(['field_licence'], $this->violationPaths($media), 'A licence outside CC0, public domain and CC BY is refused.');

    $media->set('field_licence', 'cc_by');
    $this->assertSame([], $this->violationPaths($media), 'A complete CC BY record is valid.');
  }

  /**
   * Tests that the Media Library upload form enforces the licence fields.
   *
   * Media Library's add form validates only the fields its media_library
   * form display contains, so the licence fields must be on that display.
   */
  public function testMediaLibraryFormEnforcesLicence(): void {
    $display = EntityFormDisplay::load('media.image.media_library');
    $this->assertNotNull($display);
    foreach (self::LICENCE_FIELDS as $field) {
      $this->assertNotNull($display->getComponent($field), "$field is on the Media Library upload form.");
    }
    $this->assertNull($display->getComponent('field_verified'), 'Uploaders cannot mark an image verified.');

    $media = $this->createImageMedia([]);
    $hidden = array_diff(array_keys($media->getFieldDefinitions()), array_keys($display->getComponents()));
    $violations = $media->validate()->filterByFields($hidden);
    $paths = array_unique(array_map(static fn($violation) => explode('.', $violation->getPropertyPath())[0], iterator_to_array($violations)));
    foreach (self::LICENCE_FIELDS as $field) {
      $this->assertContains($field, $paths, "The upload form reports a missing $field.");
    }
  }

  /**
   * Creates an unsaved Image media item with a real image file.
   *
   * @param array<string, string> $values
   *   Licence field values.
   */
  private function createImageMedia(array $values): MediaInterface {
    $image = $this->getTestFiles('image')[0];
    $file = File::create(['uri' => $image->uri, 'status' => 1]);
    $file->save();
    return Media::create($values + [
      'bundle' => 'image',
      'name' => 'Licence test',
      'field_media_image' => ['target_id' => $file->id(), 'alt' => 'A test image'],
    ]);
  }

  /**
   * Returns the top-level field names that have violations.
   *
   * @return list<string>
   *   Field names.
   */
  private function violationPaths(MediaInterface $media): array {
    $paths = array_map(static fn($violation) => explode('.', $violation->getPropertyPath())[0], iterator_to_array($media->validate()));
    $paths = array_values(array_unique($paths));
    sort($paths);
    return $paths;
  }

}
