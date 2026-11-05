<?php

declare(strict_types=1);

namespace Drupal\Tests\cedar_hollow_core\Traits;

/**
 * Renders the theme's components as visitors get them, in a kernel test.
 *
 * The using class must extend \Drupal\KernelTests\KernelTestBase: the trait
 * reads its $container property and calls its config() method and PHPUnit
 * assertions.
 */
trait ComponentRenderTrait {

  /**
   * Installs the theme and makes it the active theme.
   */
  protected function enableCedarHollowTheme(): void {
    $this->container->get('theme_installer')->install(['cedar_hollow']);
    $this->config('system.theme')->set('default', 'cedar_hollow')->save();
    $theme_manager = $this->container->get('theme.manager');
    $theme_manager->setActiveTheme($this->container->get('theme.initialization')->initTheme('cedar_hollow'));
  }

  /**
   * Renders a component as visitors get it.
   *
   * @param string $id
   *   The component ID.
   * @param array<string, mixed> $props
   *   The component props.
   *
   * @return string
   *   The rendered markup.
   */
  protected function renderComponent(string $id, array $props): string {
    // Component prop validation runs only while assertions are on, and a
    // production PHP configuration switches them off, so the components render
    // here as they do for visitors, whatever the value's format. A value of -1
    // compiles assertions out and cannot be changed at runtime; it already
    // renders as visitors get it.
    $build = ['#type' => 'component', '#component' => $id, '#props' => $props];
    if (ini_get('zend.assertions') === '-1') {
      return (string) $this->container->get('renderer')->renderInIsolation($build);
    }
    $assertions = ini_set('zend.assertions', '0');
    $this->assertNotFalse($assertions, 'Assertions can be switched off at runtime.');
    try {
      return (string) $this->container->get('renderer')->renderInIsolation($build);
    }
    finally {
      ini_set('zend.assertions', $assertions);
    }
  }

}
