const { defineConfig, devices } = require('@playwright/test')

const e2eMixEnv = 'env MIX_ENV=test PHX_SERVER=true PORT=4001 MIX_TEST_PARTITION=e2e MIX_BUILD_PATH=_build/e2e ENABLE_TEST_SUPPORT_COMMANDS=1'

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
      `${e2eMixEnv} mix ecto.reset && ${e2eMixEnv} mix run priv/repo/e2e_seeds.exs && ${e2eMixEnv} mix assets.build && ${e2eMixEnv} mix phx.server`,
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
