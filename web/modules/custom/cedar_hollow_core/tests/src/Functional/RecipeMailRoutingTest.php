<?php

declare(strict_types=1);

namespace Drupal\Tests\cedar_hollow_core\Functional;

use Drupal\cedar_hollow_core\Plugin\Mail\LoggerMail;
use PHPUnit\Framework\Attributes\DataProvider;
use PHPUnit\Framework\Attributes\Group;
use PHPUnit\Framework\Attributes\RunTestsInSeparateProcesses;

/**
 * A site built from the sessions recipe resolves mail to the logger plugin.
 *
 * The recipe installs Forward, whose install hook routes its send_entity
 * message to a plugin that delivers; the recipe must replace that routing.
 */
#[Group('cedar_hollow_core')]
#[RunTestsInSeparateProcesses]
final class RecipeMailRoutingTest extends SessionTestBase {

  /**
   * Tests the plugin resolved for Forward's message keys and for other mail.
   */
  #[DataProvider('messages')]
  public function testMailIsLogged(string $module, string $key): void {
    $plugin = $this->container->get('plugin.manager.mail')
      ->getInstance(['module' => $module, 'key' => $key]);
    $this->assertInstanceOf(LoggerMail::class, $plugin);
  }

  /**
   * Tests that applying the recipe again, to matching config, still works.
   */
  public function testReapplyKeepsRouting(): void {
    $this->applyRecipe(realpath($this->root . '/../recipes/cedar_hollow_sessions'));
    $this->assertSame(
      ['default' => 'cedar_hollow_logger'],
      $this->config('system.mail')->get('interface'),
    );
  }

  /**
   * Provides module and key pairs.
   *
   * @return array<string, array{string, string}>
   *   Message identifiers.
   */
  public static function messages(): array {
    return [
      'forward send_entity' => ['forward', 'send_entity'],
      'forward mail_entity' => ['forward', 'mail_entity'],
      'other module' => ['user', 'register_no_approval_required'],
    ];
  }

}
