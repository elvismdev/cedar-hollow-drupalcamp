<?php

declare(strict_types=1);

namespace Drupal\Tests\cedar_hollow_core\Functional;

use Drupal\FunctionalTests\Core\Recipe\RecipeTestTrait;
use Drupal\node\NodeInterface;
use Drupal\registration\RegistrationSettingsStorage;
use Drupal\Tests\BrowserTestBase;

/**
 * Builds the session feature from the cedar_hollow_sessions recipe.
 *
 * Applying the recipe here is also the recipe's test: if it stops applying,
 * every functional test in this module fails in setUp().
 */
abstract class SessionTestBase extends BrowserTestBase {

  use RecipeTestTrait;

  /**
   * {@inheritdoc}
   */
  protected $defaultTheme = 'stark';

  /**
   * {@inheritdoc}
   */
  protected static $modules = ['block', 'page_cache', 'dynamic_page_cache'];

  /**
   * {@inheritdoc}
   */
  protected function setUp(): void {
    parent::setUp();
    $this->applyRecipe(realpath($this->root . '/../recipes/cedar_hollow_sessions'));
    $this->container->get('module_installer')->install(['cedar_hollow_core']);
    $this->rebuildAll();
    // Stark places no blocks, so status messages need their block.
    $this->drupalPlaceBlock('system_messages_block');
  }

  /**
   * Creates a published session with the given capacity.
   */
  protected function createSession(string $title, int $capacity, bool $waitlist = TRUE): NodeInterface {
    $start = strtotime('2027-03-12 09:00 America/New_York');
    $node = $this->drupalCreateNode([
      'type' => 'session',
      'title' => $title,
      'field_day' => 'fri',
      'field_room' => 'Hall A',
      'field_session_time' => ['value' => $start, 'end_value' => $start + 2700, 'duration' => 45],
      'field_registration' => ['registration_type' => 'attendee'],
      'status' => 1,
    ]);
    $etm = $this->container->get('entity_type.manager');
    $host = $etm->getHandler('node', 'registration_host_entity')->createHostEntity($node);
    $storage = $etm->getStorage('registration_settings');
    $this->assertInstanceOf(RegistrationSettingsStorage::class, $storage);
    $settings = $storage->loadSettingsForHostEntity($host);
    $settings->set('status', TRUE);
    $settings->set('capacity', $capacity);
    $settings->set('registration_waitlist_enable', $waitlist);
    $settings->save();
    return $node;
  }

  /**
   * Returns the cache contexts header as a list.
   *
   * @return list<string>
   *   The cache contexts.
   */
  protected function cacheContexts(): array {
    return array_values(array_filter(explode(' ', (string) $this->getSession()->getResponseHeader('X-Drupal-Cache-Contexts'))));
  }

}
