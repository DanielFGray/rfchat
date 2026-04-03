/**
 * 01-browse.js — Anonymous browsing scenario
 *
 * Simulates unauthenticated users hitting the login and registration pages.
 * This tests the baseline HTTP performance of the Phoenix endpoint, static
 * asset serving, and LiveView initial page renders.
 *
 * Usage:
 *   k6 run k6/01-browse.js
 */

import http from "k6/http";
import { check, sleep } from "k6";
import { BASE_URL, randomSleep } from "./helpers.js";

export const options = {
  stages: [
    { duration: "15s", target: 50 },
    { duration: "30s", target: 150 },
    { duration: "1m", target: 200 },
    { duration: "30s", target: 200 },
    { duration: "15s", target: 0 },
  ],
  thresholds: {
    http_req_duration: ["p(95)<2000", "p(99)<4000"],
    http_req_failed: ["rate<0.05"],
    checks: ["rate>0.95"],
  },
};

export default function () {
  const scenario = Math.random();

  if (scenario < 0.4) {
    // 40%: Visit login page
    visitLogin();
  } else if (scenario < 0.8) {
    // 40%: Visit registration page
    visitRegister();
  } else {
    // 20%: Hit the root (will redirect to /login for unauth users)
    visitRoot();
  }

  sleep(randomSleep(500, 2000));
}

function visitLogin() {
  const res = http.get(`${BASE_URL}/login`, {
    tags: { name: "GET /login" },
  });

  check(res, {
    "login page status 200": (r) => r.status === 200,
    "login page has form": (r) => r.body.includes("login-form"),
    "login page has csrf": (r) => r.body.includes("csrf-token"),
  });
}

function visitRegister() {
  const res = http.get(`${BASE_URL}/register`, {
    tags: { name: "GET /register" },
  });

  check(res, {
    "register page status 200": (r) => r.status === 200,
    "register page has form": (r) => r.body.includes("registration-form"),
  });
}

function visitRoot() {
  const res = http.get(`${BASE_URL}/`, {
    redirects: 5,
    tags: { name: "GET / (unauth)" },
  });

  check(res, {
    "root redirects to login": (r) =>
      r.status === 200 && r.url.includes("/login"),
  });
}
