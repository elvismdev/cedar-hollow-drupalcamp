<?php

declare(strict_types=1);

namespace Drupal\Tests\cedar_hollow_core\Functional;

use Drupal\registration\Entity\Registration;
use PHPUnit\Framework\Attributes\Group;
use PHPUnit\Framework\Attributes\RunTestsInSeparateProcesses;

/**
 * Seat counts on themed session pages change as soon as someone signs up.
 *
 * The cedar_hollow theme's preprocess adds the session's registration list
 * cache tag, so the anonymous page cache drops its copy of the session page
 * and of the listing when a registration is saved.
 */
#[Group('cedar_hollow_core')]
#[Group('cedar_hollow_theme')]
#[RunTestsInSeparateProcesses]
final class SessionPageCacheTagTest extends SessionTestBase {

  /**
   * {@inheritdoc}
   */
  protected function setUp(): void {
    parent::setUp();
    // The theme depends on cedar_hollow_core, which the recipe's modules must
    // precede, so it is installed here rather than through $defaultTheme.
    $this->container->get('theme_installer')->install(['cedar_hollow']);
    $this->config('system.theme')->set('default', 'cedar_hollow')->save();
    $this->rebuildAll();
  }

  /**
   * Tests the seats text on the session page and the listing after a sign-up.
   */
  public function testSeatsTextFollowsRegistrations(): void {
    $session = $this->createSession('Theming with SDC', 1);
    $tag = 'registration_list.host_entity:node:' . $session->id();

    $this->drupalGet($session->toUrl());
    $this->assertSession()->statusCodeEquals(200);
    $this->assertSession()->pageTextContains('1 of 1 seats left');
    $this->assertSession()->elementExists('css', '.seats-indicator--low');
    $this->assertContains($tag, explode(' ', (string) $this->getSession()->getResponseHeader('X-Drupal-Cache-Tags')));
    $this->drupalGet($session->toUrl());
    $this->assertSession()->responseHeaderEquals('X-Drupal-Cache', 'HIT');

    $this->drupalGet('sessions');
    $this->assertSession()->pageTextContains('1 of 1 seats left');

    Registration::create([
      'type' => 'attendee',
      'entity_type_id' => 'node',
      'entity_id' => $session->id(),
      'anon_mail' => 'someone@example.com',
      'count' => 1,
    ])->save();

    $this->drupalGet($session->toUrl());
    $this->assertSession()->responseHeaderEquals('X-Drupal-Cache', 'MISS');
    $this->assertSession()->pageTextContains('Full, wait list open');
    $this->assertSession()->pageTextNotContains('1 of 1 seats left');

    $this->drupalGet('sessions');
    $this->assertSession()->pageTextContains('Full, wait list open');
  }

}
