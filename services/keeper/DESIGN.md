# Bot runner design

`services/keeper` is Avana's **bot runner**: the long-running process that hosts Avana's own bots against one chain's release manifest. Today it runs one kind of bot, the **LiquidationBot** (`packages/liquidator/bot`, the TypeScript half of the `packages/liquidator/` package from step 8), once per AMM integration.

## Naming

- **LiquidationBot** is the liquidation logic: it reads health factors, decides how to fund a liquidation (own funds or the `FlashLiquidator`'s Aave V3 flash loan) and sends `LiquidationModule.liquidate` or `FlashLiquidator.flashLiquidate`. Its class, settings (`LIQUIDATION_BOT_*`) and docs carry that name.
- **Keeper** stays the name of what is generic to running bots: this package (`@avana/keeper`, the `keeper` image and compose service), its `KEEPER_*` settings (manifest, stream, monitor, kill switch, metrics), the monitor's keeper feed (`/v1/keeper/*`, `MONITOR_KEEPER_INSTANCES`) and the keeper wallets. It is also the contracts' own word: the RiskModules' **keeper registry** (`addKeeper`, `getKeepers`, `NoActiveKeeper`) lists the bots whose presence lets borrowing run, and `11-fund-keepers` refills their gas from the keeper top-up wallet.

## Process

`src/main.ts` starts in this order, and any step that fails stops the process before it can sign:

1. Configuration (`config.ts`): the release manifest (`AVANA_MANIFEST`, ABI hash checked), the LiquidationBot's shared settings (`loadSettings`; its chain must be the manifest's), and the optional bot stream, monitor and kill-switch sets, each all or nothing. Secrets come from files only: the encrypted Foundry keystore and its password file, the stream key file, the monitor token file.
2. The signer (`loadSigner`), then one LiquidationBot per integration: that integration's AaveAdapter and LiquidationModule, the debt reserves of each CDP Spoke from the manifest, and the integration's `FlashLiquidator` only when its `OPERATOR` is this signer. A signer missing from the manifest's keeper registry is logged.
3. The halt flag from `KEEPER_HALT_STATE_PATH` (an unreadable file counts as halted), the mutual-TLS kill switch (`killSwitch.ts`) and the metrics endpoint.
4. One pass per `LIQUIDATION_BOT_POLL_MS`.

## The pass

`runner.ts`, for the head block:

1. **Accounts.** The indexer's bot stream (`stream.ts`, `/keeper/v1/events`): `AaveAdapter.AccountCreated` adds an account (one proxy per wallet and market) to its AaveAdapter's set, kept across passes. While the stream fails or after a reorg answer, the pass uses each bot's own RPC scan of `AccountCreated` instead (`AccountSet`).
2. **Bots.** Unless halted, each LiquidationBot runs its pass over its accounts: health factor on the market's Spoke, the debt reserve with the largest debt, the funding decision, a simulation, then the transaction. Liquidation is in kind: the bot receives both pool tokens (or, through the FlashLiquidator, sells them to repay the loan).
3. **Alerts** to the monitor (`monitorSink.ts`) and the log: `M-16` pages for a liquidatable account no bot can fund; `M-10` warns for a liquidation that failed, per market; `M-09` warns once an account stays liquidatable for 60 s of block time and pages at 300 s.
4. **Heartbeat**: the head is reported processed; the monitor pages when an instance falls 3 blocks behind.

Halted, the runner keeps discovering, alerting and posting its heartbeat, and sends nothing.

## What it no longer does

The replaced keeper's jobs went with the contracts they served: pending settlement and breaker pokes (Collateralization, MarketRegistry), Lens previews, swap routes through LPVaultSwap, the operator helper and its funding Safe, KMS signing, per-class gas budgets and code checks of upgradeable contracts (the core is immutable). Keeper gas is the monitor's `M-35` and the `11-fund-keepers` step.
