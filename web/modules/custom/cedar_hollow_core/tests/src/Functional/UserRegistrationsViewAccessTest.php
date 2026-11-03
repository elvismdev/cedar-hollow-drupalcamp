<?php

declare(strict_types=1);

namespace Drupal\Tests\cedar_hollow_core\Functional;

use Behat\Mink\Driver\BrowserKitDriver;
use Drupal\Component\Serialization\Yaml;
use Drupal\Core\Session\AccountInterface;
use Drupal\user\Entity\User;
use Drupal\views\Entity\View;
use Drupal\views\Views;
use PHPUnit\Framework\Attributes\Group;
use PHPUnit\Framework\Attributes\RunTestsInSeparateProcesses;

/**
 * The user registrations view lists registrations only to administrators.
 *
 * Views answers /views/ajax for any view and display it is given, so the
 * view's own access setting is what keeps other users from listing every
 * registration with "all", or another user's id, as the user argument.
 */
#[Group('cedar_hollow_core')]
#[RunTestsInSeparateProcesses]
final class UserRegistrationsViewAccessTest extends SessionTestBase {

  /**
   * Tests who can list registrations through the view.
   */
  public function testOnlyAdministratorsListRegistrations(): void {
    // Letters, digits and spaces only, so the title reads the same in HTML
    // and in JSON.
    $title = 'Registration listing probe ' . $this->randomMachineName();
    $session = $this->createSession($title, 10);
    $attendee = $this->drupalCreateUser(['access content', 'create attendee registration self', 'view own registration']);
    $this->container->get('entity_type.manager')->getStorage('registration')->create([
      'type' => 'attendee',
      'entity_type_id' => 'node',
      'entity_id' => $session->id(),
      'user_uid' => $attendee->id(),
      'count' => 1,
      'state' => 'complete',
    ])->save();
    $administrator = $this->drupalCreateUser(['access content', 'administer registration']);
    $other = $this->drupalCreateUser(['access content', 'create attendee registration self', 'view own registration']);

    // The view's own access decision, independent of how it is requested.
    $this->assertFalse($this->viewAccess(User::getAnonymousUser()));
    $this->assertFalse($this->viewAccess($other));
    $this->assertTrue($this->viewAccess($administrator));

    $this->requestRegistrations('all');
    $this->assertDenied($title);

    $this->drupalLogin($other);
    foreach (['all', (string) $attendee->id()] as $argument) {
      $this->requestRegistrations($argument);
      $this->assertDenied($title);
    }

    // The administrator sees the session through the view: the route's
    // fallback table has no column for the session.
    $this->drupalLogin($administrator);
    $this->drupalGet('user/' . $attendee->id() . '/registrations');
    $this->assertSession()->statusCodeEquals(200);
    $this->assertSession()->pageTextContains($title);

    // The view has no pager or exposed form to refresh, so it takes no AJAX
    // requests, not even from an administrator.
    $this->requestRegistrations('all');
    $this->assertDenied($title);
  }

  /**
   * Tests that both shipped copies of the view are what saving it stores.
   *
   * Views computes each display's cache metadata only on a save outside a
   * config sync, so a config import keeps whatever the YAML says. The YAML
   * must already carry it, user.permissions from the access plugin
   * included, or the site serves stale contexts and the next save differs
   * from config/.
   */
  public function testShippedViewMatchesSavedView(): void {
    $name = 'views.view.user_registrations';
    $view = View::load('user_registrations');
    $this->assertNotNull($view);
    $view->save();
    $this->container->get('config.factory')->reset($name);
    $saved = $this->config($name)->getRawData();
    unset($saved['uuid'], $saved['_core']);
    foreach (['config', 'recipes/cedar_hollow_sessions/config'] as $directory) {
      $shipped = Yaml::decode((string) file_get_contents($this->root . "/../$directory/$name.yml"));
      unset($shipped['uuid'], $shipped['_core']);
      $this->assertSame($saved, $shipped, $directory);
    }
  }

  /**
   * Returns whether the account may see the view's block display.
   */
  private function viewAccess(AccountInterface $account): bool {
    $view = Views::getView('user_registrations');
    $this->assertNotNull($view);
    return $view->access('block_1', $account);
  }

  /**
   * Posts the request a view's AJAX refresh makes, for the given user id.
   */
  private function requestRegistrations(string $argument): void {
    $driver = $this->getSession()->getDriver();
    $this->assertInstanceOf(BrowserKitDriver::class, $driver);
    $driver->getClient()->request('POST', $this->buildUrl('views/ajax', ['query' => ['_wrapper_format' => 'drupal_ajax']]), [
      'view_name' => 'user_registrations',
      'view_display_id' => 'block_1',
      'view_args' => $argument,
    ]);
  }

  /**
   * Asserts the last response was refused and does not name the session.
   */
  private function assertDenied(string $title): void {
    $this->assertSession()->statusCodeEquals(403);
    $this->assertSession()->responseNotContains($title);
  }

}
