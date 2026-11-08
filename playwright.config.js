const { defineConfig, devices } = require('@playwright/test')

// PHX_SERVER goes only on `mix phx.server`: config/test.exs turns the endpoint off, and with
// PHX_SERVER set the reset script would serve port 4001 while it runs, so the readiness check
// would pass before the real server starts.
const e2eMixEnv = 'env MIX_ENV=test PORT=4001 MIX_TEST_PARTITION=e2e MIX_BUILD_PATH=_build/e2e ENABLE_TEST_SUPPORT_COMMANDS=1'

module.exports = defineConfig({
  testDir: './tests/e2e',
  timeout: 60_000,
  expect: {
    timeout: 10_000,
  },
  fullyParallel: false,
  forbidOnly: !!process.env.CI,
  retries: process.env.CI ? 2 : 0,
  workers: 1,
  reporter: process.env.CI ? [['html'], ['list']] : 'list',
  use: {
    baseURL: 'http://127.0.0.1:4001',
    trace: 'on-first-retry',
    screenshot: 'only-on-failure',
    video: 'retain-on-failure',
  },
  webServer: {
    command:
      `${e2eMixEnv} mix ecto.migrate && ${e2eMixEnv} mix run priv/repo/e2e_reset.exs && ${e2eMixEnv} mix assets.build && ${e2eMixEnv} PHX_SERVER=true mix phx.server`,
    url: 'http://127.0.0.1:4001/login',
    reuseExistingServer: false,
    stdout: 'pipe',
    stderr: 'pipe',
    timeout: 180_000,
  },
  projects: [
    {
      name: 'desktop-chromium',
      use: { ...devices['Desktop Chrome'] },
    },
    {
      name: 'mobile-safari',
      use: { ...devices['iPhone 12'] },
    },
  ],
})
