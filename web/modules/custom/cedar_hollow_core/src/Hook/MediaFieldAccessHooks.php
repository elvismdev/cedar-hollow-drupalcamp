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
 * Lets only media administrators set media author, status and verified flag.
 *
 * The credits page lists verified images only, and an uploader keeps the
 * current user as author and the bundle's published default, so an account
 * that may upload images but not administer media must not change any of
 * these fields on any form or API.
 */
final class MediaFieldAccessHooks {

  /**
   * The permission that may edit the administrator-only media fields.
   */
  public const ADMIN_PERMISSION = 'administer media';

  /**
   * The media field that publishes an image on the credits page.
   */
  public const VERIFIED_FIELD = 'field_verified';

  /**
   * The media fields only an administrator may edit.
   *
   * @var list<string>
   */
  public const ADMIN_ONLY_FIELDS = [self::VERIFIED_FIELD, 'uid', 'status'];

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
      || !in_array($field_definition->getName(), self::ADMIN_ONLY_FIELDS, TRUE)) {
      return AccessResult::neutral();
    }
    return AccessResult::forbiddenIf(!$account->hasPermission(self::ADMIN_PERMISSION))->cachePerPermissions();
  }

}
