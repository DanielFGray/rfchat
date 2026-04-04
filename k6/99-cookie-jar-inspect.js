import http from "k6/http";
import { testLogin } from "./helpers.js";

const jar = new http.CookieJar();

export const options = { vus: 1, iterations: 1 };

export default function () {
  testLogin("test_k6_1@example.com", "test_k6_1", "/", { jar });
  console.log(JSON.stringify(jar.cookiesForURL("http://localhost:4000")));
}
