<?php

declare(strict_types=1);

namespace Drupal\cedar_hollow_core\Hook;

use Drupal\cedar_hollow_core\Validation\UniqueRegistrantConstraint;
use Drupal\Core\Hook\Attribute\Hook;

/**
 * Swaps in a duplicate-registrant message that omits the address.
 */
final class RegistrationConstraintHooks {

  /**
   * Implements hook_registration_validation_constraint_alter().
   *
   * @param array<string, array<string, mixed>> $definitions
   *   The registration constraint plugin definitions, keyed by plugin ID.
   */
  #[Hook('registration_validation_constraint_alter')]
  public function constraintAlter(array &$definitions): void {
    if (isset($definitions['UniqueRegistrant'])) {
      $definitions['UniqueRegistrant']['class'] = UniqueRegistrantConstraint::class;
    }
  }

}
