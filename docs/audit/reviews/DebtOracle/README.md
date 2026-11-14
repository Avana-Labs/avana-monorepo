# DebtOracle review

| Item | Value |
|---|---|
| Date | 2026-11-11 |
| Contract | `src/oracle/debt-oracle/`: `DebtOracle`, `DebtOracleRecovery`, `DebtOracleEvaluation`, `DebtOracleReads`, `DebtOracleStorage`, the types and interfaces; the `LPPriceMath` functions it calls |
| Spec | [2.10 DebtOracle](../../../spec/02-contracts/10-lp-oracle.md#debtoracle) (`REQ-ORACLE-091` to `-093`, `-096`, `-098`, `SPEC-ORC-018`) and the shared LPOracle rules it applies (`REQ-ORACLE-001` to `-008`, `-017`, `-022` to `-034`, `-089` to `-102`, `SPEC-ORC-001` to `-003`, `-013` to `-016`, `-019` to `-023`); `INV-030`, `INV-059`, `INV-072`, `INV-087`, `INV-098`; `ATTACK-140`, `-145`, `-150`, `-171` |
| Method | Independent adversarial review from the spec and the code only; one PoC test per demonstrable finding, run against the code as reviewed (mocked feeds, registry and store from the unit fixtures; the real MarketRegistry for the read-gas measurement) |
| Result | No Critical, High, Medium or Low. 3 Informational, 7 spec points; all fixed 2026-11-11 (see Resolution). The decoding, gas guard, failover, agreement, timers, latch, recovery evidence with the phase rule, served price and roles held under every attack tried |

## Findings

| ID | Severity | Title | Location | Description | PoC | Recommendation |
|---|---|---|---|---|---|---|
| DO-01 | Info | During a disagreement the served value comes from one route and its timestamp, age limits and legs from the other | `DebtOracleEvaluation._serve` (L260–L286), `DebtOracle._reportLegs`, `latestRoundData` | Drifting serves `max(p, b, A)`, but `servedUpdatedAt`, `borrowPriceMaxAge`/`liquidationPriceMaxAge`, `legFeeds` and `latestRoundData().updatedAt` are always the primary's. When the alternate (or `A`) is the larger value, a consumer sees the alternate's price labelled with the primary's round. PoC: primary 0.9999 from `T0 − 100`, alternate 1.03 published at `T0 + 50,000`: served 103,000,000 with `updatedAt = T0 − 100`. No gate reads these while Drifting (`liquidationPaused` is true, `borrowAllowed` false), so the effect is reporting only (Lens, monitoring, any external reader of `latestRoundData`). `REQ-ORACLE-093` defines the timestamp as the quote's, so the code follows the text; the LPOracle's rule (`SPEC-ORC-012`/`-015`: the route `SPEC-ORC-017` chooses) has no DebtOracle counterpart | `test_POC_DO01_disagreementServesAlternateUnderPrimaryTimestamp` | Define in `REQ-ORACLE-093` the route whose legs and timestamp a Drifting debt price reports: the route of the larger value (the alternate when `b > p`), and `accepted.updatedAt` when `A` is served |
| DO-02 | Info (spec contradiction) | `INV-098` says liquidation is never gated by the sequencer feed; the DebtOracle pauses repayment while it reports down | `DebtOracleEvaluation._evaluate` L42; spec `INV-098` vs `REQ-ORACLE-099`, `SPEC-ORC-021` | The code sets `liquidationPaused` when `sequencerDown`, as `REQ-ORACLE-093`, `-099` and `SPEC-ORC-021` require, so LPVaultSwap may not repay the reserve while the asset is Live. `INV-098` says "repay, debt-free exits, fee collection, pending settlement and liquidation are never gated by the feed", and that "liquidation during the grace period values collateral by the stress rules", while `REQ-ORACLE-099` says the sequencer status never changes the state or the served price | `test_POC_DO02_sequencerDownPausesDebtRepaymentInLiquidation` | Correct `INV-098`: liquidation pauses while the feed reports down and, in the grace period, applies `graceHealthFactor`; prices are unchanged by the sequencer status (as `ATTACK-171` already says) |
| DO-03 | Info | The stress rise is clamped below at 100 bps but not above at 5,000 | `LPPriceMath._stressPrice` via `debtServedPrice` | `SPEC-ORC-018` states `100 ≤ δ ≤ 5,000` and the property "the Expired value never exceeds `1.5 × A + 1`". Only the lower bound is applied in the library; the upper bound lives only in the ParameterStore setters (`STRESS_RISE_MAX_BPS`). A store returning 65,535 bps (a faulty store implementation, which takes the timelock) serves `7.55 × A` for every account holding the debt, which lowers HFs enough to make fresh collateral of healthy accounts seizable (`ATTACK-145` shape). The DebtOracle already treats every other configuration word as untrusted (range-checked decode) | `test_POC_DO03_stressRiseAboveBoundIsServed` | Read `min(δ, 5,000)` in `debtServedPrice` (or treat `δ > 5,000` as a failed read), so the `SPEC-ORC-018` bound holds in the oracle itself |

## Spec points

| # | Pages | Point | Suggested change |
|---|---|---|---|
| S1 | 2.10 `REQ-ORACLE-096` vs 4.1 `INV-030`, `ILPVaultSwapLiquidation.liquidate` natspec | `REQ-ORACLE-096`: "LPVaultSwap pokes the DebtOracle of every non-GHO debt reserve of the account it liquidates". `INV-030` and the LPVaultSwap interface: it pokes the LPOracle of `m` and the DebtOracle of the repaid reserve `r` only | Pick one. If only `r` is poked, a disagreement on another debt reserve of the account is first stored by a keeper poke, not by the liquidation |
| S2 | 4.1 `INV-030` vs 2.10 `REQ-ORACLE-093` | `INV-030` admits the repayment while the DebtOracle "is Live ... with its input no older than `liquidationPriceMaxAge`"; `REQ-ORACLE-093` requires `liquidationPaused == false`, which is also true for a Live price while the alternate is past its borrow age or the sequencer is down | Say in `INV-030` that the repaid reserve's `liquidationPaused` must be false |
| S3 | 4.1 `INV-098` vs 2.10 `REQ-ORACLE-099`, `SPEC-ORC-021`, 4.2 `ATTACK-171` | DO-02 | Per DO-02 |
| S4 | 2.10 `SPEC-ORC-012`, `SPEC-ORC-015`, `REQ-ORACLE-093` | DO-01: the disagreement rule for the served route is written for collateral only | Per DO-01 |
| S5 | 2.10 `REQ-ORACLE-092` (5) vs DebtOracle reason bit 2 | A failed `debtStressRiseBps` read both fails the asset (bit 2) and lowers `δ` to 100, so once Expired a store outage serves `A × 1.01` instead of `A × (1 + δ)` (with `δ = 500`, 100,989,900 instead of 104,989,500 for `A = 99,990,000`). `cachedWindow` has a last-read fallback (`lastCachedWindow`); `δ` does not, so a broken store makes the stress price less conservative than configured | Keep a `lastStressRiseBps` like `lastCachedWindow`, or state the 100 bps fallback as intended in the reason-bit text |
| S6 | 2.10 `REQ-ORACLE-091` (applies `REQ-ORACLE-080`, `-081`) | `REQ-ORACLE-080` names `checkpoint`, which the DebtOracle does not have; `REQ-ORACLE-081` ("checked by the reinitializer") cannot be enforced by this implementation, which has no reinitializer and no upgrade hook | Name the DebtOracle's own preserved fields in `REQ-ORACLE-091`, and state that each new implementation's reinitializer carries the `REQ-ORACLE-081` check |
| S7 | 2.10 `SPEC-ORC-018` | DO-03: the `1.5 × A + 1` property holds only through the ParameterStore's bound | Per DO-03 |

## Resolution (2026-11-11)

Every recommended fix was approved and is applied (code in `src/oracle/debt-oracle/`, spec 2.10 DebtOracle parts and 4.1). Each PoC is a regression test that failed before the fix.

| ID | Status | Fix | Regression test |
|---|---|---|---|
| DO-01 | Fixed | While the routes disagree, `servedUpdatedAt`, the age limits, the leg report and `latestRoundData().updatedAt` follow the route whose value is served (the alternate when `b > p`), or the accepted timestamp with limits 0 and no legs when `A` is served; DebtOracle counterpart written into `SPEC-ORC-012` and `SPEC-ORC-015`; `REQ-ORACLE-093` restated | `test/unit/DebtOracle.Routes.unit.t.sol`: `test_TEST_219_disagreementTimestampsFollowServedRoute`; Halmos `check_PROP_074_driftingTimestampFollows*`; Z3 MATH-UO-67 |
| DO-02 | Fixed (spec) | `INV-098` corrected: liquidation and pending settlement pause while the feed reports down (the DebtOracle's and LPOracle's `liquidationPaused`), grace applies `graceHealthFactor`, an unreadable feed blocks only borrowing; prices are unchanged by the sequencer status | `test_TEST_276_sequencerGate` now tags `INV-098` |
| DO-03 | Fixed | The DebtOracle reads the stress rise into `[100, 5,000]` itself (`min(δ, 5,000)`), so the Expired price never exceeds `1.5 × A + 1` whatever the store returns | `test/unit/DebtOracle.unit.t.sol`: `test_TEST_230_stressRiseClampedAt5000Bps`; Halmos `check_PROP_074_expiredStressRiseClamped`; Z3 MATH-UO-43d, -43e |
| S1 | Fixed | `REQ-ORACLE-096`: LPVaultSwap pokes the DebtOracle of the repaid reserve only, as `INV-030` and the LPVaultSwap interface state | — |
| S2 | Fixed | `INV-030` requires the repaid reserve's `liquidationPaused == false` | — |
| S3 | Fixed | As DO-02 | — |
| S4 | Fixed | As DO-01 | — |
| S5 | Fixed | A failed `debtStressRiseBps` read keeps `lastStressRiseBps`, the value the last writing call read (new storage field, appended to the namespace); `REQ-ORACLE-092` (5) restated | `test_TEST_219_failedStressRiseReadKeepsLastGoodValue`, `test_TEST_219_unreadableWindowAndStressRiseFailClosed` (now 104,989,500) |
| S6 | Fixed | `REQ-ORACLE-091` names the DebtOracle's own preserved fields and states that every reinitializer carries the `REQ-ORACLE-081` check | — |
| S7 | Fixed | As DO-03 | — |

## Measurements (not findings)

| Item | Value | Note |
|---|---|---|
| Worst-case `poke()`, two-leg primary and alternate, every leg on the phase path, sequencer and second source | 504,343 gas at `pokeMinGas = 600,000` (completes) | Mocked feeds (`test_measure_pokeWithEveryLegOnThePhasePath`); the unit test takes the phase path on one leg only (478,882). `SPEC-ORC-023` requires `W_poke` measured on a fork; no fork run exists yet, so the margin against real Chainlink proxies (proxy → aggregator hop) is unverified |
| `latestAnswer()` cold | 288,147 gas (mocks) | Every Aave health-factor computation that includes the reserve pays this |
| Real MarketRegistry `getToken` / `activePriceRoutes` cold | 30,692 / 22,666 gas including the 2,600 cold access | Inside `CONFIG_CALL_GAS = 40,000` with about 12,000 to spare for `getToken` (it copies all three route arrays to read one word) (`GasProbe.t.sol`) |

## Checked and holding

- Decoding: every read copies at most its ABI length (a 100 KB return costs the oracle nothing); `roundId ≥ 2^80`, `updatedAt ≥ 2^64`, `decimals > 255` are `Error`; `updatedAt > now` and `updatedAt = 0` are `Invalid`; answers `≤ minAnswer`, `≥ maxAnswer`, `≤ 0` or `≥ 2^128` are `Invalid` or normalise to 0; route values above `MAX_ROUTE_ANSWER` are `Invalid`, so `accepted.price8` fits `uint128` and the stress product never overflows. `activePriceRoutes` is accepted only in its exact canonical encoding (offsets, lengths 1–2, size ≤ 288, `replaced ≤ 2`); `getToken` only as offset 32 with `listed == 1`.
- Gas guard: every external read checks `gasleft() ≥ ⌈64·G/63⌉ + 5,000` before the call, so no caller can starve a read into a stricter state; `poke()` checks `pokeMinGas` after the proxy hop, where the gas is measured. A view reverts only `InsufficientGas`.
- Failover, agreement (`|p − b|·10⁴ ≤ T·min`), Cached/Expired from `min(S_ts, failedSince, now)`, the `lastCachedWindow` fallback, disagreement pause and expiry with the version reset, and `liquidationPaused`/`borrowAllowed` match the spec; the served price is `≥ A` in every non-Live state (`INV-087`).
- Recovery evidence: a gap is looked up only for a leg whose `seen` names the same aggregator, a new round and an advance beyond `feedMaxAge`; `getRoundData(roundId − 1)` comes from the feed, so no caller can forge a gap; the phase rule reads `phaseAggregators(phaseId − 1)` and falls back to `seen.updatedAt`, which only lengthens a gap (`ATTACK-150`). Each outage starts one grace window (`recoveredAt` monotone, latch cleared). As the spec's precision note says, only the latest gap is examined: if no poke happens during the whole Expired period and a leg publishes a second round within `feedMaxAge` of its recovery round before the next poke, no grace starts; keeper pokes during the outage (`REQ-ORACLE-037`) set the latch and cover this.
- Second source and sequencer: only `OracleNetwork` with a feed definition confirms; failures leave the asset unconfirmed or `sequencerUnknown` and never change the state, price or timers; `startedAt` above `now` is unknown.
- Roles and upgrade: admin roles only for `TIMELOCK` (`_grantRole` override), `_authorizeUpgrade` requires `APPLICATION_ADMIN`, initializers disabled on the implementation, `initialize` requires a listed asset, canonical routes, `pokeMinGas` in bounds and a Live seed; no function other than `initialize` and `poke()` writes price, timer, latch, `seen` or route-version storage.

## Not settled

- The `POKE_MIN_GAS_FLOOR = 600,000` constant and the 40,000-gas configuration reads were checked against mocks and the real registry only; a fork measurement against Chainlink proxies and the deployed ParameterStore is still needed (`SPEC-ORC-023`).

PoC files are copied from the review workspace into [`poc/`](poc/), with imports at their review-time paths (`contracts/test/review/`). Run with `forge test -j 2 --match-path 'test/review/*'`.
