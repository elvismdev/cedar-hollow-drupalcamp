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
   * Render property carrying a consumer's attributes for a media image.
   */
  private const IMG_ATTRIBUTES = '#cedar_hollow_img_attributes';

  /**
   * Image attributes by entity type, bundle, field and view mode.
   *
   * Each media view mode has one consumer here, so the attributes are stable
   * under the media render cache.
   */
  private const IMAGE_CONSUMERS = [
    'block_content.hero.field_media.full' => ['class' => ['hero__img'], 'fetchpriority' => 'high'],
    'node.session.field_image.full' => ['class' => ['session__img'], 'fetchpriority' => 'high'],
    'node.session.field_image.teaser' => ['class' => ['card__img']],
    'node.speaker.field_image.teaser' => ['class' => ['speaker-byline__img']],
  ];

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
  }

  /**
   * Implements hook_preprocess_HOOK() for field.
   *
   * Hands each referenced media item the attributes its consumer gives the
   * image. This is the first point where block content fields are built,
   * so the hero block and the nodes share it.
   *
   * @param array<mixed> $variables
   *   The template variables.
   */
  #[Hook('preprocess_field')]
  public function preprocessField(array &$variables): void {
    $element = $variables['element'];
    $key = implode('.', [$element['#entity_type'], $element['#bundle'], $element['#field_name'], $element['#view_mode']]);
    if (!isset(self::IMAGE_CONSUMERS[$key])) {
      return;
    }
    foreach (array_keys($variables['items']) as $delta) {
      $variables['items'][$delta]['content'][self::IMG_ATTRIBUTES] = self::IMAGE_CONSUMERS[$key];
    }
  }

  /**
   * Implements hook_preprocess_HOOK() for media.
   *
   * Merges a consumer's attributes into the image formatter's #attributes,
   * which core puts on the img. The consumer's values win, so the formatter's
   * loading value stays unless the consumer sets its own.
   *
   * @param array<mixed> $variables
   *   The template variables.
   */
  #[Hook('preprocess_media')]
  public function preprocessMedia(array &$variables): void {
    $extra = $variables['elements'][self::IMG_ATTRIBUTES] ?? NULL;
    if (!$extra || !isset($variables['content']['field_media_image'])) {
      return;
    }
    foreach (Element::children($variables['content']['field_media_image']) as $delta) {
      $current = $variables['content']['field_media_image'][$delta]['#attributes'] ?? [];
      $merged = $extra + $current;
      $merged['class'] = array_merge($current['class'] ?? [], $extra['class'] ?? []);
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
