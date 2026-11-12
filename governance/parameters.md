# Avana parameters

Last updated: 2026-11-12

This page lists Avana's main parameters, who sets each one and why. Values change through governance, and this page is updated with them. The full registry, with units, on-chain bounds and change delays, is [1.5 Protocol Parameters](../spec/01-architecture/05-parameters.md). The proposal these values belong to is the [ARFC](arfc-avana-lp-collateral.md). Each row links the spec rule that uses the value.

Rule IDs link to their spec page. `Q-` IDs link to the [design decisions](../spec/04-security/04-design-decisions.md).

## A. Set with the Aave DAO and its service providers

Avana proposes a starting point, and the Aave DAO decides.

| Parameter | What it does | Avana's proposed starting point | Decided in |
|---|---|---|---|
| First-loss reserve and coverage ratio ([DEF-019](../spec/03-operations/09-deficit-coverage.md)) | Sets how much of each debt asset Avana Labs funds into that asset's Avana Umbrella (Coverage Spoke) per unit of draw caps: `fundedBalance × 10⁴ ≥ coverageRatioBps × Σ drawCap`. | Open. 20% is an illustrative guide only. | Funding ARFC |
| Debt assets ([REQ-HUB-002](../spec/02-contracts/01-avana-hub-and-spokes.md), [Q-408](../spec/04-security/04-design-decisions.md)) | Which assets are listed on the Lend Spoke and borrowable on the CDP Spokes. | Stable debt assets the Aave DAO approves, for example GHO, USDC, USDT, each with its own line, draw cap, price source, swap routes and Avana Umbrella. No launch set is fixed. | Funding ARFC and listing AIP |
| Credit line per chain, Hub and debt asset ([SPEC-HUB-003](../spec/02-contracts/01-avana-hub-and-spokes.md)) | Caps what the CDP Spokes together can draw of each debt asset; it does not cap supply. | GHO on Ethereum: 2M GHO. Every other line: open, within the asset's flash liquidity in the chain's Aave V3 Pool and its swap-route depth. | Funding ARFC |
| Interest-rate curve per lend asset ([SPEC-HUB-007](../spec/02-contracts/01-avana-hub-and-spokes.md)) | Aave V4's standard kinked utilization curve: the borrow rate rises with utilization, gently up to the optimal ratio and steeply past it, which draws new supply and pushes borrowers to repay. | Set by the DAO per asset; for GHO the base rate may stay at or above the Core Hub GHO base rate. Illustration only: 5.50% base, 3.60% up to 90% utilization, 50% above it. | Funding ARFC and AIPs |
| Lend Spoke supply cap and bootstrap supply ([REQ-HUB-016](../spec/02-contracts/01-avana-hub-and-spokes.md)) | Caps what all lenders together can supply of each asset; the DAO's bootstrap supply goes in before any draw cap is raised. | Open; illustration only: $1M GHO and $1M USDT of DAO supply | Funding ARFC |
| Draw caps ([SPEC-HUB-003](../spec/02-contracts/01-avana-hub-and-spokes.md), [REQ-HUB-045](../spec/02-contracts/01-avana-hub-and-spokes.md)) | Caps what each CDP Spoke can borrow from its credit line; borrowing also needs idle Hub liquidity supplied by lenders through the Lend Spoke, public and DAO. | Open. Each cap stays within its chain's flash liquidity and swap-route depth. | Funding ARFC |
| Collateral factor ([SPEC-CF-001](../spec/02-contracts/07-risk-module.md)) | Sets how much of a position's value can back debt. | `min(token CFs) × pool risk factor`, rounded down | Listing ARFC and AIP |
| Pool risk factor ([SPEC-HUB-001](../spec/02-contracts/01-avana-hub-and-spokes.md)) | Discounts each pool for its range, depth and liquidation cost. | At most 40%, set per pool | Listing ARFC and AIP |
| Liquidation bonus ([1.5](../spec/01-architecture/05-parameters.md#liquidation-and-settlement), `minLiquidationBonus`, [Q-393](../spec/04-security/04-design-decisions.md)) | Pays the liquidator for gas, swap costs and Avana's fee. | At least 2% just below health factor 1 | Listing AIP |
| Target health factor ([1.5](../spec/01-architecture/05-parameters.md#liquidation-and-settlement), `aaveTargetHealthFactor`, [Q-393](../spec/04-security/04-design-decisions.md)) | Sets the health factor Aave's liquidation restores an account to. | 1.10 | Listing AIP |
| Market caps ([SPEC-CAP-007](../spec/02-contracts/07-risk-module.md)) | Limit exposure per market, per token and per depositor on each Hub. | Open, sized per market with the cap-sizing rule | Listing ARFC |
| Flash-borrower role ([REQ-HUB-044](../spec/02-contracts/01-avana-hub-and-spokes.md)) | Removes the Aave V3 flash-loan premium on liquidation loans. | Granted on the Aave V3 Pool on Ethereum and Base | Deployment AIP |

## B. Chosen by Avana

Economic values are a proposed default; the final value is set in the listing or funding ARFC.

| Parameter | What it does | Value | Why |
|---|---|---|---|
| `minPledgeUsd` ([REQ-ARCH-018](../spec/01-architecture/01-protocol-overview.md)) | Sets the smallest position value a pledge or top-up can add. | $10, proposed default | Stops accounts built from dust positions while keeping small LPs welcome. |
| Minimum debt ([LIQ-087](../spec/03-operations/05-liquidation.md), [Q-381](../spec/04-security/04-design-decisions.md)) | Would set the smallest loan allowed. | None | Avana's own keeper liquidates every account whatever its size and pays the gas. |
| `avanaFeeShareBps` ([SPEC-LIQ-009](../spec/02-contracts/11-lpvaultswap.md)) | Takes Avana's share of a liquidation's oracle gain. | 20%, proposed default | Never above the realized gain, so the debt is always repaid first; in the Ethereum worked example it is 39.2 GHO of a 196 GHO gain (LIQ-068). |
| Frontend fee ([Q-409](../spec/04-security/04-design-decisions.md)) | The Avana app's fee on every app action: supply, withdraw, pledge, withdraw collateral, borrow, repay, repay with collateral, deleverage. The wallet sends it to `feeRecipient` in the action's own batch; no contract charges it, and keeper liquidations pay none. | 10 bps of the action's amount (for pledge and withdraw collateral, of the position's oracle USD value, paid in the debt stablecoin), rounded down; ceiling 25 bps | Set by Avana operations in the app config, never above the 25 bps ceiling the ARFC commits to without a new ARFC. Changes no interest rate and no Aave DAO revenue; borrowing 50,000 GHO costs 50 GHO. |
| `poolShareMaxBps` ([SPEC-CAP-005](../spec/02-contracts/07-risk-module.md)) | Caps Avana's combined share of a pool's liquidity on a chain, where a pool's listing sets a cap. | 10,000 bps (no limit) by default; a per-pool cap is optional at listing; alert above 25% | Removing liquidity has no price impact, and liquidation proceeds can be sold through any approved route (other pools, DEXs, aggregators). Liquidation safety comes from the route-depth checks and draw caps; concentration risk is covered by token caps, market caps and listing review (`Q-403`). |
| `topUpSliceUsd` ([SPEC-CAP-003](../spec/02-contracts/07-risk-module.md)) | Reserves cap room for borrowers adding collateral to avoid liquidation. | 10% of the market cap, proposed default | A full market cap never stops a rescue top-up. |
| `usdBandLow`, `usdBandHigh` ([SPEC-ORC-011](../spec/02-contracts/10-lp-oracle.md)) | Blocks new borrowing when a stablecoin market leaves its peg band. | $0.90 – $1.02, proposed default | Wide enough for normal peg noise, tight enough to stop borrowing in a depeg. |
| `twapWindow`, `consistencyToleranceBps` ([SPEC-ORC-010](../spec/02-contracts/10-lp-oracle.md)) | Checks the Chainlink price against the pool's time-weighted price. | 30 min; 0.5%, proposed defaults | Moving a 30-minute average needs a price held off-market for many blocks; 0.5% is about 50 ticks of room. |
| `feedAgreementMarginBps` ([REQ-ORACLE-100](../spec/02-contracts/10-lp-oracle.md)) | Adds a margin to the two Chainlink routes' deviation thresholds before they count as disagreeing. | 0.5%, proposed default | Two honest feeds can each lag by their threshold; the margin covers rounding on top. |
| `heartbeatMargin` ([SPEC-ORC-019](../spec/02-contracts/10-lp-oracle.md)) | Extends each feed's freshness past its own heartbeat. | 30 min | Covers a late publication without treating a healthy feed as stale. |
| `cachedWindow` ([SPEC-ORC-017](../spec/02-contracts/10-lp-oracle.md)) | Holds the last good price after both routes fail, before the price expires. | 1 h | Long enough for a guardian to switch to the standby route. |
| `disagreementPauseMax` ([SPEC-ORC-017](../spec/02-contracts/10-lp-oracle.md)) | Limits how long liquidation waits while the two routes disagree. | 1 h | Bounds the liquidation stop to the same hour as the cached window. |
| `graceDuration`, `graceHealthFactor` ([SPEC-ORC-017](../spec/02-contracts/10-lp-oracle.md)) | After a price recovers, only accounts below 0.95 can be liquidated for a while. | 30 min; 0.95 | Gives borrowers time to react to a price they could not see. |
| `sequencer.gracePeriod` ([SPEC-ORC-021](../spec/02-contracts/10-lp-oracle.md)) | Applies the same grace after a Base sequencer restart. | 1 h | Users need time to reach the chain after an outage. |
| `maxQuoteChangeBps` ([REQ-AMM-CORE-014](../spec/02-contracts/19-amm-integration-interface.md)) | Caps how far a market's price can jump between two blocks before a later block confirms it. | 1% | Stops a one-block feed spike from opening borrowing or liquidation. |
| `slippageAllowanceBps` ([SPEC-LIQ-003](../spec/02-contracts/11-lpvaultswap.md)) | Sets how much below oracle value liquidation swaps may settle. | 1%, proposed default | Fits inside the 2% minimum bonus with room for costs; the worked example settles at 9,950 GHO against a 9,895.04 GHO floor. |
| `maxShortfallBps` ([SPEC-LIQ-019](../spec/02-contracts/11-lpvaultswap.md)) | Lets the keeper add its own funds to cover up to 10% more slippage. | 10% | Keeps liquidations going in thin markets without any protocol budget. |
| Wind-down ([MKT-059](../spec/03-operations/08-market-lifecycle.md)) | Offboards a market: notice, then a daily liquidation-threshold ramp. | 5 days notice; 30-day ramp; down to 50% | Every borrower sees a small, predictable daily cut and has time to repay. |
| `deficitCoverageWindow` ([REQ-FLR-021](../spec/02-contracts/14-first-loss-reserve.md)) | Sets the time to cover a recorded deficit from the Avana Umbrella. | 72 h | Gives time to confirm the deficit and fund it through the DAO-controlled Avana Umbrella while keeping lenders' exposure short. |
| `keeperFloor`, `MAX_KEEPERS` ([LIQ-065](../spec/03-operations/05-liquidation.md)) | Sets the fewest and most approved keepers per chain. | 1; 32 | Avana runs its own keeper; borrowing halts only at 0 active keepers, and more can be added later. |
| `MAX_RECORDS_PER_ACCOUNT_MARKET` ([SPEC-CHAIN-001](../spec/01-architecture/05-parameters.md#chains)) | Caps the positions one account holds in one market. | 16 | A whole-account seizure costs at most 5.15M gas, under half a 16.78M-gas block (MATH-CH-01). |

## C. Breakers (v1)

| Trigger | Setting | Action |
|---|---|---|
| Oracle or stablecoin band breach | The oracle price-state checks and the $0.90–$1.02 band | Block new borrowing and collateral withdrawals that leave debt |
| Price drop | 3% in 2 hours | Alert only |
| Avana's combined share of a pool ([SPEC-CAP-005](../spec/02-contracts/07-risk-module.md)) | Above 25% across all borrowers and Spokes on the chain | Alert only; a per-pool cap applies only where its listing sets one, and above it new borrowing and pledges that increase pool exposure are blocked |
| Collateral seized | Above 20% of a market in 1 hour | Alert only |
| Swap-route failures | 3 in 1 hour | Alert. A guardian freezes new borrowing only when the approved routes are confirmed unable to settle valid liquidations at the required size |
| Outstanding deficit | 10,000 GHO for the affected CDP Spoke's GHO reserve; other assets at a level set at listing | Freeze new borrowing on that debt reserve automatically; alert on every new deficit |
| Reopening | 30 minutes of healthy observations (provisional launch setting) | Clear a temporary price or depth gate. A deficit or security freeze reopens only through the timelock or a guardian ([2.15](../spec/02-contracts/15-governance-and-timelock.md)) |

Repayment, debt-free exits and eligible liquidations stay open through every breaker. An Aave reserve pause can still block repayment or liquidation on its own ([Q-399](../spec/04-security/04-design-decisions.md)).

## D. Governance and timelock

Each chain has its own Safes and timelock; the values are the same on Ethereum and Base.

| Setting | Value | What it controls |
|---|---|---|
| Normal delay ([REQ-ACCESS-154](../spec/02-contracts/15-governance-and-timelock.md)) | 5 days, never below 4 | Upgrades, listings, every loosening and role change |
| Short delay ([REQ-ACCESS-155](../spec/02-contracts/15-governance-and-timelock.md)) | 12 hours | Only operations that reduce risk or stop new activity |
| Grace period ([1.5](../spec/01-architecture/05-parameters.md#governance)) | 14 days | How long a ready operation stays executable |
| Governance Safe ([REQ-ACCESS-102](../spec/02-contracts/15-governance-and-timelock.md)) | 4-of-7, at most 3 Avana Labs signers | Proposes and cancels timelock operations |
| Emergency Guardian ([REQ-ACCESS-104](../spec/02-contracts/15-governance-and-timelock.md)) | 3-of-5 | Immediate freeze, pause, breaker trips and standby switches; cancel |
| Aave governance executor ([REQ-ACCESS-156](../spec/02-contracts/15-governance-and-timelock.md)) | Second proposer and DAO canceller | Proposes; the only canceller of role changes and restoring operations |
| Aave Protocol Guardian ([REQ-ACCESS-104](../spec/02-contracts/15-governance-and-timelock.md)) | Same immediate powers as the Emergency Guardian | Can also freeze or pause Avana's CDP Spoke reserves on the Aave side, and freeze Lend Spoke reserves (new supply stops, withdrawals stay open) |
| Coverage withdrawal delay ([1.5](../spec/01-architecture/05-parameters.md#governance)) | 14 days, with DAO approval | Withdrawal of unused Avana Umbrella funds |

The three signer sets do not overlap.

## Removed in v1, and why

- **Settlement budget** ([Q-397](../spec/04-security/04-design-decisions.md)). The keeper sizes the repayment, including Aave's dust rule and the exact flash principal and premium, and pays any rounding gap through its shortfall top-up.
- **In-kind settlement** ([Q-401](../spec/04-security/04-design-decisions.md)). Every liquidation settles in the debt asset or reverts. The escrow stays, only for payouts a token refuses.
- **Idle-collateral mechanism** ([Q-396](../spec/04-security/04-design-decisions.md)). Cap squatting by a non-borrowing LP is an accepted risk, handled by caps set at listing and by monitoring.
- **On-chain health floors** ([Q-398](../spec/04-security/04-design-decisions.md)). Aave's HF 1.00 is the only on-chain limit; the Lens recommends 1.10. An optional per-market floor stays off unless stress tests justify it.
- **Minimum debt** ([Q-381](../spec/04-security/04-design-decisions.md)). Avana's keeper liquidates every account whatever its size.
- **`keeperMinRepay`** ([Q-395](../spec/04-security/04-design-decisions.md)). The keeper repays whatever Aave allows per call.
- **Price-drop, seizure and route-failure auto-breakers** ([Q-399](../spec/04-security/04-design-decisions.md)). A reverted call cannot persist a failure count, and on-chain counters can be gamed, so these are alerts.
