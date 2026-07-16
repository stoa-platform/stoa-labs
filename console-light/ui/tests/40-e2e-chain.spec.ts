import { test, expect } from '@playwright/test';
import { loginAs } from './helpers/auth';

/**
 * LE chaînage complet (tâche #21) : action gouvernée DANS LA CONSOLE →
 * commit signé → push auto (hook) → webhook Gitea → Jenkins stoa-governance
 * → apply-uac → gateways RÉELLES. Cette spec ne fait QUE l'action console ;
 * le suivi Jenkins/gateways est vérifié côté harnais (labsetup).
 */
const SHOT = (n: string) => `../evidence/screenshots/e2e/${n}.png`;

test('alice publie customer-referential en dev depuis la Console', async ({ browser }) => {
  const ctx = await browser.newContext();
  const page = await ctx.newPage();
  await loginAs(page, 'alice');

  await page.goto('/contracts/customer-referential');
  await expect(page.getByTestId('contract-publish')).toBeVisible({ timeout: 15_000 });
  await page.screenshot({ path: SHOT('e2e-01-contrat-avant'), fullPage: true });

  await page.getByTestId('contract-publish').click();
  await page.getByTestId('contract-publish-message').fill('Chaînage E2E — publication gouvernée depuis la Console (vérification du cheminement complet)');
  await page.getByTestId('contract-publish-confirm').click();

  await expect(page.getByTestId('commit-sha').first()).toBeVisible({ timeout: 15_000 });
  await page.screenshot({ path: SHOT('e2e-02-commit-signe'), fullPage: true });
  await ctx.close();
});
