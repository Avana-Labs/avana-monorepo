import js from "@eslint/js"
import nextPlugin from "@next/eslint-plugin-next"
import globals from "globals"
import tseslint from "typescript-eslint"
import prettier from "eslint-config-prettier"

export default tseslint.config(
  {
    ignores: [
      ".next/**",
      // Every alternate dist dir (AVANA_NEXT_DIST_DIR: .next-dev, .next-prod, .next-dev-real, …).
      ".next-*/**",
      "node_modules/**",
      // Local Vercel build output contains compiled server bundles, not project source.
      ".vercel/**",
      ".reports/**",
      ".artifacts/**",
      "**/.artifacts/**",
      "playwright-report/**",
      "test-results/**",
      ".c?????/**",
      "convex/_generated/**",
      "tailwind.config.js",
    ],
  },
  js.configs.recommended,
  ...tseslint.configs.recommended,
  {
    files: ["**/*.{ts,tsx,js,jsx}"],
    plugins: { "@next/next": nextPlugin },
    rules: {
      ...nextPlugin.configs.recommended.rules,
      ...nextPlugin.configs["core-web-vitals"].rules,
      // `console.error` / `console.warn` are legitimate diagnostics (error boundaries,
      // caught-error handlers); only `console.log`/`debug`/`info` are flagged.
      "no-console": ["warn", { allow: ["warn", "error"] }],
      "@typescript-eslint/no-unused-vars": [
        "error",
        {
          argsIgnorePattern: "^_",
          varsIgnorePattern: "^_",
          caughtErrorsIgnorePattern: "^_",
        },
      ],
    },
    languageOptions: {
      globals: {
        ...globals.browser,
        ...globals.node,
      },
    },
  },
  {
    files: ["lib/deployment-safety.mjs"],
    languageOptions: { globals: { ...globals.node } },
  },
  {
    // CLI/seed scripts legitimately print progress to stdout and use runtime
    // globals (fetch, URL, process) — `.mjs`/`.cjs` scripts miss the main block's
    // globals otherwise, tripping no-undef.
    files: ["scripts/**/*.{ts,tsx,js,mjs,cjs}"],
    languageOptions: {
      globals: {
        ...globals.browser,
        ...globals.node,
      },
    },
    rules: {
      "no-console": "off",
      "@typescript-eslint/no-require-imports": "off",
    },
  },
  {
    // Display-only mock modules — allowed as seed input (build-seed.ts, tests),
    // BUT never as a runtime read path in app/. The audit's task #20 delete list;
    // this rule is the tripwire that catches "one more re-import" regressions
    // before they land. Update the paths when new baseline files graduate.
    files: ["app/**/*.{ts,tsx}"],
    ignores: [
      "app/lib/convex-seed/**",
      "app/**/__tests__/**",
      "**/*.test.{ts,tsx}",
      "**/*.mock.ts",
      // Baseline files themselves — they legitimately re-export each other.
      "app/lib/borrow-detail/prng.ts",
      "app/lib/borrow-detail/token-price-series.ts",
      "app/lib/borrow-detail/live-fallback.ts",
      "app/lib/borrow-detail/index.ts",
      "app/lib/borrow-detail/asset.mock.ts",
      "app/lib/borrow-detail/pool.mock.ts",
      "app/lib/lend-detail/mock.ts",
      "app/lib/multiply-detail/index.ts",
      "app/lib/home-sim.ts",
      // Known runtime consumers not yet migrated. Each entry here is a scheduled
      // follow-up PR; delete an entry (and the file) once the last import moves
      // to Convex. Adding a NEW import from anywhere else fails lint.
      "app/lib/borrow-system/read-model.ts",
      "app/lib/borrow-detail/convex-detail.ts",
      "app/lib/lend-detail/convex-detail.ts",
      "app/dashboard/borrow-hero-state.ts",
      "app/dashboard/multiply-collateral-table.tsx",
      "app/components/home-page-workspace-runtime.tsx",
      "app/components/home/home-workspace-card.tsx",
      "app/components/home/types.ts",
      "app/lib/data/providers/rewards/source.ts",
      "app/components/home-workspace-primitives.tsx",
      "app/components/home/home-action-context-bar.tsx",
      "app/components/home/pool-picker-dialog.tsx",
      "app/components/home/shared.tsx",
      "app/components/home/token-picker-dialog.tsx",
      "app/lib/action-system/formatters.ts",
      "app/lib/borrow-system/home-contracts.ts",
      "app/lib/borrow-system/home-runtime.ts",
      "app/lib/data/borrow-domain.ts",
      "app/lib/data/catalog/borrow/index.ts",
    ],
    rules: {
      "no-restricted-imports": [
        "error",
        {
          patterns: [
            {
              group: [
                "@/app/lib/borrow-detail/pool.mock",
                "@/app/lib/borrow-detail/asset.mock",
                "@/app/lib/lend-detail/mock",
                "@/app/lib/home-sim",
              ],
              message:
                "Display-only mock module — reachable only from app/lib/convex-seed/** and tests. Read from Convex (via useAvanaSessions / fetch*) instead.",
            },
            {
              // Seed-input arrays live inside app/ (not convex/) because they
              // reference the mock catalog + registry helpers at compile time.
              // They MUST stay reachable only from build-seed.ts and parity
              // tests — the whole point is that the seed pipeline reads them
              // once and Convex is the runtime source afterwards.
              group: ["@/app/lib/convex-seed/inputs/*", "**/convex-seed/inputs/*"],
              message:
                "Seed-input array — reachable only from build-seed.ts and parity tests under app/lib/convex-seed/. UI + engine code should read the corresponding Convex query instead.",
            },
          ],
        },
      ],
    },
  },
  // Must stay LAST: disables ESLint stylistic rules that would conflict with
  // Prettier, so formatting is owned solely by `prettier --check`.
  prettier,
)
