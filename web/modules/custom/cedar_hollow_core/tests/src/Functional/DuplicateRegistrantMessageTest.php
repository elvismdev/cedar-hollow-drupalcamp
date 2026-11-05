<?php

declare(strict_types=1);

namespace Drupal\Tests\cedar_hollow_core\Functional;

use PHPUnit\Framework\Attributes\Group;
use PHPUnit\Framework\Attributes\RunTestsInSeparateProcesses;

/**
 * A refused duplicate sign-up does not echo the address back.
 */
#[Group('cedar_hollow_core')]
#[RunTestsInSeparateProcesses]
final class DuplicateRegistrantMessageTest extends SessionTestBase {

  /**
   * Tests that a second anonymous sign-up with the same address is refused.
   */
  public function testDuplicateAddressIsRefusedWithoutEcho(): void {
    $session = $this->createSession('Recipes in practice', 10, FALSE);
    $register = 'node/' . $session->id() . '/register';
    $taken = 'taken-' . $this->randomMachineName() . '@example.com';

    $this->drupalGet($register);
    $this->submitForm(['anon_mail[0][value]' => $taken], 'Save Registration');
    $this->assertSession()->statusMessageContains('Registration has been saved.', 'status');

    // A different visitor: no cookies carried over from the first one.
    $this->getSession()->reset();
    $this->drupalGet($register);
    $this->submitForm(['anon_mail[0][value]' => $taken], 'Save Registration');
    $this->assertSession()->statusMessageNotContains('Registration has been saved.');
    $this->assertSession()->statusMessageContains('This email address is already registered for this session.', 'error');
    // The form keeps the visitor's own input in the field, so the check is on
    // the rendered text, which holds every message.
    $this->assertSession()->pageTextNotContains($taken);
    $this->assertSame(1, $this->countRegistrations($taken));

    // A fresh address still registers.
    $this->getSession()->reset();
    $fresh = 'fresh-' . $this->randomMachineName() . '@example.com';
    $this->drupalGet($register);
    $this->submitForm(['anon_mail[0][value]' => $fresh], 'Save Registration');
    $this->assertSession()->statusMessageContains('Registration has been saved.', 'status');
    $this->assertSame(1, $this->countRegistrations($fresh));
  }

  /**
   * Counts the registrations stored for an anonymous address.
   */
  private function countRegistrations(string $mail): int {
    return (int) $this->container->get('entity_type.manager')
      ->getStorage('registration')
      ->getQuery()
      ->accessCheck(FALSE)
      ->condition('anon_mail', $mail)
      ->count()
      ->execute();
  }

}
