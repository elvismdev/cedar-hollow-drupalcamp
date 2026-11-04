<?php

declare(strict_types=1);

namespace Drupal\Tests\cedar_hollow_core\Functional;

use Drupal\canvas\Entity\Page;
use Drupal\cedar_hollow_core\Hook\MediaFieldAccessHooks;
use Drupal\Component\Serialization\Yaml;
use Drupal\Core\Session\AccountInterface;
use Drupal\file\Entity\File;
use Drupal\media\Entity\Media;
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

  /**
   * The media form's "Authored by" input.
   */
  private const AUTHOR_WIDGET = 'uid[0][target_id]';

  /**
   * The media form's "Published" checkbox.
   */
  private const STATUS_WIDGET = 'status[value]';

  /**
   * {@inheritdoc}
   */
  protected function setUp(): void {
    parent::setUp();
    $this->container->get('module_installer')->install(['canvas', 'dblog', 'toolbar']);
    $this->rebuildAll();
    $role = Yaml::decode(file_get_contents($this->root . self::ROLE_CONFIG));
    unset($role['uuid'], $role['dependencies']);
    Role::create($role)->save();
  }

  /**
   * Tests what the demo editor role is refused and allowed.
   */
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
      'access media overview',
      'administer media',
      'administer media types',
    ]);
    $image = $this->getTestFiles('image')[0];
    $file = File::create(['uri' => $image->uri, 'status' => 1]);
    $file->save();
    $media = Media::create([
      'bundle' => 'image',
      'name' => 'Someone else\'s image',
      'uid' => $admin->id(),
      'field_media_image' => ['target_id' => $file->id(), 'alt' => 'A test image'],
    ]);
    $media->save();

    $refused = [
      '/admin/reports/dblog',
      '/node/' . $session->id() . '/registrations',
      '/admin/appearance/component/status',
      '/admin/content/media',
      '/media/' . $media->id() . '/edit',
      '/media/' . $media->id() . '/delete',
      '/admin/structure/media',
    ];

    $this->drupalLogin($admin);
    foreach ($refused as $path) {
      $this->drupalGet($path);
      $this->assertSession()->statusCodeEquals(200);
    }
    $this->assertTrue($this->mayCreateCodeComponent($admin), 'An administrator may create code components.');
    $this->drupalGet('/media/add/image');
    $this->assertSession()->fieldExists(MediaFieldAccessHooks::VERIFIED_FIELD . '[value]');
    $this->assertTrue($media->get(MediaFieldAccessHooks::VERIFIED_FIELD)->access('edit', $admin), 'An administrator may mark an image verified.');
    $this->assertSession()->fieldExists(self::AUTHOR_WIDGET);
    $this->assertSession()->fieldExists(self::STATUS_WIDGET);
    foreach (MediaFieldAccessHooks::ADMINISTERED_BASE_FIELDS as $field_name) {
      $this->assertTrue($media->get($field_name)->access('edit', $admin), "An administrator may edit the image's $field_name field.");
    }

    $this->drupalLogin($editor);
    foreach ($refused as $path) {
      $this->drupalGet($path);
      $this->assertSession()->statusCodeEquals(403);
    }
    $this->assertFalse($this->mayCreateCodeComponent($editor), 'A demo editor may not create code components.');

    $this->drupalGet('/canvas/editor/canvas_page/' . $page->id());
    $this->assertSession()->statusCodeEquals(200);
    // Canvas's media picker uploads through Media Library's add form.
    $this->drupalGet('/media/add/image');
    $this->assertSession()->statusCodeEquals(200);
    // The credits page lists verified images, so an editor cannot verify one.
    $this->assertSession()->fieldNotExists(MediaFieldAccessHooks::VERIFIED_FIELD . '[value]');
    // An upload keeps the current user as author and the published default.
    $this->assertSession()->fieldNotExists(self::AUTHOR_WIDGET);
    $this->assertSession()->fieldNotExists(self::STATUS_WIDGET);
    $this->assertFalse($media->get(MediaFieldAccessHooks::VERIFIED_FIELD)->access('edit', $editor), 'A demo editor may not mark an image verified.');
    $this->assertTrue($media->get(MediaFieldAccessHooks::VERIFIED_FIELD)->access('view', $editor), 'A demo editor may still view the verified flag.');
    $own = Media::create([
      'bundle' => 'image',
      'name' => 'The editor\'s own image',
      'uid' => $editor->id(),
      'field_media_image' => ['target_id' => $file->id(), 'alt' => 'A test image'],
    ]);
    $own->save();
    $this->assertFalse($own->get(MediaFieldAccessHooks::VERIFIED_FIELD)->access('edit', $editor), 'A demo editor may not mark their own image verified.');
    foreach (MediaFieldAccessHooks::ADMINISTERED_BASE_FIELDS as $field_name) {
      $this->assertFalse($media->get($field_name)->access('edit', $editor), "A demo editor may not edit another account's image $field_name field.");
      $this->assertFalse($own->get($field_name)->access('edit', $editor), "A demo editor may not edit their own image $field_name field.");
      $this->assertTrue($own->get($field_name)->access('view', $editor), "A demo editor may still view the image $field_name field.");
    }
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
