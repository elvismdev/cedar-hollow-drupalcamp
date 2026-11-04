<?php

declare(strict_types=1);

namespace Drupal\cedar_hollow_core\Hook;

use Drupal\Core\Access\AccessResult;
use Drupal\Core\Access\AccessResultInterface;
use Drupal\Core\Field\FieldDefinitionInterface;
use Drupal\Core\Field\FieldItemListInterface;
use Drupal\Core\Hook\Attribute\Hook;
use Drupal\Core\Session\AccountInterface;

/**
 * Lets only media administrators mark an image verified.
 *
 * The credits page lists verified images only, so an account that may upload
 * images but not administer media must not set the flag on any form or API.
 */
final class MediaFieldAccessHooks {

  /**
   * The media field that publishes an image on the credits page.
   */
  public const VERIFIED_FIELD = 'field_verified';

  /**
   * Implements hook_entity_field_access().
   *
   * @param string $operation
   *   The operation to check.
   * @param \Drupal\Core\Field\FieldDefinitionInterface $field_definition
   *   The field being checked.
   * @param \Drupal\Core\Session\AccountInterface $account
   *   The account to check.
   * @param \Drupal\Core\Field\FieldItemListInterface<\Drupal\Core\Field\FieldItemInterface>|null $items
   *   The field's values, when an entity is given.
   */
  #[Hook('entity_field_access')]
  public function entityFieldAccess(string $operation, FieldDefinitionInterface $field_definition, AccountInterface $account, ?FieldItemListInterface $items = NULL): AccessResultInterface {
    if ($operation !== 'edit'
      || $field_definition->getTargetEntityTypeId() !== 'media'
      || $field_definition->getName() !== self::VERIFIED_FIELD) {
      return AccessResult::neutral();
    }
    return AccessResult::forbiddenIf(!$account->hasPermission('administer media'))->cachePerPermissions();
  }

}
