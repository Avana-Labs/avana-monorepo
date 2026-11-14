# Quint model of Avana v1 (QNT)

`avana.qnt` is a state machine of the whole Avana v1 system across contracts, written against the final design (decisions `Q-001` … `Q-278` in `spec/04-security/04-design-decisions.md`). `avana_tests.qnt` replays named scenarios. `run.sh` runs the random simulator once per property.

| File | What it holds |
|---|---|
| `avana.qnt` | State, actions, five step relations, 58 invariants `QNT-01` … `QNT-58`, three combined invariants, design variants and seeded initial states |
| `avana_tests.qnt` | 50 deterministic scenarios `QNT-T01` … `QNT-T44` |
| `run.sh` | One `quint run --invariant=…` per property, 8 combined runs and 30 reachability (witness) runs, in parallel |

## Run

```bash
npx quint typecheck avana.qnt && npx quint test avana_tests.qnt   # seconds
./run.sh                   # quick mode: 500 traces × 20 steps per check
QUINT_FULL=1 ./run.sh      # full mode: 10,000 traces × 20 steps per check
QNT_ONLY='QNT-48|W-' ./run.sh                                      # a subset
```

`../run_all.sh` runs `typecheck` and `test` on both `.qnt` files and then `run.sh` in quick mode. A `hold` line fails if a violation is found. A `witness` line checks that the random traces reach a state (a seizure, a deficit, a rescue top-up, an executed timelock operation and so on). In quick mode a missed witness is a warning; in full mode it is a failure. Logs with full traces go to a temp folder printed at the start. In CI, the `spec` workflow runs `../run_all.sh` (quick mode), and the `models` workflow (`.github/workflows/models.yml`) runs `topology_run.sh`, the checks `../run_all.sh --nightly` adds, on every push to `main`.

## What is modelled

| Part | State | Actions |
|---|---|---|
| Uniswap v3 NFPM | per NFT: owner, liquidity, uncollected fees, pool | pool fees accrue; anyone can `increaseLiquidity`; stray transfer to the LPVault |
| LPVault and Collateralization (immutable, `Q-240`) | records (tokenId, depositor, proxy, market, credited units, rescue units, open); pending-settlement balance per market | custody and crediting; largest-first debit with lowest-ID tie-break (`Q-194`); principal-capped collect (`Q-061`); reconcile on exit and on settlement (`Q-201`); share-drop and supply-drop check on every seizure debit (`Q-160`, `Q-224`); `settlePending` bound `totalSupply + x ≤ credited + pending` (`Q-257`); NFTs leave only to their depositor of record; stray NFTs never pledgeable (`Q-258`); stray return through the timelock |
| ProxyManager and PositionProxies (`Q-225`) | Avana deploys one immutable, logic-free PositionProxy per wallet × CDP Spoke × market by CREATE2, with no implementation, upgrade or migration; it executes only calls from the AaveAdapter. The model keys a proxy by (wallet, Spoke), so a wallet's markets on one Spoke share one modelled proxy; the traces include every state in which each proxy holds one market. A proxy is created on the first pledge and bound once; the proxy registry inside each vault token | creation refused for a frozen wallet (`Q-242`); `addValidProxy` at the first pledge into a market |
| Vault tokens (immutable, `Q-224`) | balance per (market, holder) | the Adapter is the only minter and burner; recipient-only rule: Hub, Adapter, LPVaultSwap or a registered proxy |
| AaveAdapter (upgradeable; reviewed or hostile) | borrow nonce per proxy | `pledge`, `borrow`, `repay` (any payer, any debt reserve), `withdraw`, `removeLiquidity`, `recredit`, `repayWithCollateral`; the proxy is resolved from `msg.sender`; pause state, pause reason and address freeze applied by the Adapter; the one-sided backing check on every call (`Q-257`); exits read no pause state, breaker, freeze or registry state (`Q-260`). Hostile: borrows against any proxy, withdraws any proxy's supply to that proxy, mints to registered proxies, burns from registered proxies and LPVaultSwap (never the Hub), registers any address but a binding, releases any record |
| RiskModule (upgradeable; reviewed or hostile) | — | `checkPledge` with the rescue rule (`Q-252`) and `minPledgeUsd`; `preBorrowCheck`, `preWithdrawCheck` over every collateral market and debt reserve of the account (price states, debt prices, Aave pauses and freezes, offboarding, drift, Hub shares = assets, liquidation halts, breakers); `postHealthCheck` on the rescue-excluded HF against Aave's 1.00, with the optional per-market hard floor off (`Q-229`, `Q-253`, `Q-398`); the remaining-record minimum of a partial removal. Hostile: approves everything |
| MarketRegistry (`Q-227`, `Q-241`, `Q-242`) | pause state `None` / `Frozen` / `Paused` with reason `General` or `MintPathSuspect`; offboarding; manual breakers per market and per (Borrow Spoke, debt reserve); frozen addresses with a per-guardian window count | freeze, pause, reason change, unpause and unfreeze by role; breaker trips and resets; latched seizure-surge and route-failure counters written by LPVaultSwap; address freeze within the protected set and the keeper floor |
| Circuit-breaker conditions (`Q-399`) | issuer probes of pool tokens and debt assets, pool share (10%, merged with `poolShareMaxBps`), First-Loss Reserve below minimum, deficit above `breakerDeficitMax` (10,000 GHO); price drop, seizure surge and route failures are monitoring alerts only | evaluated from live state at each check; they clear with the condition |
| Borrow Spokes S1 (markets mA, mB; debt GHO and USDT) and S2 (mC; debt GHO), liquidation-manager variant (`Q-222`, `Q-237`) | supplied units per (proxy, market), collateral enabled, debt per (proxy, asset), Aave pause and freeze flags per vault and debt reserve | `liquidationCall` only from LPVaultSwap; canonical sizing with the dust rule, the collateral cap, `MustNotLeaveDust` and deficit reporting on every debt reserve |
| Hubs (one pool per debt asset, `Q-233`) | liquidity, drawn per (Spoke, asset), draw caps, deficit, accrued interest, halts, shares ≠ assets per vault-token asset | interest, halt, draw-cap changes, share drift |
| LPOracle per market | price, stored state, Cached-since, disagreement start and first stored observation, lower-route price, `recoveredAt`, feed failure, standby route and its freshness, hourly checkpoint | price move, TWAP drift, route disagreement, both routes failing, recovery with the timestamp latch (`Q-154`), standby switch by a pause guardian and its immediate reversal by the Aave executor (`Q-248`), `poke()` |
| DebtOracle (USDT) | accepted price, state, disagreement with the higher route, standby | price move (a debt rally), disagreement, failure, recovery, standby switch and reversal |
| Aave valuation (`Q-247`) | — | an Expired market served at the minimum price (worth nothing), a disagreeing market at its lower-route price, a Cached market at its last price; an Expired debt asset at its stress price, a disagreeing one at its higher route |
| LPVaultSwap (upgradeable; reviewed or hostile) | keeper list (committed operators) | one entry point `liquidate` for any caller that is not frozen (`Q-404`); gates only on the seized market's and the repaid reserve's own prices and grace per account, never the pause state, a breaker or the borrower's freeze; two sell legs with oracle-derived minimums (`Q-250`); aggregate recovery floor with the caller's shortfall top-up (`Q-251`); non-GHO buy leg within its oracle bound and a sell-back of unspent debt asset above its floor (`Q-235`, `Q-256`); Avana fee from oracle value capped by the surplus (`Q-256`); budget draws within per-call, per-key, per-market and total window caps on the keeper path (`Q-267`); deadline and minimum payout (`Q-216`); in-kind settlement with the keeper's GHO, remainder to the wallet or the PayoutEscrow (`Q-214`); `reportRecoveryShortfall` and automatic in-kind (`Q-251`); `settlePending`. Hostile: seizes and keeps, burns without settling (orphan burn), settles another proxy or without a burn, tries to transfer kept tokens (the token refuses every transfer from LPVaultSwap), settles pending without a burn, draws the budget, writes breaker counters |
| Payout escrow (PayoutEscrow, `Q-401`) | held, credited and claimed per holder; holders whose payout the token refuses | a refused liquidation payout is credited; the holder claims it to any recipient. There is no SettlementBudget (`Q-397`) |
| First-Loss Reserves (`Q-236`) | funded balance and covered total per asset | fund; `coverDeficit` in the deficit's own asset |
| Conversion and buy routes | per market: run-time failure, disabled records, primary failure; USDT buy routes: run-time failure, disabled records | fail, restore, disable and restore records through the timelock |
| AvanaTimelock (`Q-228`, `Q-245`, `Q-259`, `Q-262`, `Q-263`) | operations (calls, target, proposer, scheduled and ready times, status, canceller), normal delay, enabled short-delay selectors, admins, multisig quorum | schedule by the governance multisig or the Aave executor; public execution within the grace window; cancel by role; 33 operation templates: reviewed upgrades, parameter loosening and tightening, route records, in-kind enablement and trigger, keepers, address freeze and unfreeze, pause state, role grants, normal delay, short-delay selectors, mixed operations, standby switch and restore, breaker trip and reset, offboarding |
| Third parties | attacker EOA `eve`, attacker contract `X_rogue`, keepers and wallets calling the Spoke directly, other payers | direct `liquidationCall`, pledging others' NFTs or into wrong markets, borrowing through others' accounts, repaying others' debt, liquidation by a caller outside the committed-operator registry, nonce replay, donations, stray NFTs, claiming others' escrow |

Step relations: `step` (reviewed components, every attacker, guardians, the timelock, Aave governance and the environment), `stepHostilePolicy` (hostile RiskModule), `stepHostileSwap` (hostile LPVaultSwap), `stepAll` (both), `stepHostileAdapter` (hostile AaveAdapter). Initial states: `init` (nothing pledged), `initHostileSwap`, and seeded states built with the normal pledge and borrow transitions: `initStressed` (alice: NFTs 42 and 7 in mA, 2,500 GHO of debt; bob: NFT 8 in mA, 600 GHO and 400 USDT of debt), `initStressedHostileSwap`, `initStressedHostileAdapter`, `initRouteOutage` (`initStressed` with mA's routes failing and eve's payouts refused, so they go to the payout escrow; there is no in-kind settlement, `Q-401`) and `initCrash` (`initStressed` with mA at price 1). Each step picks an action group weighted by what can act in the current state: liquidation while an account is liquidatable, withdrawals while an unsettled seizure exists, timelock execution while an operation is ready and floor-failure reports while a trigger is approved.

## Bounds and assumptions

- **Sizes:** 3 wallets (`alice`, `bob`, attacker `eve`), 8 NFTs, 3 markets on 2 Borrow Spokes, 2 debt assets (GHO on both Spokes, USDT on S1), 6 proxies (one per wallet and Spoke), 4 keepers (3 approved at start), 3 guardian keys (the Emergency Guardian and the Aave Protocol Guardian with both roles, and one key with only the freeze role), 2 proposers.
- **Numbers (scaled):** price 1, 2 or 3 GHO per unit (start 2); USDT 1.00 or 1.20 GHO; CF 80 %; flat bonus 5 %; optional hard floor off by default (when on: 1.05 to 1.25, loosened by at most 0.03 per normal delay); HF gate 1.00 (`Q-398`); rescue target 1.10; grace HF 0.90; dust $1,000; sell slippage allowance 3 % (2 % effective with the USDT buy leg); buy allowance 2 %; floor rounding allowance 2 GHO (1 per leg); maximum shortfall allowance 10 %; Avana share 20 %; `minPledgeUsd` 300 GHO; rescue minimum 10 GHO; debt stress rise 25 %; Cached window 2 ticks; disagreement pause 2; grace 3; breaker cooldown 6, counting window 2, seizure surge 20 %, 3 route failures, price drop 3 %; 2 address freezes per guardian per 24-tick window; short delay 1, normal delay 5 (bounds 4 to 5), grace window 14; in-kind expiry 6, automatic delay 2, largest report gap 1; budget 30 GHO, per-call cap 5, per-key window cap 10, market sub-cap 5, total window cap 15; credit lines 5,000 GHO and 2,000 USDT; draw caps 4,000 (S1 GHO), 2,000 (S1 USDT), 1,000 (S2 GHO); First-Loss Reserves 500 each, minimum 300; deficit breaker 1,000; Hub `addCap` 5,000 units per market.
- **Units:** debt in asset units; settlement, cash, fees and escrow in GHO cents, so the per-leg minimums and the rounding allowance act at a finer grain than one GHO.
- **Simulation:** `quint run` random traces. Random simulation is not proof. The model uses only finite sets and integers.
- **Abstractions:**
  - One vault unit is one unit of liquidity, and its GHO value is the LPOracle price. Decimals, Uniswap amounts and exact rounding are covered by the Z3 models.
  - Hub shares = assets except for a market flagged otherwise, so the share-drop check is a unit check.
  - Aave's liquidation uses a flat bonus and no target-HF limit.
  - The two sell legs carry half the seized value each; realised slippage per leg is 0, 2 or 10 %. The flash fee is 0.
  - In-kind: the unwound tokens' oracle value is the LP's fair value plus a deviation of 0 or 5 %.
  - Interest is a +50 step. The freeze limit's 24 one-hour buckets are modelled as one fixed 24-hour window; one tick stands for one hour and `wait` advances one normal delay.
  - Upgrades through the timelock land reviewed implementations; the hostile step relations model an implementation that has already landed (their delay is checked by QNT-52).
- **Not modelled:** route selection inside a market (a market's sell routes are up, primary-down or down as a whole), the top-up slice and the cap counters (`Q-157`, `Q-158`; rescue units come from whole-pledge exemptions only), USD caps and the USD band, keeper reimbursement, risk premium, the recovery-evidence lookup across Chainlink phases (`Q-272`), feed ages within a state, `maxGhoSpend` on the GHO path.

### Readings applied

1. **Expired** is computed from timestamps (Cached for longer than the window), not stored.
2. **Grace** applies per account: if any collateral market of the account is inside its window, the deeper HF bound applies to the whole account. Grace follows only from an Expired outage seen in the source timestamps (`Q-154`).
3. **Disagreement**: seizure of the market waits from the first stored observation for `disagreementPauseMax`, then counts as Expired for its own seizure until the routes agree or a standby switch ends it. Borrowing is blocked throughout.
4. **Seized and repaid reserves only** (`Q-247`): liquidation needs fresh prices for the seized market and the repaid debt reserve alone; the account's other reserves count at Aave's conservative values.
5. **New account** (`Q-132`): an account with no debt on any debt reserve. A new-account pledge needs Live; a top-up needs Live or Drifting.
6. **Pledge gates** (`Q-227`, `Q-252`, `REQ-RISK-066`): Frozen refuses pledges by accounts with no debt; `Paused(General)` and a frozen caller require a rescue top-up; `Paused(MintPathSuspect)` refuses every pledge and re-credit; a tripped market breaker or a value below `minPledgeUsd` also needs the rescue rule.
7. **Liquidation halt for new borrowing** (`REQ-ADAPTER-010`, `REQ-RISK-062`, `EMG-047`): no active keeper, both sell-route records disabled, Hub shares ≠ assets, an Aave pause or a stale price of a reserve the account holds, or (USDT) both buy-route records disabled. A route failing only at run time does not halt.
8. **Debit check** (`Q-160`): Collateralization compares its own snapshot of the proxy's supply with the supply after the seizure and requires the token supply to have fallen by the same units. The alternative "Σ credited − units = supply" is kept as a design variant (`initLedger`).
9. **Reconciliation** (`Q-201`) runs inside every withdrawal, partial removal, re-credit, repay with collateral, zero-credit release and settlement of the affected proxy and market, before that call's own debit; the reconciled principal goes to the pending-settlement balance.
10. **Backing check** (`Q-257`): every reviewed Adapter call keeps the market's backing gap; the one-sided form passes while the gap is ≥ 0, the equality form of `Q-224` as first written only while it is 0 (design variant `initEquality`).
11. **Deadline and minimum payout** (`Q-216`) are checked inside the same guard as every other liquidation check; the settlement function takes neither.
12. **Expired valuation**: Aave's minimum price (one unit of 10⁻⁸ USD per vault token) is modelled as 0; a liquidation sized at it seizes the whole supply of that market for one unit of debt.

## Properties

"Steps" is the step relation each run uses. "Holds (quick mode)" means no violation in the 2026-11-10 quick run (500 traces × 20 steps per property); the 10,000 × 20 full run (`QUINT_FULL=1 ./run.sh`) runs by hand; no CI workflow runs it.

QNT-13, QNT-32, QNT-33 and QNT-34 keep their IDs with a replacement statement, because the Guardian incident clock, the bounded liquidation halt and keeper quarantine no longer exist (`Q-227`): QNT-32 is now "no Avana restriction changes whether a liquidation succeeds", QNT-33 "no Avana restriction reaches an exit", QNT-34 the keeper floor counting unfrozen keepers, and QNT-13 the blast radius of hostile components.

| ID | Statement | Formal statement (`avana.qnt`) | Backs | Steps | Result |
|---|---|---|---|---|---|
| QNT-01 | One NFT backs at most one open record | `qnt01_oneRecordPerNft` | Q-067, Q-193, Q-194, Q-224, Q-240, INV-005 | stepAll | Holds (quick mode) |
| QNT-02 | An open record's NFT is in LPVault custody, in the record's market, and its depositor is the wallet bound to the record's proxy for that Spoke | `qnt02_recordCustody` | Q-067, Q-107, Q-223, Q-225, Q-240, INV-005 | stepAll | Holds (quick mode) |
| QNT-03 | Vault-token supply + units burned without settlement = Σ credited + pending, so supply ≤ backing for any LPVaultSwap, with equality while every burn is settled | `qnt03_supplyEqualsBacking` | Q-066, Q-201, Q-224, Q-257, INV-001, INV-080 | stepAll | Holds (quick mode) |
| QNT-04 | Vault tokens are held only by the Hub, LPVaultSwap or a registered proxy, never the Adapter; transfers follow the (from, to) path rule, so LPVaultSwap's units leave it only by a burn | `qnt04_allowedHolders` | Q-224, Q-300, INV-011 | stepAll | Holds (quick mode) |
| QNT-05 | Each record's live liquidity ≥ its credited units | `qnt05_liquidityCoversCredit` | Q-066, Q-067, Q-254 | stepAll | Holds (quick mode) |
| QNT-06 | Hub vault-token balance = Σ Spoke supplied units (+ tokens sent to the Hub outside supply) | `qnt06_hubBalanceEqualsSupplied` | Q-066, Q-116, Q-224 | stepAll | Holds (quick mode) |
| QNT-07 | A proxy's Spoke supply never exceeds its credited units, and every exit or settlement leaves them equal | `qnt07_perProxyLedger` | Q-160, Q-201, Q-224, Q-254, Q-255, INV-008, INV-058 | stepAll | Holds (quick mode) |
| QNT-08 | One proxy per (wallet, Borrow Spoke), bound once; each vault token registers only existing proxies of its own Spoke | `qnt08_proxyBinding` | Q-107, Q-224, Q-225, Q-276 | stepAll | Holds (quick mode) |
| QNT-09 | Only LPVaultSwap moves vault collateral out of a Spoke position or reports a deficit; Spoke supply sits only with registered proxies | `qnt09_onlySwapSeizes` | Q-116, Q-144, Q-222, INV-013, INV-041 | stepAll | Holds (quick mode) |
| QNT-10 | Collateralization debits = Spoke supply decrease = burned units, largest record first | `qnt10_debitMatchesSeizure` | Q-160, Q-194, Q-224, INV-014 | stepAll | Holds (quick mode) |
| QNT-11 | Fees always go to the depositor of record | `qnt11_feesToDepositor` | Q-030, Q-061, Q-105, Q-254, Q-271 | stepAll | Holds (quick mode) |
| QNT-12 | The stray-NFT return never touches an NFT with an open record | `qnt12_rescueOnlyUncredited` | Q-104, Q-134, Q-258 | stepAll | Holds (quick mode) |
| QNT-13 | Hostile components stay inside their blast radius: no borrow beyond drawCap or below Aave HF 1, no NFT to anyone but its depositor of record, only LPVaultSwap seizes, First-Loss Reserves move only by funding and DAO coverage, Hub supply within `addCap` | `qnt13_hostileBounded` | Q-223, Q-226, Q-229, REQ-ADAPTER-040, REQ-RISK-007 | stepHostileAdapter (and inside `hostileInvariants` on stepAll) | Holds (quick mode) |
| QNT-14 | Repay of every debt reserve is open, for the borrower and any other payer, in every pause state, breaker state and freeze, unless Aave blocks it | `qnt14_repayAlwaysOpen` | Q-051, Q-118, Q-180, Q-212, Q-227, Q-242, Q-260, Q-269 | stepAll | Holds (quick mode) |
| QNT-15 | Debt-free withdrawal and partial removal are open unless Aave blocks them, including after an unsettled seizure or an orphan burn | `qnt15_debtFreeWithdrawOpen` | Q-051, Q-118, Q-134, Q-201, Q-227, Q-241, Q-242, Q-254, Q-257, Q-260 | stepAll | Holds (quick mode) |
| QNT-16 | Fee collection is always open to the depositor | `qnt16_feeCollectionOpen` | Q-030, Q-051, Q-140, Q-227 | stepAll | Holds (quick mode) |
| QNT-17 | Any partial repay (1 unit) is accepted unless Aave blocks it | `qnt17_partialRepayOpen` | Q-153, Q-169 | stepAll | Holds (quick mode) |
| QNT-18 | With the reviewed RiskModule, no borrow or debt-keeping exit while a collateral price of the account is Cached or Expired or one of its debt prices is failing | `qnt18_noBorrowOnStale` | Q-081, Q-128, Q-182, Q-229, Q-234, Q-238 | step | Holds (quick mode) |
| QNT-19 | With the reviewed RiskModule, no borrow while one of the account's vault-token reserves is frozen on Aave | `qnt19_noBorrowWhenFrozen` | Q-203, Q-229 | step | Holds (quick mode) |
| QNT-20 | Rescue-excluded HF ≥ max(1.00, optional hard floor) (`Q-398`) after every borrow and debt-keeping exit (reviewed RiskModule); drawCap, Hub liquidity and Aave HF ≥ 1 always | `qnt20_borrowFloorAndCap` | Q-095, Q-161, Q-229, Q-253 | step | Holds (quick mode) |
| QNT-21 | One successful borrow per nonce | `qnt21_nonceUnique` | Q-106, Q-229 | stepAll | Holds (quick mode) |
| QNT-22 | LPVaultSwap never seizes a market whose own price is Cached, Expired or disagreeing, nor repays a debt reserve whose own price is failing | `qnt22_noLiquidationOnStale` | Q-128, Q-162, Q-199, Q-208, Q-247 | stepHostilePolicy | Holds (quick mode; scope: the reviewed LPVaultSwap; `QNT-T24`) |
| QNT-23 | No seizure of an account with HF ≥ 1, by any LPVaultSwap | `qnt23_noHealthySeizure` | Q-116, Q-222 | stepAll | Holds (quick mode) |
| QNT-24 | Within the grace window after a real Expired → Live recovery, only accounts below the grace HF are seized | `qnt24_graceRespected` | Q-088, Q-154, Q-206, Q-264 | stepHostilePolicy | Holds (quick mode) |
| QNT-25 | Pledges follow the matrix: a new account only in `None`, Live, no market breaker, unfrozen caller; a non-rescue top-up in Live or Drifting under `None` or `Frozen`, no breaker, unfrozen caller; otherwise only a rescue top-up; nothing mints under `Paused(MintPathSuspect)` | `qnt25_topUpStates` | Q-132, Q-227, Q-230, Q-241, Q-242, Q-252 | step | Holds (quick mode) |
| QNT-26 | The settlement waterfall balances (R + shortfall + draw = net GHO cost + fee + payout); LPVaultSwap, the LPVault and Collateralization hold no vault tokens between calls | `qnt26_settlementConservation` | Q-097, Q-124, Q-235, Q-251, Q-256 | stepHostilePolicy | Holds (quick mode) |
| QNT-27 | Every settled liquidation meets the recovery floor, counting the caller's shortfall top-up | `qnt27_recoveryFloor` | Q-085, Q-198, Q-251 | stepHostilePolicy | Holds (quick mode) |
| QNT-28 | The SettlementBudget is removed (`Q-397`): every settlement is funded by recovery plus the caller and no Avana balance pays toward it | `qnt28_callerFundsGap` | Q-117, Q-127, Q-167, Q-236, Q-267, Q-397 | stepAll | Holds (quick mode) |
| QNT-29 | A caller settlement gap is charged only on liquidations that seized collateral (`Q-397`) | `qnt29_gapOnlyOnSeizure` | Q-127, Q-167, Q-198, Q-397 | stepAll | Holds (quick mode) |
| QNT-30 | Per debt asset: coverage ≤ funded reserve and ≤ recorded deficit; reserve = funded − covered | `qnt30_deficitCoverage` | Q-101, Q-142, Q-236 | stepAll | Holds (quick mode) |
| QNT-31 | Per debt asset: Σ debt = drawn per Spoke; liquidity + drawn + deficit = line + interest + reserve | `qnt31_hubAccounting` | Q-070, Q-095, Q-101, Q-233 | stepAll | Holds (quick mode) |
| QNT-32 | No Avana restriction (pause state and reason, a breaker, an address freeze of anyone but the caller, offboarding) changes whether a liquidation succeeds, on either entry point or in kind | `qnt32_avanaHaltBounded` | Q-227, Q-241, Q-242, Q-247 | stepHostilePolicy | Holds (quick mode) |
| QNT-33 | Repay, debt-free withdrawal and removal, zero-credit release, fee collection, pending settlement and escrow claims never depend on the pause state, a breaker or the address freeze | `qnt33_avanaRestrictionsExpire` | Q-227, Q-241, Q-242, Q-260 | stepAll | Holds (quick mode) |
| QNT-34 | Approved keepers never fall below `keeperFloor` (1, `Q-400`); a guardian freeze may leave 0 active (unfrozen) keepers, and then new borrowing is halted on every market | `qnt34_keeperFloor` | Q-139, Q-228, Q-242, INV-048 | stepAll | Holds (quick mode) |
| QNT-35 | NFTs are owned only by wallets or the LPVault | `qnt35_nftOwnership` | Q-067, Q-104, Q-105, Q-201, Q-255 | stepAll | Holds (quick mode) |
| QNT-36 | Liquidation liveness: an account with HF < 1 whose seized market and repaid reserve have fresh prices, a working route, no Aave pause and no Hub halt, outside grace or below the grace HF, is liquidated by an approved keeper whatever the pause state, breakers, freezes or the account's other reserves | `qnt36_liquidationLive` | Q-098, Q-128, Q-139, Q-189, Q-198, Q-247, INV-046 | stepHostilePolicy | Holds (quick mode) |
| QNT-37 | The pending-settlement balance is ≥ 0 and backs only vault tokens outside the Hub's supplied balance or units burned without settlement | `qnt37_pendingBacksTokens` | Q-201, Q-257, INV-058 | stepAll | Holds (quick mode) |
| QNT-38 | With the reviewed Adapter and RiskModule, a borrow or debt-keeping exit happens only with every gate passing: pause state, freeze, prices, no liquidation halt for a reserve held, breakers, HF | `qnt38_policyGates` | Q-189, Q-206, Q-227, Q-229, Q-241, Q-242 | step | Holds (quick mode; scope: reviewed RiskModule; a hostile one is bounded by QNT-13, `QNT-T04`) |
| QNT-39 | Any payer may repay; a repay never spends more than the debt it removes | `qnt39_repayNeverOverspends` | Q-153, Q-180, Q-212, Q-269 | stepAll | Holds (quick mode) |
| QNT-40 | Every caller of `liquidate`, a committed operator or not, funds its own gap; no Avana balance pays (`Q-397`, `Q-404`) | `qnt40_callerFundsOwnGap` | Q-008, Q-053, Q-213, Q-397, Q-404 | stepAll | Holds (quick mode) |
| QNT-41 | PayoutEscrow (payout escrow, `Q-401`): balance ≥ everything claimable; per holder credited = claimed + held | `qnt41_escrowSolvent` | Q-133, Q-214, Q-401 | stepAll | Holds (quick mode) |
| QNT-42 | Deadline and minimum payout can only make a liquidation revert | `qnt42_paramsOnlyRevert` (every target, a committed operator and another caller, three deadlines, two minimum payouts) | Q-216 | stepHostilePolicy | Holds (quick mode) |
| QNT-43 | In-kind settlement is removed (`Q-401`); a payout the token refuses is credited in full in the escrow, never lost and never a revert | `qnt43_payoutEscrowed` | Q-133, Q-214, Q-235, Q-401 | stepAll | Holds (quick mode) |
| QNT-44 | Pause state is `None`, `Frozen` or `Paused` with a reason exactly while Paused; only a pause guardian moves it back to `None`; no pledge path mints under `Paused(MintPathSuspect)` | `qnt44_pauseState` | Q-227, Q-252 | stepAll | Holds (quick mode) |
| QNT-45 | Breakers stop new activity only: no non-rescue pledge, borrow or debt-keeping exit through a tripped breaker; price drop, seizure surge and route failures are alerts and never gate a market (`Q-399`) | `qnt45_breakers` | Q-241, REQ-RISK-065 | step | Holds (quick mode) |
| QNT-46 | A frozen address makes none of the calls the freeze blocks; protected addresses are never frozen; each freezer stays within its window limit | `qnt46_addressFreeze` | Q-242 | stepAll | Holds (quick mode) |
| QNT-47 | Rescue top-ups only into an indebted account below the opening HF and within the restore amount; rescue units ≤ credited units | `qnt47_rescue` | Q-252, Q-253 | stepAll | Holds (quick mode) |
| QNT-48 | Every Adapter call leaves the market's backing gap unchanged and never negative | `qnt48_backingGap` | Q-224, Q-257, INV-080 | stepAll | Holds (quick mode) |
| QNT-49 | Partial removal leaves an open record with credited > 0, live ≥ credited, fees in custody and, with debt, a record worth `minPledgeUsd`; re-credit leaves credited = live liquidity | `qnt49_removalRecredit` | Q-254 | stepAll | Holds (quick mode) |
| QNT-50 | Repay with collateral never lowers Aave's HF while debt remains, pays no Avana fee and covers its flash loan | `qnt50_repayWithCollateral` | Q-255 | stepAll | Holds (quick mode) |
| QNT-51 | A liquidation changes only the liquidated account | `qnt51_accountIsolation` | Q-225, Q-234, Q-276, Q-278 | stepAll | Holds (quick mode) |
| QNT-52 | Timelock: no call outside the short-delay allowlist executes earlier than `MIN_NORMAL_DELAY` after scheduling, none after its grace window; the normal delay stays in its bounds; the enabled short list stays inside the allowlist; admin power stays with the timelock | `qnt52_timelockDelays` | Q-228, Q-259, Q-262 | stepAll | Holds (quick mode) |
| QNT-53 | Restoring and role-change operations are cancelled only by the DAO canceller; every operation comes from a proposer | `qnt53_restrictedCancel` | Q-228, Q-245, Q-263 | stepAll | Holds (quick mode) |
| QNT-54 | A market is Live or Drifting only while a serving route is fresh; the standby switch never bypasses freshness; the USDT price is Live only with a fresh route | `qnt54_standby` | Q-248, Q-274 | stepAll | Holds (quick mode) |
| QNT-55 | Aave never values collateral above its last accepted price nor a debt asset below it | `qnt55_conservativeValuation` | Q-238, Q-247, Q-278 | stepAll | Holds (quick mode) |
| QNT-56 | Automatic in-kind is removed (`Q-401`): a floor-failure report is a monitoring alert and never changes a market breaker or a liquidation halt (`Q-399`) | `qnt56_reportsAlertOnly` | Q-251 | stepAll | Holds (quick mode) |
| QNT-57 | Fee = min(oracle-value share, surplus); every sell leg meets its oracle minimum and, with no shortfall allowance, the legs alone meet the aggregate floor; the sell-back meets its floor; the buy leg stays within its oracle bound; the shortfall stays within the caller's cap and the budget never pays it | `qnt57_waterfall` | Q-235, Q-250, Q-251, Q-256 | stepHostilePolicy | Holds (quick mode) |
| QNT-58 | The budget sub-caps are removed (`Q-397`): the caller top-up is exactly the floor shortfall plus the settlement gap `max(0, net cost − recovery − floor shortfall)` | `qnt58_topUpSplit` | Q-236, Q-267, Q-397 | stepAll | Holds (quick mode) |

Combined runs: `honestInvariants` (all 58) on `step` from `init`, `initStressed`, `initRouteOutage` and `initCrash`; `hostileInvariants` (every property not scoped to a reviewed RiskModule or LPVaultSwap) on `stepAll` from `init`, `initHostileSwap` and `initStressedHostileSwap`; `adapterInvariants` (the properties that hold for any Adapter implementation: QNT-01, 05, 09, 12, 13, 23, 28, 30, 34, 35, 41, 44, 52 to 55) on `stepHostileAdapter` from `initStressedHostileAdapter`.

### Scenario tests (`avana_tests.qnt`)

| ID | Test | Shows | Backs |
|---|---|---|---|
| QNT-T01 | `nft42SingleRegistrationTest` | NFT #42 pledged by alice cannot be pledged again by anyone or into another market; the (alice, S1) proxy is bound and registered in mA's token | Q-067, Q-224, Q-225, Q-258 |
| QNT-T02 | `borrowNonceAndCallerTest` | replayed nonce, the attacker and the Adapter cannot borrow on alice's account; a third party may repay but not withdraw | Q-106, Q-212, Q-223, Q-229 |
| QNT-T03 | `repayAlwaysOpenTest` | partial repay to 700 GHO under `Paused(MintPathSuspect)`, a tripped breaker, a frozen borrower, a Cached price and a hostile RiskModule | Q-051, Q-153, Q-227, Q-241, Q-242, Q-260 |
| QNT-T04 | `hostilePolicyBorrowTest` | a hostile RiskModule borrows in Drifting and against an Aave-frozen reserve (scope of QNT-38 and QNT-19) but Aave's HF ≥ 1 still binds | Q-081, Q-203, Q-223, Q-229 |
| QNT-T05 | `keeperLiquidationTest` | 300 GHO repaid, 315 units from record 42, fees kept, Avana fee 3 GHO, keeper +12 GHO | Q-060, Q-061, Q-160, Q-194, Q-224, Q-256 |
| QNT-T06 | `directLiquidationBlockedTest` | only LPVaultSwap can call the Spoke's `liquidationCall` | Q-116, Q-144, Q-222 |
| QNT-T07 | `zeroSeizeThirdPartyTest`, `zeroSeizeRejectedTest` | a third party cannot make even a zero-collateral call; LPVaultSwap refuses a liquidation that seizes 0 units | Q-127, Q-144, Q-167, Q-222 |
| QNT-T08 | `hostileAdapterTest` | a hostile Adapter borrows against alice up to Aave's HF, releases her NFT to her (not to the named address), leaves unbacked tokens, registers a rogue proxy that still cannot liquidate | Q-223, Q-224, Q-226 |
| QNT-T09 | `reconcileOnExitTest` | after a hostile seize-and-keep, alice's withdrawal reconciles 315 units into the pending balance; both NFTs come back; a reviewed LPVaultSwap burns the 315 units and funds the GHO First-Loss Reserve | Q-201, Q-224, Q-257, Q-260 |
| QNT-T10 | `hostileSwapWrongRecordTest` | Collateralization refuses to debit bob for alice's seizure and refuses a settlement without a burn | Q-160, Q-224 |
| QNT-T11 | `ledgerCheckBricksTest`, `deltaCheckSurvivesTest` | a "Σ credited = supply" check would block every later liquidation; the snapshot check settles and reconciles | Q-160 |
| QNT-T12 | `graceTimestampLatchTest`, `graceReadLatchMissTest` | the timestamp latch applies grace with no read during the outage; a read latch would miss it | Q-088, Q-129, Q-154 |
| QNT-T13 | `pauseNeverStopsLiquidationTest`, `aavePauseTest` | `Paused(MintPathSuspect)`, breakers and a frozen borrower leave liquidation open; an Aave-side pause lasts until the DAO unpauses and no Avana action lifts it (C-QNT-2) | Q-202, Q-227, Q-241, Q-242 |
| QNT-T14 | `strayRescueTest` | a stray NFT is returned to its proven owner; a pledged NFT is not returnable; a stray NFT is not pledgeable | Q-104, Q-134, Q-258 |
| QNT-T15 | `sequentialLiquidationTest` | two-market account: mA seized (debt 2,000 → 1,047), then mB with a 475 GHO deficit, covered by the GHO First-Loss Reserve while the USDT one is untouched; the zero-credit record is released to alice only | Q-098, Q-101, Q-134, Q-236 |
| QNT-T16 | `donationTest` | donated liquidity returns with the NFT and is not credited | Q-067 |
| QNT-T17 | `uncappedCollectTest` | without the principal cap the liquidation would take fees | Q-061 |
| QNT-T18 | `disagreementPauseTest` | disagreement stops seizure of the market from the first stored observation, keeps it blocked as Expired after the pause, values it at the lower route, and liquidation proceeds once the routes agree | Q-162, Q-199, Q-208, Q-247 |
| QNT-T19 | `withdrawFloorTest` | withdraw-with-debt needs HF ≥ 1.00 (no opening floor; the optional hard floor is off); a hostile RiskModule is held only by Aave's HF ≥ 1 | Q-161, Q-229, Q-398 |
| QNT-T20 | `noAvanaAccountCapsTest` | two markets and two records per market in one account; a pledge on S2 creates alice's second proxy | Q-193, Q-194, Q-225, Q-234 |
| QNT-T21 | `hubHaltTest` | Hub halt: only fee collection continues | Q-118, Q-140 |
| QNT-T22 | `topUpRulesTest` | a new account needs Live; a top-up may go into Drifting, not Cached; Frozen admits an indebted account's top-up and refuses a new account; `Paused(General)` refuses a top-up that is not a rescue | Q-132, Q-227 |
| QNT-T23 | `keeperFloorTest` | with `keeperFloor` 1, removal and address freeze go down to one active keeper and stop there; adding a keeper waits the normal delay and only the DAO can cancel it | Q-139, Q-228, Q-242, Q-263, Q-400 |
| QNT-T24 | `hostileSwapStaleTest` | the reviewed LPVaultSwap seizes fresh mA while mB is Expired, never mB; a hostile one seizes all 600 units of the Expired mB for 1 GHO (finding QNT-F1) | Q-128, Q-227, Q-247 |
| QNT-T25 | `dustLiquidationSettlesTest` | a 1-GHO dust liquidation with 2 % slippage on each leg meets the per-leg minimums, settles through the floor's rounding allowance, and the keeper pays the 2-cent gap | Q-198, Q-250, Q-267, Q-397 |
| QNT-T26 | `reconcileOnSettlementTest` | an unsettled seizure is reconciled during the next reviewed settlement of the account | Q-201, INV-058 |
| QNT-T27 | `haltBlocksRiskyExitsTest` | withdraw-with-debt is blocked while both route records of a held market are disabled, open again once a short-delay `restoreRoute` executes, and blocked by Hub shares ≠ assets, which also stops liquidation of that market only; repay stays open | Q-189, Q-206, Q-227, Q-229 |
| QNT-T28 | `repayRaceTest` | bob repays alice's whole debt; alice's later repay-all spends 0; bob cannot withdraw alice's NFT | Q-180, Q-212, Q-269 |
| QNT-T29 | `anyCallerLiquidationTest` | bob, not a committed operator, liquidates through `liquidate` (paid 12 GHO, no budget exists); a past deadline, a minimum payout of 12.01 GHO, a frozen caller all revert, and bob and the committed operator k1 can each settle the dust call | Q-213, Q-216, Q-242, Q-404 |
| QNT-T30 | `payoutEscrowTest` | in-kind settlement is removed; bob's GHO payout is refused by the token, bob's liquidation completes, the 12 GHO payout is credited to bob in the escrow and claimed to alice | Q-133, Q-214, Q-228, Q-401 |
| QNT-T31 | `rescueTopUpTest` | under `Paused(General)` an account at HF 1.00 tops up a 200-GHO NFT (below `minPledgeUsd`) as a rescue, a larger one is refused, a new account is refused, `MintPathSuspect` refuses the rescue, the freeze-only key cannot unpause, and the rescue units are excluded from new borrowing | Q-227, Q-252, Q-253 |
| QNT-T32 | `breakersTest`, `seizureSurgeTest` | a manual market breaker stops borrowing and withdraw-with-debt, not repay; a GHO issuer breaker stops GHO borrowing only; a seizure surge is an alert only and leaves the market open (`Q-399`) | Q-241 |
| QNT-T33 | `addressFreezeTest` | a frozen borrower keeps repay, fee collection and debt-free withdrawal; protected addresses cannot be frozen; each guardian is limited per window; unfreezing waits the normal delay and only the DAO can cancel it | Q-242 |
| QNT-T34 | `backingOneSidedTest`, `backingEqualityBricksTest` | after an orphan burn of 315 units bob's debt-free withdrawal still works under the one-sided check and reverts under the absolute equality | Q-257, INV-080 |
| QNT-T35 | `partialRemovalTest` | partial removal pays the principal to the depositor and keeps the NFT and fees in custody; with debt the record left must be worth `minPledgeUsd` and the account keep 1.10; Paused refuses it with debt and allows it debt-free | Q-254 |
| QNT-T36 | `recreditTest` | re-credit books exactly the added liquidity, mints and supplies it; only the depositor | Q-254, Q-257 |
| QNT-T37 | `repayWithCollateralTest` | under Frozen and a tripped breaker NFT 7's 800 units repay 1,550 GHO with no bonus or fee; HF rises; 50 GHO go to alice and the NFT returns; Paused and a frozen caller refuse it | Q-255 |
| QNT-T38 | `usdtLiquidationTest` | bob's USDT debt: with the DebtOracle Cached only the GHO reserve can be repaid; the standby switch restores USDT and the executor undoes it; a buy above the oracle bound reverts; the liquidation buys 410 USDT, sells 10 back above its floor, and Avana's fee (3.79 GHO) comes from the oracle value | Q-235, Q-247, Q-248, Q-256 |
| QNT-T39 | `shortfallReportsAlertTest` | routes 10 % below the oracle fail the per-leg minimums without a shortfall allowance and settle with one (the keeper pays 20.05 GHO); floor-failure reports are alerts only and change no gate | Q-228, Q-251, Q-399, Q-401 |
| QNT-T40 | `timelockTest` | an upgrade cannot be scheduled at the short delay nor moved onto the short list; the normal delay cannot drop below 4; admin power cannot leave the timelock; with the multisig's quorum lost the Aave executor proposes; a restoring operation is cancellable only by the DAO, a mixed one by any canceller; a ready operation expires | Q-228, Q-245, Q-259, Q-262, Q-263 |
| QNT-T41 | `standbyTest` | the standby switch ends an outage at once; the Aave executor undoes it; a stale standby leaves the market Cached | Q-248 |
| QNT-T42 | `staleMarketNoShieldTest` | with mB Expired (worth nothing to Aave) the reviewed LPVaultSwap seizes the fresh mA and never mB | Q-247, Q-276, Q-277 |
| QNT-T43 | `accountIsolationTest` | alice's S1 liquidation leaves her S2 account untouched | Q-225, Q-234, Q-278 |
| QNT-T44 | `callerTopUpSplitTest` | the budget is removed: a dust liquidation's caller top-up is exactly its 2-cent settlement gap | Q-236, Q-267, Q-397 |

## Results

Run on 2026-11-10 with Quint 0.22.4 on 8 cores, in quick mode: 500 traces × 20 steps per check, 96 checks, about 14 minutes. The 10,000 × 20 full run, `QUINT_FULL=1 ./run.sh`, runs by hand; no CI workflow runs it. In full mode a missed witness fails the run, so the four quick-mode warnings below must be reached there.

Re-run on 2026-11-11 after the one entry point (`Q-404`) replaced the keeper and permissionless actions with one `liquidate` action open to every caller that is not frozen: `quint typecheck` of `avana.qnt` and `avana_tests.qnt`; `quint test avana_tests.qnt` (50 passing, `QNT-T29` now `anyCallerLiquidationTest`); and `QNT_ONLY='^(QNT-ALL-H|QNT-32|QNT-36|QNT-40|QNT-42|W-PERM)$' QNT_JOBS=2 ./run.sh` in quick mode (500 traces × 20 steps): QNT-ALL-H, QNT-32, QNT-36, QNT-40 and QNT-42 hold, and W-PERM (now a liquidation by a caller outside the committed-operator registry) is again a quick-mode warning; 5 minutes 46 seconds. The other 90 checks were not re-run on this change; the next full run covers them.

| Check | Result |
|---|---|
| `quint typecheck avana.qnt`, `quint typecheck avana_tests.qnt` | Both pass |
| `quint test avana_tests.qnt` | 50 of 50 scenarios pass (`QNT-T01` … `QNT-T44`) |
| `quint test avana.qnt` | No `run` tests in this module; passes |
| 58 properties `QNT-01` … `QNT-58` | 58 hold, 0 violated |
| 8 combined runs | 8 hold, 0 violated |
| 30 witnesses | 26 reached, 4 not reached in quick mode (warnings) |

**Combined runs**

| ID | Invariant | Init | Steps | Result | Time |
|---|---|---|---|---|---|
| QNT-ALL-H | `honestInvariants` | `init` | step | Holds | 395 s |
| QNT-ALL-HS | `honestInvariants` | `initStressed` | step | Holds | 574 s |
| QNT-ALL-HR | `honestInvariants` | `initRouteOutage` | step | Holds | 460 s |
| QNT-ALL-HC | `honestInvariants` | `initCrash` | step | Holds | 809 s |
| QNT-ALL-X | `hostileInvariants` | `init` | stepAll | Holds | 250 s |
| QNT-ALL-XH | `hostileInvariants` | `initHostileSwap` | stepAll | Holds | 249 s |
| QNT-ALL-XS | `hostileInvariants` | `initStressedHostileSwap` | stepAll | Holds | 302 s |
| QNT-ALL-A | `adapterInvariants` | `initStressedHostileAdapter` | stepHostileAdapter | Holds | 192 s |

**Single properties.** Each of `QNT-01` … `QNT-58` holds on the step relation in the Properties table (92 s to 186 s per run). No new counterexample was found.

**Witnesses**

| ID | State the traces must reach | Init | Steps | Result |
|---|---|---|---|---|
| W-SEIZE | a liquidation call moves vault tokens | `init` | step | Not reached in quick mode (warning) |
| W-SURPLUS | the Avana fee recipient receives a fee | `init` | step | Reached |
| W-ZEROREC | a record at 0 credited units | `init` | step | Reached |
| W-DEFICIT | a deficit is reported | `initStressed` | step | Reached |
| W-COVER | a First-Loss Reserve covers a deficit | `initStressed` | step | Reached |
| W-WITHDRAW | a record is closed | `init` | step | Reached |
| W-TWOMKT | one proxy holds two markets | `init` | step | Reached |
| W-GRACE | a market recovers Expired → Live | `init` | step | Reached |
| W-DISAGREE | a disagreement pause expires for liquidation | `init` | step | Reached |
| W-STRAY | a stray NFT's owner is proven | `init` | step | Reached |
| W-KEEP | a hostile LPVaultSwap keeps seized tokens | `initStressedHostileSwap` | stepHostileSwap | Reached |
| W-PERM | a liquidation by a caller outside the committed-operator registry | `init` | step | Not reached in quick mode (warning) |
| W-INKIND | a debt token starts refusing a holder's payout (in-kind removed, `Q-401`) | `init` | step | Reached |
| W-ESCROW | the PayoutEscrow credits a refused payout | `initStressed` | step | Reached |
| W-3PREPAY | a third party repays a borrower's debt | `init` | step | Reached |
| W-PENDING | a pending-settlement balance | `initStressedHostileSwap` | stepHostileSwap | Reached |
| W-ORPHAN | an exit after an orphan burn | `initStressedHostileSwap` | stepHostileSwap | Reached |
| W-RESCUE | a rescue top-up | `initStressed` | step | Reached |
| W-REMOVE | a partial removal | `initStressed` | step | Reached |
| W-RECREDIT | a re-credit | `initStressed` | step | Not reached in quick mode (warning) |
| W-RWC | a repay with collateral | `initStressed` | step | Reached |
| W-USDTLIQ | a liquidation repaying USDT | `initStressed` | step | Reached |
| W-SHORTFALL | a caller's shortfall top-up | `initCrash` | step | Reached |
| W-AUTOINKIND | a floor-failure report (an alert only) | `initCrash` | step | Reached |
| W-SURGE | a seizure-surge alert (no latch) | `initStressed` | step | Reached |
| W-STANDBY | a standby switch | `init` | step | Reached |
| W-FROZENEXIT | a frozen address withdraws or repays | `initStressed` | step | Reached |
| W-TLEXEC | a timelock operation executes | `init` | step | Reached |
| W-DAOPROP | an operation proposed by the Aave executor executes | `init` | step | Reached |
| W-DAOCANCEL | the DAO canceller cancels a DAO-only operation | `init` | step | Not reached in quick mode (warning) |

The four warnings are coverage gaps of the 500-trace sample, not property failures. The random states they ask for are reachable: the W-SURPLUS trace from `init` ends in a permissionless liquidation that moves vault tokens, so the states of W-SEIZE and W-PERM occur in this run's traces, only not inside their own samples (from `init` a seizure needs a pledge, a borrow and a price fall before the liquidation, inside 20 steps). Each state is also reached by a deterministic scenario that passes: a keeper seizure by `QNT-T05` (and from the seeded states by W-USDTLIQ, W-KEEP, W-INKIND and W-SHORTFALL), a permissionless liquidation by `QNT-T29`, a re-credit by `QNT-T36`; for W-DAOCANCEL, `QNT-T23`, `QNT-T33` and `QNT-T40` show the DAO canceller allowed and every other canceller refused on restoring and role-change operations.

### Findings

No property was violated in this run. The model records one finding from its scenarios:

| ID | Finding | Evidence | Status |
|---|---|---|---|
| QNT-F1 | A hostile LPVaultSwap can seize an Expired market in full for one unit of debt. Aave values an Expired market at its minimum price (modelled as 0), so a liquidation sized at that price seizes the whole supply of the market. Trace: alice holds mA and mB on S1 with debt; mA falls to price 1; mB's feeds fail; after two ticks mB is Expired. The reviewed LPVaultSwap seizes the fresh mA and refuses every amount on mB; a hostile one seizes all 600 units of mB for 1 GHO. | `QNT-T24` (`hostileSwapStaleTest`), `QNT-T42`; QNT-22 holds for the reviewed LPVaultSwap | Bounded by the timelock: a hostile LPVaultSwap must wait the normal delay and can be cancelled (QNT-52, QNT-53); the reviewed implementation never seizes a market whose own price is Cached, Expired or disagreeing (QNT-22, `Q-247`) |

## Traceability rows

`traceability.md` is generated by `trace.py` from the `QNT-… verifies:` tags in the `.qnt` files. Rows:

| Requirement | Statement | Quint IDs | Status |
|---|---|---|---|
| Q-067 / Q-224 / Q-225 / Q-258 | Depositor of record; one proxy per wallet and Spoke; stray NFTs not pledgeable | QNT-01, QNT-02, QNT-05, QNT-08, QNT-35, QNT-T01, QNT-T16 | Holds (quick mode); scenarios pass |
| Q-223 / Q-226 / Q-229 | Adapter and RiskModule blast radius | QNT-13, QNT-T04, QNT-T08, QNT-T19 | Holds (quick mode); scenarios pass |
| Q-116 / Q-144 / Q-222 | Only the liquidation manager seizes | QNT-09, QNT-23, QNT-T06, QNT-T07 | Holds (quick mode); scenarios pass |
| Q-160 / Q-224 | Debit equals the share drop and the supply drop | QNT-07, QNT-10, QNT-T05, QNT-T10, QNT-T11 | Holds (quick mode); scenarios pass |
| Q-201 / Q-257 | Reconcile on exit; pending balance; one-sided backing check | QNT-03, QNT-07, QNT-15, QNT-37, QNT-48, QNT-T09, QNT-T26, QNT-T34 | Holds (quick mode); scenarios pass |
| Q-051 / Q-118 / Q-212 / Q-260 / Q-269 | Repay, fee collection and debt-free exits open unless Aave blocks | QNT-14, QNT-15, QNT-16, QNT-17, QNT-39, QNT-T03, QNT-T21, QNT-T28 | Holds (quick mode); scenarios pass |
| Q-227 / Q-252 | Pause state and reasons; rescue top-ups | QNT-25, QNT-33, QNT-44, QNT-47, QNT-T13, QNT-T22, QNT-T31 | Holds (quick mode); scenarios pass |
| Q-241 | Circuit breakers stop new activity only | QNT-32, QNT-33, QNT-45, QNT-T32 | Holds (quick mode); scenarios pass |
| Q-242 | Address freeze | QNT-34, QNT-46, QNT-T23, QNT-T29, QNT-T33 | Holds (quick mode); scenarios pass |
| Q-247 / Q-238 / Q-248 | Per-reserve liquidation gate, conservative valuation, standby | QNT-22, QNT-36, QNT-54, QNT-55, QNT-T18, QNT-T24, QNT-T38, QNT-T41, QNT-T42 | Holds (quick mode); scenarios pass |
| Q-081 / Q-128 / Q-203 / Q-229 / Q-253 | Borrow-side gates, HF floor, rescue exclusion | QNT-18, QNT-19, QNT-20, QNT-38, QNT-T27, QNT-T31 | Holds (quick mode); scenarios pass |
| Q-088 / Q-154 / Q-264 | Grace per account | QNT-24, QNT-T12 | Holds (quick mode); scenarios pass |
| Q-085 / Q-198 / Q-250 / Q-251 / Q-256 / Q-235 | Floor, per-leg minimums, shortfall top-up, fee, buy and sell-back legs | QNT-26, QNT-27, QNT-57, QNT-T05, QNT-T25, QNT-T38, QNT-T39 | Holds (quick mode); scenarios pass |
| Q-127 / Q-167 / Q-236 / Q-267 | Settlement budget removed; the caller funds every gap (`Q-397`) | QNT-28, QNT-29, QNT-58, QNT-T44 | Holds (quick mode); scenarios pass |
| Q-101 / Q-233 / Q-236 | Per-asset Hub accounting and deficit coverage | QNT-30, QNT-31, QNT-T15 | Holds (quick mode); scenarios pass |
| Q-139 / Q-228 | Keeper floor | QNT-34, QNT-T23 | Holds (quick mode); scenarios pass |
| Q-213 / Q-216 / Q-404 | Any-caller liquidation and call bounds | QNT-40, QNT-42, QNT-T29 | Holds (quick mode); scenarios pass |
| Q-133 / Q-214 / Q-251 | In-kind removed; payout escrow; shortfall reports as alerts (`Q-399`, `Q-401`) | QNT-41, QNT-43, QNT-56, QNT-T30, QNT-T39 | Holds (quick mode); scenarios pass |
| Q-254 | Partial removal and re-credit | QNT-49, QNT-T35, QNT-T36 | Holds (quick mode); scenarios pass |
| Q-255 | Repay with collateral | QNT-50, QNT-T37 | Holds (quick mode); scenarios pass |
| Q-225 / Q-234 / Q-276 | Account isolation per Spoke | QNT-51, QNT-T20, QNT-T43 | Holds (quick mode); scenarios pass |
| Q-228 / Q-245 / Q-259 / Q-262 / Q-263 | Timelock delays, allowlist, roles, cancel rules | QNT-52, QNT-53, QNT-T40 | Holds (quick mode); scenarios pass |
