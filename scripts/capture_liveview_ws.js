const fs = require("fs")

const CDP_HTTP = "http://127.0.0.1:9222"
const BASE_URL = "http://127.0.0.1:4000"
const OUTPUT = "/tmp/liveview-ws-capture.json"

async function createTarget() {
  const res = await fetch(`${CDP_HTTP}/json/new?${encodeURIComponent("about:blank")}`, {
    method: "PUT",
  })
  return res.json()
}

async function main() {
  const target = await createTarget()
  const ws = new WebSocket(target.webSocketDebuggerUrl)

  let id = 0
  const pending = new Map()
  const frames = []
  let liveSocketRequestId = null

  function send(method, params = {}) {
    const msgId = ++id
    ws.send(JSON.stringify({ id: msgId, method, params }))
    return new Promise((resolve, reject) => {
      pending.set(msgId, { resolve, reject, method })
    })
  }

  ws.onmessage = (event) => {
    const msg = JSON.parse(event.data)

    if (msg.id && pending.has(msg.id)) {
      const { resolve, reject } = pending.get(msg.id)
      pending.delete(msg.id)
      if (msg.error) reject(msg.error)
      else resolve(msg.result)
      return
    }

    if (msg.method === "Network.webSocketCreated") {
      if (msg.params.url.includes("/live/websocket")) {
        liveSocketRequestId = msg.params.requestId
      }
    }

    if (
      liveSocketRequestId &&
      (msg.method === "Network.webSocketFrameSent" || msg.method === "Network.webSocketFrameReceived") &&
      msg.params.requestId === liveSocketRequestId
    ) {
      frames.push({
        direction: msg.method.endsWith("Sent") ? "sent" : "received",
        opcode: msg.params.response.opcode,
        payload: msg.params.response.payloadData,
      })
    }
  }

  await new Promise((resolve) => {
    ws.onopen = resolve
  })

  await send("Page.enable")
  await send("DOM.enable")
  await send("Runtime.enable")
  await send("Network.enable")

  await send("Page.navigate", { url: `${BASE_URL}/login` })
  await new Promise((resolve) => setTimeout(resolve, 1200))

  await send("Runtime.evaluate", {
    expression: `
      (() => {
        const email = document.querySelector('input[name="user[email]"]')
        const password = document.querySelector('input[name="user[password]"]')
        if (email) email.value = 'test_k6_1@example.com'
        if (password) password.value = 'LoadTest12345!'
        if (email) email.dispatchEvent(new Event('input', { bubbles: true }))
        if (password) password.dispatchEvent(new Event('input', { bubbles: true }))
        document.querySelector('form')?.requestSubmit()
      })()
    `,
  })

  await new Promise((resolve) => setTimeout(resolve, 1800))

  await send("Page.navigate", { url: `${BASE_URL}/?channel=general` })
  await new Promise((resolve) => setTimeout(resolve, 2500))

  await send("Runtime.evaluate", {
    expression: `
      (() => {
        const body = document.querySelector('#message-form textarea[data-rich-composer-body]')
        const metadata = document.querySelector('#message-form textarea[data-rich-composer-metadata]')
        if (body) {
          body.value = 'captured-from-browser'
          body.dispatchEvent(new Event('input', { bubbles: true }))
        }
        if (metadata) {
          metadata.value = '{}'
          metadata.dispatchEvent(new Event('input', { bubbles: true }))
        }
        document.querySelector('#message-form')?.requestSubmit()
      })()
    `,
  })

  await new Promise((resolve) => setTimeout(resolve, 3000))

  fs.writeFileSync(OUTPUT, JSON.stringify(frames, null, 2))
  console.log(`captured ${frames.length} websocket frames to ${OUTPUT}`)
  ws.close()
}

main().catch((error) => {
  console.error(error)
  process.exit(1)
})
