import http from "k6/http";
import { sleep } from "k6";
import {
  testLogin,
  getCsrfToken,
  userSendMessage,
} from "./helpers.js";

const jar = new http.CookieJar();

export const options = {
  vus: 1,
  iterations: 1,
};

export default function () {
  const email = __ENV.SINGLE_EMAIL || "test_k6_1@example.com";
  const username = __ENV.SINGLE_USERNAME || "test_k6_1";
  const channelId = __ENV.SINGLE_CHANNEL_ID;

  if (!channelId) {
    throw new Error("SINGLE_CHANNEL_ID is required");
  }

  if (!testLogin(email, username, "/", { jar })) {
    throw new Error("login failed");
  }

  sleep(0.1);

  const csrfToken = getCsrfToken("/", { jar });
  if (!csrfToken) {
    throw new Error("csrf token missing");
  }

  const res = userSendMessage(
    jar,
    csrfToken,
    channelId,
    `single-trace-${Date.now()}`,
  );

  if (res.status !== 201) {
    throw new Error(`unexpected status: ${res.status}`);
  }
}
