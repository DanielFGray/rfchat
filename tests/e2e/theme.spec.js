const { test, expect } = require('@playwright/test')

const baseURL = 'http://127.0.0.1:4001'

async function login(page) {
  const url = new URL('/api/testing/command', baseURL)
  url.searchParams.set('command', 'login')
  url.searchParams.set('payload', JSON.stringify({ email: 'e2e@example.com', username: 'e2e_user', password: 'supersecurepass', next: '/' }))
  await page.goto(url.toString())
  await expect(page.locator('#guild-shell[data-hydrated="true"]')).toBeVisible()
}

// Skip colour transitions so computed styles and screenshots show the settled theme.
const settle = (page) =>
  page.addStyleTag({ content: '*, *::before, *::after { transition: none !important }' })

const surfaceColors = (page) =>
  page.evaluate(() => ({
    theme: document.documentElement.getAttribute('data-theme'),
    scheme: getComputedStyle(document.documentElement).colorScheme,
    sidebar: getComputedStyle(document.querySelector('#guild-shell aside')).backgroundColor,
    main: getComputedStyle(document.querySelector('main')).backgroundColor,
  }))

test('theme toggle switches shell surfaces between light, dark and system', async ({ page }, testInfo) => {
  await page.emulateMedia({ colorScheme: 'dark' })
  await login(page)
  await settle(page)

  await page.locator('button[data-phx-theme="light"]').first().click()
  await expect(page.locator('html')).toHaveAttribute('data-theme', 'light')
  const light = await surfaceColors(page)
  await page.screenshot({ path: testInfo.outputPath('light.png') })

  await page.locator('button[data-phx-theme="dark"]').first().click()
  await expect(page.locator('html')).toHaveAttribute('data-theme', 'dark')
  const dark = await surfaceColors(page)
  await page.screenshot({ path: testInfo.outputPath('dark.png') })

  // The choice survives a full page load.
  await page.locator('button[data-phx-theme="light"]').first().click()
  await page.reload()
  await expect(page.locator('#guild-shell[data-hydrated="true"]')).toBeVisible()
  await expect(page.locator('html')).toHaveAttribute('data-theme', 'light')
  await settle(page)
  await page.screenshot({ path: testInfo.outputPath('light-reloaded.png') })
  await page.locator('button[data-phx-theme="dark"]').first().click()

  expect(light.scheme).toBe('light')
  expect(dark.scheme).toBe('dark')
  expect(light.main).not.toBe(dark.main)
  expect(light.sidebar).not.toBe(dark.sidebar)

  await page.locator('button[data-phx-theme="system"]').first().click()
  await expect(page.locator('html')).not.toHaveAttribute('data-theme', /.+/)
  expect((await surfaceColors(page)).main).toBe(dark.main)
  await page.emulateMedia({ colorScheme: 'light' })
  expect((await surfaceColors(page)).main).toBe(light.main)
})

test('light theme applies to the settings page', async ({ page }, testInfo) => {
  await page.emulateMedia({ colorScheme: 'dark' })
  await login(page)
  await page.locator('button[data-phx-theme="light"]').first().click()
  await page.locator('#open-settings-link').click()
  await expect(page.locator('#settings-panel-title')).toBeVisible()
  await settle(page)
  await expect(page.locator('html')).toHaveAttribute('data-theme', 'light')
  const bg = await page.evaluate(() => getComputedStyle(document.querySelector('main')).backgroundColor)
  expect(bg).toBe('oklch(0.92 0.004 286.32)')
  await page.screenshot({ path: testInfo.outputPath('settings-light.png') })
})
