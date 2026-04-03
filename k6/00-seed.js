/**
 * 00-seed.js — Data seeding for k6 load tests
 *
 * Creates test users, a bot with API token, and populates channels with
 * initial messages so subsequent load tests have realistic data to work with.
 *
 * Prerequisites:
 *   - Phoenix server running with ENABLE_TEST_SUPPORT_COMMANDS=1
 *   - Database seeded (mix run priv/repo/seeds.exs)
 *
 * Usage:
 *   k6 run k6/00-seed.js
 *   BASE_URL=http://localhost:4000 k6 run k6/00-seed.js
 */

import { sleep, check } from "k6";
import { testCommand, randomMessage, TEST_PASSWORD } from "./helpers.js";

export const options = {
  vus: 1,
  iterations: 1,
  thresholds: {
    checks: ["rate==1"],
  },
};

const USER_COUNT = Number(__ENV.SEED_USERS || 50);
const MESSAGES_PER_CHANNEL = Number(__ENV.SEED_MESSAGES || 30);

export default function () {
  console.log("=== k6 seed: starting ===");

  // 1. Clean up any previous k6 test data
  console.log("Cleaning previous k6 data...");
  const cleanResult = testCommand("clear_k6_data");
  if (cleanResult) {
    console.log(
      `  Cleaned: ${cleanResult.deleted_users} users, ${cleanResult.deleted_messages} messages`,
    );
  }

  sleep(0.5);

  // 2. Create test users in bulk
  console.log(`Creating ${USER_COUNT} test users...`);
  const usersResult = testCommand("bulk_create_users", {
    count: USER_COUNT,
    prefix: "test_k6",
    password: TEST_PASSWORD,
  });

  if (!usersResult) {
    console.error("Failed to create test users — aborting seed");
    return;
  }

  console.log(`  Created ${usersResult.count} users`);
  const users = usersResult.users;

  sleep(0.5);

  // 3. Get available channels
  console.log("Fetching channels...");
  const channelsResult = testCommand("list_channels");
  if (!channelsResult || !channelsResult.channels.length) {
    console.error("No channels found — run `mix run priv/repo/seeds.exs` first");
    return;
  }

  const channels = channelsResult.channels;
  console.log(`  Found ${channels.length} channels: ${channels.map((c) => c.slug).join(", ")}`);

  sleep(0.5);

  // 4. Create a bot with API token for messaging tests
  console.log("Creating load test bot...");
  const botResult = testCommand("create_bot_with_token", {
    username: "test_bot_k6",
    display_name: "K6 Load Test Bot",
    email: "test_bot_k6@bot.local",
    label: "k6-load-test-token",
  });

  if (!botResult) {
    console.error("Failed to create bot — aborting seed");
    return;
  }

  console.log(`  Bot: ${botResult.bot.username} (${botResult.bot.id})`);
  console.log(`  Token: ${botResult.token.substring(0, 12)}...`);

  sleep(0.5);

  // 5. Populate channels with initial messages from different users
  console.log(`Seeding ${MESSAGES_PER_CHANNEL} messages per channel...`);

  for (const channel of channels) {
    let created = 0;

    for (let i = 0; i < MESSAGES_PER_CHANNEL; i++) {
      const user = users[i % users.length];

      const result = testCommand("create_message", {
        channel_slug: channel.slug,
        username: user.username,
        body: randomMessage(),
      });

      if (result) created++;

      // Tiny pause to avoid overwhelming the DB during seed
      if (i % 10 === 0) sleep(0.1);
    }

    console.log(`  #${channel.slug}: ${created}/${MESSAGES_PER_CHANNEL} messages`);
  }

  // 6. Summary
  console.log("\n=== k6 seed: complete ===");
  console.log(`  Users:    ${users.length}`);
  console.log(`  Channels: ${channels.length}`);
  console.log(`  Bot:      ${botResult.bot.username}`);
  console.log(`  Token:    ${botResult.token}`);
  console.log(`\nSave the bot token for use in other k6 tests:`);
  console.log(`  export K6_BOT_TOKEN="${botResult.token}"`);
  console.log(
    `  export K6_CHANNEL_IDS="${channels.map((c) => c.id).join(",")}"`,
  );
}
