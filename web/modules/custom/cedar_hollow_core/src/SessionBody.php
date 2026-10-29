<?php

declare(strict_types=1);

namespace Drupal\cedar_hollow_core;

use Drupal\Component\Utility\Html;

/**
 * The text format of session bodies and the conversion into it.
 *
 * The session body field allows only this format, so a body stored in any
 * other format makes the editor choose one before saving.
 */
final class SessionBody {

  /**
   * The only text format the session body field allows.
   */
  public const FORMAT = 'session_html';

  /**
   * Converts plain text to paragraphs, keeping single line breaks.
   *
   * @param string $text
   *   Plain text, with paragraphs separated by blank lines.
   *
   * @return string
   *   Escaped HTML: one p element per paragraph.
   */
  public static function fromPlainText(string $text): string {
    $paragraphs = preg_split('/\R{2,}/', trim($text));
    return implode("\n", array_map(static fn($paragraph) => '<p>' . nl2br(Html::escape($paragraph), FALSE) . '</p>', $paragraphs));
  }

}
