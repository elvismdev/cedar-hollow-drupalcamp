<?php

declare(strict_types=1);

namespace Drupal\Tests\cedar_hollow_core\Kernel;

use Drupal\Tests\canvas\Kernel\CanvasKernelTestBase;
use PHPUnit\Framework\Attributes\DataProvider;
use PHPUnit\Framework\Attributes\Group;
use PHPUnit\Framework\Attributes\RunTestsInSeparateProcesses;

/**
 * Theme components print URL props into href only after cleaning them.
 */
#[Group('cedar_hollow_core')]
#[RunTestsInSeparateProcesses]
final class UrlPropHrefTest extends CanvasKernelTestBase {

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
    $this->container->get('theme_installer')->install(['cedar_hollow']);
    $this->config('system.theme')->set('default', 'cedar_hollow')->save();
    $theme_manager = $this->container->get('theme.manager');
    $theme_manager->setActiveTheme($this->container->get('theme.initialization')->initTheme('cedar_hollow'));
  }

  /**
   * URL prop values and the href each must render with.
   *
   * @return array<string, array{string, string}>
   *   The URL prop value and the expected href.
   */
  public static function urlProvider(): array {
    return [
      'absolute https URL' => ['https://example.com/sessions?day=1#top', 'https://example.com/sessions?day=1#top'],
      'root-relative path' => ['/sessions', '/sessions'],
      'path with a colon in the query' => ['/agenda?time=10:00', '/agenda?time=10:00'],
      'mailto link' => ['mailto:hello@example.com', 'mailto:hello@example.com'],
      'javascript scheme' => ['javascript:alert(1)', 'alert(1)'],
      'mixed-case javascript scheme' => ['JaVaScRiPt:alert(1)', 'alert(1)'],
      'leading space before scheme' => [' javascript:alert(1)', 'alert(1)'],
      'leading U+0001 before scheme' => ["\u{0001}javascript:alert(1)", 'alert(1)'],
      'leading U+001F before scheme' => ["\u{001F}javascript:alert(1)", 'alert(1)'],
      'data scheme' => ['data:text/html,x', 'text/html,x'],
      'vbscript scheme' => ['vbscript:x', 'x'],
    ];
  }

  /**
   * Tests the href each URL-taking component renders.
   */
  #[DataProvider('urlProvider')]
  public function testComponentHref(string $url, string $expected): void {
    $components = [
      'cedar_hollow:button' => ['text' => 'Go', 'url' => $url, 'variant' => 'primary'],
      'cedar_hollow:title' => ['text' => 'Go', 'url' => $url, 'level' => '2', 'size' => 'medium'],
      'cedar_hollow:eyebrow' => ['text' => 'Go', 'url' => $url, 'tone' => 'default'],
      'cedar_hollow:breadcrumb' => [
        'breadcrumb' => [['text' => 'Go', 'url' => $url], ['text' => 'Here']],
        'tone' => 'default',
      ],
    ];
    // Component prop validation runs only while assertions are on, and a
    // production PHP configuration switches them off, so the components render
    // here as they do for visitors, whatever the value's format.
    $assertions = ini_set('zend.assertions', '0');
    $this->assertNotFalse($assertions, 'Assertions can be switched off at runtime.');
    try {
      foreach ($components as $id => $props) {
        $build = ['#type' => 'component', '#component' => $id, '#props' => $props];
        $html = (string) $this->container->get('renderer')->renderInIsolation($build);
        // The raw markup is read, so no HTML parser normalizes the value first.
        $this->assertSame(1, preg_match('/<a[^>]*\shref="([^"]*)"/', $html, $matches), "$id renders a link.");
        $this->assertSame($expected, html_entity_decode($matches[1], ENT_QUOTES | ENT_HTML5), "$id href.");
      }
    }
    finally {
      ini_set('zend.assertions', $assertions);
    }
  }

}
