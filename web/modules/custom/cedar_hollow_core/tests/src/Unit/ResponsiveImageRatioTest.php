<?php

declare(strict_types=1);

namespace Drupal\Tests\cedar_hollow_core\Unit;

use Drupal\Component\Serialization\Yaml;
use Drupal\Tests\UnitTestCase;
use PHPUnit\Framework\Attributes\Group;

/**
 * Every responsive image style serves one cropped ratio.
 *
 * A browser picks any candidate from srcset, so a style that mixes ratios
 * changes the image's shape with the viewport and shifts the layout.
 */
#[Group('cedar_hollow_core')]
final class ResponsiveImageRatioTest extends UnitTestCase {

  private const CROP_EFFECT = 'focal_point_scale_and_crop';

  private const RATIO_TOLERANCE = 0.01;

  /**
   * Tests that the site's configuration has no violations.
   */
  public function testSiteConfig(): void {
    $directory = $this->root . '/../config';
    // An empty glob would report no violations, so the styles must be found.
    $this->assertNotEmpty(glob($directory . '/responsive_image.styles.*.yml'), "No responsive image styles in $directory");
    $this->assertSame([], $this->violations($directory));
  }

  /**
   * Tests that a style mapping two ratios is reported once.
   */
  public function testMixedFixture(): void {
    $violations = $this->violations(dirname(__DIR__, 2) . '/fixtures/responsive_image_mixed');
    $this->assertCount(1, $violations);
    $this->assertStringStartsWith('mixed:', $violations[0]);
  }

  /**
   * Returns one message per responsive image style that breaks the rules.
   *
   * @return list<string>
   *   Messages, each starting with the responsive image style id.
   */
  private function violations(string $directory): array {
    $violations = [];
    foreach (glob($directory . '/responsive_image.styles.*.yml') as $file) {
      $style = Yaml::decode(file_get_contents($file));
      $mapped = [];
      foreach ($style['image_style_mappings'] as $mapping) {
        $mapped = array_merge($mapped, $mapping['image_mapping_type'] === 'sizes'
          ? $mapping['image_mapping']['sizes_image_styles']
          : [$mapping['image_mapping']]);
      }
      $mapped = array_values(array_unique($mapped));

      $problems = [];
      $ratios = [];
      foreach ($mapped as $image_style_id) {
        $crop = $this->cropEffect($directory, $image_style_id);
        if ($crop === NULL) {
          $problems[] = "$image_style_id does not use " . self::CROP_EFFECT;
          continue;
        }
        $ratios[$image_style_id] = $crop['width'] / $crop['height'];
      }
      if ($ratios && max($ratios) - min($ratios) > self::RATIO_TOLERANCE) {
        $problems[] = 'maps more than one ratio (' . implode(', ', array_keys($ratios)) . ')';
      }
      if (!in_array($style['fallback_image_style'], $mapped, TRUE)) {
        $problems[] = 'fallback ' . $style['fallback_image_style'] . ' is not mapped';
      }
      if ($problems) {
        $violations[] = $style['id'] . ': ' . implode('; ', $problems);
      }
    }
    return $violations;
  }

  /**
   * Returns the crop effect's data for an image style, or NULL.
   *
   * @return array{width: int, height: int}|null
   *   The crop dimensions.
   */
  private function cropEffect(string $directory, string $image_style_id): ?array {
    $file = "$directory/image.style.$image_style_id.yml";
    if (!is_file($file)) {
      return NULL;
    }
    foreach (Yaml::decode(file_get_contents($file))['effects'] ?? [] as $effect) {
      if ($effect['id'] === self::CROP_EFFECT) {
        return $effect['data'];
      }
    }
    return NULL;
  }

}
