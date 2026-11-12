# Hypothesis: executable reference model of Avana

This folder holds an executable Python model of Avana (`model/`) and the Hypothesis tests that drive it. The model implements the final design (`Q-001`…`Q-278`) with integer arithmetic and real decimals: Uniswap v3 `uint128` liquidity and full-range amounts, tokens with 6 and 18 decimals, Aave V4 WAD/RAY/BPS math ported line by line from `aave-v4@a3ef63e`, 8-decimal prices, per-market vault-token decimals (6, 12, 18), two debt assets (GHO at its fixed price and USDC through its DebtOracle) and one PositionProxy per wallet per Borrow Spoke. Every check is tagged `HYP-NN verifies: Q-…/REQ-…/INV-…/SPEC-…` for `trace.py`.

Run from `spec/05-verification/`:

```bash
.venv/bin/python -m pytest -q hypothesis                      # recorded settings (run_all.sh runs this)
AVANA_HYP_SCALE=5 .venv/bin/python -m pytest -q hypothesis    # deeper search: 5x the examples
```

No dependencies beyond `requirements.txt` (hypothesis 6.112.5, pytest 8.3.3). The example database is off, so runs write no files; a failure prints a `@reproduce_failure` blob. `AVANA_HYP_NOSHRINK=1` skips shrinking for quick triage.

## Model

| File | Contents | Source mirrored |
|---|---|---|
| `model/mathlib.py` | WAD/RAY/BPS helpers, `mulDiv` up/down, `sqrt`, SharesMath (virtual 1e6), `toValue`, linear interest; every helper checks its Solidity bit width | Aave V4 `WadRayMath`, `PercentageMath`, `MathUtils`, `SharesMath`, `SpokeUtils`; OZ `Math` |
| `model/uniswap.py` | `getSqrtRatioAtTick`, `getAmount0/1Delta`, `maxLiquidityPerTick`; pool as a reserve holder; NFPM mint, `increaseLiquidity` (anyone), `decreaseLiquidity`, `collect`, approvals | v3-core, v3-periphery |
| `model/tokens.py` | One ERC-20 ledger for USDC, USDT, DAI, GHO and the vault tokens; zero-amount transfers revert; issuer pause, blocklist, transfer fee (the USDT fee switch), refused delivery and transfer callbacks for reentrancy | `Q-217`, `Q-271`, `Q-278` |
| `model/aave.py` | Hub (add, remove, draw, restore, reportDeficit, eliminateDeficit, refreshPremium, caps); Spoke (supply, withdraw, borrow, repay, collateral, health factor over several collateral and debt reserves, risk premium, `liquidationCall` with bonus curve, target HF, dust rules, deficit reporting, per-account reserve limit); the liquidation-manager Spoke accepts only LPVaultSwap and no `receiveShares` | `Hub.sol`, `Spoke.sol`, `LiquidationLogic.sol`, `Q-222`, `Q-237` |
| `model/oracle.py` | Chainlink feeds with phase-aware round IDs; primary, alternate and standby route per token; LPOracle (`isqrt(4·v0·v1) − 1`, $1 stable ceiling, agreement, TWAP, USD band with the upper bound on capped prices, Live / Drifting / Cached / Expired, served price by state, age limits, recovery evidence with the phase rule, grace latch, hourly checkpoint); DebtOracle (failover, agreement, Cached, Expired stress price) | `SPEC-ORC-001`…`018`, `Q-247`, `Q-248`, `Q-264`, `Q-272`, `Q-274`, `Q-275` |
| `model/avana.py` | MarketRegistry state (pause state and reason, market status, circuit breakers, address freeze, approved debt reserves per Spoke), vault tokens (Adapter-only mint and burn, recipient check, proxy registry), Collateralization (records, credit, rescue units, exposure counters with the fixed basis and re-credit rebase, reconcile on exit, pending balance), LPVault custody, AaveAdapter (pledge, borrow, repay and repay-all with refund, withdrawal, partial removal, re-credit, one-sided backing check), RiskModule (`checkPledge` with rescue top-ups, pre-checks, rescue-excluded health check), Coverage Spokes per debt asset, PayoutEscrow | `Q-223`…`Q-260`, `Q-267`, `Q-269`, `Q-270` |
| `model/swap.py` | LPVaultSwap and SettlementMath: gates per seized market and repaid reserve, an Aave V3 flash loan of the debt asset (premium `⌈F × 5 / 10⁴⌉`, refused unless `φ × 10⁴ ≤ maxFlashFeeBps × F`) or caller funds in that asset, `liquidationCall`, the leftover `X − D` repaying the flash loan, burn and settle with share-drop and supply-drop checks, swap routes from each pool token straight into the debt asset with per-leg minimum outputs, caller top-up of the floor shortfall and any settlement gap (no settlement budget, Q-397), Avana fee from oracle value, payout in the debt asset repaid, a refused payout credited in the PayoutEscrow (payout escrow, Q-401), shortfall reports as monitoring alerts, pending settlement into the GHO Coverage Spoke, repay with collateral; faulty LPVaultSwap versions (seize without settling, orphan burn) | `SPEC-LIQ-001`…`020`, `SPEC-SET-001`…`006`, `Q-235`, `Q-250`, `Q-251`, `Q-255`, `Q-256`, `Q-261`, `Q-267` |
| `model/timelock.py` | AvanaTimelock: required delay, schedule and execution window, `setNormalDelay` bounds, immutable short-delay allowlist, cancel rules for restoring and role-change operations, admin roles only for the timelock | `SPEC-GOV-001`…`015`, `Q-228`, `Q-259`, `Q-262`, `Q-263` |
| `model/params.py` | Launch values and per-market values | 1.5 Parameters |
| `model/invariants.py` | Global invariants checked after every state-machine step, including solvency per debt asset | 4.1 Global Invariants |

Every flow is one atomic transaction (`System.tx`): any revert restores the whole state. Outer entry points hold the protocol Lock, so a reentrant call reverts `LockHeld`.

Parameters: no on-chain opening floor (Q-398): the gate is HF ≥ 1.00, an optional per-market hard floor is off, and rescue top-ups restore the recommended HF 1.10; Aave target HF 1.10, LP CF 31.2%, max bonus 5% with factor 50%; caps $3M per market with a $300k slice, $5M per token, $1.5M per depositor, pool share 10%, stress floor $1.00, `minPledgeUsd` $10; primary heartbeat 1 h and alternate 24 h, `feedMaxAge` heartbeat + 600 s, `borrowPriceMaxAge` `min(heartbeat + 600, 4,200)`, Cached 1 h, disagreement pause 1 h, agreement tolerance 1.5%, TWAP tolerance 0.5%, USD band 0.90–1.02, grace 30 min below HF 0.95, `debtStressRiseBps` 500; `slippageAllowanceBps` 100, `floorRoundingAllowance` 1 GHO and 1 USDC, flash premium 5 bps with `maxFlashFeeBps` 10, Avana fee 20%, `maxShortfallBps` 1,000; breakers (Q-399): oracle and band, pool share 10% (`poolShareMaxBps`), issuer, coverage, deficit 10,000 GHO; price drop, seizure surge and route failures are monitoring alerts only; address freezes 20 per guardian per 24 h; keeper floor 1, at most 32 keepers (Q-400); credit lines 2M GHO and 1M USDC; Coverage Spokes 400,000 GHO and 50,000 USDC (illustrative model values; the funding ARFC sets `coverageRatioBps` and the reserve minimum). Swap routes: a primary and a backup route into the debt asset at Chainlink minus 0.3%; no buy route: a USDC liquidation flash-borrows USDC and settles in it.

## Settings and run log

| Test file | Budget |
|---|---|
| `test_hyp_state_machine.py` | `max_examples=400`, `stateful_step_count=60`; profiles: launch caps, caps that follow the cap-sizing rule of `Q-249` (solvency checked after every step), small caps; a faulty RiskModule in 1 of 6 runs outside the cap-sizing profile; one or two Borrow Spokes |
| `test_hyp_numeric.py` | 1–500 examples per test (stated in each `@cfg`); `HYP-46` up to 10,000 chunks; `HYP-47` 4 × 5,000 operations; `HYP-48` 3 × 300 cycles and 8 runs of 20–120 liquidations |
| `test_hyp_scenarios.py` | 15–80 examples per property; single-case sequences |
| `test_hyp_timelock.py` | state machine 300 × 40 steps; 300 examples per property |

Run log (2026-11-10; Python 3.9.6, hypothesis 6.112.5, pytest 8.3.3; example database off, random seeds):

| Run | Command (from `spec/05-verification/`) | Bounds | Result | Exit |
|---|---|---|---|---|
| Recorded | `.venv/bin/python -m pytest -q hypothesis` | settings above | 71 tests: 70 passed, 1 failed (`test_hyp85_leg_minimums_within_aggregate_floor`, the finding below); 509 s wall, 261 s CPU | 1 |
| Recorded (option C, `Q-404`) | `.venv/bin/python -m pytest -q hypothesis` | settings above | 82 tests: 81 passed, 1 failed (`test_hyp83_debt_asset_flash_settlement`: its balance assertion missed the helper's premium; fixed, then `-k "hyp83 or hyp65"`: 2 passed); 1,093 s wall. `model/swap.py`: caller funding `Kf`, no premium term, gap `max(0, D + A − Kf − R)`, keeperOut paid directly, helper loan and top-up outside LPVaultSwap; HYP-23, -38, -65, -83 restated | 0 after the fix |
| Deep, state machine | `AVANA_HYP_SCALE=5 .venv/bin/python -m pytest -q hypothesis/test_hyp_state_machine.py` | 2,000 examples × 60 steps | 1 passed; 282 s | 0 |
| Deep, numeric, scenarios and timelock | `AVANA_HYP_SCALE=4 .venv/bin/python -m pytest -q hypothesis/test_hyp_numeric.py hypothesis/test_hyp_scenarios.py hypothesis/test_hyp_timelock.py` | 4 × the recorded examples | 66 passed, 2 failed in 1,738 s: the USDC run of `HYP-47` exceeded the 1M USDC draw cap with the test's own borrow sizes (the test now stays inside the cap and passes), and the sum bound now tested as `test_hyp85_leg_minimums_within_aggregate_floor` | 1 |
| Deep, numeric and scenarios after those two changes | same command | 4 × the recorded examples | stopped after 34 tests at the close of the session: 33 passed, 1 failed (the same `HYP-85` sum bound) | — |
| Deep, timelock | `AVANA_HYP_SCALE=5 .venv/bin/python -m pytest -q hypothesis/test_hyp_timelock.py` | 1,500 × 40 steps; 1,500 examples per property | 9 passed; 62 s | 0 |
| Per-leg minimum sum bound after the spec fix (`INV-083`, `SPEC-LIQ-018` with the LP-price term, `HYP-85`) | `.venv/bin/python -m pytest -q hypothesis/test_hyp_numeric.py -k hyp85` | settings above (500 examples each, pinned counterexample included) | 2 passed in 5 s | 0 |
| Restore amount at the served price (`SPEC-CAP-003`, `model/avana.py` `restore_booked`) | `.venv/bin/python -m pytest -q hypothesis -k "hyp55 or slice or rescue or topup or restore"`, then `.venv/bin/python -m pytest -q hypothesis/test_hyp_state_machine.py` | settings above | 3 passed in 8 s; state machine 1 passed in 156 s | 0, 0 |
| Public lending (`Q-407`): Lend Spoke supply cap separate from the credit line, DAO bootstrap supply, `HYP-97` in the lender rule | `.venv/bin/python -m pytest -q -p no:cacheprovider hypothesis/test_hyp_state_machine.py hypothesis/test_hyp_scenarios.py` | settings above | 39 passed in 82 s | 0 |
| Kinked rate curve (`Q-408`): `model/aave.py` ports `AssetInterestRateStrategy.calculateInterestRate` and recomputes each debt asset's drawn rate after every Hub action; `HYP-98` added as a global invariant | `.venv/bin/python -m pytest -q -p no:cacheprovider hypothesis` | settings above | 82 passed in 209 s. A first run failed `HYP-98` because the lender rule accrues the GHO index outside a Hub action and the check read the moved index; the check now reads the index the rate was set at (`rate_index`), as V4's `updateDrawnRate` does | 0 |

State machine actors and rules: borrowers on four wallets (pledge, open and borrow near the floor in GHO and USDC, borrow with nonce, deadline and minimum HF, every repay form by the borrower and a third party including racing repay-alls, whole withdrawal, partial removal, re-credit after a liquidity donation, repay with collateral in GHO and USDC, fee collection); an outside LP adding and removing pool depth; approved keepers (flash or own GHO, every route mode, deadlines, minimum payouts, shortfall top-ups, full-size sweeps, shortfall reports); a permissionless liquidator; a flash-loan attacker liquidating any account including its own; a pool manipulator moving spot prices off the TWAP and sandwiching swap routes; Aave governance raising the flash premium above `maxFlashFeeBps` and the Pool's idle liquidity draining, after which keepers fund the debt themselves; a public lender adding (up to and past the Lend Spoke supply cap) and withdrawing (up to and past the Hub's idle liquidity) on the Lend Spoke beside the DAO's bootstrap supply (`HYP-97`); guardians (freeze, pause with either reason, unpause, unfreeze, address freeze, manual breakers, standby switches); token issuers (USDT fee switch, USDC pause, delivery refusal, gas-burning receivers); Aave (reserve pause and freeze, configuration drift); price moves on all routes, primary only, pool only and across a Chainlink phase change, depegs to $0.05, feed breaks, zero and maximum answers, time advance with and without heartbeats, `poke` with and without gas; hostile seizure and orphan burns followed by reconcile and pending settlement; deficit coverage per asset; dust to every Avana address; escrow claims; keeper removal.

## Results

Every property below **holds** in the recorded and deep runs. The one finding, the sum bound on the per-leg minimum outputs (`HYP-85`, see [Finding](#finding)), is resolved in the spec: `INV-083` and `SPEC-LIQ-018` now carry the LP-price rounding term, and both `HYP-85` tests pass against that text. One property has a stated bound (`HYP-53`).

### Global invariants (after every step)

| ID | Property | Decisions |
|---|---|---|
| HYP-01 | Vault-token supply ≤ Σ credited + pending units, per market | Q-066, Q-201, Q-224, INV-001 |
| HYP-89 | The backing gap `Σ credited + pending − supply` equals the units orphan-burned by a faulty LPVaultSwap, so every Adapter call keeps it unchanged and conforming calls keep it at 0 | Q-257, INV-080, INV-066 |
| HYP-02 | Each record's live liquidity ≥ its credited units; the LPVault holds every open NFT; the record's proxy is `proxyOf[depositor][spoke]` | Q-066, Q-067, Q-225, INV-064 |
| HYP-03 | Hub vault-token balance = Hub liquidity = Σ supplied shares over every Spoke; shares = assets | Q-066, Q-068, Q-103, Q-189 |
| HYP-04, HYP-12 | Vault tokens rest only in the Hub and in LPVaultSwap (seized units a faulty version kept); no other holder ever receives one | Q-068, Q-120, Q-224 |
| HYP-05 | Per proxy and market, supplied = credited − units a faulty version seized and nobody reconciled | Q-160, Q-193, Q-194, Q-201 |
| HYP-06 | Σ balances = supply for every token | Q-097, Q-124 |
| HYP-74 | No Avana contract or proxy ends a transaction holding any token beyond dust sent to it by plain transfer; GHO leaves only through the flows | Q-063, Q-211, Q-255, Q-278, INV-079 |
| HYP-07 | Debt never negative; Hub and Spoke share and premium accounting agree per debt asset and Spoke | Q-116, Q-153 |
| HYP-08 | Deficit bookkeeping per asset consistent; Coverage Spokes never draw | Q-070, Q-101, Q-142, Q-236 |
| HYP-09 | Pools stay solvent for every position's principal and owed amounts | Q-061 |
| HYP-10 | Market counters = Σ record charges, each charge = ⌈basis × credited / basis units⌉ (re-credit rebases), token counters exact, budgets never exceeded | Q-055, Q-150, Q-158, Q-174, Q-175, Q-254 |
| HYP-77 | Rescue units ≤ credited on every record | Q-252, Q-253, INV-082 |
| HYP-93 | Proxy bindings never change | Q-224, Q-225, INV-064 |
| HYP-31, HYP-87 | The SettlementBudget is removed (Q-397): every liquidation is funded by recovery plus the caller (`R + shortfall + K ≥ D + φ_D`), and the caller top-up is exactly the floor shortfall plus the settlement gap | Q-117, Q-167, Q-236, Q-267, Q-397, INV-037, INV-038 |
| HYP-65 | PayoutEscrow (payout escrow, Q-401) conservation: credited = claimed + held; `totalClaimable` = Σ credits ≤ balance | Q-214, Q-401, INV-061 |
| HYP-11 | LPOracle and DebtOracle served prices ≥ 1; a non-Live market never above its accepted price; a non-Live debt price never below its accepted price | Q-056, Q-191, Q-247, Q-248, INV-055, INV-087 |
| HYP-39 | A `removeKeeper` never leaves fewer than `keeperFloor` (1) unfrozen keepers, approved keepers never fall below it and never exceed `MAX_KEEPERS` (32); a guardian freeze may leave 0 unfrozen keepers, which halts new borrowing (`Q-400`) | Q-053, Q-139, Q-155, Q-242, Q-400 |
| HYP-70 | Solvency per debt asset (GHO and USDC): Σ min(debt, realizable) + pending value + Coverage Spoke ≥ Σ debt + Hub deficit, with realizable = `V(1 − s) − U − floorRoundingAllowanceGho` at Chainlink prices; checked after every step of the cap-sizing profile, where one pool token at a time may fall to $0.05 and the debt asset stays within its stress rise | Q-236, Q-249, Q-278, INV-074 |

### Flow postconditions (state machine)

| ID | Property | Decisions |
|---|---|---|
| HYP-13, HYP-54 | After a borrow, `hfEx ≥ max(1.00, optional hard floor, minHealthFactor)` (Q-398) and Aave's HF ≥ `hfEx`; with a faulty RiskModule only Aave's HF ≥ 1 holds | Q-018, Q-229, Q-253, SPEC-PROXY-001, SPEC-CF-003 |
| HYP-14 | Borrow only in pause state None, with every collateral market Live and every collateral and debt price within `borrowPriceMaxAge` | Q-081, Q-128, Q-227, Q-234, Q-238, Q-275 |
| HYP-15 | Wrong nonce or past deadline reverts and keeps the nonce; success increments it and pays the receiver exactly | Q-075, Q-105, Q-106 |
| HYP-16 | Zero debt returns 0 with no movement; a partial repay of 0 reverts; otherwise repay by any payer succeeds in every pause, breaker and freeze state unless Aave pauses the reserve | Q-051, Q-153, Q-227, Q-260, INV-043 |
| HYP-17, HYP-95 | A partial repay pulls `min(cap, debt)`; repay-all pulls the cap, Aave takes the debt, the rest is refunded in the same call and the debt is 0 | Q-153, Q-180, Q-268, Q-269 |
| HYP-60 | Repay-all with debt above the cap reverts `RepayExceedsMax` before any transfer | Q-180, Q-269 |
| HYP-64 | A third-party repay never debits the borrower; a second repay-all after the debt is cleared pulls nothing | Q-212 |
| HYP-18, HYP-76 | A debt-free withdrawal succeeds in every pause state, reason, breaker, freeze, price state and dust condition; only an Aave pause of the vault reserve stops it | Q-029, Q-227, Q-241, Q-242, Q-260, INV-045, INV-081 |
| HYP-19 | Withdrawal returns the whole NFT with its fees to the depositor of record | Q-009, Q-067, Q-201 |
| HYP-20 | After withdraw-with-debt `hfEx` meets the floor, never under Paused or for a frozen wallet | Q-018, Q-229, Q-253 |
| HYP-78 | A partial removal debits the record and the NFT by exactly the units; a re-credit credits exactly `live − credited` and rebases the charge | Q-254, INV-088 |
| HYP-79 | A repay with collateral lowers the named debt, raises no other debt, never lowers Aave's HF while debt remains, pays no fee, and never runs under Paused or for a frozen wallet | Q-255, INV-089 |
| HYP-21 | Fee collection succeeds in every Avana state unless the token itself cannot move | Q-011, Q-030, Q-227, INV-044 |
| HYP-22 | New accounts pledge only Live, top-ups Live or Drifting, every pledge at least the minimum value | Q-054, Q-132, Q-227, Q-230 |
| HYP-59 | Charge ≥ units × stress floor; slice only for indebted accounts | Q-150, Q-157, Q-175 |
| HYP-23, HYP-81 | Only HF < 1 accounts are liquidated, by an approved keeper or the permissionless entry point; a frozen caller never liquidates | Q-053, Q-213, Q-222, Q-242 |
| HYP-24, HYP-25 | Settlement changes no supply except the burned vault tokens; LPVaultSwap ends every settlement with zero change for every token | Q-063, Q-097, Q-124, Q-271 |
| HYP-26, HYP-27, HYP-28 | Records debited = seized units, largest first with only the last partial; fees never taken | Q-061, Q-108, Q-160, Q-194, Q-224 |
| HYP-29, HYP-86 | Routed: `R + shortfall ≥ minRec` in the debt asset, with the effective slippage after the flash premium and the floor shortfall at most the caller's maximum (in-kind settlement is removed, Q-401) | Q-085, Q-159, Q-198, Q-235, Q-251, INV-034 |
| HYP-30, HYP-84 | `S = max(0, R_f − D)`; `A = min(⌊max(0, V − D) × 20%⌋, S)`, with no flash-premium term in a liquidation (`SPEC-LIQ-007`) | Q-097, Q-256, INV-036, INV-086 |
| HYP-38, HYP-67 | No budget exists (Q-397): the caller, keeper or permissionless, pays any settlement gap `max(0, D + φ_D − R − floorGap − K)`; no Avana balance funds a liquidation | Q-159, Q-198, Q-213, Q-261, Q-267, INV-038, INV-062 |
| HYP-83 | Non-GHO debt: `G ≤ bound(X)`, `Gcov = min(Gnet, bound(D))` | Q-235, INV-070 |
| HYP-32 | A deficit is recorded only with no collateral left | Q-070, Q-101, Q-193 |
| HYP-72 | Each liquidation adds at most `seizedValue × (1 − 1/LB)` to the account's shortfall | Q-249, Q-278, INV-076 |
| HYP-34 | Collateral seized ≤ debt repaid × bonus + one unit | Q-060, Q-116 |
| HYP-35 | A full-size liquidation of a single-reserve account that leaves collateral and debt ends at HF ≥ target 1.10 | Q-060, Q-185 |
| HYP-36 | Liveness: every HF < 1 account whose seized market and repaid reserve pass their gates, with no Aave pause, honest routes and an active keeper, is liquidated at full size | Q-128, Q-198, Q-227, Q-247, INV-046 |
| HYP-37 | A gas-starved `poke()` reverts and changes no stored oracle state | Q-129, Q-154 |
| HYP-50 | Inside the grace window only accounts below HF 0.95 are liquidated | Q-088, Q-129, Q-154, Q-264 |
| HYP-58 | `settlePending` retires exactly the units it burns, meets `minPending` and funds only the GHO Coverage Spoke | Q-201, Q-211, Q-236 |
| HYP-33 | Coverage burns only the asset's Coverage Spoke shares, never above the recorded deficit or the funded balance | Q-070, Q-101, Q-142, Q-236, INV-042, INV-071 |
| HYP-61 | No borrow against an Aave-frozen vault reserve | Q-203 |
| HYP-66 | A payout the token refuses (the caller's or Avana's fee) is credited in the PayoutEscrow and never reverts the liquidation (Q-401) | Q-214, Q-401 |
| HYP-68 | A liquidation past its deadline reverts | Q-216 |
| HYP-97 | Public lending (`Q-407`): a public lender's Lend Spoke supply succeeds exactly when it fits the Lend Spoke supply cap (never the credit line), and a withdrawal succeeds exactly when it is within the Hub's idle liquidity; the DAO's bootstrap supply is an ordinary Lend Spoke position | Q-407, REQ-HUB-017, REQ-HUB-019 |
| HYP-98 | Rate curve (`Q-408`): after every step each debt asset's drawn rate equals Aave V4's kinked curve (`AssetInterestRateStrategy.calculateInterestRate`, ported line for line) at the liquidity and drawn amount of the asset's last Hub action, and lies between `baseDrawnRate` and `base + before + after` | SPEC-HUB-007, REQ-HUB-008, Q-408 |
| HYP-96 | The multi-actor suite as a whole: every rule and every invariant above over arbitrary interleavings | Q-224…Q-278 |

### Numeric and scenario properties

| ID | Property | Bounds | Decisions |
|---|---|---|---|
| HYP-40 | Positions below `minPledgeUsd` never mint; above it they pledge and withdraw exactly; a 1-wei loan in GHO or USDC records debt ≥ the amount and a quoted repay-all clears it | prices $0.05–$10; up to 1e7 s of interest | Q-066, Q-153, Q-169, Q-230 |
| HYP-41 | No overflow up to `type(uint128).max` liquidity; `maxLiquidityPerTick` < `uint120` | spacings 1/10/60/200 | Q-066, Q-092 |
| HYP-42 | LP price `isqrt(4·p0·p1) − 1` positive, 1–2 units below exact; out-of-bounds or stale answers rejected; `borrowPriceMaxAge = min(heartbeat + 600, 4,200)` | 1 h and 24 h heartbeats | Q-028, Q-056, Q-191, Q-274 |
| HYP-71 | Conservative valuation: for every spot price (pool moved ±40% off the TWAP) the oracle value of the units is at most the oracle-price value of what removal returns; at the oracle ratio the fixed routes return at least the realizable value `V(1 − s) − U − 1 GHO` | prices $0.05–$10; 1e3–1e30 units | Q-028, Q-198, Q-278, INV-078 |
| HYP-90 | Oracle answers of 0, −1, `2^255 − 1`, the bounds and one past them, and sudden moves: never a price, served ≥ 1, ≤ accepted outside Live, 1 when Expired; DebtOracle serves `q`, `max(p, b, A)`, `A`, `⌈A(10⁴ + δ)/10⁴⌉`; an outage longer than `cachedWindow` opens the grace window on recovery whether or not a poke saw Expired and when the recovery round is the first of a new aggregator phase, with `recoveredAt` after the outage and never after now | 1 h – 4 days of outage | Q-247, Q-248, Q-264, Q-272, Q-275, INV-055, INV-087 |
| HYP-43 | Zero borrow, `debtToCover = 0`, zero or whole-record removal and zero-unit repay with collateral revert; zero-debt repay returns 0 | — | Q-075, Q-153, Q-180, Q-217 |
| HYP-44 | One whole vault token ≈ $2 in all three decimal markets; exact mint and burn over cycles | — | Q-066 |
| HYP-45 | Largest-first allocation over up to 40 records; 14 NFTs over 3 markets in one account | — | Q-108, Q-194, Q-234 |
| HYP-46 | Unwinding in up to 10,000 pieces never returns more than at once | — | Q-061, Q-131, Q-254 |
| HYP-47 | 5,000 borrows and repays per run with interest, GHO and USDC: debt never below what was borrowed, total repaid ≥ total borrowed | 4 runs | Q-075, Q-153, Q-169 |
| HYP-48 | 300 pledge, fees, collect, withdraw cycles leave counters at 0; 20–120 small liquidations never seize more than `paid × maxBonus` + 1 unit each | — | Q-030, Q-060, Q-174 |
| HYP-84 | `effectiveSlippage(bNet, allowance)` is the largest `s ≤ allowance` with `bNet(10⁴ − s) ≥ 10⁸` and has no cost term (`SPEC-LIQ-002`, `SPEC-LIQ-003`); `payouts(V, D, R_f, avanaFeeShareBps)` splits `S` exactly into `A + kr + B`, keeps `A ≤ min(S, G)`, and `A` equals the oracle term `⌊G × share / 10⁴⌋` while `S` covers it; `B = max(0, S − G)` | `V` up to 1e28 wei, share 0–5,000 bps, `bNet` 9,000–12,000 | Q-256, Q-261, INV-036, INV-086 |
| HYP-85 | With the pool at the oracle-implied price, each leg's minimum asks for at most its own oracle value less the slippage, and the minimums sum to at most `minGho + n + U + ⌈2·c·10¹⁰ / 10^d⌉` while no leg minimum is clamped at 1, and at most `minGho + n + 2U + ⌊floorRoundingAllowanceGho / n⌋ + ⌈2·c·10¹⁰ / 10^d⌉` in every case, as `INV-083` and `SPEC-LIQ-018` state. The bound without the LP-price term failed (see [Finding](#finding), resolved) | 1e3–1e30 units, prices $0.05–$1 | Q-250, INV-083, SPEC-LIQ-018 |
| HYP-87 | The caller gap `max(0, D + φ − R − floorGap − K)` always closes settlement exactly (Q-397, replacing the budget's market sub-cap) | random amounts | Q-267, Q-397 |
| HYP-49 | Accounts with 2–3 markets and both debt assets after depegs to $0.05–$0.85 end within 40 calls healthy, debt-free, or with no collateral and the rest recorded as deficit | — | Q-060, Q-070, Q-166, Q-234 |
| HYP-51 | GHO at $1.006–$1.03 keeps the GHO market Live, valued at the ceiling, open for pledges and borrows | — | Q-177, Q-200, Q-275 |
| HYP-52 | Dust on LPVaultSwap, the LPVault, Collateralization, the proxy and the escrow never blocks repay, repay-all or withdrawal | 1 wei – 1e6 wei | Q-097, Q-124 |
| HYP-53 | Every HF < 1 account from $11 to $100k in either debt asset is liquidated; draws stay within the rounding bound. **Bound:** a debt worth less than one vault-token unit × bonus makes Aave size a 0-unit seizure, which reverts `NothingSeized` | $11–$100k | Q-085, Q-159, Q-198, Q-267 |
| HYP-54 | The health gate passes exactly at `max(1.00, optional hard floor, minHealthFactor)`; the hard floor is off by default and binds at 1.05 when set (Q-398); a faulty RiskModule leaves Aave's HF ≥ 1 | — | Q-229, Q-398, SPEC-CF-003 |
| HYP-55 | The slice serves only indebted accounts below 1.10, up to the restore amount, and books rescue units | — | Q-150, Q-157, SPEC-CAP-003 |
| HYP-56 | A disagreeing market serves its lower routes, is not seized and blocks new debt; the account's fresh market is liquidated; repay stays open; seizure resumes when the routes agree | — | Q-199, Q-208, Q-247 |
| HYP-57, HYP-58 | After a seizure no LPVaultSwap version settled, withdrawal, removal or liquidation reconciles it into the pending balance, every vault token stays backed, and `settlePending` by anyone funds only the GHO Coverage Spoke | 1–5 records | Q-201, Q-211, Q-236 |
| HYP-62 | Two partial-removal paths to the same remaining units book the same charge; the last exit clears exactly, also after a re-credit | up to 20 removals | Q-158, Q-174, Q-254 |
| HYP-63 | Outside the USD band borrowing stops, top-ups stay open, liquidation continues | — | Q-176, Q-195, Q-275 |
| HYP-64 | Third-party and racing repays in GHO and USDC: two repay-alls spend exactly the debt, the borrower is never debited | up to 1 h of interest | Q-212, Q-269 |
| HYP-65, HYP-66 | In-kind settlement is removed (Q-401); a keeper payout or Avana fee the debt token refuses, in either debt asset: the liquidation completes, the payout is escrowed in the PayoutEscrow and claimable in full | — | Q-214, Q-401, INV-061 |
| HYP-67 | Permissionless liquidations fund their own settlement gap (Q-397); with routes down they revert `NoRouteAvailable`; a call that fails is then settled by the keeper path | $11–$50k | Q-213, Q-397, INV-062 |
| HYP-68 | Deadlines from −1 h to +1 h and minimum payouts up to 10,000 GHO only make a liquidation revert; when it succeeds every amount equals the call without them | — | Q-216 |
| HYP-69 | With every token reverting on zero amounts, liquidations complete | — | Q-217 |
| HYP-72 | Repeated liquidations of underwater accounts each add at most `V(1 − 1/LB)` to the shortfall, and raise HF while HF ≥ LB × CF | prices down to $0.02 (below $0.05 the market fails and waits) | INV-076 |
| HYP-73 | No zero-risk profit loop: an actor with 1–6 wallets opening minimum-size accounts, sandwiching its own routes and self-liquidating as keeper or permissionless caller ends debt-free with holdings up by at most `n × (U + 1 GHO)` | — | Q-198, Q-256, Q-267, Q-276, Q-277, INV-077 |
| HYP-75 | A market that is Expired, disagreeing, breaker-tripped, Aave-paused, offboarding or without routes never blocks liquidation of the account's fresh market, nor repay or debt-free withdrawal from the failing market | — | Q-234, Q-247, Q-260, INV-075 |
| HYP-76 | Under Frozen, `Paused(General)`, `Paused(MintPathSuspect)`, a market or debt breaker, an address freeze or configuration drift, new pledges and borrowing stop while repay, fee collection, debt-free removal and withdrawal and liquidation run | — | Q-227, Q-241, Q-242, INV-067, INV-081 |
| HYP-77 | Rescue top-ups pass Frozen, `Paused(General)`, breakers and the address freeze, are refused under `Paused(MintPathSuspect)`, book every unit as rescue units, and cannot be borrowed against | — | Q-252, Q-253, Q-277, INV-082, INV-069 |
| HYP-78 | Partial removal pays the principal to the depositor by balance delta, charges release on the fixed basis, and only the depositor re-credits | — | Q-254, INV-088 |
| HYP-79 | Repay with collateral in GHO and USDC, with sandwiched routes: debt down, HF never down while debt remains, no fee or draw; when the routes are too far below the oracle it reverts | haircuts to 5% | Q-255, INV-089 |
| HYP-80 | Each on-chain breaker condition (pool share, issuer, coverage, deficit above 10,000 GHO) stops new borrowing; repay and liquidation continue; price drop, seizure surge and route failures are alerts only and never gate (Q-399) | — | Q-241, Q-399, SPEC-BRK-001…006 |
| HYP-81 | Address freeze: never the protected set, no keeper floor on a freeze (`Q-400`: freezing the last unfrozen keeper halts new borrowing), 20 per guardian per 24 h; a frozen wallet repays, collects fees and is liquidated, but cannot borrow, open an account or liquidate | — | Q-242, INV-085 |
| HYP-82 | A guardian's standby switch ends a disagreement on collateral and on the USDC debt price at once | — | Q-248, INV-087 |
| HYP-83 | Debt-asset flash and payout: a USDC liquidation with oversized `debtToCover` flash-borrows USDC at the Aave V3 premium, refused with `FlashFeeTooHigh` unless `φ × 10⁴ ≤ maxFlashFeeBps × F` and then funded by the caller; recovery, Avana's fee and the payout are in USDC, the leftover repays the flash loan and LPVaultSwap keeps no token; in the state machine every liquidation settles in its debt asset and a short or repriced flash source falls back to the caller-funded path | — | Q-235, Q-317, Q-335, Q-358, INV-070, INV-095 |
| HYP-86 | Shortfall top-ups keep full-size liquidations running when routes are below the floor, paid by the caller (Q-397); shortfall reports are alerts only and change no gate (Q-399, Q-401) | — | Q-251, Q-397, Q-399 |
| HYP-89 | After an orphan burn of any size, pledges and withdrawals keep working and keep the gap | — | Q-224, Q-257, INV-080 |
| HYP-91 | USDT fee switch, with USDT a pool token and GHO the debt: liquidation, pending settlement, removal and repay with collateral settle at the amounts received and the issuer breaker trips (a fee on a debt asset is refused by Aave V4's Hub instead, 2.11 `REQ-SWAP-123`); USDC pause stops new USDC exposure only; a third party repays a blocklisted borrower; a token calling back into Avana during `collect` or `decreaseLiquidity` meets `LockHeld` | fee 1–50 bps | Q-217, Q-241, Q-271, INV-054 |
| HYP-92 | Withdrawal cascades: 3–8 debt-free LPs exit one after another during a depeg while the lender withdraws and indebted accounts are liquidated; every exit succeeds and solvency per debt asset holds after each step | depegs to $0.30 | Q-227, Q-260, Q-278, INV-045, INV-074 |
| HYP-93 | One proxy per wallet per Spoke: two Spokes give two accounts with separate health factors and debt sets; vault tokens mint only to the Hub, the Adapter or a registered proxy and transfer only to those and LPVaultSwap | — | Q-224, Q-225, Q-239, Q-276, INV-063, INV-064, INV-066 |
| HYP-94 | Accounts with several reserves: a USDC rally lowers HF; a stale USDC price blocks new debt account-wide; debt-free is `borrowCount == 0` from Aave, after which withdrawal ignores offboarding, breakers and Paused | — | Q-233, Q-234, Q-238, Q-260, INV-072 |
| HYP-88 | Timelock: `normalDelay` ∈ [4, 5] days; enabled short selectors ⊆ the immutable allowlist; every executed operation waited its required delay and ran within 14 days of becoming ready; an operation with any call off the short list waited ≥ 4 days; restoring-only and role-change operations are cancelled only by the DAO canceller; admin roles held only by the timelock | 300 × 40 steps | Q-228, Q-259, Q-262, Q-263, INV-068, INV-090 |

Bound of HYP-53 in numbers: an account whose whole debt is smaller than one vault-token unit times the bonus (one unit of the d = 6 market is $0.000002) would be repaid for 0 collateral; LPVaultSwap's zero-seizure check refuses it. No value is at risk in such an account.

Solvency (HYP-70) is asserted in the profile whose caps follow the cap-sizing rule of `Q-249`: $100k per market with a $10k slice and $300k per token against 100,000 GHO and 100,000 USDC Coverage Spokes, one pool token falling at a time and USDC moving at most 4% up. Outside those assumptions (several tokens failing at once, debt-asset rallies beyond `debtStressRiseBps`, caps above the tail term) INV-074 is a sizing obligation of the DAO, not a property of the code, and the other profiles do not assert it.

## Finding

**The per-leg minimums can exceed the aggregate floor by more than `n + U` (Informational).** `INV-083` states that the sum of the per-leg minimums is at most `minGho + n + U`, and `SPEC-LIQ-018` gives the reason as "`Σ Vlegᵢ` equals `V` within one raw unit per leg" when the pool trades at the oracle-implied price. `V` is computed from the 8-decimal LP price `isqrt(4·v0·v1) − 1` (`SPEC-LIQ-004`, `SPEC-ORC-008`), which sits up to 2 units of 10⁻⁸ USD per whole vault token below the exact value, while each `Vlegᵢ` values the removed tokens directly. On a large seizure the difference exceeds one raw unit per leg.

Counterexample (`test_hyp85_leg_minimums_within_aggregate_floor`, pinned): DAI/USDC market (`d = 12`), DAI at $0.05034328, USDC at $0.05000075, pool at the oracle-implied price, `c = 3,414,711,693,649,457,640` units seized (3,414,712 whole tokens, `V = 342,643.88` GHO), `s = 1,833` bps, spacing 200. The two leg minimums sum to 279,836.302780237500851792 GHO; `minGho + n + U` is 279,836.259901008297603709 GHO; the excess is 42,879,229,203,248,083 wei (0.0429 GHO, 1.3 × 10⁻⁷ of the seizure). The effect is limited to rounding: every leg still asks for at most its own oracle value less `sLeg`, so an honest route passes, and the gap is far smaller than the slippage term.

Recommended change: in `INV-083` replace "the sum of the per-leg minimums is at most `minGho + n + U`" with "the sum of the per-leg minimums is at most `minGho + n + U + ⌈2·c·10¹⁰ / 10^d⌉`, the last term being the LP price's rounding of 2 units of 10⁻⁸ USD per whole vault token, in GHO wei"; in `SPEC-LIQ-018` replace "`Σ Vlegᵢ` equals `V` within one raw unit per leg, so `Σ minOutᵢ ≤ minGho + n + U`" with "`Σ Vlegᵢ` exceeds `V` by at most one raw unit per leg plus `⌈2·c·10¹⁰ / 10^d⌉` GHO wei of LP-price rounding, so `Σ minOutᵢ ≤ minGho + n + U + ⌈2·c·10¹⁰ / 10^d⌉`". `test_hyp85_leg_minimums_within_corrected_bound` checks that bound and holds.

**Status: resolved in spec (2026-11-10).** `INV-083` and `SPEC-LIQ-018` state `Σ minOutᵢ ≤ minGho + n + U + ⌈2·c·10¹⁰ / 10^d⌉` while no leg minimum is clamped at 1 and `≤ minGho + n + 2U + ⌊floorRoundingAllowanceGho / n⌋ + ⌈2·c·10¹⁰ / 10^d⌉` in every case (the clamped case is `FINDING-191`). `test_hyp85_leg_minimums_within_aggregate_floor` now checks that text and passes, pinned example included (0.0429 GHO over `minGho + n + U`, inside the 0.0683 GHO LP term). Mirrored as `FINDING-200`.

## Scope and limits

Three markets, four borrower wallets and up to two Borrow Spokes, 60 steps per state-machine run; one price per token for each route. Swap routes trade at Chainlink ∓ 0.3% into the debt asset, with haircuts standing for sandwiches and manipulated pools; route depth and MEV are covered by `simulation/`. Interest is linear per accrual as in Aave V4, at each debt asset's kinked-curve rate recomputed after every Hub action (`SPEC-HUB-007`; illustrative curves: GHO 550 / 360 / 5,000 bps at 90 %, USDC 0 / 650 / 4,000 bps at 92 %), with `liquidityFee = 0`. The TWAP's time-weighted liquidity is the pool's current in-range liquidity. Guardian, issuer and Aave actions are applied directly; their timelock timing is modelled in `model/timelock.py` and `quint/`. Formula-level proofs are in `z3/` (`MATH-*`); this folder checks that the flows built on those formulas keep the invariants over generated sequences. The model keys each borrower's proxy by (wallet, Spoke), as `proxyOf[depositor][spoke]` in `HYP-02`, so one modelled account can hold several markets; it therefore does not test the cross-market isolation of one proxy per (wallet, CDP Spoke, market) (`INV-064`). That isolation is checked by the Foundry per-market proxy tests (`TEST-190`, `TEST-271`) and the Certora rules `PROP-064` and `PROP-076`.

## Traceability rows

| Requirement | Statement | IDs | Status |
|---|---|---|---|
| Q-066 / Q-224 / Q-257 | Supply ≤ credited + pending; Adapter mint and burn; one-sided backing gap | HYP-01, HYP-02, HYP-03, HYP-89, HYP-93 | Holds |
| Q-068 / Q-120 / Q-224 | Vault tokens only with allowed holders | HYP-04, HYP-12, HYP-93 | Holds |
| Q-097 / Q-124 / Q-271 | No value created; zero deltas; amounts by balance delta; dust never blocks | HYP-06, HYP-24, HYP-25, HYP-52, HYP-74, HYP-91 | Holds |
| Q-018 / Q-229 / Q-253 | Health gate and rescue-excluded HF | HYP-13, HYP-20, HYP-54, HYP-77 | Holds |
| Q-081 / Q-128 / Q-234 / Q-238 / Q-275 | Borrow gates over every reserve; USD band | HYP-14, HYP-63, HYP-94 | Holds |
| Q-212 / Q-260 / Q-269 | Repay by any payer; exits read no registry; repay-all refund | HYP-16, HYP-17, HYP-18, HYP-60, HYP-64, HYP-95 | Holds |
| Q-227 / Q-241 / Q-242 | Pause state and reason, breakers, address freeze stop new activity only | HYP-76, HYP-80, HYP-81 | Holds |
| Q-247 / Q-248 / Q-264 / Q-272 | Gating per seized market; stress values; standby; grace start; phase rule | HYP-11, HYP-50, HYP-56, HYP-75, HYP-82, HYP-90 | Holds |
| Q-252 / Q-253 | Rescue top-ups and rescue units | HYP-55, HYP-77 | Holds |
| Q-254 | Partial removal and re-credit | HYP-62, HYP-78 | Holds |
| Q-255 | Repay with collateral | HYP-79 | Holds |
| Q-235 / Q-256 / Q-261 / Q-358 | Liquidation in the debt asset with a flash loan of that asset, fee from oracle value | HYP-29, HYP-30, HYP-83, HYP-84 | Holds |
| Q-250 / INV-083 | Per-leg minimum outputs | HYP-85 | Holds (the sum bound now includes the LP-price rounding; finding resolved in spec) |
| Q-251 | Shortfall top-up (automatic in-kind removed, Q-401) | HYP-29, HYP-86 | Holds |
| Q-236 / Q-267 | Per-asset coverage; caller-funded settlement gap (budget removed, Q-397) | HYP-08, HYP-31, HYP-33, HYP-38, HYP-87 | Holds |
| Q-201 / Q-211 | Reconcile on exit; pending proceeds to the GHO Coverage Spoke | HYP-57, HYP-58 | Holds |
| Q-085 / Q-159 / Q-198 | Recovery floor, rounding allowance | HYP-29, HYP-38, HYP-53 | Holds (HYP-53 bound: 0-unit seizures) |
| Q-213 / Q-214 / Q-216 / Q-217 | Permissionless path, escrow, deadline and minimum payout, zero amounts | HYP-65, HYP-66, HYP-67, HYP-68, HYP-69 | Holds |
| Q-228 / Q-262 / Q-263 | Timelock delays, short-delay allowlist, cancel rules | HYP-88 | Holds |
| Q-278 | Solvency per debt asset, conservative valuation, deficit bound, no zero-risk loop, GHO conservation, no contagion, cascades, oracle and token edge cases, multi-actor suite | HYP-70, HYP-71, HYP-72, HYP-73, HYP-74, HYP-75, HYP-90, HYP-91, HYP-92, HYP-96 | Holds |
