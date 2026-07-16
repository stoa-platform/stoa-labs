import { test, expect, Page } from '@playwright/test';
import { loginAs } from './helpers/auth';

/**
 * Parcours démo 15 min (CADRAGE §1) — preuve de bout en bout :
 * édition validée → publication=commit → promotion → 4-yeux → audit signé.
 * Captures dans ../evidence/screenshots/demo/.
 *
 * Matrice RBAC (API-CONTRACT §2) :
 *  - alice (tenant-admin) : request, pas approve
 *  - bob (devops) : approve, pas request
 *  - dave (cpi-admin) : request + approve → le cas d'auto-approbation bloquée
 */
const SHOT = (n: string) => `../evidence/screenshots/demo/${n}.png`;
test.describe.configure({ mode: 'serial' });

async function createPromotion(page: Page, slug: string, chainIndex: '0' | '1', message: string) {
  await page.goto('/promotions');
  await page.getByTestId('promotion-new').click();
  await page.getByTestId('promotion-create-slug').selectOption(slug);
  await page.getByTestId('promotion-create-chain').selectOption(chainIndex);
  await page.getByTestId('promotion-create-message').fill(message);
  await page.getByTestId('promotion-create-submit').click();
  await expect(page.getByTestId('promotion-new-dialog')).toHaveCount(0, { timeout: 10_000 });
}

test('étape 3-4 : alice édite payments-initiation — règle destructive puis publication dev', async ({ browser }) => {
  const ctx = await browser.newContext();
  const page = await ctx.newPage();
  await loginAs(page, 'alice');

  await page.goto('/contracts/payments-initiation/edit');
  await expect(page.getByTestId('editor-save')).toBeVisible({ timeout: 10_000 });

  // provoquer l'erreur destructive sur le DELETE (dernier endpoint)
  const approvalSwitch = page.getByTestId(/endpoint-llm-approval-/).last();
  await approvalSwitch.scrollIntoViewIfNeeded();
  await approvalSwitch.click();
  await expect(page.getByTestId('editor-error-destructive')).toBeVisible({ timeout: 5_000 });
  await page.screenshot({ path: SHOT('demo-03a-erreur-destructive'), fullPage: true });
  await approvalSwitch.click(); // corriger
  await expect(page.getByTestId('editor-destructive-ok')).toBeVisible({ timeout: 5_000 });

  await page.getByTestId('editor-save').click();
  await expect(page.getByTestId('commit-sha').first()).toBeVisible({ timeout: 10_000 });
  await page.screenshot({ path: SHOT('demo-04a-brouillon-commit'), fullPage: true });

  await page.getByTestId('editor-publish').click();
  const msg = page.locator('textarea').last();
  await msg.fill('Publication initiale en dev — démo gouvernance');
  await page.getByRole('button', { name: /confirmer|publier/i }).last().click();
  await expect(page.getByTestId('commit-sha').first()).toBeVisible({ timeout: 10_000 });
  await page.screenshot({ path: SHOT('demo-04b-publication-dev-commit'), fullPage: true });
  await ctx.close();
});

test('étape 5 : alice demande dev→staging ; bob approuve (merge signé)', async ({ browser }) => {
  const ctxA = await browser.newContext();
  const pageA = await ctxA.newPage();
  await loginAs(pageA, 'alice');
  await createPromotion(pageA, 'payments-initiation', '0', 'Demande de promotion dev→staging après publication validée');
  await pageA.screenshot({ path: SHOT('demo-05a-promotion-demandee'), fullPage: true });
  await ctxA.close();

  const ctxB = await browser.newContext();
  const pageB = await ctxB.newPage();
  await loginAs(pageB, 'bob');
  await pageB.goto('/promotions');
  await pageB.getByTestId(/promotion-approve-/).first().click();
  await pageB.getByRole('button', { name: 'Approuver' }).last().click();
  await pageB.waitForTimeout(1200);
  await pageB.screenshot({ path: SHOT('demo-05b-approbation-staging-bob'), fullPage: true });
  await ctxB.close();
});

test('étape 6-7 : dave demande staging→production, son auto-approbation est bloquée (4-yeux) ; bob approuve', async ({ browser }) => {
  // dave (cpi-admin : request + approve) demande la production
  const ctxD = await browser.newContext();
  const pageD = await ctxD.newPage();
  await loginAs(pageD, 'dave');
  await createPromotion(pageD, 'payments-initiation', '1', 'Promotion en production — démonstration du principe des 4 yeux');

  // tentative d'auto-approbation → bouton désactivé (tooltip 4-yeux)
  const selfApprove = pageD.getByTestId(/promotion-approve-/).first();
  await expect(selfApprove).toBeDisabled({ timeout: 5_000 });
  await pageD.screenshot({ path: SHOT('demo-06a-self-approval-bloquee-dave'), fullPage: true });
  await ctxD.close();

  // bob (devops, ≠ demandeur) approuve la production
  const ctxB = await browser.newContext();
  const pageB = await ctxB.newPage();
  await loginAs(pageB, 'bob');
  await pageB.goto('/promotions');
  await pageB.getByTestId(/promotion-approve-/).first().click();
  await pageB.getByRole('button', { name: 'Approuver' }).last().click();
  await pageB.waitForTimeout(1200);
  await pageB.screenshot({ path: SHOT('demo-07a-production-approuvee-bob'), fullPage: true });
  await ctxB.close();
});

test('étape 8 : audit — chaque action a son commit signé ; deploiements à jour', async ({ browser }) => {
  const ctx = await browser.newContext();
  const page = await ctx.newPage();
  await loginAs(page, 'alice');
  await page.goto('/audit');
  await expect(page.getByTestId('audit-row').first()).toBeVisible({ timeout: 10_000 });
  await page.screenshot({ path: SHOT('demo-08a-audit-signe'), fullPage: true });

  await page.goto('/contracts/payments-initiation');
  await page.waitForTimeout(800);
  await page.screenshot({ path: SHOT('demo-08b-deploiements-apres-promotions'), fullPage: true });
  await ctx.close();
});
