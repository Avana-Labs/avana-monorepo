---
title: Market Parameters
description: Each Avana market's pool and risk parameters per Spoke, and the protocol-wide Avana parameters.
updated: {{updated}}
---

**Deployment values.** Each network's section shows the values that network's deployment listed with, read from its release manifest and deploy output. On mainnet the Aave DAO sets caps, collateral factors, liquidation bonuses, collateral risk premiums and First-Loss Reserve amounts through its proposals.

{{networks}}

## All networks

These parameters have the same rules on every network. Bounds are enforced on-chain unless the description says otherwise. `Set by governance` means the Aave DAO or Avana's timelock decides the value; where Avana proposes a starting value, the description gives it. `Per network` means the value differs between networks and is given in each network's section.

### Fees

| Parameter | Value | Bounds | Description | Source |
| --- | --- | --- | --- | --- |
| `avanaFeeShareBps` | 2,000 bps (20%) | 0–5,000 bps | Avana's share of a liquidation's gain over the debt repaid, valued at the oracle price and paid in the repaid debt asset. It never exceeds the surplus the liquidation actually realized, so the debt is always repaid first. | `Q-097`, `Q-196`, `Q-231`, `SPEC-LIQ-009`; `ParameterStoreStorage.sol:84`, `SettlementMath.sol:311-315` |
| `feeRecipient` | Avana treasury | Non-zero address | Avana's treasury receives both the liquidation fee share and the app's frontend fee. It is a separate account from the deployer and the keeper, and changes only through the timelock at the normal delay. | `Q-196`, `Q-409`; `ParameterStoreAdminRiskLogic.sol:89`, `contracts/script/local/lib/chain.ts:132` (#135), `contracts/script/local/lib/keys.ts:52-54` (#135) |
| `defaultBps` (frontend fee) | 10 bps | 0–25 bps | Fee the Avana app adds to every action it builds: supply, withdraw, pledge, withdraw collateral, borrow, repay, repay with collateral and deleverage. The wallet sends it to `feeRecipient` in the action's own batch; no contract charges it, and keeper liquidations pay none. | `Q-409`; `services/convex/convex/lib/fees.ts:29`, `:188` |
| Interest fee | None | — | Avana charges no fee on borrow interest; borrowers pay only the Hub's borrow rate. | `Q-231` |

> The 25 bps frontend fee ceiling is a commitment in the Aave proposal enforced by the app's fee rules, not by a contract. The Joint Configuration Safe can change `avanaFeeShareBps` at once within its bounds; every other change waits the normal delay (`REQ-ROLE-117`, `ParameterStoreAdminRiskLogic.sol:117`).

### Risk module

| Parameter | Value | Bounds | Description | Source |
| --- | --- | --- | --- | --- |
| `RESCUE_HEALTH_FACTOR` | 1.10 | — | An indebted account below this health factor can add collateral as a rescue top-up, which uses the market's reserved slice when caps are full. It is not a borrow limit. | `Q-398`; `RiskModuleMath.sol:13` |
| `RECOMMENDED_HEALTH_FACTOR` | 1.10 | — | Health factor of the recommended borrow amount the app shows beside the maximum at 1.00. It is guidance and is not enforced on-chain. | `Q-398`; `LensConstants.sol:19` |
| `minPledgeUsd` | Set by governance | $0–$100,000 | Smallest USD value one pledge, new account or top-up can add, so accounts are not built from dust positions. Avana proposes $10 per market. | `Q-230`, `Q-394`; `ParameterStoreStorage.sol:83` |
| `RESCUE_MIN_PLEDGE_USD` | $10 | — | A rescue top-up needs only the lower of this and `minPledgeUsd`, so a raised minimum never stops a borrower adding collateral to avoid liquidation. | `Q-252`; `RiskModuleMath.sol:16` |
| `marketUsdCap` | Set by governance | > 0 at listing; 0 or more after a tightening | USD budget for pledges in one market. Tightening it to 0 stops new pledges and leaves repay, exits, liquidation and rescue top-ups open. | `Q-197`; `ParameterStoreLoosenLogic.sol:134` |
| `tokenUsdCap` | Set by governance | > 0 at listing; 0 or more after a tightening | Exposure cap per underlying token across every Spoke and market of a Hub. Each pledge counts its full LP value against both of its tokens. | `Q-197`, `Q-249` |
| `LOOSEN_CAP_STEP_BPS` | 15,000 bps (×1.5) | — | Largest rise of a USD cap in one loosening, at most once per normal delay. A cap below $1,000 can instead be raised straight to $1,000 (`USD_CAP_REOPEN_BASE`). | `Q-246`; `ParameterStoreStorage.sol:73`, `:98` |
| `topUpSliceUsd` | Set by governance | ≤ `marketUsdCap` | Cap room reserved in each market for rescue top-ups, so a full cap never blocks a borrower adding collateral. Avana proposes 10% of the market cap. | `Q-157`, `Q-394` |
| `stressFloorUsd` | Set by governance | > 0 | Lowest price per vault token used when charging caps. Avana proposes $1.00. | `Q-175`, `Q-394` |
| `poolRiskFactor` | Set by governance | 1–9,000 bps | Per-pool discount in the LP collateral factor, `min(CF0, CF1) × poolRiskFactor`. The Aave DAO sets the resulting collateral factor. | `Q-186`; `ParameterStoreStorage.sol:81`, `ParameterStoreAdminRiskLogic.sol:103` |
| `tokenCollateralFactorBps` | Set by governance | 1–9,999 bps | Each token's collateral factor on the Aave V4 Core Hub, recorded at listing as CF0 and CF1 of the LP collateral factor. | `Q-188`; `ParameterStoreStorage.sol:82`, `ParameterStoreAdminRiskLogic.sol:218` |
| `marketSpeedLimits.window` | Set by governance | 3,600–604,800 s | Length of each borrow-speed and pledge-speed window. Any window takes at most one limit, so a mispriced market loses at most one limit before a guardian freeze. Avana proposes 21,600 s (6 hours). | `Q-411`, `SPEC-CAP-011`; `ParameterStoreSpeedRules.sol:18-20` |
| `marketSpeedLimits.borrowRateBps`, `borrowMinUsd`, `borrowMaxUsd` | Set by governance | Rate 0–10,000 bps; min ≤ max | New debt per window in a market, net of repays, is at most the rate times the Spoke's debt, kept between the min and max. Avana proposes 25%, $250,000 and $2,500,000. | `Q-411`, `REQ-RISK-092`; `ParameterStoreSpeedRules.sol:22`, `:31` |
| `marketSpeedLimits.pledgeRateBps`, `pledgeMinUsd`, `pledgeMaxUsd` | Set by governance | Rate 0–10,000 bps; min ≤ max | New collateral per window in a market, net of withdrawals, is at most the rate times the market's booked value, kept between the min and max; rescue top-ups are exempt. Avana proposes 25%, $1,000,000 and $10,000,000. | `Q-411`, `REQ-RISK-093`; `ParameterStoreSpeedRules.sol:22`, `:31` |
| `debtSpeedLimit.rateBps`, `min`, `max` | Set by governance | Rate 0–10,000 bps; min ≤ max | New draws per window of one debt asset from one Hub across every Avana Spoke, net of repays. Avana proposes 25%, 500,000 and 5,000,000 tokens, so draw caps bind first. | `Q-411`, `REQ-RISK-092`; `ParameterStoreSpeedRules.sol:42` |
| `gateRecoverySeconds` | Set by governance | 600–7,200 s | Time a temporary gate (oracle or pool depth) stays closed after its last recorded breach. Avana proposes 1,800 s. | `Q-399`; `ParameterStoreStorage.sol:87-88` |
| `breakerDeficitMax` | Set by governance | 0 to the reserve's `firstLossReserveMinimum` | Outstanding deficit on a debt reserve above which new borrowing of that reserve freezes until an authorized reset. Avana proposes 10,000 GHO for a GHO reserve. | `Q-241`, `Q-399`; `ParameterStoreLoosenLogic.sol:290` |
| `BreakerReasons.TEMPORARY` | `ORACLE`, `POOL_DEPTH` | — | Gates that block new borrowing or pledges only while their condition holds, then reopen after `gateRecoverySeconds`. Repay, debt-free exits, rescue top-ups and liquidation stay open. | `Q-399`; `Breaker.sol:23-44` |
| `BreakerReasons.SECURITY`, `MANUAL` | `ISSUER`, `CONFIG_DRIFT`, `DEFICIT`, `MANUAL` | — | Freezes that stay latched until a guardian or a timelock operation resets them. There is no on-chain budget breaker; price drops, seizure surges and route failures are monitoring alerts. | `Q-241`, `Q-399`; `Breaker.sol:15-19`, `:31-46` |
| `ISSUER_PROBE_GAS` | 30,000 gas | — | Gas given to each check of a token issuer's pause or fee switch. A probe that fails counts as tripped, so a token cannot hide an issuer action. | `Q-241`; `RiskModuleMath.sol:19` |
| `liquidationFee` (Aave, per LP reserve) | 0 | Any other value is drift | Aave V4's native liquidation fee on vault-token reserves must stay 0. | `Q-068`, `Q-281`; `RiskModuleDriftLogic.sol:259`, `MarketRegistryActivationLogic.sol:79` |
| `receiveSharesEnabled` (Aave, per LP reserve) | false | Any other value is drift | A liquidator must receive vault tokens, never Spoke supply shares, so every seizure goes through the vault token's transfer rule. | `Q-281`; `RiskModuleDriftLogic.sol:217` |
| `reinvestmentController` (Aave, per vault-token asset) | `address(0)` | Any other value is drift | No reinvestment controller may hold vault-token assets on the Hub. | `Q-281`; `RiskModuleDriftLogic.sol:246` |

> A configuration drift (`CONFIG_DRIFT`) blocks new pledges, borrowing and withdrawals that leave debt on the Spoke; it never blocks repay, debt-free exits or liquidation (`REQ-RISK-078`).

### Liquidation and settlement

| Parameter | Value | Bounds | Description | Source |
| --- | --- | --- | --- | --- |
| `targetHealthFactor` (expected) | 1.10 | > 1.00 | Health factor Aave's liquidation restores an account to, as Avana records it for each CDP Spoke. The Aave DAO sets the live value; a different live value counts as drift. | `Q-185`, `Q-393`; `09_ListMarkets.s.sol:331`, `ParameterStoreListingLogic.sol:250-251` |
| `minLiquidationBonus` (expected) | 200 bps (2%) | 200–9,999 bps | Bonus just below health factor 1 that Avana's checks assume. It must cover gas, swap costs and Avana's fee share. | `Q-179`, `Q-393`; `09_ListMarkets.s.sol:331`, `ParameterStoreStorage.sol:100` |
| `liquidationBonusFactor`, `healthFactorForMaxBonus` | Set by governance | — | Aave V4 liquidation settings of each CDP Spoke that shape the bonus between its minimum and maximum. The deployment payload uses 5,000 bps and 0.95 on the test networks. | `Q-393`; `06_AaveDeploymentPayload.s.sol` `_hubSpokes` |
| `slippageAllowanceBps` | Set by governance | ≥ `slippageAllowanceMinBps`, < 10,000 bps | Most below oracle value a liquidation's swaps may settle; it is also capped live by the net bonus. Avana proposes 100 bps; each network's listed values are under its Slippage allowance. | `SPEC-LIQ-003`, `Q-394`; `ParameterStoreListingLogic.sol:71-76` |
| `slippageAllowanceMinBps` | Set by governance | ≥ route fee plus price impact | Floor for `slippageAllowanceBps`, set per market at listing, so a tightening can never make liquidation impossible. Each network's listed values are under its Slippage allowance. | `Q-139`, `Q-209` |
| `LOOSEN_SLIPPAGE_STEP_BPS` | 25 bps | — | Largest rise of `slippageAllowanceBps` in one loosening. | `Q-246`; `ParameterStoreStorage.sol:74` |
| `maxShortfallBps` | Set by governance | 0–5,000 bps | Extra slippage per swap leg a liquidator can buy by adding its own funds. The liquidator also pays any rounding gap this way, since there is no settlement budget. Avana proposes 1,000 bps. | `Q-251`, `Q-397`; `ParameterStoreStorage.sol:86` |
| `floorRoundingAllowance` | Set by governance | > 0 and worth at most $1 | Fixed amount subtracted from the recovery floor of a liquidation, so very small liquidations settle. Avana proposes $1 worth of each debt asset. | `Q-198`, `Q-397`; `ParameterStoreRisk.sol:224` |
| `maxFlashFeeBps` | Set by governance | 0–100 bps | Highest Aave V3 flash-loan premium accepted for `deleverage` and the flash liquidation helper; `liquidate` itself takes no flash loan. Avana proposes 10 bps. | `SPEC-LIQ-015`, `Q-404`; `ParameterStoreStorage.sol:85` |
| `routeDepthThreshold` | Set by governance | > 0 | Amount of the debt asset each approved swap route must deliver within the slippage allowance in the stress case. It is a listing and monitoring criterion. Each network's listed value is under its Chain settings. | `Q-244`, `REQ-CONFIG-070` |
| `settlementReserveId` | First debt reserve enabled on the Spoke | An enabled debt reserve of the Spoke | Debt reserve whose asset a market's pending settlement is converted into, and whose First-Loss Reserve receives it. | `Q-338`, `Q-408` |
| `PENDING_SLIPPAGE_CAP_BPS` | 30 bps | — | Cap on swap slippage when value held after a liquidation is settled later. | `SPEC-LIQ-014`; `SettlementMath.sol:39` |
| `PAYOUT_TRANSFER_GAS` | 100,000 gas | — | Gas given to each payout of a liquidation (borrower surplus, Avana's fee, residues). A payout that fails is held in the payout escrow for its recipient to claim. | `Q-214`, `Q-401`; `LPVaultSwapStorage.sol:21` |
| `MAX_REPAY_TRANSFERS` | 4 | — | Most transfers used to repay a flash loan of a debt asset with a transfer fee in `deleverage`. | `Q-390`; `LPVaultSwapStorage.sol:26` |
| `MAX_RECORDS_PER_ACCOUNT_MARKET` | 16 | — | Most open positions one account holds in one market, so seizing a whole account fits within the 7.5M gas liquidation budget. | `Q-287`, `SPEC-CHAIN-001`; `AmmConstants.sol:16` |

### Oracles

| Parameter | Value | Bounds | Description | Source |
| --- | --- | --- | --- | --- |
| `twapWindow` | 1,800 s | > 0 and within the pool's observation history; on an L2 at most `sequencer.gracePeriod` | Window of the check that compares the Chainlink-implied price with the pool's time-weighted price. A hookless Uniswap v4 pool has no time-weighted price, so its market reads the window from the same pair's Uniswap v3 reference pool and also checks the v4 pool's spot price. | `Q-196`, `REQ-PSTORE-034`, `REQ-AMM-V4-005`; `09_ListMarkets.s.sol:868`, `:1074` |
| `consistencyToleranceBps` | Set by governance | 10–10,000 bps | Largest allowed gap between the pool's time-weighted price and the Chainlink-implied price; one tick is about 1 bp. Avana proposes 50 bps. | `Q-196`, `Q-394`; `ParameterStoreStorage.sol:77`, `ParameterStoreListingLogic.sol:72-76` |
| `feedHeartbeat` | Per feed, as Chainlink publishes it | 1–86,400 s | Published heartbeat of each Chainlink feed, recorded at listing. | `Q-182`; `ParameterStoreStorage.sol:79`, `ParameterStoreListingLogic.sol:168` |
| `heartbeatMargin` | Set by governance | 1–3,600 s | Margin added to a feed's heartbeat before its price counts as stale, so a late publication does not stop a healthy feed. Avana proposes 1,800 s. | `SPEC-ORC-019`, `Q-394`; `ParameterStoreStorage.sol:78` |
| `feedMaxAge`, `liquidationPriceMaxAge`, `borrowPriceMaxAge` | `feedHeartbeat` + `heartbeatMargin` | — | Oldest price a route leg, a liquidation or a borrow accepts. Because a price can be a full heartbeat old, a borrow also needs the token's second source to agree. | `SPEC-ORC-019`, `Q-274` |
| `feedAgreementMarginBps` | Set by governance | 0–10,000 bps | Margin added to the two Chainlink routes' deviation thresholds before they count as disagreeing. Avana proposes 50 bps. | `Q-184`, `Q-394`; `ParameterStoreAdminRiskLogic.sol:85` |
| `feedAgreementToleranceBps` | Per token, computed at listing | ≥ both routes' deviation thresholds + `feedAgreementMarginBps` | Allowed difference between a token's primary and alternate Chainlink routes. | `Q-184`, `Q-196` |
| `secondSource.toleranceBps` | Set by governance | 1–500 bps | Each token has an independent second price source that must agree with the served price before a borrow or a withdrawal that leaves debt. Liquidation never reads it. | `Q-287`, `Q-385`; `ParameterStoreStorage.sol:99`, `ParameterStoreAdminRiskLogic.sol:363` |
| `cachedWindow` | Set by governance | > 0 | After both routes of a token fail, the market keeps its last good price for this long before the price expires. Avana proposes 3,600 s, time for a guardian to switch to the standby route. | `Q-183`, `Q-394`; `ParameterStoreAdminRiskLogic.sol:83` |
| `disagreementPauseMax` | Set by governance | 0–3,600 s | Longest liquidation pause while the two routes disagree; after it the market counts as expired for liquidation. Avana proposes 3,600 s. | `Q-183`, `Q-199`; `ParameterStoreStorage.sol:91` |
| `graceDuration` | Set by governance | 0–7,200 s | After a price recovers from expired, only accounts below `graceHealthFactor` can be liquidated for this long, so borrowers can react to a price they could not see. Avana proposes 1,800 s. | `Q-196`, `Q-394`; `ParameterStoreStorage.sol:76` |
| `graceHealthFactor` | Set by governance | 0.90 to below 1.00 | Health factor below which accounts can be liquidated during grace. Avana proposes 0.95. | `Q-196`; `ParameterStoreStorage.sol:75`, `ParameterStoreAdminRiskLogic.sol:81` |
| `usdBandLow`, `usdBandHigh` | Set by governance | Low < $1.00 < high | LP value per $1 at peg outside which a Stable-tier market blocks new borrowing and withdrawals that leave debt. Avana proposes $0.90 and $1.02. | `Q-195`, `Q-206`; `ParameterStoreAdminRiskLogic.sol:83` |
| `STABLE_CEILING_USD` | $1.00 | — | Every USD stablecoin leg is valued at no more than $1, so a premium cannot inflate collateral. | `Q-177`; `LPPriceMath.sol:36` |
| `debtStressRiseBps` | Set by governance | 100–5,000 bps | Once a non-GHO debt asset's price expires, its last price is raised by this much, so debt that cannot be priced counts at a stress price. Avana proposes 500 bps for USDC. | `Q-247`, `Q-248`; `ParameterStoreStorage.sol:89-90` |
| `MAX_ROUTE_ANSWER` | $10,000,000,000 per token | — | Largest route price accepted, far above every listable token and small enough that price math cannot overflow. | `Q-191`; `LPPriceMath.sol:41` |

### Market registry

| Parameter | Value | Bounds | Description | Source |
| --- | --- | --- | --- | --- |
| `MAX_MARKET_COUNT` | Set at deployment | ≥ 1 | Most markets the registry ever lists on a chain, closed ones included. It is fixed when the MarketRegistry is deployed and keeps the ParameterStore's chain-wide re-check of every market within one transaction. Each network's value is under its Chain settings. | `REQ-MREG-034`; `MarketRegistryStorage.sol:184`, `MarketRegistryListingLogic.sol:187`, `contracts/script/local/lib/chain.ts:131` (#135) |
| `RiskTier` | Stable, Correlated, Volatile | — | Listing class of each Hub and CDP Spoke. A Stable-tier market may hold only USD stablecoins; Correlated pools hold tokens that track each other, and Volatile pools hold uncorrelated tokens. Each chain has one Hub, which takes Spokes of every class; its RiskTier is set to Volatile so that it accepts all of them, and each Spoke sets its own risk parameters. | `Q-058`, `REQ-CONFIG-016`; `RiskTier.sol:10-15`, `MarketRegistryListingLogic.sol:95-120`, `contracts/script/local/lib/chain.ts:110-113` (#135) |
| `MAX_POOL_TOKENS` | 8 | 2–8 | Most tokens in one market's pool. | `REQ-CONFIG-017`; `AmmConstants.sol:14-15` |
| `approvedDebtReserves` | Listed per Spoke above | The Spoke's borrowable reserves | Debt reserves each CDP Spoke offers. The drift check requires them to equal the Spoke's borrowable reserves on Aave. | `Q-233`, `REQ-HUB-101` |
| `OFFBOARD_NOTICE_SECONDS` | 432,000 s (5 days) | — | Public notice between a market's offboarding and both the Aave DAO's liquidation-threshold drop and the market's closing. | `Q-355`; `MarketRegistryStorage.sol:146` |
| `OFFBOARD_TARGET_SHARE_BPS` | 5,000 bps (50%) | — | Liquidation threshold an offboarded market is lowered to, as a share of its threshold at offboarding. The Aave DAO applies the drop once after the notice. | `Q-355`; `MarketRegistryStorage.sol:149` |

### Aave-side settings

The Aave DAO sets these values on Avana's Hub and Spokes. Avana records some of them and checks the rest.

| Parameter | Value | Bounds | Description | Source |
| --- | --- | --- | --- | --- |
| `drawCap` | Set by governance | Summed over every CDP Spoke with an enabled reserve of the asset on the Hub, covered by the asset's First-Loss Reserve at `coverageRatioBps` | Most one CDP Spoke may borrow of one debt asset. Avana reads it live from the Hub and records no line of its own; each draw cap is sized against the depth of its swap routes. Borrowing also needs idle Hub liquidity supplied through the Lend Spoke. | `SPEC-HUB-003`, `Q-407` |
| `addCap` (Lend Spoke) | Set by governance | — | Supply cap of each Lend Spoke asset, which bounds what all lenders together may supply. It is separate from the draw caps. | `REQ-HUB-017`, `Q-407` |
| `baseDrawnRate`, `rateGrowthBeforeOptimal`, `rateGrowthAfterOptimal`, `optimalUsageRatio` | Set by governance | Optimal ratio 1–99%; base + before + after ≤ 100,000 bps | Aave V4's kinked interest rate curve for each lend asset: the borrow rate rises gently up to the optimal usage and steeply past it, which draws new supply and pushes borrowers to repay. | `SPEC-HUB-007`, `Q-408` |
| `liquidityFee` (per lend asset) | Set by governance | — | Share of borrow interest on each lend asset that the Hub keeps for the Aave treasury instead of paying to suppliers. | `Q-408`; `06_AaveDeploymentPayload.s.sol` `_liquidityFee` |
| `spokeUserReservesLimit` | Set by governance | — | Most reserves one account can use on a CDP Spoke, counting its collateral reserve and its debt reserves. | `Q-193`, `Q-280` |
| `collateralRisk`, `riskPremiumThreshold` | Set by governance | Threshold ≥ highest `collateralRisk` + 1 | Aave V4 risk premium settings of each CDP Spoke and its reserves. | `Q-111`, `Q-178` |

### Keepers

| Parameter | Value | Bounds | Description | Source |
| --- | --- | --- | --- | --- |
| `KEEPER_FLOOR` | 1 | 1–32 | Fewest active committed keepers on a chain. Removing a keeper below it reverts, and new borrowing halts only while no active keeper remains; liquidation stays open to every address. | `Q-242`, `Q-400`; `LPVaultSwapStorage.sol:80`, `LPVaultSwap.sol:177` |
| `MAX_KEEPERS` | 32 | — | Most registered committed keepers per chain. | `Q-316`, `Q-400`; `LPVaultSwapStorage.sol:28` |
| `SIGNER` (liquidation keeper) | Separate keeper signer | — | Avana's liquidation keeper sends from its own signer, held in a KMS or HSM. Each chain runs one keeper, with its own signer and operator flash liquidation helper. | `REQ-HELPER-011`; `OperatorFlashLiquidator.sol:27`, `services/README.md:246`, `:261`, `:273`, `contracts/script/local/lib/keys.ts:52-54` (#135) |
| `pokeBreakers`, `pokeConfig` | Every block | — | Avana's keeper simulates the breaker and drift checks every block and sends them only when a breach or drift must be recorded. Anyone may call them. | `REQ-RISK-090`, `REQ-RISK-091`, `Q-413` |
| `MAX_SIGNERS` (AvanaGasVault) | 8 | 1–8 | Most keeper signers one gas vault refills. | `Q-413`; `AvanaGasVault.sol:32` |
| `PERIOD`, `MAX_SENDS_PER_PERIOD` | 86,400 s; 4 | — | Window of each signer's refill cap and the most refills a signer gets in it. | `Q-413`; `AvanaGasVault.sol:26-29` |
| `minBalance`, `targetBalance`, `periodCap` | Set by governance | 0 < `minBalance` ≤ `targetBalance`; `periodCap` > 0 | A signer below `minBalance` is refilled to `targetBalance`, and at most `periodCap` is sent to it in any 24 hours. They are sized from the signer's measured daily gas spend. | `Q-413`; `AvanaGasVault.sol:387` |

### Governance and timelock

| Parameter | Value | Bounds | Description | Source |
| --- | --- | --- | --- | --- |
| `SHORT_DELAY` | Per network | — | Delay of an operation whose every call is on the short-delay list: tightenings, freezes, pauses, breaker trips, standby switches, keeper removals and market activation. Each network's value is under its Chain settings. | `Q-228`, `Q-262`; `AvanaTimelock.sol:26` |
| `normalDelay` | Per network | `MIN_NORMAL_DELAY`–`MAX_DELAY` | Delay of every other operation: upgrades, listings, loosenings, fee changes, keeper additions and role changes. A loosening of a step-limited parameter moves one step at most once per normal delay. Each network's value is under its Chain settings. | `Q-228`, `Q-246`; `AvanaTimelock.sol:72`, `AvanaCoreDeploy.sol:88` |
| `MIN_NORMAL_DELAY` | Per network | — | Floor of the normal delay, long enough for borrowers to leave before any normal-delay operation executes. It is fixed when the timelock is deployed and is lower on the test networks and local development chains. Each network's value is under its Chain settings. | `Q-262`, `SPEC-GOV-015`, `REQ-ACCESS-187`; `AvanaTimelock.sol:31-36` |
| `MAX_DELAY` | 432,000 s (5 days) | — | Ceiling of the normal delay. | `Q-228`; `AvanaTimelock.sol:28` |
| `GRACE_PERIOD` | 1,209,600 s (14 days) | — | Time a ready operation stays executable; after it the operation expires. | `Q-228`; `AvanaTimelock.sol:32` |
| `publicExecution` | Per network | — | While on, any address may execute a ready operation. Each network's value is under its Chain settings. | `Q-228`; `AvanaCoreDeploy.sol:88` |
| `PROPOSER_ROLE` | Governance multisig, Aave governance executor | ≥ 2 proposers | The two proposers of timelock operations. Only the Aave governance executor cancels role changes and restoring operations. | `Q-245`, `REQ-ACCESS-156` |
| Governance multisig | Per network | At least 4 signers | Proposes and cancels operations. The intended holder is a 4-of-7 Safe with at most 3 signers from Avana Labs, from at least 3 organisations; each network's holder, and whether it is a Safe, is under Role holders on [Access Control](/developers/reference/access-controls). | `Q-114`, `Q-245`, `Q-285` |
| Emergency Guardian | Per network | — | Holds the immediate powers: freeze, pause, address freeze, breaker trips and standby route switches, plus cancel. It cannot change a parameter value. The intended holder is a 3-of-5 Safe; each network's holder is under Role holders on [Access Control](/developers/reference/access-controls). | `Q-227`, `Q-228`, `Q-241`, `REQ-ROLE-007` |
| Joint Configuration Safe (`APPLICATION_RISK_STEWARD`) | Per network | Tightenings only, plus `avanaFeeShareBps` within 0–5,000 bps | The intended holder is a 2-of-3 Safe: one Avana Labs signer, one Aave service-provider signer and an independent risk-provider seat. It can tighten ParameterStore values at once, never loosen them. Each network's holder is under Role holders on [Access Control](/developers/reference/access-controls). | `REQ-PSTORE-002`, `REQ-ROLE-117` |
| `MAX_ADDRESS_FREEZES_PER_DAY` | 20 | — | Most address freezes one caller can make in about 24 hours, so a compromised guardian cannot freeze addresses at scale. | `Q-242`; `MarketRegistryStorage.sol:130` (`_MAX_FREEZES_PER_DAY`) |
| `STANDBY_RESWITCH_COOLDOWN` | 5 days | — | After the Aave DAO undoes a standby switch, the guardians cannot switch the same token again for this long. | `REQ-MREG-028`; `MarketRegistryStorage.sol:143` (`_STANDBY_RESWITCH_COOLDOWN`) |

> Signer sets of the governance multisig, the Emergency Guardian, the Joint Configuration Safe and the Aave Protocol Guardian do not overlap. Each chain has its own Safes and timelock.

### First-Loss Reserve

Each (Hub, debt asset) has an Avana Umbrella (First-Loss Reserve), funded by Avana Labs, that covers deficits first. A DAO deficit offset funded by the Aave DAO treasury covers what remains.

| Parameter | Value | Bounds | Description | Source |
| --- | --- | --- | --- | --- |
| `firstLossReserveMinimum` | Set by governance | ≥ `coverageRatioBps` × summed draw caps / 10,000 | Minimum funded balance of each Avana Umbrella, set in the funding proposal. | `Q-236`, `Q-353`, `Q-391` |
| `coverageRatioBps` | Set by governance | 0–10,000 bps | Required coverage of each (Hub, asset): the funded balance must be at least this share of the draw caps on it, checked when a debt reserve is enabled and on every borrow of the asset, so a draw-cap raise past the cover stops new borrows of the asset until the reserve is funded or the cap is cut. 20% is an illustrative guide only. | `Q-353`, `Q-391`; `ParameterStoreListingLogic.sol:304` |
| `daoDeficitOffset` | Set by governance | ≥ 0 | Size of the Aave DAO's second loss layer for each (Hub, asset), spent only after the Avana Umbrella is empty or deactivated. | `Q-410` |
| `RESERVE_WITHDRAWAL_DELAY` | 1,209,600 s (14 days) | Must equal 14 days | Delay before unused funds can leave an Avana Umbrella or a DAO deficit offset, with DAO approval. | `Q-101`; `AvanaFirstLossReserve.sol:46`, `:101` |
| `deficitCoverageWindow` | Set by governance | — | Longest time from a recorded Hub deficit to its coverage by the Avana Umbrella. Avana proposes 72 hours; monitoring alerts on any deficit at once. | `Q-101`, `Q-394` |
| `COVERAGE_ROLE` | Emergency Guardian, Aave Protocol Guardian | — | Holders of the role that spends an Avana Umbrella to cover a deficit. | `Q-142`; `08_AaveLossLayersPayload.s.sol:53`, `:102` |
