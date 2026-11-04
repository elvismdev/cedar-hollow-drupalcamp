<?php

declare(strict_types=1);

namespace Drupal\Tests\cedar_hollow_core\Kernel;

use Drupal\cedar_hollow_core\Plugin\Mail\LoggerMail;
use Drupal\Component\Serialization\Yaml;
use Drupal\KernelTests\KernelTestBase;
use PHPUnit\Framework\Attributes\DataProvider;
use PHPUnit\Framework\Attributes\Group;
use PHPUnit\Framework\Attributes\RunTestsInSeparateProcesses;

/**
 * The mail manager resolves the logger plugin for Forward's message keys.
 *
 * Checked against the mail routing in the exported configuration.
 */
#[Group('cedar_hollow_core')]
#[RunTestsInSeparateProcesses]
final class MailRoutingTest extends KernelTestBase {

  /**
   * {@inheritdoc}
   */
  protected static $modules = [
    'system',
    'forward',
    'cedar_hollow_core',
  ];

  /**
   * {@inheritdoc}
   */
  protected function setUp(): void {
    parent::setUp();
    // KernelTestBase overrides the default mail plugin with a collector. The
    // override is removed only so the exported routing is what gets resolved;
    // this test only looks plugins up and must never send mail.
    unset($GLOBALS['config']['system.mail']['interface']);
    $this->container->get('config.factory')->reset('system.mail');
    // Use the mail routing the site exports, not the module default.
    $path = $this->root . '/../config/system.mail.yml';
    $this->assertFileExists($path);
    $exported = Yaml::decode((string) file_get_contents($path));
    $this->config('system.mail')->set('interface', $exported['interface'])->save();
  }

  /**
   * Tests that both Forward message keys resolve to the logger plugin.
   */
  #[DataProvider('forwardKeys')]
  public function testForwardMailIsLogged(string $key): void {
    $plugin = $this->container->get('plugin.manager.mail')
      ->getInstance(['module' => 'forward', 'key' => $key]);
    $this->assertInstanceOf(LoggerMail::class, $plugin);
  }

  /**
   * Provides the message keys Forward uses.
   *
   * @return array<string, array{string}>
   *   Message keys.
   */
  public static function forwardKeys(): array {
    return [
      'send_entity' => ['send_entity'],
      'mail_entity' => ['mail_entity'],
    ];
  }

}
