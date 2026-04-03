/**
 * 04-session-stress.js — Session validation stress test
 *
 * Pre-logs-in a pool of users, then hammers authenticated page loads to
 * stress the session validation path: token lookup, user preloading,
 * session touch updates, and LiveView initial mount rendering.
 *
 * This finds issues with:
 *   - Database connection pool exhaustion on session queries
 *   - Session touch (last_seen_at) write contention
 *   - Memory pressure from concurrent LiveView mounts
 *
 * Prerequisites:
 *   - Run 00-seed.js first
 *
 * Usage:
 *   k6 run k6/04-session-stress.js
 */

import http from "k6/http";
import { check, sleep } from "k6";
import { BASE_URL, testLogin, randomSleep } from "./helpers.js";

const USER_POOL_SIZE = 50;

// One persistent cookie jar per VU — module-scope means it lives for the
// entire VU lifetime and is NOT cleared between iterations (unlike the
// default per-iteration jar that k6 resets on each iteration start).
const jar = new http.CookieJar();

export const options = {
  scenarios: {
    session_hammer: {
      executor: "ramping-vus",
      startVUs: 0,
      stages: [
        { duration: "10s", target: 25 },
        { duration: "20s", target: 50 },
        { duration: "1m", target: 50 },
        { duration: "15s", target: 0 },
      ],
    },
  },
  thresholds: {
    http_req_duration: ["p(95)<2000", "p(99)<5000"],
    http_req_failed: ["rate<0.10"],
    checks: ["rate>0.90"],
  },
};

export function setup() {
  // Verify seed users exist — actual login happens per-VU in default()
  console.log(`Verifying ${USER_POOL_SIZE} seed users exist...`);

  const loggedIn = [];
  for (let i = 1; i <= USER_POOL_SIZE; i++) {
    const email = `test_k6_${i}@example.com`;
    const result = testLogin(email, `test_k6_${i}`, "/");
    if (result) {
      loggedIn.push(email);
    }
  }

  console.log(`  ${loggedIn.length}/${USER_POOL_SIZE} users verified`);
  return { loggedIn };
}

export default function (data) {
  // Each VU gets its own dedicated user — no sharing between VUs
  const userIndex = (__VU % USER_POOL_SIZE) + 1;
  const email = `test_k6_${userIndex}@example.com`;

  // Each VU logs in on its first iteration to populate its own cookie jar.
  // Re-login every 100 iterations to refresh sessions.
  if (__ITER === 0 || __ITER % 100 === 0) {
    testLogin(email, `test_k6_${userIndex}`, "/", { jar });
    sleep(0.2);
  }

  // Hammer authenticated endpoints.
  // Pass the persistent jar explicitly so sessions survive across iterations.
  // Use redirects:0 to prevent an unauthenticated redirect from overwriting
  // the auth cookie in the jar with a new blank session cookie.
  const action = Math.random();

  if (action < 0.5) {
    // 50%: Hit the main chat page (LiveView mount)
    const res = http.get(`${BASE_URL}/`, {
      redirects: 0,
      jar,
      tags: { name: "GET / (session)" },
    });

    check(res, {
      "authed home loads": (r) => r.status === 200,
      "not redirected to login": (r) => r.status !== 302,
    });
  } else if (action < 0.8) {
    // 30%: Hit the settings page
    const res = http.get(`${BASE_URL}/settings`, {
      redirects: 0,
      jar,
      tags: { name: "GET /settings (session)" },
    });

    check(res, {
      "settings loads": (r) => r.status === 200,
      "settings not redirected": (r) => r.status !== 302,
    });
  } else {
    // 20%: Navigate to a specific channel path
    const channels = ["general", "engineering", "random"];
    const channel = channels[Math.floor(Math.random() * channels.length)];

    const res = http.get(`${BASE_URL}/?channel=${channel}`, {
      redirects: 0,
      jar,
      tags: { name: "GET /?channel=:slug" },
    });

    check(res, {
      "channel page loads": (r) => r.status === 200,
    });
  }

  sleep(randomSleep(100, 500));
}
