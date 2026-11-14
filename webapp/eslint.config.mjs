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
    // The prototype's simulated engines, seeds and mock catalogs were removed: every number on a
    // page comes from services/convex or the chain. This tripwire fails lint if one comes back.
    files: ["app/**/*.{ts,tsx}", "components/**/*.{ts,tsx}", "lib/**/*.{ts,tsx}"],
    rules: {
      "no-restricted-imports": [
        "error",
        {
          patterns: [
            {
              group: [
                "**/*.mock",
                "**/mock",
                "**/mocks/*",
                "@/app/lib/home-sim",
                "@/app/lib/borrow-sim",
                "@/app/lib/convex-seed/*",
                "@/app/lib/data/mock/*",
                "@/app/lib/data/catalog/*",
                "@/app/lib/deterministic",
                "@/app/lib/*-engine",
                "@/app/lib/*-engine/*",
                "@/app/lib/multiply-*",
                "@/app/lib/umbrella-*",
              ],
              message:
                "Simulated data was removed from the app. Read markets from services/convex and wallet values from the chain.",
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
