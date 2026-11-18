const { test, expect } = require('@playwright/test')

const baseURL = 'http://127.0.0.1:4001'

async function command(request, name, payload = {}) {
  const response = await request.post(new URL('/api/testing/command', baseURL).toString(), {
    data: { command: name, ...payload },
  })
  expect(response.ok()).toBeTruthy()
  return (await response.json()).data
}

async function login(page, credentials) {
  const url = new URL('/api/testing/command', baseURL)
  url.searchParams.set('command', 'login')
  url.searchParams.set('payload', JSON.stringify({ ...credentials, next: '/' }))
  await page.goto(url.toString())
  await expect(page.locator('#server-shell[data-hydrated="true"]')).toBeVisible({ timeout: 60_000 })
}

// Act only once the socket has connected: the live mount resets what was done before it. The
// connected mount reads the shared remote test database, which can take several seconds.
async function connected(page) {
  await expect(page.locator('[data-phx-main]')).toHaveClass(/phx-connected/, { timeout: 60_000 })
}

// The radio inputs are visually hidden inside their labels, so a click goes to the label.
async function choose(page, rowKey, flag, state) {
  await page.locator(`label:has(#overwrite-${rowKey}-${flag}-${state})`).click()
  await expect(page.locator(`#overwrite-${rowKey}-${flag}-${state}`)).toBeChecked()
}

test('an owner makes a channel private to one role', async ({ page, browser, request }, testInfo) => {
  // The desktop sidebar shows the channel links; the mobile project would also repeat the flow
  // against the same database.
  test.skip(testInfo.project.name !== 'desktop-chromium', 'desktop-only settings flow')
  const owner = { email: 'e2e@example.com', username: 'e2e_user', password: 'supersecurepass' }
  const member = {
    email: 'e2e-perms-member@example.com',
    username: 'e2e_perms_member',
    password: 'supersecurepass',
  }
  await command(request, 'upsert_user', member)

  const memberContext = await browser.newContext()
  const memberPage = await memberContext.newPage()
  await login(memberPage, member)
  await expect(memberPage.locator('#channel-link-random')).toBeVisible()

  await login(page, owner)
  await page.goto('/settings?tab=roles')
  await connected(page)
  await page.getByLabel('New role name').fill('E2E Insiders')
  await page.locator('#create-role-button').click()
  const roleRow = page.locator('#role-list > li', { hasText: 'E2E Insiders' })
  await expect(roleRow).toHaveCount(1)
  const roleId = (await roleRow.getAttribute('id')).replace('role-row-', '')

  await page.locator('#settings-tab-server').click()
  await page.locator('#open-channel-manager').click()
  await page.locator('#edit-channel-random').click()
  await expect(page.locator('#channel-permissions')).toBeVisible()

  // @everyone loses view_channel.
  const everyoneRow = page.locator('#overwrite-list > li').first()
  await expect(everyoneRow).toContainText('@everyone')
  const everyoneKey = (await everyoneRow.getAttribute('id')).replace('overwrite-row-', '')
  await page.locator(`#toggle-overwrite-${everyoneKey}`).click()
  await choose(page, everyoneKey, 'view_channel', 'deny')
  await page.locator(`#save-overwrite-${everyoneKey}`).click()
  await expect(page.locator('#flash-group')).toContainText('Permissions saved.')

  // The new role gets it back; adding the override opens its row.
  const roleKey = `role-${roleId}`
  await page.locator('#add-overwrite-role').selectOption(`role:${roleId}`)
  await page.locator('#add-overwrite-role-button').click()
  await expect(page.locator(`#overwrite-form-${roleKey}`)).toBeVisible()
  await choose(page, roleKey, 'view_channel', 'allow')
  await page.locator(`#save-overwrite-${roleKey}`).click()
  await expect(page.locator(`#overwrite-row-${roleKey}`)).toContainText('+1')
  await page.screenshot({ path: testInfo.outputPath('channel-permissions.png') })

  // The member's open sidebar drops the channel without a reload, and it stays gone after one.
  await expect(memberPage.locator('#channel-link-random')).toHaveCount(0)
  await memberPage.reload()
  await expect(memberPage.locator('#server-shell[data-hydrated="true"]')).toBeVisible({ timeout: 60_000 })
  await expect(memberPage.locator('#channel-link-random')).toHaveCount(0)
  await expect(memberPage.locator('#channel-link-general')).toBeVisible()

  // Undo both changes, so a later spec on the same database sees the seeded channel.
  await page.locator(`#toggle-overwrite-${everyoneKey}`).click()
  page.once('dialog', (dialog) => dialog.accept())
  await page.locator(`#delete-overwrite-${everyoneKey}`).click()
  await expect(page.locator('#flash-group')).toContainText('Override removed.')
  await page.goto('/settings?tab=roles')
  await connected(page)
  page.once('dialog', (dialog) => dialog.accept())
  await page.locator(`#delete-role-${roleId}`).click()
  await expect(page.locator(`#role-row-${roleId}`)).toHaveCount(0)
  await expect(memberPage.locator('#channel-link-random')).toBeVisible()

  await memberContext.close()
})
