# Control area: internal formal verification report (FV-C)

> **Status:** In review · **Owner:** Avana Labs · **Last reviewed:** 2026-11-10
>
> **Check prefix:** `FV-CTL-NN` · **Finding prefix:** `FV-CTL-F-NN` · **Reproduce everything:** `audit/formal-verification/control/run.sh`

## 1. Project summary

Avana's internal formal verification of the control area, run against the specification before any implementation exists. The models were written from the spec text; the existing models in `spec/05-verification/` were read only after the results were in (section 9).

| Item | Value |
|---|---|
| Area | control ([methodology](../methodology.md) section 1) |
| Contracts in scope | AaveAdapter gates, RiskModule, PositionProxy and ProxyManager binding (immutable proxy per wallet × CDP Spoke × market since run `FV-CTL-R5`), standard-Spoke drift settings, the IFlashSource, Hub-keyed caps and credit lines, MarketRegistry (pause switch, lifecycle, routes, debt reserves), ParameterStore, LPOracle with LPPriceMath, Lock (two members), Lens, AvanaTimelock, UUPS upgrade paths |
| Spec version | `spec/` as of 2026-11-09 20:30; decisions `Q-001`…`Q-240`, with `Q-227` as amended (no pause state stops liquidation) |
| Targets | `T-53` … `T-80` (the 28 control targets), properties added from the spec reading, and two approved rules not yet written into the spec (circuit breakers, address freeze) |
| Tools | Z3 4.13.0 (Python), exhaustive enumeration over finite domains, Quint 0.22.4 `quint run` (randomized: 10,000 samples × 12 steps per invariant) |
| Result | 122 checks: 89 Verified, 2 Verified under bounded model, 6 Quint invariants with no violation in 10,000 samples, 25 Violated. The violations are 16 findings: 4 Medium, 5 Low, 7 Informational. Every Medium and Low finding has a recommended spec change whose model is Verified (`-FIX` checks). |
| AMM-neutral design | Run `FV-CTL-R5` (2026-11-10) against the AMM-neutral spec (`Q-001`…`Q-380`): 180 checks: 163 Verified, 6 Verified under bounded model, 6 Quint invariants with no violation, 0 Violated outside open findings, and 5 checks Violated as open findings `FV-CTL-F-25`…`F-29` (2 Low, 3 Informational). Section 13. |
| Re-verification | Run `FV-CTL-R3` (2026-11-10) against the final spec (`Q-001`…`Q-278`): 165 checks, 152 Verified, 6 Verified under bounded model, 7 Violated. Every earlier finding's proving check passes; the 7 violations are new findings `FV-CTL-F-18`…`F-24` (1 Medium, 1 Low, 5 Informational). Section 12. |

**Area overview.** Every privileged change runs as an AvanaTimelock operation (12-hour short list, otherwise the normal delay of at most 5 days, 14-day grace). The MarketRegistry holds one `PauseState`, read only by the AaveAdapter for pledge, borrow and withdraw-with-debt. The RiskModule holds every pledge and borrow-side check. The LPOracle serves a price that never reverts and reports Live, Drifting, Cached or Expired from source timestamps. Repay, fee collection, debt-free withdrawal, zero-credit release, liquidation and pending settlement never read the pause state.

## 2. Assessment methodology

- **Rules:** symbolic pre-state, symbolic call, assertions on the post-state. Z3 proves the negation unsatisfiable (Verified) or returns a model (Violated; the counterexample is printed and stored in `results/<model>.json`).
- **Inductive invariants:** base case (initializer, constructor or launch values) and step case (assume the invariant, apply any state-changing call symbolically, prove it again). Used for the admin-role holders, `normalDelay`, the Lock holder, route records, SettlementBudget caps, relational parameter bounds and the LPOracle stored state.
- **Exhaustive enumeration:** finite domains checked completely (pause state × function × caller roles, page × state × action, 10⁴ leg-behaviour combinations, call-graph reachability, freeze sets). A complete enumeration is reported as Verified; an enumeration over a bounded sequence length is reported as Verified under bounded model with the bound.
- **Witnesses** (`-W`): the success path of each non-trivial rule is reachable, so no rule is vacuous.
- **Fix validation:** each finding has a `-FIX` check that encodes the exact recommended change and is Verified.
- **Cross-page consistency** is a property in its own right: where several pages define one rule (pause matrix, restricted-function matrix, delay classes, pledge price-state rule), each page is encoded separately and the encodings are compared.
- **Over-approximation:** upgradeable contracts in the "any implementation" scope of [4.1](../../../spec/04-security/01-global-invariants.md) are arbitrary functions; adversaries choose every free input. **Under-approximation:** the bounds in section 3.

**Security context.** Threats of [4.2](../../../spec/04-security/02-attack-scenarios.md) mapped to targets: governance takeover and timelock bypass (`T-53`, `T-54`, `T-55`, `T-64`); guardian abuse (`T-55`, `T-56`); stale or manipulated prices (`T-59`, `T-66`…`T-70`); unsafe opening (`T-58`, `T-77`, `T-78`); upgrade takeover (`T-64`, `T-65`); read-only reentrancy (`T-72`, `T-73`); one account affecting another (`T-61`, `T-62`, `T-63`).

## 3. General assumptions and simplifications

| Assumption | Used by | Justification and discharge |
|---|---|---|
| Accounts unrolled to 2 collateral markets and 3 debt reserves; batches to 4 calls; the served price to 4 legs | `FV-CTL-16`…`22`, `43`, `44`, `71` | Each gate is a conjunction over reserves, so a counterexample needs one reserve. Discharged on code by the prover rules in [audit-mapping.md](audit-mapping.md) with `loop_iter` 3 and a non-optimistic run. |
| `keccak256` is injective (CREATE2 addresses, salts, ERC-7201 roots) | `FV-CTL-88`, `89`, `90` | Collision resistance. |
| Aave V4 `borrowCount` counts exactly the reserves with non-zero debt | `FV-CTL-40-FIX` | `Spoke.repay` at `a3ef63e` restores premium before drawn debt and clears the borrowing flag at zero drawn shares. Fork test on a full repay with premium. |
| The health factor is Aave's floored WAD value read after the Spoke call | `FV-CTL-38` | `SPEC-PROXY-006`, `REQ-ADAPTER-026`. |
| The LPOracle per-read facts (failed, `S_ts`, route timestamps, disagreement, other Drifting reasons, Expired-by-timestamps, recovery evidence) are what 2.10's pipeline computes | `FV-CTL-63`…`70`, `72` | The arithmetic of the pipeline is checked separately (`FV-CTL-71`, `73`…`76`). Gas is one flag per call; the `pokeMinGas` behaviour on real gas is a Foundry test, as the methodology prescribes. |
| Bounds: route answers ≤ `MAX_ROUTE_ANSWER` (10¹²); `L < 2^120`; `price8 < 2^64`; decimals 6–18 | `FV-CTL-53`, `57`, `73`, `76` | 1.5 registry, `REQ-CONFIG-022`. |
| Role checks are uninterpreted: any role map is covered | `FV-CTL-01`, `07` | The deployed map is the live-config check. |
| The circuit-breaker and address-freeze rules are encoded from their approved description in two readings: as described, and as recommended | `FV-CTL-91`…`96` | The rules are not yet in the spec; the checks carry over once they are written. |

**OpSec assumptions the results rely on.** These cannot be proved in a model; each is a monitored deployment property.

1. **Signer independence.** The governance multisig (4-of-7), the Emergency Guardian (3-of-5) and the Aave Protocol Guardian have pairwise disjoint signer sets (`REQ-ACCESS-104`), and no single organisation reaches a quorum in two of them. Every conclusion of the form "a guardian cancels it" (`FV-CTL-21`, `22`, `24-FIX`, `26-FIX`, `95-FIX`) assumes at least one canceller is not compromised together with the proposer.
2. **Quorum availability and cancel latency.** At least one canceller reaches quorum inside the short delay (12 hours), and the Aave governance executor completes a cancel inside the normal delay. If Aave's proposal, vote and execution timeline does not fit inside `normalDelay`, `DAO_CANCELLER_ROLE` cannot stop a role-change operation in time, and `FV-CTL-F-01` becomes High.
3. **Monitoring.** Every scheduled operation raises an alert that reaches borrowers and cancellers; role changes, `setNormalDelay`, `setShortDelaySelector` and `togglePublicExecution` alert at once (`REQ-ACCESS-017`, `REQ-ACCESS-024`). The exit-window results (`FV-CTL-25`) assume a borrower reacts within 3 days.
4. **Keys.** The deployer holds no role after deployment (`REQ-ACCESS-027`). Keeper keys belong to distinct operators on independent infrastructure, so the keeper floor counts independent keepers.
5. **Keepers poke.** `FV-CTL-69-FIX` relies on a poke at least once per heartbeat (`REQ-ORACLE-037`).

**Unproved assumptions.** Aave's liquidation sizing and dust rule (fork tests `TEST-109`…`TEST-111`); the sum of Borrow Spoke `drawCap`s per asset (Aave configuration, live-config check); the storage-layout diff on real `forge inspect` output (`TEST-137`; this model checks the comparison rule only).

## 4. Findings summary

| Impact \ Likelihood | Low | Medium | High |
|---|---|---|---|
| **High** | Medium: F-01, F-02, F-03, F-04 | — | — |
| **Medium** | Low: F-06, F-07, F-08, F-10 | — | — |
| **Low** | Low: — | Low: F-09 | — |

Informational (no security consequence, or a methodology or text defect): F-11 … F-17. All 16 were changed in the spec, and their proving checks pass against the final pages in run `FV-CTL-R3` (section 12.3); that run found `FV-CTL-F-18` … `F-24` (section 12.4).

| ID | Title | Severity | Checks |
|---|---|---|---|
| FV-CTL-F-01 | A role-change operation hands out admin power that no guardian can cancel and that then acts without delay | Medium | `FV-CTL-01`, `03`, Quint `FV-CTL-98` |
| FV-CTL-F-02 | Exits and the health floor depend on the upgradeable MarketRegistry | Medium | `FV-CTL-40`, `41` |
| FV-CTL-F-03 | `buySlippageAllowanceBps` has no liquidation-liveness bound; a short-delay tighten halts non-GHO liquidation | Medium | `FV-CTL-57`, `57-EX` |
| FV-CTL-F-04 | Address freeze as described blocks exits and liquidation and can target protocol addresses | Medium | `FV-CTL-91`, `92`, `93`, `95` |
| FV-CTL-F-06 | The short-delay list can admit risk-raising and loosening selectors | Low | `FV-CTL-24`, `62` |
| FV-CTL-F-07 | `normalDelay` can be cut to 12 hours, voiding the exit-window guarantee | Low | `FV-CTL-26` |
| FV-CTL-F-08 | The grace-window fallback starts grace before the recovery (contradicts `INV-031`) | Low | `FV-CTL-70` |
| FV-CTL-F-09 | A cancelled market registration makes its pool unlistable for life | Low | `FV-CTL-81` |
| FV-CTL-F-10 | A reinitializer in a PositionProxy implementation is callable by anyone after a proxy-code change (history: the AMM-neutral design has no upgradeable proxy code, section 13.1) | Low | `FV-CTL-87` |
| FV-CTL-F-11 | Pages disagree on short-delay selectors for the USD band and grace parameters | Informational | `FV-CTL-58` |
| FV-CTL-F-12 | `REQ-CONFIG-050` forbids the zero per-call cap that the SettlementBudget allows | Informational | `FV-CTL-60` |
| FV-CTL-F-13 | An unobserved recovery leaves `failedSince` stale; the next failure is reported Expired at once | Informational | `FV-CTL-69` |
| FV-CTL-F-14 | `checkRecordBacking` reverts on overflow instead of returning an empty page | Informational | `FV-CTL-77` |
| FV-CTL-F-15 | `predictProxy` views diverge from the stored proxy after a ProxyManager upgrade (history: the ProxyManager is immutable in the AMM-neutral design, section 13.1) | Informational | `FV-CTL-90` |
| FV-CTL-F-16 | Methodology targets `T-60` and `T-65` claim "any implementation" scope the design does not give | Informational | `FV-CTL-45`, `11` |
| FV-CTL-F-17 | Circuit-breaker design requirements (attacker-movable triggers, reset path, recording failures) | Informational | `FV-CTL-96` and section 7 |

(There is no F-05; the guardian-cancel part of the address freeze is folded into F-04.)

Findings of run `FV-CTL-R5` (AMM-neutral design, section 13.3), open:

| ID | Title | Severity | Checks |
|---|---|---|---|
| FV-CTL-F-25 | Delay-class pages disagree after the AMM-neutral renames (resolved in `FV-CTL-R6`) | Informational | `FV-CTL-58` |
| FV-CTL-F-26 | Short tighten selectors of 2.9 and 2.13 are missing from `SHORT_ELIGIBLE`, which names a selector 2.9 does not define | Low | `FV-CTL-153` |
| FV-CTL-F-27 | The Lens and the flash-fee ceiling round the premium bound up while LPVaultSwap compares exact products (resolved in `FV-CTL-R6`) | Low | `FV-CTL-78` |
| FV-CTL-F-28 | 1.4 still states the old proxy key, the four-member Lock and old LPVault function names | Informational | `FV-CTL-04` |
| FV-CTL-F-29 | `REQ-ADAPTER-036` states a Hub → Adapter vault-token path that the token refuses | Informational | `FV-CTL-162` |

## 5. Detailed findings

### FV-CTL-F-01 — A role-change operation hands out admin power that no guardian can cancel and that then acts without delay

- **Severity:** Medium (Impact High, Likelihood Low). **Status:** open.
- **Spec rules:** `REQ-ACCESS-002`, `REQ-ACCESS-003`, `REQ-ACCESS-019`, `REQ-ACCESS-032`, `REQ-ACCESS-083`, `REQ-ACCESS-111`, `REQ-ACCESS-113`, `REQ-ADAPTER-003`, `SPEC-GOV-005`, `INV-068`, 1.4 compromised-key table.
- **Violated property:** `T-53` "`APPLICATION_ADMIN` is held only by the AvanaTimelock"; `T-64` "only the AvanaTimelock … can upgrade"; `FV-CTL-01` (inductive admin invariant), `FV-CTL-03`, Quint `upgradesGuardianCancellable` and `adminOnlyTimelock`.
- **Description.** The admin invariant is enforced only at initialization. `grantRole(APPLICATION_ADMIN, X)` on any upgradeable contract, or `grantRole(DEFAULT_ADMIN_ROLE, X)` on the timelock, is a pure role-change operation, so only `DAO_CANCELLER_ROLE` can cancel it (`SPEC-GOV-005`). Once it executes, `X` calls `upgradeToAndCall`, `setProxyImplementation`, any setter or `unpause` directly, with no further delay and no canceller. `SPEC-GOV-005`'s own rationale (a proposer must not shield a harmful call from the guardians) is defeated: the harmful call is the grant itself. `REQ-ACCESS-111` ("no account may, except through a timelock operation that waited its required delay, upgrade") and `REQ-ACCESS-113` ("every canceller can stop it") fail for the upgrade `X` performs.
- **Counterexample.** Z3 step: caller = timelock (holds `DEFAULT_ADMIN_ROLE`), `GRANT(APP_ADMIN, 0)` → `hasRole(APP_ADMIN, 0)` with `0 ≠ TIMELOCK`. Trace (Quint, 4 steps): at 1,780,000,000 the compromised governance multisig schedules `[AaveAdapter.grantRole(APPLICATION_ADMIN, X)]`; the Emergency Guardian's and the Aave Protocol Guardian's `cancel` revert `RoleChangeCancelRestricted`; at 1,780,432,000 anyone executes it; `X` calls `AaveAdapter.upgradeToAndCall(hostile, "")` in the next block. The Adapter blast radius (borrow every reserve to each `drawCap`, withdraw supplied vault tokens) then applies with no cancel window for the upgrade.
- **Recommendation (exact spec change).** Add to 2.15 Configuration rules: "`REQ-ACCESS-153` — Every upgradeable Avana contract MUST override `_grantRole` to revert `AdminRoleOnlyTimelock(role, account)` when `role` is `DEFAULT_ADMIN_ROLE` or `APPLICATION_ADMIN` and `account != TIMELOCK`, and the AvanaTimelock MUST revert the same error when `role == DEFAULT_ADMIN_ROLE` and `account != address(this)`. A move to a new timelock is an upgrade of each contract to an implementation whose `TIMELOCK` constant names it, at the normal delay and cancellable by every canceller." Amend `REQ-ACCESS-032` to "Upgrade and admin authority never leaves the timelock", and the governance-multisig row of the 1.4 compromised-key table to remove "grant roles" as a route to admin power. `FV-CTL-01-FIX`, `FV-CTL-03-FIX` and Quint `gov_fixed` verify the change.

### FV-CTL-F-02 — Exits and the health floor depend on the upgradeable MarketRegistry

- **Severity:** Medium (Impact High, Likelihood Low). **Status:** open.
- **Spec rules:** `REQ-PROXY-027`, `REQ-PROXY-033`, `REQ-PROXY-034`, `REQ-PROXY-035`, `REQ-PROXY-037`, `REQ-ACCESS-068`, `REQ-ADAPTER-047`, `INV-025`, `INV-043`, `INV-045`; scope labels of 4.1.
- **Violated property:** `T-57` repay liveness and `T-58` health floor, evaluated for any MarketRegistry implementation (`FV-CTL-41`, `FV-CTL-40`).
- **Description.** The scope labels of 4.1 put the MarketRegistry in "any implementation", and its blast radius is "misprice gates, list bad routes, pause; cannot move funds". But `repay` reverts `UnknownDebtReserve` unless `MARKET_REGISTRY.isApprovedDebtReserve` is true; `withdraw` reads `marketOfVaultToken`, the market's `reserveId` and `getDebtReserveIds` from it. A faulty MarketRegistry therefore (a) blocks every repay and withdrawal (`REQ-ADAPTER-047` assumes only the pause read matters), and (b) returning an empty `getDebtReserveIds` turns a withdraw-with-debt into the debt-free path: no pause check, no RiskModule, no health floor, so the account can leave at Aave's HF = 1 instead of 1.10/1.05.
- **Counterexample.** `FV-CTL-40`: debts (1, 1, 1) in three reserves, MarketRegistry lists none → Adapter classifies the account debt-free. `FV-CTL-41`: every Aave precondition holds, `isApprovedDebtReserve = false` → repay reverts.
- **Recommendation.** Amend `REQ-PROXY-034`: "debt-free ⇔ `spoke.getUserAccountData(proxy).borrowCount == 0`" (the predicate the RiskModule already uses for top-ups, so the two classifications coincide). Amend `REQ-PROXY-027`: drop the `UnknownDebtReserve` check from `repay` (repaying any reserve the Spoke accepts only lowers debt; the Spoke rejects unknown reserves itself). Amend `REQ-PROXY-033`/`REQ-PROXY-037`: resolve the market and `reserveId` for a withdrawal from the vault token's immutables and the Hub and Spoke (`HUB.getAssetId(vaultToken)`, `spoke.getReserveId(HUB, assetId)`), not from the MarketRegistry. If the reads stay, add to the MarketRegistry blast radius in 1.3, 4.1 `INV-018` and `REQ-PSTORE-003`'s sibling: "a faulty MarketRegistry can block repay and withdrawal and can bypass the health floor down to Aave's HF 1", and scope `INV-043`, `INV-045` to "reviewed AaveAdapter and MarketRegistry". `FV-CTL-40-FIX` and `FV-CTL-41-FIX` verify the first option.

### FV-CTL-F-03 — `buySlippageAllowanceBps` has no liquidation-liveness bound

- **Severity:** Medium (Impact High, Likelihood Low). **Status:** open.
- **Spec rules:** `INV-047`, `INV-046`, `REQ-PSTORE-006`, `REQ-ACCESS-151`, `REQ-CONFIG-052`, `SPEC-LIQ-015`, 2.15 "Liquidation-liveness bounds".
- **Violated property:** `T-71` "every tighten setter … stays inside its … liquidation-liveness bounds"; `INV-047` lists `buySlippageAllowanceBps` among setters whose every accepted value keeps `INV-046` satisfiable.
- **Description.** The only bounds are `[1, 300]` bps. `tightenBuySlippageAllowanceBps` runs at the short delay and may set 1 bps. `SPEC-LIQ-015` then caps the buy leg at `⌈debtToCover × Pdebt / Pgho × 1.0001⌉`, below the cost of any real route, so both buy routes revert `GhoSpendTooHigh` and no account holding that debt can be liquidated. The RiskModule's `DebtLiquidationHalted` looks only at route usability flags, so borrowing of that asset continues.
- **Counterexample.** `FV-CTL-57-EX`: USDC debt `debtToCover = 5,000,000,000` (5,000 USDC), `Pdebt = Pgho = 1.00`, `buySlippageAllowanceBps` tightened from 30 to 1: bound = 5,000.5 GHO; a GSM buy with a 0.20 % fee spends 5,010 GHO > bound; the DEX backup costs more. 12 hours after scheduling, USDC-debt liquidation stops.
- **Recommendation.** Add to 2.9: "`REQ-PSTORE-015` — Each non-GHO debt reserve MUST store `buySlippageAllowanceMinBps(spoke, debtReserveId)`, set in its listing batch to at least the larger of its two buy routes' fee plus expected price impact at `buyRouteDepthThresholdGho`, changed only by `setBuySlippageAllowanceMinBps` (normal delay), which reverts if the new value is above the current `buySlippageAllowanceBps`; `tightenBuySlippageAllowanceBps` reverts `LivenessBound` below it." Add the row to `REQ-CONFIG-052`, 2.15 `REQ-ACCESS-095`…`100` and `INV-047`'s liveness list, and the parameter to 1.5. Also have `RiskModule` refuse borrowing of a reserve whose buy routes cannot fill within the allowance (`DebtLiquidationHalted`). `FV-CTL-57-FIX` verifies the bound.

### FV-CTL-F-04 — Address freeze as described blocks exits and liquidation and can target protocol addresses

- **Severity:** Medium (Impact High, Likelihood Low). **Status:** open (design check of an approved rule not yet in the spec).
- **Spec rules affected:** `REQ-ACCESS-068`, `REQ-ACCESS-089`, `REQ-ACCESS-112`, `REQ-ROLE-055`, `INV-046`, `INV-067`, `SPEC-GOV-005`, `SPEC-GOV-008`.
- **Violated properties:** "no combination of breaker, pause, freeze or offboarding blocks repay, debt-free withdrawal or liquidation of anyone" (`FV-CTL-91`, `92`); "the guardian cannot freeze the timelock, the Aave executor or LPVaultSwap" (`FV-CTL-93`); guardian powers bounded by one normal delay (`FV-CTL-95`).
- **Counterexamples.** (1) A frozen wallet with zero debt calls `AaveAdapter.withdraw`: the freeze check at the Adapter entry point reverts, so its debt-free withdrawal is blocked (`FV-CTL-91`, case `["None", false, false, true], withdraw_debt_free`); `repayAllAndWithdraw` likewise. (2) The guardian freezes `LPVaultSwap`: `AaveAdapter.burnSeized` is an Adapter entry point called by LPVaultSwap, so every liquidation and `settlePending` reverts (`FV-CTL-92`). (3) Freezing every approved keeper leaves only `liquidatePermissionless`, which has no budget draw and no in-kind mode, so accounts that need either cannot be liquidated, and the keeper floor (`SPEC-GOV-008`) is bypassed because frozen keepers still count as approved. (4) Freezing the timelock at the Adapter blocks upgrades of the Adapter; if `unfreezeAddress` lives behind the same check, the timelock can never unfreeze itself. (5) The freezing guardian cancels every `unfreezeAddress` operation (any canceller may cancel a non-role-change operation), keeping its victim frozen until the guardian is removed by a role-change operation and a fresh unfreeze executes: two normal delays.
- **Recommendation (text for the new rule).** "The address freeze MUST apply only to `pledge`, `borrow`, the with-debt branch of `withdraw`, `ProxyManager.deployProxy` for a frozen wallet, and to a frozen address as the caller of `liquidate` or `liquidatePermissionless`; it MUST NOT apply to `repay` (as payer or borrower), the debt-free branch of `withdraw`, `repayAllAndWithdraw`, `LPVault.collectFees`, `Collateralization.releaseZeroCredit`, `settlePending`, `burnSeized` or any contract-to-contract call. `freezeAddress` MUST revert for the AvanaTimelock, the Aave governance executor, every Avana contract, the Hub, every approved Spoke, the GHO FlashMinter and every route, and for an approved keeper when the approved keepers that are not frozen would fall below `keeperFloor`; `approvedKeeperCount` for the floor counts unfrozen keepers only. `unfreezeAddress` is an `APPLICATION_ADMIN` operation at the normal delay that only `DAO_CANCELLER_ROLE` can cancel." `FV-CTL-91-FIX`, `92-FIX`, `93-FIX`, `95-FIX` verify it; `FV-CTL-94` shows a frozen address is released only by a timelock `unfreezeAddress` (given F-01's fix).

### FV-CTL-F-06 — The short-delay list can admit risk-raising and loosening selectors

- **Severity:** Low (Impact Medium, Likelihood Low). **Spec rules:** `REQ-ACCESS-016`, `REQ-ACCESS-141`, `REQ-ACCESS-142`, `REQ-ROLE-105`, `REQ-CONFIG-053`, `REQ-PSTORE-002`.
- **Violated property:** "the short-delay list can only reduce risk or restore reviewed configuration" and "loosening always waits the normal delay" (`FV-CTL-24`, `FV-CTL-62`).
- **Counterexample.** `setShortDelaySelector(MarketRegistry, setRoute, true)` passes `REQ-ACCESS-142` (only role, upgrade, beacon and initializer selectors and the timelock are refused). After that one normal-delay operation, new route code (or `setPriceSource`, `addKeeper`, any `loosen*`) executes 12 hours after scheduling, below the 3-day borrower reaction the exit window assumes.
- **Recommendation.** Amend `REQ-ACCESS-142`: "The constructor MUST fix an immutable set `SHORT_ELIGIBLE` of `(target, selector)` pairs equal to the launch short-delay list; `setShortDelaySelector(target, selector, true)` MUST revert `InvalidShortDelaySelector` unless the pair is in `SHORT_ELIGIBLE`; disabling any entry is allowed." Adding a new short-eligible selector then needs a new timelock deployment (role-change operations on every contract). `FV-CTL-24-FIX` verifies it.

### FV-CTL-F-07 — `normalDelay` can be cut to 12 hours, voiding the exit-window guarantee

- **Severity:** Low (Impact Medium, Likelihood Low: the cut is itself a normal-delay operation every canceller can cancel). **Spec rules:** `SPEC-GOV-003`, `SPEC-GOV-012`, `SPEC-GOV-014`, `REQ-ACCESS-125`, `REQ-ACCESS-140`, `REQ-ACCESS-148`, `REQ-ROLE-104`, `INV-068`.
- **Violated property:** `REQ-ACCESS-148` / `REQ-ROLE-104` "the normal delay MUST be at least the time a borrower needs to leave plus the cancellers' reaction time" (`FV-CTL-26`).
- **Counterexample.** After `setNormalDelay(43,200)`, an AaveAdapter upgrade is ready 43,200 s after scheduling; a borrower with one NFT and the 3-day reaction of `SPEC-GOV-014` needs 259,224 s > 43,200.
- **Recommendation.** Add constant `MIN_NORMAL_DELAY = 345,600` (4 days) to the AvanaTimelock; `setNormalDelay` requires `MIN_NORMAL_DELAY ≤ newDelay ≤ MAX_DELAY` (`DelayOutOfBounds` otherwise) in `SPEC-GOV-003`, `SPEC-GOV-012`, `REQ-ACCESS-125`, `REQ-ACCESS-140`, `INV-068` and 1.5. `FV-CTL-26-FIX` proves the exit guarantee for a 3-day reaction and up to 7,199 NFTs at every reachable delay. (Alternatively keep `[SHORT_DELAY, MAX_DELAY]` and state in `REQ-ACCESS-148` that the exit guarantee holds only while `normalDelay ≥ r + 12·(k + 1)`.)

### FV-CTL-F-08 — The grace-window fallback starts grace before the recovery

- **Severity:** Low (Impact Medium: accounts in `[graceHealthFactor, 1)` lose the grace window; Likelihood Low). **Spec rules:** `REQ-ORACLE-032`, `REQ-ORACLE-034`, `SPEC-ORC-014`, `INV-031`.
- **Violated property:** `INV-031` "`recoveredAt` is the `updatedAt` of the first fresh round after the outage" (`FV-CTL-70`).
- **Counterexample.** Token1's both routes were Stale long enough to latch Expired; its alternate is now Invalid, so `SPEC-ORC-014` gives no interval and `REQ-ORACLE-032` falls back to `min(t0, t1)`. Token0 is on a 24-hour leg last updated 50,000 s ago. `recoveredAt = now − 50,000`, so with `graceDuration = 1,800` the window ended before it started and accounts at HF 0.97 are liquidated at the first fresh price. (Z3: `t0 = 1 < t1 = 2 = recovery`, `recoveredAt = 1`.)
- **Recommendation.** In `REQ-ORACLE-032` replace "to `min(t0, t1)` of the fresh price" with "to `max(t0, t1)` of the fresh price (the newest input, at or after the recovered token's first fresh round and never after `now`)". `FV-CTL-70-FIX` verifies `trueRecovery ≤ recoveredAt ≤ now`.

### FV-CTL-F-09 — A cancelled market registration makes its pool unlistable for life

- **Severity:** Low (Impact Low, Likelihood Medium: `cancelRegistration` is the documented path for a listing whose Aave payload or activation check fails). **Spec rules:** `REQ-CONFIG-007`, `REQ-CONFIG-032`, `REQ-CONFIG-048`, `REQ-VTOKEN-021`, `REQ-VTOKEN-038`.
- **Violated property:** `REQ-CONFIG-048` frees the pool's keys so the pool can be registered again (`FV-CTL-81`).
- **Counterexample.** Batch `[deployVaultToken(P, marketId = 1), registerMarket(P)]`, then `cancelRegistration(1)`. Relisting with a new token: `deployVaultToken` reverts `TokenExistsForPool` (factory slot is write-once). Relisting with the existing token: `registerMarket` assigns ID 2 but `token.marketId() == 1`, so `VaultTokenMismatch`. Also `REQ-CONFIG-007` ("at most one market for the life of the contract") contradicts `REQ-CONFIG-048` (frees keys).
- **Recommendation.** Amend `REQ-CONFIG-032` and `REQ-CONFIG-048`: "`cancelRegistration` keeps the cancelled `marketId` reserved for its pool; a later `registerMarket` for a pool whose factory token already exists MUST reuse the cancelled `marketId` that token carries (and require its `lpOracle` to match), instead of `marketCount + 1`." State in `REQ-CONFIG-007` that a key maps to at most one non-cancelled market. `FV-CTL-81-FIX` verifies relisting.

### FV-CTL-F-10 — A reinitializer in a PositionProxy implementation is callable by anyone after a beacon change

- **Severity:** Low (Impact Medium, Likelihood Low). **Spec rules:** `REQ-PROXY-005`, `REQ-PROXY-007`, `REQ-PROXY-086`, `REQ-ACCESS-031`.
- **Violated property:** `T-64` "implementations cannot be initialised" / no front-runnable reinitializer (`FV-CTL-87`).
- **Description and counterexample.** UUPS contracts run `reinitializer(n)` atomically inside `upgradeToAndCall` (`REQ-ACCESS-031`). A beacon change (`setProxyImplementation`) has no per-proxy call, and the spec puts no caller rule on a reinitializer in a PositionProxy implementation, so after the change any address can call it first on every proxy (case `Beacon, reinitializer present, no guard, caller = anyone`).
- **Recommendation.** Add to `REQ-PROXY-005`: "A PositionProxy implementation MUST NOT contain an `initializer` other than the first or any `reinitializer`; new per-proxy storage is initialized lazily inside an `OnlyAdapter` function." `FV-CTL-87-FIX` verifies it.

### FV-CTL-F-11 — Pages disagree on short-delay selectors for the USD band and grace parameters (Informational)

1.5 (`usdBandLow/High` "Short (narrow)", `graceDuration` "Short (lower)", `graceHealthFactor` "Short (raise)"), 3.8 `MKT-027` and 1.4 `REQ-ROLE-027`/`REQ-ROLE-105` ("every `tighten*` setter") give these parameters short-delay tighten selectors; 2.9 `REQ-CONFIG-049` makes them structural (normal) and neither 2.9 nor the 2.15 launch short-delay list has a tighten selector for them (`FV-CTL-58`). Recommendation: either add `tightenUsdBand(low, high)` (narrow only), `tightenGraceDuration` (lower only) and `tightenGraceHealthFactor` (raise only, `< 1e18`) to 2.9 and to the 2.15 short list, or change the 1.5 class column and `MKT-027` to "Normal". The second keeps 2.15 as the single definition.

### FV-CTL-F-12 — `REQ-CONFIG-050` forbids the zero per-call cap the SettlementBudget allows (Informational)

`REQ-CONFIG-050` requires `floorRoundingAllowanceGho ≤ perCallCap(spoke, r)` for every approved debt reserve, but `REQ-BUDGET-017` and `REQ-BUDGET-022` allow `perCall = 0` (a new reserve before `loosenCaps`, or `tightenCaps(…, 0, …)`). Counterexample (`FV-CTL-60`): `perCall = 1, allowance = 1`, `tightenCaps(0, 0)` succeeds → `allowance > perCall`; `loosenFloorRoundingAllowanceGho` is then blocked for every positive value. Recommendation: in `REQ-CONFIG-050`, `REQ-ACCESS-132`, `REQ-ACCESS-058` and 1.4 `REQ-ROLE-027`, write "every non-zero `perCallCap`". `FV-CTL-59` proves the corrected invariant.

### FV-CTL-F-13 — An unobserved recovery leaves `failedSince` stale (Informational)

`REQ-ORACLE-027` clears `failedSince` only at a poke that sees the market not failed. Counterexample (`FV-CTL-69`): poke at 1,000,000 records a caught error (`failedSince = 1,000,000`); the feed recovers at 1,000,600 with no poke; a new failure starts at 1,004,000 and the poke at 1,004,100 computes `failureStart = 1,000,000`, so the market is Expired at once instead of Cached until 1,007,600. Liquidation and borrowing gating are the same in Cached and Expired, and the latch is not affected (it needs source timestamps), so there is no security consequence. Recommendation: add to `SPEC-ORC-013`: "Cached is measured from the first failed read observed since the last poke that saw the market not failed; with keepers poking per `REQ-ORACLE-037` the difference is at most one heartbeat." `FV-CTL-69-FIX` verifies the property under that cadence.

### FV-CTL-F-14 — `checkRecordBacking` reverts on overflow instead of returning an empty page (Informational)

`REQ-LENS-014` walks `offset … min(offset + limit, nextRecordId) − 1`; with checked arithmetic, `offset = 2^256 − 8`, `limit = 200` reverts, contradicting `REQ-LENS-024` (empty page past the end) (`FV-CTL-77`). Recommendation: in `REQ-LENS-014`, "return an empty page when `offset ≥ nextRecordId`; otherwise walk `offset` to `offset + min(limit, nextRecordId − offset) − 1`". `FV-CTL-77-FIX` verifies no overflow.

### FV-CTL-F-15 — `predictProxy` views diverge from the stored proxy after a ProxyManager upgrade (Informational)

`predictProxy` hashes the BeaconProxy creation code compiled into the ProxyManager implementation and the `initialize(wallet, spoke)` call data. A ProxyManager upgrade that changes either changes every predicted address, so `Lens.predictProxy` returns `(new address, deployed = true)` and `RiskModule.previewPledge` previews an empty account for an existing borrower (`FV-CTL-90`). Recommendation: `REQ-LENS-008`, `REQ-PROXY-049` and `REQ-RISK-031` return `ADAPTER.proxyOf(wallet, spoke)` when it is non-zero and the prediction otherwise; `REQ-PROXY-050` adds "a ProxyManager upgrade MUST keep the BeaconProxy creation-code hash and the `initialize` selector". `FV-CTL-90-FIX` verifies it.

### FV-CTL-F-16 — Methodology targets claim scope the design does not give (Informational)

`T-60` says the reserve-flag refusal "holds for any RiskModule", but `Q-229` moved the frozen-collateral refusal from the immutable proxy into the RiskModule; with an arbitrary RiskModule only Aave's checks on the borrowed reserve remain (`FV-CTL-45`: borrow with a frozen collateral reserve). `INV-060` is correctly scoped to the reviewed RiskModule. `T-65` lists the AaveAdapter among implementations whose hostility the immutable contracts contain; `Q-223` and `INV-018` trust it for custody, and a hostile Adapter reaches `VaultToken.mint`, `addValidProxy`, `deployProxy`, `Collateralization.pledge` and `release` (`FV-CTL-11`). Recommendation: in methodology section 6.3, `T-60` reads "for the reviewed RiskModule; for any RiskModule, Aave refuses a paused or frozen borrowed reserve", and `T-65` drops AaveAdapter from its list. `FV-CTL-10` proves `T-65` for RiskModule, ParameterStore, MarketRegistry, LPOracle and LPVaultSwap.

### FV-CTL-F-17 — Circuit-breaker design requirements (Informational)

`FV-CTL-96` proves the breaker, the pause state and offboarding combine monotonically and never reach an exit or liquidation, provided the breaker is read only by the AaveAdapter's pledge, top-up, borrow and withdraw-with-debt paths. Three requirements follow for the rule text: (1) triggers based on TVL or liquidity drops must use windows one actor cannot move in one transaction (an LP withdrawing its own position or a borrower's debt-free exit must not trip a protocol-wide halt of new activity); (2) "repeated route or keeper failures" can be counted only from calls that succeed (a primary route failing over to the backup), because a reverted liquidation records nothing; the counter must never make a liquidation revert; (3) the reset path must be stated: if only the timelock resets a breaker, an attacker who can move a trigger halts new borrowing for one normal delay per trip. Recommended: automatic reset when the trigger condition has been false for a stated window, plus `APPLICATION_PAUSE_GUARDIAN` reset.

## 6. Bug-class sweep

| Bug class | Result | Evidence |
|---|---|---|
| Uninitialized or re-initialized proxies and beacon implementations | **Found** for beacon reinitializers (F-10). Ruled out for implementations and first initialization: `_disableInitializers()` makes every implementation uninitializable; each proxy initializer runs once in its creating call. | `FV-CTL-86`, `FV-CTL-87`, `FV-CTL-02` |
| Storage-layout collision on upgrade | Ruled out at the rule level: the append-only comparator accepts exactly appends and rejects every delete, retype, insert and reorder; ERC-7201 roots are distinct for distinct namespace IDs. The diff on real layouts is `TEST-137`. | `FV-CTL-88` |
| Privileged path that bypasses the timelock or delay class | **Found**: admin-role grants (F-01); short-list growth (F-06); `normalDelay` cut (F-07). Ruled out: `requiredDelay` cannot be undercut by batching, role/upgrade/beacon/timelock-config selectors are never short, every `APPLICATION_ADMIN`/`TIMELOCK` selector runs only as a timelock execution given the admin invariant. | `FV-CTL-01`, `03`, `07`, `16`, `17`, `23`, `24`, `26` |
| Re-registration or duplicate listing that overwrites state | Ruled out for overwrites: market keys, the factory's pool slot, debt-reserve approval and `addValidProxy` are write-once or idempotent. **Found** the opposite failure: a cancelled pool can never be relisted (F-09). | `FV-CTL-82`, `FV-CTL-83`, `FV-CTL-81` |
| Guardian that can block its own removal or block exits | Ruled out for the current spec: pure role changes are DAO-only cancel, guardians reach only freeze/pause/unfreeze/unpause/cancel, a freeze-only key cannot lift, and no pause state reaches an exit. **Found** in the address-freeze design (F-04: exits, liquidation, protocol addresses, cancelling unfreezes). | `FV-CTL-05`, `06`, `21`, `22`, `32`, `34`, `91`…`95` |
| Stale or manipulated prices accepted for borrowing | Ruled out: every collateral market Live and every input within `borrowPriceMaxAge` and not in the future; every debt source the recorded one and fresh, including the reserve being borrowed; the aggregate age limit equals the per-leg test; caching never refreshes a timestamp; disagreement, band, TWAP and clamp each make the market Drifting. | `FV-CTL-43`, `44`, `64`, `67`, `71`, `75` |
| Oracle state machine stuck or never expiring | Ruled out: fresh, valid, agreeing inputs give Live whatever is stored; a failed market is Expired at most `cachedWindow` after its failure start; the latch clears at the first non-failed poke; `poke` is idempotent and a gas-short poke changes nothing. Reporting quirk F-13 (Expired too early, never too late). | `FV-CTL-65`, `66`, `68`, `69` |
| One account's action changing another's position | Ruled out: every borrower entry point acts on `proxyOf[msg.sender][spoke]`; one proxy per pair; the proxy accepts only the Adapter; nonces are per proxy; a third-party repay pulls only from the payer and only lowers debt. | `FV-CTL-08`, `42`, `46`, `47`, `89` |
| Read-only reentrancy through Lens or views | Ruled out: every Lens function and every Collateralization and LPVault custody view reverts while the Lock is held; LPOracle views read only feeds and storage written by `poke`, which makes only static calls; the Lock admits only fixed members and named inner callers. | `FV-CTL-85`, `FV-CTL-97` |

## 7. Design check of the approved rules (circuit breakers, address freeze)

Proved for the recommended reading (`-FIX` checks): no combination of pause state, breaker, offboarding or address freeze blocks repay, debt-free withdrawal, fees, zero-credit release or pending settlement for anyone (`FV-CTL-91-FIX`); no set of up to four guardian freezes stops liquidation of an account that needs the keeper path (`FV-CTL-92-FIX`, bounded); the guardian cannot freeze the timelock, the Aave governance executor or LPVaultSwap (`FV-CTL-93-FIX`); a frozen address is unfrozen only by a timelock `unfreezeAddress` (`FV-CTL-94`), which only `DAO_CANCELLER_ROLE` can cancel (`FV-CTL-95-FIX`); breaker, pause and offboarding combine monotonically (`FV-CTL-96`). The described reading fails four of these (F-04); F-17 lists the breaker requirements. A frozen address can still move to a new wallet through a debt-free withdrawal and a new pledge: an address freeze limits an address, not a person.

## 8. Parameter drift

- Every risk parameter and every relational bound of the 1.5 Bounds column (`topUpSliceUsd ≤ marketUsdCap`, `borrowPriceMaxAge ≤ liquidationPriceMaxAge`, `feedHeartbeat < liquidationPriceMaxAge`, `slippageAllowanceMinBps ≤ slippageAllowanceBps`, `graceHealthFactorMin ≤ graceHealthFactor < 1e18`) stays satisfied under any sequence of tighten, loosen and structural calls, because the step case holds for every setter (`FV-CTL-61`, inductive; it relies on `REQ-CONFIG-050`'s rule that every setter enforces the Bounds column, both sides of each relation).
- Each tighten setter moves strictly in its safer direction and keeps hard and liveness bounds, evaluated at execution (`FV-CTL-56-1`…`7`).
- Loosening takes the normal delay only while no loosen selector is on the short-delay list; the spec does not prevent adding one (F-06, `FV-CTL-62`); with the `SHORT_ELIGIBLE` allowlist it holds (`FV-CTL-24-FIX`).
- One parameter has no liveness bound although `INV-047` claims one (F-03).

## 9. Comparison with the existing spec-stage models

Read after the results were in. `spec/05-verification/z3/governance/gv01_timelock_timing.py`: `MATH-GOV-05` proves the exit window at `delay ≥ 432,000` with the delay fixed, so it does not see F-07 (the delay can be cut to 43,200); `MATH-GOV-10` proves the every-call cancel rule, which `FV-CTL-21` confirms, but no model covers admin-role grants (F-01). `MATH-GOV-07` and `FV-CTL-31` agree on the pause transitions. No disagreement on a proved property was found.

## 10. Properties overview

The tables of sections 10, 11 and 12.6 record runs `FV-CTL-R1` and `FV-CTL-R3` as they ran. The checks changed or added for the AMM-neutral design are listed in section 13.

Sections 10 and 11 list the properties of run `FV-CTL-R1`; the properties of the re-verification against the final spec are in section 12.5.

| Target | Family | Status | Checks |
|---|---|---|---|
| T-53 role matrix, admin only timelock, self-only selectors | F-14 | Violated → F-01; matrix consistent | `FV-CTL-01`…`07` |
| T-54 required delay, window, `updateDelay`, normal-delay bounds | F-15/F-25 | Verified; F-06, F-07 | `FV-CTL-16`…`20`, `23`, `24`, `26` |
| T-55 cancel rights, self-held admin | F-14/F-25 | Verified (cancel rule); admin part → F-01 | `FV-CTL-21`, `22`, `01` |
| T-56 pause transitions and effects | F-15 | Verified | `FV-CTL-05`, `06`, `31`…`35` |
| T-57 repay liveness | F-03 | Verified for a reviewed MarketRegistry; → F-02 | `FV-CTL-41`, `42`, `34` |
| T-58 health floor after borrow and withdraw-with-debt | F-22 | Verified; MarketRegistry dependency → F-02 | `FV-CTL-38`, `39`, `40` |
| T-59 oracle gate on borrow | F-16 | Verified | `FV-CTL-43`, `44`, `71` |
| T-60 Aave reserve flags | F-15/F-04 | Verified (reviewed RiskModule); scope → F-16 | `FV-CTL-43`, `45` |
| T-61 borrow nonce | F-12 | Verified | `FV-CTL-46` |
| T-62 proxy binding | F-13 | Verified; view → F-15 | `FV-CTL-47`, `86`, `89`, `90` |
| T-63 proxy accepts only the Adapter | F-14 | Verified | `FV-CTL-08`, `09` |
| T-64 upgrade safety | F-18 | Violated → F-01, F-10; layout rule Verified | `FV-CTL-03`, `07`, `86`…`88` |
| T-65 containment | F-18 | Verified for RM/PS/MR/LPO/LPVaultSwap; scope → F-16 | `FV-CTL-10`, `11` |
| T-66 `latestAnswer` never reverts, ≥ 1 | F-16/F-03 | Verified | `FV-CTL-63`, `72` |
| T-67 source timestamps, cache, Cached → Expired | F-16 | Verified; F-08, F-13 | `FV-CTL-64`, `65`, `68`…`70` |
| T-68 Drifting reasons, disagreement pause | F-16 | Verified | `FV-CTL-67`, `68` |
| T-69 LPPriceMath | F-24/F-11 | Verified | `FV-CTL-73`…`76` |
| T-70 poke idempotency, gas, latch | F-09/F-15 | Verified; F-08 | `FV-CTL-65`, `66`, `70` |
| T-71 tighten/loosen bounds | F-25 | Verified; F-03, F-06, F-11 | `FV-CTL-56`, `57`, `58`, `61`, `62` |
| T-72 Lock | F-19 | Verified | `FV-CTL-85` |
| T-73 views locked mid-operation | F-19/F-10 | Verified | `FV-CTL-97` |
| T-74 Lens preview and paging | F-10/F-23 | Verified (bound equality); F-14 | `FV-CTL-77`, `78` |
| T-75 market lifecycle | F-15 | Verified; F-09 | `FV-CTL-79`…`83` |
| T-76 route records | F-14/F-23 | Verified | `FV-CTL-84` |
| T-77 pledge checks and charge | F-04/F-25 | Verified | `FV-CTL-53`…`55` |
| T-78 drift and Hub shares | F-15/F-04 | Verified | `FV-CTL-43` |
| T-79 SettlementBudget caps | F-25 | Verified; text F-12 | `FV-CTL-59`, `60` |
| T-80 drawCap configuration | F-04 | Verified (vault asset); sum of drawCaps out of scope | `FV-CTL-99` |
| Approved rules: breakers, address freeze | — | Violated as described → F-04, F-17; Verified as recommended | `FV-CTL-91`…`96` |
| Governance state machine (Quint) | F-15 | 6 invariants hold in 10,000 samples; 2 violated in `gov_spec` (F-01) | `FV-CTL-98` |

## 11. Detailed properties

Status values: Verified (Z3 unsat of the negation, or complete enumeration of a finite domain); Verified under bounded model (bound stated); Violated (counterexample in `results/`, linked to a finding); Quint runs are randomized simulation and are reported as "no violation in 10,000 samples", never as Verified. Every check is tagged in its source with `FV-CTL-NN verifies: …`; `check_ids.py` confirms every cited spec ID is defined (257 IDs, 0 undefined). The full log of the last run is `results/run.log`.

### Access control and upgrade authorisation (`fv_ctl_access.py`)

| Check | Targets | Property | Status | Method | Spec IDs |
|---|---|---|---|---|---|
| `FV-CTL-01` | T-53, T-64 | APPLICATION_ADMIN/DEFAULT_ADMIN_ROLE stay with the timelock across every role call (spec as written) | Violated | Z3 (sat of negation) | `REQ-ACCESS-002`, `REQ-ACCESS-003`, `REQ-ACCESS-014`, `REQ-ACCESS-032`, `INV-068` |
| `FV-CTL-01-FIX` | T-53, T-64 | APPLICATION_ADMIN/DEFAULT_ADMIN_ROLE stay with the timelock across every role call (with the recommended _grantRole guard) | Verified | Z3 (unsat of negation) | `REQ-ACCESS-002`, `REQ-ACCESS-003`, `REQ-ACCESS-014`, `REQ-ACCESS-032`, `INV-068` |
| `FV-CTL-02` | T-53, T-64 | Initializers grant DEFAULT_ADMIN_ROLE and APPLICATION_ADMIN to the timelock only (base case) | Verified | Z3 (unsat of negation) | `REQ-ACCESS-150`, `REQ-ACCESS-027` |
| `FV-CTL-03` | T-53, T-55, T-64 | Every Adapter upgrade is cancellable by every canceller (role-change shield) | Violated | Z3 (sat of negation) | `REQ-ACCESS-111`, `REQ-ACCESS-113`, `REQ-ADAPTER-003`, `REQ-ADAPTER-042`, `SPEC-GOV-005` |
| `FV-CTL-03-FIX` | T-53, T-55, T-64 | Every Adapter upgrade is cancellable by every canceller (role-change shield) with fix | Verified | Z3 (unsat of negation) | `REQ-ACCESS-111`, `REQ-ACCESS-113`, `REQ-ADAPTER-003`, `REQ-ADAPTER-042`, `SPEC-GOV-005` |
| `FV-CTL-04` | T-53, T-63 | Every page names the same allowed caller for each privileged selector (matrix consistency) | Verified | exhaustive enumeration (23 cases) | `REQ-ACCESS-025`, `REQ-ACCESS-066`, `REQ-ROLE-019`, `REQ-ROLE-015`, `REQ-MREG-004` |
| `FV-CTL-05` | T-53, T-56 | Guardian keys reach exactly freeze, pause, unfreeze, unpause and cancel | Verified | direct computation | `REQ-ACCESS-089`, `REQ-ACCESS-112`, `REQ-ACCESS-094` |
| `FV-CTL-06` | T-56 | A key holding only APPLICATION_FREEZE_GUARDIAN can call no lifting selector | Verified | direct computation | `REQ-ACCESS-086`, `REQ-ACCESS-124`, `REQ-ROLE-071` |
| `FV-CTL-07` | T-53, T-64 | Given the admin invariant, every APPLICATION_ADMIN or TIMELOCK selector runs only as a timelock execution | Verified | Z3 (unsat of negation) | `REQ-ACCESS-111`, `REQ-ACCESS-015`, `REQ-ACCESS-010` |
| `FV-CTL-08` | T-63 | A PositionProxy state change succeeds only for msg.sender == ADAPTER, never for its own wallet | Verified | Z3 (unsat of negation) | `REQ-PROXY-040`, `REQ-PROXY-087`, `REQ-PROXY-088`, `REQ-PROXY-089`, `REQ-ROLE-019` |
| `FV-CTL-08-W` | T-63 | Witness: the Adapter's call to the proxy succeeds | Verified | Z3 witness (sat) | `REQ-PROXY-040` |
| `FV-CTL-09` | T-63 | PositionProxy selector inventory contains no generic-call, signature, manager or upgrade selector | Verified | exhaustive enumeration (11 cases) | `REQ-PROXY-007`, `REQ-PROXY-008`, `REQ-PROXY-001` |
| `FV-CTL-10` | T-65 | No hostile RiskModule, ParameterStore, MarketRegistry, LPOracle or LPVaultSwap reaches mint, proxy registration, NFT return or budget withdrawal | Verified | exhaustive enumeration (5 cases) | `INV-052`, `INV-053`, `REQ-RISK-007`, `REQ-PSTORE-003` |
| `FV-CTL-11` | T-65 | A hostile AaveAdapter reaches VT.mint and proxy registration (methodology T-65 scope check) | Violated | direct computation | `INV-018`, `Q-223` |

Reproduce: `spec/05-verification/.venv/bin/python audit/formal-verification/control/fv_ctl_access.py`

### Timelock delays and cancel rights (`fv_ctl_timelock.py`)

| Check | Targets | Property | Status | Method | Spec IDs |
|---|---|---|---|---|---|
| `FV-CTL-16` | T-54 | schedule succeeds only with delay >= requiredDelay; one non-listed call makes the batch normal | Verified | Z3 (unsat of negation) | `SPEC-GOV-001`, `REQ-ACCESS-141`, `REQ-ACCESS-117`, `INV-068` |
| `FV-CTL-17` | T-54 | A batch never needs less delay than any of its parts (no riding a loosening on a tightening batch) | Verified | Z3 (unsat of negation) | `SPEC-GOV-001`, `REQ-ROLE-105` |
| `FV-CTL-18` | T-54 | From readyAt on an operation is exactly one of executable or expired; never executable before readyAt | Verified | Z3 (unsat of negation) | `SPEC-GOV-002`, `SPEC-GOV-013`, `REQ-ACCESS-118`, `REQ-ACCESS-126` |
| `FV-CTL-18-EX` | T-54 | SPEC-GOV-002 example: last executable second 1,781,641,599, expiry at 1,781,641,600 | Verified | direct computation | `SPEC-GOV-002` |
| `FV-CTL-19` | T-54 | After a normal-delay cut, any operation using the shorter delay executes no earlier than old + new after the cut was scheduled | Verified | Z3 (unsat of negation) | `SPEC-GOV-003`, `REQ-ACCESS-125`, `REQ-ACCESS-017` |
| `FV-CTL-20` | T-54 | normalDelay stays within [SHORT_DELAY, MAX_DELAY] (base 432,000; every step preserves it) | Verified | Z3 (unsat of negation) | `SPEC-GOV-012`, `REQ-ACCESS-030`, `REQ-ACCESS-140`, `REQ-ACCESS-125` |
| `FV-CTL-21` | T-55 | Every canceller can cancel any batch holding a non-role call; only DAO_CANCELLER cancels a pure role change | Verified | Z3 (unsat of negation) | `SPEC-GOV-005`, `REQ-ACCESS-019`, `REQ-ACCESS-020`, `REQ-ACCESS-119`, `REQ-ACCESS-143` |
| `FV-CTL-22` | T-55 | The cancel window lasts at least requiredDelay; a guardian's power ends by readyAt of its pure revocation | Verified | Z3 (unsat of negation) | `SPEC-GOV-007`, `SPEC-GOV-006`, `REQ-ACCESS-112` |
| `FV-CTL-23` | T-54, T-64 | No role, upgrade, beacon, initializer or timelock-config selector is ever on the short list, so those operations always wait the normal delay | Verified | exhaustive enumeration (31 cases) | `REQ-ACCESS-142`, `REQ-ACCESS-024`, `REQ-ACCESS-148`, `REQ-ACCESS-018` |
| `FV-CTL-24` | T-54 | setShortDelaySelector refuses every risk-raising selector (short list stays risk-reducing) | Violated | exhaustive enumeration (1 cases) | `REQ-ACCESS-016`, `REQ-ACCESS-141`, `REQ-ROLE-105` |
| `FV-CTL-24-FIX` | T-54 | With a constructor-fixed short-eligible allowlist, no risk-raising selector can become short | Verified | exhaustive enumeration (11 cases) | `REQ-ACCESS-016` |
| `FV-CTL-25` | T-64 | At the launch normal delay a borrower with a 3-day reaction and up to 14,399 NFTs exits before any normal-delay change | Verified | Z3 (unsat of negation) | `SPEC-GOV-014`, `REQ-ACCESS-148`, `INV-068` |
| `FV-CTL-25-EX` | T-64 | SPEC-GOV-014 example: k = 14,400 no longer fits (bound is exactly 14,399) | Verified | direct computation | `SPEC-GOV-014` |
| `FV-CTL-26` | T-64 | For every reachable normalDelay, a borrower with a 3-day reaction and one NFT exits before an upgrade executes | Violated | Z3 (sat of negation) | `REQ-ACCESS-148`, `REQ-ROLE-104`, `INV-068` |
| `FV-CTL-26-FIX` | T-64 | With normalDelay >= 345,600 the exit guarantee holds for a 3-day reaction and up to 7,199 NFTs | Verified | Z3 (unsat of negation) | `REQ-ACCESS-148`, `REQ-ROLE-104` |

Reproduce: `spec/05-verification/.venv/bin/python audit/formal-verification/control/fv_ctl_timelock.py`

### Pause state machine and exit liveness (`fv_ctl_pause.py`)

| Check | Targets | Property | Status | Method | Spec IDs |
|---|---|---|---|---|---|
| `FV-CTL-31` | T-56 | 2.15 SPEC-GOV-004 and 2.8 REQ-MREG-001/004 define the same transition and revert for every state, function and caller | Verified | exhaustive enumeration (96 cases) | `SPEC-GOV-004`, `REQ-MREG-001`, `REQ-MREG-004`, `REQ-ACCESS-085`, `REQ-ACCESS-122`, `REQ-ACCESS-123`, `INV-049` |
| `FV-CTL-32` | T-56 | A freeze-only key never leaves Frozen or Paused; P or A reaches None from every state; Paused never returns to Frozen | Verified | exhaustive enumeration (3 cases) | `SPEC-GOV-004`, `REQ-ACCESS-086`, `REQ-ACCESS-087`, `REQ-ROLE-071` |
| `FV-CTL-33` | T-56 | Every page's pause matrix equals the AaveAdapter/LPVaultSwap decision procedure for every state and action | Verified | exhaustive enumeration (210 cases) | `Q-227`, `REQ-ACCESS-072`, `REQ-ACCESS-073`, `REQ-ACCESS-074`, `REQ-MREG-002`, `INV-067`, `REQ-ADAPTER-045`, `REQ-ADAPTER-046`, `REQ-SWAP-003` |
| `FV-CTL-34` | T-56, T-57 | Repay, fees, debt-free withdrawal, zero-credit release, liquidation and pending settlement are open in every pause state | Verified | exhaustive enumeration (18 cases) | `REQ-ACCESS-068`, `REQ-ROLE-068`, `REQ-ADAPTER-047`, `REQ-RISK-040`, `LIQ-002` |
| `FV-CTL-35` | T-56 | A stronger pause state never allows an action a weaker one blocks | Verified | exhaustive enumeration (90 cases) | `SPEC-GOV-004`, `REQ-ACCESS-074` |

Reproduce: `spec/05-verification/.venv/bin/python audit/formal-verification/control/fv_ctl_pause.py`

### Borrow-side gates, health floor and repay liveness (`fv_ctl_gates.py`)

| Check | Targets | Property | Status | Method | Spec IDs |
|---|---|---|---|---|---|
| `FV-CTL-38` | T-58 | postHealthCheck passes only if the exact collateral/debt ratio is >= max(minOpeningHealthFactor, 1.05, minHealthFactor), whatever minOpeningHealthFactor is within bounds | Verified | Z3 (unsat of negation) | `SPEC-PROXY-001`, `SPEC-CF-003`, `REQ-ADAPTER-026`, `REQ-PROXY-022`, `INV-025`, `REQ-RISK-059` |
| `FV-CTL-38-W` | T-58 | Witness: a borrow leaving exactly hf = 1.10 passes | Verified | Z3 witness (sat) |  |
| `FV-CTL-39` | T-58 | Every Adapter path that can lower an indebted account's health ends with postHealthCheck (debt-free paths need zero debt) | Verified | direct computation | `REQ-ADAPTER-027`, `REQ-PROXY-046`, `REQ-ADAPTER-071`, `INV-025` |
| `FV-CTL-40` | T-58 | The Adapter's debt-free test never takes an indebted account down the unchecked path, for any MarketRegistry implementation | Violated | Z3 (sat of negation) | `REQ-PROXY-034`, `REQ-PROXY-035`, `INV-025`, `INV-045` |
| `FV-CTL-40-FIX` | T-58 | With debt-free decided by Spoke borrowCount == 0, the test is exact for any MarketRegistry | Verified | Z3 (unsat of negation) | `REQ-PROXY-034` |
| `FV-CTL-41` | T-57 | Repay succeeds whenever Aave allows it and the payer funds it, for any MarketRegistry implementation | Violated | Z3 (sat of negation) | `INV-043`, `REQ-PROXY-027`, `REQ-PROXY-032`, `REQ-ACCESS-068`, `REQ-ADAPTER-047` |
| `FV-CTL-41-FIX` | T-57 | With the MarketRegistry approval read removed from repay, repay liveness holds for any MarketRegistry | Verified | Z3 (unsat of negation) | `INV-043` |
| `FV-CTL-42` | T-57 | Repay pulls at most min(maxRepaySpend, live debt), exactly the debt for repay-all, and nothing at zero debt | Verified | Z3 (unsat of negation) | `SPEC-PROXY-003`, `REQ-PROXY-028`, `REQ-PROXY-083`, `REQ-PROXY-084` |
| `FV-CTL-43` | T-59, T-60, T-78 | A borrow passes preBorrowCheck only if every collateral market is Live and fresh (no future timestamps), no reserve of the account is paused or frozen, every debt source is the recorded one and fresh, no drift and Hub shares == assets | Verified | Z3 (unsat of negation) | `SPEC-PROXY-002`, `REQ-ADAPTER-015`, `REQ-ADAPTER-016`, `REQ-RISK-061`, `REQ-ADAPTER-061`, `REQ-ADAPTER-019`, `REQ-ADAPTER-021`, `INV-023`, `INV-024`, `INV-060`, `INV-029`, `INV-072` |
| `FV-CTL-43-W` | T-59 | Witness: a two-market, three-reserve account passes preBorrowCheck | Verified | Z3 witness (sat) |  |
| `FV-CTL-44` | T-59 | The borrowed reserve's price source and freshness are checked even before the account holds that debt | Verified | Z3 (unsat of negation) | `REQ-PROXY-019`, `SPEC-PROXY-002` |
| `FV-CTL-45` | T-60 | Methodology T-60 scope check: with an arbitrary RiskModule no borrow completes against a frozen collateral reserve | Violated | Z3 (sat of negation) | `INV-060`, `REQ-PROXY-079`, `Q-229` |
| `FV-CTL-46` | T-61 | borrowNonce rises by exactly 1 per successful borrow, is unchanged by a reverted one, and admits one borrow per nonce value | Verified | Z3 (unsat of negation) | `INV-019`, `REQ-PROXY-015` |
| `FV-CTL-47` | T-62 | A wallet's pledge, borrow or withdrawal can act only on its own proxy, never on another wallet's account | Verified | Z3 (unsat of negation) | `REQ-ADAPTER-066`, `REQ-PROXY-053`, `Q-223` |

Reproduce: `spec/05-verification/.venv/bin/python audit/formal-verification/control/fv_ctl_gates.py`

### RiskModule opening checks and parameter bounds (`fv_ctl_params.py`)

| Check | Targets | Property | Status | Method | Spec IDs |
|---|---|---|---|---|---|
| `FV-CTL-53` | T-77 | A pledge passes the minimum only if its exact value reaches minPledgeUsd; the booked charge is >= 1 and never below the value at the booking price | Verified | Z3 (unsat of negation) | `SPEC-CAP-001`, `REQ-RISK-057`, `REQ-PSTORE-005`, `REQ-VAULT-110`, `Q-230` |
| `FV-CTL-54` | T-77 | After a passing pledge: 0 < sliceUsd <= usdCharge only for an eligible top-up, the regular counter stays <= max(before, cap), the slice <= topUpSliceUsd, token counters exceed their cap by at most the slice | Verified | Z3 (unsat of negation) | `SPEC-CAP-002`, `REQ-RISK-025`, `INV-028` |
| `FV-CTL-55` | T-77 | Pledge price-state rule of the RiskModule equals the LPOracle state-effects table for new accounts and top-ups | Verified | exhaustive enumeration (12 cases) | `REQ-RISK-017`, `INV-026`, `REQ-ORACLE-015` |
| `FV-CTL-56-1` | T-71 | tightenMinOpeningHealthFactor moves only in the safer direction and preserves hard and liveness bounds | Verified | Z3 (unsat of negation) | `SPEC-GOV-011`, `SPEC-GOV-009`, `REQ-CONFIG-051`, `REQ-CONFIG-052`, `REQ-ACCESS-120`, `INV-047` |
| `FV-CTL-56-2` | T-71 | tightenSlippageAllowanceBps moves only in the safer direction and preserves hard and liveness bounds | Verified | Z3 (unsat of negation) | `SPEC-GOV-011`, `SPEC-GOV-009`, `REQ-CONFIG-051`, `REQ-CONFIG-052`, `REQ-ACCESS-120`, `INV-047` |
| `FV-CTL-56-3` | T-71 | tightenTwapToleranceTicks moves only in the safer direction and preserves hard and liveness bounds | Verified | Z3 (unsat of negation) | `SPEC-GOV-011`, `SPEC-GOV-009`, `REQ-CONFIG-051`, `REQ-CONFIG-052`, `REQ-ACCESS-120`, `INV-047` |
| `FV-CTL-56-4` | T-71 | tightenFeedAgreementToleranceBps moves only in the safer direction and preserves hard and liveness bounds | Verified | Z3 (unsat of negation) | `SPEC-GOV-011`, `SPEC-GOV-009`, `REQ-CONFIG-051`, `REQ-CONFIG-052`, `REQ-ACCESS-120`, `INV-047` |
| `FV-CTL-56-5` | T-71 | tightenMinPledgeUsd moves only in the safer direction and preserves hard and liveness bounds | Verified | Z3 (unsat of negation) | `SPEC-GOV-011`, `SPEC-GOV-009`, `REQ-CONFIG-051`, `REQ-CONFIG-052`, `REQ-ACCESS-120`, `INV-047` |
| `FV-CTL-56-6` | T-71 | tightenMarketUsdCap moves only in the safer direction and preserves hard and liveness bounds | Verified | Z3 (unsat of negation) | `SPEC-GOV-011`, `SPEC-GOV-009`, `REQ-CONFIG-051`, `REQ-CONFIG-052`, `REQ-ACCESS-120`, `INV-047` |
| `FV-CTL-56-7` | T-71 | tightenBuySlippageAllowanceBps moves only in the safer direction and preserves hard and liveness bounds | Verified | Z3 (unsat of negation) | `SPEC-GOV-011`, `SPEC-GOV-009`, `REQ-CONFIG-051`, `REQ-CONFIG-052`, `REQ-ACCESS-120`, `INV-047` |
| `FV-CTL-57` | T-71 | Every buySlippageAllowanceBps a setter accepts still admits an honest buy whose cost was validated at listing | Violated | Z3 (sat of negation) | `INV-047`, `INV-046`, `REQ-PSTORE-006`, `REQ-ACCESS-151`, `SPEC-LIQ-015` |
| `FV-CTL-57-EX` | T-71 | Concrete case: USDC debt 5,000 at $1, buySlippageAllowanceBps tightened to 1, a 20 bps route spends 5,010 GHO > bound 5,000.5 GHO (GhoSpendTooHigh on both routes) | Violated | direct computation | `INV-047`, `SPEC-LIQ-015` |
| `FV-CTL-57-FIX` | T-71 | With a per-reserve buySlippageAllowanceMinBps >= the route cost validated at listing, every accepted value admits the honest buy | Verified | Z3 (unsat of negation) | `INV-047`, `SPEC-LIQ-015` |
| `FV-CTL-58` | T-71, T-54 | Every page agrees on which parameters have a short-delay tighten selector | Violated | exhaustive enumeration (1 cases) | `REQ-CONFIG-049`, `REQ-ROLE-105`, `REQ-ACCESS-141`, `MKT-027` |
| `FV-CTL-59` | T-79 | perCall <= per24h <= PER_24H_CAP_MAX, perCall <= the per-call maximum, and a non-zero perCall >= floorRoundingAllowanceGho, across every cap and allowance setter | Verified | Z3 (unsat of negation) | `REQ-BUDGET-017`, `REQ-BUDGET-019`, `REQ-ACCESS-058` |
| `FV-CTL-60` | T-79 | REQ-CONFIG-050 as written: floorRoundingAllowanceGho <= perCallCap of every approved debt reserve, across every setter | Violated | Z3 (sat of negation) | `REQ-CONFIG-050`, `REQ-ACCESS-132`, `REQ-BUDGET-022` |
| `FV-CTL-61` | T-71 | Under any sequence of tighten, loosen and structural setter calls every risk parameter and every relational bound stays satisfied (inductive step) | Verified | Z3 (unsat of negation) | `REQ-CONFIG-050`, `REQ-CONFIG-052`, `REQ-CONFIG-023`, `REQ-ACCESS-095`, `REQ-ACCESS-096`, `INV-047` |
| `FV-CTL-99` | T-80 | No borrow, withdraw-with-debt or new-account pledge completes while any Spoke can draw the vault-token asset | Verified | Z3 (unsat of negation) | `INV-029`, `REQ-CONFIG-043`, `INV-057` |
| `FV-CTL-62` | T-71, T-54 | No loosen selector can be added to the short-delay list (loosening always waits the normal delay) | Violated | exhaustive enumeration (1 cases) | `REQ-CONFIG-053`, `REQ-ACCESS-142`, `REQ-PSTORE-002` |

Reproduce: `spec/05-verification/.venv/bin/python audit/formal-verification/control/fv_ctl_params.py`

### MarketRegistry lifecycle, routes and Lock (`fv_ctl_registry.py`)

| Check | Targets | Property | Status | Method | Spec IDs |
|---|---|---|---|---|---|
| `FV-CTL-79` | T-75 | A market moves only None -> Registered -> Active -> Offboarding (or Registered -> None by cancel); activation needs every check; Offboarding never returns | Verified | exhaustive enumeration (48 cases) | `REQ-CONFIG-013`, `REQ-CONFIG-042`, `REQ-CONFIG-047`, `REQ-CONFIG-048`, `REQ-MREG-015`, `REQ-ACCESS-034`, `REQ-ACCESS-134` |
| `FV-CTL-80` | T-75 | An in-kind window opened at execution lasts at most inKindExpiry <= 7 days and ends with no transaction | Verified | Z3 (unsat of negation) | `SPEC-GOV-010`, `REQ-MREG-016`, `REQ-ACCESS-057` |
| `FV-CTL-81` | T-75 | A pool whose registration was cancelled can be listed again | Violated | direct computation | `REQ-CONFIG-048`, `REQ-CONFIG-007`, `REQ-CONFIG-032`, `REQ-VTOKEN-021`, `REQ-VTOKEN-038` |
| `FV-CTL-81-FIX` | T-75 | With registerMarket reusing the cancelled marketId bound in the pool's existing token, the pool can be listed again | Verified | direct computation | `REQ-CONFIG-048` |
| `FV-CTL-82` | T-75 | registerMarket never overwrites a pool, vault-token or LPOracle key that maps to a market | Verified | Z3 (unsat of negation) | `REQ-CONFIG-007`, `REQ-VTOKEN-021` |
| `FV-CTL-83` | T-75 | getDebtReserveIds equals the approved set, without duplicates, after every approve/remove sequence (no re-approval overwrite) | Verified under bounded model | exhaustive enumeration (62 cases) | `REQ-MREG-006`, `REQ-MREG-010`, `REQ-PROXY-034` |
| `FV-CTL-84` | T-76 | A route slot always holds a previously approved route that is not the market's own pool and shares no dependency with the other slot; disable clears only the enabled flag; restore admits only an approved address | Verified | Z3 (unsat of negation) | `REQ-ACCESS-047`, `REQ-ACCESS-048`, `REQ-CONFIG-060`, `REQ-CONFIG-061`, `REQ-CONFIG-062`, `REQ-ACCESS-127` |
| `FV-CTL-85` | T-72 | Only a fixed member acquires a free Lock, only the holder releases it, nothing runs through delegatecall, and an inner call succeeds only while its named caller holds the Lock | Verified | Z3 (unsat of negation) | `INV-054`, `REQ-LOCK-019`, `REQ-LOCK-020`, `REQ-LOCK-021`, `REQ-LOCK-022`, `REQ-ROLE-021` |
| `FV-CTL-85-W` | T-72 | Witness: the Adapter acquires the free Lock | Verified | Z3 witness (sat) |  |

Reproduce: `spec/05-verification/.venv/bin/python audit/formal-verification/control/fv_ctl_registry.py`

### LPOracle state machine and LPPriceMath (`fv_ctl_oracle.py`)

| Check | Targets | Property | Status | Method | Spec IDs |
|---|---|---|---|---|---|
| `FV-CTL-63` | T-66 | latestAnswer() is >= 1 in every state before and after every poke (accepted price stays >= 1) | Verified | Z3 (unsat of negation) | `INV-055`, `REQ-ORACLE-020`, `SPEC-ORC-012` |
| `FV-CTL-64` | T-67 | The accepted price changes only from a Live observation newer than the stored one; its timestamp never decreases and is a source timestamp; re-reading the same rounds never refreshes it | Verified | Z3 (unsat of negation) | `INV-056`, `REQ-ORACLE-021`, `REQ-ORACLE-029`, `SPEC-ORC-012` |
| `FV-CTL-65` | T-70, T-67 | expiredLatched is set only when source timestamps show Expired; a caught error, a config/decimals failure or a gas shortfall never sets it, and a gas-short poke changes nothing | Verified | Z3 (unsat of negation) | `REQ-ORACLE-030`, `INV-031`, `REQ-ORACLE-024` |
| `FV-CTL-66` | T-70 | poke() is idempotent within a block: a second poke on the same reads changes no stored field | Verified | Z3 (unsat of negation) | `INV-031`, `REQ-ORACLE-026`, `REQ-ORACLE-033` |
| `FV-CTL-67` | T-68 | After a poke a disagreeing market is Drifting and liquidation-paused; the first-observation time is set once per episode and never moves; the pause lasts < disagreementPauseMax from it | Verified | Z3 (unsat of negation) | `SPEC-ORC-016`, `REQ-ORACLE-022`, `REQ-ORACLE-028`, `INV-059`, `REQ-ORACLE-018` |
| `FV-CTL-68` | T-67, T-68 | No stored timer or latch keeps a market out of Live once its inputs are valid, fresh and agree; a failed market is Expired at most cachedWindow after its failure start | Verified | Z3 (unsat of negation) | `REQ-ORACLE-016`, `REQ-ORACLE-006`, `REQ-ORACLE-023` |
| `FV-CTL-69` | T-67 | A failure that began less than cachedWindow ago is reported Cached (not Expired) | Violated | Z3 (sat of negation) | `SPEC-ORC-013`, `REQ-ORACLE-017`, `REQ-ORACLE-027` |
| `FV-CTL-69-FIX` | T-67 | With a poke observing the recovery, a failure that began less than cachedWindow ago is Cached | Verified | Z3 (unsat of negation) | `SPEC-ORC-013`, `REQ-ORACLE-037` |
| `FV-CTL-70` | T-67, T-70 | A grace window started by the latch begins no earlier than the recovered token's first fresh round (fallback min(t0, t1) as written) | Violated | Z3 (sat of negation) | `INV-031`, `REQ-ORACLE-032`, `REQ-ORACLE-034`, `SPEC-ORC-014` |
| `FV-CTL-70-FIX` | T-67, T-70 | A grace window started by the latch begins no earlier than the recovered token's first fresh round (fallback max(t0, t1)) | Verified | Z3 (unsat of negation) | `INV-031`, `REQ-ORACLE-032`, `REQ-ORACLE-034`, `SPEC-ORC-014` |
| `FV-CTL-71` | T-59, T-67 | now - servedUpdatedAt <= borrowPriceMaxAge() holds exactly when every leg in use is within its own limit; the derived limit is never negative | Verified | Z3 (unsat of negation) | `SPEC-ORC-015`, `REQ-ORACLE-043`, `SPEC-PROXY-002`, `REQ-ADAPTER-016` |
| `FV-CTL-72` | T-66 | For every combination of leg behaviours (10^4 cases) latestAnswer() returns a value >= 1, and reverts only with InsufficientGas after a caught failure below pokeMinGas | Verified | exhaustive enumeration (20000 cases) | `INV-055`, `REQ-ORACLE-020`, `REQ-ORACLE-039`, `REQ-ORACLE-001`, `REQ-ORACLE-002` |
| `FV-CTL-73` | T-69 | price8 = isqrt(4 v0 v1) - 1 is >= 1, (price8 + 1)^2 <= 4 v0 v1 (never above 2*sqrt(v0 v1)), within 2 units of it, symmetric, and 4 v0 v1 < 2^256 | Verified | Z3 (unsat of negation) | `SPEC-ORC-008`, `INV-055`, `REQ-ORACLE-012` |
| `FV-CTL-74` | T-69 | The stable ceiling never raises a price, is monotone, and is a no-op at or below the ceiling | Verified | Z3 (unsat of negation) | `SPEC-ORC-004`, `REQ-ORACLE-009` |
| `FV-CTL-75` | T-69 | The agreement check /p - b/ * 10^4 <= T * min(p, b) is symmetric in p and b (both sides are order-free) and uses no division | Verified | Z3 (unsat of negation) | `SPEC-ORC-003`, `REQ-ORACLE-008` |
| `FV-CTL-75-W` | T-69 | Witness: floor division would admit T + 1 bps where the exact check refuses (why the cross-multiplied form is required) | Verified | Z3 witness (sat) | `SPEC-ORC-003` |
| `FV-CTL-76` | T-69 | The reference sqrt price never overflows and lies in [MIN_SQRT_RATIO, MAX_SQRT_RATIO) after clamping | Verified | Z3 (unsat of negation) | `SPEC-ORC-009`, `REQ-ORACLE-014` |

Reproduce: `spec/05-verification/.venv/bin/python audit/formal-verification/control/fv_ctl_oracle.py`

### Upgrade safety, binding and Lens view integrity (`fv_ctl_upgrade_lens.py`)

| Check | Targets | Property | Status | Method | Spec IDs |
|---|---|---|---|---|---|
| `FV-CTL-86` | T-64, T-62 | An implementation whose constructor ran _disableInitializers() can never be initialized or reinitialized; a proxy's initializer runs once | Verified | Z3 (unsat of negation) | `REQ-ACCESS-150`, `REQ-PROXY-003`, `REQ-PROXY-004`, `REQ-ADAPTER-004`, `REQ-ORACLE-080` |
| `FV-CTL-87` | T-64, T-62 | After any implementation change no address other than the timelock (UUPS) or the AaveAdapter (beacon) can run a reinitializer first | Violated | exhaustive enumeration (6 cases) | `REQ-PROXY-005`, `REQ-PROXY-007`, `REQ-ACCESS-031`, `REQ-PROXY-086` |
| `FV-CTL-87-FIX` | T-64 | With 'no reinitializer in a PositionProxy implementation; migrations only in OnlyAdapter functions', nobody else runs one | Verified | exhaustive enumeration (3 cases) | `REQ-PROXY-005` |
| `FV-CTL-88` | T-64 | The append-only layout rule accepts exactly the appending and identical layouts and rejects every delete, retype, insert and reorder | Verified | exhaustive enumeration (20 cases) | `REQ-ADAPTER-004`, `REQ-PROXY-005`, `REQ-ORACLE-080` |
| `FV-CTL-89` | T-62 | One PositionProxy per (wallet, spoke): equal CREATE2 addresses imply the same pair (keccak modelled as injective) | Verified | Z3 (unsat of negation) | `INV-012`, `REQ-PROXY-052`, `REQ-PROXY-053` |
| `FV-CTL-90` | T-62, T-74 | predictProxy (Adapter, Lens, RiskModule.previewPledge) equals the stored proxy of every deployed account across ProxyManager upgrades | Violated | direct computation | `REQ-LENS-008`, `REQ-PROXY-049`, `REQ-RISK-031` |
| `FV-CTL-90-FIX` | T-62 | Returning proxyOf(wallet, spoke) when it is set makes the view exact across upgrades | Verified | Z3 (unsat of negation) | `REQ-LENS-008` |
| `FV-CTL-77` | T-74 | checkRecordBacking returns an empty page (never reverts) for every offset beyond the last record | Violated | Z3 (sat of negation) | `REQ-LENS-014`, `REQ-LENS-024`, `REQ-LENS-023` |
| `FV-CTL-77-FIX` | T-74 | With the early return for offset >= nextRecordId the walk never overflows and stays within [offset, nextRecordId] | Verified | Z3 (unsat of negation) | `REQ-LENS-014`, `REQ-LENS-024` |
| `FV-CTL-78` | T-74 | previewLiquidation's maxGhoSpend equals SPEC-LIQ-015's bound, so any spend LPVaultSwap accepts is within the preview's maxGhoSpend | Verified | Z3 (unsat of negation) | `REQ-LENS-028`, `SPEC-LIQ-015`, `REQ-LENS-016` |
| `FV-CTL-97` | T-73 | Every view a third party can call mid-operation either reverts while the Lock is held or reads state the locked call does not write | Verified | exhaustive enumeration (7 cases) | `REQ-LENS-006`, `REQ-LENS-021`, `REQ-VAULT-125`, `REQ-ORACLE-025` |

Reproduce: `spec/05-verification/.venv/bin/python audit/formal-verification/control/fv_ctl_upgrade_lens.py`

### Design check: circuit breakers and address freeze (`fv_ctl_breakers.py`)

| Check | Targets | Property | Status | Method | Spec IDs |
|---|---|---|---|---|---|
| `FV-CTL-91` | T-56, T-57 | [DESCRIBED] No combination of pause state, breaker, offboarding or address freeze blocks repay, debt-free withdrawal, fees, zero-credit release or pending settlement | Violated | exhaustive enumeration (2 cases) | `REQ-ACCESS-068`, `REQ-ROLE-055`, `INV-067`, `REQ-ADAPTER-047` |
| `FV-CTL-91-FIX` | T-56, T-57 | [RECOMMENDED] No combination of pause state, breaker, offboarding or address freeze blocks repay, debt-free withdrawal, fees, zero-credit release or pending settlement | Verified | exhaustive enumeration (168 cases) | `REQ-ACCESS-068`, `REQ-ROLE-055`, `INV-067`, `REQ-ADAPTER-047` |
| `FV-CTL-92` | T-56, T-53 | [DESCRIBED] No set of guardian freezes (up to 4) stops liquidation of an account that needs the keeper path | Violated | exhaustive enumeration (4 cases) | `INV-046`, `REQ-ACCESS-100`, `SPEC-GOV-008`, `REQ-ACCESS-112` |
| `FV-CTL-92-FIX` | T-56, T-53 | [RECOMMENDED] No set of guardian freezes (up to 4) stops liquidation of an account that needs the keeper path | Verified under bounded model | exhaustive enumeration (10 cases) | `INV-046`, `REQ-ACCESS-100`, `SPEC-GOV-008`, `REQ-ACCESS-112` |
| `FV-CTL-93` | T-53 | [DESCRIBED] The guardian cannot freeze the timelock, the Aave governance executor or LPVaultSwap | Violated | exhaustive enumeration (1 cases) | `REQ-ACCESS-089`, `REQ-ACCESS-112` |
| `FV-CTL-93-FIX` | T-53 | [RECOMMENDED] The guardian cannot freeze the timelock, the Aave governance executor or LPVaultSwap | Verified | exhaustive enumeration (3 cases) | `REQ-ACCESS-089`, `REQ-ACCESS-112` |
| `FV-CTL-94` | T-53 | A frozen address becomes unfrozen only by an unfreezeAddress executed by the timelock | Verified | exhaustive enumeration (30 cases) | `REQ-ACCESS-111`, `REQ-ACCESS-003` |
| `FV-CTL-95` | T-55 | [DESCRIBED] The freezing guardian cannot keep an address frozen past one normal delay by cancelling its unfreeze | Violated | direct computation | `SPEC-GOV-005`, `SPEC-GOV-006`, `REQ-ACCESS-112` |
| `FV-CTL-95-FIX` | T-55 | [RECOMMENDED] unfreezeAddress operations are cancellable only by DAO_CANCELLER_ROLE | Verified | direct computation | `SPEC-GOV-005` |
| `FV-CTL-96` | T-56 | Breaker, pause and offboarding combine monotonically: new activity runs only when every control allows it; any control can only remove actions | Verified | exhaustive enumeration (288 cases) | `INV-067`, `REQ-SWAP-003`, `Q-227` |

Reproduce: `spec/05-verification/.venv/bin/python audit/formal-verification/control/fv_ctl_breakers.py`

### Governance state machine (`governance.qnt`, Quint)

| Check | Instance | Invariant | Result |
|---|---|---|---|
| `FV-CTL-98` | `gov_spec` | `execWaitedNormalDelay` | no violation in 10,000 samples |
| `FV-CTL-98` | `gov_spec` | `pauseTransitionsLegal` | no violation in 10,000 samples |
| `FV-CTL-98` | `gov_spec` | `upgradesGuardianCancellable` | Violated → F-01 (schedule grant, wait, execute, direct upgrade) |
| `FV-CTL-98` | `gov_spec` | `adminOnlyTimelock` | Violated → F-01 |
| `FV-CTL-98` | `gov_fixed` | all four | no violation in 10,000 samples |

Reproduce: `spec/05-verification/node_modules/.bin/quint run --main gov_spec --max-samples 10000 --max-steps 12 --invariant upgradesGuardianCancellable --seed 0x1 audit/formal-verification/control/governance.qnt`

## 12. Re-verification against the final spec (run `FV-CTL-R3`, 2026-11-10)

Sections 4 to 11 record run `FV-CTL-R1` against the spec of 2026-11-09. This section is the result against the final spec: decisions `Q-001`…`Q-278`, every page integrated (traceability: 2,927 requirements). The models encode the final text of 1.4, 2.5 to 2.10 (with the new DebtOracle), 2.15, 3.2 to 3.4, 3.6 and 3.8, and the parts of 1.5, 2.9, 2.13 and 2.17 that those pages depend on. The rules that `FV-CTL-R1` recommended are now spec rules, so each former `-FIX` check is now the main check under its original ID, and the separate `-FIX` checks are gone.

### 12.1 What the models now cover

- **Admin power** (`fv_ctl_access.py`, `governance.qnt`). The `_grantRole` override `AdminRoleOnlyTimelock` on every upgradeable contract, and on the timelock's own `DEFAULT_ADMIN_ROLE`, keeps upgrade and setter power with the timelock across every role call and initializer (`FV-CTL-01`, `02`). A role-change operation therefore cannot hand out upgrade power that escapes the cancellers (`FV-CTL-03`, Quint `adminOnlyTimelock`, `upgradesGuardianCancellable`). The restricted-function matrix agrees on every page, including the address-freeze, breaker and standby selectors (`FV-CTL-04`). A guardian key reaches only the emergency selectors and cancel, and a freeze-only key lifts nothing (`FV-CTL-05`, `06`).
- **Timelock** (`fv_ctl_timelock.py`). The normal delay stays within [345,600 s, 432,000 s] after any operation (`FV-CTL-20`, `20-EX`, Quint `normalDelayInBounds`). A cut takes effect at least 8 days after it is scheduled (`FV-CTL-19`). The short-delay list never leaves the constructor-fixed `SHORT_ELIGIBLE` set, and no risk-raising, loosening, lifting or code-changing selector can join it (`FV-CTL-23`, `24`). Every stop selector is short-eligible, so the governance Safe halts new activity in 12 hours on its own (`FV-CTL-27`). Pure role-change and pure restoring operations, `setInKindAutoTrigger(true)` included, can be cancelled only by `DAO_CANCELLER_ROLE`; mixed batches can be cancelled by every canceller (`FV-CTL-21`, `21-EX`, Quint `restoringNotGuardianCancellable`). At every reachable delay, a borrower with a 3-day reaction leaves with up to 7,199 NFTs (`FV-CTL-26`, `26-EX`).
- **Pause state and reasons** (`fv_ctl_pause.py`). The transitions with `General` and `MintPathSuspect` are the same on 2.8 and 2.15. The reason is None exactly when the state is not Paused (`FV-CTL-31`, `32`). Six pages allow the same actions in all four states (`FV-CTL-33`). Rescue top-ups stay open except under `MintPathSuspect`, and under `General` they are the only pledge admitted (`FV-CTL-37`). Exits and liquidation are open in every state (`FV-CTL-34`).
- **Circuit breakers and address freeze** (`fv_ctl_breakers.py`). No combination of pause state, reason, market or debt breaker, offboarding, or caller or borrower freeze blocks an exit or the liquidation of a frozen wallet's positions (`FV-CTL-91`). A rescue top-up is stopped only by `MintPathSuspect` and offboarding (`FV-CTL-151`), and the controls combine monotonically (`FV-CTL-96`). Breakers are read only in the RiskModule's three checks (`FV-CTL-109`).
  - The price-drop, pool-share, seizure-surge, route-failure, issuer and debt conditions match their formulas and examples (`FV-CTL-106`, `107`, `108` with examples). The issuer probe fails closed. A latch never shortens `latchedUntil`, and recording from LPVaultSwap never reverts (`FV-CTL-150`).
  - The freeze never covers a protected address (`FV-CTL-93`). It keeps at least `keeperFloor` active keepers (`FV-CTL-92`, `105`), allows each caller at most 20 freezes in any 24 hours (`FV-CTL-104`), and is lifted only by a normal-delay `unfreezeAddress` that no guardian can cancel (`FV-CTL-94`, `95`).
- **Gates, exits and rescue units** (`fv_ctl_gates.py`). The health floor counts rescue units at zero, and the check passes only if the collateral without them covers the debt at the floor (`FV-CTL-38`, `102`). Every path that can lower an indebted account's health ends with that check, or with the repay-with-collateral direction check (`FV-CTL-39`). The debt-free test is exact (`FV-CTL-40`).
  - Repay, the debt-free branches of withdraw and removeLiquidity, `repayAllAndWithdraw`, `burnSeized` and the deleverage callbacks read no registry, RiskModule, parameter or oracle state (`FV-CTL-100`). Repay succeeds under every pause, freeze, breaker and registry implementation (`FV-CTL-41`), and its sizing and refund follow `SPEC-PROXY-003` and `REQ-ADAPTER-085` (`FV-CTL-42`).
  - The borrow and withdraw pre-checks include the DebtOracle state, the breakers and the active-keeper halt (`FV-CTL-43`, `103`, `44`), with `T-60` as now scoped (`FV-CTL-45`).
  - An exempted pledge is a rescue top-up within its restore amount and at least min(`minPledgeUsd`, $10), and every such rescue passes outside `MintPathSuspect` (`FV-CTL-101`, `101-EX`).
- **Oracles** (`fv_ctl_oracle.py`).
  - **Served price:** the served price by state is fresh when Live, at most the accepted price otherwise, the lower-route price during a disagreement, and 1 at Expired. No stress value sizes a seizure (`FV-CTL-63`, `110`, `111`, `113`).
  - **USD band:** the upper bound is tested on capped prices, so a market of two stables can breach only the lower bound (`FV-CTL-114`).
  - **Heartbeat margins:** `borrowPriceMaxAge = min(heartbeat + 600, 4,200)` never refuses an on-time hourly feed, and a serving alternate is held to its borrow age for liquidation (`FV-CTL-71`, `116`…`118`).
  - **Phase rollover:** the fallback gap contains the true one, so no recovery evidence is lost (`FV-CTL-120`…`122`).
  - **Standby switch, oracle side:** a route-version change resets only the disagreement timer and never makes a market Live (`FV-CTL-123`, `124`).
  - **Checkpoint:** it is always an accepted price at least an hour old (`FV-CTL-125`, `126`).
  - **DebtOracle:** it serves at least the accepted price whenever not Live, rounds the Expired stress rise up, never exceeds 1.5A + 1, and pauses liquidation of its reserve whenever not Live (`FV-CTL-127`, `128`).
  - **Cached window and grace start:** these follow `SPEC-ORC-013` and `REQ-ORACLE-032` (`FV-CTL-69`, `70`, `119`, `129`).
- **Parameters, registry, upgrades and Lens** (`fv_ctl_params.py`, `fv_ctl_registry.py`, `fv_ctl_upgrade_lens.py`).
  - **Parameters:** the buy-slippage floor and the two-leg inequality (`FV-CTL-57`, `130`, `131`); every tightener, plus the step and spacing limits on loosening (`FV-CTL-56`, `132`…`135`); the page agreement on short tighteners (`FV-CTL-58`); `SHORT_ELIGIBLE` (`FV-CTL-62`, `140`); the budget caps and the per-market sub-cap (`FV-CTL-59`, `60`, `138`, `141`, `147`).
  - **Registry:** relisting after a cancelled registration (`FV-CTL-79`, `81`, `82`); the standby switch on the registry side (`FV-CTL-84`, `143`…`146`).
  - **Upgrades:** no reinitializer in a PositionProxy implementation (`FV-CTL-87`).
  - **`proxyOf` and the Lens:** `proxyOf` is the account every view shows (`FV-CTL-90`, `149`), and `checkRecordBacking` has no overflow (`FV-CTL-77`).

### 12.2 Result

| Model | Checks | Verified | Verified under bounded model | Violated |
|---|---|---|---|---|
| `fv_ctl_access.py` | 13 | 13 | 0 | 0 |
| `fv_ctl_timelock.py` | 17 | 16 | 1 | 0 |
| `fv_ctl_pause.py` | 7 | 6 | 0 | 1 (`FV-CTL-36`) |
| `fv_ctl_gates.py` | 18 | 18 | 0 | 0 |
| `fv_ctl_params.py` | 24 | 21 | 0 | 3 (`FV-CTL-137`, `139`, `142`) |
| `fv_ctl_registry.py` | 13 | 9 | 4 | 0 |
| `fv_ctl_oracle.py` | 38 | 36 | 0 | 2 (`FV-CTL-112`, `115`) |
| `fv_ctl_upgrade_lens.py` | 10 | 9 | 0 | 1 (`FV-CTL-148`) |
| `fv_ctl_breakers.py` | 19 | 18 | 1 | 0 |
| `governance.qnt` (Quint) | 6 invariants | 6 with no violation in 10,000 samples | — | 0 |
| **Total** | **165** | **152** | **6** | **7** |

`check_ids.py`: 377 cited spec IDs, 0 undefined. `run.sh` exits 1 because of the seven violations below, which are new findings against the final text; each check stays failing until its spec change is made.

### 12.3 Findings of run `FV-CTL-R1`

Every earlier finding's proving check now passes against the edited pages.

| Finding | Severity | Decision | Proving checks (pass in `FV-CTL-R3`) |
|---|---|---|---|
| `FV-CTL-F-01` | Medium | `Q-259` | `FV-CTL-01`, `01-W`, `02`, `03`, `07`; Quint `adminOnlyTimelock`, `upgradesGuardianCancellable` |
| `FV-CTL-F-02` | Medium | `Q-260` | `FV-CTL-40`, `41`, `100` |
| `FV-CTL-F-03` | Medium | `Q-261` | `FV-CTL-57`, `130`, `131` |
| `FV-CTL-F-04` | Medium | `Q-242`, `Q-262`, `Q-263` | `FV-CTL-91`, `92`, `93`, `94`, `95`, `104`, `105`, `151` |
| `FV-CTL-F-06` | Low | `Q-262` | `FV-CTL-23`, `24`, `62` |
| `FV-CTL-F-07` | Low | `Q-262` | `FV-CTL-20`, `20-EX`, `26`, `26-EX`; Quint `normalDelayInBounds` |
| `FV-CTL-F-08` | Low | `Q-264` | `FV-CTL-70`, `129` (the grace start of a recovery by a new round of a one-leg route; the two-leg and standby cases are `FV-CTL-F-18`) |
| `FV-CTL-F-09` | Low | `Q-265` | `FV-CTL-79`, `81`, `82` |
| `FV-CTL-F-10` | Low | `Q-266` | `FV-CTL-87`, `09` |
| `FV-CTL-F-11` | Informational | `Q-246` | `FV-CTL-58` |
| `FV-CTL-F-12` | Informational | `Q-267` | `FV-CTL-59`, `60`, `141` |
| `FV-CTL-F-13` | Informational | `Q-183` | `FV-CTL-69`, `119` |
| `FV-CTL-F-14` | Informational | `Q-268` | `FV-CTL-77` |
| `FV-CTL-F-15` | Informational | `Q-266`, `Q-268` | `FV-CTL-90`, `149` |
| `FV-CTL-F-16` | Informational | `Q-223`, `Q-229` | `FV-CTL-11`, `45` |
| `FV-CTL-F-17` | Informational | `Q-241` | `FV-CTL-96`, `106`, `107`, `108`, `109`, `150` |

### 12.4 New findings

| ID | Title | Severity | Check |
|---|---|---|---|
| `FV-CTL-F-18` | The grace window can start before the recovery when the recovered token is on a two-leg route or recovered through a standby switch | Medium | `FV-CTL-115` |
| `FV-CTL-F-19` | With `disagreementPauseMax = 0`, a view on a disagreeing market that no poke has yet observed serves the primary-route price and reports liquidation open | Low | `FV-CTL-112` |
| `FV-CTL-F-20` | The 1.4 pause table names `ApplicationPaused` for a new account's pledge under `Paused(General)`; the contracts revert `NotRescueTopUp` | Informational | `FV-CTL-36` |
| `FV-CTL-F-21` | `REQ-RISK-057` and `REQ-RISK-066` name different errors for the same pledge below `minPledgeUsd` | Informational | `FV-CTL-137` |
| `FV-CTL-F-22` | The `REQ-PSTORE-006` example overstates the `SPEC-LIQ-015` spend bound by 0.01 GHO | Informational | `FV-CTL-139` |
| `FV-CTL-F-23` | `SPEC-SET-002`'s per-key bound breaks for a removed debt reserve whose budget caps stay set | Informational | `FV-CTL-142` |
| `FV-CTL-F-24` | The Lens paging rules give two outcomes for a limit above `LENS_MAX_PAGE` with an offset past the last record | Informational | `FV-CTL-148` |

#### FV-CTL-F-18 — The grace window can start before the recovery (two-leg route, standby switch)

`REQ-ORACLE-032` states "The window must start no earlier than the recovery". When the latch is set and `SPEC-ORC-014` gives no interval, the fallback sets `recoveredAt = min(max(t0, t1), now)`, where `t_i` are the route timestamps of the fresh price. A route timestamp is the oldest leg of the route (`SPEC-ORC-002`), and a standby that a guardian switches in has no `seen` record (`REQ-ORACLE-031`), so its recovery gives no evidence and the fallback applies. In both cases the recovery is later than every `t_i`.

- Standby switch: switch at 1,762,700,000, standby round at 1,762,697,000, token0 at 1,762,698,000. Then `recoveredAt = 1,762,698,000` and `graceEndsAt = 1,762,699,800`, which is before the poke, so no grace window opens at all.
- Two-leg recovery: new USDT/ETH round at 1,762,700,000, ETH/USD at 1,762,697,000, token0 at 1,762,696,500. Then `recoveredAt = 1,762,697,000`, 3,000 s before the recovery.

Accounts that grace should protect, with HF in [`graceHealthFactor`, 1), are liquidated at once after the outage ends. The Z3 counterexample is `recoveryByStandbySwitch = true`, recovery at 2, `t0 = t1 = 1`, `recoveredAt = 1`.

Recommended change:
- In `REQ-ORACLE-032`, replace the fallback with `min(max over every leg ℓ in use of updatedAt_ℓ, now)`, the newest input of the fresh price.
- Add: "when the poke observes a route-version change (`REQ-ORACLE-095`) while `expiredLatched` is set, `recoveredAt = now`".
- In `REQ-ORACLE-065`, add the route-version observation to the inputs that may start grace.
- The DebtOracle follows by `REQ-ORACLE-092`.

#### FV-CTL-F-19 — A disagreement can go unreported when `disagreementPauseMax = 0`

1.5 bounds `disagreementPauseMax` only above (≤ 3,600 s), so 0 is allowed. `SPEC-ORC-016` defines `pauseActive = D ∧ now < s + disagreementPauseMax` with `s = disagreeSince ≠ 0 ? disagreeSince : now`, and `disagreementExpired = D ∧ disagreeSince ≠ 0 ∧ now ≥ disagreeSince + disagreementPauseMax`.

When a view reads `disagreeSince` as 0, neither holds. That happens when no poke has yet seen the episode, or when the route version changed since the last poke. The view (Aave's `latestAnswer`, `getPriceState`) then serves `min(fresh, A)` from the primary routes instead of the lower-route price, and reports `liquidationPaused = false`. This contradicts `REQ-ORACLE-086`, which treats "some token disagrees" as `pauseActive ∨ disagreementExpired`.

Counterexample: `disagreementPauseMax = 0`, `disagreeSince` read as 0 after a route-version change, `now = 1`. It is not reachable at the launch value of 3,600 s, and every Avana caller pokes first (`FV-CTL-67`).

Recommended change: in `SPEC-ORC-016`, define `disagreementExpired = D ∧ now ≥ s + disagreementPauseMax`, using the same `s` as `pauseActive`, so `D ⇒ pauseActive ∨ disagreementExpired` always holds. The alternative is a lower bound `disagreementPauseMax ≥ 1` in 1.5.

#### FV-CTL-F-20 — 1.4 names the wrong error for a new account's pledge under `Paused(General)`

The 1.4 table "Application pause state", row "New pledge (account with no debt)", column `Paused(General)`, says "No (`ApplicationPaused`)".

Under `General` the Adapter does not revert. It sets `requireRescue` (`REQ-ADAPTER-083`), and the RiskModule then reverts `NotRescueTopUp(type(uint256).max, usdCharge, 0)` (`REQ-RISK-066` and its example). 2.15 `REQ-ACCESS-074`, 3.6 `EMG-018` and `INV-026` state that error.

Recommended change: write "No (`NotRescueTopUp`: the Adapter sets `requireRescue`)" in that cell.

#### FV-CTL-F-21 — Two rules name different errors for one pledge below `minPledgeUsd`

Example: a new account pledges $12 into a market with `minPledgeUsd = $50` whose pool-share cap is exceeded.

- `REQ-RISK-066`'s order gives `NotRescueTopUp`, because the value is not its only exemption reason.
- `REQ-RISK-057` gives `BelowMinPledge(1,200,000,000, 5,000,000,000)`, because it says a pledge below `minPledgeUsd` that is not admitted as a rescue "reverts `BelowMinPledge` whatever its other exemption reasons".

Z3 found the same split with `pledgeUsd = 1,000,000,001` and `minPledgeUsd = 1,000,000,003`.

Recommended change: replace that sentence of `REQ-RISK-057` with: "A pledge below the rescue minimum reverts `BelowMinPledge(pledgeUsd, min(minPledgeUsd, RESCUE_MIN_PLEDGE_USD))` whatever its other exemption reasons; one at or above it but below `minPledgeUsd` that is not admitted as a rescue top-up reverts `BelowMinPledge(pledgeUsd, minPledgeUsd)` when the value is its only exemption reason and `NotRescueTopUp` otherwise (`REQ-RISK-066`)."

#### FV-CTL-F-22 — The `REQ-PSTORE-006` example overstates the spend bound

`SPEC-LIQ-015` takes the ceiling in GHO wei. Buying 10,000 USDC at $0.9998 with 50 bps therefore allows at most 10,047,990,000,000,000,000,000 wei, which is 10,047.99 GHO. A spend of 10,048 GHO, the figure the example gives, reverts `GhoSpendTooHigh`.

Recommended change: write "may spend at most `10,000 × 0.9998 × 1.005 = 10,047.99` GHO (`10,047.99e18` wei)".

#### FV-CTL-F-23 — `SPEC-SET-002`'s per-key bound after a debt reserve is removed

`removeDebtReserve` leaves the reserve's SettlementBudget caps in place. `loosenFloorRoundingAllowanceGho` checks `REQ-CONFIG-050` only against approved reserves. A removed key can therefore end with `0 < perCallCap < 2 × floorRoundingAllowanceGho`, against `SPEC-SET-002`'s Bounds sentence, which covers every key.

Counterexample: removed key with caps (2, 2), allowance raised from 1 to 2. Honest flows are unaffected, because a removed reserve can no longer be named and relisting re-checks it.

Recommended change:
- Scope the `SPEC-SET-002` Bounds sentence to "every approved debt reserve (`REQ-CONFIG-050`)".
- Add to `REQ-MREG-010` and `MKT-045`: "the removal operation also calls `SettlementBudget.tightenCaps(spoke, r, 0, 0)`".

#### FV-CTL-F-24 — The Lens paging rules give two outcomes for one call

Example: `n = 1,250`, `offset = 1,250`, `limit = 201`. Z3 also found `offset = 0`, `n = 0`, `limit ≈ 2^255`.

- `REQ-LENS-014` and `REQ-LENS-024` say an empty array, "for any offset and limit up to type(uint256).max".
- `REQ-LENS-020` and `REQ-LENS-023` revert `LimitTooHigh` for a limit above `LENS_MAX_PAGE` (200).

Recommended change:
- Limit `REQ-LENS-024` to "any `offset` up to `type(uint256).max` and any `limit ≤ LENS_MAX_PAGE`".
- In `REQ-LENS-014`, write that after the limit checks of `REQ-LENS-023` (0 returns an empty array; a limit above `LENS_MAX_PAGE` reverts `LimitTooHigh`), the call returns an empty array when `offset ≥ n`.
- `FV-CTL-77` proves that no input overflows.

#### Observation (no failing check)

`REQ-ORACLE-088` says the price-drop breaker "compares the served price", and its example uses "a served price of 193,900,000 before 1,762,660,900". `SPEC-BRK-001` compares `lastAcceptedPrice()`, and with `now − at ≤ 7,200` it still trips at 1,762,660,900 itself. Writing "accepted price" and "until 1,762,660,900 inclusive" would make the two pages say the same.

### 12.5 Run `FV-CTL-R4`: the findings of section 12.4 resolved

Each recommended change of section 12.4 is now in the spec (2026-11-10), and the models encode the changed text. `run.sh` exits 0: 167 checks, 155 Verified, 6 Verified under bounded model, 0 Violated, and 6 Quint invariants with no violation. `FV-CTL-115`, `FV-CTL-112`, `FV-CTL-36`, `FV-CTL-137`, `FV-CTL-139`, `FV-CTL-142` and `FV-CTL-148` now pass; `FV-CTL-115-EX` recomputes the new `REQ-ORACLE-032` examples, and `FV-CTL-152` proves the peg condition that `SPEC-BRK-002` gained for `SIM-GAP-13`. Changed rules: `REQ-ORACLE-032`, `REQ-ORACLE-065`, `REQ-ORACLE-095` (`F-18`); `SPEC-ORC-016` (`F-19`); the 1.4 pause table (`F-20`); `REQ-RISK-057` (`F-21`); `REQ-PSTORE-006` (`F-22`); `SPEC-SET-002`, `REQ-MREG-010`, `MKT-045` and 1.5 `floorRoundingAllowanceGho` (`F-23`); `REQ-LENS-014`, `REQ-LENS-024` (`F-24`). The observation on `REQ-ORACLE-088` has no failing check and is unchanged. The tables of section 12.6 list the checks of `FV-CTL-R3`.

### 12.6 Properties of run `FV-CTL-R3`

Reproduce any model with `spec/05-verification/.venv/bin/python audit/formal-verification/control/<model>.py`, and the whole run with `audit/formal-verification/control/run.sh`.

**`fv_ctl_access.py`** (13 checks)

| Check | Property | Result | Method | Verifies |
|---|---|---|---|---|
| `FV-CTL-01` | APPLICATION_ADMIN and DEFAULT_ADMIN_ROLE stay with the timelock across every grant, revoke and renounce, executed or not (AdminRoleOnlyTimelock) | Verified | Z3 (unsat of negation) | `REQ-ACCESS-153`, `REQ-ACCESS-032`, `REQ-ACCESS-003`, `REQ-MREG-005`, `REQ-ADAPTER-084`, `REQ-PROXY-101`, `REQ-ORACLE-097`, `INV-068`, `INV-084` |
| `FV-CTL-01-W` | Witness: the timelock grants a guardian role to a Safe, while the same operation granting APPLICATION_ADMIN reverts | Verified | Z3 witness (sat) | `REQ-MREG-005`, `REQ-ACCESS-153` |
| `FV-CTL-02` | Initializers grant DEFAULT_ADMIN_ROLE and APPLICATION_ADMIN only to the TIMELOCK constant (any other argument reverts) | Verified | Z3 (unsat of negation) | `REQ-ACCESS-150`, `REQ-ACCESS-027`, `REQ-ADAPTER-074`, `REQ-PROXY-085`, `REQ-ACCESS-153` |
| `FV-CTL-03` | Every Adapter upgrade is a timelock operation every canceller can cancel: a role-change operation cannot hand out upgrade power | Verified | Z3 (unsat of negation) | `REQ-ACCESS-153`, `REQ-ACCESS-113`, `REQ-ADAPTER-003`, `REQ-ADAPTER-042`, `REQ-ADAPTER-084`, `SPEC-GOV-005` |
| `FV-CTL-04` | Every page names the same allowed caller for each privileged selector, including the address freeze, breaker and standby selectors | Verified | exhaustive enumeration (33 cases) | `REQ-ACCESS-025`, `REQ-ACCESS-066`, `REQ-ROLE-019`, `REQ-ROLE-015`, `REQ-MREG-004`, `REQ-ACCESS-157`, `REQ-ACCESS-158`, `REQ-ACCESS-159`, `REQ-ROLE-107`, `REQ-ROLE-108`, `REQ-ROLE-109` |
| `FV-CTL-05` | Guardian keys reach exactly freeze, pause, unfreeze, unpause, freezeAddress, breaker trip and reset, useStandbyRoute and cancel; never unfreezeAddress, an upgrade, a setter or a route choice | Verified | direct computation | `REQ-ACCESS-089`, `REQ-ACCESS-112`, `REQ-ACCESS-094`, `REQ-ROLE-076` |
| `FV-CTL-06` | A key holding only APPLICATION_FREEZE_GUARDIAN can call no lifting selector (unfreeze, unpause, breaker reset, address unfreeze) | Verified | direct computation | `REQ-ACCESS-086`, `REQ-ACCESS-124`, `REQ-ROLE-071`, `REQ-MREG-004`, `REQ-MREG-025` |
| `FV-CTL-07` | Every APPLICATION_ADMIN or TIMELOCK selector runs only as a timelock execution | Verified | Z3 (unsat of negation) | `REQ-ACCESS-111`, `REQ-ACCESS-015`, `REQ-ACCESS-010`, `REQ-ACCESS-153` |
| `FV-CTL-08` | A PositionProxy state change succeeds only for msg.sender == ADAPTER, never for its own wallet | Verified | Z3 (unsat of negation) | `REQ-PROXY-040`, `REQ-PROXY-087`, `REQ-PROXY-088`, `REQ-PROXY-089`, `REQ-ROLE-019` |
| `FV-CTL-08-W` | Witness: the Adapter's call to the proxy succeeds | Verified | Z3 witness (sat) | `REQ-PROXY-040` |
| `FV-CTL-09` | PositionProxy selector inventory contains no generic-call, signature, manager, upgrade or reinitializer selector | Verified | exhaustive enumeration (11 cases) | `REQ-PROXY-007`, `REQ-PROXY-008`, `REQ-PROXY-001`, `REQ-PROXY-005` |
| `FV-CTL-10` | No hostile RiskModule, ParameterStore, MarketRegistry, LPOracle, DebtOracle or LPVaultSwap reaches mint, proxy registration, NFT return or budget withdrawal | Verified | exhaustive enumeration (6 cases) | `INV-052`, `INV-053`, `REQ-RISK-007`, `REQ-PSTORE-003`, `REQ-ADAPTER-081`, `REQ-ORACLE-098` |
| `FV-CTL-11` | Methodology T-65 names only contained components (the AaveAdapter, which reaches mint and proxy registration, is in the reviewed scope instead) | Verified | direct computation | `INV-018`, `INV-052`, `INV-053` |

**`fv_ctl_timelock.py`** (17 checks)

| Check | Property | Result | Method | Verifies |
|---|---|---|---|---|
| `FV-CTL-16` | schedule succeeds only with delay >= requiredDelay; one non-listed call makes the batch normal | Verified | Z3 (unsat of negation) | `SPEC-GOV-001`, `REQ-ACCESS-141`, `REQ-ACCESS-117`, `INV-068` |
| `FV-CTL-17` | A batch never needs less delay than any of its parts (no riding a loosening on a tightening batch) | Verified | Z3 (unsat of negation) | `SPEC-GOV-001`, `REQ-ROLE-105` |
| `FV-CTL-18` | From readyAt on an operation is exactly one of executable or expired; never executable before readyAt | Verified | Z3 (unsat of negation) | `SPEC-GOV-002`, `SPEC-GOV-013`, `REQ-ACCESS-118`, `REQ-ACCESS-126` |
| `FV-CTL-18-EX` | SPEC-GOV-002 example: last executable second 1,781,641,599, expiry at 1,781,641,600 | Verified | direct computation | `SPEC-GOV-002` |
| `FV-CTL-19` | After a normal-delay cut, any operation using the shorter delay executes no earlier than old + new (at least 8 days) after the cut was scheduled | Verified | Z3 (unsat of negation) | `SPEC-GOV-003`, `REQ-ACCESS-125`, `REQ-ACCESS-017` |
| `FV-CTL-20` | normalDelay stays within [MIN_NORMAL_DELAY, MAX_DELAY] = [345,600, 432,000] (base 432,000; every step preserves it) | Verified | Z3 (unsat of negation) | `SPEC-GOV-012`, `SPEC-GOV-015`, `REQ-ACCESS-030`, `REQ-ACCESS-140`, `REQ-ACCESS-154`, `REQ-ACCESS-125` |
| `FV-CTL-20-EX` | setNormalDelay examples: 345,600 and 432,000 accepted; 345,599, 259,200, 300,000, 432,001 and 864,000 revert DelayOutOfBounds; a cut scheduled at 1,780,000,000 lets an upgrade be ready at 1,780,777,600 | Verified | direct computation | `SPEC-GOV-003`, `SPEC-GOV-012`, `SPEC-GOV-015` |
| `FV-CTL-21` | Only DAO_CANCELLER cancels a pure role-change or pure restoring operation; every canceller cancels a mixed batch, a setInKindAutoTrigger(false) or any other operation | Verified | Z3 (unsat of negation) | `SPEC-GOV-005`, `REQ-ACCESS-020`, `REQ-ACCESS-143`, `REQ-ACCESS-156`, `REQ-ACCESS-163`, `INV-068`, `INV-090` |
| `FV-CTL-21-EX` | SPEC-GOV-005 and SPEC-GOV-006 examples: who may cancel each listed batch | Verified | exhaustive enumeration (11 cases) | `SPEC-GOV-005`, `SPEC-GOV-006`, `REQ-MREG-022`, `REQ-MREG-028` |
| `FV-CTL-22` | The cancel window lasts at least requiredDelay; a guardian cannot cancel its own pure revocation, which anyone executes at readyAt | Verified | Z3 (unsat of negation) | `SPEC-GOV-007`, `SPEC-GOV-006`, `REQ-ACCESS-112` |
| `FV-CTL-23` | The constructor accepts the whole SHORT_ELIGIBLE list, and every reachable short list stays inside it: no role, upgrade, beacon, initializer or timelock selector ever takes the short delay | Verified under bounded model | exhaustive enumeration (22 cases) | `REQ-ACCESS-142`, `REQ-ACCESS-155`, `REQ-ACCESS-141`, `REQ-ACCESS-148`, `REQ-ACCESS-018`, `INV-090` |
| `FV-CTL-24` | setShortDelaySelector refuses every risk-raising, loosening, lifting or code-changing selector (InvalidShortDelaySelector) | Verified | exhaustive enumeration (20 cases) | `REQ-ACCESS-016`, `REQ-ACCESS-141`, `REQ-ACCESS-142`, `REQ-ACCESS-155`, `REQ-ROLE-105` |
| `FV-CTL-27` | Every stop selector (freeze, pause, freezeAddress, tripMarketBreaker, tripDebtBreaker) is short-eligible, so the governance Safe halts new activity in 43,200 s; no lifting selector is | Verified | direct computation | `REQ-ACCESS-155`, `REQ-ACCESS-128`, `REQ-ACCESS-062`, `REQ-ACCESS-063`, `SPEC-GOV-001` |
| `FV-CTL-25` | At the launch normal delay a borrower with a 3-day reaction and up to 14,399 NFTs exits before any normal-delay change | Verified | Z3 (unsat of negation) | `SPEC-GOV-014`, `REQ-ACCESS-148`, `INV-068` |
| `FV-CTL-25-EX` | SPEC-GOV-014 example: k = 14,400 no longer fits the launch delay (bound is exactly 14,399) | Verified | direct computation | `SPEC-GOV-014` |
| `FV-CTL-26` | For every reachable normalDelay, a borrower with a 3-day reaction and up to 7,199 NFTs exits before any normal-delay operation executes | Verified | Z3 (unsat of negation) | `SPEC-GOV-015`, `SPEC-GOV-014`, `REQ-ACCESS-148`, `REQ-ACCESS-154`, `REQ-ROLE-104`, `INV-068` |
| `FV-CTL-26-EX` | SPEC-GOV-015 example: k_max = 7,199 at the floor; k = 1 leaves 86,376 s to spare; k = 7,200 needs 345,612 s | Verified | direct computation | `SPEC-GOV-015` |

**`fv_ctl_pause.py`** (7 checks)

| Check | Property | Result | Method | Verifies |
|---|---|---|---|---|
| `FV-CTL-31` | 2.15 SPEC-GOV-004 and 2.8 REQ-MREG-001/004/024 define the same transition and revert for every state, reason, call and caller | Verified | exhaustive enumeration (192 cases) | `SPEC-GOV-004`, `REQ-MREG-001`, `REQ-MREG-004`, `REQ-MREG-024`, `REQ-ACCESS-085`, `REQ-ACCESS-122`, `REQ-ACCESS-123`, `INV-049` |
| `FV-CTL-32` | A freeze-only key never leaves Frozen or Paused; P or A reaches None from every state; Paused never returns to Frozen; the reason is None exactly when not Paused; either guardian raises General to MintPathSuspect at once | Verified | exhaustive enumeration (4 cases) | `SPEC-GOV-004`, `REQ-ACCESS-086`, `REQ-ACCESS-087`, `REQ-ROLE-071`, `REQ-MREG-024`, `INV-050` |
| `FV-CTL-33` | Every page's pause matrix (four states, twelve actions) allows exactly what the AaveAdapter's decision procedure allows | Verified | exhaustive enumeration (288 cases) | `REQ-ACCESS-072`, `REQ-ACCESS-073`, `REQ-ACCESS-074`, `REQ-ACCESS-164`, `REQ-MREG-002`, `REQ-ROLE-073`, `INV-067`, `REQ-ADAPTER-045`, `REQ-ADAPTER-046`, `REQ-ADAPTER-083`, `REQ-LENS-031`, `REQ-SWAP-003` |
| `FV-CTL-36` | Every error a page names for a blocked action is the error the Adapter and RiskModule raise | Violated | exhaustive enumeration (3 cases) | `REQ-ACCESS-074`, `REQ-ADAPTER-083`, `REQ-RISK-066`, `INV-026` |
| `FV-CTL-34` | Repay, repayAllAndWithdraw, fees, debt-free withdrawal and removal, zero-credit release, liquidation and pending settlement are open in every state and reason | Verified | exhaustive enumeration (28 cases) | `REQ-ACCESS-068`, `REQ-ROLE-068`, `REQ-ADAPTER-047`, `REQ-RISK-040`, `LIQ-002`, `INV-081` |
| `FV-CTL-37` | A rescue top-up is open in None, Frozen and Paused(General) and is the only pledge Paused(General) admits; Paused(MintPathSuspect) admits no minting action | Verified | exhaustive enumeration (4 cases) | `REQ-MREG-024`, `REQ-ADAPTER-083`, `REQ-ACCESS-164`, `REQ-RISK-066`, `INV-067` |
| `FV-CTL-35` | A stronger pause state or reason never allows an action a weaker one blocks | Verified | exhaustive enumeration (192 cases) | `SPEC-GOV-004`, `REQ-ACCESS-074`, `REQ-ACCESS-164` |

**`fv_ctl_gates.py`** (18 checks)

| Check | Property | Result | Method | Verifies |
|---|---|---|---|---|
| `FV-CTL-38` | postHealthCheck passes only if the collateral without rescue units covers the debt at max(minOpeningHealthFactor, 1.05, minHealthFactor), exactly, whatever minOpeningHealthFactor is within bounds | Verified | Z3 (unsat of negation) | `SPEC-PROXY-001`, `SPEC-CF-003`, `SPEC-CF-005`, `REQ-ADAPTER-026`, `REQ-RISK-068`, `REQ-PROXY-022`, `INV-025`, `REQ-RISK-059` |
| `FV-CTL-38-W` | Witness: a borrow leaving hfEx exactly 1.10 with no rescue units passes | Verified | Z3 witness (sat) | `SPEC-CF-005`, `REQ-ADAPTER-026` |
| `FV-CTL-102` | SPEC-CF-005 example: E = 3.12e28, subtraction 0.0312e18, hfEx = 1.1688e18; borrowing back to Aave hf 1.10 gives hfEx about 1.0714 and reverts | Verified | direct computation | `SPEC-CF-005`, `REQ-RISK-068` |
| `FV-CTL-39` | Every Adapter path that can lower an indebted account's health ends with postHealthCheck or the repay-with-collateral direction check; the unchecked paths run only at zero debt | Verified | direct computation | `REQ-ADAPTER-027`, `REQ-ADAPTER-078`, `REQ-ADAPTER-080`, `REQ-ADAPTER-071`, `INV-025` |
| `FV-CTL-40` | The Adapter's debt-free test (Spoke borrowCount == 0) is exact: no indebted account takes the unchecked path and no debt-free account the gated one, for any MarketRegistry | Verified | Z3 (unsat of negation) | `REQ-PROXY-034`, `REQ-PROXY-035`, `INV-025`, `INV-045` |
| `FV-CTL-100` | Repay, the debt-free branches of withdraw and removeLiquidity, repayAllAndWithdraw, burnSeized and the deleverage callbacks read no MarketRegistry, RiskModule, ParameterStore or oracle state; every new-activity path does read the registry | Verified | exhaustive enumeration (11 cases) | `REQ-ADAPTER-047`, `REQ-ADAPTER-086`, `REQ-PROXY-027`, `REQ-PROXY-035`, `REQ-ADAPTER-070`, `REQ-ADAPTER-081`, `REQ-ACCESS-148`, `INV-045`, `INV-081` |
| `FV-CTL-41` | Repay succeeds whenever Aave allows it and the payer funds it, for every pause state and reason, payer or borrower freeze, breaker and MarketRegistry implementation | Verified | Z3 (unsat of negation) | `INV-043`, `REQ-PROXY-027`, `REQ-PROXY-032`, `REQ-ACCESS-068`, `REQ-ADAPTER-047`, `REQ-ADAPTER-082` |
| `FV-CTL-42` | Repay pulls min(maxRepaySpend, live debt) for a partial repay and maxRepaySpend for a repay-all, refunds received - spent, nets exactly the live debt for a fee-free repay-all, and moves nothing at zero debt | Verified | Z3 (unsat of negation) | `SPEC-PROXY-003`, `REQ-PROXY-028`, `REQ-PROXY-029`, `REQ-PROXY-030`, `REQ-PROXY-083`, `REQ-PROXY-084`, `REQ-ADAPTER-085` |
| `FV-CTL-42-EX` | REQ-PROXY-083 example: Aave takes 3,024,657,535 and 2,005,342,465 return to the borrower | Verified | direct computation | `REQ-PROXY-083`, `REQ-ADAPTER-085` |
| `FV-CTL-43` | A borrow passes preBorrowCheck only if every collateral market is Live, fresh and unbroken, no collateral reserve is paused or frozen, every debt price is GHO's or a Live, fresh DebtOracle on the recorded source, the borrowed reserve's debt breaker is clear, an active keeper exists, with no drift and Hub shares == assets | Verified | Z3 (unsat of negation) | `SPEC-PROXY-002`, `REQ-ADAPTER-015`, `REQ-ADAPTER-016`, `REQ-RISK-061`, `REQ-ADAPTER-061`, `REQ-ADAPTER-019`, `REQ-ADAPTER-021`, `REQ-RISK-065`, `REQ-RISK-071`, `REQ-ADAPTER-010`, `INV-023`, `INV-024`, `INV-060`, `INV-029`, `INV-072` |
| `FV-CTL-43-W` | Witness: a two-market, three-reserve account (GHO and a Live DebtOracle reserve) passes preBorrowCheck | Verified | Z3 witness (sat) | `REQ-ADAPTER-024` |
| `FV-CTL-103` | A withdraw-with-debt passes preWithdrawCheck only under the same gates except Offboarding and Aave-frozen collateral, and with the debt breaker of every held reserve clear | Verified | Z3 (unsat of negation) | `REQ-ADAPTER-025`, `REQ-PROXY-036`, `REQ-RISK-065`, `INV-024` |
| `FV-CTL-44` | The borrowed reserve's price source, DebtOracle state and freshness are checked even before the account holds that debt | Verified | Z3 (unsat of negation) | `REQ-PROXY-019`, `SPEC-PROXY-002`, `REQ-RISK-061` |
| `FV-CTL-45` | T-60 as scoped: with the reviewed RiskModule no borrow completes against a paused or frozen collateral reserve; with any RiskModule Aave refuses a paused or frozen borrowed reserve | Verified | Z3 (unsat of negation) | `INV-060`, `REQ-PROXY-079`, `REQ-ADAPTER-019`, `REQ-ADAPTER-061` |
| `FV-CTL-101` | A pledge admitted through an exemption (Paused(General), a frozen caller, a tripped market breaker, the pool-share cap or minPledgeUsd above $10) is a rescue top-up: indebted, below minOpeningHealthFactor, charged at most its restore amount and worth at least min(minPledgeUsd, $10); and every such rescue passes unless the reason is MintPathSuspect | Verified | Z3 (unsat of negation) | `REQ-RISK-066`, `REQ-RISK-067`, `REQ-ADAPTER-083`, `REQ-ADAPTER-082`, `REQ-RISK-016`, `INV-082` |
| `FV-CTL-101-EX` | REQ-RISK-066 example: restoreBooked = 266,666,666,667 ($2,666.67); a $2,000 rescue passes, a $3,000 one reverts NotRescueTopUp; at price8 80,000,000 the restore amount is 333,333,333,334 | Verified | direct computation | `REQ-RISK-066`, `SPEC-CAP-003`, `REQ-ADAPTER-083` |
| `FV-CTL-46` | borrowNonce rises by exactly 1 per successful borrow, is unchanged by a reverted one, and admits one borrow per nonce value | Verified | Z3 (unsat of negation) | `INV-019`, `REQ-PROXY-015` |
| `FV-CTL-47` | A wallet's pledge, borrow or withdrawal can act only on its own proxy, never on another wallet's account | Verified | Z3 (unsat of negation) | `REQ-ADAPTER-066`, `REQ-PROXY-053`, `Q-223` |

**`fv_ctl_params.py`** (24 checks)

| Check | Property | Result | Method | Verifies |
|---|---|---|---|---|
| `FV-CTL-53` | A regular pledge passes only if its exact value reaches minPledgeUsd and a rescue top-up only if it reaches min(minPledgeUsd, $10) and is eligible within the restore amount; an eligible rescue at or above that minimum is never refused for value; the booked charge is >= 1 and never below the value | Verified | Z3 (unsat of negation) | `SPEC-CAP-001`, `REQ-RISK-057`, `REQ-RISK-066`, `REQ-RISK-067`, `REQ-PSTORE-005`, `INV-028` |
| `FV-CTL-54` | After a passing pledge: sliceUsd <= usdCharge and > 0 only for an eligible top-up within restoreBooked; a non-zero slice fits topUpSliceUsd and the token and depositor counters exceed their caps by at most the slice; rescueUnits is L for a rescue, ceil(L*sliceUsd/usdCharge) for a slice top-up, 0 otherwise, and never above L | Verified | Z3 (unsat of negation) | `SPEC-CAP-002`, `SPEC-CAP-003`, `REQ-RISK-025`, `REQ-RISK-066`, `INV-028` |
| `FV-CTL-55` | Pledge price-state rule of the RiskModule equals the LPOracle state-effects table (read from 2.10) for new accounts and top-ups | Verified | exhaustive enumeration (13 cases) | `REQ-RISK-017`, `INV-026`, `REQ-ORACLE-015` |
| `FV-CTL-56` | Every tighten setter (24 ParameterStore parameters) moves only in the safer direction inside its hard and liveness bounds; every step-limited loosening moves one step (0.03e18, x1.5 exact product, slice base max(old, floor(cap/10)), +25 bps) at least normalDelay >= 345,600 s after the previous one and records its time | Verified | Z3 (unsat of negation) | `SPEC-GOV-011`, `SPEC-GOV-009`, `REQ-PSTORE-017`, `REQ-CONFIG-051`, `REQ-CONFIG-052`, `REQ-ACCESS-120`, `REQ-ACCESS-161` |
| `FV-CTL-57` | buySlippageAllowanceBps is never set or tightened below buySlippageAllowanceMinBps, the floor never above the allowance, and every accepted allowance admits the honest buy whose cost was validated at listing (cost <= SPEC-LIQ-015 bound) | Verified | Z3 (unsat of negation) | `REQ-PSTORE-015`, `REQ-PSTORE-006`, `REQ-CONFIG-052`, `INV-047`, `INV-046`, `REQ-ACCESS-151`, `SPEC-LIQ-015` |
| `FV-CTL-130` | The two-leg inequality holds for every Active/Offboarding market and approved non-GHO reserve after every setBuySlippageAllowanceBps, tightenBuySlippageAllowanceBps, slippageAllowanceMinBps or maxFlashFeeBps change, activateMarket, approveDebtReserve and removeDebtReserve (inductive step, per pair) | Verified | Z3 (unsat of negation) | `REQ-PSTORE-021`, `REQ-MREG-032`, `REQ-CONFIG-052`, `INV-047`, `REQ-PSTORE-006` |
| `FV-CTL-131` | Spec examples: minLB 10,200 with floor 30 bps admits c = 169 and refuses 170; minLB 10,250 with 50 bps admits 198 and refuses 199; floor max(15, 30) = 30 admits tightening to 30, refuses 29 and a floor of 51 above a 50 bps allowance | Verified | direct computation | `REQ-PSTORE-021`, `REQ-MREG-032`, `REQ-PSTORE-015`, `REQ-CONFIG-052` |
| `FV-CTL-139` | REQ-PSTORE-006 example: buying 10,000 USDC at Pdebt $0.9998 with 50 bps may spend at most 10,048 GHO under the SPEC-LIQ-015 bound | Violated | direct computation | `REQ-PSTORE-006`, `SPEC-LIQ-015` |
| `FV-CTL-132` | Each breaker tightener (2.9 table: price drop, pool share, seizure, route failures lowered; cooldown raised; deficit max lowered) is short, makes its breaker strictly more sensitive within its bounds, and breakerPoolShareBps >= poolShareMaxBps survives both setters | Verified | Z3 (unsat of negation) | `REQ-PSTORE-016`, `REQ-ROLE-112`, `REQ-CONFIG-049` |
| `FV-CTL-133` | tightenMaxShortfallBps lowers within [0, 5,000] and never widens any leg's slippage; tightenDebtStressRiseBps raises within [100, 5,000] and the served stress price ceil(accepted*(10^4+rise)/10^4) is never below the accepted price; spec examples hold | Verified | Z3 (unsat of negation) | `REQ-PSTORE-018`, `REQ-PSTORE-020`, `SPEC-LIQ-019`, `SPEC-ORC-018`, `REQ-ROLE-112` |
| `FV-CTL-134` | Three loosenings of one key span at least 2 x MIN_NORMAL_DELAY = 691,200 s, lower minOpeningHealthFactor by at most 0.09e18 and raise a cap by at most 3.375x, however normalDelay moves within its bounds | Verified | Z3 (unsat of negation) | `SPEC-GOV-011`, `REQ-PSTORE-017`, `REQ-ACCESS-161`, `SPEC-GOV-003` |
| `FV-CTL-135` | Spec examples: 1.10 -> 1.07 accepted, 1.0699 LoosenStepTooLarge, a second loosening at T + 3 days LoosenTooSoon(T + 432,000); $5M -> $7.5M accepted, +1 refused; 100 -> 125 bps accepted, 126 refused; 40 -> 65 -> 90 -> 100 in three steps; a slice at 0 restores to 1.5 x cap/10; 50 -> 75 bps, 76 refused | Verified | direct computation | `SPEC-GOV-011`, `REQ-PSTORE-017`, `REQ-CONFIG-071`, `MKT-053`, `REQ-PSTORE-006` |
| `FV-CTL-136` | Spec examples: $99,995 charge and value at 199,990,000; $50,000 charge at the $1 floor; 999,950,000 and 999,934,990 below $10, 1,000,149,990 and 1,000,134,976 above; a $12 rescue passes and a $12 ordinary top-up fails at minPledgeUsd $50 | Verified | direct computation | `SPEC-CAP-001`, `REQ-PSTORE-005`, `REQ-RISK-067`, `REQ-RISK-057` |
| `FV-CTL-137` | REQ-RISK-057 and REQ-RISK-066 name the same revert for every pledge below a minimum | Violated | Z3 (sat of negation) | `REQ-RISK-057`, `REQ-RISK-066` |
| `FV-CTL-58` | Every page (1.4 role table, 1.5 class column, 2.9 setter table and REQ-CONFIG-049, 2.15 launch list, 3.8 MKT-027) names the same parameters as having a short-delay tighten selector, with the same safer direction; usdBand and grace parameters have none on any page | Verified | exhaustive enumeration (53 cases) | `REQ-CONFIG-049`, `REQ-ROLE-027`, `REQ-ROLE-105`, `REQ-ACCESS-155`, `REQ-PSTORE-002`, `MKT-027` |
| `FV-CTL-59` | Across tightenCaps, loosenCaps, the allowance setters and debt-reserve listing and removal: 0 <= perCall <= per24h <= 20,000 GHO, perCall <= 1,000 GHO, and every cap write leaves the key closed (0, 0) or perCall >= 2 x floorRoundingAllowanceGho | Verified | Z3 (unsat of negation) | `REQ-BUDGET-006`, `REQ-BUDGET-017`, `REQ-BUDGET-019`, `REQ-ACCESS-058`, `REQ-ROLE-094` |
| `FV-CTL-60` | REQ-CONFIG-050 as written: 2 x floorRoundingAllowanceGho <= perCallCap for every approved reserve whose caps are not both 0, across every cap and allowance setter and debt-reserve listing; a closed (0, 0) reserve is allowed and never bounds the allowance | Verified | Z3 (unsat of negation) | `REQ-CONFIG-050`, `REQ-ACCESS-132`, `REQ-BUDGET-017`, `REQ-BUDGET-022`, `REQ-ROLE-027` |
| `FV-CTL-142` | SPEC-SET-002 bound for every (spoke, debtReserveId) key: closed (0, 0) or 2 x floorRoundingAllowanceGho <= perCallCap, across every setter including removeDebtReserve | Violated | Z3 (sat of negation) | `SPEC-SET-002`, `REQ-CONFIG-050`, `REQ-MREG-010` |
| `FV-CTL-141` | Spec examples: per-call cap 25 GHO admits an allowance of 12.5e18 and refuses 12.5e18 + 1; with a 1 GHO allowance tightenCaps to 1.5 GHO reverts, to 10 GHO succeeds, (0, 0) closes the USDC reserve | Verified | direct computation | `REQ-CONFIG-050`, `REQ-BUDGET-006` |
| `FV-CTL-138` | The market sub-cap lies in [100 GHO, max(100 GHO, per24hCap)] for any reported count; with a correct count k and floor(per24hCap/k) >= 100 GHO, markets drawing within their sub-caps always leave each market its share in the reserve window; spec examples hold | Verified | Z3 (unsat of negation) | `SPEC-SET-006`, `REQ-BUDGET-024`, `REQ-BUDGET-025`, `REQ-MREG-031`, `REQ-ACCESS-058` |
| `FV-CTL-61` | Under any sequence of tighten, loosen, structural and setFeed calls every relational bound stays satisfied: slice <= cap, borrowPriceMaxAge <= min(heartbeat + 600, 4,200) and <= liquidationPriceMaxAge, heartbeat < feedMaxAge <= liquidationPriceMaxAge, slippage floor, grace bounds, breakerPoolShareBps >= poolShareMaxBps, buy floor <= allowance | Verified | Z3 (unsat of negation) | `REQ-CONFIG-050`, `REQ-CONFIG-052`, `REQ-CONFIG-023`, `REQ-PSTORE-016`, `REQ-PSTORE-015`, `REQ-ACCESS-095`, `REQ-ACCESS-096`, `INV-047` |
| `FV-CTL-99` | No borrow, withdraw-with-debt or new-account pledge completes while any Spoke can draw the vault-token asset | Verified | Z3 (unsat of negation) | `INV-029`, `REQ-CONFIG-043`, `INV-057` |
| `FV-CTL-62` | SHORT_ELIGIBLE (2.15 launch list) holds no loosen, structural set, role, upgrade, beacon, initializer, timelock, price-source, route, keeper-add, unfreeze or reset selector; setShortDelaySelector(..., true) admits only SHORT_ELIGIBLE pairs, so no loosen selector can ever be short | Verified | exhaustive enumeration (773 cases) | `REQ-ACCESS-142`, `REQ-ACCESS-155`, `REQ-ACCESS-141`, `REQ-CONFIG-053`, `REQ-PSTORE-002` |
| `FV-CTL-140` | With both guardians unavailable the governance Safe halts new activity at the short delay: freeze, pause, freezeAddress, both breaker trips and useStandbyRoute are APPLICATION_ADMIN selectors in SHORT_ELIGIBLE, so a batch of them needs 43,200 s; adding a lift makes it normal | Verified | exhaustive enumeration (6 cases) | `REQ-ACCESS-155`, `REQ-ACCESS-128`, `REQ-ACCESS-062`, `REQ-ACCESS-063`, `REQ-MREG-028`, `SPEC-GOV-001` |

**`fv_ctl_registry.py`** (13 checks)

| Check | Property | Result | Method | Verifies |
|---|---|---|---|---|
| `FV-CTL-79` | A market moves only None -> Registered -> Active -> Offboarding, Registered -> Cancelled and Cancelled -> Registered (relisting with its token and LPOracle); activation needs every check; Active never returns and Offboarding is final | Verified | exhaustive enumeration (120 cases) | `REQ-CONFIG-013`, `REQ-CONFIG-042`, `REQ-CONFIG-047`, `REQ-CONFIG-048`, `REQ-MREG-015`, `REQ-MREG-030`, `MKT-002` |
| `FV-CTL-80` | An in-kind window, opened by enableInKind or the automatic trigger, ends at most inKindExpiry <= 7 days after its last opening, closes with no transaction, and a later inKindExpiry change never moves it | Verified | Z3 (unsat of negation) | `SPEC-GOV-010`, `REQ-MREG-016`, `REQ-MREG-029`, `REQ-ACCESS-057` |
| `FV-CTL-81` | From every reachable state with a cancelled registration, the pool's next listing batch (no new token) reuses the reserved marketId, leaves marketCount unchanged and can be activated; a different LPOracle reverts VaultTokenMismatch | Verified under bounded model | exhaustive enumeration (16 cases) | `REQ-CONFIG-048`, `REQ-CONFIG-007`, `REQ-CONFIG-032`, `REQ-MREG-030`, `MKT-051`, `REQ-VTOKEN-021`, `REQ-VTOKEN-038` |
| `FV-CTL-82` | Every pool (and so its vault-token, LPOracle and reserve keys) maps to at most one market that is not cancelled; a marketId belongs to one pool for life and equals the marketId its vault token carries | Verified under bounded model | exhaustive enumeration (41 cases) | `REQ-CONFIG-007`, `REQ-VTOKEN-021`, `REQ-MREG-030`, `MKT-051` |
| `FV-CTL-147` | activeMarketCount (Active or Offboarding markets of the Spoke) never decreases and grows by exactly one only on activateMarket; a cancelled or registered market is never counted (example: 3 Active + 1 Offboarding = 4) | Verified under bounded model | exhaustive enumeration (42 cases) | `REQ-MREG-031`, `SPEC-SET-006`, `REQ-BUDGET-024` |
| `FV-CTL-83` | getDebtReserveIds equals the approved set, without duplicates, after every approve/remove sequence | Verified under bounded model | exhaustive enumeration (62 cases) | `REQ-MREG-006`, `REQ-MREG-010`, `REQ-PROXY-034` |
| `FV-CTL-84` | A conversion route slot always holds a previously approved route that avoids the market's pool and shares no dependency with the other slot (disable clears only the flag, restore admits only an approved address); a token's primary, alternate and standby share no feed, are defined and primary and standby legs are hourly, so the routes in force share no feed and the primary in force is hourly; replacedSlot is None at listing | Verified | Z3 (unsat of negation) | `REQ-ACCESS-047`, `REQ-ACCESS-048`, `REQ-CONFIG-060`, `REQ-CONFIG-061`, `REQ-CONFIG-062`, `REQ-ACCESS-127`, `REQ-CONFIG-021`, `REQ-CONFIG-027`, `REQ-MREG-027`, `REQ-MREG-028`, `REQ-ORACLE-054` |
| `FV-CTL-143` | useStandbyRoute succeeds only for the pause guardian or the timelock, onto the Primary or Alternate slot of a listed token with a non-empty standby, no active switch, every standby leg defined and, for Primary, hourly; otherwise it reverts with the REQ-MREG-028 error; a second switch always reverts | Verified | exhaustive enumeration (722 cases) | `REQ-MREG-028`, `REQ-ACCESS-159`, `REQ-CONFIG-021`, `MKT-033` |
| `FV-CTL-144` | priceRouteVersion rises by exactly one on every successful setPriceSource, useStandbyRoute, cancelStandbySwitch and restorePriceRoute and on nothing else; every change of the routes in force (activePriceRoutes) comes with an increment | Verified | Z3 (unsat of negation) | `REQ-MREG-028`, `REQ-CONFIG-027`, `MKT-033`, `REQ-CONFIG-003` |
| `FV-CTL-145` | useStandbyRoute: pause guardian (immediate) or timelock (short, DAO-only cancel); cancelStandbySwitch: only the Aave governance executor, immediate, never a timelock operation; restorePriceRoute: only APPLICATION_ADMIN, not short-eligible, so at the normal delay | Verified | exhaustive enumeration (15 cases) | `REQ-MREG-028`, `REQ-ACCESS-159`, `REQ-ACCESS-155`, `REQ-ACCESS-156`, `MKT-033` |
| `FV-CTL-146` | activePriceRoutes substitutes the standby into the replaced slot only: the other slot is its recorded route, None gives the recorded pair, and switch, cancel and restore never change the recorded primary, alternate or standby | Verified | Z3 (unsat of negation) | `REQ-MREG-028`, `REQ-MREG-027`, `REQ-CONFIG-027` |
| `FV-CTL-85` | Only a fixed member acquires a free Lock, only the holder releases it, nothing runs through delegatecall, and an inner call succeeds only while its named caller holds the Lock | Verified | Z3 (unsat of negation) | `INV-054`, `REQ-LOCK-019`, `REQ-LOCK-020`, `REQ-LOCK-021`, `REQ-LOCK-022`, `REQ-ROLE-021` |
| `FV-CTL-85-W` | Witness: the Adapter acquires the free Lock | Verified | Z3 witness (sat) | `REQ-LOCK-019` |

**`fv_ctl_oracle.py`** (38 checks)

| Check | Property | Result | Method | Verifies |
|---|---|---|---|---|
| `FV-CTL-63` | Served price by state (SPEC-ORC-017): fresh when Live, min(fresh, A) when Drifting without disagreement, min(lower, A) during a disagreement, A when Cached, 1 when Expired; served >= 1 always, <= A whenever not Live, <= fresh whenever not failed, <= price8 of getTokenPrices() and equal to it when Live or Cached; the accepted price and checkpoint stay >= 1 after every poke | Verified | Z3 (unsat of negation) | `INV-055`, `INV-087`, `REQ-ORACLE-020`, `SPEC-ORC-017`, `REQ-ORACLE-085`, `REQ-ORACLE-044`, `REQ-ORACLE-060` |
| `FV-CTL-64` | The accepted price changes only from a Live observation newer than the stored one; its timestamp never decreases and is a source timestamp; re-reading the same rounds never refreshes it; the served timestamp is a source timestamp (accepted when failed, the routes in use otherwise) | Verified | Z3 (unsat of negation) | `INV-056`, `REQ-ORACLE-021`, `REQ-ORACLE-029`, `SPEC-ORC-012`, `REQ-ORACLE-041`, `REQ-ORACLE-066` |
| `FV-CTL-65` | expiredLatched is set only when source timestamps show Expired; a caught error, a config/decimals failure or a gas shortfall never sets it, and a gas-short poke changes nothing | Verified | Z3 (unsat of negation) | `REQ-ORACLE-030`, `INV-031`, `REQ-ORACLE-024`, `REQ-ORACLE-065` |
| `FV-CTL-66` | poke() is idempotent within a block: a second poke on the same reads changes no stored field (timers, latch, recoveredAt, accepted price, checkpoint) | Verified | Z3 (unsat of negation) | `INV-031`, `REQ-ORACLE-026`, `REQ-ORACLE-033`, `REQ-ORACLE-088`, `REQ-ORACLE-095` |
| `FV-CTL-67` | After a poke a disagreeing market is Drifting, served at its lower routes and liquidation-paused; the first-observation time is set once per episode (per route version) and never moves; the pause lasts < disagreementPauseMax from it, then disagreementExpired holds until the routes agree | Verified | Z3 (unsat of negation) | `SPEC-ORC-016`, `REQ-ORACLE-022`, `REQ-ORACLE-028`, `INV-059`, `REQ-ORACLE-018`, `REQ-ORACLE-084` |
| `FV-CTL-68` | No stored timer, latch or route version keeps a market out of Live once its inputs are valid, fresh and agree; a failed market is Expired at most cachedWindow after its failure start | Verified | Z3 (unsat of negation) | `REQ-ORACLE-016`, `REQ-ORACLE-006`, `REQ-ORACLE-023`, `REQ-ORACLE-019` |
| `FV-CTL-69` | Cached window (SPEC-ORC-013): Cached is never reported at or after min(F + H, S_ts) + cachedWindow, F the true failure start and H the keeper poke interval; once a poke saw the recovery, Expired is never reported before F + cachedWindow; a stored failedSince only brings Expired earlier, and later failed pokes never move it | Verified | Z3 (unsat of negation) | `SPEC-ORC-013`, `REQ-ORACLE-017`, `REQ-ORACLE-027`, `REQ-ORACLE-037` |
| `FV-CTL-70` | A grace window started by the latch fallback recoveredAt = min(max(t0, t1), now) never starts after the poke's block and, when the recovered route's timestamp is its new round, never before the recovery; the REQ-ORACLE-032 example gives grace until 1,762,651,800 | Verified | Z3 (unsat of negation) | `INV-031`, `REQ-ORACLE-032`, `REQ-ORACLE-034`, `SPEC-ORC-014` |
| `FV-CTL-115` | The latch fallback never starts a grace window before the recovery, also when the recovered token is on a two-leg route or recovered through a standby switch (REQ-ORACLE-032: 'The window must start no earlier than the recovery') | Violated | Z3 (sat of negation) | `REQ-ORACLE-032`, `SPEC-ORC-002`, `REQ-ORACLE-094`, `INV-031` |
| `FV-CTL-71` | now - servedUpdatedAt <= borrowPriceMaxAge() (resp. liquidationPriceMaxAge()) holds exactly when every leg in use is within its own borrow (resp. liquidation, alternates held to min(liq, borrow)) limit; both derived limits are never negative | Verified | Z3 (unsat of negation) | `SPEC-ORC-015`, `REQ-ORACLE-043`, `SPEC-PROXY-002`, `REQ-ADAPTER-016`, `REQ-ORACLE-090` |
| `FV-CTL-72` | For every combination of leg behaviours (10^4 cases x gas x Cached/Expired) latestAnswer() returns a value >= 1 (1 exactly when Expired, <= A when not Live), and reverts only with InsufficientGas after a caught failure below pokeMinGas | Verified | exhaustive enumeration (40000 cases) | `INV-055`, `REQ-ORACLE-020`, `REQ-ORACLE-039`, `REQ-ORACLE-001`, `REQ-ORACLE-002`, `REQ-ORACLE-061` |
| `FV-CTL-73` | price8 = isqrt(4 v0 v1) - 1 is >= 1, (price8 + 1)^2 <= 4 v0 v1 (never above 2*sqrt(v0 v1)), within 2 units of it, and 4 v0 v1 < 2^256 | Verified | Z3 (unsat of negation) | `SPEC-ORC-008`, `INV-055`, `REQ-ORACLE-012` |
| `FV-CTL-74` | The stable ceiling never raises a price, is monotone, and is a no-op at or below the ceiling | Verified | Z3 (unsat of negation) | `SPEC-ORC-004`, `REQ-ORACLE-009` |
| `FV-CTL-75` | The agreement check \|p - b\| * 10^4 <= T * min(p, b) is symmetric in p and b (both sides are order-free) and uses no division; the SPEC-ORC-003 examples agree (b = 99,900,000) and disagree (b = 97,500,000) at T = 225 | Verified | Z3 (unsat of negation) | `SPEC-ORC-003`, `REQ-ORACLE-008` |
| `FV-CTL-75-W` | Witness: floor division would admit T + 1 bps where the exact check refuses (why the cross-multiplied form is required) | Verified | Z3 witness (sat) | `SPEC-ORC-003` |
| `FV-CTL-76` | The reference sqrt price never overflows and lies in [MIN_SQRT_RATIO, MAX_SQRT_RATIO) after clamping | Verified | Z3 (unsat of negation) | `SPEC-ORC-009`, `REQ-ORACLE-014` |
| `FV-CTL-110` | Lower-route price (SPEC-ORC-017): with w_i = ceil_i(min(p_i, b_i)) when both routes are valid (else v_i), 1 <= w_i <= v_i, so w0 w1 <= v0 v1 and lower = isqrt(4 w0 w1) - 1 satisfies 1 <= lower <= fresh; served = min(lower, A) lies in [1, A] | Verified | Z3 (unsat of negation, 4 lemmas) | `SPEC-ORC-017`, `SPEC-ORC-008`, `REQ-ORACLE-086`, `INV-055` |
| `FV-CTL-111` | SPEC-ORC-017 example: A = 199,980,000; token1 routes 100,000,000 / 97,500,000 give lower = 197,484,175 and served 197,484,175; Cached serves 199,980,000; Expired serves 1; TWAP Drifting with fresh 199,986,998 serves 199,980,000; SPEC-ORC-012 fresh = 199,986,998 | Verified | direct computation | `SPEC-ORC-017`, `INV-087`, `SPEC-ORC-008`, `SPEC-ORC-012` |
| `FV-CTL-112` | Whenever some token disagrees (REQ-ORACLE-008) and the market is not failed, pauseActive or disagreementExpired holds, so the market is served at its lower routes and liquidationPaused is true (REQ-ORACLE-086: 'While some token disagrees (SPEC-ORC-016 pauseActive or disagreementExpired)') | Violated | Z3 (sat of negation) | `SPEC-ORC-016`, `SPEC-ORC-017`, `REQ-ORACLE-086`, `REQ-ORACLE-022`, `INV-059` |
| `FV-CTL-113` | Expired serves exactly 1 (REQ-ORACLE-085) and Cached serves A; whenever the served price is one of the stress values (Cached A, Expired 1, a disagreement's lower routes), liquidationPaused is true, so no stress value sizes a seizure of this market | Verified | Z3 (unsat of negation) | `REQ-ORACLE-085`, `SPEC-ORC-016`, `SPEC-ORC-017`, `INV-087`, `REQ-SWAP-008` |
| `FV-CTL-114` | USD band: when both tokens are stables v0 v1 <= 10^16 < usdBandHigh^2, so only the uncapped lower bound can trip and a stable premium never breaches; testing capped values never breaches where uncapped would not; examples: GHO 104,700,000 with USDC 1e8 is in band (uncapped it would breach), 99,987,000 x 100,010,000 in band, both at 89,000,000 breach low | Verified | Z3 (unsat of negation, 5 lemmas) | `SPEC-ORC-011`, `REQ-ORACLE-009`, `REQ-ORACLE-056`, `REQ-ORACLE-015`, `REQ-ORACLE-073` |
| `FV-CTL-116` | Feed age rules: borrowPriceMaxAge = min(hb + 600, 4,200) is at most 4,200 and at most liquidationPriceMaxAge; for every primary or standby leg (hb <= 3,600) it equals hb + 600, so a feed whose next round comes at most hb + d after the last (d < 600 s network delay) is never refused by the borrow age | Verified | Z3 (unsat of negation) | `REQ-CONFIG-023`, `REQ-CONFIG-021`, `REQ-ORACLE-054`, `SPEC-ORC-015` |
| `FV-CTL-116-W` | Witness: the REQ-CONFIG-023 examples are admissible: USDC/USD hb 3,600 (borrow 4,200, feedMaxAge = liquidation 4,200) and a USDC/ETH alternate leg hb 86,400 (borrow 4,200, feedMaxAge = liquidation 87,000) | Verified | Z3 witness (sat) | `REQ-CONFIG-023`, `REQ-ORACLE-054` |
| `FV-CTL-117` | Alternates held to their borrow age: each leg's liquidation limit is >= its borrow limit (so borrowPriceMaxAge() <= liquidationPriceMaxAge()); while a serving alternate leg is past its borrowPriceMaxAge (ALTERNATE_PAST_BORROW_AGE) the liquidation age test already fails | Verified | Z3 (unsat of negation) | `REQ-ORACLE-090`, `SPEC-ORC-015`, `SPEC-ORC-016`, `REQ-ORACLE-019` |
| `FV-CTL-118` | SPEC-ORC-015 / REQ-ORACLE-090 examples: servedUpdatedAt 1,762,646,400, liquidation and borrow deadlines 1,762,650,600, both age limits 4,200 (own alternate limit would allow seizure until 1,762,733,400); with token1 back on its primary both deadlines 1,762,650,600; at 1,762,650,601 the USDT/ETH leg is 4,201 s old and ALTERNATE_PAST_BORROW_AGE is set | Verified | direct computation | `SPEC-ORC-015`, `REQ-ORACLE-090`, `REQ-ORACLE-054` |
| `FV-CTL-119` | SPEC-ORC-013 examples: staleFrom 1,004,201 and 1,134,201 give staleAt 1,134,201, Cached until 1,137,800 and Expired from 1,137,801; a failedSince of 1,000,000 left by an unobserved recovery gives failureStart 1,000,000 at the poke at 1,004,100, Expired at once instead of Cached until 1,007,600 | Verified | direct computation | `SPEC-ORC-013` |
| `FV-CTL-120` | Phase rollover: with the fallback prev = seen.updatedAt <= the true previous round, every leg gap, route stale interval S_r and both-stale interval B_i contains the true one with the same end, so Expired-by-timestamps evidence is never lost on an aggregator upgrade, recoveredAt_new never decreases, and recoveredAt_new <= now | Verified | Z3 (unsat of negation) | `SPEC-ORC-014`, `REQ-ORACLE-089`, `REQ-ORACLE-075`, `REQ-ORACLE-033` |
| `FV-CTL-121` | SPEC-ORC-014 examples: S_primary = [1,004,201, 1,200,000), alternate gap [1,134,201, 1,190,000), B lasts 55,799 s >= 3,600, recoveredAt = 1,190,000, graceEndsAt = 1,191,800; phase fallback from seen 996,400 gives [1,000,601, 1,200,000), which contains the true gap, and B is unchanged | Verified | direct computation | `SPEC-ORC-014`, `REQ-ORACLE-089`, `REQ-ORACLE-034` |
| `FV-CTL-122` | A caught error never starts grace by itself: over every route outcome pair and latch origin, a grace window starts only from source timestamps (getRoundData, the previous-phase round, the oracle's own seen timestamp, staleFrom, or a latch set from timestamps); an unusable lookup or an Invalid/Error route gives no evidence | Verified | exhaustive enumeration (320 cases) | `REQ-ORACLE-065`, `REQ-ORACLE-089`, `REQ-ORACLE-030`, `REQ-ORACLE-075`, `SPEC-ORC-014` |
| `FV-CTL-123` | A route-version change changes only disagreeSince (now if some token disagrees, else 0); failedSince, expiredLatched, recoveredAt, the accepted price and the checkpoint are as without the change; the state is the same (never Live by itself); a failed market with failedSince != 0 is Expired from failedSince + cachedWindow whatever the new routes give; REQ-ORACLE-095 example: Expired from 1,762,653,600, disagreeSince 1,762,652,000 | Verified | Z3 (unsat of negation) | `REQ-ORACLE-095`, `REQ-ORACLE-094`, `REQ-ORACLE-028`, `REQ-MREG-028`, `INV-059` |
| `FV-CTL-123-W` | Witness (REQ-ORACLE-095 example): Cached with failedSince 1,762,650,000; a switch at 1,762,652,000 to a standby that disagrees with the alternate yields Drifting with disagreeSince 1,762,652,000 | Verified | Z3 witness (sat) | `REQ-ORACLE-095`, `REQ-MREG-028` |
| `FV-CTL-124` | Failover and standby: over every primary/alternate/standby validity and slot, the quote is the primary slot when valid, else the alternate slot, else none; the standby in force is evaluated exactly as the route it replaces; every route in the primary slot has hourly legs (hb <= 3,600) | Verified | exhaustive enumeration (375 cases) | `REQ-ORACLE-005`, `REQ-ORACLE-006`, `REQ-ORACLE-094`, `REQ-MREG-028`, `REQ-CONFIG-021`, `REQ-MREG-027` |
| `FV-CTL-125` | The checkpoint is written only by a poke with now >= checkpoint.at + 3,600, at block time, and always equals the accepted price after REQ-ORACLE-029 (never a stress-served price); a gas-short poke never writes it | Verified | Z3 (unsat of negation) | `REQ-ORACLE-088`, `SPEC-BRK-001`, `REQ-ORACLE-062` |
| `FV-CTL-126` | Checkpoint example: (199,980,000, 1,762,650,000) is kept by a poke at 1,762,652,000 and replaced by (199,950,000, 1,762,653,700) at 1,762,653,700; 193,900,000 is 3.03 % below it and trips a 300 bps price-drop breaker until 1,762,660,900 (SPEC-BRK-001 compares while now - at <= 7,200) | Verified | direct computation | `REQ-ORACLE-088`, `SPEC-BRK-001` |
| `FV-CTL-127` | DebtOracle (SPEC-ORC-018): served = q Live, max(p, b, A) disagreeing, A Cached, ceil(A(10^4 + delta)/10^4) Expired; served >= 1, served >= A whenever not Live, the Expired value is >= the exact rise, < exact + 1 and <= 1.5 A + 1, and A (10^4 + delta) < 2^256; liquidationPaused whenever not Live, so no stress value prices a repayment; accepted is written only when Live and newer; no stable ceiling (served = q above $1) | Verified | Z3 (unsat of negation) | `SPEC-ORC-018`, `REQ-ORACLE-093`, `REQ-ORACLE-092`, `REQ-ORACLE-091`, `REQ-ORACLE-096`, `REQ-ORACLE-098`, `INV-087`, `REQ-SWAP-091` |
| `FV-CTL-127-W` | Witness: a Live debt asset above $1 is served uncapped (q = 100,300,000) | Verified | Z3 witness (sat) | `SPEC-ORC-018`, `REQ-ORACLE-093` |
| `FV-CTL-128` | SPEC-ORC-018 examples: A = 99,990,000 Expired serves 104,989,500 at delta 500 (10,000 USDC of debt counts $10,498.95) and 101,989,800 at delta 200; A = 99,987,001 at delta 500 rounds 104,986,351.05 up to 104,986,352; routes 99,990,000 / 100,300,000 disagreeing with A = 99,995,000 serve 100,300,000; Cached serves 99,995,000 | Verified | direct computation | `SPEC-ORC-018`, `INV-087` |
| `FV-CTL-129` | inGrace iff recoveredAt != 0 and recoveredAt <= now < recoveredAt + graceDuration: a grace window lasts exactly graceDuration seconds from recoveredAt, never before it, and a recoveredAt capped at now (SPEC-ORC-014, REQ-ORACLE-032) is in grace at the poke that sets it whenever graceDuration > 0 | Verified | Z3 (unsat of negation) | `REQ-ORACLE-034`, `REQ-ORACLE-033`, `INV-031` |

**`fv_ctl_upgrade_lens.py`** (10 checks)

| Check | Property | Result | Method | Verifies |
|---|---|---|---|---|
| `FV-CTL-86` | An implementation whose constructor ran _disableInitializers() can never be initialized or reinitialized; a proxy's initializer runs once | Verified | Z3 (unsat of negation) | `REQ-ACCESS-150`, `REQ-PROXY-003`, `REQ-PROXY-004`, `REQ-ADAPTER-004`, `REQ-ORACLE-080`, `REQ-ACCESS-031` |
| `FV-CTL-87` | After any implementation change only the timelock (UUPS reinitializer inside upgradeToAndCall) or the AaveAdapter (beacon: no extra initializer, no reinitializer, OnlyAdapter state functions) can change a proxy's state | Verified | exhaustive enumeration (100 cases) | `REQ-PROXY-005`, `REQ-PROXY-007`, `REQ-ACCESS-031`, `REQ-ACCESS-147`, `REQ-PROXY-086`, `REQ-PROXY-004` |
| `FV-CTL-88` | The append-only layout rule accepts exactly the appending and identical layouts and rejects every delete, retype, insert and reorder | Verified | exhaustive enumeration (20 cases) | `REQ-ADAPTER-004`, `REQ-PROXY-005`, `REQ-ORACLE-080` |
| `FV-CTL-89` | One PositionProxy per (wallet, spoke): equal CREATE2 addresses imply the same pair (keccak modelled as injective) | Verified | Z3 (unsat of negation) | `INV-012`, `REQ-PROXY-052`, `REQ-PROXY-053`, `REQ-ARCH-035` |
| `FV-CTL-90` | For every deployed account the Adapter, Lens and previewPledge proxy views equal the stored proxyOf before and after any ProxyManager upgrade (even one that changed the creation code), Lens reports deployed = true; deployProxy refuses a frozen wallet and predictProxy reads no MarketRegistry state | Verified | Z3 (unsat of negation) | `REQ-PROXY-049`, `REQ-LENS-008`, `REQ-RISK-031`, `REQ-PROXY-099`, `REQ-PROXY-053` |
| `FV-CTL-149` | With the creation-code hash kept across ProxyManager upgrades, the address the views show before an account exists (deployed = false) is the address deployProxy later creates, and deployProxy's own equality check with predictProxy cannot fail | Verified | Z3 (unsat of negation) | `REQ-PROXY-050`, `REQ-PROXY-052`, `REQ-LENS-008` |
| `FV-CTL-77` | checkRecordBacking returns an empty page whenever offset >= nextRecordId and otherwise walks offset .. offset + min(limit, n - offset) - 1 with no underflow or overflow, at most limit IDs, all below nextRecordId, for every 256-bit offset, limit and nextRecordId | Verified | Z3 (unsat of negation) | `REQ-LENS-014`, `REQ-LENS-024`, `REQ-LENS-023` |
| `FV-CTL-148` | The Lens paging rules give checkRecordBacking one outcome for every (offset, limit, nextRecordId) | Violated | Z3 (sat of negation) | `REQ-LENS-014`, `REQ-LENS-020`, `REQ-LENS-023`, `REQ-LENS-024` |
| `FV-CTL-78` | previewLiquidation's maxGhoSpend equals SPEC-LIQ-015's bound for a non-GHO debt and debtToCover for GHO, so any spend LPVaultSwap accepts is within the preview (SPEC-LIQ-015 example: 5,015 GHO) | Verified | Z3 (unsat of negation) | `REQ-LENS-028`, `SPEC-LIQ-015`, `REQ-LENS-016` |
| `FV-CTL-97` | Every view a third party can call mid-operation either reverts while the Lock is held or reads state the locked call does not write before its last external call | Verified | exhaustive enumeration (8 cases) | `REQ-LENS-006`, `REQ-LENS-021`, `REQ-VAULT-125`, `REQ-ORACLE-025`, `REQ-SWAP-104`, `REQ-MREG-026` |

**`fv_ctl_breakers.py`** (19 checks)

| Check | Property | Result | Method | Verifies |
|---|---|---|---|---|
| `FV-CTL-91` | No combination of pause state and reason, market or debt breaker, offboarding, or freeze of the caller or borrower blocks repay, debt-free withdrawal or removal, repayAllAndWithdraw, fees, zero-credit release, pending settlement, burnSeized, escrow claims or the liquidation of a frozen wallet's positions | Verified | exhaustive enumeration (1536 cases) | `INV-081`, `REQ-ADAPTER-086`, `REQ-ADAPTER-047`, `REQ-MREG-023`, `REQ-RISK-065`, `REQ-ACCESS-068`, `REQ-ROLE-068`, `INV-067` |
| `FV-CTL-151` | A rescue top-up passes every combination of breakers, address freeze, Frozen and Paused(General); only Paused(MintPathSuspect) and Offboarding stop it | Verified | exhaustive enumeration (128 cases) | `REQ-RISK-066`, `REQ-RISK-065`, `REQ-ADAPTER-082`, `REQ-ADAPTER-083`, `INV-081`, `INV-082` |
| `FV-CTL-96` | Pause state, breakers, offboarding and the address freeze combine monotonically: a stronger combination never allows an action a weaker one blocks | Verified | exhaustive enumeration (53460 cases) | `INV-081`, `REQ-MREG-003`, `REQ-ADAPTER-049`, `REQ-ACCESS-082` |
| `FV-CTL-109` | Breakers are read only in checkPledge (non-rescue), preBorrowCheck and preWithdrawCheck; no exit, liquidation path or repay with collateral reads one | Verified | exhaustive enumeration (20 cases) | `REQ-RISK-065`, `REQ-ACCESS-082`, `REQ-ADAPTER-086`, `REQ-ADAPTER-080`, `INV-081` |
| `FV-CTL-93` | freezeAddress reverts ProtectedAddress for every protected kind (timelock, Aave governance executor, every Avana contract, live vault tokens and oracles, DebtOracles, Hub, Spokes, GHO, the FlashMinter, recorded routes, registered proxies) | Verified | exhaustive enumeration (24 cases) | `REQ-MREG-020`, `REQ-ACCESS-157`, `INV-085`, `REQ-ACCESS-089`, `REQ-ACCESS-112` |
| `FV-CTL-92` | No sequence of guardian freezes (up to 4) stops liquidation of an account that needs the keeper path: at least keeperFloor active keepers remain and LPVaultSwap is never frozen | Verified under bounded model | exhaustive enumeration (104 cases) | `INV-046`, `INV-085`, `REQ-MREG-021`, `REQ-RISK-071`, `SPEC-GOV-008`, `REQ-ACCESS-112` |
| `FV-CTL-105` | Active keepers never fall below keeperFloor: every removeKeeper, freezeAddress, addKeeper and unfreezeAddress preserves \|A\| >= keeperFloor | Verified | Z3 (unsat of negation) | `SPEC-GOV-008`, `REQ-MREG-021`, `INV-085`, `INV-046` |
| `FV-CTL-105-EX` | SPEC-GOV-008 example: with 5 keepers and floor 3, the third freeze reverts KeeperFloorBreached(3, 3) and removing an active keeper at 3 reverts KeeperFloor(2, 3) | Verified | direct computation | `SPEC-GOV-008`, `REQ-MREG-021` |
| `FV-CTL-104` | No caller makes more than 20 freezes in any 24 consecutive hours: the rolling-window check keeps every window, past and future, at or below 20 | Verified | Z3 (unsat of negation) | `REQ-MREG-019`, `INV-085`, `REQ-ACCESS-157` |
| `FV-CTL-104-EX` | REQ-MREG-019 example: the 21st freeze at hour H0+2 reverts FreezeLimitReached; at H0+24 the window covers H0+1..H0+24 and 7 more freezes are allowed | Verified | direct computation | `REQ-MREG-019` |
| `FV-CTL-94` | A frozen address becomes unfrozen only by an unfreezeAddress the timelock executes after the normal delay | Verified | exhaustive enumeration (45 cases) | `REQ-MREG-022`, `REQ-ACCESS-157`, `REQ-ACCESS-111`, `REQ-ACCESS-003`, `INV-085` |
| `FV-CTL-95` | No guardian can cancel a pure unfreezeAddress operation; a batch that mixes it with another call stays cancellable by every canceller, and only delays the unfreeze | Verified | exhaustive enumeration (4 cases) | `SPEC-GOV-005`, `REQ-ACCESS-156`, `REQ-MREG-022`, `REQ-ACCESS-112`, `INV-085` |
| `FV-CTL-106` | Price-drop breaker: trips only on a fall strictly larger than breakerPriceDropBps against a checkpoint at most 2 hours old, is monotone in the price, and its products stay below 2^78 | Verified | Z3 (unsat of negation) | `SPEC-BRK-001`, `REQ-RISK-065`, `REQ-ORACLE-088` |
| `FV-CTL-106-EX` | SPEC-BRK-001 and SPEC-BRK-002 examples: 193,990,000 against 200,000,000 trips at 300 bps and 194,000,000 does not; supply 4.1e12 against liqHM 2e13 trips at 2,000 bps and 4e12 does not | Verified | direct computation | `SPEC-BRK-001`, `SPEC-BRK-002` |
| `FV-CTL-107` | Seizure surge: the window base equals the credited units before the window's first seizure, the latch compares exact products, and a latch never shortens latchedUntil (max with now + cooldown) | Verified | Z3 (unsat of negation) | `SPEC-BRK-005`, `SPEC-BRK-006`, `REQ-MREG-025`, `REQ-MREG-026`, `INV-081` |
| `FV-CTL-107-EX` | SPEC-BRK-005 and SPEC-BRK-006 examples: 2,000,000,000 seized units of 10,000,000,000 do not latch and one more does; route failures at 10:05, 10:31 and 10:52 latch until 16:52, while a third at 11:07 restarts the count at 1 | Verified | direct computation | `SPEC-BRK-005`, `SPEC-BRK-006` |
| `FV-CTL-108` | Issuer probe fails closed: a paused flag, a positive fee rate, a revert, an out-of-gas or malformed return trips the breaker; a probe of None never trips | Verified | exhaustive enumeration (15 cases) | `SPEC-BRK-003`, `SPEC-BRK-004`, `REQ-MREG-027`, `REQ-RISK-065` |
| `FV-CTL-108-EX` | SPEC-BRK-004 examples: a GHO deficit of 1,000.5 against breakerDeficitMax 1,000 trips DEFICIT; a SettlementBudget of 450 GHO against per24hCap 500 trips BUDGET | Verified | direct computation | `SPEC-BRK-004` |
| `FV-CTL-150` | Only the freeze guardian or the admin trips, only the pause guardian or the admin resets, only LPVaultSwap records; a record call from LPVaultSwap never reverts, so it can never revert a liquidation | Verified | exhaustive enumeration (72 cases) | `REQ-MREG-025`, `REQ-MREG-026`, `REQ-ACCESS-158`, `REQ-ROLE-108`, `INV-081` |

**`governance.qnt`** (module `gov`, `quint run --seed 0x1`, 10,000 samples × 12 steps)

| Check | Invariant | Result |
|---|---|---|
| `FV-CTL-98` | `execWaitedNormalDelay` | no violation in 10,000 samples |
| `FV-CTL-98` | `pauseTransitionsLegal` | no violation in 10,000 samples |
| `FV-CTL-98` | `upgradesGuardianCancellable` | no violation in 10,000 samples |
| `FV-CTL-98` | `adminOnlyTimelock` | no violation in 10,000 samples |
| `FV-CTL-98` | `normalDelayInBounds` | no violation in 10,000 samples |
| `FV-CTL-98` | `restoringNotGuardianCancellable` | no violation in 10,000 samples |

## 13. AMM-neutral design (run `FV-CTL-R5`, 2026-11-10)

The spec was rewritten for the AMM-neutral design (decisions `Q-279`…`Q-380`): an immutable logic-free PositionProxy per wallet × CDP Spoke × market, one AMM-neutral ledger per chain keyed by `positionKey` with n-token amounts, an exact range match at pledge, a Lock with two members, standard Aave V4 Spokes guarded by drift settings, caps keyed by Hub, and an `IFlashSource` in place of the GHO flash minter. Every check keeps its ID; a check whose rule changed is restated below and its result detail says "Changed for the AMM-neutral design". Findings `FV-CTL-F-01`…`F-24` and their history stay as written above.

### 13.1 Checks changed for the AMM-neutral design

| Check | Before | Now |
|---|---|---|
| `FV-CTL-04` | Hand-written caller matrix with the proxy's named functions, `setProxyImplementation`, `returnStrayNft`, `receiveNft`/`returnNft`/`removeLiquidity` and a four-member Lock | Proxy `execute`; `deployProxy` with the CREATE2 key each page states; no implementation setter; `returnStray`; the LPVault custody names read from 1.4 and 2.2; Lock members read from 1.4, 2.6 and 2.16. Reports every disagreement at once (open finding `F-28`) |
| `FV-CTL-08`, `08-W`, `09` | `supplyCollateral`, `borrow`, `repay`, `withdrawCollateral` Adapter-only; inventory without `execute` | `execute(target, data)` Adapter-only, never to itself, zero or a codeless target; inventory `execute` plus `ADAPTER`, `WALLET`, `SPOKE`, `MARKET_ID`; the Adapter's call builder never sends a liquidation, position-manager or risk-premium selector |
| `FV-CTL-10` | Containment edges through `receiveNft`, `returnNft`, `returnStrayNft`, `buyExactOut` | Edges through `receivePosition`, `returnPosition`, `unwind`, `releaseToDepositor`, `collectFees`, `returnStray`, `FS.flashLoan`; the `IFlashSource` added to the hostile components |
| `FV-CTL-57` | `buySlippageAllowanceBps` above its floor | The market's `slippageAllowanceBps` above `slippageAllowanceMinBps(m)`, which covers the worst swap-route cost into every enabled debt asset (no buy leg, `REQ-PSTORE-006`) |
| `FV-CTL-58` | Six pages compared on the old parameter names | Names as the pages spell them after the renames (`consistencyToleranceBps`, `floorRoundingAllowance`, `routeDepthThreshold`, `minDebtUsd`, `maxFlashFeeBps`); MKT-027 parsed from its text; cross-Hub caps compared on 1.4, 1.5 and 2.15; SettlementBudget windows moved to `FV-CTL-153` (open finding `F-25`) |
| `FV-CTL-62` | Old MarketRegistry short selectors | `activateCdpSpoke`, `activateDebtReserve`, `freezeAll`, `pauseAll`, `tightenCrossHubCap`, `disableCrossHubLines` classified |
| `FV-CTL-78` | Lens `maxGhoSpend` equals the GHO buy bound | Lens `premiumWithinMax` against LPVaultSwap's flash-premium check (open finding `F-27`) |
| `FV-CTL-86`, `88` | Initializer and layout rules for UUPS and the beacon proxy | UUPS contracts only; the proxy has neither |
| `FV-CTL-87` | Beacon implementations: no reinitializer | Immutable proxy: no initializer, upgrade, role, receiver or fallback selector; page inventory read from 2.5 |
| `FV-CTL-89` | CREATE2 per (wallet, spoke) | CREATE2 per (wallet, spoke, marketId) with the Adapter in the init code; no other deployer or Adapter reaches a triple's address |
| `FV-CTL-90`, `149` | Views stay equal across a ProxyManager upgrade | ProxyManager immutable; views keyed by (wallet, marketId) |
| `FV-CTL-93` | Protected set with GHO and the GHO flash minter | Listed debt assets, the `IFlashSource`, every integration's LPVault, position manager and factory, each read from `REQ-MREG-020` |
| `FV-CTL-130`, `131`, `139` | Two-leg inequality with a buy allowance; GHO buy example | `minLB × (10⁴ − slippageAllowanceMinBps) ≥ 10⁴ × (10⁴ + maxFlashFeeBps)` per (market, debt reserve) under every setter, activation and `enableDebtReserve`; the page's example (101,694,000; 169 passes, 170 reverts); the `REQ-PSTORE-024` flash-fee ceiling example |
| `FV-CTL-132` | Breaker table keys | Scoped key `breakerDeficitMax(hub, asset)` read as `breakerDeficitMax` |
| `FV-CTL-55` | 2.10 table "State" | 2.10 table "State or condition", with `Live, borrowAllowed`, `Live, a second source disagrees or is unavailable` and the sequencer rows as modifiers |
| `FV-CTL-23`, `25`, `26`, `62` | "beacon" and "NFTs" wording | Implementation setter; positions |

### 13.2 New checks

| Check | Property | Status | Method | Spec IDs |
|---|---|---|---|---|
| `FV-CTL-153` | Every tighten selector 2.9 or 2.13 marks short is in `SHORT_ELIGIBLE`, and `SHORT_ELIGIBLE` names no ParameterStore selector 2.9 lacks | Violated (open finding `F-26`) | direct computation on the pages | `REQ-ACCESS-141`, `REQ-ACCESS-155`, `REQ-CONFIG-049`, `REQ-PSTORE-024` |
| `FV-CTL-154` | Every Collateralization and LPVault effect that moves value is reachable only from a call tree of AaveAdapter or LPVaultSwap; the timelock reaches only `returnStray` with the Lock free | Verified | exhaustive enumeration | `REQ-LOCK-004`, `REQ-LOCK-010`, `REQ-LOCK-028`, `REQ-COLL-029`, `REQ-ADAPTER-050` |
| `FV-CTL-155` | With `receiveSharesEnabled = false`, `liquidationFee = 0` and no reinvestment controller, only LPVaultSwap seizes through the standard 5-argument `liquidationCall` | Verified | exhaustive enumeration | `REQ-VTOKEN-006`, `REQ-VTOKEN-008`, `REQ-VTOKEN-026`, `REQ-ADAPTER-029`, `REQ-ADAPTER-030`, `REQ-ADAPTER-033`, `REQ-VTOKEN-025`, `REQ-PROXY-008` |
| `FV-CTL-155-W` | Mutation witness: with receive-shares on, any liquidator seizes with no token transfer | Verified (witness) | Z3 witness | `REQ-ADAPTER-029`, `REQ-RISK-078` |
| `FV-CTL-156` | Any drift of the seven standard-Spoke conditions trips `CONFIG_DRIFT`, which stops new risk only; `REQ-RISK-078` names every setting and effect | Verified | exhaustive enumeration | `REQ-RISK-078`, `REQ-RISK-086`, `REQ-ADAPTER-036`, `REQ-ADAPTER-020`, `REQ-HUB-110` |
| `FV-CTL-157`, `157-W` | Flash pre-loan bound, lender not the home or funding Hub, callback from the Pool for the source's own initiation and the active context, premium within the ceiling; witness on the `SPEC-LIQ-015` example | Verified | Z3 | `REQ-FLASH-001`…`005`, `REQ-FLASH-009`, `REQ-SWAP-012`, `REQ-SWAP-013`, `SPEC-LIQ-015` |
| `FV-CTL-158` | Only the timelock replaces the flash source, with the LPVaultSwap binding; a short, repriced, paused or replaced source falls back to caller funds | Verified | exhaustive enumeration | `REQ-FLASH-006`, `REQ-SWAP-014`, `REQ-FLASH-008`, `REQ-FLASH-010` |
| `FV-CTL-159`, `159-W` | Hub-keyed counters bound the Hub's cap across any number of Spokes and markets; per-Spoke counters would admit it once per Spoke | Verified | Z3 | `REQ-COLL-026`, `REQ-VAULT-034`, `REQ-RISK-079`, `REQ-COLL-030` |
| `FV-CTL-160` | Draw caps on (funding Hub, asset) stay within the credit line, the cross-Hub part within `crossHubCap ≤` coverage; a cross-Hub borrow needs lines enabled and the funding Hub unpaused | Verified | Z3 (inductive step) | `SPEC-HUB-003`, `SPEC-CAP-010`, `REQ-FLR-043`, `REQ-RISK-082`, `REQ-HUB-103`, `REQ-CONFIG-081`, `REQ-HUB-020` |
| `FV-CTL-161` | Market windows partition the asset window, so one market cannot starve another | Verified | Z3 | `SPEC-SET-006`, `SPEC-SET-005`, `REQ-BUDGET-020`, `REQ-BUDGET-021`, `REQ-BUDGET-024` |
| `FV-CTL-162` | Every page states the same vault-token paths (no Hub → Adapter) | Violated (open finding `F-29`) | direct computation on the pages | `REQ-VTOKEN-006`, `REQ-ADAPTER-036`, `REQ-VTOKEN-041` |

The harness gained `open_finding(check, finding)` (`common.py`): a violation registered there prints as `[OPN]` with its counterexample, its status reads "Violated (open finding …)", and it does not fail `run.sh`, which lists the open findings at the end. A registered check that passes is reported Verified, and its registration is then removed.

### 13.3 Open findings

#### FV-CTL-F-25 — Delay-class pages disagree after the AMM-neutral renames (Informational)

- **Status.** Resolved in `FV-CTL-R6` (2026-11-10): `FV-CTL-58` is Verified against the changed pages.

- **Check.** `FV-CTL-58`.
- **Counterexample.** 3.8 `MKT-027` still lists `twapToleranceTicks` and omits `consistencyToleranceBps`; 2.15's launch list names `tightenFloorRoundingAllowanceGho` where 2.9, 1.4, 1.5 and 3.8 name `floorRoundingAllowance`, and omits `maxFlashFeeBps`; 1.5 and 1.4 mark `idleUsdCap`, `idleBookingSeconds` and `coverageRatioBps` as short-delay tightenings, but no page defines a tighten selector for them and `SHORT_ELIGIBLE` holds none.
- **Impact.** A tightening the parameters page calls short executes at the normal delay; reviewers reading 3.8 see a parameter that no longer exists.
- **Spec change.** `MKT-027`: replace `twapToleranceTicks` with `consistencyToleranceBps`. 2.15 launch list and `REQ-ACCESS-155`: replace `tightenFloorRoundingAllowanceGho` with `tightenFloorRoundingAllowance` and add `tightenMaxFlashFeeBps`. For `idleUsdCap`, `idleBookingSeconds` and `coverageRatioBps`: either add `tightenIdleUsdCap`, `tightenIdleBookingSeconds` (2.9) and the owner's `tightenCoverageRatioBps` to their setter tables and to `SHORT_ELIGIBLE`, or mark the three Normal in both directions on 1.5 and 1.4.

#### FV-CTL-F-26 — Short tighten selectors missing from `SHORT_ELIGIBLE` (Low)

- **Check.** `FV-CTL-153`.
- **Counterexample.** Short on the owning page, absent from `SHORT_ELIGIBLE`: `ParameterStore.tightenFloorRoundingAllowance` and `tightenMaxFlashFeeBps` (2.9), `SettlementBudget.tightenAssetWindow` and `tightenMarketWindow` (2.13). In `SHORT_ELIGIBLE` but not defined on 2.9: `ParameterStore.tightenFloorRoundingAllowanceGho`.
- **Impact.** `SHORT_ELIGIBLE` is immutable; built from 2.15 as written, the governance Safe can never lower the flash-fee ceiling, a rounding allowance or a SettlementBudget window at the short delay, so a flash-provider premium raise or a dust-wave drain waits the normal delay (up to 5 days) for its response.
- **Spec change.** 2.15 "Delay classes and timing" launch list: ParameterStore row replace `tightenFloorRoundingAllowanceGho` with `tightenFloorRoundingAllowance` and add `tightenMaxFlashFeeBps`; SettlementBudget row `tightenCaps`, `tightenAssetWindow`, `tightenMarketWindow`. `REQ-ACCESS-155` follows the list.

#### FV-CTL-F-27 — Premium bound rounded up in the Lens and the ceiling text, exact in LPVaultSwap (Low)

- **Status.** Resolved in `FV-CTL-R6` (2026-11-10): `FV-CTL-78` is Verified against the changed pages.

- **Check.** `FV-CTL-78`.
- **Counterexample.** Z3: `F = D = 99`, `maxFlashFeeBps = 100`, Pool premium 51 bps, so the Pool's half-up `percentMul` charges `φ = 1`. The Lens (`REQ-LENS-029`) reports `premiumWithinMax` because `1 ≤ ⌈99 × 100 / 10⁴⌉ = 1`; LPVaultSwap (`REQ-FLASH-002`, `REQ-SWAP-013`, `SPEC-LIQ-015`) reverts `FlashFeeTooHigh` because `1 × 10⁴ = 10,000 > 100 × 99 = 9,900`. At launch values the same split occurs whenever the Pool premium equals the ceiling and `F × 10 / 10⁴` has a fractional part of at least one half: `F = 1,950,000,500` (USDC base units) at 10 bps gives `φ = 1,950,001`; the Lens and `REQ-PSTORE-024`'s ceiling `⌈F × 10 / 10⁴⌉ = 1,950,001` admit it, LPVaultSwap's `19,500,010,000 > 19,500,005,000` refuses it.
- **Impact.** A keeper following the preview submits a flash-funded liquidation that reverts; the caller-funded path still works, so liquidation is not blocked.
- **Spec change.** Use one bound everywhere, the exact one: `REQ-LENS-029` `premiumWithinMax` true when `flashPremium × 10⁴ ≤ maxFlashFeeBps × F` with `F` the flash amount in `params` (not `D`); `REQ-PSTORE-024` "refuses a loan whose premium `φ` has `φ × 10⁴ > maxFlashFeeBps × amount`", and its example `10e6 × 10⁴ ≤ 10 × 20,000e6`.

#### FV-CTL-F-28 — 1.4 still states the old proxy key, the four-member Lock and old LPVault names (Informational)

- **Check.** `FV-CTL-04`.
- **Counterexample.** `REQ-ROLE-020`: `deployProxy(wallet, spoke)`, salt `keccak256(abi.encode(wallet, spoke))`; 2.5 `REQ-PROXY-051` and 2.15 `REQ-ACCESS-147`: `(wallet, spoke, marketId)`. `REQ-ROLE-021`: "The four members: AaveAdapter, Collateralization, LPVault, LPVaultSwap"; 2.6 `REQ-ADAPTER-050` and 2.16 `REQ-LOCK-004`: two members. `REQ-ROLE-038`: `releaseLiquidity`; 2.2: `releaseToDepositor`, plus `topUpPosition` and `collectFees`, which 1.4 omits.
- **Spec change.** `REQ-ROLE-020`: `deployProxy(wallet, spoke, marketId)`, salt `keccak256(abi.encode(wallet, spoke, marketId))`, `ProxyExists` for a deployed triple. `REQ-ROLE-021`: "The two members: AaveAdapter and LPVaultSwap". `REQ-ROLE-038`: `receivePosition(marketId, owner, positionKey)`, `topUpPosition`, `returnPosition(positionKey)`, `unwind(positionKey, units, minAmounts, recipient)`, `releaseToDepositor`, `collectFees(positionKey, depositor)`, as 2.2 names them.

#### FV-CTL-F-29 — `REQ-ADAPTER-036` states a Hub → Adapter path (Informational)

- **Check.** `FV-CTL-162`.
- **Counterexample.** `REQ-ADAPTER-036` (2.7): "only Hub supply, Hub to Adapter, and Hub to LPVaultSwap on seizure". `REQ-VTOKEN-006` and `REQ-VTOKEN-041`: there is no Hub → Adapter transfer; a withdrawal goes Hub → proxy and the Adapter burns from the proxy (coordinator ruling on the withdrawal path).
- **Related.** `FV-CTL-155` first ran without the proxy rule and found that a registered proxy as liquidator passes the token check (Hub → proxy is the withdrawal path, and the token cannot tell it from a seizure). Exclusivity for that case comes from `REQ-PROXY-008` (the Adapter never makes a proxy call `liquidationCall`); the pages that say "any other liquidator reverts on the token transfer" (`REQ-VTOKEN-006`, `REQ-ADAPTER-036`) should name that rule.
- **Spec change.** `REQ-ADAPTER-036`: "only proxy → Hub supply, Hub → proxy withdrawal and Hub → LPVaultSwap seizure ([2.4](04-vault-tokens.md) `REQ-VTOKEN-006`)", and add "a registered proxy never calls `liquidationCall`, because the Adapter's call builder has no such selector (`REQ-PROXY-008`)". Same sentence in `REQ-VTOKEN-006` after "any liquidator other than LPVaultSwap reverts on the token transfer".

### 13.4 Result

Run `FV-CTL-R5` ([RUNS.md](RUNS.md)): 174 Z3 and enumeration checks (163 Verified, 6 Verified under bounded model, 5 Violated as open findings `FV-CTL-F-25`…`F-29`) and 6 Quint invariants with no violation in 10,000 samples; `check_ids.py` 0 undefined. `run.sh` exits 0. The open findings are spec-text disagreements and one rounding mismatch; none weakens solvency, exits or liquidation.
