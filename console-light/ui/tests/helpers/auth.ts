import { Page, expect } from '@playwright/test';

/**
 * Login complet via le broker Oracle (Dex) — le VRAI flux de la démo :
 * Console → Keycloak (kc_idp_hint=oracle) → Dex (login/password) → retour Console.
 * Gère le formulaire Keycloak "update account information" du premier login broker.
 */
export async function loginAs(page: Page, username: string, password = 'password') {
  await page.goto('/');
  // Si déjà sur l'app (session existante), logout d'abord est géré par fixture — ici on suppose contexte vierge.
  await page.getByTestId('login-oracle').click();

  // Dex : formulaire login (email ou username) / password.
  await page.waitForURL(/:5556\/dex\//, { timeout: 15_000 });
  const loginField = page.locator('input#login, input[name="login"]').first();
  await loginField.fill(`${username}@bc.example`);
  await page.locator('input#password, input[name="password"]').first().fill(password);
  await page.locator('button[type="submit"], #submit-login').first().click();

  // Keycloak peut présenter "update account information" au premier login broker (KC26).
  try {
    const fn = page.locator('#firstName');
    await fn.waitFor({ state: 'visible', timeout: 4_000 });
    const cap = username.charAt(0).toUpperCase() + username.slice(1);
    await fn.fill(cap);
    await page.locator('#lastName').fill('Demo');
    const email = page.locator('#email');
    if (await email.isVisible().catch(() => false)) {
      if (!(await email.inputValue())) await email.fill(`${username}@bc.example`);
    }
    await page.locator('input[type="submit"], button[type="submit"]').first().click();
  } catch {
    // pas de formulaire de complétion — tant mieux
  }

  // Retour sur la console authentifiée.
  await page.waitForURL(/localhost:5173/, { timeout: 20_000 });
  await expect(page.getByTestId('page-login')).toHaveCount(0, { timeout: 15_000 });
}

export async function logout(page: Page) {
  const btn = page.getByTestId('logout');
  if (await btn.isVisible().catch(() => false)) {
    await btn.click();
    await page.waitForURL(/localhost:5173/, { timeout: 15_000 }).catch(() => {});
  }
  await page.context().clearCookies();
}
