<?php

declare(strict_types=1);

namespace Drupal\cedar_hollow_core;

use Drupal\Core\Cache\CacheableMetadata;
use Drupal\Core\Entity\EntityTypeManagerInterface;
use Drupal\Core\StringTranslation\StringTranslationTrait;
use Drupal\node\NodeInterface;
use Drupal\registration_waitlist\HostEntityInterface as WaitListHostEntityInterface;

/**
 * Describes a session's seats as one display state and its text.
 *
 * The same rule is implemented in JavaScript by the agenda builder, which
 * reads raw numbers from /api/agenda. The seats always come from Entity
 * Registration's host entity.
 */
final class SeatsSummary {

  use StringTranslationTrait;

  /**
   * Remaining seats at or below this count are shown as "low".
   */
  public const LOW_THRESHOLD = 5;

  public function __construct(
    private readonly EntityTypeManagerInterface $entityTypeManager,
  ) {}

  /**
   * Returns the seats summary for a session, or NULL if it takes no sign-ups.
   *
   * @param \Drupal\node\NodeInterface $node
   *   The session.
   * @param \Drupal\Core\Cache\CacheableMetadata $cacheability
   *   Receives the host entity's cache metadata and the session's
   *   registration list cache tag, which Registration invalidates whenever a
   *   registration for the session is saved or deleted.
   *
   * @return array{remaining: ?int, capacity: int, state: string, text: string}|null
   *   The summary.
   */
  public function summarize(NodeInterface $node, CacheableMetadata $cacheability): ?array {
    $host = $this->entityTypeManager
      ->getHandler('node', 'registration_host_entity')
      ->createHostEntity($node);
    $cacheability->addCacheableDependency($host);
    if (!$host->isConfiguredForRegistration()) {
      return NULL;
    }
    $cacheability->addCacheTags([$host->getRegistrationListCacheTag()]);
    $open = $host->isOpenForRegistration(TRUE);
    $cacheability->addCacheableDependency($open->getCacheableMetadata());

    $capacity = (int) $host->getSetting('capacity');
    $remaining = $host->getSpacesRemaining();
    $waitlist = $host instanceof WaitListHostEntityInterface && $host->isWaitListEnabled();
    $state = self::state($open->isValid(), $capacity, $remaining, $waitlist);

    return [
      'remaining' => $remaining,
      'capacity' => $capacity,
      'state' => $state,
      'text' => (string) match ($state) {
        'closed' => $this->t('Sign-up closed'),
        'unlimited' => $this->t('Open seating'),
        'full' => $this->t('Full'),
        'waitlist' => $this->t('Full, wait list open'),
        default => $this->t('@remaining of @capacity seats left', ['@remaining' => $remaining, '@capacity' => $capacity]),
      },
    ];
  }

  /**
   * Maps seat numbers to a display state.
   */
  public static function state(bool $open, int $capacity, ?int $remaining, bool $waitlist): string {
    return match (TRUE) {
      !$open => 'closed',
      $capacity === 0 => 'unlimited',
      $remaining === 0 => $waitlist ? 'waitlist' : 'full',
      $remaining <= self::LOW_THRESHOLD => 'low',
      default => 'open',
    };
  }

}
