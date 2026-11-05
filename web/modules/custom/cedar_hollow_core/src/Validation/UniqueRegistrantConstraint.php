<?php

declare(strict_types=1);

namespace Drupal\cedar_hollow_core\Validation;

use Drupal\registration\Plugin\Validation\RegistrationConstraint\UniqueRegistrantConstraint as RegistrationUniqueRegistrantConstraint;
use Drupal\registration\Plugin\Validation\RegistrationConstraint\UniqueRegistrantConstraintValidator;

/**
 * Registration's UniqueRegistrant constraint without the address in its text.
 *
 * The original message repeats the submitted address, which tells any
 * anonymous visitor whether that address signed up. The validator still
 * passes %mail as a parameter; a message without the placeholder ignores it.
 */
final class UniqueRegistrantConstraint extends RegistrationUniqueRegistrantConstraint {

  /**
   * Email address is already registered.
   */
  public string $emailAlreadyRegisteredMessage = 'This email address is already registered for this session.';

  /**
   * {@inheritdoc}
   */
  public function validatedBy(): string {
    // The parent would derive the validator from this class's name.
    return UniqueRegistrantConstraintValidator::class;
  }

}
