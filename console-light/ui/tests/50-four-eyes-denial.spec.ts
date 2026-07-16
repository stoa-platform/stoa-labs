import { test, expect } from '@playwright/test';
import { loginAs } from './helpers/auth';
import fs from 'node:fs';
import path from 'node:path';

/**
 * Goal A7 — refus 4-yeux EXERCÉ E2E (le denials.jsonl restait vide).
 *
 * dave (cpi-admin : peut demander ET approuver) demande accounts-read int→prod
 * via la Console (dialog corrigé : chaîne ADR-075 dynamique + change_ref/pv_ref),
 * puis TENTE d'approuver sa propre promotion. L'UI DÉSACTIVE le bouton (garde UX) ;
 * le contournement délibéré (client direct sur le BFF avec le vrai token de dave)
 * se heurte à l'autorité serveur : 403 SELF_APPROVAL_BLOCKED, tracé dans
 * evidence/denials/denials.jsonl — le fichier que consomme la piste d'audit.
 * Contre-épreuve identité : bob (≠ dave) approuve la même promotion → succès.
 *
 * NB : le username = preferred_username = "<user>@bc.example" (pas "dave" nu).
 * La preuve headless équivalente (sans navigateur) : console-light/scripts/
 * prove-a7-four-eyes.sh.
 */

const BFF = 'http://localhost:8787';
const TENANT = 'banking-demo';
const DENIALS = path.resolve(
  __dirname,
  '../../var/governance-repo/evidence/denials/denials.jsonl',
);
const SHOT = (n: string) => `../evidence/screenshots/four-eyes/${n}.png`;

/** Récupère l'access_token OIDC réel depuis le sessionStorage (clé par préfixe,
 * robuste au changement d'authority). */
async function accessToken(page: import('@playwright/test').Page): Promise<string> {
  return page.evaluate(() => {
    for (let i = 0; i < sessionStorage.length; i++) {
      const k = sessionStorage.key(i);
      if (k && k.startsWith('oidc.user:')) {
        return JSON.parse(sessionStorage.getItem(k) as string).access_token as string;
      }
    }
    return '';
  });
}

function denialLines(): Record<string, unknown>[] {
  if (!fs.existsSync(DENIALS)) return [];
  return fs
    .readFileSync(DENIALS, 'utf8')
    .split('\n')
    .filter(Boolean)
    .map((l) => JSON.parse(l));
}

test('4-yeux : dave ne peut pas auto-approuver sa promotion prod (403 + denials.jsonl)', async ({
  browser,
}) => {
  const ctx = await browser.newContext();
  const page = await ctx.newPage();
  await loginAs(page, 'dave');

  // 1. Demande int→prod via le dialog corrigé (chaîne dynamique + refs de gate).
  await page.goto('/promotions');
  // cpi-admin voit un sélecteur de tenant : cibler banking-demo avant tout.
  const tenantSel = page.getByTestId('promotion-tenant-select');
  if (await tenantSel.count()) {
    await tenantSel.selectOption('banking-demo').catch(() => {});
  }
  await page.getByTestId('promotion-new').click();
  await expect(page.getByTestId('promotion-new-dialog')).toBeVisible({ timeout: 15_000 });
  // Le select de contrat est désactivé tant que la requête contrats est en vol.
  const slugSel = page.getByTestId('promotion-create-slug');
  await expect(slugSel).toBeEnabled({ timeout: 15_000 });
  await slugSel.selectOption('accounts-read');
  await page.getByTestId('promotion-create-chain').selectOption({ label: 'int → prod' });
  await page.getByTestId('promotion-create-message').fill('tentative auto-approbation E2E (4-yeux)');
  await page.getByTestId('promotion-create-changeref').fill('CHG-0001');
  await page.getByTestId('promotion-create-pvref').fill('PV-2026-042');

  const created = page.waitForResponse(
    (r) => r.url().includes(`/tenants/${TENANT}/promotions`) && r.request().method() === 'POST',
  );
  await page.getByTestId('promotion-create-submit').click();
  const promoResp = await created;
  expect(promoResp.status()).toBe(200);
  const promoID = (await promoResp.json()).promotion.id as string;
  expect(promoID).toBeTruthy();

  // 2. Garde UX : le bouton Approuver est désactivé pour le demandeur.
  await page.getByTestId(`promotion-expand-${promoID}`).click().catch(() => {});
  await expect(page.getByTestId(`promotion-approve-${promoID}`)).toBeDisabled({ timeout: 10_000 });
  await page.screenshot({ path: SHOT('50-01-bouton-bloque'), fullPage: true });

  // 3. Contournement délibéré de l'UI = client direct sur le BFF avec le VRAI
  //    token de dave → l'autorité serveur refuse (APIRequestContext ignore CORS).
  const wc0 = denialLines().length;
  const daveTok = await accessToken(page);
  expect(daveTok).toBeTruthy();
  const denied = await ctx.request.post(
    `${BFF}/api/v1/tenants/${TENANT}/promotions/${promoID}/approve`,
    { headers: { Authorization: `Bearer ${daveTok}` }, data: { message: 'auto-approbation interdite' } },
  );
  expect(denied.status()).toBe(403);
  expect((await denied.json()).error.code).toBe('SELF_APPROVAL_BLOCKED');

  // 4. Le refus est INSCRIT dans denials.jsonl (fichier synchrone, +≥1 ligne).
  await expect
    .poll(() => denialLines().length, { timeout: 20_000, message: 'denials.jsonl doit croître' })
    .toBeGreaterThan(wc0);
  const entry = denialLines().find((d) => d.resource === promoID);
  expect(entry, 'entrée denials pour cette promotion').toBeTruthy();
  expect(entry!.code).toBe('SELF_APPROVAL_BLOCKED');
  expect(entry!.action).toBe('promote-approve');
  expect(entry!.tenant).toBe(TENANT);
  expect(String(entry!.user)).toContain('@bc.example');

  // 5. CONTRE-ÉPREUVE identité : bob (≠ dave) approuve la MÊME promotion → 200.
  const ctxBob = await browser.newContext();
  const pageBob = await ctxBob.newPage();
  await loginAs(pageBob, 'bob');
  await pageBob.goto('/promotions');
  const bobTok = await accessToken(pageBob);
  const approved = await ctxBob.request.post(
    `${BFF}/api/v1/tenants/${TENANT}/promotions/${promoID}/approve`,
    { headers: { Authorization: `Bearer ${bobTok}` }, data: { message: 'approbation croisée (bob≠dave)' } },
  );
  expect(approved.status()).toBe(200);
  const approvedBy = (await approved.json()).promotion.approved_by as string;
  expect(approvedBy).toContain('@bc.example');
  expect(String(entry!.user)).not.toBe(approvedBy); // le gate est keyé sur l'identité

  await ctxBob.close();
  await ctx.close();
});
