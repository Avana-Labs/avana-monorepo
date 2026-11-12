# AMM-neutral design review: final re-check

Date: 2026-11-10. Scope: every finding of [report.md](report.md) (`AMMN-RT`, `FLOW`, `GAS`, `INT`, `ARCH`, `SM`) and `FINDING-286`…`FINDING-292` of [5.3](../../../spec/05-verification/03-audit-findings.md), checked against the rewritten spec pages and the interfaces in `contracts/src`. No Solidity implementation exists, so every status is a spec-stage result.

Method: for each finding, the resolving rule and decision IDs come from the 5.3 entry (`FINDING-201`…`FINDING-292`). Each rule was located where it is defined (2.x, 3.x, 4.x and 1.x pages) and, where an interface exists, in `contracts/src`. The original exploit was then re-run against the new text. The ten focus items and the three new attacks were traced end to end. The other findings were checked for rule existence, specificity, and conflicts with the pages they touch.

Status meanings:

- **RESOLVED:** the rule exists, it is specific, and the original scenario no longer works.
- **WEAK:** a rule exists, but it has a loophole or conflicts with another page or an interface.
- **OPEN:** no rule closes the finding.

## Summary

| Status | Count |
|---|---|
| RESOLVED | 75 |
| WEAK | 14 (10 distinct issues after merging duplicates) |
| OPEN | 0 |
| New attacks | 4 (1 Medium, 3 Low; one of the Low items is the same issue as RT-13) |

**Spec-stage security score at the re-check: 96.5 / 100.** The deductions are listed in [Score](#score). **After the [fix pass](#fix-pass): 99.0 / 100**, with no WEAK or OPEN item ([re-score](#re-score-after-the-fix-pass)). **After the [parameter decisions](#parameter-decisions-2026-11-10): 98.0 / 100**, with FLOW-16 and an in-kind removal residual accepted ([re-score](#re-score-after-the-parameter-decisions)).

## Results per finding

Each FINDING number is the 5.3 entry that resolves the finding (RT-01…16 → 201…216, FLOW-01…26 → 217…242, GAS-01…16 → 243…258, INT-01…08 → 259…266, ARCH-01…10 → 267…276, SM-01…06 → 277…282).

| ID | Status | Resolving IDs | Reason |
|---|---|---|---|
| AMMN-RT-01 | RESOLVED | `REQ-AMM-CORE-006`, `REQ-VAULT-009`, `SPEC-BACK-001`, `REQ-COLL-024`, `INV-005`; `Q-359` | `IAmmIntegration.receivePosition` (`RangeMismatch`/`PoolMismatch`) and the v3 and Slipstream pages require exact `tickLower`/`tickUpper` equality and the factory-derived pool, so a `[−1, 1]` NFT cannot enter a `[−50, 50]` market. Two notes. Collateralization's "independent" re-check (`marketOfPosition == vaultToken.marketId()`) only echoes the `marketId` it passed in. The error name differs between pages: `RangeMismatch` in 2.19, 2.20 and `ILPVaultErrors`, `ShapeMismatch` in `REQ-VAULT-103/104`, `REQ-AMM-V3-009` and `REQ-AMM-SLIP-018`. |
| AMMN-RT-02 | RESOLVED | `SPEC-ORC-006`, `SPEC-ORC-009`, `SPEC-AMM-CORE-001`, `INV-078`, `REQ-ORACLE-104`; `Q-359`, `Q-363` | The oracle sqrt price is clamped to `[s_a, s_b]` and amounts are floored, then reduced by 1 raw unit. The 1.05-ratio depeg now prices at the one-token holding ($9.52, not $28.45). Spot is never read. |
| AMMN-RT-03 | WEAK | `REQ-RISK-078`, `REQ-VTOKEN-006`, `REQ-VTOKEN-025`, `REQ-ADAPTER-029`, `INV-093`, `ATTACK-155`; `Q-362`, `Q-281` | The exposure is understated. `ATTACK-155` and 4.3 bound it to "the block of the change", but `CONFIG_DRIFT` stops only Avana's own new activity. It cannot stop a third party's `liquidationCall(..., true)` or that party's direct Spoke borrow against the shares, so the exposure lasts until Aave reverts the flag. 4.3 (Aave Spoke row) also still says the token admits "Hub to AaveAdapter", which `REQ-VTOKEN-006` forbids. |
| AMMN-RT-04 | RESOLVED | `REQ-PROXY-050`, `REQ-PROXY-052`, `REQ-PROXY-101`, `INV-064`, `INV-065`; `Q-359` | `IPositionProxy` has no implementation slot, upgrade or migration. Its salt is `(wallet, spoke, marketId)`, so no implementation can be chosen and no second proxy can exist. |
| AMMN-RT-05 | WEAK | `REQ-COLL-026`, `REQ-RISK-079`, `SPEC-CAP-005`, `INV-092`; `Q-361` | The token and depositor caps are one counter per Hub. The pool-share cap is still per market (`vaultToken.totalSupply()` against the market's own depth). Several ranges of one pool are separate markets (`REQ-VTOKEN-021`), so k ranges give Avana up to k × `poolShareMaxBps` of the pool's active liquidity. FINDING-205 says the pool share is "keyed by Hub", which is not what the rules say. |
| AMMN-RT-06 | RESOLVED | `REQ-AMM-V4-001`, `REQ-AMM-CORE-004`; `Q-363`, `Q-302` | v4 is not listed. The readiness rule requires a hook allowlist with no remove hooks or deltas, and refuses positions with a subscriber. |
| AMMN-RT-07 | RESOLVED | `REQ-AMM-CURVE-002`, `REQ-AMM-BAL-002`, `REQ-AMM-CORE-012`, `REQ-AMM-CORE-014`; `Q-363` | Not listed at launch. The guards are specific: a reentrancy-lock read, `getReserves`, effective supply, and a per-block quote-change cap. |
| AMMN-RT-08 | RESOLVED | `SPEC-ORC-022`, `REQ-PSTORE-027`, `REQ-AMM-SLIP-013`; `Q-365` | The buffer is `⌈W / CHAIN_BLOCK_TIME⌉ + 1` (901 on Base), so dust swaps cannot roll the window. |
| AMMN-RT-09 | RESOLVED | `REQ-ROUTE-006`, `INV-083`; `Q-363` | Route stress uses the full value V as a single token at each range edge. |
| AMMN-RT-10 | RESOLVED | `REQ-PROXY-052`, `REQ-PROXY-055`, `INV-064`; `Q-359` | One Adapter per chain, the market in the salt, and `deployProxy` callable by the Adapter only. |
| AMMN-RT-11 | RESOLVED | `INV-094`, `REQ-CONFIG-081`, `INV-057`; `Q-360` | Cross-Hub lines are off at launch. The funding Hub owns the cap and one registry sums the lines. |
| AMMN-RT-12 | RESOLVED | `REQ-ADAPTER-031`, `REQ-VTOKEN-020`, `REQ-VTOKEN-021`, `INV-003`; `Q-359`, `Q-362` | One Spoke per vault-token asset, checked at listing and by the drift check. The Adapter and LPVaultSwap read the Spoke from the token. |
| AMMN-RT-13 | WEAK | `INV-097`, `SPEC-SET-003`, `SPEC-SET-006`, `REQ-BUDGET-002`; `Q-362` | The windows are partitioned per market, but the balance is shared (`remainingToday` includes `available(T)`). `INV-097` says "sum of every market's window cap ≤ balance" and "no sequence of draws for one market lowers the room of another", yet nothing on-chain enforces it; only off-chain top-ups (`REQ-BUDGET-005`) do. See N3. |
| AMMN-RT-14 | RESOLVED | `REQ-READY-001`; `Q-363`, `Q-365` | Not listed at launch. The listing rule covers market hours, corporate actions and holder allowlists. |
| AMMN-RT-15 | RESOLVED | `REQ-CONFIG-075`, `REQ-AMM-V3-002`, `REQ-AMM-SLIP-006`; `Q-359` | Listing checks the NFPM/factory/pool pairing and the pool code hash on-chain. |
| AMMN-RT-16 | RESOLVED | `INV-065`, `REQ-PROXY-050`; `Q-359` | No migration exists. |
| AMMN-FLOW-01 | WEAK | `INV-091`, `INV-054`, `REQ-LOCK-004`, `REQ-LOCK-028`; `Q-362` | `ILock` and `REQ-LOCK-028` are correct: two members, callee-side checks. `INV-091` conflicts with them: "every value-moving entry point of every LPVault … reverts unless `msg.sender` is a Lock member", while `IAmmIntegration` requires `msg.sender == COLLATERALIZATION`. Built literally, `INV-091` makes every flow revert again. `INV-054` also says `releaseZeroCredit`/`collectFees` "check that it is free and hold it", which non-members cannot do. |
| AMMN-FLOW-02 | RESOLVED | `INV-095`, `REQ-FLASH-001`…`010`, `REQ-SWAP-012`; `Q-362`, `Q-365` | The Aave V3 Pool flash-lends the debt asset on both chains, with a caller-funded fallback. GHO on Base is sized to about 0.13M of flash liquidity. |
| AMMN-FLOW-03 | RESOLVED | `INV-098`, `REQ-CHAIN-003`, `REQ-ORACLE-099`, `SPEC-ORC-021`; `Q-362`, `Q-364` | Sequencer feed and grace period. An unknown status blocks borrowing only. |
| AMMN-FLOW-04 | RESOLVED | `INV-065`, `REQ-PROXY-050`, `REQ-ARCH-177`; `Q-359` | The beacon and migration are removed. |
| AMMN-FLOW-05 | RESOLVED | `INV-094`, `INV-071`; `Q-360` | Each debt reserve records its funding Hub. Pending value goes to that (Hub, asset)'s Coverage Spoke. |
| AMMN-FLOW-06 | RESOLVED | `INV-094`, `REQ-RISK-082`, `SPEC-CAP-010`; `Q-360` | The registry sum is checked on-chain at `enableDebtReserve` and at every cap change. |
| AMMN-FLOW-07 | RESOLVED | `INV-064`, `INV-075`, `REQ-ARCH-207`; `Q-359` | Several markets per Spoke, with one proxy per (Spoke, market). |
| AMMN-FLOW-08 | RESOLVED | `INV-005`, `INV-078`, `SPEC-UNIT-001`; `Q-359` | Bounded-range math, the exact shape, and caps per shape. |
| AMMN-FLOW-09 | RESOLVED | `REQ-SWAP-025`, `LIQ-082`, `LIQ-023`, `SPEC-ORC-007`, `INV-078`; `Q-363`, `Q-350` | With no spot gate, a spot move only changes the token mix. The oracle-ratio composition is the minimum over all spots, and this holds out of range too because the value is monotone towards the clamped edge. Per-leg `minOut`, the shortfall top-up and automatic in-kind settlement bound the swap side. The text overclaims slightly: "never reverts" ignores a route sandwich beyond `minOut`, which falls back to the backup route and then to in-kind settlement. |
| AMMN-FLOW-10 | RESOLVED | `REQ-AMM-SLIP-001`…`003`, `REQ-AMM-SLIP-009`, `REQ-AMM-SLIP-018`; `Q-365` | Slipstream decoders, pool lookup by `tickSpacing`, three NPM/factory generations, and unstaked NFTs only. |
| AMMN-FLOW-11 | WEAK | `REQ-VTOKEN-020`, `REQ-VTOKEN-021`, `REQ-VTOKEN-028`, `REQ-CONFIG-007`, `REQ-MREG-030`; `Q-359` | 2.4 keys tokens by (Spoke, market key). 2.8 still says "the vault-token factory's registry maps each pool to one token for life and rejects a second" (`REQ-CONFIG-007`) and reserves the `marketId` "for its pool" (`REQ-MREG-030`). `marketOfKey` excludes the Spoke, and a Closed market is "not cancelled", so the relisting on another Spoke that `REQ-VTOKEN-020` promises is refused with `DuplicateMarketKey`. |
| AMMN-FLOW-12 | WEAK | `EMG-052`, `EMG-064`, `INV-081`; `Q-365`, `Q-346` | Documented as Aave-side containment. The scenario still works (an Aave halt stops repay, withdraw and liquidation). report.md itself keeps a residual Medium. |
| AMMN-FLOW-13 | RESOLVED | `INV-093`, `REQ-ADAPTER-028`…`036`, `REQ-VTOKEN-025`; `Q-362` | The Spoke type is decided: standard Spoke, 5-argument `liquidationCall`, `receiveShares = false`. |
| AMMN-FLOW-14 | RESOLVED | `INV-070`, `INV-083`, `REQ-ROUTE-001`, `REQ-ROUTE-002`, `REQ-ROUTE-006`; `Q-362`, `Q-363` | Direct swaps into the debt asset, with route rules per token class. |
| AMMN-FLOW-15 | RESOLVED | `INV-071`, `REQ-HUB-103`, `DEF-015`, `DEF-020`; `Q-360`, `Q-365` | The Coverage Spoke covers first. The Aave-side remainder is stated and published per Spoke. |
| AMMN-FLOW-16 | WEAK | `REQ-RISK-080`, `REQ-ADAPTER-095`, `INV-092`; `Q-361` | `releaseIdle` applies only after `idleBookingSeconds` with no debt. One small borrow keeps the whole charge in `Regular`. Sybil wallets can still fill `marketUsdCap` for the interest on token debts. |
| AMMN-FLOW-17 | RESOLVED | `REQ-CHAIN-002`, `REQ-ARCH-034`; `Q-359` | Every contract has a stated scope. |
| AMMN-FLOW-18 | RESOLVED | `REQ-PROXY-052`, `REQ-PROXY-055`; `Q-359` | Same as RT-10. |
| AMMN-FLOW-19 | RESOLVED | `INV-049`, `REQ-CHAIN-001`, `REQ-CHAIN-002`, `REQ-ARCH-153`; `Q-361` | Controls are per chain and keyed by Hub. A borrow reads both the home and funding Hub pause. |
| AMMN-FLOW-20 | RESOLVED | `REQ-ORACLE-101`, `INV-093`; `Q-362` | The oracle source is drift-checked. The breaker stops new activity only. |
| AMMN-FLOW-21 | RESOLVED | `REQ-CONFIG-077`, `REQ-ARCH-207`, `REQ-ARCH-209`; `Q-359` | Listing rules are per integration. |
| AMMN-FLOW-22 | RESOLVED | `REQ-CONFIG-080`, `MKT-057`, `INV-045`; `Q-363` | `stepWindDown` ramps the LT, so wind-down ends. A vault defect exits through a new `integrationId` (new key). The relisting conflict is counted under FLOW-11. |
| AMMN-FLOW-23 | RESOLVED | `SPEC-LIQ-022`, `REQ-SWAP-026`, `REQ-SWAP-027`; `Q-363`, `Q-337` | `B = max(0, S − G)`, in the waterfall. |
| AMMN-FLOW-24 | RESOLVED | `INV-002`, `INV-006`, `REQ-COLL-006`, `REQ-COLL-027`; `Q-359` | `positionKey` + `integrationId`, n-token arrays. |
| AMMN-FLOW-25 | RESOLVED | `INV-048`, `REQ-CHAIN-002`; `Q-359` | One keeper floor per chain. |
| AMMN-FLOW-26 | RESOLVED | `REQ-SWAP-106`, `REQ-SWAP-116`, `INV-089`; `Q-363`, `Q-347` | Allowed under `Paused(General)`. |
| AMMN-GAS-01 | RESOLVED | `INV-096`(a), `REQ-AMM-CORE-015`, `LIQ-022`; `Q-362` | 16 records, worst case at most 8M gas at listing. The numbers disagree (0.29M per record in FINDING-243, 0.24M in `LIQ-022`/`REQ-AMM-CORE-015`), but both fit. A third party cannot add records to another account. |
| AMMN-GAS-02 | WEAK | `INV-096`(b), `SPEC-CHAIN-001`, `SPEC-CAP-009`, `LIQ-087`; `Q-362`, `Q-311` | The minimum debt is sized from the one-record gas `G(1) = 1.55M`, while the 16-record bound allows `G(16) = 5.15M`, so an account at the minimum with 16 records costs a third-party keeper more gas than it pays. That contradicts `LIQ-087` "economic for every account". |
| AMMN-GAS-03 | RESOLVED | `REQ-AMM-V4-001`; `Q-363` | Same as RT-06. |
| AMMN-GAS-04 | RESOLVED | `REQ-SWAP-103`, `REQ-SWAP-104`, `SPEC-ORC-023`; `Q-367` | 64/63 guard before each gas-limited `try`. |
| AMMN-GAS-05 | RESOLVED | `SPEC-ORC-023`, `REQ-ORACLE-102`; `Q-367` | Stipend per read and a floor of at least the measured gas. |
| AMMN-GAS-06 | RESOLVED | `INV-095`, `REQ-FLASH-001`…`006`; `Q-362`, `Q-365` | Same as FLOW-02. |
| AMMN-GAS-07 | RESOLVED | `SPEC-LIQ-021`, `REQ-SWAP-118`, `INV-096`, `INV-097`; `Q-367` | `marketUsdCap` is sized to route depth, flash liquidity and the record bound. |
| AMMN-GAS-08 | RESOLVED | `REQ-ROUTE-003`, `REQ-ROUTE-005`, `REQ-SWAP-064`, `EMG-063`; `Q-367` | No shared route intermediate, with an in-kind fallback for blocked tokens. |
| AMMN-GAS-09 | WEAK | `INV-091`, `REQ-VAULT-150`; `Q-362` | Duplicate of FLOW-01 (`INV-091` caller wording). |
| AMMN-GAS-10 | RESOLVED | `SPEC-SET-003`, `INV-097`; `Q-362` | Running sums, constant slots. |
| AMMN-GAS-11 | RESOLVED | `REQ-SWAP-005`, `ATTACK-057`; `Q-367` | Keeper sizing margin and private order flow. |
| AMMN-GAS-12 | RESOLVED | `REQ-SWAP-107`; `Q-367` | `MAX_KEEPERS = 32`. |
| AMMN-GAS-13 | RESOLVED | `REQ-AMM-CORE-015`, `REQ-AMM-CURVE-005`; `Q-367` | n is capped, with a single-token exit for wide pools. |
| AMMN-GAS-14 | RESOLVED | `REQ-AMM-SLIP-009`; `Q-365` | Staked NFTs are refused. |
| AMMN-GAS-15 | RESOLVED | `SPEC-BACK-016`, `REQ-VAULT-015`; `Q-367` | 5-slot record, layout checked in CI. |
| AMMN-GAS-16 | RESOLVED | `REQ-CONFIG-005`; `Q-367` | Per-market immutables and a context hash. |
| AMMN-INT-01 | WEAK | `SPEC-ORC-019`, `REQ-ORACLE-054`, `REQ-ORACLE-100`, `SPEC-ORC-020`, `REQ-PSTORE-028`; `Q-364` | The heartbeat failure is closed: 84,600 to 88,200 s limits, and stablecoins are listable. The second source is now a single gate on borrowing, though. One `secondSource` per token, replaceable only at the normal delay (`setSecondSource`, 5 days) and with no standby. If USDC's second source fails, every borrow and withdraw-with-debt involving USDC on the chain stops, which is every launch Stable market. Liquidation is unaffected. The pages also conflict: `EMG-103` says the market becomes "not Live", which `REQ-ORACLE-100` forbids, and `EMG-002` names `feedAgreementToleranceBps` where `SPEC-ORC-020` uses `secondSource.toleranceBps`. |
| AMMN-INT-02 | RESOLVED | `REQ-ROUTE-011`, `EXT-013`; `Q-365` | GSM is not a primary route, and seized GSMs are refused. |
| AMMN-INT-03 | RESOLVED | `INV-070`, `REQ-ROUTE-031`; `Q-362` | The buy leg is removed. |
| AMMN-INT-04 | RESOLVED | `INV-093`, `REQ-CONFIG-074`; `Q-362` | Standard 5-argument Spoke. |
| AMMN-INT-05 | RESOLVED | `INV-095`, `REQ-FLASH-001`; `Q-362` | Same as FLOW-02. |
| AMMN-INT-06 | RESOLVED | `INV-098`, `REQ-ORACLE-099`; `Q-362`, `Q-365` | Same as FLOW-03. |
| AMMN-INT-07 | WEAK | `INV-093`, `REQ-RISK-078`, `REQ-VTOKEN-006`; `Q-362` | Duplicate of RT-03. |
| AMMN-INT-08 | RESOLVED | `EXT-001`, `REQ-HUB-063`; `Q-365` | Halt scope stated. |
| AMMN-ARCH-01 | WEAK | `INV-091`, `REQ-COLL-029`, `REQ-COLL-032`; `Q-362` | One ledger per chain closes the conflict. The `INV-091` caller wording is the same issue as FLOW-01. |
| AMMN-ARCH-02 | RESOLVED | `REQ-ARCH-004`, `REQ-ARCH-207`, `REQ-ARCH-208`; `Q-359` | Spoke per (chain, Hub, AMM, tier). |
| AMMN-ARCH-03 | RESOLVED | `INV-092`, `REQ-SWAP-032`; `Q-359` | One Adapter and one LPVaultSwap per chain. |
| AMMN-ARCH-04 | RESOLVED | `INV-095`, `REQ-FLASH-002`, `REQ-FLASH-005`, `REQ-FLASH-006`, `REQ-FLASH-008`; `Q-362` | Liquidity and fee checked per call, replaceable source, `drawCap` sized to half the flash liquidity. See N1 for the Hub check. |
| AMMN-ARCH-05 | RESOLVED | `REQ-CHAIN-001`…`004`, `INV-098`; `Q-365` | Per-chain parameters and sequencer rules. |
| AMMN-ARCH-06 | RESOLVED | `IAmmIntegration`, `IAmmIntegrationHooks`, `REQ-VAULT-001`, `REQ-VAULT-152`; `Q-359` | The interface is AMM-neutral, with hooks for the shapes it does not cover. |
| AMMN-ARCH-07 | RESOLVED | `INV-093`, `REQ-ADAPTER-028`…`036`; `Q-362` | Standard Spoke and three settings. |
| AMMN-ARCH-08 | RESOLVED | `REQ-LENS-001`, `INV-052`; `Q-359` | The Lens is periphery. |
| AMMN-ARCH-09 | RESOLVED | `INV-065`, `REQ-PROXY-050`; `Q-359` | One model: logic-free immutable proxy. |
| AMMN-ARCH-10 | RESOLVED | `INV-093`, `REQ-RISK-078`; `Q-362` | The drift check is the primary control. |
| AMMN-SM-01 | RESOLVED | `INV-094`, `REQ-RISK-082`, `SPEC-CAP-010`; `Q-360` | The funding Hub checks its cap. Lowering a line reverts until the caps under it are lowered. |
| AMMN-SM-02 | RESOLVED | `INV-057`; `Q-360` | Restated as a gate on new draws. |
| AMMN-SM-03 | RESOLVED | `INV-063`, `INV-064`, `INV-065`, `REQ-PROXY-050`, `REQ-PROXY-101`, `REQ-ADAPTER-099`; `Q-359` | `IPositionProxy.execute` is the only mutator and takes any target, so exits depend only on the live Adapter at a fixed address. No proxy version can be stranded. Adapter upgrade risk is the accepted `INV-018` blast radius. |
| AMMN-SM-04 | WEAK | `INV-093`, `REQ-ADAPTER-036`, `REQ-VTOKEN-025`; `Q-362` | Duplicate of RT-03 (the time between drift and breaker is not the bound; Aave's revert of the flag is). |
| AMMN-SM-05 | RESOLVED | `INV-075`, `INV-092`, `REQ-RISK-079`; `Q-361` | Token price sharing stated. Token exposure counted per funding Hub. |
| AMMN-SM-06 | RESOLVED | `INV-094`, `REQ-HUB-103`, `BOR-019`; `Q-361` | A borrow reads the funding Hub's pause. |
| FINDING-286 | RESOLVED | `REQ-LOCK-028`, `REQ-VAULT-165`; `Q-362` | `returnStray` is a timelock-only exception that reverts while the Lock is held. |
| FINDING-287 | RESOLVED | `MKT-027`, `REQ-ACCESS-141`, `REQ-ACCESS-155`; `Q-362` | Names fixed; parameters with no tighten setter are not Short. |
| FINDING-288 | RESOLVED | `REQ-ACCESS-141`, `REQ-ACCESS-155`; `Q-362` | `SHORT_ELIGIBLE` lists the five tighten setters. |
| FINDING-289 | RESOLVED | `REQ-FLASH-002`, `REQ-LENS-029`, `REQ-PSTORE-024`; `Q-317` | One exact form, `φ × 10⁴ ≤ maxFlashFeeBps × F`, also in `IFlashSource`. |
| FINDING-290 | RESOLVED | `REQ-ROLE-020`, `REQ-ROLE-021`, `REQ-ROLE-038`; `Q-362` | 1.4 now has the triple salt and two Lock members. |
| FINDING-291 | WEAK | `REQ-ADAPTER-036`, `REQ-VTOKEN-006`; `Q-362` | Fixed on 2.6 and 2.4. 4.3 (Aave V4 Spoke row, Assumptions) still says the rule "admits only supply into the Hub, Hub to AaveAdapter and Hub to LPVaultSwap on seizure". Informational. |
| FINDING-292 | RESOLVED | `SPEC-LIQ-018`, `REQ-SWAP-121`, `LIQ-090`; `Q-250`, `Q-251` | A dust leg is `Vlegᵢ ≤ Ulegᵢ`, with `Ulegᵢ` the value of one raw unit of token i in debt units, rounded up. A keeper who moves spot to make a leg dust receives at most `max(1 raw token unit, 1 raw debt unit)` per leg per call, below $0.01 for every launch token, and the floor already excludes it. The borrower does not control the unwind mix. Value cannot be pushed into dust legs. |

## Focus re-runs

- **RT-01 in the integration code path.** The check is in the interface: `IAmmIntegration.receivePosition` and `validatePosition` (`RangeMismatch`, `PoolMismatch`), `ClMarketConfig` stores the exact ticks, and `ICollateralizationAdapter` documents the revert. The exploit fails at custody, before any mint.
- **RT-02 clamp.** The pricing module clamps with `s = min(max(s_O, s_a), s_b)` on the capped prices. `REQ-ORACLE-104` reports the clamp and sets Drifting, so new debt against a one-token holding stops.
- **RT-03/SM-04 drift timing.** Suppose the Aave DAO sets `receiveSharesEnabled = true`. A third party liquidates with `receiveShares = true`, receiving supply shares worth 105,000 for repaying 100,000. It then borrows 100,800 on the Spoke at CF 0.96. Avana's breaker trips on its next call, but the Spoke is unmodified: the attacker's account is not a proxy, so Avana gates neither its liquidation nor its borrow. LPVaultSwap cannot settle the attacker's shares because Collateralization holds no record for them. The attack repeats on every liquidatable account until Aave reverts the flag. Severity: Medium, conditional on an Aave configuration error. Fix: state the bound as "until the Aave flag is reverted". Add a monitored Aave-payload pre-check to the playbook, and an Avana-requested Aave guardian action (freeze the reserve, `drawCap = 0`) that fires on `CONFIG_DRIFT`.
- **RT-05 cap multiplication.** Fixed for the token and depositor caps. The pool-share cap remains per market (see table).
- **SM-03 exits.** Closed: no proxy code version exists.
- **FLOW-01 Lock.** The design is closed; only the `INV-091`/`INV-054` wording conflicts.
- **INT-01.** The 24 h heartbeat plus the 1,800 s margin is consistent, and liquidation never reads the second source. The second source can block every borrow that touches its token for at least 5 days (see table).
- **GAS-01.** Closed. GAS-02 is where it falls short (see table).
- **FLOW-09.** Closed by the minimum-over-spot property, including out of range.
- **FINDING-292.** No profitable way to engineer dust legs.

## New attacks against the final design

| # | Attack | Works? | Severity |
|---|---|---|---|
| N1 | **Flash source that sits on another market's Hub.** `IFlashSource.flashLoan` and `REQ-FLASH-001` check `LENDER() != spokeHub`, an address equality. `REQ-FLASH-006`'s setter refuses only a lender that *is* a recorded Hub. The future source the same rule names ("a flash Spoke on a V4 Hub") has a Spoke address, so it passes even when its Spoke draws from the liquidated market's own Hub. The rationale of `REQ-FLASH-005` (no repaying a Hub with its own liquidity) is therefore not enforced for any non-V3 source. Also, LPVaultSwap checks the funding Hub while the source checks the home Hub, two different identities. | Not at launch (the lender is the V3 Pool). Opens with the first replacement source, at the normal delay. | Low |
| N2a | **Blocklisted fee recipient.** `REQ-SWAP-028`/`REQ-SWAP-064`: the transfer of A to `feeRecipient` is unguarded, and its failure reverts the whole liquidation. If Circle or Tether blocklists the treasury Safe, every routed liquidation with `S > 0` and every `settlePending` residue in that asset reverts chain-wide. `setFeeRecipient` is normal delay (5 days). Approved keepers' in-kind mode pays no Avana fee and still works; `liquidatePermissionless` stops. Fix: escrow or skip A on a failed transfer, as `REQ-SWAP-076` does for B. | Yes, on an issuer action. | Low |
| N2b | **USDT transfer fee breaks the flash path.** `REQ-SWAP-108` says a 5,000 USDT flash "arrives as 4,995 USDT and LPVaultSwap passes 4,995", but `REQ-FLASH-003` contradicts it. After the Pool's transfer the source holds `amounts[0] × (1 − f)`, and its transfer of exactly `amounts[0]` to LPVaultSwap reverts. Even with a gross-up, the source requires `balance ≥ amount + premium` after LPVaultSwap returns only `F + φ`, which nets less. Once Tether sets `basisPointsRate > 0`, every flash-funded liquidation and every `deleverage` of a USDT debt reserve reverts. Only caller-funded and in-kind paths remain, and the spec claims the case is handled. Fix: gross up inside the source and in `REQ-SWAP-026` step 4, or refuse USDT as a debt asset while its fee is non-zero. | Yes, for any USDT debt reserve, on an issuer action. | Medium |
| N3 | **Cross-market drain of the shared SettlementBudget balance.** Market windows partition the *window* but not the *balance*. Approved-keeper draws for market A, within A's window, lower `available(T)` for every market until Avana tops up off-chain. After a few days of high draws in one market, others' draw-needing liquidations revert `InsufficientBudget`. A shared LPVaultSwap adds no further cross-market path: the Lock serializes per transaction, breakers and windows are per market, and N2a is its one shared-recipient halt. | Yes, bounded by per-call caps and windows. Draws are approved-keeper only. | Low (same issue as RT-13, counted once) |

## Score

Rubric of report.md: 100 − 6 per Critical − 2 per High − 0.5 per Medium, counting only WEAK and OPEN items and new attacks, after merging duplicates.

| Item | Severity | Points |
|---|---|---|
| RT-03 / SM-04 / INT-07 (drift bound; third-party `receiveShares` path) | Medium | 0.5 |
| RT-05 (pool-share cap per market) | Medium | 0.5 |
| FLOW-12 (Aave halt stops exits, accepted) | Medium | 0.5 |
| FLOW-16 (minimum borrow keeps the cap filled) | Medium | 0.5 |
| GAS-02 (minimum debt sized for one record, not 16) | Medium | 0.5 |
| INT-01 (single second source, normal-delay replacement; page conflicts) | Medium | 0.5 |
| N2b (USDT fee contradicts the flash source) | Medium | 0.5 |
| RT-13 / N3, FLOW-01 / GAS-09 / ARCH-01, FLOW-11, N1, N2a | Low | 0 |
| FINDING-291 | Informational | 0 |
| **Spec-stage score** | | **100 − 3.5 = 96.5** |

No Critical or High is open, so no cap applies. The score assumes that the pending proving checks of 5.3 pass against the rewritten pages. Above 90 at this stage still says nothing about the implementation, which did not exist on that date.

## Fix pass

Date: 2026-11-10, after decisions `Q-381`…`Q-390` and the rewrite of the pages they change. Each WEAK item and each new attack was re-run against the rule that now resolves it. Decision `Q-381` sets no minimum debt on any chain: Avana's own approved keepers liquidate every account and Avana pays their gas, and the permissionless fallback stays. GAS-02 therefore closes by decision, not by resizing a minimum.

| Item | Status at re-check | Resolving rules | Decision | Status after fix pass | Re-run result |
|---|---|---|---|---|---|
| AMMN-RT-03 / SM-04 / INT-07 (receiveShares drift) | WEAK | `INV-093`, `REQ-RISK-078`, `REQ-RISK-090` (per-block `pokeConfig`), `ATTACK-155`, `EXT-001` | `Q-382` | RESOLVED, residual accepted | The bound is stated as it is: exposure lasts from the Aave change until the drift check trips `CONFIG_DRIFT`. The check runs on every Avana entry point and on a per-block keeper poke, so the window is the block of the change and the next block. A third party's `receiveShares = true` seizure, or its borrow against the shares, in that window is an accepted residual risk bounded by the Spoke draw caps. The 3.6 playbook asks the Aave Protocol Guardian to freeze the reserve and set the draw caps to 0. |
| AMMN-RT-05 (pool-share cap) | WEAK | `INV-092`, `REQ-COLL-026` (`poolUnits` per pool), `REQ-RISK-079`, `SPEC-CAP-005` | `Q-383` | RESOLVED | One counter per pool sums every market (every range) of that pool on the chain. k ranges now share one `poolShareMaxBps`, so the k-fold share is refused at the pledge that crosses the cap. |
| AMMN-RT-13 / N3 (shared SettlementBudget balance) | WEAK | `INV-097`, `SPEC-SET-007`, `REQ-BUDGET-002`, `REQ-BUDGET-027`…`030` | `Q-387`, later `Q-397` | RESOLVED, then resolved by removal of the budget ([parameter decisions](#parameter-decisions-2026-11-10)) | `INV-097` states what holds: windows bound each market's draws, the asset window and the balance bound their sum, and `reservedSum ≤ balance`. Each market's reserve is spent only by that market. A draw for market A that would leave the balance below the other markets' reserves reverts `InsufficientBudget`, so B and C keep their floors. The free part above the reserves is shared, bounded per day by each market's window. |
| AMMN-FLOW-01 / GAS-09 / ARCH-01 (`INV-091` caller wording) | WEAK | `INV-091`, `INV-054`, `REQ-LOCK-028`, `REQ-VAULT-150`, `ILock`, `PROP-075` | `Q-362` | RESOLVED | 4.1, 2.16 and the interface now say the same thing. Collateralization accepts only a Lock member while the Lock is held. An LPVault's position-moving functions accept only Collateralization while a member holds the Lock, so they run only inside a call tree a member opened. `returnStray` is timelock-only and runs only while the Lock is free. A literal build no longer reverts every flow. |
| AMMN-FLOW-11 (relisting) | WEAK | `REQ-VTOKEN-020`, `REQ-VTOKEN-021`, `REQ-CONFIG-007`, `REQ-MREG-030`, `ATTACK-179` | `Q-359` | RESOLVED | Vault tokens are keyed by `(spoke, marketKey)`, and 2.8 no longer maps a pool to one token for life, so a market is relisted after its wind-down without `DuplicateMarketKey`. |
| AMMN-FLOW-12 (Aave halt stops exits) | WEAK | `EMG-052`, `EMG-064`, 3.6 accepted-risk playbook, `ATTACK-180`, `FINDING-228` | `Q-346` | ACCEPTED | An Aave halt still stops repay, withdrawal and liquidation on that Spoke. Only Aave governance can set or lift it, so the risk is accepted with a playbook. Bound: positions open while the halt lasts, within each market's caps. |
| AMMN-FLOW-16 (cap squatting) | WEAK | `REQ-RISK-080`, `REQ-ADAPTER-095`, `INV-092`, `ATTACK-184` | `Q-384`, later `Q-396` | RESOLVED, then ACCEPTED after the idle mechanism was removed ([parameter decisions](#parameter-decisions-2026-11-10)) | Idle is decided by utilisation, `debtValue × 10⁴ < IDLE_UTILIZATION_BPS × borrowCapacity`, not by zero debt. A token borrow no longer keeps a charge in `Regular`, and a squatter that borrows again is moved back to `Regular` only if there is room. |
| AMMN-GAS-02 (minimum debt sized for one record) | WEAK | `INV-096`, `SPEC-CHAIN-001`, `LIQ-087`, `TEST-278`, `PROP-082` | `Q-381` | RESOLVED by decision | No minimum; Avana keeper pays gas. Liquidation no longer depends on any keeper's profit, so the break-even gap is gone. The 16-record cap stays for a different reason: `G(16) = 1.31M + 0.24M × 16 = 5.15M ≤ 16,777,216`. |
| AMMN-INT-01 (second source can block borrows) | WEAK | `SPEC-ORC-020`, `REQ-ORACLE-100`, `REQ-PSTORE-028`, `REQ-PSTORE-029`, `EMG-103`, `EMG-106` | `Q-385` | RESOLVED | Each token may have a pre-approved standby second source. Either guardian switches to it at once (`useStandbySecondSource`), and switching back needs the timelock (`restoreSecondSource`). A failed USDC second source stops borrows for one guardian transaction, not 5 days. `EMG-103` keeps the market Live, as `REQ-ORACLE-100` requires. |
| FINDING-291 (4.3 wording) | WEAK (Informational) | `EXT-001`, `REQ-ADAPTER-036`, `REQ-VTOKEN-006` | `Q-362` | RESOLVED | The 4.3 Aave V4 Hub assumptions now list the token's allowed transfers: proxy to Hub, Hub to proxy (withdrawal), Hub to LPVaultSwap (seizure), and Adapter mint and burn. The Adapter never receives the token from the Hub. |
| N1 (flash source on a Hub) | New, Low | `INV-095`, `REQ-FLASH-001`, `REQ-FLASH-005`, `REQ-FLASH-006`, `ATTACK-195`, `FINDING-293` | `Q-386` | RESOLVED | The source reports through `LENDER()` the pool or Hub it borrows from. `setFlashSource` (`InvalidFlashSource`) and every flash call (`FlashSourceIsHub`) refuse it when that is any Hub recorded on the chain. A flash Spoke on the Stable LP Hub reports that Hub and is refused. |
| N2a (blocklisted fee recipient) | New, Low | `INV-036`, `REQ-SWAP-026`, `REQ-SWAP-028`, `REQ-SWAP-064`, `REQ-SWAP-076`, `REQ-ESCROW-005`, `ATTACK-196`, `FINDING-294` | `Q-389` | RESOLVED | A failed fee or payout transfer goes to the PayoutEscrow, credited to its recipient, and never reverts the liquidation or `settlePending`. A blocklisted treasury Safe no longer halts USDC liquidations. |
| N2b (fee-on-transfer debt asset) | New, Medium | `INV-095`, `REQ-FLASH-003`, `REQ-SWAP-108`, `REQ-SWAP-122`, `REQ-SWAP-123`, `SPEC-BRK-003`, `ATTACK-197`, `FINDING-295` | `Q-390` | RESOLVED | The source forwards what it received, and LPVaultSwap tops the source up by balance delta so that it ends with `F + φ`. At 10 bps, a 5,000 USDT loan at 5 bps costs `⌈5,002.5 / 0.999⌉` = 5,007.507508 USDT sent. A non-zero fee trips the reserve's `ISSUER` debt breaker: new borrows stop and liquidation continues. `enableDebtReserve` reverts `TransferFeeActive` unless the fee is 0. |

### Re-score after the fix pass

Same rubric: 100 − 6 per Critical − 2 per High − 0.5 per Medium, after merging duplicates. It counts WEAK and OPEN items and new attacks. Accepted residual risks keep their Medium deduction, as FLOW-12 did in the first scoring.

| Item | Severity | Points |
|---|---|---|
| RT-03 / SM-04 / INT-07 residual: third-party seizure from an Aave change until `CONFIG_DRIFT` trips, bounded by the Spoke draw caps (accepted) | Medium | 0.5 |
| FLOW-12: Aave halt stops exits (accepted, playbook) | Medium | 0.5 |
| Every other item above (resolved) | | 0 |
| **Spec-stage score after the fix pass** | | **100 − 1.0 = 99.0** |

No Critical, High, WEAK or OPEN item remains. The score assumes that the proving checks named above (`TEST-268`…`TEST-287`, `PROP-075`, `PROP-077`, `PROP-082`, `PROP-084`, `PROP-096`, `PROP-097`) pass on the code. It is a spec-stage result only.

## Parameter decisions (2026-11-10)

After the fix pass, decisions `Q-391`…`Q-402` removed five mechanisms (recorded in [4.4](../../../spec/04-security/04-design-decisions.md)). Each removal was re-run against the findings it touched.

| Removed | Decision | Why | Effect on findings |
|---|---|---|---|
| SettlementBudget, with `perCallCap`, the reserved floors, the market and asset windows and every draw | `Q-397` | It closed only rounding gaps of about one debt unit per liquidation, yet it added an immutable contract per chain, a funding duty in every debt asset, and windows and reserves that needed their own fixes (RT-13, N3, GAS-10). The caller already has a funded shortfall top-up. Aave V4's dust rule can raise the repayment needed to finish a liquidation, so the caller sizes `debtToCover` and its funding (flash principal and exact premium) up front, and pays any rounding gap at final settlement through the shortfall top-up (`INV-034`, `INV-037`, `INV-038`). | RT-13 / N3 and GAS-10 are resolved by removal: no shared settlement balance exists for one market to drain. No finding reopens. |
| In-kind settlement: `enableInKind`, the automatic trigger, `reportRecoveryShortfall`, the probe, `inKindExpiry` and the in-kind split | `Q-401` | It paid keepers in pool tokens priced from the oracle during the outages in which the oracle and routes were least reliable, and its trigger, probe and expiry each added attack surface. The PayoutEscrow stays, renamed in purpose only, as the payout escrow for transfers a token refuses (borrower surplus, fee, keeper payout). | Partly reopens FLOW-09 and GAS-08: while every route of a leg fails, liquidation of that market waits until a route or the standby route works (`NoRouteAvailable`, `INV-039`). New borrowing is frozen by the guardian meanwhile, and other markets are unaffected (`INV-075`). Accepted as a Medium residual (`Q-401`). |
| Idle-collateral mechanism: `releaseIdle`, `admitIdleCharge`, the `Idle` bucket, `idleUsdCap`, `idleBookingSeconds`, `IDLE_UTILIZATION_BPS` | `Q-396` | It added a third cap bucket and its booking rules to answer one griefing case, and a utilisation threshold that still had edges. | FLOW-16 (cap squatting by a debt-free LP) reopens and is accepted: caps are set at listing and a cap held near full by debt-free accounts is a monitoring alert. A squatter locks its own capital and blocks only new pledges, never exits, repay, rescues (the slice) or liquidation. |
| On-chain health floors: `minOpeningHealthFactor` and `PROXY_HEALTH_FACTOR_FLOOR` | `Q-398` | Lenders are protected by the collateral factor, liquidation and first-loss coverage, not by a floor above Aave's HF 1. The Lens previews a recommended borrow at HF 1.10 beside the maximum at HF 1.00 ($100,000 at a 70 % collateral factor: $63,636 recommended, $70,000 maximum). An optional per-market `hardHealthFloor` exists, off by default. The rescue top-up threshold is `rescueHealthFactor` (1.10). | No finding reopens. |
| Alert-only breakers: price drop (3 % in 2 hours), seizure surge (20 % of a market in 1 hour), swap-route failures (3 in 1 hour), with `breakerCooldown` | `Q-399` | Reverted calls cannot persist failure counts, and attacker-movable counters could be gamed to halt borrowing. They are monitoring alerts; a route freeze is a guardian action when the routes are confirmed unable to settle. The on-chain gates are the oracle and stablecoin band checks, the 10 % pool concentration gate and the deficit freeze at 10,000 GHO. | GAS-04 (breaker reports starved of gas) is resolved by removal for liquidations. No finding reopens. |

`keeperMinRepay` is also removed (`Q-395`), and `keeperFloor` is 1 with `MAX_KEEPERS` 32 (`Q-400`). With the permissionless path open, neither change reopens a finding.

### Re-score after the parameter decisions

Same rubric as the fix pass. Accepted residual risks keep their Medium deduction.

| Item | Severity | Points |
|---|---|---|
| RT-03 / SM-04 / INT-07 residual (accepted) | Medium | 0.5 |
| FLOW-12: Aave halt stops exits (accepted, playbook) | Medium | 0.5 |
| FLOW-16: cap squatting by a debt-free LP (accepted, `Q-396`) | Medium | 0.5 |
| FLOW-09 / GAS-08 residual: liquidation waits while every route of a leg fails (accepted, `Q-401`) | Medium | 0.5 |
| Every other item (resolved) | | 0 |
| **Spec-stage score after the parameter decisions** | | **100 − 2.0 = 98.0** |

No Critical, High, WEAK or OPEN item remains. It is a spec-stage result only.
