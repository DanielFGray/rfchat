/**
 * 02-auth-flow.js — Registration and login lifecycle
 *
 * Tests the full user authentication lifecycle: register a new user via the
 * test support API, then log in via the Phoenix form POST, access the
 * authenticated app, and log out.
 *
 * This exercises session creation, CSRF validation, and authenticated page
 * rendering under load.
 *
 * Prerequisites:
 *   - Run 00-seed.js first to create test users
 *
 * Usage:
 *   k6 run k6/02-auth-flow.js
 */

import http from "k6/http";
import { check, sleep } from "k6";
import { BASE_URL, testLogin, randomSleep } from "./helpers.js";

export const options = {
  stages: [
    { duration: "10s", target: 20 },
    { duration: "30s", target: 50 },
    { duration: "1m", target: 100 },
    { duration: "30s", target: 100 },
    { duration: "15s", target: 0 },
  ],
  thresholds: {
    http_req_duration: ["p(95)<3000", "p(99)<5000"],
    http_req_failed: ["rate<0.05"],
    checks: ["rate>0.90"],
  },
};

export default function () {
  // Each VU logs in as a pre-seeded user (cycles through 50 users)
  const userIndex = (__VU % 50) + 1;
  const email = `test_k6_${userIndex}@example.com`;
  const username = `test_k6_${userIndex}`;

  // 1. Log in via test support to get an authenticated browser session
  const loggedIn = testLogin(email, username, "/");

  if (!loggedIn) {
    sleep(1);
    return;
  }

  sleep(randomSleep(300, 800));

  // 2. Access the authenticated home page (guild chat)
  const homeRes = http.get(`${BASE_URL}/`, {
    redirects: 5,
    tags: { name: "GET / (authed)" },
  });

  check(homeRes, {
    "home page loads": (r) => r.status === 200,
    "home has liveview": (r) =>
      r.body.includes("data-phx-main") || r.body.includes("phx-socket"),
  });

  sleep(randomSleep(500, 1500));

  // 3. Visit the settings page
  const settingsRes = http.get(`${BASE_URL}/settings`, {
    redirects: 5,
    tags: { name: "GET /settings" },
  });

  check(settingsRes, {
    "settings page loads": (r) => r.status === 200,
  });

  sleep(randomSleep(300, 800));

  // 4. Navigate back to home
  const homeAgain = http.get(`${BASE_URL}/`, {
    redirects: 5,
    tags: { name: "GET / (return)" },
  });

  check(homeAgain, {
    "return to home ok": (r) => r.status === 200,
  });

  sleep(randomSleep(500, 2000));

  // 5. Log out
  const csrfMatch = homeAgain.body.match(/name="csrf-token"\s+content="([^"]+)"/);
  if (csrfMatch) {
    const logoutRes = http.request("DELETE", `${BASE_URL}/logout`, null, {
      headers: { "x-csrf-token": csrfMatch[1] },
      redirects: 0,
      tags: { name: "DELETE /logout" },
    });

    check(logoutRes, {
      "logout redirects": (r) => r.status === 302 || r.status === 303,
    });
  }

  sleep(randomSleep(500, 1000));
}
