/**
 * 06-realistic.js — Comprehensive realistic load simulation
 *
 * Models a day-in-the-life of the chat server with four concurrent user
 * personas running in parallel, each with realistic think times and
 * proportional traffic weights:
 *
 *   - Lurkers (50%):  Browse login/register, occasionally log in
 *   - Chatters (25%): Authenticated users navigating channels
 *   - Active (15%):   Bot-driven message creation (write path)
 *   - Readers (10%):  Bot-driven message listing (read path)
 *
 * This is the "run it overnight" test for capacity planning.
 *
 * Prerequisites:
 *   - Run 00-seed.js first
 *   - Set K6_BOT_TOKEN and K6_CHANNEL_IDS
 *
 * Usage:
 *   K6_BOT_TOKEN="..." K6_CHANNEL_IDS="..." k6 run k6/06-realistic.js
 */

import http from "k6/http";
import { check, sleep } from "k6";
import {
  BASE_URL,
  testLogin,
  botSendMessage,
  botListMessages,
  botCreateThread,
  botGetThread,
  randomMessage,
  pickRandom,
  randomSleep,
} from "./helpers.js";

const BOT_TOKEN = __ENV.K6_BOT_TOKEN;
const CHANNEL_IDS = (__ENV.K6_CHANNEL_IDS || "").split(",").filter(Boolean);

export const options = {
  scenarios: {
    lurkers: {
      executor: "ramping-vus",
      startVUs: 0,
      stages: [
        { duration: "30s", target: 50 },
        { duration: "2m", target: 150 },
        { duration: "3m", target: 150 },
        { duration: "1m", target: 0 },
      ],
      exec: "lurkerBehavior",
    },
    chatters: {
      executor: "ramping-vus",
      startVUs: 0,
      stages: [
        { duration: "30s", target: 25 },
        { duration: "2m", target: 75 },
        { duration: "3m", target: 75 },
        { duration: "1m", target: 0 },
      ],
      exec: "chatterBehavior",
    },
    active_writers: {
      executor: "ramping-vus",
      startVUs: 0,
      stages: [
        { duration: "30s", target: 10 },
        { duration: "2m", target: 40 },
        { duration: "3m", target: 40 },
        { duration: "1m", target: 0 },
      ],
      exec: "activeBehavior",
    },
    readers: {
      executor: "ramping-vus",
      startVUs: 0,
      stages: [
        { duration: "30s", target: 10 },
        { duration: "2m", target: 30 },
        { duration: "3m", target: 30 },
        { duration: "1m", target: 0 },
      ],
      exec: "readerBehavior",
    },
  },
  thresholds: {
    http_req_duration: ["p(95)<3000", "p(99)<5000"],
    http_req_failed: ["rate<0.05"],
    checks: ["rate>0.90"],
    "http_req_duration{name:GET /login}": ["p(95)<1500"],
    "http_req_duration{name:POST /login}": ["p(95)<2000"],
    "http_req_duration{name:POST /api/v1/channels/:id/messages}": [
      "p(95)<2000",
    ],
    "http_req_duration{name:GET /api/v1/channels/:id/messages}": [
      "p(95)<1500",
    ],
  },
};

// ---------------------------------------------------------------------------
// Scenario: Lurkers — Anonymous and occasional login
// ---------------------------------------------------------------------------

export function lurkerBehavior() {
  const action = Math.random();

  if (action < 0.4) {
    // Browse login page
    const res = http.get(`${BASE_URL}/login`, {
      tags: { name: "GET /login" },
    });
    check(res, { "login page ok": (r) => r.status === 200 });
  } else if (action < 0.7) {
    // Browse register page
    const res = http.get(`${BASE_URL}/register`, {
      tags: { name: "GET /register" },
    });
    check(res, { "register page ok": (r) => r.status === 200 });
  } else if (action < 0.85) {
    // Try to access home (redirect to login)
    const res = http.get(`${BASE_URL}/`, {
      redirects: 5,
      tags: { name: "GET / (lurker)" },
    });
    check(res, { "root redirects ok": (r) => r.status === 200 });
  } else {
    // Actually log in (simulating a returning user)
    const userIndex = Math.floor(Math.random() * 50) + 1;
    testLogin(`test_k6_${userIndex}@example.com`, `test_k6_${userIndex}`, "/");
  }

  sleep(randomSleep(1000, 4000));
}

// ---------------------------------------------------------------------------
// Scenario: Chatters — Authenticated navigation
// ---------------------------------------------------------------------------

export function chatterBehavior() {
  const userIndex = (__VU % 50) + 1;
  const email = `test_k6_${userIndex}@example.com`;

  // Log in at the start of each iteration
  testLogin(email, `test_k6_${userIndex}`, "/");
  sleep(randomSleep(300, 800));

  const action = Math.random();

  if (action < 0.5) {
    // Navigate to the main chat page
    const res = http.get(`${BASE_URL}/`, {
      redirects: 5,
      tags: { name: "GET / (chatter)" },
    });
    check(res, {
      "chat page loads": (r) => r.status === 200,
      "has liveview": (r) =>
        r.body.includes("data-phx-main") || r.body.includes("phx-socket"),
    });
  } else if (action < 0.75) {
    // Navigate to a specific channel
    const channels = ["general", "engineering", "random"];
    const channel = pickRandom(channels);

    const res = http.get(`${BASE_URL}/?channel=${channel}`, {
      redirects: 5,
      tags: { name: "GET /?channel=:slug" },
    });
    check(res, { "channel view loads": (r) => r.status === 200 });
  } else {
    // Visit settings
    const res = http.get(`${BASE_URL}/settings`, {
      redirects: 5,
      tags: { name: "GET /settings" },
    });
    check(res, { "settings loads": (r) => r.status === 200 });
  }

  sleep(randomSleep(2000, 6000));
}

// ---------------------------------------------------------------------------
// Scenario: Active writers — Bot API message creation
// ---------------------------------------------------------------------------

export function activeBehavior() {
  if (!BOT_TOKEN || CHANNEL_IDS.length === 0) {
    sleep(1);
    return;
  }

  const channelId = pickRandom(CHANNEL_IDS);
  const action = Math.random();

  if (action < 0.7) {
    // 70%: Send a message
    botSendMessage(BOT_TOKEN, channelId, randomMessage());
  } else if (action < 0.85) {
    // 15%: Send a message, then create a thread on it
    const sendRes = botSendMessage(BOT_TOKEN, channelId, randomMessage());

    if (sendRes.status === 201) {
      sleep(randomSleep(200, 500));
      const msg = JSON.parse(sendRes.body).data;
      botCreateThread(BOT_TOKEN, msg.id, {
        name: `Discussion ${Date.now()}`,
      });
    }
  } else {
    // 15%: Read then reply pattern (list messages, then send)
    const listRes = botListMessages(BOT_TOKEN, channelId, 5);

    if (listRes.status === 200) {
      sleep(randomSleep(300, 800));
      botSendMessage(BOT_TOKEN, channelId, randomMessage());
    }
  }

  sleep(randomSleep(1000, 3000));
}

// ---------------------------------------------------------------------------
// Scenario: Readers — Bot API message listing
// ---------------------------------------------------------------------------

export function readerBehavior() {
  if (!BOT_TOKEN || CHANNEL_IDS.length === 0) {
    sleep(1);
    return;
  }

  const action = Math.random();

  if (action < 0.6) {
    // 60%: List messages in a random channel
    const channelId = pickRandom(CHANNEL_IDS);
    botListMessages(BOT_TOKEN, channelId);
  } else if (action < 0.8) {
    // 20%: List messages across all channels (scanning behavior)
    for (const channelId of CHANNEL_IDS) {
      botListMessages(BOT_TOKEN, channelId, 10);
      sleep(randomSleep(100, 300));
    }
  } else {
    // 20%: Read message then check for thread
    const channelId = pickRandom(CHANNEL_IDS);
    const listRes = botListMessages(BOT_TOKEN, channelId, 5);

    if (listRes.status === 200) {
      const messages = JSON.parse(listRes.body).data || [];
      if (messages.length > 0) {
        const msg = pickRandom(messages);
        botGetThread(BOT_TOKEN, msg.id);
      }
    }
  }

  sleep(randomSleep(1000, 4000));
}
