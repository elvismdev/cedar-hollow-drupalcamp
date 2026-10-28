<?php

declare(strict_types=1);

namespace Drupal\Tests\cedar_hollow_core\Functional;

use Drupal\registration\Entity\Registration;
use PHPUnit\Framework\Attributes\Group;
use PHPUnit\Framework\Attributes\RunTestsInSeparateProcesses;

/**
 * The agenda JSON follows its contract and drops cached copies on sign-up.
 */
#[Group('cedar_hollow_core')]
#[RunTestsInSeparateProcesses]
final class AgendaEndpointTest extends SessionTestBase {

  private const KEYS = [
    'id', 'title', 'url', 'start', 'end', 'day', 'room', 'track',
    'registerUrl', 'capacity', 'remaining', 'full', 'waitlist', 'open',
  ];

  /**
   * Tests the agenda JSON contract and that a sign-up drops its cached copy.
   */
  public function testSeatsAreNearLive(): void {
    $session = $this->createSession('Keynote', 40);

    // Twice as anonymous: the second response must come from the page cache,
    // so the later change proves invalidation, not a cold cache.
    $this->drupalGet('api/agenda');
    $this->drupalGet('api/agenda');
    $this->assertSession()->responseHeaderEquals('X-Drupal-Cache', 'HIT');
    $before = $this->agenda();
    $this->assertSame(self::KEYS, array_keys($before[0]));
    $this->assertSame(40, $before[0]['remaining']);
    $this->assertIsString($before[0]['registerUrl']);
    $this->assertFalse($before[0]['full']);
    $this->assertSame('2027-03-12T09:00:00-05:00', $before[0]['start']);

    Registration::create([
      'type' => 'attendee',
      'entity_type_id' => 'node',
      'entity_id' => $session->id(),
      'anon_mail' => 'someone@example.com',
      'count' => 1,
    ])->save();

    $this->drupalGet('api/agenda');
    $this->assertSession()->responseHeaderEquals('X-Drupal-Cache', 'MISS');
    $this->assertSame(39, $this->agenda()[0]['remaining']);
    $this->assertSession()->responseHeaderContains('X-Drupal-Cache-Tags', 'registration_list.host_entity:node:' . $session->id());
    $contexts = $this->cacheContexts();
    $this->assertNotContains('user', $contexts);
    $this->assertContains('user.permissions', $contexts);
  }

  /**
   * Returns the sessions from the current JSON response.
   *
   * @return list<array<string, mixed>>
   *   The sessions.
   */
  private function agenda(): array {
    return json_decode($this->getSession()->getPage()->getContent(), TRUE)['sessions'];
  }

}
