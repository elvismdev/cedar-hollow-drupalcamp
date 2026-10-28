<?php

declare(strict_types=1);

namespace Drupal\Tests\cedar_hollow_core\Functional;

use Drupal\canvas\Entity\Page;
use Drupal\Component\Serialization\Yaml;
use Drupal\Core\Session\AccountInterface;
use Drupal\user\Entity\Role;
use PHPUnit\Framework\Attributes\Group;
use PHPUnit\Framework\Attributes\RunTestsInSeparateProcesses;

/**
 * The demo editor role can edit Canvas pages and nothing an outsider should.
 *
 * Reviewers get this role on the public demo, so each refusal is checked
 * against an administrator getting through the same door.
 */
#[Group('cedar_hollow_core')]
#[Group('cedar_hollow_theme')]
#[RunTestsInSeparateProcesses]
final class DemoEditorAccessTest extends SessionTestBase {

  private const ROLE_CONFIG = '/../config/user.role.demo_editor.yml';

  protected function setUp(): void {
    parent::setUp();
    $this->container->get('module_installer')->install(['canvas', 'dblog', 'toolbar']);
    $this->rebuildAll();
    $role = Yaml::decode(file_get_contents($this->root . self::ROLE_CONFIG));
    unset($role['uuid'], $role['dependencies']);
    Role::create($role)->save();
  }

  public function testDemoEditorAccess(): void {
    $session = $this->createSession('Theming with SDC', 10);
    $page = Page::create(['title' => 'Try Canvas here']);
    $page->save();

    $editor = $this->drupalCreateUser();
    $editor->addRole('demo_editor')->save();
    $admin = $this->drupalCreateUser([
      'access site reports',
      'administer registration',
      'administer code components',
      'administer components',
      'administer themes',
      'create canvas_page',
      'edit canvas_page',
    ]);

    $refused = [
      '/admin/reports/dblog',
      '/node/' . $session->id() . '/registrations',
      '/admin/appearance/component/status',
    ];

    $this->drupalLogin($admin);
    foreach ($refused as $path) {
      $this->drupalGet($path);
      $this->assertSession()->statusCodeEquals(200);
    }
    $this->assertTrue($this->mayCreateCodeComponent($admin), 'An administrator may create code components.');

    $this->drupalLogin($editor);
    foreach ($refused as $path) {
      $this->drupalGet($path);
      $this->assertSession()->statusCodeEquals(403);
    }
    $this->assertFalse($this->mayCreateCodeComponent($editor), 'A demo editor may not create code components.');

    $this->drupalGet('/canvas/editor/canvas_page/' . $page->id());
    $this->assertSession()->statusCodeEquals(200);
  }

  /**
   * Checks the Canvas route that creates a code component, for one account.
   */
  private function mayCreateCodeComponent(AccountInterface $account): bool {
    return $this->container->get('access_manager')->checkNamedRoute(
      'canvas.api.config.post',
      ['canvas_config_entity_type_id' => 'js_component'],
      $account,
    );
  }

}
