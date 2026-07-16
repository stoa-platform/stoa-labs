import { test, expect } from '@playwright/test';
import { loginAs } from './helpers/auth';

/**
 * REPLAY COMPLET (demande Christophe) : édition réelle → brouillon → publication
 * → promotion dev→staging → approbation par un pair. Chaque étape = commit signé
 * → push auto → webhook → Jenkins. Le marqueur horodaté garantit de vrais diffs.
 */
const SHOT = (n: string) => `../evidence/screenshots/replay/${n}.png`;
const MARK = `replay ${new Date().toISOString().slice(0, 16)}`;
test.describe.configure({ mode: 'serial' });

test('alice : édition réelle + publication de customer-referential', async ({ browser }) => {
  const ctx = await browser.newContext();
  const page = await ctx.newPage();
  await loginAs(page, 'alice');

  await page.goto('/contracts/customer-referential/edit');
  const desc = page.getByTestId('editor-description');
  await desc.waitFor({ state: 'visible', timeout: 15_000 });
  const current = (await desc.inputValue()).split(' [replay')[0];
  await desc.fill(`${current} [${MARK}]`);

  await page.getByTestId('editor-save').click();
  await expect(page.getByTestId('commit-sha').first()).toBeVisible({ timeout: 15_000 });
  await page.screenshot({ path: SHOT('replay-01-brouillon'), fullPage: false });

  await page.getByTestId('editor-publish').click();
  await page.locator('textarea').last().fill(`Publication replay — ${MARK}`);
  await page.getByRole('button', { name: /confirmer|publier/i }).last().click();
  await expect(page.getByTestId('commit-sha').first()).toBeVisible({ timeout: 15_000 });
  await ctx.close();
});

test('alice demande dev→staging ; bob approuve (merge signé → push → CI)', async ({ browser }) => {
  const ctxA = await browser.newContext();
  const pageA = await ctxA.newPage();
  await loginAs(pageA, 'alice');
  await pageA.goto('/promotions');
  await pageA.getByTestId('promotion-new').click();
  await pageA.getByTestId('promotion-create-slug').selectOption('customer-referential');
  await pageA.getByTestId('promotion-create-chain').selectOption('0');
  await pageA.getByTestId('promotion-create-message').fill(`Promotion replay vers staging — ${MARK}`);
  await pageA.getByTestId('promotion-create-submit').click();
  await expect(pageA.getByTestId('promotion-new-dialog')).toHaveCount(0, { timeout: 10_000 });
  await ctxA.close();

  const ctxB = await browser.newContext();
  const pageB = await ctxB.newPage();
  await loginAs(pageB, 'bob');
  await pageB.goto('/promotions');
  await pageB.getByTestId(/promotion-approve-/).first().click();
  await pageB.getByRole('button', { name: 'Approuver' }).last().click();
  await pageB.waitForTimeout(1500);
  await pageB.screenshot({ path: SHOT('replay-02-approbation'), fullPage: true });
  await ctxB.close();
});
