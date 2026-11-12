# Governance timing models (MATH-GOV)

Z3 models of the AvanaTimelock's delays and windows, the MarketRegistry's market-count limit, the delay floor that protects the exit window, the short-delay allowlist, cancel rights with the role-change and restoring marks, the application pause state and its reasons, the keeper floor, and the bounds governance can change without stopping liquidation ([2.15](../../../02-contracts/15-governance-and-timelock.md)). Every `SPEC-GOV-001…015` formula is cited by at least one check here; the page's worked examples are recomputed in [`../../sympy/sym09_governance_timing_examples.py`](../../sympy/sym09_governance_timing_examples.py).

Run one script with `../../.venv/bin/python <file>.py`, or every model with `../../run_all.sh`. Each check asserts the negation of a property and prints `PROVED` (the negation is unsat), `COUNTEREXAMPLE` (the model is printed) or `TIMEOUT`; the script exits 1 only when a result differs from the one recorded beside the check. Every check carries a `# MATH-GOV-NN verifies: …` tag that `../../trace.py` reads.

## What is modelled

Integer seconds (`block.timestamp`), no rounding. Batches of up to 6 calls, each with a payload length and a short-list flag; state sequences of up to 4 calls (5 for allowlist changes); every subset of the guardian roles.

| Rule | Final formula | Source |
|---|---|---|
| Constants | `SHORT_DELAY = 43,200`; `MIN_NORMAL_DELAY = 345,600`; `MAX_DELAY = 432,000`; `GRACE_PERIOD = 1,209,600`; launch `normalDelay = 432,000` | `REQ-ACCESS-140` |
| Required delay | `SHORT_DELAY` iff `n ≥ 1` and every call has a 4-byte selector whose `(target, selector)` is on the short-delay list; else `normalDelay` | `SPEC-GOV-001` |
| Window | executable iff `readyAt ≤ t < readyAt + GRACE_PERIOD`, `readyAt = t_s + delay`; expired from `readyAt + GRACE_PERIOD`; clean-up only when expired | `SPEC-GOV-002`, `SPEC-GOV-013` |
| Delay change | `MIN_NORMAL_DELAY ≤ newDelay ≤ MAX_DELAY`, waits the old delay | `SPEC-GOV-003`, `SPEC-GOV-012` |
| Pause state | `None`, `Frozen`, `Paused(General)`, `Paused(MintPathSuspect)`; reason `None` iff not paused; `pause(r)` needs `r ≠ ρ` | `SPEC-GOV-004`, `REQ-ACCESS-072…074`, `REQ-ACCESS-164` |
| Cancel | `CANCELLER_ROLE ∧ (¬roleChange ∧ ¬restoring ∨ DAO_CANCELLER_ROLE)`; both marks are every-call marks; the DAO-only cancel set is `restoreRoute`, `useStandbyRoute`, `unfreezeAddress` (MarketRegistry) and `addKeeper` (LPVaultSwap), keyed by `(target, selector)` only | `SPEC-GOV-005`, `REQ-ACCESS-156` |
| Keeper floor | `removeKeeper` only if active keepers after it `≥ keeperFloor = 1`; `addKeeper` only while approved keepers `< MAX_KEEPERS = 32`; `freezeAddress` is never floor-checked and may reach 0 active keepers, at which new borrowing halts on the chain | `SPEC-GOV-008` |
| Tighten and loosen | tighten strictly safer within hard and liveness bounds; loosen one step (`≤ 0.03e18`, `new·10^4 ≤ old·15,000`, `≤ 25` bps) at most once per `normalDelay` per key | `SPEC-GOV-009`, `SPEC-GOV-011` |
| No in-kind window | no governance-timed settlement state exists (`Q-401`); a payout `x` whose transfer fails is credited to its payee in the PayoutEscrow (payout escrow), `credited = x` | `SPEC-GOV-010` |
| Exit window | exit guaranteed iff `r + 12·(k + 1) ≤ W`; at the floor `k_max = ⌊(MIN_NORMAL_DELAY − r)/12⌋ − 1 = 7,199` for `r = 259,200` | `SPEC-GOV-014`, `SPEC-GOV-015` |
| Market-count limit | new market `id = c + 1` accepted only if `id ≤ N = MAX_MARKET_COUNT` (then `c' = c + 1`); relisting `1 ≤ id ≤ c`, `c' = c`; the ParameterStore re-check walks `1 … c`, gas `g(c) = a + b·c`, `N_max = ⌊(cap − a)/b⌋` | `REQ-MREG-034`, `REQ-MREG-030`, `REQ-PSTORE-009` |
| Allowlist | `setShortDelaySelector(x, true)` only for `x ∈ SHORT_ELIGIBLE`, which holds no role, upgrade, beacon, initializer or timelock pair; at launch it is every ParameterStore `tighten*` selector (including `tightenHardHealthFloor`, `tightenGateRecoverySeconds` and `tightenPoolShareMaxBps`), the MarketRegistry stops and route restores, and `removeKeeper` | `REQ-ACCESS-142`, `REQ-ACCESS-152` |

## Properties


### `gv01_timelock_timing.py`

| ID | Statement | Verifies | Assumptions / bounds | Result |
|---|---|---|---|---|
| `MATH-GOV-01` | requiredDelay is SHORT_DELAY only when every call is short-listed with a 4-byte selector, else normalDelay (a short payload or an empty batch takes normalDelay); always in [SHORT, MAX] | `SPEC-GOV-001`, `REQ-ACCESS-141` | batches of up to 6 calls | PROVED |
| `MATH-GOV-02` | an operation executes only in [t_s + requiredDelay, t_s + d + GRACE): never early, never after grace | `SPEC-GOV-002`, `REQ-ACCESS-118` | batches of up to 6 calls | PROVED |
| `MATH-GOV-03` | from scheduling a delay cut to the first operation under the new delay takes >= old + new >= 2 x MIN_NORMAL_DELAY (8 days) | `SPEC-GOV-003`, `SPEC-GOV-015`, `REQ-ACCESS-029` | integers (seconds) | PROVED |
| `MATH-GOV-04` | executable and expired are exclusive, and a ready operation that is not executable is expired | `SPEC-GOV-013`, `SPEC-GOV-002`, `REQ-ACCESS-126` | batches of up to 6 calls | PROVED |
| `MATH-GOV-05` | launch normal delay 432,000 s: exit fits for any k <= 14,399 NFTs and reaction r <= 3 days | `SPEC-GOV-014`, `REQ-ACCESS-148` | k <= 14,399, r <= 259,200 | PROVED |
| `MATH-GOV-06` | wrong reading: if an upgrade could run at SHORT_DELAY, a 3-day reaction time could not exit first (deliberate counterexample) | `SPEC-GOV-014`, `REQ-ACCESS-142` | k <= 10 | COUNTEREXAMPLE (deliberate) |
| `MATH-GOV-07` | a key holding only APPLICATION_FREEZE_GUARDIAN never returns Frozen or Paused to None and never changes a pause reason in 4 calls | `SPEC-GOV-004`, `REQ-ACCESS-086`, `REQ-ACCESS-124`, `REQ-ACCESS-122` | 4-call sequences, every role subset | PROVED |
| `MATH-GOV-07b` | over 4 calls by any caller the reason is None exactly when the state is not Paused | `SPEC-GOV-004`, `REQ-ACCESS-086`, `REQ-ACCESS-124`, `REQ-ACCESS-122` | 4-call sequences, every role subset | PROVED |
| `MATH-GOV-08` | repay, fees, debt-free withdrawal and removal, liquidation, pending settlement and zero-credit release are open in None, Frozen, Paused(General) and Paused(MintPathSuspect) | `SPEC-GOV-004`, `REQ-ACCESS-068`, `REQ-ACCESS-072`, `REQ-ACCESS-073`, `REQ-ACCESS-074`, `REQ-ACCESS-164` | every state and reason | PROVED |
| `MATH-GOV-08b` | a rescue top-up is open under Paused(General) and Frozen, and no pledge of any kind (so no mint) is open under Paused(MintPathSuspect) | `SPEC-GOV-004`, `REQ-ACCESS-068`, `REQ-ACCESS-072`, `REQ-ACCESS-073`, `REQ-ACCESS-074`, `REQ-ACCESS-164` | every state and reason | PROVED |
| `MATH-GOV-09` | wrong reading (any-call marking): one no-op grantRole shields a malicious upgrade batch from every non-DAO canceller (deliberate counterexample) | `SPEC-GOV-005`, `REQ-ACCESS-143` | batches of up to 6 calls | COUNTEREXAMPLE (deliberate) |
| `MATH-GOV-10` | every-call marking: any batch with a call that is neither a role call nor DAO-only is cancellable by every canceller; a pure role-change or pure restoring batch only with DAO_CANCELLER_ROLE | `SPEC-GOV-005`, `SPEC-GOV-006`, `REQ-ACCESS-019`, `REQ-ACCESS-143`, `REQ-ACCESS-156` | batches of up to 6 calls | PROVED |
| `MATH-GOV-11` | 4 tighten executions: value never rises and never falls below max(hard bound, liveness bound) | `SPEC-GOV-011`, `SPEC-GOV-009`, `REQ-ACCESS-120` | 4 executions | PROVED |
| `MATH-GOV-12` | 4 keeper removals, freezes, unfreezes and additions: a removal never leaves fewer than keeperFloor = 1 active keeper, the approved list never exceeds MAX_KEEPERS = 32, and new borrowing is open iff at least 1 keeper is active | `SPEC-GOV-008`, `REQ-ACCESS-100`, `REQ-ACCESS-121`, `REQ-ACCESS-169` | 4 keeper actions | PROVED |
| `MATH-GOV-13` | no settlement mode is governance-timed, and a refused payout is credited in full to its payee in the escrow (received + credited = x, credited = x when the transfer fails) | `SPEC-GOV-010`, `REQ-ACCESS-055` | integers (debt-asset base units) | PROVED |
| `MATH-GOV-14` | accepted grace settings: HF < 0.90 is never shielded and no grace wait exceeds 7,200 s | `SPEC-GOV-012`, `REQ-ACCESS-096` | WAD integers | PROVED |
| `MATH-GOV-15` | the window in which a canceller can act lasts at least requiredDelay | `SPEC-GOV-007`, `REQ-ACCESS-020` | batches of up to 6 calls | PROVED |

### `gv02_delay_floor_allowlist.py`

| ID | Statement | Verifies | Assumptions / bounds | Result |
|---|---|---|---|---|
| `MATH-GOV-16` | at every reachable normal delay (>= MIN_NORMAL_DELAY) a borrower with k <= 7,199 NFTs and a 3-day reaction exits first | `SPEC-GOV-015`, `SPEC-GOV-014`, `REQ-ACCESS-154` | k <= 7,199, r <= 259,200 | PROVED |
| `MATH-GOV-17` | the bound is exact: k = 7,200 at the floor needs 345,612 s > 345,600 s (deliberate counterexample, why k_max = 7,199) | `SPEC-GOV-015` | k = 7,200, r = 259,200 | COUNTEREXAMPLE (deliberate) |
| `MATH-GOV-18` | k_max = floor((MIN_NORMAL_DELAY - r) / 12) - 1 is the largest k with r + 12(k+1) <= MIN_NORMAL_DELAY, for every r <= MIN_NORMAL_DELAY - 12 | `SPEC-GOV-015` | r <= 345,588 | PROVED |
| `MATH-GOV-19` | over 5 setShortDelaySelector calls a pair outside SHORT_ELIGIBLE (every role, upgrade, beacon and timelock pair) never becomes short | `SPEC-GOV-001`, `SPEC-GOV-015`, `REQ-ACCESS-142`, `REQ-ACCESS-152`, `SPEC-GOV-014` | 5 list changes | PROVED |
| `MATH-GOV-19b` | hence any batch containing an upgrade or role call is ready no earlier than t_s + MIN_NORMAL_DELAY | `SPEC-GOV-001`, `SPEC-GOV-015`, `REQ-ACCESS-142`, `REQ-ACCESS-152`, `SPEC-GOV-014` | 5 list changes | PROVED |
| `MATH-GOV-20` | cap step new * 10^4 <= old * 15,000 admits exactly new <= 1.5 * old (no rounding in the loosener's favour) | `SPEC-GOV-011`, `REQ-ACCESS-120` | integers, caps < 2^128 | PROVED |
| `MATH-GOV-20b` | three loosenings of one cap key: at most 3.375x the start value and at least 2 x MIN_NORMAL_DELAY between the first and the third | `SPEC-GOV-011`, `REQ-ACCESS-120` | integers, caps < 2^128 | PROVED |
| `MATH-GOV-20c` | hardHealthFloor loosening: old - new <= 0.03e18 per step (0, off, counts as 1.00e18), so one step from 1.10 reaches at most 1.07 and cannot switch the floor off; switching off needs a set floor of at most 1.03 | `SPEC-GOV-011`, `REQ-ACCESS-120` | integers, caps < 2^128 | PROVED |
| `MATH-GOV-20d` | topUpSliceUsd loosening from 0 is capped by 1.5 x floor(marketUsdCap / 10): a 4,000,000e8 cap admits at most 600,000e8 | `SPEC-GOV-011`, `REQ-ACCESS-120` | integers, caps < 2^128 | PROVED |
| `MATH-GOV-21` | an operation is restoring iff it has at least one call and every call is in the DAO-only cancel set; an empty batch or one mixing a DAO-only call with any other call is never restoring | `SPEC-GOV-005`, `REQ-ACCESS-156` | batches of up to 4 calls | PROVED |
| `MATH-GOV-22` | cleanupExpiredOperation succeeds only when the operation can no longer execute, and the same calls scheduled again are ready only after a fresh requiredDelay | `SPEC-GOV-013`, `REQ-ACCESS-126` | integers (seconds) | PROVED |
| `MATH-GOV-23` | an accepted setNormalDelay value v (MIN_NORMAL_DELAY <= v <= MAX_DELAY) gives a wait of 4 to 5 days at the required delay | `SPEC-GOV-012`, `SPEC-GOV-003`, `REQ-ACCESS-125` | integers (seconds) | PROVED |
| `MATH-GOV-24` | a pure revokeRole batch cannot be cancelled by a guardian, and executed at readyAt it leaves the guardian no power from t_s + delay on | `SPEC-GOV-006`, `SPEC-GOV-005` | integers (seconds) | PROVED |

### `gv03_market_count_limit.py`

| ID | Statement | Verifies | Assumptions / bounds | Result |
|---|---|---|---|---|
| `MATH-GOV-25` | over 6 listing calls (new or relisting) from any c0 ≤ N, marketCount never exceeds MAX_MARKET_COUNT | `REQ-MREG-034`, `REQ-MREG-030` | 6 calls, N ≥ 1, integers | PROVED |
| `MATH-GOV-26` | wrong reading: without the check at registration the count passes the limit (deliberate counterexample) | `REQ-MREG-034` | N = 1, c0 = 1 | COUNTEREXAMPLE |
| `MATH-GOV-27` | at the limit (c0 = N) a relisting of any cancelled id ≤ N is still accepted and leaves the count at N | `REQ-MREG-034`, `REQ-MREG-030` | integers | PROVED |
| `MATH-GOV-28` | with g(c) = a + b·c, every walk of c ≤ N_max = ⌊(cap − a)/b⌋ markets fits the cap, and N_max + 1 markets do not | `REQ-MREG-034`, `REQ-PSTORE-009` | a ≥ 0, b ≥ 1, cap > a, integers | PROVED |
| `MATH-GOV-28b` | fixture example: per-market gas ⌊(9,515,531 − 302,539)/63⌋ = 146,237, and the mock-LPOracle walk alone bounds N at 113 under 2^24 gas (an upper bound only; the real LPOracle costs more per market) | `REQ-MREG-034` | figures of the `REQ-MREG-034` example | PROVED |

## Findings

No check in this folder finds a defect in the final spec. The 4 counterexamples are deliberate: `MATH-GOV-26` shows that without the registration check the market count passes `MAX_MARKET_COUNT` (why the check sits in `listCollateralMarket`, before any write); `MATH-GOV-06` shows that an upgrade at the 12-hour short delay would beat a 3-day reaction (why upgrade and role selectors are never short), `MATH-GOV-09` shows that any-call role-change marking would let one no-op `grantRole` shield a harmful batch from the guardians (why the mark is every-call), and `MATH-GOV-17` shows that `k = 7,200` NFTs no longer fit the floor delay (why `k_max = 7,199` is exact).

## Results

| Date | Command | Versions | Bounds | Proved | Counterexample | Timeout | Exit |
|---|---|---|---|---|---|---|---|
| 2026-11-10 | `../../.venv/bin/python gv01_timelock_timing.py`; `../../.venv/bin/python gv02_delay_floor_allowlist.py` | Python 3.9.6, z3-solver 4.13.0 | batches of 6 calls, sequences of 4–5 calls; 120 s per query | 27 (15 + 12) | 3 (2 + 1, all deliberate) | 0 | 0 for both scripts |
| 2026-11-11 | `../../.venv/bin/python gv03_market_count_limit.py` | Python 3.9.6, z3-solver 4.13.0 | 6 listing calls; 120 s per query | 4 | 1 (deliberate) | 0 | 0 |
