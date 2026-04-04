/**
 * 07-message-flood.js — Authenticated message posting flood test
 *
 * Simulates hundreds of users simultaneously posting messages via the
 * session-auth'd HTTP endpoint POST /api/v1/user/channels/:id/messages.
 * This stresses the full DB write path: session lookup, permission check,
 * message insert, PubSub broadcast.
 *
 * Prerequisites:
 *   - Run 00-seed.js with SEED_USERS=300 first
 *   - Phoenix server running with ENABLE_TEST_SUPPORT_COMMANDS=1
 *   - mix run priv/repo/seeds.exs (ensures @everyone role + channels exist)
 *
 * Usage:
 *   SEED_USERS=300 k6 run k6/00-seed.js          # seed once
 *   K6_CHANNEL_IDS=id1,id2,id3 k6 run k6/07-message-flood.js
 *
 * Key env vars:
 *   BASE_URL        — default http://localhost:4000
 *   K6_CHANNEL_IDS  — comma-separated channel UUIDs (from 00-seed.js output)
 *   FLOOD_VUS       — peak concurrent users (default 200)
 *   FLOOD_USERS     — seeded user pool size to draw from (default 300)
 */

import http from "k6/http";
import { check, sleep } from "k6";
import {
  BASE_URL,
  testLogin,
  getCsrfToken,
  userSendMessage,
  randomMessage,
  randomSleep,
  pickRandom,
} from "./helpers.js";

const FLOOD_VUS = Number(__ENV.FLOOD_VUS || 200);
const FLOOD_USERS = Number(__ENV.FLOOD_USERS || 300);

// Parse channel IDs from env — fall back to a placeholder so the script
// at least loads. k6 will error at runtime if the IDs are invalid.
const CHANNEL_IDS = (__ENV.K6_CHANNEL_IDS || "").split(",").filter(Boolean);

// One persistent cookie jar per VU — survives across iterations.
const jar = new http.CookieJar();

// Per-VU CSRF token cache — fetched once after login, refreshed every
// 50 iterations to handle server-side token rotation.
let cachedCsrfToken = null;

export const options = {
  scenarios: {
    message_flood: {
      executor: "ramping-vus",
      startVUs: 0,
      stages: [
        { duration: "20s", target: Math.floor(FLOOD_VUS * 0.25) }, // warm up to 25%
        { duration: "30s", target: Math.floor(FLOOD_VUS * 0.75) }, // ramp to 75%
        { duration: "30s", target: FLOOD_VUS },                    // full flood
        { duration: "1m", target: FLOOD_VUS },                     // sustain
        { duration: "20s", target: 0 },                            // ramp down
      ],
    },
  },
  thresholds: {
    // p95 under 3s is acceptable for a write-heavy endpoint with pool pressure
    "http_req_duration{name:POST /api/v1/user/channels/:id/messages}": [
      "p(95)<3000",
      "p(99)<8000",
    ],
    // Allow a small error rate — we expect some 403s if @everyone role is
    // missing or 429s if rate limiting is active
    "http_req_failed{name:POST /api/v1/user/channels/:id/messages}": [
      "rate<0.05",
    ],
    checks: ["rate>0.90"],
  },
};

export function setup() {
  if (CHANNEL_IDS.length === 0) {
    console.error(
      "No channel IDs provided. Set K6_CHANNEL_IDS=id1,id2,... from 00-seed.js output.",
    );
  }
  console.log(
    `Message flood: ${FLOOD_VUS} VUs, ${FLOOD_USERS} user pool, ${CHANNEL_IDS.length} channels`,
  );
  return { channelIds: CHANNEL_IDS };
}

export default function (data) {
  const channelIds = data.channelIds;
  if (channelIds.length === 0) return;

  // Each VU gets a dedicated user slot, wrapping around the pool
  const userIndex = (__VU % FLOOD_USERS) + 1;
  const email = `test_k6_${userIndex}@example.com`;
  const username = `test_k6_${userIndex}`;

  // Login on first iteration (or every 100 to refresh expired sessions)
  const needsLogin = __ITER === 0 || __ITER % 100 === 0;

  if (needsLogin) {
    const ok = testLogin(email, username, "/", { jar });
    if (!ok) {
      console.error(`VU ${__VU}: login failed for ${email}`);
      sleep(1);
      return;
    }

    // Fetch CSRF token from the authenticated home page
    cachedCsrfToken = getCsrfToken("/", { jar });
    if (!cachedCsrfToken) {
      console.error(`VU ${__VU}: could not extract CSRF token after login`);
      sleep(1);
      return;
    }

    sleep(0.1);
  }

  // Rotate CSRF token cache every 50 iterations (token TTL is generous in
  // Phoenix but we stay safe)
  if (__ITER > 0 && __ITER % 50 === 0 && !needsLogin) {
    const fresh = getCsrfToken("/", { jar });
    if (fresh) cachedCsrfToken = fresh;
  }

  // Post a message to a random channel
  const channelId = pickRandom(channelIds);
  const body = randomMessage();

  const res = userSendMessage(jar, cachedCsrfToken, channelId, body);

  if (res.status === 403) {
    console.warn(
      `VU ${__VU} iter ${__ITER}: 403 forbidden — user ${email} may lack @everyone role. ` +
        "Ensure mix run priv/repo/seeds.exs has been run.",
    );
  } else if (res.status === 302) {
    // Redirected to login — session expired or cookie jar corrupted
    console.warn(
      `VU ${__VU} iter ${__ITER}: session expired, will re-login next iteration`,
    );
    cachedCsrfToken = null;
  } else if (res.status !== 201) {
    console.error(
      `VU ${__VU} iter ${__ITER}: unexpected ${res.status}: ${res.body.substring(0, 200)}`,
    );
  }

  // Realistic think time: 0.5–2s between posts
  sleep(randomSleep(500, 2000));
}
