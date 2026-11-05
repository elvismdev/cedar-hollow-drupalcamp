<?php

declare(strict_types=1);

namespace Drupal\cedar_hollow_core\EventSubscriber;

use Drupal\Core\StringTranslation\StringTranslationTrait;
use Drupal\registration\Event\RegistrationDataAlterEvent;
use Drupal\registration\Event\RegistrationEvents;
use Drupal\registration\RegistrationValidationResultInterface;
use Symfony\Component\EventDispatcher\EventSubscriberInterface;
use Symfony\Component\Validator\ConstraintViolation;

/**
 * Keeps the duplicate-address message from echoing the address.
 *
 * Registration's UniqueRegistrant constraint refuses a second sign-up with an
 * address already registered for the session, and its message repeats that
 * address, which tells any anonymous visitor whether it signed up. The
 * refusal is kept; only the message text changes.
 */
final class DuplicateRegistrantMessageSubscriber implements EventSubscriberInterface {

  use StringTranslationTrait;

  /**
   * The violation code UniqueRegistrant sets for an address already in use.
   */
  private const DUPLICATE_EMAIL_CODE = 'email';

  /**
   * Replaces the duplicate-address violation with one that omits the address.
   *
   * @param \Drupal\registration\Event\RegistrationDataAlterEvent $event
   *   The validation result alter event.
   */
  public function alterValidationResult(RegistrationDataAlterEvent $event): void {
    $result = $event->getData();
    if (!$result instanceof RegistrationValidationResultInterface || !$result->hasViolationWithCode(self::DUPLICATE_EMAIL_CODE)) {
      return;
    }
    $violations = $result->getViolations();
    foreach ($violations as $offset => $violation) {
      if (!$violation instanceof ConstraintViolation || $violation->getCode() !== self::DUPLICATE_EMAIL_CODE) {
        continue;
      }
      $message = $this->t('This email address cannot be registered for this session. If you already signed up, you do not need to register again.');
      $violations->set($offset, new ConstraintViolation(
        $message,
        $message->getUntranslatedString(),
        [],
        $violation->getRoot(),
        $violation->getPropertyPath(),
        $violation->getInvalidValue(),
        $violation->getPlural(),
        $violation->getCode(),
        $violation->getConstraint(),
        $violation->getCause(),
      ));
    }
  }

  /**
   * {@inheritdoc}
   */
  public static function getSubscribedEvents(): array {
    return [
      RegistrationEvents::REGISTRATION_ALTER_VALIDATION_RESULT => 'alterValidationResult',
    ];
  }

}
