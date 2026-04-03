/**
 * 03-messaging.js — Bot API messaging stress test
 *
 * Hammers the bot API message endpoints: creating messages, listing messages,
 * and creating threads. This is the primary write-path stress test and
 * exercises the database, PubSub broadcasting, and JSON serialization.
 *
 * Prerequisites:
 *   - Run 00-seed.js first
 *   - Set K6_BOT_TOKEN and K6_CHANNEL_IDS environment variables
 *
 * Usage:
 *   K6_BOT_TOKEN="..." K6_CHANNEL_IDS="id1,id2,id3" k6 run k6/03-messaging.js
 */

import { check, sleep } from "k6";
import {
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

if (!BOT_TOKEN) {
  console.error("K6_BOT_TOKEN is required. Run 00-seed.js first.");
}

if (CHANNEL_IDS.length === 0) {
  console.error("K6_CHANNEL_IDS is required. Run 00-seed.js first.");
}

export const options = {
  scenarios: {
    // Constant message creation rate
    message_writers: {
      executor: "ramping-vus",
      startVUs: 0,
      stages: [
        { duration: "10s", target: 10 },
        { duration: "30s", target: 30 },
        { duration: "1m", target: 50 },
        { duration: "30s", target: 50 },
        { duration: "15s", target: 0 },
      ],
      exec: "writeMessages",
    },
    // Concurrent message readers
    message_readers: {
      executor: "ramping-vus",
      startVUs: 0,
      stages: [
        { duration: "10s", target: 20 },
        { duration: "30s", target: 60 },
        { duration: "1m", target: 100 },
        { duration: "30s", target: 100 },
        { duration: "15s", target: 0 },
      ],
      exec: "readMessages",
    },
    // Thread creation and reading
    thread_workers: {
      executor: "ramping-vus",
      startVUs: 0,
      stages: [
        { duration: "15s", target: 5 },
        { duration: "30s", target: 10 },
        { duration: "1m", target: 15 },
        { duration: "30s", target: 15 },
        { duration: "15s", target: 0 },
      ],
      exec: "threadOperations",
    },
  },
  thresholds: {
    "http_req_duration{name:POST /api/v1/channels/:id/messages}": [
      "p(95)<2000",
      "p(99)<4000",
    ],
    "http_req_duration{name:GET /api/v1/channels/:id/messages}": [
      "p(95)<1500",
      "p(99)<3000",
    ],
    http_req_failed: ["rate<0.05"],
    checks: ["rate>0.90"],
  },
};

// Scenario: write messages to random channels
export function writeMessages() {
  if (!BOT_TOKEN || CHANNEL_IDS.length === 0) return;

  const channelId = pickRandom(CHANNEL_IDS);
  const body = randomMessage();

  botSendMessage(BOT_TOKEN, channelId, body);

  sleep(randomSleep(200, 1000));
}

// Scenario: read messages from random channels
export function readMessages() {
  if (!BOT_TOKEN || CHANNEL_IDS.length === 0) return;

  const channelId = pickRandom(CHANNEL_IDS);

  const res = botListMessages(BOT_TOKEN, channelId);

  if (res.status === 200) {
    const data = JSON.parse(res.body);
    check(data, {
      "messages array present": (d) => d.data && Array.isArray(d.data),
    });
  }

  sleep(randomSleep(300, 1200));
}

// Scenario: create threads from existing messages, then read them
export function threadOperations() {
  if (!BOT_TOKEN || CHANNEL_IDS.length === 0) return;

  const channelId = pickRandom(CHANNEL_IDS);

  // First, get the latest messages in the channel
  const listRes = botListMessages(BOT_TOKEN, channelId, 10);
  if (listRes.status !== 200) {
    sleep(1);
    return;
  }

  const messages = JSON.parse(listRes.body).data || [];
  if (messages.length === 0) {
    sleep(1);
    return;
  }

  // Pick a random message and try to create a thread or read its thread
  const message = pickRandom(messages);

  if (Math.random() < 0.3) {
    // 30% chance: create a new thread
    botCreateThread(BOT_TOKEN, message.id, {
      name: `Thread ${Date.now()}`,
    });
  } else {
    // 70% chance: try to read the thread
    botGetThread(BOT_TOKEN, message.id);
  }

  sleep(randomSleep(500, 2000));
}
