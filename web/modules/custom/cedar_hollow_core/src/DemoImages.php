<?php

declare(strict_types=1);

namespace Drupal\cedar_hollow_core;

/**
 * Limits and locations shared by the demo image scripts.
 *
 * The scripts in scripts/ fetch the demo photos, put them on a site and
 * check them after a rebuild; all three apply these values.
 */
final class DemoImages {

  /**
   * Width of the widest image style the hero feeds, in pixels.
   */
  public const HERO_WIDTH = 2304;

  /**
   * Largest hero original, in bytes.
   */
  public const HERO_CAP = 900 * 1024;

  /**
   * Largest original of every other image, in bytes.
   */
  public const CAP = 400 * 1024;

  /**
   * Largest total of all originals, in bytes.
   */
  public const TOTAL_CAP = 10 * 1024 * 1024;

  /**
   * Where fetched originals wait in the web container before placing.
   */
  public const FETCHED_DIR = '/tmp/cedar-hollow-images';

  /**
   * Where placed originals are stored.
   */
  public const FILES_DIR = 'public://demo-images';

}
