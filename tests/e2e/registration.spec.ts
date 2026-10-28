import { execSync } from 'node:child_process';
import { test, expect } from '../fixtures';

test.afterAll(() => {
  // Registrations would use up seats on reruns.
  execSync('ddev drush entity:delete registration -y', { stdio: 'ignore' });
});

test('an attendee follows the sign-up link and registers', async ({ page }) => {
  await page.goto('/sessions/caching-render-arrays');
  await expect(page.getByText('40 of 40 seats left')).toBeVisible();
  await page.getByRole('link', { name: 'Sign up for this session' }).click();
  await expect(page.getByRole('heading', { name: 'Sign up: Caching render arrays' })).toBeVisible();
  await page.getByLabel('Email').fill('attendee@example.com');
  await page.getByRole('button', { name: 'Save Registration' }).click();
  await expect(page.getByText('Registration has been saved.')).toBeVisible();

  await page.goto('/sessions/caching-render-arrays');
  await expect(page.getByText('39 of 40 seats left')).toBeVisible();
});
