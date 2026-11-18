/**
 * 09-liveview-message-flood.js — Real workload message flood test
 *
 * Each VU follows a browser-like path once per session:
 *   1. Login with a real session cookie
 *   2. Load GET /?channel=:slug and extract LiveView root/session/static + CSRF
 *   3. Connect to /live/websocket and join the LiveView topic once
 *   4. Keep that socket open and send multiple real "send_message" form events
 *
 * This is closer to real chat usage than reconnecting for every message.
 */

import http from "k6/http";
import ws from "k6/ws";
import { check, sleep } from "k6";
import { BASE_URL, loginUser, testLogin, randomMessage, randomSleep } from "./helpers.js";

const FLOOD_VUS = Number(__ENV.FLOOD_VUS || 100);
const FLOOD_USERS = Number(__ENV.FLOOD_USERS || 300);
const MESSAGES_PER_SESSION = Number(__ENV.MESSAGES_PER_SESSION || 5);
const SESSION_TIMEOUT_MS = Number(__ENV.SESSION_TIMEOUT_MS || 30000);
const LOGIN_MODE = (__ENV.LOGIN_MODE || "test_support").trim();
const STAGE_RAMP_1 = __ENV.STAGE_RAMP_1 || "20s";
const STAGE_RAMP_2 = __ENV.STAGE_RAMP_2 || "30s";
const STAGE_RAMP_3 = __ENV.STAGE_RAMP_3 || "30s";
const STAGE_HOLD = __ENV.STAGE_HOLD || "1m";
const STAGE_RAMP_DOWN = __ENV.STAGE_RAMP_DOWN || "20s";
const THINK_TIME_MIN_MS = Number(__ENV.THINK_TIME_MIN_MS || 500);
const THINK_TIME_MAX_MS = Number(__ENV.THINK_TIME_MAX_MS || 2000);
const MESSAGE_THINK_MIN_MS = Number(__ENV.MESSAGE_THINK_MIN_MS || 300);
const MESSAGE_THINK_MAX_MS = Number(__ENV.MESSAGE_THINK_MAX_MS || 1200);
const CHANNEL_SLUGS = (__ENV.K6_CHANNEL_SLUGS || "general,engineering,random")
  .split(",")
  .map((s) => s.trim())
  .filter(Boolean);

const jar = new http.CookieJar();
const authenticatedUsers = new Set();

export function setup() {
  if (LOGIN_MODE !== "phoenix") {
    return { sessions: {} };
  }

  const sessions = {};
  const neededUsers = Math.min(FLOOD_USERS, FLOOD_VUS);

  for (let userIndex = 1; userIndex <= neededUsers; userIndex += 1) {
    const email = `test_k6_${userIndex}@example.com`;
    const setupJar = new http.CookieJar();
    const cookies = loginUser(email, null, { jar: setupJar, returnCookies: true });

    if (!cookies || !cookies._tavern_key) {
      throw new Error(`setup login failed for ${email}`);
    }

    sessions[email] = cookies;
  }

  return { sessions };
}

export const options = {
  setupTimeout: __ENV.SETUP_TIMEOUT || "5m",
  scenarios: {
    liveview_message_flood: {
      executor: "ramping-vus",
      startVUs: 0,
      stages: [
        { duration: STAGE_RAMP_1, target: Math.floor(FLOOD_VUS * 0.25) },
        { duration: STAGE_RAMP_2, target: Math.floor(FLOOD_VUS * 0.75) },
        { duration: STAGE_RAMP_3, target: FLOOD_VUS },
        { duration: STAGE_HOLD, target: FLOOD_VUS },
        { duration: STAGE_RAMP_DOWN, target: 0 },
      ],
    },
  },
  thresholds: {
    checks: ["rate>0.85"],
  },
};

function extractRoot(html) {
  const idMatch = html.match(/<div id="([^"]+)" data-phx-main/);
  const sessionMatch = html.match(/data-phx-session="([^"]+)"/);
  const staticMatch = html.match(/data-phx-static="([^"]+)"/);
  const csrfMatch = html.match(/name="csrf-token" content="([^"]+)"/);

  return {
    rootId: idMatch && idMatch[1],
    session: sessionMatch && sessionMatch[1],
    staticToken: staticMatch && staticMatch[1],
    csrfToken: csrfMatch && csrfMatch[1],
  };
}

function trackStatic() {
  return [`${BASE_URL}/assets/css/app.css`, `${BASE_URL}/assets/js/app.js`];
}

function cookieHeader(baseUrl) {
  const cookies = jar.cookiesForURL(baseUrl);
  const pairs = [];

  for (const [name, values] of Object.entries(cookies)) {
    if (!values || values.length === 0) continue;
    pairs.push(`${name}=${values[0]}`);
  }

  return pairs.join("; ");
}

function joinUrl(csrfToken) {
  const match = BASE_URL.match(/^(https?):\/\/([^/]+)$/);
  const proto = match && match[1] === "https" ? "wss" : "ws";
  const host = match ? match[2] : "localhost:4000";
  return `${proto}://${host}/live/websocket?_csrf_token=${encodeURIComponent(csrfToken)}&_mounts=0&_live_referer=${encodeURIComponent(BASE_URL + "/")}&vsn=2.0.0`;
}

function currentChannelSlug() {
  return CHANNEL_SLUGS[(__VU - 1) % CHANNEL_SLUGS.length];
}

function pageUrlForChannel(slug) {
  return `${BASE_URL}/?channel=${encodeURIComponent(slug)}`;
}

function buildFormValue(body) {
  const metadata = {
    composer: "tiptap",
    entities: [],
    document: {
      type: "doc",
      content: [{ type: "paragraph" }],
    },
  };

  return `message%5Bbody%5D=${encodeURIComponent(body)}&message%5Bmetadata%5D=${encodeURIComponent(JSON.stringify(metadata))}`;
}

function sendMessageFrame(topic, messageRef, body) {
  return JSON.stringify([
    "4",
    String(messageRef),
    topic,
    "event",
    {
      type: "form",
      event: "send_message",
      value: buildFormValue(body),
      meta: {},
    },
  ]);
}

function authenticate(email, username) {
  if (authenticatedUsers.has(email)) {
    return true;
  }

  if (LOGIN_MODE === "phoenix") {
    const ok = loginUser(email, null, { jar });

    if (ok) {
      authenticatedUsers.add(email);
    }

    return ok;
  }

  const ok = testLogin(email, username, "/", { jar });

  if (ok) {
    authenticatedUsers.add(email);
  }

  return ok;
}

function restoreSession(email, setupData) {
  const cookies = setupData && setupData.sessions && setupData.sessions[email];

  if (!cookies) {
    return false;
  }

  for (const [name, value] of Object.entries(cookies)) {
    jar.set(BASE_URL, name, value);
  }

  authenticatedUsers.add(email);
  return true;
}

export default function (setupData) {
  const userIndex = ((__VU - 1) % FLOOD_USERS) + 1;
  const email = `test_k6_${userIndex}@example.com`;
  const username = `test_k6_${userIndex}`;
  const channelSlug = currentChannelSlug();

  if (!restoreSession(email, setupData) && !authenticate(email, username)) {
    check(false, { "login ok": () => false });
    sleep(1);
    return;
  }

  const pageRes = http.get(pageUrlForChannel(channelSlug), {
    jar,
    redirects: 0,
    tags: { name: "GET /?channel=:slug (liveview)" },
  });

  if (pageRes.status === 302 && pageRes.headers.Location === "/login") {
    authenticatedUsers.delete(email);

    if (!authenticate(email, username)) {
      check(false, { "login ok": () => false });
      sleep(1);
      return;
    }

    return;
  }

  check(pageRes, {
    "channel page loads": (r) => r.status === 200,
  });

  if (pageRes.status !== 200) {
    sleep(1);
    return;
  }

  const root = extractRoot(pageRes.body);
  check(root, {
    "liveview root extracted": (r) => !!(r.rootId && r.session && r.staticToken && r.csrfToken),
  });

  if (!(root.rootId && root.session && root.staticToken && root.csrfToken)) {
    sleep(1);
    return;
  }

  const wsHeaders = {
    Cookie: cookieHeader(BASE_URL),
  };

  const result = ws.connect(joinUrl(root.csrfToken), { headers: wsHeaders }, (socket) => {
    const topic = `lv:${root.rootId}`;
    let receivedJoinAck = false;
    let receivedMessageAckCount = 0;
    let sentMessageCount = 0;
    let nextMessageRef = 12;
    const joinRef = "4";
    const heartbeatRef = "10";

    function queueNextMessage() {
      if (!receivedJoinAck || sentMessageCount >= MESSAGES_PER_SESSION) {
        return;
      }

      sentMessageCount += 1;
      socket.send(sendMessageFrame(topic, nextMessageRef, randomMessage()));
      nextMessageRef += 2;
    }

    socket.on("open", () => {
      const joinPayload = {
        url: pageUrlForChannel(channelSlug),
        params: {
          _csrf_token: root.csrfToken,
          _track_static: trackStatic(),
          _mounts: 0,
          _mount_attempts: 0,
        },
        session: root.session,
        static: root.staticToken,
        sticky: false,
      };

      socket.send(JSON.stringify([joinRef, joinRef, topic, "phx_join", joinPayload]));
      socket.send(JSON.stringify([null, heartbeatRef, "phoenix", "heartbeat", {}]));
    });

    socket.on("message", (raw) => {
      const msg = JSON.parse(raw);
      const event = msg[3];
      const payload = msg[4] || {};

      if (event === "phx_reply" && payload.status === "ok" && msg[0] === joinRef) {
        if (!receivedJoinAck) {
          receivedJoinAck = true;
          queueNextMessage();
          return;
        }

        if (msg[1] !== joinRef) {
          receivedMessageAckCount += 1;

          if (sentMessageCount < MESSAGES_PER_SESSION) {
            socket.setTimeout(() => {
              queueNextMessage();
            }, randomSleep(MESSAGE_THINK_MIN_MS, MESSAGE_THINK_MAX_MS) * 1000);
          } else if (receivedMessageAckCount >= MESSAGES_PER_SESSION) {
            socket.close();
          }
        }
      }
    });

    socket.setTimeout(() => {
      socket.close();
    }, SESSION_TIMEOUT_MS);

    socket.on("close", () => {
      check(
        { receivedJoinAck, receivedMessageAckCount, sentMessageCount },
        {
          "liveview join ack": (v) => v.receivedJoinAck,
          "liveview message ack": (v) => v.receivedMessageAckCount === v.sentMessageCount,
        },
      );
    });
  });

  check(result, {
    "websocket session established": (r) => r && r.status === 101,
  });

  sleep(randomSleep(THINK_TIME_MIN_MS, THINK_TIME_MAX_MS));
}
