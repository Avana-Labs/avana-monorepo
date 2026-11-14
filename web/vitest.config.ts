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
  "**/__tests__/**/sandbox-adapter-contract.ts",
]

// `.test.ts` specs that genuinely need a DOM (localStorage / storage events,
// renderHook, requestIdleCallback, …). Everything else `.ts` runs in the fast
// `node` environment; only `.tsx` render tests and these files pay for jsdom.
// If a node-project spec ever needs the DOM, it fails loudly — move it here.
const DOM_TS_TESTS = [
  "app/lib/borrow-system/__tests__/storage.test.ts",
  "app/lib/currency/__tests__/exchange-rates.test.ts",
  "app/lib/siwe/__tests__/auth-store-cross-tab.test.ts",
  "app/lib/swap-system/__tests__/swap-storage-occ.p2-05.test.ts",
  "app/lib/ui/__tests__/use-has-mounted.test.ts",
  "app/lib/web3/__tests__/schedule-idle.test.ts",
  "convex/__tests__/prices-freshness.test.ts",
  "convex/onboarding.test.ts",
  "convex/sandbox-umbrella.test.ts",
]

export default defineConfig({
  plugins: [react()],
  resolve: {
    alias: {
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
          include: ["app/**/__tests__/**/*.{test,spec}.ts", "tests/unit/**/*.test.ts", "convex/**/*.test.ts"],
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
    ],
  },
})
