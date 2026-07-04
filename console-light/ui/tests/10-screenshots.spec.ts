import { test, expect, Page } from '@playwright/test';
import { loginAs } from './helpers/auth';

/**
 * Phase B — captures de tous les écrans pour la revue visuelle (lisible, propre,
 * pro, intuitive). Sauvegarde dans ../../evidence/screenshots/.
 * Pré-requis : rôles assignés (labsetup kc-roles) + BFF + Vite up.
 */
const SHOT = (name: string) => `../evidence/screenshots/${name}.png`;

async function shoot(page: Page, name: string) {
  await page.waitForLoadState('networkidle').catch(() => {});
  await page.waitForTimeout(400); // settle animations
  await page.screenshot({ path: SHOT(name), fullPage: true });
}

test.describe.configure({ mode: 'serial' });

test('login — page de connexion', async ({ browser }) => {
  const page = await (await browser.newContext()).newPage();
  await page.goto('/');
  await shoot(page, '00-login');
  await page.context().close();
});

test('alice (fournisseur) — écrans tenant', async ({ browser }) => {
  const ctx = await browser.newContext();
  const page = await ctx.newPage();
  await loginAs(page, 'alice');

  await shoot(page, '01-dashboard-alice');

  await page.goto('/contracts');
  await expect(page.getByTestId('page-contracts')).toBeVisible({ timeout: 10_000 });
  await shoot(page, '02-contracts');

  await page.goto('/contracts/accounts-read');
  await shoot(page, '03-contract-detail-accounts-read');

  await page.goto('/contracts/payments-initiation/edit');
  await shoot(page, '04-contract-edit-payments');

  await page.goto('/promotions');
  await shoot(page, '05-promotions');

  await page.goto('/subscriptions');
  await shoot(page, '06-subscriptions');

  await page.goto('/audit');
  await shoot(page, '07-audit');

  await page.goto('/tenants');
  await shoot(page, '08-tenants');

  await page.goto('/targets');
  await shoot(page, '09-targets');

  await ctx.close();
});

test('dave (admin) — écrans plateforme', async ({ browser }) => {
  const ctx = await browser.newContext();
  const page = await ctx.newPage();
  await loginAs(page, 'dave');
  await page.goto('/admin/roles');
  await shoot(page, '10-admin-roles');
  await page.goto('/admin/users');
  await shoot(page, '11-admin-users');
  await ctx.close();
});

test('carol (auditrice, viewer) — lecture seule', async ({ browser }) => {
  const ctx = await browser.newContext();
  const page = await ctx.newPage();
  await loginAs(page, 'carol');
  await page.goto('/contracts');
  await shoot(page, '12-contracts-viewer-carol');
  await page.goto('/audit');
  await shoot(page, '13-audit-viewer-carol');
  await ctx.close();
});
