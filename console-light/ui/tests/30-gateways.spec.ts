import { test } from '@playwright/test';

/**
 * Tâche #21 — « log toi sur toutes les gateways » : preuve de connexion sur
 * chaque gateway RÉELLE avec capture. (APISIX n'a pas d'UI : preuve via admin
 * API en evidence/ci/, hors Playwright.)
 */
const SHOT = (n: string) => `../evidence/screenshots/gateways/${n}.png`;
test.describe.configure({ mode: 'serial' });

test('WSO2 — login publisher (admin/admin) + liste des APIs', async ({ browser }) => {
  const ctx = await browser.newContext({ ignoreHTTPSErrors: true });
  const page = await ctx.newPage();
  await page.goto('https://localhost:9443/publisher', { waitUntil: 'domcontentloaded', timeout: 60_000 });
  // login Carbon/IS
  const user = page.locator('#usernameUserInput, #username, input[name="username"]').first();
  await user.waitFor({ state: 'visible', timeout: 30_000 });
  await user.fill('admin');
  await page.locator('#password, input[name="password"]').first().fill('admin');
  await page.locator('button[type="submit"], input[type="submit"]').first().click();
  // consentement éventuel puis liste des APIs
  await page.waitForLoadState('networkidle').catch(() => {});
  const approve = page.getByRole('button', { name: /continue|approve|allow/i }).first();
  if (await approve.isVisible().catch(() => false)) await approve.click();
  await page.waitForURL(/publisher/, { timeout: 30_000 }).catch(() => {});
  await page.waitForTimeout(4000);
  await page.screenshot({ path: SHOT('wso2-publisher-apis'), fullPage: true });
  await ctx.close();
});

test('webMethods RÉEL — login UI (Administrator/manage) + écran APIs', async ({ browser }) => {
  const ctx = await browser.newContext();
  const page = await ctx.newPage();
  await page.goto('http://localhost:19072/apigatewayui', { waitUntil: 'domcontentloaded', timeout: 60_000 });
  const user = page.locator('#username, input[name="username"], input[type="text"]').first();
  await user.waitFor({ state: 'visible', timeout: 45_000 });
  await user.fill('Administrator');
  await page.locator('#password, input[name="password"], input[type="password"]').first().fill('manage');
  await page.locator('button[type="submit"], input[type="submit"], button:has-text("Log"), button:has-text("Sign")').first().click();
  await page.waitForTimeout(8000); // SPA lente au premier chargement
  await page.screenshot({ path: SHOT('webmethods-ui-home'), fullPage: true });
  // la vue APIs via le menu de navigation (pas d'URL devinée)
  await page.getByRole('link', { name: 'APIs', exact: true }).first().click();
  await page.waitForTimeout(6000);
  await page.screenshot({ path: SHOT('webmethods-ui-apis'), fullPage: true });
  await ctx.close();
});
