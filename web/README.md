# Avana Sandbox

Avana is a lending protocol built on Aave V4 that enables AMM liquidity pool positions to be used as collateral. Liquidity providers from Uniswap, Balancer, Curve, or Aerodrome can deposit supported LP positions, have them evaluated inside market-specific risk frameworks, and borrow against them while the positions stay active in the underlying pools.

This is an interactive free risk frontend demo for exploring **Avana**. You can try to borrow against LP positions on Aave v4 here in a sandbox, not real transaction way. Everything runs locally with **synthetic wallets, markets, and transactions** so you can learn flows, stress-test UX, and validate engine behavior without mainnet risk.

## Main routes

| Route        | What to try                                               |
| ------------ | --------------------------------------------------------- |
| `/`          | Home workspace — Borrow, Repay, Claim, Remove in one card |
| `/borrow`    | Market explorer + pool detail pages with sidebar actions  |
| `/lend`      | Supply / withdraw stable and volatile assets              |
| `/multiply`  | Loop markets, leverage ruler, deleverage                  |
| `/dashboard` | Portfolio tabs: Borrow, Lend, Multiply, Activity          |

## Core flows to exercise

1. **Borrow** — Select collateral pool → enter amount → review health factor / borrowing power → simulate transaction.
2. **Pledge (supply collateral)** — Pick an LP pool you hold → deposit → see borrow power increase.
3. **Repay / Remove / Claim** — Pay down debt, withdraw collateral %, or claim fee rewards.
4. **Lend** — Deposit wallet balance into a market; withdraw supplied position.
5. **Multiply** — Set collateral amount + multiplier; review net APY, LTV, liquidation price.

## Contributing

Keep changes focused: engine logic in `app/lib/*-engine`, product UI in `app/{borrow,lend,multiply}`, shared action chrome in `app/components/action-page`. Run `npm test` and `npm run build` before opening a PR.
