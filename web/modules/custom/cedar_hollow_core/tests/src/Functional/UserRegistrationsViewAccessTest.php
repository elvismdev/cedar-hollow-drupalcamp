<?php

declare(strict_types=1);

namespace Drupal\Tests\cedar_hollow_core\Functional;

use Behat\Mink\Driver\BrowserKitDriver;
use PHPUnit\Framework\Attributes\Group;
use PHPUnit\Framework\Attributes\RunTestsInSeparateProcesses;

/**
 * The user registrations view lists registrations only to administrators.
 *
 * Views answers /views/ajax for any view and display it is given, so the
 * view's own access setting is what keeps anonymous visitors from listing
 * every registration with "all" as the user argument.
 */
#[Group('cedar_hollow_core')]
#[RunTestsInSeparateProcesses]
final class UserRegistrationsViewAccessTest extends SessionTestBase {

  /**
   * Tests anonymous and administrator requests for every registration.
   */
  public function testViewsAjaxListsRegistrationsOnlyToAdministrators(): void {
    $title = 'Registration listing probe ' . $this->randomMachineName();
    $session = $this->createSession($title, 10);
    $attendee = $this->drupalCreateUser(['access content', 'create attendee registration self']);
    $this->container->get('entity_type.manager')->getStorage('registration')->create([
      'type' => 'attendee',
      'entity_type_id' => 'node',
      'entity_id' => $session->id(),
      'user_uid' => $attendee->id(),
      'count' => 1,
      'state' => 'complete',
    ])->save();

    $this->requestAllRegistrations();
    $this->assertSession()->statusCodeEquals(403);
    $this->assertSession()->responseNotContains($title);

    $this->drupalLogin($this->drupalCreateUser(['access content', 'administer registration']));
    $this->requestAllRegistrations();
    $this->assertSession()->statusCodeEquals(200);
    $this->assertSession()->responseContains($title);
  }

  /**
   * Posts the request the view's AJAX pager makes, with "all" as the user.
   */
  private function requestAllRegistrations(): void {
    $driver = $this->getSession()->getDriver();
    $this->assertInstanceOf(BrowserKitDriver::class, $driver);
    $driver->getClient()->request('POST', $this->buildUrl('views/ajax', ['query' => ['_wrapper_format' => 'drupal_ajax']]), [
      'view_name' => 'user_registrations',
      'view_display_id' => 'block_1',
      'view_args' => 'all',
    ]);
  }

}
