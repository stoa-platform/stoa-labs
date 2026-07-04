import { test } from '@playwright/test';
import { loginAs, logout } from './helpers/auth';

/**
 * Phase A — premier login broker des 4 personas : crée les users fédérés dans
 * Keycloak. À exécuter AVANT l'assignation des rôles (labsetup kc-roles), puis
 * re-login (les specs suivantes) pour que les tokens portent les rôles.
 */
for (const u of ['alice', 'bob', 'carol', 'dave']) {
  test(`premier login broker — ${u}`, async ({ browser }) => {
    const ctx = await browser.newContext();
    const page = await ctx.newPage();
    await loginAs(page, u);
    await logout(page);
    await ctx.close();
  });
}
