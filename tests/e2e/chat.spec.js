const { test, expect } = require('@playwright/test')

const baseURL = 'http://127.0.0.1:4001'

/**
 * Run a test-support server command and return its JSON data.
 * For non-login commands that return JSON responses.
 */
async function runServerCommand(page, command, payload = {}) {
  const url = new URL('/api/testing/command', baseURL)
  url.searchParams.set('command', command)
  url.searchParams.set('payload', JSON.stringify(payload))

  const response = await page.request.get(url.toString())
  expect(response.ok()).toBeTruthy()
  const body = await response.json()
  return body.data
}

/**
 * Log in by navigating the browser to the test-support login endpoint.
 * The server creates a session and redirects to `next` (default "/").
 * The browser follows the redirect and ends up authenticated.
 */
async function loginViaTestSupport(page, { email = 'e2e@example.com', username = 'e2e_user', password = 'supersecurepass', display_name, next = '/' } = {}) {
  const url = new URL('/api/testing/command', baseURL)
  url.searchParams.set('command', 'login')
  url.searchParams.set('payload', JSON.stringify({ email, username, password, display_name, next }))
  await page.goto(url.toString())
  await expect(page.locator('#logout-link')).toBeVisible()
}

async function loginAsSeedUser(page) {
  await loginViaTestSupport(page)
}

test.beforeEach(async ({ page }) => {
  await page.addInitScript(() => {
    const notifications = []

    class FakeNotification {
      static permission = 'granted'

      constructor(title, options = {}) {
        this.title = title
        this.options = options
        notifications.push({ title, ...options })
      }

      close() {}
    }

    Object.defineProperty(document, 'visibilityState', {
      configurable: true,
      get: () => 'hidden',
    })

    window.Notification = FakeNotification
    window.__rfchatNotifications = notifications
  })
})

test('desktop user can switch channels and send a chat message', async ({ page }, testInfo) => {
  test.skip(testInfo.project.name !== 'desktop-chromium', 'desktop-only interaction flow')

  const displayName = 'E2E User'
  const unique = `${Date.now()}`.slice(-6)
  const message = `Hello **bold** @e2e_user`
  const code = `console.log("${unique}")`
  const link = `https://example.com/${unique}`

  await loginAsSeedUser(page)
  await expect(page.locator('#channel-link-general')).toBeVisible()

  await page.locator('#channel-link-engineering').click()
  await expect(page).toHaveURL(/\?channel=engineering$/)
  await expect(page.locator('#message-form')).toBeVisible()
  await expect(page.locator('#rich-composer-shell')).not.toHaveClass(/is-expanded/)

  const composer = page.locator('#message-form [contenteditable="true"]').first()

  await expect(composer).toBeVisible()
  await composer.click()
  await expect(page.locator('#rich-composer-shell')).toHaveClass(/is-focused/)
  await composer.pressSequentially(message)
  await page.getByRole('button', { name: 'Code block' }).click()
  await composer.pressSequentially(code)
  await page.getByRole('button', { name: 'Code block' }).click()
  await composer.pressSequentially(`\n\n${link}`)
  await page.getByRole('button', { name: 'Send message' }).click()

  const sentMessage = page.locator(`#message-list [data-markdown-source*="${unique}"]`).last()
  await expect(sentMessage).toContainText('Hello')
  await expect(sentMessage).toContainText('bold')
  await expect(sentMessage).toContainText('@e2e_user')
  await expect(sentMessage).toContainText(code)
  await expect(sentMessage).toContainText(link)
  await expect(page.locator('#message-list')).toContainText(displayName)
})

test('mobile user can open drawers and reaction bottom sheet', async ({ page }, testInfo) => {
  test.skip(testInfo.project.name !== 'mobile-safari', 'mobile-only interaction flow')

  await loginAsSeedUser(page)

  await page.locator('#open-mobile-sidebar').click()
  await expect(page.locator('#mobile-channel-drawer')).toHaveClass(/translate-x-0/)
  await page.locator('#channel-link-engineering').click()
  await expect(page).toHaveURL(/\?channel=engineering$/)

  await page.locator('#open-mobile-members').click()
  await expect(page.locator('#mobile-members-drawer')).toHaveClass(/translate-x-0/)
  await expect(page.locator('#mobile-members-drawer')).toContainText('Members')
  await page.locator('#close-mobile-members').click()

  const reactionButton = page.locator('[id^="open-reaction-picker-"]').first()
  await reactionButton.click()

  const reactionSheet = page.locator('[id^="reaction-picker-"]').first()
  await expect(reactionSheet).toBeVisible()
  await expect(reactionSheet).toHaveClass(/fixed/)

  await page.locator('[id^="reaction-picker-default-"]').first().click()
  await expect(page.locator('[id^="reaction-"]').first()).toBeVisible()
})

test('settings trigger is visible and navigates to authenticated settings route', async ({ page }) => {
  await loginViaTestSupport(page)

  await expect(page.locator('#open-settings-link')).toBeVisible()

  await page.locator('#open-settings-link').click()
  await expect(page).toHaveURL(/\/settings$/)
  await expect(page.locator('#settings-panel-title')).toBeVisible()

  const guest = await page.context().browser().newPage()
  await guest.goto('/settings')
  await expect(guest).toHaveURL(/\/login$/)
  await guest.close()
})

test('server branding updates settings and shell surfaces', async ({ page }) => {
  await runServerCommand(page, 'set_server_name', { name: 'RFChat' })
  await loginAsSeedUser(page)

  await page.locator('#open-settings-link').click()
  await expect(page).toHaveURL(/\/settings$/)

  await page.getByRole('button', { name: 'Server management' }).click()
  await page.getByLabel('Server name').fill('Orbit HQ')
  await page.getByRole('button', { name: 'Save server settings' }).click()

  await expect(page.locator('#flash-group')).toContainText('Server settings updated.')
  await expect(page.getByLabel('Server name')).toHaveValue('Orbit HQ')

  await page.locator('#back-to-chat-link').click()
  await expect(page).toHaveURL(/\/($|\?)/)
  await expect(page.locator('#mobile-channel-drawer')).toContainText('Orbit HQ')
})

test('inactive channel mention triggers browser notification', async ({ browser }) => {
  const unique = `${Date.now()}`.slice(-6)
  const authorEmail = `test_notify_${unique}@example.com`
  const authorUsername = `test_notify_${unique}`
  const authorDisplayName = `Notify ${unique}`
  const password = 'supersecurepass'
  const author = await browser.newPage()
  const receiver = await browser.newPage()

  await receiver.addInitScript(() => {
    const notifications = []

    class FakeNotification {
      static permission = 'granted'

      constructor(title, options = {}) {
        this.title = title
        this.options = options
        notifications.push({ title, ...options })
      }

      close() {}
    }

    Object.defineProperty(document, 'visibilityState', {
      configurable: true,
      get: () => 'hidden',
    })

    window.Notification = FakeNotification
    window.__rfchatNotifications = notifications
  })

  await loginViaTestSupport(author, { email: authorEmail, username: authorUsername, password, display_name: authorDisplayName })
  await loginViaTestSupport(receiver)

  await author.locator('#channel-link-engineering').click()
  await expect(author).toHaveURL(/\?channel=engineering$/)

  const composer = author.locator('#message-form [contenteditable="true"]').first()
  await composer.click()
  await composer.pressSequentially(`ping @e2e_user ${unique}`)
  await author.getByRole('button', { name: 'Send message' }).click()

  await expect(receiver.locator('#channel-mention-engineering')).toBeVisible()

  await expect.poll(async () => {
    return await receiver.evaluate(() => window.__rfchatNotifications || [])
  }).toContainEqual(
    expect.objectContaining({
      title: expect.stringContaining('mentioned you in #Engineering'),
      body: expect.stringContaining(`ping @e2e_user ${unique}`),
    })
  )

  await author.close()
  await receiver.close()
})
