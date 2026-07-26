const { defineConfig } = require("@playwright/test");

module.exports = defineConfig({
  testDir: "./benchmark/harness/browser",
  timeout: 30_000,
  use: {
    baseURL: process.env.BENCH_BASE_URL || "http://127.0.0.1:3100",
    headless: true
  }
});
