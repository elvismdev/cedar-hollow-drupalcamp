<?php

declare(strict_types=1);

namespace Drupal\Tests\cedar_hollow_core\Kernel;

use Drupal\canvas\Entity\JavaScriptComponent;
use Drupal\Tests\canvas\Kernel\CanvasKernelTestBase;
use PHPUnit\Framework\Attributes\Group;
use PHPUnit\Framework\Attributes\RunTestsInSeparateProcesses;

/**
 * A cache rebuild writes back a code component's missing compiled script.
 */
#[Group('cedar_hollow_core')]
#[RunTestsInSeparateProcesses]
final class CanvasAssetRebuildTest extends CanvasKernelTestBase {

  /**
   * {@inheritdoc}
   */
  protected static $modules = [
    ...parent::CANVAS_KERNEL_TEST_MINIMAL_MODULES,
    'cedar_hollow_core',
  ];

  /**
   * Tests that a deleted compiled script is written again on rebuild.
   */
  public function testMissingCompiledScriptIsRewritten(): void {
    $component = JavaScriptComponent::create([
      'machineName' => 'probe',
      'name' => 'Probe',
      'status' => TRUE,
      'props' => [],
      'required' => [],
      'slots' => [],
      'js' => ['original' => 'export default () => null;', 'compiled' => 'export default () => null;'],
      'css' => ['original' => '', 'compiled' => ''],
      'dataDependencies' => [],
    ]);
    $component->save();
    $path = $component->getJsPath();
    $this->assertFileExists($path);

    unlink($path);
    $this->assertFileDoesNotExist($path);

    $this->container->get('module_handler')->invokeAll('rebuild');
    $this->assertFileExists($path);
    $this->assertSame('export default () => null;', file_get_contents($path));
  }

}
