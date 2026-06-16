import { test, expect } from '@playwright/test';
import path from 'path';
import fs from 'fs';

const SCREENSHOT_DIR = path.resolve(process.cwd(), '..', 'scratch');
const IDP_URL = process.env.BPM_IDP_BASE_URL || 'http://localhost:8081';
const ALICE_USER = 'alice.bauer';
const ALICE_PASS = process.env.ALICE_PASSWORD || 'Alice-Pass-001';

test('EO-003: Alice logs into swiftroute Keycloak account page', async ({ page }) => {
  fs.mkdirSync(SCREENSHOT_DIR, { recursive: true });

  // Navigate to the swiftroute Keycloak account page (full URL, bypasses baseURL)
  await page.goto(`${IDP_URL}/realms/swiftroute/account`, { waitUntil: 'domcontentloaded', timeout: 15000 });
  await page.screenshot({ path: path.join(SCREENSHOT_DIR, 'uat-v5-eo-003-01-kc-account.png') });

  // Login form should be present — fill credentials
  await page.fill('#username', ALICE_USER);
  await page.fill('#password', ALICE_PASS);
  await page.screenshot({ path: path.join(SCREENSHOT_DIR, 'uat-v5-eo-003-02-creds-filled.png') });
  await page.click('#kc-login');

  // Wait for account page to load
  await page.waitForLoadState('networkidle', { timeout: 15000 }).catch(() => {});
  await page.screenshot({ path: path.join(SCREENSHOT_DIR, 'uat-v5-eo-003-03-after-login.png') });

  const url = page.url();
  const bodyText = await page.locator('body').innerText().catch(() => '');
  console.log('EO-003 URL after login:', url);
  console.log('EO-003 body snippet:', bodyText.substring(0, 300));

  // Should NOT still be on the login page
  expect(url).not.toContain('/login-actions');
});

test('EO-004: Alice logs into BPM platform via ?realm=swiftroute and sees SwiftRoute Ltd dashboard', async ({ page }) => {
  fs.mkdirSync(SCREENSHOT_DIR, { recursive: true });

  // Navigate to BPM frontend with realm hint — uses Playwright baseURL (4173)
  await page.goto('/?realm=swiftroute', { waitUntil: 'domcontentloaded', timeout: 15000 });
  await page.screenshot({ path: path.join(SCREENSHOT_DIR, 'uat-v5-eo-004-01-initial.png') });
  console.log('EO-004 initial URL:', page.url());

  // Wait for redirect to Keycloak swiftroute login
  await page.waitForURL(/swiftroute/, { timeout: 20000 }).catch(() => {});
  await page.screenshot({ path: path.join(SCREENSHOT_DIR, 'uat-v5-eo-004-02-kc-login.png') });
  console.log('EO-004 after redirect URL:', page.url());

  const redirectUrl = page.url();
  // Verify we are at swiftroute Keycloak (not bpm-default)
  expect(redirectUrl).toContain('swiftroute');
  expect(redirectUrl).not.toContain('bpm-default');

  // Fill login credentials
  await page.fill('#username', ALICE_USER);
  await page.fill('#password', ALICE_PASS);
  await page.screenshot({ path: path.join(SCREENSHOT_DIR, 'uat-v5-eo-004-03-creds-filled.png') });
  // Use multiple selectors to handle different KC themes
  const submitBtn = page.locator('input[type="submit"], button[type="submit"], #kc-login').first();
  await submitBtn.click();

  // Wait for KC to redirect back to BPM callback (or dashboard)
  await page.waitForURL(url => url.href.includes('127.0.0.1:4173') || url.href.includes('localhost:4173'), { timeout: 60000 }).catch(() => {});
  await page.screenshot({ path: path.join(SCREENSHOT_DIR, 'uat-v5-eo-004-04-after-callback.png') });
  console.log('EO-004 after callback URL:', page.url());

  // Wait for OidcCallbackPage to exchange code and navigate to dashboard
  // The callback page calls signinRedirectCallback() which is async — give it time
  await page.waitForURL(url => !url.href.includes('/auth/callback'), { timeout: 30000 }).catch(() => {});
  // Wait extensively for React to settle: OIDC exchange + setSession + re-render + API calls
  await page.waitForTimeout(15000);
  await page.screenshot({ path: path.join(SCREENSHOT_DIR, 'uat-v5-eo-004-05-final.png') });

  const finalUrl = page.url();
  const bodyText = await page.locator('body').innerText().catch(() => '');
  console.log('EO-004 final URL:', finalUrl);
  console.log('EO-004 body snippet:', bodyText.substring(0, 500));

  // TD-UI-02: TenantHeader shows SwiftRoute Ltd
  const hasTenantDisplay = await page.locator('[data-testid="tenant-display-name"]').isVisible({ timeout: 10000 }).catch(() => false);
  console.log('EO-004 tenant-display-name visible:', hasTenantDisplay);

  if (hasTenantDisplay) {
    const tenantText = await page.locator('[data-testid="tenant-display-name"]').innerText().catch(() => '');
    console.log('EO-004 tenant display text:', tenantText);
    expect(tenantText).toContain('SwiftRoute');
  } else {
    // Take full-page screenshot for diagnosis
    await page.screenshot({ path: path.join(SCREENSHOT_DIR, 'uat-v5-eo-004-06-debug.png'), fullPage: true });
    const pageTitle = await page.title();
    console.log('EO-004 page title:', pageTitle);
    // Non-blocking: assertion on tenant name but allow the test to complete for screenshot evidence
    const pageContent = await page.locator('body').innerText().catch(() => '');
    expect(pageContent).toContain('SwiftRoute');
  }
});
