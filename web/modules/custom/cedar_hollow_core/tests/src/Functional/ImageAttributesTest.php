<?php

declare(strict_types=1);

namespace Drupal\Tests\cedar_hollow_core\Functional;

use Drupal\file\Entity\File;
use Drupal\media\Entity\Media;
use PHPUnit\Framework\Attributes\Group;
use PHPUnit\Framework\Attributes\RunTestsInSeparateProcesses;

/**
 * A session image keeps its class and fetch priority whatever renders first.
 *
 * Media is render-cached per media view mode, so the theme's image
 * attributes must not depend on the page that first rendered the media.
 */
#[Group('cedar_hollow_core')]
#[Group('cedar_hollow_theme')]
#[RunTestsInSeparateProcesses]
final class ImageAttributesTest extends SessionTestBase {

  /**
   * {@inheritdoc}
   */
  protected function setUp(): void {
    parent::setUp();
    $this->container->get('theme_installer')->install(['cedar_hollow']);
    $this->config('system.theme')->set('default', 'cedar_hollow')->save();
    $this->rebuildAll();
  }

  /**
   * Tests a session page after the same media was rendered in an RSS item.
   */
  public function testSessionImageAfterAnotherViewModeRendersFirst(): void {
    $image = $this->getTestFiles('image')[0];
    $file = File::create(['uri' => $image->uri, 'status' => 1]);
    $file->save();
    $media = Media::create([
      'bundle' => 'image',
      'name' => 'Session photo',
      'field_media_image' => ['target_id' => $file->id(), 'alt' => 'Server racks'],
      'field_source_url' => 'https://commons.wikimedia.org/wiki/File:Example.jpg',
      'field_creator' => 'Example creator',
      'field_licence' => 'cc0',
      'field_licence_url' => 'https://creativecommons.org/publicdomain/zero/1.0/',
      'status' => 1,
    ]);
    $media->save();
    $session = $this->createSession('Caching render arrays', 10);
    $session->set('field_image', $media->id())->save();

    // The RSS display falls back to the default display, which shows the
    // image in the page media view mode and so fills its render cache.
    $build = $this->container->get('entity_type.manager')->getViewBuilder('node')->view($session, 'rss');
    $rss = (string) $this->container->get('renderer')->renderInIsolation($build);
    // The setup only tests something if the RSS item rendered the media in
    // the page view mode, whose 16:9 styles the session page uses too.
    $this->assertStringContainsString('16_9_', $rss);

    $this->drupalGet($session->toUrl());
    $this->assertSession()->elementAttributeContains('css', 'img[srcset*="16_9_"]', 'class', 'hero__img');
    $this->assertSession()->elementAttributeContains('css', 'img[srcset*="16_9_"]', 'fetchpriority', 'high');
  }

}
