// apple_token.mjs — grab the App Store amp-api bearer token via a headless browser.
//
// Apple removed the token from the App Store page HTML/JS; it's now created at runtime.
// A real browser loads the app page, its JS calls amp-api.apps.apple.com with an
// Authorization header, and we intercept that header. This is the only reliable way
// to get the token now (your Q1: this is the legit headless-browser use case).
//
// Setup (one-time):
//   npm init -y && npm i playwright && npx playwright install chromium
//
// Use:
//   node apple_token.mjs 324684580 us        # prints the bearer token to stdout
//   TOKEN=$(node apple_token.mjs 324684580)  # capture for amp_reviews.exs
//
// The token is shared/public (not per-user) and rotates periodically — grab a fresh
// one per session. Tokens typically last hours.

import { chromium } from 'playwright';

const appId = process.argv[2];
const country = process.argv[3] || 'us';
if (!appId) { console.error('usage: node apple_token.mjs <appId> [country]'); process.exit(1); }

const browser = await chromium.launch({ headless: true });
const page = await (await browser.newContext({
  userAgent: 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 Safari/605.1.15'
})).newPage();

let token = null;
page.on('request', (req) => {
  const auth = req.headers()['authorization'];
  if (!token && auth && auth.startsWith('Bearer ') && req.url().includes('amp-api')) {
    token = auth.slice('Bearer '.length);
  }
});

try {
  await page.goto(`https://apps.apple.com/${country}/app/id${appId}`, { waitUntil: 'networkidle', timeout: 30000 });
  // reviews load lazily — scroll to trigger the amp-api call if not already fired
  for (let i = 0; i < 6 && !token; i++) {
    await page.mouse.wheel(0, 2000);
    await page.waitForTimeout(800);
  }
} catch (e) {
  // networkidle can time out on heavy pages; we may already have the token
}
await browser.close();

if (token) { console.log(token); }
else { console.error('token not captured — try re-running, or increase scroll/wait'); process.exit(2); }
