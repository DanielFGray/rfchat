const { test, expect } = require('@playwright/test')

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

test('user can log in, switch channels, and send a chat message', async ({ page }) => {
  const email = 'e2e@example.com'
  const displayName = 'E2E User'
  const password = 'supersecurepass'
  const unique = `${Date.now()}`.slice(-6)
  const message = `Hello **bold** @e2e_user`
  const code = `console.log("${unique}")`
  const link = `https://example.com/${unique}`

  await page.goto('/login')

  await page.getByLabel('Email').pressSequentially(email)
  await page.getByLabel('Password').pressSequentially(password)

  await page.getByRole('button', { name: 'Log in' }).click()

  await expect(page).toHaveURL(/\/$/)
  await expect(page.locator('#logout-link')).toBeVisible()
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

test('settings trigger is visible and navigates to authenticated settings route', async ({ page }) => {
  await page.goto('/login')
  await page.getByLabel('Email').fill('e2e@example.com')
  await page.getByLabel('Password').fill('supersecurepass')
  await page.getByRole('button', { name: 'Log in' }).click()

  await expect(page).toHaveURL(/\/$/)
  await expect(page.locator('#open-settings-link')).toBeVisible()

  await page.locator('#open-settings-link').click()
  await expect(page).toHaveURL(/\/settings$/)
  await expect(page.locator('#settings-panel-title')).toBeVisible()

  const guest = await page.context().browser().newPage()
  await guest.goto('/settings')
  await expect(guest).toHaveURL(/\/login$/)
  await guest.close()
})

test('inactive channel mention triggers browser notification', async ({ browser }) => {
  const unique = `${Date.now()}`.slice(-6)
  const authorEmail = `notify-${unique}@example.com`
  const authorUsername = `notify_${unique}`
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

  await author.goto('/register')
  await author.getByLabel('Email').fill(authorEmail)
  await author.getByLabel('Username').fill(authorUsername)
  await author.getByLabel('Display name').fill(authorDisplayName)
  await author.getByLabel('Password').fill(password)
  await author.getByRole('button', { name: 'Create account' }).click()

  await expect(author).toHaveURL(/\/login$/)
  await author.getByLabel('Email').fill(authorEmail)
  await author.getByLabel('Password').fill(password)
  await author.getByRole('button', { name: 'Log in' }).click()
  await expect(author.locator('#logout-link')).toBeVisible()

  await receiver.goto('/login')
  await receiver.getByLabel('Email').fill('e2e@example.com')
  await receiver.getByLabel('Password').fill(password)
  await receiver.getByRole('button', { name: 'Log in' }).click()
  await expect(receiver.locator('#logout-link')).toBeVisible()

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
