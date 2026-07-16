/**
 * Console Light — configuration Tailwind.
 * Les design tokens proviennent du design system @stoa/shared vendorisé
 * (src/vendor/stoa-shared/tailwind/tokens.js) — voir CADRAGE §4 (socle transverse).
 */
const tokens = require('./src/vendor/stoa-shared/tailwind/tokens.js');

/** @type {import('tailwindcss').Config} */
module.exports = {
  darkMode: 'class',
  content: ['./index.html', './src/**/*.{ts,tsx}'],
  theme: {
    extend: tokens,
  },
  plugins: [],
};
