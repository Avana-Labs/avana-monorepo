# AMM-neutral architecture: gas and denial-of-service review

Date: 2026-11-10. Scope: the proposed AMM-neutral architecture (per-Hub LPVaultSwap, MarketRegistry, ParameterStore, RiskModule, SettlementBudget, PayoutEscrow and Lock; per-CDP-Spoke LPVault and Collateralization; one LP market per CDP Spoke), read against `docs/spec/02-contracts/*`, `docs/spec/03-operations/05-liquidation.md` and the interfaces and types in `contracts/src/**`. `contracts/src` holds interfaces, types and constants only, so every gas figure below is an estimate built from known external costs and must be replaced by a fork-test measurement (each finding names the test).

## Assumptions used for the numbers

| Item | Value | Note |
|---|---|---|
| Ethereum block gas limit | 30M (as requested); 60M as a sensitivity | Mainnet raised the limit to 45M and then 60M during 2025; read the current value. |
| Per-transaction gas cap | 16,777,216 (2²⁴) | EIP-7825 (Fusaka). It binds any single liquidation or batch transaction regardless of the block limit. Confirm whether the OP Stack fork running on Base enforces it; design as if it does. |
| Base | 2 s blocks; block gas limit assumed 150M | The limit was raised repeatedly; read the current value. Typical L2 gas price 0.005–0.05 gwei plus the L1 data fee. |
| ETH price | $3,000 | Profitability scales linearly. |
| Liquidation bonus | 2 % at onset (`minLiquidationBonus` 10,200) and 5 % deep (`maxLiquidationBonus` 10,500) | `SPEC-HUB-005`. |
| Realized slippage | 0.30 % of seized value (allowance 1 %) | |
| Keeper share | 80 % of the surplus after the 20 % Avana fee | `avanaFeeShareBps = 2,000`; flash fee 0. |
| NFPM `decreaseLiquidity` + `collect` | 150k–250k per NFT | Slipstream adds an estimated 5k–20k for reward-growth bookkeeping; measure. |
| v3 swap | 100k–150k per hop | |
| GSM `sellAsset` / `buyAsset` | 100k–130k | |
| Cold account / cold slot | 2,600 / 2,100 | EIP-2929. |

## Gas model of one liquidation

Component estimates for a cold liquidation on Ethereum (`LIQ-011`…`LIQ-060` order):

| Component | GHO debt | Non-GHO debt | Basis |
|---|---|---|---|
| Base tx + calldata (~400 B) | 28k | 28k | 21k + 16 gas/byte |
| LPVaultSwap UUPS entry, Lock acquire/release, ~10 inner `LOCK.holder()` checks | 45k | 50k | cold Lock + TLOAD/TSTORE |
| Config reads: `Market` (9 slots), routes (`TokenDef` arrays), `GlobalParams` (~11 slots), market and debt-reserve params, through 3 proxied contracts | 90k | 110k | ~35 cold slots + 6 cold accounts |
| LPOracle `poke()`: up to 32 config slots, 4 Chainlink reads, TWAP `observe`, state writes | 180k | 180k | `OracleConfig` is 36 slots |
| DebtOracle `poke()` | 0 | 80k | |
| GHO flash mint + repay | 70k | 70k | mint, callback, burn |
| Debt-asset buy (`buyExactOut`) + route overhead | 0 | 160k | GSM or one v3 hop |
| Aave V4 `liquidationCall` incl. AaveOracle → LPOracle `latestAnswer` | 400k | 400k | V3 is 250k–400k; V4 adds Hub hops |
| Sell-back of unused debt asset | 0 | 140k | one swap |
| AaveAdapter burn of seized vault tokens | 30k | 30k | |
| `settleSeizure` fixed part (reconcile, totals, snapshot) | 30k | 30k | |
| **Per debited record**: list step, record writes, RiskModule exposure release, `removeLiquidity` (NFPM) | **240k** (200k–290k) | **240k** | `REQ-VAULT-053`, `REQ-VAULT-057` |
| Two settlement legs to GHO (stable pair through GSMs) | 310k | 310k | 2 × (GSM + route overhead) |
| Waterfall: budget draw, keeper and fee transfers, breaker report (`try`, ≤ 80k), events | 150k | 150k | |
| **Total, 1 record** | **≈ 1.55M** (1.2M–1.9M) | **≈ 1.95M** (1.5M–2.4M) | |
| **Fixed part (without records)** | ≈ 1.31M | ≈ 1.71M | |

A volatile pair whose token needs an extra hop (WETH → USDC → GSM) adds ~100k per such leg.

### Worst case per scenario

| Scenario | Gas | Max records in one call under 16.78M tx cap | Under 30M block | Under 60M block (still capped per tx) |
|---|---|---|---|---|
| GHO debt, k records | 1.31M + 0.24M·k | 64 (53 at 290k/record) | 119 | 64 |
| Non-GHO debt, k records | 1.71M + 0.24M·k | 62 | 117 | 62 |
| 3-token Curve pool (ERC-20 LP, no records), proportional exit | ≈ 1.8M (oracle 230k, `remove_liquidity` 200k, 3 legs 540k) | n/a | n/a | n/a |
| Same, single-coin exit | ≈ 1.3M (one leg) | n/a | n/a | n/a |
| 8-token Balancer pool, proportional exit | ≈ 3.0M (oracle ~500k, exit ~350k, 8 legs ~1.44M) | n/a | n/a | n/a |
| Batch of B one-record GHO liquidations in one tx (sequential calls, `REQ-SWAP-041`) | 1.55M + 1.25M·(B−1) (warm accounts and slots save ~300k each) | B ≤ 13 | B ≤ 23 | B ≤ 13 |

On Base the same gas applies per liquidation; with an assumed 150M block, ~95 single liquidations fit per block, so the per-transaction cap and the swap routes, not the block, are the limits.

### Keeper profitability (net of gas, per call, ETH $3,000)

Keeper income per call is `0.8 × (bonus − 0.3 % × 1.05) × D`, where `D` is the debt repaid in that call: 1.355 % of `D` at a 2 % bonus and 3.748 % at 5 %.

GHO debt (1.55M gas):

| Debt repaid `D` | 1 gwei, 2 % / 5 % | 10 gwei, 2 % / 5 % | 50 gwei, 2 % / 5 % |
|---|---|---|---|
| $500 | +$2.1 / +$14.1 | −$39.7 / −$27.8 | −$225.7 / −$213.8 |
| $5,000 | +$63.1 / +$182.8 | +$21.3 / +$140.9 | −$164.7 / −$45.1 |
| $50,000 | +$673.0 / +$1,869.4 | +$631.1 / +$1,827.5 | +$445.1 / +$1,641.5 |
| Break-even `D` | $343 / $124 | $3,431 / $1,241 | $17,156 / $6,203 |

Non-GHO debt (1.95M gas):

| Debt repaid `D` | 1 gwei, 2 % / 5 % | 10 gwei, 2 % / 5 % | 50 gwei, 2 % / 5 % |
|---|---|---|---|
| $500 | +$0.9 / +$12.9 | −$51.7 / −$39.8 | −$285.7 / −$273.8 |
| $5,000 | +$61.9 / +$181.6 | +$9.3 / +$128.9 | −$224.7 / −$105.1 |
| $50,000 | +$671.8 / +$1,868.2 | +$619.1 / +$1,815.5 | +$385.1 / +$1,581.5 |
| Break-even `D` | $432 / $156 | $4,317 / $1,561 | $21,584 / $7,804 |

With `CF_LP` = 31.2 %, a $500 debt implies about $1,600 of collateral, so a $10 pledge carries about $3 of debt. On Base at 0.05 gwei a 1.55M-gas liquidation costs about $0.23 plus the L1 data fee, so break-even `D` is about $17 at a 2 % bonus; at 1 gwei congestion, the 1-gwei column applies.

---

## Findings

| ID | Severity | Title |
|---|---|---|
| AMMN-GAS-01 | High | Seizure walks an unbounded record list; with Aave's dust rule some accounts cannot be liquidated in one transaction |
| AMMN-GAS-02 | High | `minPledgeUsd = $10` does not cover liquidation gas on Ethereum; small debts are never liquidated at normal gas prices |
| AMMN-GAS-03 | High (gate for Uniswap v4) | Uniswap v4 hooks and position subscribers can block or gas-grief liquidity removal |
| AMMN-GAS-04 | Medium | Breaker reports can be starved through the 63/64 rule, so circuit breakers never latch |
| AMMN-GAS-05 | Medium | `pokeMinGas` floor is not tied to the 63/64 bound of the feed calls it protects |
| AMMN-GAS-06 | Medium | The liquidation flow assumes GHO flash minting and GSMs that may not exist, or are small, on Base |
| AMMN-GAS-07 | Medium | Crash throughput is capped by swap-route depth, GSM capacity and the per-tx cap, not by the Lock |
| AMMN-GAS-08 | Medium | Pausable or blocklisting tokens on the shared per-Hub LPVaultSwap and shared route intermediates halt other markets |
| AMMN-GAS-09 | Medium | The Lock's immutable allowlist cannot name per-Spoke LPVaults and ledgers |
| AMMN-GAS-10 | Low | SettlementBudget reads 75 cold buckets per draw; one-market Spokes share the total window |
| AMMN-GAS-11 | Low | Small repay front-runs push a keeper's partial liquidation into Aave's dust rule |
| AMMN-GAS-12 | Low | `activeKeeperCount` has no keeper bound and is read on the borrow path |
| AMMN-GAS-13 | Low | n-token unwinds scale settlement legs and oracle reads with n |
| AMMN-GAS-14 | Low | Slipstream gauge state: unstaked-only must be enforced, and staking later adds a liveness dependency |
| AMMN-GAS-15 | Gas | Storage packing of hot structs |
| AMMN-GAS-16 | Gas | Per-Spoke immutables and cached reads |

### AMMN-GAS-01 — Unbounded record walk in seizure (High)

`REQ-VAULT-025` and `REQ-VAULT-054` put no cap on records per account-market and rely on keepers sizing `debtToCover`. Each debited record costs about 240k gas (`REQ-VAULT-057` calls NFPM once per record). Keepers cannot always size down: Aave sizes the seizure, and its dust rule (`LIQ-017`) forces a full liquidation when the leftover debt or collateral would fall below the threshold (assumed $1,000; confirm the V4 constant). The last chunk of every account is therefore seized whole.

Numbers: an account built from $10 records holds 100 records in its last $1,000, or 125 after a 20 % drop ($8 each). Gas = 1.31M + 125 × 0.24M = 31.3M, which exceeds the 16.78M per-tx cap and the 30M block. The largest last chunk that fits is 64 records (GHO) or 62 (non-GHO). An attacker on Base can build such an account for a few dollars of gas. The account then stays liquidatable but unliquidatable, and its debt becomes bad debt as prices fall. The pledge-side walk is also O(n) per insert (two cold slots, ~4.2k per step), so building n records costs O(n²): about 33M gas in total for 125 records, which is cheap on Base.

Fix: cap open records per account-market at `MAX_RECORDS_PER_ACCOUNT_MARKET` = 16 (≤ 1.31M + 16 × 0.29M = 5.95M, under 36 % of the per-tx cap even at the high per-record estimate). `pledge` reverts with `TooManyRecords` at the cap; rescue top-ups count against the cap, and a borrower adds value to an existing record via `recredit` or by merging. Add `REQ-VAULT-025` text with the bound and the gas formula. Alternatively, for fungible full-range v3 and Slipstream positions, consolidate each account-market into one vault-owned NFT at pledge time and track depositors' fees per record. That keeps one NFPM call per seizure, but it changes fee accounting.

Verification: Foundry fork test `test_gas_seizeMaxRecords` that pledges `MAX_RECORDS` records at `minPledgeUsd`, drives HF < 1 and liquidates with `debtToCover = type(uint256).max`; `vm.snapshotGasLastCall` must stay ≤ 8M on both a mainnet and a Base fork. Invariant test: `openRecordCount[proxy][vaultToken] ≤ MAX_RECORDS` across random pledge, release and seizure sequences.

### AMMN-GAS-02 — $10 minimum pledge versus liquidation gas (High)

`REQ-VAULT-025` and the RiskModule rationale say the $10 floor "keeps each record worth more than the gas to seize it". The relevant comparison is the keeper's income (`bonus × D`), not the record's value. At `CF_LP` = 31.2 %, a $10 record carries about $3 of debt and earns the keeper about $0.04 at a 2 % bonus, while one call costs $4.65 at 1 gwei. On Ethereum, break-even debt is $343–$3,431 (1–10 gwei, 2 % bonus) for GHO debt and $432–$4,317 for non-GHO debt (tables above). In a crash with 50 gwei gas, positions with debt below about $17k (2 % bonus) are not liquidated by profit-seeking keepers. The SettlementBudget's 25 GHO per-call cap does not change this, because it covers the recovery shortfall, not keeper gas.

Fix: make `minPledgeUsd`, plus a new `minDebtUsd` checked at borrow, chain-specific. Ethereum: debt ≥ $2,000, implying collateral ≥ about $7,000 at 28 % LTV. Base: $10–$50 pledge. Keep `REQ-RISK` text stating `minDebtUsd × netKeeperRate ≥ liquidationGas × gasPriceP95 × ETH` with the numbers per chain. Alternatively, fund dust liquidations from a capped per-market keeper subsidy (an Avana-run keeper paid from the SettlementBudget), with the cost stated.

Verification: a parameter Z3/Python check in `docs/spec/05-verification` asserting the inequality per chain with measured gas; a fork test measuring the 1-record liquidation gas that feeds the check.

### AMMN-GAS-03 — Uniswap v4 hooks and subscribers on removal (High, gate before listing v4)

A v4 pool hook with `BEFORE_REMOVE_LIQUIDITY`, `AFTER_REMOVE_LIQUIDITY` or `AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA` permission runs inside every seizure. It can revert, which blocks all liquidations of the market; burn unbounded gas, which pushes the seizure past the per-tx cap; or take a delta from the removed tokens, which lowers recovery. A v4 position can also have a subscriber (`PositionManager` notifier) whose `notifyModifyLiquidity` call can revert the removal. Swap hooks on v4 pools used as settlement routes can likewise revert or burn gas.

Fix: list only v4 pools whose hook address has none of the remove-liquidity flag bits set (checked from the address bits at listing and stored per market), or an allowlisted immutable hook whose removal gas is measured; require `!hasSubscriber(tokenId)` at pledge, and the vault never calls `subscribe`. For v4 swap routes, allowlist hook-free pools only.

Verification: listing unit tests with mock hooks for each flag (expect `ListingCheckFailed`); a fork test with a gas-burning subscriber (expect pledge to fail); gas snapshot of a v4 seizure.

### AMMN-GAS-04 — Breaker reports starved by the 63/64 rule (Medium)

LPVaultSwap calls `recordLiquidationOutcome` and `recordRecoveryShortfall` as `try … {gas: BREAKER_RECORD_GAS}` (80,000) and continues on failure (`BreakerRecordFailed`). The EVM forwards at most 63/64 of the remaining gas. A keeper, or any caller of `liquidatePermissionless`, can set the transaction gas so that less than 80k remains at that point. The report then fails while the liquidation succeeds. Repeating this keeps `SEIZURE_SURGE`, `PRICE_DROP` and `ROUTE_FAILURES` from ever latching, so the breakers are suppressed during the exact event they exist for.

Fix: before each gas-limited `try`, require `gasleft() ≥ BREAKER_RECORD_GAS × 64 / 63 + POST_CALL_GAS` and revert with `InsufficientGas` otherwise. Do the same for `PAYOUT_TRANSFER_GAS` (100k), where starving only diverts the remainder to the escrow, and for `ISSUER_PROBE_GAS` (30k).

Verification: Foundry test that binary-searches the tx gas limit for `liquidate` and asserts that at every limit where the call succeeds, the breaker window was updated (`BreakerWindow.unitsSeized` increased).

### AMMN-GAS-05 — `pokeMinGas` floor versus 63/64 (Medium)

`REQ-ORACLE-024` requires `gasleft() ≥ pokeMinGas` at entry and after every caught failure. A feed call that runs out of gas returns with at least 1/64 of the gas it was given remaining in the caller. The post-failure check proves the feed had enough gas only if `63 × pokeMinGas ≥ maxFeedGas`, and the poke must also finish its remaining legs and writes. With 4 feed reads, a TWAP read and writes, the rest of the poke needs about 120k.

Fix: give every feed and pool read an explicit `{gas: FEED_CALL_GAS}` (for example 50k), require `gasleft() ≥ FEED_CALL_GAS × 64/63 + REMAINING_POKE_GAS` before each call, and set `POKE_MIN_GAS_FLOOR ≥` the measured full-poke gas. State the formula in `REQ-ORACLE-024` and `REQ-ACCESS-051`.

Verification: fuzz test of `poke()` over the tx gas limit: every successful poke with a recorded failure must also succeed with a recorded failure at a gas limit 2M higher (no failure caused by gas alone); gas snapshot of the worst-case poke (both routes failing over to the alternates).

### AMMN-GAS-06 — GHO flash mint and GSM on Base (Medium; High if absent)

The decided flow flash-mints GHO, settles every leg to GHO and draws a GHO SettlementBudget. On Ethereum, `GhoFlashMinter` and the GSMs exist. On Base, GHO arrives through a bridge facilitator; whether a flash-mint facilitator or GSM with enough capacity exists must be checked. Without them, step 1 cannot run, and conversion to GHO relies on thin DEX pools, so every Slipstream liquidation competes for the same small GHO liquidity.

Fix: before listing on Base, confirm on a fork that a GHO flash-mint facilitator exists and its bucket capacity is at least the largest single liquidation, and that the GHO/USDC route depth meets the recovery floor at the market's caps. Otherwise specify a Base liquidation funding source, such as an Aave flash loan of the debt asset, settled in the debt asset.

Verification: Base fork test of a full liquidation of a capped-size position with the settlement routes in force; assert `R ≥ minGho`.

### AMMN-GAS-07 — Liveness in a 20 % crash (Medium)

The Lock does not serialize liquidations. It is transient (EIP-1153) and released at the end of each call, so separate transactions never contend for it, and sequential calls in one keeper transaction each acquire and release it. Shared per-Hub state does not cap throughput either: SettlementBudget draws are optional, and caller top-up exists. The limits are:

- Gas: about 1.25M–1.55M per call gives about 19 calls per 30M block (38 at 60M), at most 13 per transaction (per-tx cap), and about 95 per 2 s block on Base at 150M. With keepers getting 30 % of blockspace, Ethereum processes about 6 per block. A crash with N = 20 markets × 500 accounts × 30 % liquidatable × 2 calls each (target-HF partials) = 6,000 calls takes about 1,000 blocks (3.3 h) on Ethereum and about 10 minutes on Base.
- Swap routes: all liquidations of a market sell the same token into the same route. The per-leg oracle `minOut` (100 bps) fails once the cumulative in-block price impact exceeds the allowance minus the price change already absorbed. Per block, the sellable volume is about the route's depth at 1 % minus the arbitrage refill per block. GSMs fill to their exposure cap, after which the backup route takes over.
- GHO flash-mint bucket capacity is shared per chain across all Hubs. A call larger than the capacity reverts, and keepers must split it.

Fix: add a liveness section to the spec with these formulas and per-market inputs (route depth at 1 %, GSM headroom, calls per account), and size `marketUsdCap` so that the capped market liquidates within the oracle's `liquidationPriceMaxAge` at the 95th-percentile gas share. Provide a keeper batch entry point or documented multicall so warm-state savings apply.

Verification: a simulation (`SIM-*`) replaying a 20 % drop over N markets with measured per-call gas and route depth curves, asserting that the queue drains within the bound; a fork test of 13 sequential liquidations in one tx under 16.78M.

### AMMN-GAS-08 — Token behaviour on shared per-Hub contracts (Medium)

- Pause (USDC, USDT): NFPM `collect` to LPVaultSwap reverts, so every market holding the token stops liquidating, as expected. Volatile markets whose settlement route passes through USDC (WETH → USDC → GSM) also stop, although they do not hold USDC. Fix: require primary and alternate routes of each token to share no intermediate token, and check this at `setRoute`.
- Blocklist: if the issuer blocklists the per-Hub LPVaultSwap address, settlement of every market of the Hub holding that token stops, because `collect` names LPVaultSwap as recipient. Fix: document the UUPS migration path, and allow `removeLiquidity` to send to a per-Spoke settlement receiver set at deployment. Borrower-address blocklists are handled by the escrow (`REQ-SWAP-030`).
- USDT `approve`: routes use exact approvals reset to 0 (`LIQ-019`), which is correct. Require `SafeERC20.forceApprove`, because USDT returns no `bool` and reverts on nonzero-to-nonzero changes.
- ERC-777-style hooks: borrower in-kind transfers are capped at 100k and fall back to the escrow; the Lock blocks reentry. Reject tokens with an ERC-1820 `ERC777Token` implementer at listing.

Verification: fork tests with USDC `pause()` (impersonating the pauser) and `blacklist(LPVaultSwap)`, asserting which markets still liquidate; a listing test for an ERC-777 mock; a unit test that USDT approvals use `forceApprove`.

### AMMN-GAS-09 — Lock allowlist versus per-Spoke custody (Medium)

`REQ-LOCK-018` requires constant gas with "at most four immutable comparisons", and the Lock stores single `COLLATERALIZATION` and `LP_VAULT` immutables. Under the proposal, every CDP Spoke has its own LPVault and Collateralization, so a per-Hub Lock cannot name them as immutables. A storage registry adds one cold SLOAD (2.1k) per check, and a per-Spoke Lock would not see call trees that cross Spokes through the shared AaveAdapter and LPVaultSwap.

Fix: keep one Lock per Hub with the Adapter and LPVaultSwap as immutables. Recognize custody contracts by CREATE2 address: the Lock recomputes `address(keccak256(0xff, FACTORY, salt(spokeId), INIT_CODE_HASH))` from a caller-supplied `spokeId`. This stays constant gas (~1k) with no storage. Update `REQ-LOCK-018`.

Verification: unit tests that a vault from another factory or another salt is refused; gas snapshot of `acquire` ≤ 3k.

### AMMN-GAS-10 — SettlementBudget bucket reads and shared window (Low)

`SPEC-SET-003` sums 25 hourly buckets for three windows (reserve, total and market), so each draw reads 75 cold slots, about 160k gas. With one market per Spoke, the market sub-cap floor (`MIN_MARKET_WINDOW_CAP`, 100 GHO) times 200 markets exceeds `PER_24H_CAP_MAX` (20,000 GHO). Dust in many markets can therefore exhaust the shared total, after which keepers must top up.

Fix: keep a running window sum per key and subtract buckets as they expire (amortized O(1)), or pack buckets as `uint128` pairs to halve the reads. Bound `Σ market sub-caps ≤ PER_24H_CAP_MAX` at listing, or document the contention.

Verification: gas snapshot of `draw` ≤ 40k; equivalence fuzz test of the running sum against the 25-bucket sum.

### AMMN-GAS-11 — Repay front-runs and the dust rule (Low)

A 1-wei repay changes `D` slightly, so a keeper whose `minPayout` has no tolerance reverts. A larger repay that brings the leftover just under Aave's dust threshold turns a partial `debtToCover` into a `MustNotLeaveDust`-style revert. The borrower can repeat this every block at the cost of a small repay. The Lens adds `LENS_DUST_MARGIN_BPS` (500), which helps only if keepers use it.

Fix: keepers set `debtToCover` either at least 5 % below the dust boundary or as a full close, and set `minPayout` with at least 1 % tolerance. Use private order flow on Ethereum. Spec text in `LIQ-011`.

Verification: fork test in which a front-running repay precedes a Lens-sized liquidation; it must still succeed.

### AMMN-GAS-12 — Keeper list bound (Low)

`activeKeeperCount()` counts approved keepers that are not frozen, and freezes live in the MarketRegistry, so the count is O(K) cross-contract reads. The RiskModule reads it on borrow pre-checks. `getKeepers()` returns an unbounded array.

Fix: `MAX_KEEPERS = 32` in `addKeeper`, or maintain the count incrementally through a `notifyFreeze` call.

Verification: gas snapshot of `preBorrowCheck` with 32 keepers; unit test that `addKeeper` reverts above the cap.

### AMMN-GAS-13 — n-token unwinds (Low)

Curve and Balancer positions are ERC-20, so there is one unwind per liquidation (no record walk). Settlement legs and oracle feeds scale with n: about 1.8M gas for 3 tokens and about 3.0M for 8 tokens. Native-ETH Curve pools send ETH to LPVaultSwap.

Fix: prefer single-token exits (`remove_liquidity_one_coin`, Balancer single-token exit) with the oracle floor applied to the one output, which costs about 1.3M; cap n per market type; require `receive()` to accept ETH only while the Lock is held.

Verification: fork gas snapshots per AMM type, checked against a stated per-type gas budget.

### AMMN-GAS-14 — Slipstream gauge state (Low)

Unstaked-only holds because the LPVault owns the NFT and never stakes it. The LPVault must never call `approve` or `setApprovalForAll` on the Slipstream NFPM, and `pledge` must reject an NFT whose owner is a gauge. If staked positions are supported later, each seizure adds a gauge `withdraw` (estimated 100k–150k per record), and a killed or paused gauge can block seizure.

Fix: state both rules in the Slipstream intake path, and put any later staking behind a per-market flag with a gauge-failure fallback.

Verification: fork test on Base of a seizure of an unstaked Slipstream position, with a gas snapshot; unit test that the vault holds no NFPM approvals.

### AMMN-GAS-15 — Storage packing (Gas)

| Struct | Now | Packed | Saving |
|---|---|---|---|
| `BackingRecord` + `listNext`/`listPrev` mappings | 8 + 2 slots | 5: `tokenId uint96 + depositor`; `proxy + pledgedAt uint40 + lastDebitedAt uint40 + inList`; `credited + originalUnits`; `originalUsdCharge + currentUsdCharge`; `rescueUnits uint128 + next uint64 + prev uint64`. Drop `vaultToken` (one market per ledger). | ~110k per pledge (5 fresh slots fewer); ~5k per debited record |
| `Market` | 9 slots | Per-Spoke immutables (GAS-16), plus 1 slot `status + registeredAt + activatedAt` | ~17k per full read, read 3–4 times per liquidation |
| `OracleLeg` | 4 slots | 2: `aggregator + decimals + feedMaxAge + deviation + 2 ages` (31 B); `minAnswer int128 + maxAnswer int128` | `OracleConfig` 36 → 20 slots, ~34k per cold poke |
| `GlobalParams` | ~11 slots | 5 with `uint64` health factors and bands and `uint128` GHO amounts | ~13k per cold full read |
| `PledgeCounters` | 5 slots | 3 (`uint128` pairs) | ~4k per record release |
| `BreakerWindow` | 2 slots | 1 (`uint64 + uint88 + uint88 + uint16`) | 2.1k per report |
| `ProxyMarket[]` in PositionProxy | dynamic array | one `ProxyMarket` slot pair (one market per Spoke) | removes a length slot and the loop |

Calldata and memory structs (`LiquidationParams`, `SettlementReport`, `LiquidationResult`) do not need packing.

Verification: `forge inspect <Contract> storageLayout` checked in CI against the packed layout, and `forge snapshot --diff` on pledge and liquidation.

### AMMN-GAS-16 — Immutables and cached reads (Gas)

With one market per CDP Spoke, pool, tokens, vault token, LPOracle, reserve IDs, decimals and AMM-specific fields (`fee`, `tickSpacing`) are fixed per Spoke. Deploy the per-Spoke LPVault and Collateralization as clones with immutable arguments, and have LPVaultSwap read the market once and pass a `MarketContext` to trusted Avana callees instead of each re-reading the MarketRegistry and ParameterStore. This also takes v3-specific fields out of the shared `Market` struct, which the AMM-neutral split needs anyway. Estimated saving: 50k–80k per liquidation and 20k–40k per borrow.

Verification: gas snapshot comparison, plus a test that every callee rejects a `MarketContext` whose hash does not match the registry's stored commitment.

## Checked with no finding

| Vector | Result |
|---|---|
| NFT spam to the LPVault | `REQ-VAULT-078`: canonical NFPM only, records nothing; no storage growth. For v4 and Slipstream, keep the same rule per NFPM. |
| PayoutEscrow claims | `mapping(token => mapping(borrower => uint256))`; written only by liquidations; no iteration. |
| Lens | Paged at 200 records (`REQ-LENS-011`); `getAccount` does not loop over records. |
| Spoke iteration in drift checks | `REQ-ADAPTER-031` requires exactly 2 Spokes on each vault-token asset; no Hub-wide Spoke loop on hot paths. `MarketRegistry.getSpokes()` is an unbounded view; keep it off-chain only. |
| Proxy creation | CREATE2 per wallet × Spoke; mapping only. |
