# Avana web app

The Next.js app of Avana (`@avana/web` in the npm workspace): Lend, Borrow, the Portfolio dashboard, the market detail pages, Swap, the Support Center and Ask AI. It reads markets from [services/convex](../services/convex/README.md); wallet values will be read live from the chain.

## What works today

- Markets, detail pages and charts come from `services/convex` (`api.markets.*` and the detail queries). Without a deployment every list is empty and detail pages 404.
- Wallet connection (wagmi + ConnectKit) and optional SIWE sign-in. Sign-in is only needed for per-wallet features (synced preferences, support requests, Ask AI with a wallet); no page is gated on it.
- Contract calls are not wired yet. Action pages open, and their previews and submit buttons say "Transactions are not available yet."
- Swap shows its UI; quotes are unsupported until CoW Swap is connected.
- Quests and points are placeholders ("Coming soon"); nothing is granted.
- Ask AI market answers work; questions about the user's own positions answer that wallet data is not available yet.

## Setup

From the repository root:

```sh
npm install
cp webapp/.env.example webapp/.env.local   # then fill in the values you have
npm run dev --workspace @avana/web   # http://localhost:3000
```

The app imports the Convex API from `../services/convex/convex` (the `@/convex/*` path alias in `tsconfig.json` and `vitest.config.ts`). Run `npx convex dev` in `services/convex` against your own deployment, or point `NEXT_PUBLIC_CONVEX_URL` at an existing one.

## Environment

Every variable is listed with a comment in [`.env.example`](.env.example). `next build` succeeds with all of them empty.

| Variable                                                | Needed for                                                                                                                                        |
| ------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------- |
| `NEXT_PUBLIC_CONVEX_URL`, `NEXT_PUBLIC_CONVEX_SITE_URL` | Market data (services/convex deployment)                                                                                                          |
| `NEXT_PUBLIC_WALLETCONNECT_PROJECT_ID`                  | WalletConnect wallets                                                                                                                             |
| `NEXT_PUBLIC_SIWE_ISSUER`, `SIWE_JWT_PRIVATE_JWK`       | SIWE sign-in and the JWTs Convex accepts (`SIWE_JWT_ISSUER` on the Convex deployment must equal the issuer)                                       |
| `CONVEX_RATE_LIMIT_SECRET`                              | Rate limit of the SIWE routes (same value on the Convex deployment)                                                                               |
| `ASK_AI_GUEST_SECRET`                                   | Ask AI for visitors without sign-in                                                                                                               |
| `NEXT_PUBLIC_SENTRY_DSN`, `SENTRY_AUTH_TOKEN`           | Error reporting and source map upload (Vercel builds)                                                                                             |
| `NEXT_PUBLIC_AVANA_CHAIN_ID`, `NEXT_PUBLIC_RPC_*`       | Reserved for contract calls; the first target is the local anvil deployment (chain 31337) read through the manifest loader in `packages/protocol` |

Ask AI's OpenAI key and models (`OPENAI_API_KEY`, `ASK_AI_MODEL`, ...) are set on the Convex deployment, not here.

## Scripts

| Command             | Does                                          |
| ------------------- | --------------------------------------------- |
| `npm run dev`       | Development server                            |
| `npm run build`     | Production build                              |
| `npm run lint`      | ESLint                                        |
| `npm run typecheck` | `tsc --noEmit`                                |
| `npm test`          | Vitest unit tests                             |
| `npm run test:e2e`  | Playwright (needs a running app and browsers) |

## Layout

| Path                                                  | Contents                                                                                                       |
| ----------------------------------------------------- | -------------------------------------------------------------------------------------------------------------- |
| `app/`                                                | Routes (`borrow`, `lend`, `swap`, `dashboard`, `ask`, `support-center`, `actions`, `api`) and their components |
| `app/lib/borrow-system`, `lend-system`, `swap-system` | Session state, read models and transaction adapters of each product                                            |
| `app/lib/borrow-detail`, `lend-detail`, `detail-page` | Detail page view models built from Convex rows                                                                 |
| `app/lib/i18n`                                        | Translations (13 languages besides English)                                                                    |
| `components/`, `lib/`                                 | Shared UI, CSP, analytics                                                                                      |
