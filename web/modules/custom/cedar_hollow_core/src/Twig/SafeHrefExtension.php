<?php

declare(strict_types=1);

namespace Drupal\cedar_hollow_core\Twig;

use Drupal\Component\Utility\UrlHelper;
use Twig\Extension\AbstractExtension;
use Twig\TwigFilter;

/**
 * Provides the safe_href filter for URLs printed into href and src.
 *
 * Themes cannot register services, so the filter lives in this module, which
 * the Cedar Hollow theme depends on.
 */
final class SafeHrefExtension extends AbstractExtension {

  /**
   * {@inheritdoc}
   */
  public function getFilters(): array {
    return [
      new TwigFilter('safe_href', [self::class, 'safeHref']),
    ];
  }

  /**
   * Cleans a URL before it is printed into an href or src attribute.
   *
   * Removes C0 and C1 control characters and leading whitespace, then strips
   * every scheme that is not on the site's allowed protocol list. The result
   * is not escaped; Twig's autoescape or Attribute escapes it on output.
   *
   * @param string|\Stringable|null $url
   *   The URL as given to the template.
   *
   * @return string
   *   The cleaned URL.
   */
  public static function safeHref(string|\Stringable|null $url): string {
    $url = preg_replace('/[\x{0000}-\x{001F}\x{007F}-\x{009F}]/u', '', (string) $url) ?? '';
    return UrlHelper::stripDangerousProtocols(ltrim($url));
  }

}
