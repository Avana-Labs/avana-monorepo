# User simulation: run log

One entry per simulation run. Each new run appends an entry; earlier entries are never edited. Findings are tracked in the [findings register](../findings-register.md) as `SIM-GAP-01`…`SIM-GAP-12`, numbered as the gaps in [report.md](report.md) section 4.

The simulation exits 0 whenever it completes. Its invariant checks are protocol-level assertions after every step; the gaps are found by reading the outputs (refusals, reverts, liquidation counts, gas), not by a failing check.

## SIM-R1 — 2026-11-09 — reported run

| Item | Value |
|---|---|
| Date | 2026-11-09 (result files written 21:08–21:10) |
| What ran | The 1,000-agent, 90-day simulation in three variants (`base`, `mainnet-feeds`, `literal-repay-quote`) at the default seed, and the `base` variant at four more seeds |
| Commands | `spec/05-verification/.venv/bin/python audit/user-simulation/run_simulation.py` and `spec/05-verification/.venv/bin/python audit/user-simulation/run_simulation.py --extra-seeds 4` (from the repository root) |
| Tools | Python 3.9.6, standard library only (no numpy) |
| Seeds and bounds | Seed 20261109 (extra seeds 20261110…20261113); 90 days; 985 users, 3 approved keepers, 10 searchers, 2 attackers; six stress episodes on the same path in every run |
| Exit code | 0 |
| Findings produced | `SIM-GAP-01`…`SIM-GAP-12` |
| Spec state | Decisions `Q-001`…`Q-240` |
| Output | `results/summary-<variant>-<seed>.json` and `results/tables-<variant>-<seed>.md` |

Results per run (invariant checks are the 15 kinds listed in report section 3.6):

| Variant | Seed | Invariant checks | Violations | Liquidation calls | Summary sha256 (first 16) |
|---|---|---|---|---|---|
| `base` | 20261109 | 440,947 | 0 | 151 | `202f9f8bb7795922` |
| `mainnet-feeds` | 20261109 | 423,318 | 0 | 0 | `b241cb338ed88fd5` |
| `literal-repay-quote` | 20261109 | 437,404 | 0 | 161 | `471f4afc04407ddc` |
| `base` | 20261110 | 402,156 | 0 | 77 | `9d4d38ed943e1c57` |
| `base` | 20261111 | 429,262 | 0 | 91 | `9626daa0dd102acf` |
| `base` | 20261112 | 395,878 | 0 | 33 | `828cb60ce0af65a8` |
| `base` | 20261113 | 400,859 | 0 | 129 | `23fa9dc92c6ee0f8` |

The report's figure of 440,947 checks is the `base` run at seed 20261109; every other run has its own count, and all have 0 violations.

## SIM-R2 — 2026-11-09 — confirmation re-run

| Item | Value |
|---|---|
| Date | 2026-11-09, 22:00 EST |
| What ran | The `base` variant at the default seed, to confirm determinism and the reported counts |
| Command | `spec/05-verification/.venv/bin/python audit/user-simulation/run_simulation.py --only base` |
| Tools | Python 3.9.6, standard library only |
| Seeds and bounds | Seed 20261109; 90 days; population as in `SIM-R1` |
| Results | 440,947 invariant checks, 0 violations, 151 liquidation calls; sha256 `202f9f8bb7795922`, the fingerprint the report states. `results/summary-base-20261109.json` was rewritten byte-for-byte identical. |
| Exit code | 0 |
| Wall time | 35.0 s, run alongside the three formal-verification re-runs (the report gives about 25 s alone) |
| Findings produced | None new |
| Spec state | Decisions `Q-001`…`Q-240`. Decisions `Q-241`…`Q-278` were recorded in 4.4 by then but are not modelled. |

## SIM-R3 — 2026-11-10 — re-run against the final spec

| Item | Value |
|---|---|
| Date | 2026-11-10 |
| What ran | The simulation brought up to the final spec (report section 7.1) in the three variants at the default seed and the `base` variant at four more seeds, then the `mainnet-feeds` variant again after two fixes that act only in that variant, and the `base` variant once more to confirm determinism |
| Commands | `spec/05-verification/.venv/bin/python audit/user-simulation/run_simulation.py --extra-seeds 4 --jobs 7`; `spec/05-verification/.venv/bin/python audit/user-simulation/run_simulation.py --only mainnet-feeds`; `spec/05-verification/.venv/bin/python audit/user-simulation/run_simulation.py --only base --out <scratch directory>` (from the repository root) |
| Tools | Python 3.9.6, standard library only (no numpy); `multiprocessing` for `--jobs` |
| Seeds and bounds | Seed 20261109 (extra seeds 20261110…20261113); 90 days; 985 users, 3 approved keepers, 10 searchers, 2 attackers; the six stress episodes of `SIM-R1` plus a 30-hour stall of every DAI route from day 52.0 |
| Exit code | 0 for every command |
| Wall time | 3 min 29 s for the seven runs in parallel; 75 s for `mainnet-feeds` alone; 157 s for the confirmation run |
| Findings produced | `SIM-GAP-13` (Medium) and `SIM-GAP-14` (Low). `SIM-GAP-01`…`09`, `11`, `12` closed; `SIM-GAP-10` unchanged (accepted risk) |
| Spec state | Decisions `Q-001`…`Q-278` |
| Output | `results/final-spec/summary-<variant>-<seed>.json` and `results/final-spec/tables-<variant>-<seed>.md`; the files of `SIM-R1` stay in `results/` |

Results per run (invariant checks are the 23 kinds listed in report section 7.2):

| Variant | Seed | Invariant checks | Violations | Liquidation calls | Summary sha256 (first 16) |
|---|---|---|---|---|---|
| `base` | 20261109 | 514,318 | 3 (`SIM-GAP-14` check) | 88 | `3fcacfa76f23f648` |
| `mainnet-feeds` | 20261109 | 474,442 | 0 | 4 | `1c1d0182899b0a1f` |
| `literal-repay-quote` | 20261109 | 515,219 | 3 (`SIM-GAP-14` check) | 86 | `ce8a9884106091a5` |
| `base` | 20261110 | 501,751 | 3 (`SIM-GAP-14` check) | 87 | `9d3ec23ce1bf7602` |
| `base` | 20261111 | 495,259 | 3 (`SIM-GAP-14` check) | 83 | `e6e1f795183bcfe6` |
| `base` | 20261112 | 455,373 | 3 (`SIM-GAP-14` check) | 70 | `4103289748c21951` |
| `base` | 20261113 | 449,478 | 3 (`SIM-GAP-14` check) | 81 | `deff299915a949ae` |

The violations are the check "rescue top-up sized to restore `minOpeningHealthFactor` at the served price is admitted (`SPEC-CAP-003`, `REQ-RISK-026`)" at the three USDe/USDT probes (days 60.21, 60.25, 66.0); it stays failing until `SIM-GAP-14` is fixed in the spec. Two earlier `mainnet-feeds` outputs (`d2eaa465c1d97ecc` and `a58f40d0c319ef47`) were replaced by the run listed above after two fixes that act only in that variant: the guardian switches to a standby only when a primary is past its heartbeat (a 24-hour primary is otherwise paged every day), and the address-freeze probe skips its debt rows when the frozen wallet holds no debt. Neither changes a `base` path: the confirmation run of `base`, made after the first fix, printed `3fcacfa76f23f648` again, and the second fix only skips rows when the dust wallet has no debt, which never happens in `base`.

## SIM-R4 — 2026-11-10 — pool-share breaker at the final `SPEC-BRK-002`

| Item | Value |
|---|---|
| Date | 2026-11-10 |
| What ran | The `base` variant at the default seed, with the pool-share breaker brought up to the final `SPEC-BRK-002`: `POOL_SHARE` counts only while `q0 × q1 ≤ 10^16` on the uncapped quotes, and a token with no quote counts as at or below peg (`avana_sim/world.py` `at_or_below_peg`, `avana_sim/protocol.py` `market_breaker`) |
| Command | `spec/05-verification/.venv/bin/python audit/user-simulation/run_simulation.py --only base` (from the repository root) |
| Tools | Python 3.9.6, standard library only |
| Seeds and bounds | Seed 20261109; 90 days; population and episodes as in `SIM-R3` |
| Results | 514,318 invariant checks, 88 liquidation calls, summary sha256 `916f5dd5d76063b0`. Borrowing blocked by the pool-share breaker: GHO/USDC 0 hours during the GHO premium (44.8 hours in `SIM-R3`); USDC/USDT 72.3 hours and USDe/USDT 72.0 hours during the USDT depeg, as in `SIM-R3`; DAI/USDC 2.2 hours, plus 1.0 hour together with the manual trip of the DAI stall. 3 violations, all of the `SIM-GAP-14` check at the USDe/USDT probes, as in `SIM-R3` |
| Exit code | 0 |
| Wall time | 145.5 s |
| Findings produced | None new |
| Findings resolved | `SIM-GAP-13`: the GHO premium no longer trips the pool-share breaker, and the USDT depeg, the case the breaker exists for, still trips it |
| Spec state | Final spec, decisions `Q-001`…`Q-278`, with `SPEC-BRK-002`, `EMG-068`, `EMG-089` and `Q-241` as changed for `SIM-GAP-13` |
| Output | `results/final-spec/summary-base-20261109.json`, `results/final-spec/tables-base-20261109.md` |

## SIM-R5 — 2026-11-10 — restore amount at the final `SPEC-CAP-003`

| Item | Value |
|---|---|
| Date | 2026-11-10 |
| What ran | The `base` variant at the default seed, with the restore amount brought up to the final `SPEC-CAP-003`: `restoreBooked = usdToRestore × max(price8, stressFloorUsd) / served8`, `served8` the served price (`avana_sim/protocol.py` `pledge_check`), and the app sizing a rescue top-up as `usdToRestore` at the served price (`avana_sim/engine.py`). Includes the `SIM-R4` pool-share change. |
| Command | `spec/05-verification/.venv/bin/python audit/user-simulation/run_simulation.py --only base --out <scratch directory>` (from the repository root); the two output files were then copied to `results/final-spec/` |
| Tools | Python 3.9.6, standard library only |
| Seeds and bounds | Seed 20261109; 90 days; population and episodes as in `SIM-R3` |
| Results | 514,318 invariant checks, 0 violations, 88 liquidation calls, summary sha256 `b32c4c5cdc21307b`. The check "rescue top-up sized to restore `minOpeningHealthFactor` at the served price is admitted (`SPEC-CAP-003`, `REQ-RISK-026`)" ran 15 times and passed every time, including the three USDe/USDT probes (days 60.21, 60.25, 66.0) that failed in `SIM-R3` and `SIM-R4`. 4 rescue top-ups were sized to the full restore amount, all 4 while the served price was below the accepted price, and all 4 were admitted. The pool-share breaker figures are those of `SIM-R4`. |
| Exit code | 0 |
| Wall time | 142 s |
| Findings produced | None new |
| Findings resolved | `SIM-GAP-14` |
| Spec state | Final spec, decisions `Q-001`…`Q-278`, with `SPEC-CAP-003` and `REQ-RISK-026` as changed for `SIM-GAP-14` |
| Output | `results/final-spec/summary-base-20261109.json`, `results/final-spec/tables-base-20261109.md` (replacing the `SIM-R4` files of the same names) |


## SIM-R6 — 2026-11-10 — deployment topologies, first grid (superseded)

| Item | Value |
|---|---|
| Date | 2026-11-10 |
| What ran | The topology comparison of [topology-options.md](../design-review/topology-options.md): T1, T2 and T3 in 8 scenarios (T3 also in `eth-crash`), 40 days each, 6 seeds |
| Command | `spec/05-verification/.venv/bin/python audit/user-simulation/run_simulation.py --topology --seeds 6 --jobs 8` (from the repository root) |
| Tools | Python 3.9.6, standard library only; `multiprocessing` |
| Seeds and bounds | Seeds 20261109…20261114; 150 runs |
| Results | 0 invariant violations. Superseded: in `dai-failure`, accounts left with dust collateral and debt were "liquidated" for zero every keeper scan (up to 34,607 calls in one run) and their debt was never written off, so liquidation counts were inflated and bad debt understated |
| Exit code | 0 |
| Wall time | 8 min 4 s |
| Findings produced | The dust-liquidation loop, fixed in `avana_sim/engine.py` `_routed` (a repay or seizure below 10⁻⁶ USD is `NothingToRepay`) |
| Output | Replaced by `SIM-R7` |

## SIM-R7 — 2026-11-10 — deployment topologies (reported)

| Item | Value |
|---|---|
| Date | 2026-11-10 |
| What ran | The topology comparison of [topology-options.md](../design-review/topology-options.md) after the dust fix: T1 (one market per Spoke), T2 (several markets per Spoke) and T3 (T2 plus a Volatile-Hub Spoke borrowing USDC from the Stable Hub) in `calm`, `dai-depeg`, `usdt-depeg`, `pool-crunch`, `two-pool`, `oracle-stale`, `dai-crash` and `dai-failure`, and T3 in `eth-crash`; 40 days per run, shock on day 25. Then the `base` variant once more to confirm the topology option leaves the base path unchanged |
| Commands | `spec/05-verification/.venv/bin/python audit/user-simulation/run_simulation.py --topology --seeds 5 --jobs 8`; `spec/05-verification/.venv/bin/python audit/user-simulation/run_simulation.py --only base --out <scratch directory>` (from the repository root) |
| Tools | Python 3.9.6, standard library only; `multiprocessing` |
| Seeds and bounds | Seeds 20261109…20261113; 125 runs; 985 people on three stable markets (USDC/USDT and DAI/USDC on chain A, USDC/USDT-B on chain B), plus 150 WETH/USDC LPs in T3; no attackers, probes or pauses |
| Results | 0 invariant violations in 125 runs (2,509,764 to 2,527,680 checks per scenario). No liquidation or bad debt in any topology in `calm`, `dai-depeg`, `usdt-depeg`, `pool-crunch` and `two-pool`. `oracle-stale`: 0 accounts liquidated in T1, 11.4 (0–28) in T2, every one through a market healthy on its own. `dai-failure`: bad debt $8.1k (T1), $6.7k (T2), $9.2k (T3), 0.22–0.31% of the $3M Hub reserve, all within the First-Loss Reserve. `DrawCapExceeded` refusals before the shock: 29 (T1), 4 (T2), 116 (T3). Mean over seeds per metric in `results/topology/aggregate.md`. Base confirmation: 514,318 checks, 0 violations, 88 liquidation calls, sha256 `b32c4c5cdc21307b`, as in `SIM-R5` |
| Exit code | 0 for both commands |
| Wall time | 12 min 40 s for the grid (3,079 CPU-seconds; the machine was also running a Quint verification job, so about 6.5 min on 8 idle cores); 85 s for the base confirmation |
| Findings produced | None in the register. Design questions for the topology choice are listed in [topology-options.md](../design-review/topology-options.md#what-t2-needs) |
| Spec state | Final spec, decisions `Q-001`…`Q-278`; spec pages unchanged |
| Output | `results/topology/summary-<topology>-<scenario>-<seed>.json`, `results/topology/aggregate.md`, `results/topology/aggregate.json` (sha256 `e1f941bd50ace096`) |

## SIM-R8 — 2026-11-10 — base confirmation after the AMM-neutral spec rewrite

| Item | Value |
|---|---|
| Date | 2026-11-10 |
| What ran | The `base` variant at the default seed, after the spec was rewritten for the AMM-neutral design (one immutable PositionProxy per wallet × CDP Spoke × market, one ledger per chain, Hub-keyed caps, the Aave V3 flash source). No file under `avana_sim/` changed |
| Command | `spec/05-verification/.venv/bin/python audit/user-simulation/run_simulation.py --only base --out <scratch directory>` (from the repository root) |
| Tools | Python 3.9.6, standard library only |
| Seeds and bounds | Seed 20261109; 90 days; population and episodes as in `SIM-R3` |
| Results | 514,318 invariant checks, 0 violations, 88 liquidation calls, summary sha256 `b32c4c5cdc21307b` (full digest `b32c4c5cdc21307b6ee37a4712a817a252853d95df030033d29dffa7a3c40fd7`), byte-for-byte equal to `results/final-spec/summary-base-20261109.json` of `SIM-R5` |
| Exit code | 0 |
| Wall time | 81 CPU-seconds; 4,272 s elapsed, because the machine was running the formal-verification suites at the same time |
| Findings produced | None in the register |
| Spec state | AMM-neutral design, decisions `Q-001`…`Q-380` |
| Output | Scratch directory only; `results/final-spec/` unchanged |

Why the fingerprint did not change: the fingerprint is a function of the simulation code, the seed and the parameters, and none of them changed. The topology change lives in the spec, not in the `base` path. `base` runs without `--topology`, so `Protocol` has no Spoke map: every wallet has one account on one Spoke, and each of the 85 `multi_market` people (2 or 3 markets each) holds all of them in that one account. That is the account scope the AMM-neutral design removes. The design's scope, one account per wallet and market, is topology `T1` of `SIM-R7`, where no account was liquidated through a healthy market. The `base` variant therefore still checks the superseded account scope for people with more than one market, and it does not model the Aave V3 flash source (premium, `maxFlashLoan` and the caller-funded fallback when liquidity is short). Bringing `base` to per-market accounts would change its fingerprint and needs a new run.

## SIM-R9 — 2026-11-10 — `base` at the decided account scope, flash source and minimum debt

| Item | Value |
|---|---|
| Date | 2026-11-10 |
| What ran | The `base` variant at the default seed after the model was brought to the decided design (report section 7.6): one account per wallet and market (`avana_sim/engine.py` `_split` with a per-market key, the split the topology runs use per Spoke); routed liquidations flash-borrow the debt asset through `IFlashSource` at 5 bps (`maxFlashFeeBps` = 10), convert the seized legs into the debt asset and pay `A`, `Kr` and `B` in it (`_routed`, `LIQ-027`, `LIQ-031`, `SPEC-LIQ-010`, `SPEC-LIQ-022`); repay with collateral sizes `x = Vnet / (1 + maxFlashFeeBps)` and repays the loan with its premium (`avana_sim/protocol.py` `deleverage_quote`); `minDebtUsd` = $2,000 on every borrow (`borrow_check`, `SPEC-CAP-009`, `REQ-RISK-077`); liquidation gas 1,550,000 for one record (`SPEC-CHAIN-001`) plus 290,000 per further record (`avana_sim/params.py`). Probe accounts hold $20,000 so their debt reaches the minimum. A first run with the same changes, in which a person refused by the minimum tried again at every check (`37b9b3fa0bc69457`, 532,028 checks, 0 violations, 27 liquidation calls), was replaced: the app shows the minimum and the person stays debt-free |
| Command | `spec/05-verification/.venv/bin/python audit/user-simulation/run_simulation.py --only base` (from the repository root), then the same command with `--out <scratch directory>` to confirm determinism |
| Tools | Python 3.9.6, standard library only |
| Seeds and bounds | Seed 20261109; 90 days; population and episodes as in `SIM-R3` |
| Results | 501,748 invariant checks (27 kinds), 0 violations, 18 liquidation calls on 10 accounts, summary sha256 `cd79a767842cfe9a` (full digest `cd79a767842cfe9a66fa984c15f778a6215f92340a758b3c36905eef5ba80661`); the confirmation run printed the same digest. Against `SIM-R5`/`SIM-R8` (`b32c4c5cdc21307b`): liquidation calls 88 → 18, accounts liquidated 77 → 10, bad debt $0 → $0, settlement-budget draws $0.69 → $0, supplier loss $0 → $0, bonus paid by borrowers $1,043 → $184, keeper loss reimbursed $57,848 → $20,535. All 18 calls were flash-funded (premium $4.34); keeper reward $44, Avana fee $36, borrower surplus $0 |
| Exit code | 0 for both commands |
| Wall time | 22.5 s; 20.9 s for the confirmation |
| Findings produced | None in the register; observations in report section 7.6 |
| Spec state | AMM-neutral design, decisions `Q-001`…`Q-380` |
| Output | `results/final-spec/summary-base-20261109.json`, `results/final-spec/tables-base-20261109.md` (replacing the `SIM-R5` files of the same names) |

Why the fingerprint changed: `SIM-R8` showed that the fingerprint depends only on the simulation code, the seed and the parameters, and that `base` still modelled the superseded account scope and no flash source. This run changes the code in five ways, each of which moves the event path:

- **Accounts.** The 85 `multi_market` people now hold 2 or 3 accounts each. A price fall in one market no longer lowers the health factor of their other markets: the 11 liquidations of multi-market accounts on a market other than the failed one, and all 5 GHO/USDC and 3 USDC/USDT liquidations, are gone. Each account also gets its own check-in events, which changes the random draws of every later event.
- **Minimum debt.** 233 people whose planned borrow would leave less than $2,000 of debt stay debt-free (borrowers 438 → 201, every `small` person among the 23 who borrowed before). The 40 dust accounts of the attacker can no longer borrow, so their 40 liquidation calls are gone. Fewer, larger accounts carry debt, so fewer accounts reach health factor 1 in the USDe crash.
- **Flash source and payout.** The premium raises the debt cost to `D + φD` and lowers the effective slippage by 5 bps; there is no GHO buy leg, so the USDC fee of 0.2% on the buy leg is gone and a pool leg in the debt asset is not swapped. This changes which calls need a caller shortfall (30 → 16) and every payout figure.
- **Gas.** A liquidation costs 1,550,000 gas instead of 1,035,000 for one record, so each keeper call loses more; the total reimbursed is lower only because there are fewer calls.
- **Checks.** Six new invariant kinds (debt-asset conservation, `minOut` floor, `A + Kr + B = Y`, no `B` with a shortfall or budget draw, flash premium within `maxFlashFeeBps` on liquidation and on repay with collateral) replace the GHO conservation and `minGho` floor checks, so the set and count of checks changed.

The variants `mainnet-feeds` and `literal-repay-quote`, the extra base seeds and the topology grid of `SIM-R7` share this code and were not re-run; re-running them would print new fingerprints.

## SIM-R10 — 2026-11-10 — `base` with no minimum debt

| Item | Value |
|---|---|
| Date | 2026-11-10 |
| What ran | The `base` variant at the default seed after the owner's decision `Q-381`: Avana has no minimum debt on any chain, and Avana's own keepers liquidate every account and pay the gas. Two code changes: the `minDebtUsd` refusal is removed from `borrow_check` (`avana_sim/protocol.py`) and from the app's pre-check (`avana_sim/engine.py`), with `MIN_DEBT_USD` and the `below_min_debt` frustration removed (`avana_sim/params.py`, `avana_sim/metrics.py`); liquidation gas follows the `SPEC-CHAIN-001` gas units model `G(n) = 1,310,000 + 240,000 × n` for an account with `n` records (was 1,260,000 + 290,000 × min(n, 3); `G(1) = 1,550,000` in both) |
| Command | `spec/05-verification/.venv/bin/python audit/user-simulation/run_simulation.py --only base` (from the repository root), then the same command with `--out <scratch directory>` to confirm determinism |
| Tools | Python 3.9.6, standard library only |
| Seeds and bounds | Seed 20261109; 90 days; population and episodes as in `SIM-R3` |
| Results | 559,561 invariant checks (27 kinds), 0 violations, 101 liquidation calls on 86 accounts, summary sha256 `b42224e0f720442e` (full digest `b42224e0f720442e63283e41c15ee29b4dbdb2aabc6a92aad48e541b6d6ab886`); the confirmation run printed the same digest. Against `SIM-R9` (`cd79a767842cfe9a`): people who borrow 201 → 483, liquidation calls 18 → 101 (40 of them on the attacker's dust accounts), accounts liquidated 10 → 86, bad debt $0 → $0, supplier loss $0 → $0, settlement-budget draws $0 → $0.18, bonus paid by borrowers $184 → $684, Avana fee $36 → $133, keeper reward $44 → $156, borrower surplus $0 → $0, flash-funded calls 18 → 101 (premium $16), caller shortfall top-ups 16 → 57 calls ($412), keeper loss after gas, now Avana's own keeper cost, $20,535 → $116,799 (of which $47,662 on the 40 dust-attack calls; largest single call $1,703 of gas) |
| Exit code | 0 for both commands |
| Wall time | 32.8 s; 32.0 s for the confirmation |
| Findings produced | None in the register. The dust-account attack is back: with no minimum, 40 dust accounts borrow and are liquidated at Avana's gas cost. Solvency is unaffected (no bad debt, no supplier loss); the cost is Avana's keeper budget |
| Spec state | AMM-neutral design, decisions `Q-001`…`Q-381` |
| Output | `results/final-spec/summary-base-20261109.json`, `results/final-spec/tables-base-20261109.md` (replacing the `SIM-R9` files of the same names) |

Why the fingerprint changed: the code changed in the two ways above. Without the minimum, the 233 people `SIM-R9` stopped now borrow, which adds borrow, repay and check-in events and moves every later random draw; the attacker's 40 dust accounts borrow again and are liquidated in the USDe crash. The gas model changes the gas of every call with more than one record. The variants `mainnet-feeds` and `literal-repay-quote`, the extra base seeds and the topology grid share this code and were not re-run.


## SIM-R11 — 2026-11-10 — `base` at current mainnet gas prices

| Item | Value |
|---|---|
| Date | 2026-11-10 |
| What ran | The `base` variant at the default seed after the gas price path was brought to current mainnet levels. Source: the Etherscan gas tracker at 2026-11-10 16:19 UTC (base fee, Standard and Fast 0.939 gwei; Rapid 1.139 gwei; a 21,000-gas transfer at $0.041, which implies ETH at about $2,080; a swap at $0.70; the week's heatmap mostly low with brief peaks). The gas path is now the parameter `GAS_PRICE` in `avana_sim/params.py`: calm base 0.1–1.2 gwei with the same daily sine shape and log-normal noise (σ = 0.25); floors of 5 gwei on the USDT depeg (day 30.0–30.5) and on a scenario shock (8 gwei with an ETH drop), 30 gwei on the worst USDe crash half-day (day 60.0–60.5), 10 gwei on the next half-day, 4 gwei on day 75.25–75.5. `ETH_USD` = 2,080 (was 3,000). Congestion, which applies `FEED_DELAY_CONGESTED` to Chainlink rounds and the longer inclusion delay, is now `GAS_CONGESTION_MULT` × `base_hi` = 4 × 1.2 = 4.8 gwei instead of a fixed 70 gwei; on this seed only days 30.0–30.5 and 60.0–61.0 are congested, as before (calm maximum 2.99 gwei; the day-75 spike stays below the threshold, as its 60 gwei was below 70). The summary gains `total_gas` and `dust_attack_gas` under `liquidations` (`avana_sim/report.py`), and the `gas_exceeds_value` cause text states the new costs (`avana_sim/metrics.py`) |
| Command | `spec/05-verification/.venv/bin/python audit/user-simulation/run_simulation.py --only base` (from the repository root), then the same command with `--out <scratch directory>` to confirm determinism |
| Tools | Python 3.9.6, standard library only |
| Seeds and bounds | Seed 20261109; 90 days; population and episodes as in `SIM-R3` |
| Results | 546,706 invariant checks (27 kinds), 0 violations, 99 liquidation calls on 86 accounts, summary sha256 `751619709834af63` (full digest `751619709834af639eb70075de905b17812b3757de3bfa60e682fd994ee211fa`); the confirmation run printed the same digest. Against `SIM-R10` (`b42224e0f720442e`): people who borrow 483 → 485, liquidation calls 101 → 99 (40 of them on the attacker's dust accounts, unchanged), bad debt $0 → $0, supplier loss $0 → $0, settlement-budget draws $0.18 → $0.48, bonus paid by borrowers $684 → $689, Avana fee $133 → $135, keeper reward $156 → $181, caller shortfall top-ups 57 calls ($412) → 53 calls ($391), keeper loss after gas (Avana's own keeper cost) $116,799 → $9,762. Avana keeper gas: $9,552 in total over 99 calls, $96 per liquidation on average (largest single call $127); $3,869 (40.5%) on the 40 dust-attack calls ($97 each, all at 30 gwei in the USDe crash) and $5,683 on the 59 other calls ($96 each). Users who found gas above the value they could borrow (`gas_exceeds_value`): 3 |
| Exit code | 0 for both commands |
| Wall time | 40.7 s; 40.7 s for the confirmation |
| Findings produced | None in the register. The dust-account attack still costs Avana gas, but about 12 times less than in `SIM-R10`: keeper loss after gas on calls repaying under $100 is $4,094 (43 calls) against $47,662 |
| Spec state | AMM-neutral design, decisions `Q-001`…`Q-381` |
| Output | `results/final-spec/summary-base-20261109.json`, `results/final-spec/tables-base-20261109.md` (replacing the `SIM-R10` files of the same names) |

Why the fingerprint changed: every gas cost in the run is priced from the gas path, and the path and `ETH_USD` changed. Gas costs gate user decisions (the break-even warning before a pledge, whether collecting fees is worth it, whether a permissionless liquidation pays), so some people act differently and every later random draw moves. The 14–22 gwei base of `SIM-R3`…`SIM-R10` was about 15 to 30 times the current level and its 250 gwei crash peak about 8 times; with ETH at $3,000 instead of $2,080, the keeper cost of those runs was about 12 times the cost at current prices. The variants `mainnet-feeds` and `literal-repay-quote`, the extra base seeds and the topology grid share this code and were not re-run.

## SIM-R12 — 2026-11-10 — `base` after the parameter decisions `Q-395`…`Q-401`

| Item | Value |
|---|---|
| Date | 2026-11-10 |
| What ran | The `base` variant at the default seed after the removed mechanisms left the parameters and the engine (`avana_sim/params.py`, `protocol.py`, `engine.py`, `world.py`, `report.py`). No SettlementBudget (`Q-397`): a rounding gap at final settlement is paid by the keeper as part of its shortfall top-up, within `maxShortfallBps`, and the budget parameters, draws and report lines are gone. No in-kind settlement (`Q-401`): the governance and automatic in-kind openings, `inKindAutoDelay`, `inKindExpiry` and the in-kind liquidation mode are gone; a failed keeper attempt only counts toward the route-failure alert. No on-chain health floors (`Q-398`): `minOpeningHealthFactor` and `PROXY_HEALTH_FACTOR_FLOOR` are replaced by Aave's 1.00 and an optional per-market hard floor, off (0); the app's max button borrows the Lens recommended amount at HF 1.10, and a rescue top-up restores HF 1.10. Breakers (`Q-399`): price drop, seizure and route failures are alerts that block nothing, there is no cooldown, the concentration gate trips when Avana's share of a pool exceeds `poolShareMaxBps` (10%, no peg condition) and `breakerDeficitMax` is 10,000 GHO. `keeperFloor` = 1, `MAX_KEEPERS` = 32 (`Q-400`); new borrowing halts only at 0 active keepers. `keeperMinRepay` is removed (`Q-395`). The model had no idle-collateral mechanism, so `Q-396` changes nothing in it |
| Command | `spec/05-verification/.venv/bin/python audit/user-simulation/run_simulation.py --only base` (from the repository root) |
| Tools | Python 3.9.6, standard library only |
| Seeds and bounds | Seed 20261109; 90 days; population and episodes as in `SIM-R3` |
| Results | 572,608 invariant checks (27 kinds), 0 violations, 98 liquidation calls on 84 accounts, summary sha256 `eb8721c3196683b3` (full digest `eb8721c3196683b349b2b695d3fb26b9a9406a769a0e8a1d2bc07b4f1fa70484`). Against `SIM-R11` (`751619709834af63`): liquidation calls 99 → 98 (40 on the attacker's dust accounts, unchanged), bad debt $0 → $0, bonus paid by borrowers $689 → $557, Avana fee $135 → $108, keeper reward $181 → $129, caller shortfall top-ups 53 calls ($391) → 55 calls ($319, now including the rounding gaps a budget draw used to cover), keeper loss after gas $9,762 → $9,498, no monitoring alert fired. The concentration gate, now without the peg condition, blocked borrowing for 72.7 h on USDC/USDT and 72.3 h on USDe/USDT during the USDT depeg, 45.0 h on GHO/USDC during the GHO premium and 3.5 h on DAI/USDC |
| Exit code | 0 |
| Wall time | 29.4 s |
| Findings produced | None in the register |
| Spec state | AMM-neutral design, decisions `Q-001`…`Q-402` |
| Output | `results/final-spec/summary-base-20261109.json`, `results/final-spec/tables-base-20261109.md` (replacing the `SIM-R11` files of the same names) |

Why the fingerprint changed: the max-button borrowers now borrow the Lens recommended amount, the health gates of borrow and withdrawal-with-debt test 1.00 instead of 1.10, the concentration gate trips on share alone, and the settlement path no longer draws on a budget. Each of these changes which actions pass, so later random draws move. The variants `mainnet-feeds` and `literal-repay-quote`, the extra base seeds and the topology grid share this code and were not re-run.
