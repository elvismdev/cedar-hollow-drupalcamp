<?php

declare(strict_types=1);

namespace Drupal\Tests\cedar_hollow_core\Kernel;

use Drupal\Tests\canvas\Kernel\CanvasKernelTestBase;
use Drupal\Tests\cedar_hollow_core\Traits\ComponentRenderTrait;
use PHPUnit\Framework\Attributes\DataProvider;
use PHPUnit\Framework\Attributes\Group;
use PHPUnit\Framework\Attributes\RunTestsInSeparateProcesses;

/**
 * The title's level reaches the heading tag name only from its enum.
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
   * Level values outside every component's enum.
   *
   * @return array<string, array{string}>
   *   The level value.
   */
  public static function offEnumProvider(): array {
    return [
      'attribute injection' => ['2 onfocus=alert(1) tabindex=0 autofocus x'],
      'non-heading tag name' => ['div'],
      'script tag name' => ['script'],
      'empty value' => [''],
      'level 1' => ['1'],
      'level 7' => ['7'],
      'leading space' => [' 3'],
      'trailing space' => ['3 '],
      'leading zero' => ['03'],
      'decimal' => ['3.0'],
      'exponent' => ['3e0'],
    ];
  }

  /**
   * Tests that each level in the title's enum renders its heading.
   */
  public function testTitleKeepsEnumLevels(): void {
    foreach (['2', '3', '4', '5', '6'] as $level) {
      $html = $this->renderComponent('cedar_hollow:title', ['text' => 'Go', 'level' => $level]);
      $this->assertHeading($html, $level, 'title--h' . $level, "Title level $level");
    }
  }

  /**
   * Tests that an off-enum title level renders the default heading.
   */
  #[DataProvider('offEnumProvider')]
  public function testTitleFallsBackToDefault(string $level): void {
    $html = $this->renderComponent('cedar_hollow:title', ['text' => 'Go', 'level' => $level]);
    $this->assertHeading($html, '2', 'title--h2', 'Title');
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
   * @param string $message
   *   The assertion message prefix.
   */
  private function assertHeading(string $html, string $level, string $modifier, string $message): void {
    // The raw markup is read, so no HTML parser normalizes the tag first.
    $this->assertSame(1, preg_match('/<[^<>]*data-component-id="cedar_hollow:title"[^<>]*>/', $html, $open), "$message renders a title.");
    $this->assertSame(sprintf('<h%s data-component-id="cedar_hollow:title" class="title %s">', $level, $modifier), $open[0], "$message opening tag.");
    $this->assertSame(1, preg_match('/Go\s*<\/([^<>]*)>/', $html, $close), "$message closes the title.");
    $this->assertSame('h' . $level, $close[1], "$message closing tag.");
    $this->assertStringNotContainsString('onfocus', $html, "$message has no injected attribute.");
  }

}
