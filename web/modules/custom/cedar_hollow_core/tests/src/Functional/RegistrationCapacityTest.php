<?php

declare(strict_types=1);

namespace Drupal\Tests\cedar_hollow_core\Functional;

use Drupal\Core\Test\AssertMailTrait;
use Drupal\registration\Entity\RegistrationInterface;
use PHPUnit\Framework\Attributes\Group;
use PHPUnit\Framework\Attributes\RunTestsInSeparateProcesses;

/**
 * A full session sends the next sign-up to the wait list.
 */
#[Group('cedar_hollow_core')]
#[RunTestsInSeparateProcesses]
final class RegistrationCapacityTest extends SessionTestBase {

  use AssertMailTrait;

  /**
   * Tests the wait list and that only completed sign-ups get mail.
   */
  public function testFullSessionWaitLists(): void {
    $session = $this->createSession('Theming with SDC', 1);
    $register = 'node/' . $session->id() . '/register';
    // Collect mail in state so it can be read back; nothing is sent.
    $this->config('system.mail')->set('interface.default', 'test_mail_collector')->save();

    $first = $this->drupalCreateUser(['access content', 'create attendee registration self']);
    $this->drupalLogin($first);
    $this->drupalGet($register);
    $this->submitForm([], 'Save Registration');
    $this->assertSession()->statusMessageContains('Registration has been saved.', 'status');

    $second = $this->drupalCreateUser(['access content', 'create attendee registration self']);
    $this->drupalLogin($second);
    $this->drupalGet($register);
    $this->assertSession()->pageTextContains('This session is full. Signing up adds you to the wait list.');
    $this->submitForm([], 'Save Registration');
    $this->assertSession()->statusMessageContains('Registration placed on the wait list.', 'warning');

    // Stored state, read through the entity API rather than the page.
    $storage = $this->container->get('entity_type.manager')->getStorage('registration');
    $states = [];
    foreach ($storage->loadMultiple() as $registration) {
      $this->assertInstanceOf(RegistrationInterface::class, $registration);
      $states[$registration->getUser()->id()] = $registration->getState()->id();
    }
    $this->assertSame('complete', $states[$first->id()]);
    $this->assertSame('waitlist', $states[$second->id()]);

    // Only the completed registration gets a confirmation.
    $recipients = array_column($this->getMails(), 'to');
    $this->assertContains($first->getEmail(), $recipients);
    $this->assertNotContains($second->getEmail(), $recipients);
  }

}
