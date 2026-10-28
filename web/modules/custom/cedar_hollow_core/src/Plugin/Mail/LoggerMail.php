<?php

declare(strict_types=1);

namespace Drupal\cedar_hollow_core\Plugin\Mail;

use Drupal\Core\Mail\Attribute\Mail;
use Drupal\Core\Mail\MailInterface;
use Drupal\Core\StringTranslation\TranslatableMarkup;

/**
 * Writes outgoing mail to the log instead of sending it.
 */
#[Mail(
  id: 'cedar_hollow_logger',
  label: new TranslatableMarkup('Cedar Hollow log mailer'),
  description: new TranslatableMarkup('Logs every message to the cedar_hollow_core channel; nothing is sent.'),
)]
final class LoggerMail implements MailInterface {

  /**
   * {@inheritdoc}
   */
  public function format(array $message): array {
    $message['body'] = implode("\n\n", array_map('strval', (array) $message['body']));
    return $message;
  }

  /**
   * {@inheritdoc}
   */
  public function mail(array $message): bool {
    \Drupal::logger('cedar_hollow_core')->notice('Mail to @to, subject "@subject": @body', [
      '@to' => $message['to'],
      '@subject' => $message['subject'],
      '@body' => $message['body'],
    ]);
    return TRUE;
  }

}
