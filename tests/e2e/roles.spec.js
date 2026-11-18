const { test, expect } = require('@playwright/test')

const baseURL = 'http://127.0.0.1:4001'

async function command(request, name, payload = {}) {
  const response = await request.post(new URL('/api/testing/command', baseURL).toString(), {
    data: { command: name, ...payload },
  })
  expect(response.ok()).toBeTruthy()
  return (await response.json()).data
}

async function login(page) {
  const url = new URL('/api/testing/command', baseURL)
  url.searchParams.set('command', 'login')
  url.searchParams.set('payload', JSON.stringify({ email: 'e2e@example.com', username: 'e2e_user', password: 'supersecurepass', next: '/' }))
  await page.goto(url.toString())
  await expect(page.locator('#server-shell[data-hydrated="true"]')).toBeVisible()
}

// Role ids are server-generated, so a row is found by its name and its id read from the DOM.
async function roleId(page, name) {
  const row = page.locator('#role-list > li', { hasText: name })
  await expect(row).toHaveCount(1)
  return (await row.getAttribute('id')).replace('role-row-', '')
}

async function createRole(page, name) {
  await page.getByLabel('New role name').fill(name)
  await page.locator('#create-role-button').click()
  return roleId(page, name)
}

test('an owner creates, edits, moves, gives and deletes a role', async ({ page, request }, testInfo) => {
  const { user: member } = await command(request, 'upsert_user', {
    email: 'e2e-roles-member@example.com',
    username: 'e2e_roles_member',
    password: 'supersecurepass',
  })

  await login(page)
  await page.goto('/settings?tab=roles')
  // Act only once the socket has connected: the live mount resets a form filled before it. The
  // connected mount reads the shared remote test database, which can take several seconds.
  await expect(page.locator('[data-phx-main]')).toHaveClass(/phx-connected/, { timeout: 60_000 })
  await expect(page.locator('#settings-view-roles')).toBeVisible()

  const alpha = await createRole(page, 'E2E Alpha')
  const beta = await createRole(page, 'E2E Beta')

  // A new role lands just above the default role, so Beta starts below Alpha.
  const rowIds = () => page.locator('#role-list > li').evaluateAll((rows) => rows.map((row) => row.id))
  expect((await rowIds()).indexOf(`role-row-${beta}`)).toBeGreaterThan((await rowIds()).indexOf(`role-row-${alpha}`))

  await page.locator(`#edit-role-${beta}`).click()
  await page.locator('#role-permission-kick_members').check()
  await page.locator('#save-role-button').click()
  await expect(page.locator('#flash-group')).toContainText("Role E2E Beta saved.")
  await page.locator(`#edit-role-${beta}`).click()
  await expect(page.locator('#role-permission-kick_members')).toBeChecked()
  await page.locator('#cancel-role-edit').click()

  await page.locator(`#move-role-up-${beta}`).click()
  await expect
    .poll(async () => {
      const ids = await rowIds()
      return ids.indexOf(`role-row-${beta}`) < ids.indexOf(`role-row-${alpha}`)
    })
    .toBe(true)
  await page.screenshot({ path: testInfo.outputPath('roles-tab.png') })

  await page.locator('#settings-tab-server').click()
  await page.locator(`#open-member-roles-${member.id}`).click()
  await page.locator(`#member-role-select-${member.id}`).selectOption(beta)
  await page.locator(`#add-member-role-${member.id}`).click()
  await expect(page.locator(`#member-role-${member.id}-${beta}`)).toBeVisible()
  await page.screenshot({ path: testInfo.outputPath('member-roles.png') })

  await page.locator('#settings-tab-roles').click()
  page.once('dialog', (dialog) => dialog.accept())
  await page.locator(`#delete-role-${beta}`).click()
  await expect(page.locator(`#role-row-${beta}`)).toHaveCount(0)
  await expect(page.locator(`#role-row-${alpha}`)).toBeVisible()
})
