import path from "node:path"
import react from "@vitejs/plugin-react"
import { defineConfig } from "vitest/config"

const sharedExclude = [
  "**/node_modules/**",
  "**/.next/**",
  "**/__tests__/flow.harness.ts",
  "**/__tests__/**/stress-fixtures.ts",
  "**/__tests__/**/fixtures.ts",
  "**/__tests__/**/oracle.ts",
]

// `.test.ts` specs that genuinely need a DOM (localStorage / storage events,
// renderHook, requestIdleCallback, …). Everything else `.ts` runs in the fast
// `node` environment; only `.tsx` render tests and these files pay for jsdom.
// If a node-project spec ever needs the DOM, it fails loudly — move it here.
const DOM_TS_TESTS = [
  "app/lib/currency/__tests__/exchange-rates.test.ts",
  "app/lib/siwe/__tests__/auth-store-cross-tab.test.ts",
  "app/lib/ui/__tests__/use-has-mounted.test.ts",
  "app/lib/web3/__tests__/schedule-idle.test.ts",
]

export default defineConfig({
  plugins: [react()],
  resolve: {
    alias: {
      // The Convex API and the Ask AI library live in services/convex (same mapping as tsconfig `paths`).
      "@/convex": path.resolve(__dirname, "../services/convex/convex"),
      "@": path.resolve(__dirname, "."),
      // Next.js `server-only` guard isn't resolvable under vitest; stub it.
      "server-only": path.resolve(__dirname, "tests/stubs/server-only.ts"),
    },
  },
  test: {
    // Split the suite by environment: pure-logic specs run under `node` (no jsdom
    // spin-up), DOM/React specs run under `jsdom`. Same setup file + aliases for both.
    projects: [
      {
        extends: true,
        test: {
          name: "node",
          environment: "node",
          setupFiles: ["./vitest.setup.ts"],
          include: ["app/**/__tests__/**/*.{test,spec}.ts", "tests/unit/**/*.test.ts"],
          exclude: [...sharedExclude, ...DOM_TS_TESTS],
        },
      },
      {
        extends: true,
        test: {
          name: "jsdom",
          environment: "jsdom",
          setupFiles: ["./vitest.setup.ts"],
          include: ["app/**/__tests__/**/*.{test,spec}.tsx", ...DOM_TS_TESTS],
          exclude: sharedExclude,
        },
      },
      {
        // Field tests against a local services/convex seeded by scripts/local-convex-seed.ts. They skip
        // unless AVANA_LOCAL_CONVEX_URL is set (`npm run test:local-convex`).
        extends: true,
        test: {
          name: "local-convex",
          environment: "node",
          include: ["tests/local-convex/**/*.test.ts"],
          exclude: sharedExclude,
          testTimeout: 60_000,
        },
      },
      {
        // Real transactions on the local Ethereum fork, signed by a Foundry keystore. They skip unless
        // AVANA_FORK_RPC_ETHEREUM, AVANA_LOCAL_CONVEX_URL and AVANA_FORK_KEYSTORE are set (`npm run test:local-fork`).
        extends: true,
        test: {
          name: "local-fork",
          environment: "node",
          include: ["tests/local-fork/**/*.test.ts"],
          exclude: sharedExclude,
          testTimeout: 180_000,
          fileParallelism: false,
        },
      },
    ],
  },
})
