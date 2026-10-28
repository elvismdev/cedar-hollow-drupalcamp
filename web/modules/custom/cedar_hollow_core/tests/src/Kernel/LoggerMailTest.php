<?php

declare(strict_types=1);

namespace Drupal\Tests\cedar_hollow_core\Kernel;

use Drupal\KernelTests\KernelTestBase;
use PHPUnit\Framework\Attributes\Group;
use PHPUnit\Framework\Attributes\RunTestsInSeparateProcesses;

/**
 * Mail sent through the logger plugin is recorded and not delivered.
 */
#[Group('cedar_hollow_core')]
#[RunTestsInSeparateProcesses]
final class LoggerMailTest extends KernelTestBase {

  protected static $modules = ['system', 'dblog', 'user'];

  protected function setUp(): void {
    parent::setUp();
    $this->installSchema('dblog', ['watchdog']);
    $this->installConfig(['system']);
    // Loaded by path so the test does not need the module's dependencies.
    require_once dirname(__DIR__, 3) . '/src/Plugin/Mail/LoggerMail.php';
  }

  public function testMailIsLogged(): void {
    $subject = 'Probe ' . bin2hex(random_bytes(4));
    $plugin = new \Drupal\cedar_hollow_core\Plugin\Mail\LoggerMail();
    $message = $plugin->format(['to' => 'someone@example.com', 'subject' => $subject, 'body' => ['Line one', 'Line two']]);
    $this->assertSame("Line one\n\nLine two", $message['body']);
    $this->assertTrue($plugin->mail($message));

    $logged = $this->container->get('database')->select('watchdog', 'w')
      ->fields('w', ['variables'])
      ->condition('type', 'cedar_hollow_core')
      ->execute()
      ->fetchField();
    $this->assertNotFalse($logged);
    $this->assertStringContainsString($subject, $logged);
  }

}
