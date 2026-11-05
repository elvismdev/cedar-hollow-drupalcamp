<?php

declare(strict_types=1);

namespace Drupal\Tests\cedar_hollow_core\Kernel;

use Drupal\Core\Render\Markup;
use Drupal\Tests\canvas\Kernel\CanvasKernelTestBase;
use Drupal\Tests\cedar_hollow_core\Traits\ComponentRenderTrait;
use PHPUnit\Framework\Attributes\Group;
use PHPUnit\Framework\Attributes\RunTestsInSeparateProcesses;

/**
 * Heading levels reach the heading tag name only from each component's enum.
 */
#[Group('cedar_hollow_core')]
#[RunTestsInSeparateProcesses]
final class TitleLevelTest extends CanvasKernelTestBase {

  use ComponentRenderTrait;

  /**
   * {@inheritdoc}
   */
  protected static $modules = [
    ...parent::CANVAS_KERNEL_TEST_MINIMAL_MODULES,
    'cedar_hollow_core',
  ];

  /**
   * {@inheritdoc}
   */
  protected function setUp(): void {
    parent::setUp();
    $this->enableCedarHollowTheme();
  }

  /**
   * Tests that every level in the title's enum renders its own heading.
   */
  public function testTitleKeepsEnumLevels(): void {
    $enum = $this->enumOf('cedar_hollow:title', 'level');
    $this->assertNotEmpty($enum, 'The title declares a level enum.');
    foreach ($enum as $level) {
      foreach ([$level, (int) $level] as $value) {
        foreach ([NULL, '/sessions'] as $url) {
          $html = $this->renderComponent('cedar_hollow:title', ['text' => 'Go', 'level' => $value] + ($url === NULL ? [] : ['url' => $url]));
          $this->assertHeading($html, $level, 'title--h' . $level, $url, 'Title level ' . self::describe($value) . ($url ? ' linked' : ''));
        }
      }
    }
  }

  /**
   * Tests that an off-enum title level renders the default heading.
   */
  public function testTitleFallsBackToDefault(): void {
    foreach (self::offEnumValues() as $value) {
      foreach ([NULL, '/sessions'] as $url) {
        $html = $this->renderComponent('cedar_hollow:title', ['text' => 'Go', 'level' => $value] + ($url === NULL ? [] : ['url' => $url]));
        $this->assertHeading($html, '2', 'title--h2', $url, 'Title level ' . self::describe($value) . ($url ? ' linked' : ''));
      }
    }
  }

  /**
   * Tests that every level in a molecule's enum renders its own heading.
   */
  public function testMoleculesKeepEnumLevels(): void {
    foreach (self::molecules() as $id => [, $size, $url]) {
      $enum = $this->enumOf($id, 'heading_level');
      $this->assertNotEmpty($enum, "$id declares a heading_level enum.");
      foreach ($enum as $level) {
        foreach ([$level, (int) $level] as $value) {
          $html = $this->renderComponent($id, ['heading' => 'Go', 'heading_level' => $value] + ($url === NULL ? [] : ['url' => $url]));
          $this->assertHeading($html, $level, 'title--size-' . $size, $url, "$id level " . self::describe($value));
        }
      }
    }
  }

  /**
   * Tests that an off-enum molecule heading level renders its default.
   */
  public function testMoleculesFallBackToDefault(): void {
    // Levels 5 and 6 are in the title's enum but outside the molecules' enum.
    $values = [...self::offEnumValues(), '5', '6', 5, 6];
    foreach (self::molecules() as $id => [$default, $size, $url]) {
      foreach ($values as $value) {
        $html = $this->renderComponent($id, ['heading' => 'Go', 'heading_level' => $value] + ($url === NULL ? [] : ['url' => $url]));
        $this->assertHeading($html, $default, 'title--size-' . $size, $url, "$id level " . self::describe($value));
      }
    }
  }

  /**
   * Level values outside every component's enum.
   *
   * @return list<mixed>
   *   The level values.
   */
  private static function offEnumValues(): array {
    return [
      '2 onfocus=alert(1) tabindex=0 autofocus x',
      'div',
      'script',
      '',
      '1',
      '7',
      ' 3',
      '3 ',
      '03',
      '3.0',
      '3e0',
      1,
      7,
      TRUE,
      FALSE,
      NULL,
      ['3'],
      Markup::create('3 onfocus=alert(1) x'),
    ];
  }

  /**
   * The molecules that render a title from a heading level.
   *
   * @return array<string, array{string, string, ?string}>
   *   The default level, the title size and the URL to link the title to,
   *   keyed by component ID. The callout's title takes no URL.
   */
  private static function molecules(): array {
    return [
      'cedar_hollow:callout' => ['2', 'large', NULL],
      'cedar_hollow:card' => ['3', 'small', '/sessions'],
      'cedar_hollow:featured-card' => ['3', 'large', '/sessions'],
    ];
  }

  /**
   * Reads the enum a component declares for a prop.
   *
   * @param string $id
   *   The component ID.
   * @param string $prop
   *   The prop name.
   *
   * @return list<string>
   *   The enum values.
   */
  private function enumOf(string $id, string $prop): array {
    $component = $this->container->get('plugin.manager.sdc')->find($id);
    return array_values($component->metadata->schema['properties'][$prop]['enum'] ?? []);
  }

  /**
   * Describes a level value for an assertion message.
   */
  private static function describe(mixed $value): string {
    return get_debug_type($value) . ' ' . json_encode(is_object($value) ? (string) $value : $value);
  }

  /**
   * Asserts the rendered title is a plain heading at a level.
   *
   * @param string $html
   *   The rendered markup.
   * @param string $level
   *   The expected heading level.
   * @param string $modifier
   *   The expected title modifier class.
   * @param string|null $url
   *   The URL the title links to, or NULL for an unlinked title.
   * @param string $message
   *   The assertion message prefix.
   */
  private function assertHeading(string $html, string $level, string $modifier, ?string $url, string $message): void {
    // The raw markup is read, so no HTML parser normalizes the tag first.
    $this->assertSame(1, preg_match('/<[^<>]*data-component-id="cedar_hollow:title"[^<>]*>/', $html, $open, PREG_OFFSET_CAPTURE), "$message renders a title.");
    $this->assertSame(sprintf('<h%s data-component-id="cedar_hollow:title" class="title %s">', $level, $modifier), $open[0][0], "$message opening tag.");
    // The heading holds only its text or one link around it, so the closing
    // tag that follows that content closes the heading itself.
    $rest = substr($html, $open[0][1] + strlen($open[0][0]));
    $this->assertSame(1, preg_match('/^\s*(<a\b[^<>]*>Go<\/a>|Go)\s*<\/([^<>]*)>/', $rest, $close), "$message heading content.");
    $link = $url === NULL ? 'Go' : sprintf('<a href="%s" class="title__link">Go</a>', $url);
    $this->assertSame($link, $close[1], "$message heading content.");
    $this->assertSame('h' . $level, $close[2], "$message closing tag.");
    $this->assertStringNotContainsString('onfocus', $html, "$message has no injected attribute.");
  }

}
