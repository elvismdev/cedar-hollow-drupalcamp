<?php

declare(strict_types=1);

namespace Drupal\cedar_hollow_core\Plugin\Mail;

use Drupal\Core\Mail\Attribute\Mail;
use Drupal\Core\Mail\MailInterface;
use Drupal\Core\Plugin\ContainerFactoryPluginInterface;
use Drupal\Core\StringTranslation\TranslatableMarkup;
use Psr\Log\LoggerInterface;
use Symfony\Component\DependencyInjection\ContainerInterface;

/**
 * Writes outgoing mail to the log instead of sending it.
 */
#[Mail(
  id: 'cedar_hollow_logger',
  label: new TranslatableMarkup('Cedar Hollow log mailer'),
  description: new TranslatableMarkup('Logs every message to the cedar_hollow_core channel; nothing is sent.'),
)]
final class LoggerMail implements MailInterface, ContainerFactoryPluginInterface {

  /**
   * The log channel messages are written to.
   */
  public const CHANNEL = 'cedar_hollow_core';

  public function __construct(
    private readonly LoggerInterface $logger,
  ) {}

  /**
   * {@inheritdoc}
   *
   * @param \Symfony\Component\DependencyInjection\ContainerInterface $container
   *   The service container.
   * @param array<string, mixed> $configuration
   *   The plugin configuration.
   * @param string $plugin_id
   *   The plugin ID.
   * @param mixed $plugin_definition
   *   The plugin definition.
   */
  public static function create(ContainerInterface $container, array $configuration, $plugin_id, $plugin_definition): static {
    return new static($container->get('logger.factory')->get(self::CHANNEL));
  }

  /**
   * {@inheritdoc}
   *
   * @param array<string, mixed> $message
   *   The message, with its body as a string or a list of strings.
   *
   * @return array<string, mixed>
   *   The message with a plain text body.
   */
  public function format(array $message): array {
    $message['body'] = implode("\n\n", array_map('strval', (array) $message['body']));
    return $message;
  }

  /**
   * {@inheritdoc}
   *
   * @param array<string, mixed> $message
   *   The formatted message.
   */
  public function mail(array $message): bool {
    $this->logger->notice('Mail to @to, subject "@subject": @body', [
      '@to' => $message['to'],
      '@subject' => $message['subject'],
      '@body' => $message['body'],
    ]);
    return TRUE;
  }

}
