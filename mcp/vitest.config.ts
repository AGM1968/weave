import { defineConfig } from "vitest/config";

export default defineConfig({
  test: {
    include: ["src/**/*.test.ts"],
    exclude: ["dist/**", "node_modules/**"],
    testTimeout: 30_000,
    // Inside a test suite the user's config.env cannot log wv calls
    // (wv-6b0f57): the wv processes these tests spawn stay out of the
    // durable call log when vitest runs directly, not via test-mcp-vitest.sh.
    env: { WV_TEST_SUITE: "1" },
  },
});
