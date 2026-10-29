<?php

declare(strict_types=1);

namespace Drupal\Tests\cedar_hollow_core\Unit;

use Drupal\cedar_hollow_core\SessionBody;
use Drupal\Tests\UnitTestCase;
use PHPUnit\Framework\Attributes\CoversClass;
use PHPUnit\Framework\Attributes\Group;

/**
 * Tests the conversion of plain-text session bodies.
 */
#[CoversClass(SessionBody::class)]
#[Group('cedar_hollow_core')]
final class SessionBodyTest extends UnitTestCase {

  /**
   * Tests that paragraphs, line breaks and markup characters survive.
   */
  public function testFromPlainText(): void {
    $text = "Render arrays & <caching>.\n\nTags, contexts\nand max-age.\n";
    $this->assertSame(
      "<p>Render arrays &amp; &lt;caching&gt;.</p>\n<p>Tags, contexts<br>\nand max-age.</p>",
      SessionBody::fromPlainText($text),
    );
  }

}
