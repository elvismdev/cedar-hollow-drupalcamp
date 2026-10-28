<?php

declare(strict_types=1);

namespace Drupal\cedar_hollow_core\Hook;

use Drupal\Core\Form\FormStateInterface;
use Drupal\Core\Hook\Attribute\Hook;
use Drupal\Core\StringTranslation\StringTranslationTrait;

/**
 * Tells registrants their address is only used for the demo.
 */
final class RegistrationFormHooks {

  use StringTranslationTrait;

  /**
   * Implements hook_form_FORM_ID_alter() for the attendee sign-up form.
   *
   * @param array<mixed> $form
   *   The sign-up form.
   * @param \Drupal\Core\Form\FormStateInterface $form_state
   *   The form state.
   */
  #[Hook('form_registration_attendee_register_form_alter')]
  public function registerFormAlter(array &$form, FormStateInterface $form_state): void {
    if (isset($form['anon_mail']['widget'][0]['value'])) {
      $form['anon_mail']['widget'][0]['value']['#description'] = $this->t('Used only for this demo. Mail is never sent.');
    }
  }

}
