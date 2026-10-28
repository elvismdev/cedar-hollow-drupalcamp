<?php

declare(strict_types=1);

namespace Drupal\cedar_hollow_core\Hook;

use Drupal\Core\Entity\EntityTypeManagerInterface;
use Drupal\Core\Extension\ModuleHandlerInterface;
use Drupal\Core\Hook\Attribute\Hook;

/**
 * Keeps Canvas's compiled code component files present.
 *
 * Canvas writes each code component's compiled JavaScript and CSS to public
 * files only when the component is saved. A site that receives its database
 * without those files, as a copy to Pantheon does, then serves the component
 * as a missing script. Writing them again on every cache rebuild means
 * `drush deploy` repairs such a site; the file names are content hashes, so an
 * unchanged component rewrites identical files.
 */
final class CanvasAssetHooks {

  /**
   * Config entity types whose compiled assets Canvas writes to public files.
   */
  private const ASSET_ENTITY_TYPES = ['js_component', 'asset_library'];

  public function __construct(
    private readonly EntityTypeManagerInterface $entityTypeManager,
    private readonly ModuleHandlerInterface $moduleHandler,
  ) {}

  /**
   * Implements hook_rebuild().
   */
  #[Hook('rebuild')]
  public function rebuild(): void {
    if (!$this->moduleHandler->moduleExists('canvas')) {
      return;
    }
    foreach (self::ASSET_ENTITY_TYPES as $entity_type_id) {
      $storage = $this->entityTypeManager->getStorage($entity_type_id);
      foreach ($storage->loadMultiple() as $entity) {
        $storage->generateFiles($entity);
      }
    }
  }

}
