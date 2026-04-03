/**
 * 05-spike.js — Spike / burst traffic simulation
 *
 * Simulates a viral moment or raid scenario: traffic goes from idle to
 * extreme in seconds, combining anonymous browsing, login attempts, and
 * bot API messaging all at once.
 *
 * This reveals:
 *   - Connection pool exhaustion under sudden load
 *   - Graceful degradation behavior
 *   - Recovery time after spike subsides
 *   - Rate limiter effectiveness
 *
 * Prerequisites:
 *   - Run 00-seed.js first
 *   - Set K6_BOT_TOKEN and K6_CHANNEL_IDS
 *
 * Usage:
 *   K6_BOT_TOKEN="..." K6_CHANNEL_IDS="..." k6 run k6/05-spike.js
 */

import http from "k6/http";
import { check, sleep } from "k6";
import {
  BASE_URL,
  testLogin,
  botSendMessage,
  botListMessages,
  randomMessage,
  pickRandom,
  randomSleep,
} from "./helpers.js";

const BOT_TOKEN = __ENV.K6_BOT_TOKEN;
const CHANNEL_IDS = (__ENV.K6_CHANNEL_IDS || "").split(",").filter(Boolean);

export const options = {
  scenarios: {
    spike: {
      executor: "ramping-vus",
      startVUs: 0,
      stages: [
        // Calm before the storm
        { duration: "10s", target: 10 },
        // SPIKE: instant ramp to 500 VUs
        { duration: "5s", target: 500 },
        // Hold at peak
        { duration: "1m", target: 500 },
        // Rapid cooldown
        { duration: "10s", target: 50 },
        // Recovery period
        { duration: "30s", target: 50 },
        // Wind down
        { duration: "10s", target: 0 },
      ],
    },
  },
  thresholds: {
    http_req_duration: ["p(95)<5000"],
    http_req_failed: ["rate<0.15"],
    checks: ["rate>0.80"],
  },
};

export default function () {
  const action = Math.random();

  if (action < 0.5) {
    // 50%: Anonymous browsing (cheapest operation)
    browseAnonymous();
  } else if (action < 0.75) {
    // 25%: Login attempts
    loginAttempt();
  } else if (action < 0.90) {
    // 15%: Bot API read (message listing)
    botRead();
  } else {
    // 10%: Bot API write (message creation)
    botWrite();
  }

  sleep(randomSleep(100, 800));
}

function browseAnonymous() {
  const pages = ["/login", "/register"];
  const page = pickRandom(pages);

  const res = http.get(`${BASE_URL}${page}`, {
    tags: { name: `GET ${page} (spike)` },
  });

  check(res, {
    "page loads during spike": (r) => r.status === 200,
  });
}

function loginAttempt() {
  const userIndex = Math.floor(Math.random() * 50) + 1;
  const email = `test_k6_${userIndex}@example.com`;
  testLogin(email, `test_k6_${userIndex}`, "/");
}

function botRead() {
  if (!BOT_TOKEN || CHANNEL_IDS.length === 0) return;

  const channelId = pickRandom(CHANNEL_IDS);
  botListMessages(BOT_TOKEN, channelId, 20);
}

function botWrite() {
  if (!BOT_TOKEN || CHANNEL_IDS.length === 0) return;

  const channelId = pickRandom(CHANNEL_IDS);
  botSendMessage(BOT_TOKEN, channelId, randomMessage());
}
