import { existsSync } from 'node:fs';
import { defineConfig, devices } from '@playwright/test';

// Use the pinned Playwright's own browser when installed; in sandboxes that only have a pre-installed
// Chromium (e.g. PLAYWRIGHT_BROWSERS_PATH=/opt/pw-browsers) point PW_CHROMIUM_EXECUTABLE at it.
const localChromium = '/opt/pw-browsers/chromium-1194/chrome-linux/chrome';
const executablePath = process.env.PW_CHROMIUM_EXECUTABLE || (existsSync(localChromium) ? localChromium : undefined);

export default defineConfig({
  testDir: './e2e',
  timeout: 90_000,
  retries: 0,
  reporter: [['list']],
  use: {
    baseURL: 'http://localhost:4173',
    trace: 'off',
    ...devices['Desktop Chrome'],
    launchOptions: executablePath ? { executablePath } : {},
  },
  webServer: {
    command: 'npm run build && npm run preview',
    url: 'http://localhost:4173/config.json',
    reuseExistingServer: false,
    timeout: 60_000,
  },
});
