<?php

declare(strict_types=1);

namespace Drupal\cedar_hollow\Hook;

use Drupal\cedar_hollow_core\SeatsSummary;
use Drupal\Core\Cache\CacheableMetadata;
use Drupal\Core\Config\ConfigFactoryInterface;
use Drupal\Core\Datetime\DateFormatterInterface;
use Drupal\Core\Form\FormStateInterface;
use Drupal\Core\Hook\Attribute\Hook;
use Drupal\Core\Render\Element;
use Drupal\Core\Routing\RouteMatchInterface;
use Drupal\Core\StringTranslation\StringTranslationTrait;
use Drupal\node\NodeInterface;

/**
 * Theme hooks for Cedar Hollow: suggestions and the values components need.
 */
final class ThemeHooks {

  use StringTranslationTrait;

  /**
   * Time zone the camp runs in; session times are formatted in it.
   */
  private const TIME_ZONE = 'America/New_York';

  /**
   * The Entity Registration sign-up form for the attendee type.
   */
  private const REGISTER_FORM_ID = 'registration_attendee_register_form';

  /**
   * The view whose radio filters render as filter-group components.
   */
  private const SESSIONS_VIEW = 'sessions';

  /**
   * Render property marking an exposed filter as a filter-group.
   */
  private const FILTER_GROUP = '#cedar_hollow_filter_group';

  /**
   * Image attributes by Image media view mode.
   *
   * Media is render-cached per media view mode, so the attributes are keyed
   * by it: whichever page renders a media item first, the cached image
   * carries the same attributes. Each of these view modes is used by one
   * component; hero and page both feed the hero component, on the front
   * page and the session page. Card and speaker-byline photos are
   * decorative, since the heading or name beside them carries the meaning,
   * so their alt is empty.
   */
  private const IMAGE_ATTRIBUTES = [
    'hero' => ['class' => ['hero__img'], 'fetchpriority' => 'high'],
    'page' => ['class' => ['hero__img'], 'fetchpriority' => 'high'],
    'card' => ['class' => ['card__img'], 'alt' => ''],
    'avatar' => ['class' => ['speaker-byline__img'], 'alt' => ''],
    'credits' => ['class' => ['credits-view__img']],
  ];

  /**
   * Render property marking a session card in the listing's first row.
   */
  private const FIRST_ROW = '#cedar_hollow_first_row';

  /**
   * Cards in the first row of the session list at its widest.
   *
   * The list's grid fits at most three 18rem columns in the 72rem page.
   */
  private const FIRST_ROW_CARDS = 3;

  /**
   * Image attributes for a first-row card, which is above the fold.
   *
   * Every other card image keeps the card formatter's lazy loading.
   */
  private const FIRST_ROW_IMAGE_ATTRIBUTES = ['loading' => 'eager', 'fetchpriority' => 'high'];

  public function __construct(
    private readonly SeatsSummary $seatsSummary,
    private readonly DateFormatterInterface $dateFormatter,
    private readonly ConfigFactoryInterface $configFactory,
    private readonly RouteMatchInterface $routeMatch,
  ) {}

  /**
   * Implements hook_preprocess_HOOK() for node--session.
   *
   * Prepares scalar props for the date-badge, session-meta and
   * seats-indicator components, in every view mode.
   *
   * @param array<mixed> $variables
   *   The template variables.
   */
  #[Hook('preprocess_node__session')]
  public function preprocessNodeSession(array &$variables): void {
    $node = $variables['node'];
    assert($node instanceof NodeInterface);
    $cacheability = CacheableMetadata::createFromRenderArray($variables);

    $time = $node->get('field_session_time')->first();
    if ($time) {
      $start = (int) $time->getValue()['value'];
      $end = (int) $time->getValue()['end_value'];
      $variables['date_badge'] = [
        'month' => $this->formatTime($start, 'M'),
        'day' => $this->formatTime($start, 'j'),
      ];
      $variables['time_range'] = (string) $this->t('@day, @start to @end', [
        '@day' => $this->formatTime($start, 'D j M'),
        '@start' => $this->formatTime($start, 'g:ia'),
        '@end' => $this->formatTime($end, 'g:ia'),
      ]);
    }

    $variables['room'] = (string) $node->get('field_room')->value;
    $track = $node->get('field_track')->entity;
    $variables['track_label'] = $track ? $track->label() : '';
    if ($track) {
      $cacheability->addCacheableDependency($track);
    }

    $variables['seats'] = $this->seatsSummary->summarize($node, $cacheability);
    $cacheability->applyTo($variables);

    // Hands the first-row mark to the card image, with a cache key so the
    // eager image is cached apart from the lazy one.
    if (!empty($variables['elements'][self::FIRST_ROW]) && isset($variables['content']['field_image'][0])) {
      self::markFirstRow($variables['content']['field_image'][0]);
    }
  }

  /**
   * Implements hook_preprocess_HOOK() for views_view_unformatted.
   *
   * Marks the session listing's first-row cards, whose images are above the
   * fold and load eagerly.
   *
   * @param array<mixed> $variables
   *   The template variables.
   */
  #[Hook('preprocess_views_view_unformatted')]
  public function preprocessViewsViewUnformatted(array &$variables): void {
    if ($variables['view']->id() !== 'sessions') {
      return;
    }
    foreach (array_slice(array_keys($variables['rows']), 0, self::FIRST_ROW_CARDS) as $index) {
      self::markFirstRow($variables['rows'][$index]['content']);
    }
  }

  /**
   * Marks a render array as a first-row card and caches it separately.
   *
   * @param array<mixed> $build
   *   An entity render array that has not been rendered yet.
   */
  private static function markFirstRow(array &$build): void {
    $build[self::FIRST_ROW] = TRUE;
    if (isset($build['#cache']['keys'])) {
      $build['#cache']['keys'][] = 'first_row';
    }
  }

  /**
   * Implements hook_preprocess_HOOK() for media.
   *
   * Merges the attributes for the media view mode into the image formatter's
   * #attributes, which core puts on the img. These values win, so the
   * formatter's loading value stays unless they set their own.
   *
   * @param array<mixed> $variables
   *   The template variables.
   */
  #[Hook('preprocess_media')]
  public function preprocessMedia(array &$variables): void {
    $extra = self::IMAGE_ATTRIBUTES[$variables['view_mode']] ?? NULL;
    if (!$extra || !isset($variables['content']['field_media_image'])) {
      return;
    }
    if (!empty($variables['elements'][self::FIRST_ROW])) {
      $extra = self::FIRST_ROW_IMAGE_ATTRIBUTES + $extra;
    }
    foreach (Element::children($variables['content']['field_media_image']) as $delta) {
      $current = $variables['content']['field_media_image'][$delta]['#attributes'] ?? [];
      $merged = $extra + $current;
      $merged['class'] = array_merge($current['class'] ?? [], $extra['class']);
      $variables['content']['field_media_image'][$delta]['#attributes'] = $merged;
    }
  }

  /**
   * Implements hook_preprocess_HOOK() for page.
   *
   * @param array<mixed> $variables
   *   The template variables.
   */
  #[Hook('preprocess_page')]
  public function preprocessPage(array &$variables): void {
    $site = $this->configFactory->get('system.site');
    $variables['site_name'] = $site->get('name');
    $variables['demo_notice'] = $this->t('Cedar Hollow DrupalCamp is a fictional event. This site is a demo.');
    CacheableMetadata::createFromRenderArray($variables)
      ->addCacheableDependency($site)
      ->applyTo($variables);
  }

  /**
   * Implements hook_theme_suggestions_HOOK_alter() for form.
   *
   * @param string[] $suggestions
   *   The template suggestions.
   * @param array<mixed> $variables
   *   The template variables.
   */
  #[Hook('theme_suggestions_form_alter')]
  public function themeSuggestionsFormAlter(array &$suggestions, array $variables): void {
    if (($variables['element']['#form_id'] ?? NULL) === self::REGISTER_FORM_ID) {
      $suggestions[] = 'form__' . self::REGISTER_FORM_ID;
    }
  }

  /**
   * Implements hook_preprocess_HOOK() for form.
   *
   * Gives the sign-up form a heading naming the session from the route.
   *
   * @param array<mixed> $variables
   *   The template variables.
   */
  #[Hook('preprocess_form')]
  public function preprocessForm(array &$variables): void {
    if (($variables['element']['#form_id'] ?? NULL) !== self::REGISTER_FORM_ID) {
      return;
    }
    $cacheability = CacheableMetadata::createFromRenderArray($variables)->addCacheContexts(['route']);
    $node = $this->routeMatch->getParameter('node');
    if ($node instanceof NodeInterface) {
      $variables['form_heading'] = $this->t('Sign up: @title', ['@title' => $node->label()]);
      $cacheability->addCacheableDependency($node);
    }
    $cacheability->applyTo($variables);
  }

  /**
   * Implements hook_form_FORM_ID_alter() for views_exposed_form.
   *
   * Makes the exposed filters' submit the primary button. On the sessions
   * listing, marks each radio filter to render as a filter-group and drops
   * the bare radios wrapper, so its options sit directly in the group.
   *
   * @param array<mixed> $form
   *   The exposed form.
   * @param \Drupal\Core\Form\FormStateInterface $form_state
   *   The form state.
   */
  #[Hook('form_views_exposed_form_alter')]
  public function formViewsExposedFormAlter(array &$form, FormStateInterface $form_state): void {
    if (isset($form['actions']['submit'])) {
      $form['actions']['submit']['#button_type'] = 'primary';
    }
    if ($form_state->get('view')?->id() !== self::SESSIONS_VIEW) {
      return;
    }
    foreach (Element::children($form) as $key) {
      if (($form[$key]['#type'] ?? NULL) === 'radios') {
        $form[$key][self::FILTER_GROUP] = TRUE;
        $form[$key]['#theme_wrappers'] = [];
      }
    }
  }

  /**
   * Implements hook_theme_suggestions_HOOK_alter() for fieldset.
   *
   * @param string[] $suggestions
   *   The template suggestions.
   * @param array<mixed> $variables
   *   The template variables.
   */
  #[Hook('theme_suggestions_fieldset_alter')]
  public function themeSuggestionsFieldsetAlter(array &$suggestions, array $variables): void {
    if (!empty($variables['element'][self::FILTER_GROUP])) {
      $suggestions[] = 'fieldset__filter_group';
    }
  }

  /**
   * Implements hook_theme_suggestions_HOOK_alter() for views_exposed_form.
   *
   * Views offers no per-view suggestion for its exposed form.
   *
   * @param string[] $suggestions
   *   The template suggestions.
   * @param array<mixed> $variables
   *   The template variables.
   */
  #[Hook('theme_suggestions_views_exposed_form_alter')]
  public function themeSuggestionsViewsExposedFormAlter(array &$suggestions, array $variables): void {
    $view = $variables['form']['#view'] ?? NULL;
    if ($view) {
      $suggestions[] = 'views_exposed_form__' . $view->id();
    }
  }

  /**
   * Formats a timestamp in the camp's time zone.
   */
  private function formatTime(int $timestamp, string $format): string {
    return $this->dateFormatter->format($timestamp, 'custom', $format, self::TIME_ZONE);
  }

}
