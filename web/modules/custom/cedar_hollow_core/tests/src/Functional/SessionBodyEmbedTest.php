<?php

declare(strict_types=1);

namespace Drupal\Tests\cedar_hollow_core\Functional;

use Drupal\ckeditor5\Plugin\Editor\CKEditor5;
use Drupal\editor\Entity\Editor;
use Drupal\file\Entity\File;
use Drupal\filter\Entity\FilterFormat;
use Drupal\media\Entity\Media;
use PHPUnit\Framework\Attributes\Group;
use PHPUnit\Framework\Attributes\RunTestsInSeparateProcesses;

/**
 * Session bodies embed Image media with captions and nothing unsafe.
 */
#[Group('cedar_hollow_core')]
#[RunTestsInSeparateProcesses]
final class SessionBodyEmbedTest extends SessionTestBase {

  /**
   * Tests that the format and editor the recipe installs are a valid pair.
   */
  public function testFormatAndEditorAreValid(): void {
    $format = FilterFormat::load('session_html');
    $editor = Editor::load('session_html');
    $this->assertNotNull($format);
    $this->assertNotNull($editor);
    $messages = array_map(static fn($violation) => (string) $violation->getMessage(), iterator_to_array(CKEditor5::validatePair($editor, $format)));
    $this->assertSame([], $messages);
  }

  /**
   * Tests that both embed view modes render a captioned figure.
   */
  public function testEmbedsRenderCaptionedFigures(): void {
    $image = $this->getTestFiles('image')[0];
    $file = File::create(['uri' => $image->uri, 'status' => 1]);
    $file->save();
    $media = Media::create([
      'bundle' => 'image',
      'name' => 'Embedded photo',
      'field_media_image' => ['target_id' => $file->id(), 'alt' => 'Laptops on a table'],
      'field_source_url' => 'https://commons.wikimedia.org/wiki/File:Example.jpg',
      'field_creator' => 'Example creator',
      'field_licence' => 'cc0',
      'field_licence_url' => 'https://creativecommons.org/publicdomain/zero/1.0/',
      'status' => 1,
    ]);
    $media->save();

    $embed = static fn(string $view_mode, string $caption) => sprintf(
      '<drupal-media data-entity-type="media" data-entity-uuid="%s" data-view-mode="%s" data-caption="%s"></drupal-media>',
      $media->uuid(),
      $view_mode,
      $caption,
    );
    $session = $this->createSession('Images in Drupal', 10);
    $session->set('body', [
      'value' => '<p style="color: red">Intro.</p>'
      . $embed('embed_wide', 'A wide caption')
      . '<script>alert(1)</script><img src="/core/misc/druplicon.png" alt="">'
      . $embed('embed_photo', 'A photo caption'),
      'format' => 'session_html',
    ])->save();

    $this->drupalGet($session->toUrl());
    $assert = $this->assertSession();
    $assert->statusCodeEquals(200);
    $assert->elementsCount('css', 'figure', 2);
    $assert->elementTextEquals('css', 'figure:nth-of-type(1) figcaption', 'A wide caption');
    $assert->elementTextEquals('css', 'figure:nth-of-type(2) figcaption', 'A photo caption');
    $assert->elementAttributeContains('css', 'figure:nth-of-type(1) img', 'srcset', '/styles/16_9_640/');
    $assert->elementAttributeContains('css', 'figure:nth-of-type(2) img', 'srcset', '/styles/3_2_400/');
    $assert->elementAttributeContains('css', 'figure:nth-of-type(2) img', 'sizes', 'auto,');

    // filter_html drops the element and keeps its text as plain text.
    $assert->responseNotContains('<script>alert(1)');
    $assert->responseNotContains('druplicon.png');
    $assert->responseNotContains('color: red');
  }

}
