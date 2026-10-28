<?php

declare(strict_types=1);

namespace Drupal\cedar_hollow_core\Controller;

use Drupal\Core\Cache\CacheableJsonResponse;
use Drupal\Core\Cache\CacheableMetadata;
use Drupal\Core\DependencyInjection\ContainerInjectionInterface;
use Drupal\Core\Entity\EntityTypeManagerInterface;
use Drupal\Core\Url;
use Drupal\node\NodeInterface;
use Drupal\registration_waitlist\HostEntityInterface as WaitListHostEntityInterface;
use Symfony\Component\DependencyInjection\ContainerInterface;

/**
 * Returns every published session with its seats, for the agenda builder.
 *
 * Seats come from Entity Registration's host entity, never from a count of our
 * own. The response carries each session's registration list cache tag, which
 * Registration invalidates whenever a registration for that session changes,
 * so cached copies are dropped as soon as a seat is taken.
 */
final class AgendaController implements ContainerInjectionInterface {

  /**
   * The node bundle that hosts registrations.
   */
  public const SESSION_BUNDLE = 'session';

  /**
   * Time zone the camp runs in; sessions are formatted in it explicitly.
   */
  public const TIME_ZONE = 'America/New_York';

  public function __construct(
    private readonly EntityTypeManagerInterface $entityTypeManager,
  ) {}

  /**
   * {@inheritdoc}
   */
  public static function create(ContainerInterface $container): static {
    return new static($container->get('entity_type.manager'));
  }

  /**
   * Returns every published session with its seats as JSON.
   */
  public function list(): CacheableJsonResponse {
    $cacheability = (new CacheableMetadata())
      ->addCacheTags(['node_list:' . self::SESSION_BUNDLE])
      ->addCacheContexts(['user.permissions', 'user.node_grants:view']);

    $storage = $this->entityTypeManager->getStorage('node');
    $nids = $storage->getQuery()
      ->accessCheck(TRUE)
      ->condition('type', self::SESSION_BUNDLE)
      ->condition('status', 1)
      ->sort('field_session_time.value')
      ->sort('title')
      ->execute();

    $handler = $this->entityTypeManager->getHandler('node', 'registration_host_entity');
    $time_zone = new \DateTimeZone(self::TIME_ZONE);
    $sessions = [];
    foreach ($storage->loadMultiple($nids) as $node) {
      assert($node instanceof NodeInterface);
      $host = $handler->createHostEntity($node);
      $cacheability->addCacheableDependency($host);
      if (!$host->isConfiguredForRegistration()) {
        continue;
      }
      // HostEntity::getCacheTags() does not include the list tag.
      $cacheability->addCacheTags([$host->getRegistrationListCacheTag()]);

      // isOpenForRegistration(), not isAvailableForRegistration(): the latter
      // adds the user context and would split the cache per user.
      $open = $host->isOpenForRegistration(TRUE);
      $cacheability->addCacheableDependency($open->getCacheableMetadata());

      $url = $node->toUrl()->toString(TRUE);
      $cacheability->addCacheableDependency($url);
      $register_url = NULL;
      if ($open->isValid()) {
        $generated = Url::fromRoute('entity.node.registration.register', ['node' => $node->id()])->toString(TRUE);
        $cacheability->addCacheableDependency($generated);
        $register_url = $generated->getGeneratedUrl();
      }

      $track = $node->get('field_track')->entity;
      if ($track) {
        $cacheability->addCacheableDependency($track);
      }

      $time = $node->get('field_session_time')->first();
      $capacity = (int) $host->getSetting('capacity');
      $remaining = $host->getSpacesRemaining();
      $full = $remaining === 0;
      $waitlist = $full
        && $host instanceof WaitListHostEntityInterface
        && $host->isWaitListEnabled();

      $sessions[] = [
        'id' => (int) $node->id(),
        'title' => $node->label(),
        'url' => $url->getGeneratedUrl(),
        'start' => $time ? (new \DateTimeImmutable('@' . $time->value))->setTimezone($time_zone)->format(DATE_ATOM) : NULL,
        'end' => $time ? (new \DateTimeImmutable('@' . $time->end_value))->setTimezone($time_zone)->format(DATE_ATOM) : NULL,
        'day' => $node->get('field_day')->value,
        'room' => $node->get('field_room')->value,
        'track' => $track?->label(),
        'registerUrl' => $register_url,
        'capacity' => $capacity,
        'remaining' => $remaining,
        'full' => $full,
        'waitlist' => $waitlist,
        'open' => $open->isValid(),
      ];
    }

    $response = new CacheableJsonResponse([
      'generated' => (new \DateTimeImmutable('now', $time_zone))->format(DATE_ATOM),
      'sessions' => $sessions,
    ]);
    $response->addCacheableDependency($cacheability);
    return $response;
  }

}
