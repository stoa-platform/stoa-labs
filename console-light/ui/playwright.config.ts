import { defineConfig } from '@playwright/test';

export default defineConfig({
  testDir: './tests',
  timeout: 60_000,
  fullyParallel: false,
  workers: 1,
  retries: 0,
  use: {
    baseURL: 'http://localhost:5173',
    channel: 'chrome', // Chrome installé sur la machine — pas de download navigateur
    viewport: { width: 1440, height: 900 },
    trace: 'retain-on-failure',
    locale: 'fr-FR',
  },
});
