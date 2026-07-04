import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';

// Console Light — dev server sur :5173, proxy /api → BFF governance-api (:8787).
// Voir API-CONTRACT.md §0 (topologie & ports).
export default defineConfig({
  plugins: [react()],
  server: {
    port: 5173,
    strictPort: true,
    proxy: {
      '/api': {
        target: 'http://localhost:8787',
        changeOrigin: true,
      },
    },
  },
});
