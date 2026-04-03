import http from "k6/http";
import { check } from "k6";

export const BASE_URL = __ENV.BASE_URL || "http://localhost:4000";
export const TEST_PASSWORD = __ENV.TEST_PASSWORD || "LoadTest12345!";

// ---------------------------------------------------------------------------
// Test support API (dev/test only, requires ENABLE_TEST_SUPPORT_COMMANDS=1)
// ---------------------------------------------------------------------------

export function testCommand(command, payload = {}) {
  const res = http.post(
    `${BASE_URL}/api/testing/command?command=${command}`,
    JSON.stringify(payload),
    {
      headers: { "Content-Type": "application/json" },
      tags: { name: `TEST ${command}` },
    },
  );

  check(res, { [`${command} ok`]: (r) => r.status === 200 });

  if (res.status !== 200) {
    console.error(`testCommand(${command}) failed: ${res.status} ${res.body}`);
    return null;
  }

  return JSON.parse(res.body).data;
}

export function testLogin(email, username = null, next = "/", options = {}) {
  const derivedUsername =
    username || email.split("@")[0].replace(/[^a-z0-9_]/g, "_");

  const reqOptions = {
    redirects: 0,
    tags: { name: "TEST login" },
  };
  if (options.jar) reqOptions.jar = options.jar;

  const res = http.get(
    `${BASE_URL}/api/testing/command?command=login&payload=${encodeURIComponent(
      JSON.stringify({
        email,
        username: derivedUsername,
        display_name: derivedUsername,
        password: TEST_PASSWORD,
        next,
      }),
    )}`,
    reqOptions,
  );

  const success = check(res, {
    "test login redirects": (r) => r.status === 302,
  });

  if (!success) {
    console.error(`testLogin failed for ${email}: ${res.status} ${res.body}`);
    return null;
  }

  return true;
}

// ---------------------------------------------------------------------------
// Phoenix form-based auth helpers
// ---------------------------------------------------------------------------

// GET a Phoenix page and extract the CSRF token from the response HTML.
function extractCsrfToken(html) {
  // Phoenix puts the CSRF token in a <meta> tag and/or hidden <input>.
  const metaMatch = html.match(
    /name="csrf-token"\s+content="([^"]+)"/,
  );
  if (metaMatch) return metaMatch[1];

  // Fallback: hidden input in forms
  const inputMatch = html.match(
    /name="_csrf_token"\s+value="([^"]+)"/,
  );
  if (inputMatch) return inputMatch[1];

  // Also try the reverse attribute order
  const inputMatchAlt = html.match(
    /value="([^"]+)"\s+name="_csrf_token"/,
  );
  if (inputMatchAlt) return inputMatchAlt[1];

  return null;
}

// Log in via the standard Phoenix form POST and return the session cookie jar.
// This is the same flow a browser would take: GET /login -> POST /login.
export function loginUser(email, password) {
  // 1. GET the login page to establish session + CSRF token
  const loginPage = http.get(`${BASE_URL}/login`, {
    redirects: 0,
    tags: { name: "GET /login" },
  });

  if (loginPage.status >= 300 && loginPage.status < 400) {
    return true;
  }

  const csrfToken = extractCsrfToken(loginPage.body);
  if (!csrfToken) {
    console.error("Could not extract CSRF token from login page");
    return null;
  }

  // 2. POST the login form (Phoenix expects form-encoded data under user[...])
  const loginRes = http.post(
    `${BASE_URL}/login`,
    {
      "user[email]": email,
      "user[password]": password || TEST_PASSWORD,
      "user[remember_me]": "false",
      _csrf_token: csrfToken,
    },
    {
      redirects: 0,
      tags: { name: "POST /login" },
    },
  );

  const success = check(loginRes, {
    "login redirects": (r) => r.status === 302,
  });

  if (!success) {
    console.error(`Login failed for ${email}: ${loginRes.status}`);
    return null;
  }

  return true;
}

// Get the CSRF token for an authenticated page (useful after login)
export function getCsrfToken(path = "/") {
  const res = http.get(`${BASE_URL}${path}`, {
    tags: { name: `GET ${path}` },
  });

  return extractCsrfToken(res.body);
}

// ---------------------------------------------------------------------------
// Bot API helpers
// ---------------------------------------------------------------------------

export function botHeaders(token) {
  return {
    "Content-Type": "application/json",
    Authorization: `Bearer ${token}`,
  };
}

export function botListMessages(token, channelId, limit = 50) {
  const headers = botHeaders(token);
  const res = http.get(
    `${BASE_URL}/api/v1/channels/${channelId}/messages?limit=${limit}`,
    { headers, tags: { name: "GET /api/v1/channels/:id/messages" } },
  );

  check(res, { "bot list messages ok": (r) => r.status === 200 });
  return res;
}

export function botSendMessage(token, channelId, body) {
  const headers = botHeaders(token);
  const res = http.post(
    `${BASE_URL}/api/v1/channels/${channelId}/messages`,
    JSON.stringify({ message: { body } }),
    { headers, tags: { name: "POST /api/v1/channels/:id/messages" } },
  );

  check(res, { "bot send message ok": (r) => r.status === 201 });
  return res;
}

export function botGetThread(token, messageId) {
  const headers = botHeaders(token);
  const res = http.get(
    `${BASE_URL}/api/v1/messages/${messageId}/thread`,
    { headers, tags: { name: "GET /api/v1/messages/:id/thread" } },
  );

  return res;
}

export function botCreateThread(token, messageId, attrs = {}) {
  const headers = botHeaders(token);
  const res = http.post(
    `${BASE_URL}/api/v1/messages/${messageId}/threads`,
    JSON.stringify({ thread: attrs }),
    { headers, tags: { name: "POST /api/v1/messages/:id/threads" } },
  );

  check(res, { "bot create thread ok": (r) => r.status === 201 });
  return res;
}

// ---------------------------------------------------------------------------
// Message content generators
// ---------------------------------------------------------------------------

const TOPICS = [
  "Just deployed the latest build",
  "Has anyone seen the new Elixir release?",
  "Working on the authentication module",
  "The database migration went smoothly",
  "Quick sync about the sprint goals",
  "Found an interesting edge case",
  "Performance numbers look good today",
  "Updated the dependencies last night",
  "The CI pipeline is green again",
  "We should discuss the API design",
  "Refactored the channel permissions",
  "New feature request from the team",
  "Testing the WebSocket connections",
  "Monitoring dashboard looks healthy",
  "Fixed the race condition in messages",
];

export function randomMessage() {
  const base = TOPICS[Math.floor(Math.random() * TOPICS.length)];
  return `${base} (k6-${Date.now()}-${__VU}-${__ITER})`;
}

// ---------------------------------------------------------------------------
// Utility
// ---------------------------------------------------------------------------

export function randomSleep(minMs, maxMs) {
  const ms = Math.floor(Math.random() * (maxMs - minMs) + minMs);
  return ms / 1000; // k6 sleep() takes seconds
}

export function pickRandom(arr) {
  return arr[Math.floor(Math.random() * arr.length)];
}
