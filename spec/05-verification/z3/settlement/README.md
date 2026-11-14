# Settlement math (`MATH-ST-…`)

Z3 models of how a liquidation settles and how its losses are covered: the net bonus and effective slippage, the recovery floor and where it is measured, the per-leg minimum outputs, the caller's shortfall top-up, the flash-source checks and the leftover debt asset, the payout waterfall in the debt asset with Avana's fee taken from oracle value and the fee / keeper / borrower split, the pool spot and sequencer gates, the per-chain minimum debt, the rounding gap the caller closes through its shortfall top-up, the payout escrow for payouts a recipient cannot receive, the principal-capped collect, the debit equalities and seizure order, repay with collateral, and the First-Loss reserve's coverage, withdrawal and sizing. The last script recomputes every worked example of the settlement pages in exact integers.

Pages modelled: [2.11 LPVaultSwap](../../../02-contracts/11-lpvaultswap.md) (`SPEC-LIQ-001`…`022`), [2.12 Settlement routes](../../../02-contracts/12-settlement-routes.md), [2.13 Settlement rounding gap](../../../02-contracts/13-settlement-budget.md) (`SPEC-SET-001`, with `SPEC-SET-002`…`007` restated), [2.14 First-Loss reserve](../../../02-contracts/14-first-loss-reserve.md) (`SPEC-FLR-001`…`005`), [2.18 Payout escrow (PayoutEscrow)](../../../02-contracts/18-payout-escrow.md), and the flows [3.5 Liquidation](../../../03-operations/05-liquidation.md), [3.7 Collect fees](../../../03-operations/07-collect-fees.md) and [3.9 Deficit coverage](../../../03-operations/09-deficit-coverage.md). Pinned upstream code: Aave V4 `a3ef63ea`, the Aave V3 Pool `flashLoan` premium rule, Uniswap v3 `NonfungiblePositionManager` (0.7.6).

## Run

```bash
../../run_all.sh                                   # every spec-stage check
../../.venv/bin/python st03_waterfall.py           # one model, from this folder
```

Each check prints `PROVED` (the negation is unsat), `COUNTEREXAMPLE` (the model is printed), `TIMEOUT`, `COMPUTED` (a worked example whose stated figures all equal the exact evaluation) or `MISMATCH` (a stated figure differs). `[MAX]` lines report an optimum and are informational unless they record an expected value. Every check records its expected result and a script exits 1 only when a result differs from it. Deliberate wrong-reading and boundary checks record `COUNTEREXAMPLE`. A property of the specification that fails keeps `PROVED` (or `COMPUTED`) as its expectation, so its script exits 1 until the specification changes; those are the [Findings](#findings).

Every check carries a `# MATH-ST-NN verifies: <IDs>` tag directly above it, which [`trace.py`](../../trace.py) reads.

## Formulas modelled

Amounts are base units of the debt asset repaid (`Q-333`: every liquidation settles in its debt asset; the scripts that work in 18-decimal units (st01, st02, st04, st05, st10, st12 and parts of st14) are the 18-decimal instance of the same formulas, with `Pgho` read as `Pdebt`; where a model keeps a `cBuy` parameter or a `Gcov`/`Gnet` pair, the current design is the instance `cBuy = 0`, `Gcov = Gnet = D`, which every such check covers. There is no buy leg, no sell-back and no GHO flash mint: the flash loan is the debt asset itself through `IFlashSource` (Aave V3 Pool `flashLoan`), and every payout is in the debt asset); prices are Aave's 8-decimal USD; bps with 10⁴ = 100 %.

| Spec ID | Formula (final text) | Rounding | Script |
|---|---|---|---|
| `SPEC-LIQ-001` | `bNet = 10⁴ + ⌊(b − 10⁴)(10⁴ − lf)/10⁴⌋` | down | st02 |
| `SPEC-LIQ-002` | no cost term in a liquidation: the former `costsBps` is 0 on every call (the models keep it as a parameter fixed at 0; `⌈φ·10⁴/F⌉` survives only as the deleverage and helper pre-loan quote of `SPEC-LIQ-015`) | — | st02, st11 |
| `SPEC-LIQ-003`, `-016` | `s = min(allowance, ⌊10⁴(bNet − 10⁴)/bNet⌋)` when `bNet > 10⁴`, else 0, so `bNet(10⁴ − s) ≥ 10⁸`; liveness `minLB(10⁴ − smin) ≥ 10⁴(10⁴ + maxFlashFeeBps)` (st02 also checks the general `cBuy` form, of which this is `cBuy = 0`) | down | st02, st16 |
| `SPEC-LIQ-004` | `V = mulDiv(c·Pc, 10^dd, 10^dv·Pdebt)` | down | st02, st14 |
| `SPEC-LIQ-005` | `U = Σᵢ ⌈pᵢ·10^dd/(10^dᵢ·Pdebt)⌉`; `minRec = max(0, ⌈V(10⁴ − s)/10⁴⌉ − U − floorRoundingAllowance)`, tested on `R' = R + shortfall` | slippage term up, `U` up | st01, st02, st04 |
| `SPEC-LIQ-006` | `R` = debt-asset balance change from just before `burnSeized` to after the last route call | exact | st01 |
| `SPEC-LIQ-007` | no `φD` term: `G`, `S`, `A`, `kr`, `B` from `D` alone; a helper's or deleverage loan quote is `fee(x) = ⌈x·p/10⁴⌉` (V3.4 rounds half-up; the source's ceiling quote is the binding gate) | up | st03, st11 |
| `SPEC-LIQ-008` | `S = max(0, R_f − D − φD)`, `R_f = max(R, minRec)` | exact | st03, st16 |
| `SPEC-LIQ-009` | `A = min(⌊max(0, V − D − φD)·avanaFeeShareBps/10⁴⌋, S)` | down | st01, st03 |
| `SPEC-LIQ-010` | `keeperOut = (K + F + R') − (D + F + φ + A + B)`, `InsufficientProceeds` if negative; with a transfer fee `K`, `F`, `F + φ` are the measured `Kr`, `Fr`, `P` and `τ = (F − Fr) + (P − F − φ)` falls on `keeperOut` | checked | st03, st16 |
| `SPEC-LIQ-011`…`013` | no in-kind settlement: every liquidation settles in the debt asset over the swap routes, and a token with no usable route reverts `NoRouteAvailable`; the unwind at oracle prices is never below fair value | — | st05 |
| `REQ-SWAP-076`, `REQ-ESCROW-*` | a payout is delivered or escrowed in full; `totalClaimable = Σ claimable ≤ balance`; a claim pays the whole credit once | exact | st05, st14 |
| `SPEC-LIQ-014` | `s_P = min(slippageAllowanceBps, 30)`; `minPending = max(0, ⌈V_P(10⁴ − s_P)/10⁴⌉ − U − allowance)` | up | st10 |
| `SPEC-LIQ-015` | flash pre-loan: `F ≤ maxFlashLoan`, `fee(F)·10⁴ ≤ maxFlashFeeBps·F`; callback `φ·10⁴ ≤ maxFlashFeeBps·F`; cap strictly above the Pool rate | none | st11 |
| `SPEC-LIQ-017` | leftover `X − D` repays the flash loan, never swapped | exact | st03, st11 |
| `SPEC-LIQ-018` | `minOutᵢ = max(1, ⌈Vlegᵢ(10⁴ − sLeg)/10⁴⌉ − Ulegᵢ − ⌊allowance/n⌋)`, `Vlegᵢ` rounded down | leg value down, term up | st10 |
| `REQ-SWAP-121` | dust leg iff `Vlegᵢ ≤ Ulegᵢ`: not swapped, 0 toward `R`, sent to the caller | `Vlegᵢ` down, `Ulegᵢ` up | st10 |
| `SPEC-LIQ-019` | `sLeg = min(9,999, s + min(maxShortfallBps, ⌊maxShortfall·10⁴/V⌋))`; `shortfall = max(0, minRec − R, gap)` with `gap` of `SPEC-SET-001`, `minRec − R ≤ maxShortfall` and `gap ≤ maxShortfall`, pulled from the caller | relaxation down | st01, st03, st10 |
| `SPEC-LIQ-020` | `Vnet = max(0, ⌊V(10⁴ − s)/10⁴⌋ − U − ε)`, `cap = ⌊Vnet·10⁴/(10⁴ + maxFlashFeeBps)⌋`, `x = min(debt, cap)` (debt units) | down | st12, st15 |
| `SPEC-LIQ-021` | `T_drain = blockTime·max(⌈N/callsPerBlock⌉, ⌈L/depthPerBlock⌉, ⌈Lflash/flashPerBlock⌉)` | calls down, blocks up | st15 |
| `SPEC-LIQ-022` | `kr = min(S, G) − A`, `B = S − A − kr = max(0, S − G)`, `G = max(0, V − D − φD)` | exact | st03, st15 |
| `REQ-ROUTE-006` | one-sided stress: one leg of `V` into depth `10V` loses `1/11`, two `V/2` legs `1/21` each | exact | st15 |
| `REQ-ROUTE-012` | LitePSM gem amount: `cost(g) = g·c + ⌊g·c·tout/10¹⁸⌋`; `g₀ = ⌊D·10¹⁸/((10¹⁸ + tout)·c)⌋`, take `g₀ + 1` when `cost(g₀ + 1) ≤ D` | down (fee floor) | st15 |
| `SPEC-SET-001` | `gap = max(0, D + φ + τ + A + B − Kr − R)`, `τ = F − Fr`, `A`, `B` on `R_f`, closed by the caller's top-up; no budget, no draw, no shared pool (st16 models the `F = D` form, equal by MATH-ST-122) | exact | st03, st04, st16 |
| `REQ-SWAP-122` | top-up loop: `need = owed − balance(source)`, at most 4 transfers; USDT fee `min(⌊x·ρ/10⁴⌋, maxFee)`, `ρ ≤ 19`, `maxFee < 50·10⁶` | down (fee) | st16 |
| `SPEC-BACK-006`…`008` | seizure list and greedy debit; share drop = supply drop = debit; `collect(max = decreaseLiquidity amounts)` | exact; NFPM uint128 | st06, st07, st08 |
| `SPEC-FLR-001`…`003` | `amount = min(maxAmount, ⌈deficitRay/RAY⌉, fundedBalance())`; Hub `eliminateDeficit`; `fundedBalance = ⌊shares(A + 10⁶)/(S + 10⁶)⌋`; withdrawal `min(request, fundedBalance)`, shares up | against the reserve | st09 |
| `SPEC-FLR-004` | `lossFactor = max(0, (1 + g) − h(1 − dLP)/(CF·LB(1 + u)))` | reals | st13 |
| `SPEC-FLR-005` | `tail = ⌈(tokenUsdCap + slices)·CF_t·10¹⁴/minOpeningHealthFactor⌉·10^{d_a}/P_a`, capped by draw capacity | up | st13, st14 |

Aave sizing used in the models (`LiquidationLogic._calculateCollateralToLiquidate`): `c = ⌊debtRay·Pd·10^dv·b/(10^dd·Pc·10⁴·RAY)⌋`; collateral-driven branch `debtRay = ⌈c·Pc·10^dd·10⁴·RAY/(Pd·10^dv·b)⌉`, shares and `D` rounded up. Markets: USDC/USDT with `dv = 6` at $2.00, GHO/USDC `dv = 12`, USDC/USDT `dv = 18` at $2.10 (the 2.11 examples), a $10 `dv = 6` market; debt up to 10²⁶ wei (100M GHO) per call.

## Properties

### `st01_recovery_floor.py`: where the floor is measured

| ID | Statement | Verifies | Result |
|---|---|---|---|
| MATH-ST-01 | With nothing else landing in the window and no top-up allowed, passing the floor means the collateral itself returned at least `minRec`, for every caller funds `K`, flash `F`, debt pulled `G = D` and leftover `g' = X − D`. | `SPEC-LIQ-005`, `-006`, `-014`, `-019`, `LIQ-030` | PROVED |
| MATH-ST-02 | Wrong reading: the floor tested on the whole balance before repayment passes a poor recovery. | `SPEC-LIQ-006` | COUNTEREXAMPLE |
| MATH-ST-03 | Wrong reading: the floor tested on the balance net of flash principal still counts caller funds. | `SPEC-LIQ-006` | COUNTEREXAMPLE |
| MATH-ST-04 | Avana's fee is non-decreasing in the recovery and equal for any two recoveries whose surplus covers it: a self-sandwich, a bad route or debt asset injected into the window does not change it. | `SPEC-LIQ-009`, `-006`, `-008` | PROVED |

### `st02_floor_covers_flash.py`: does the slippage term repay the flash loan?

| ID | Statement | Verifies | Result |
|---|---|---|---|
| MATH-ST-05 | Wrong reading: a subtractive bound `s = bonus` leaves the slippage term below `D`. | `SPEC-LIQ-003` | COUNTEREXAMPLE |
| MATH-ST-06 | With `(1 + bNet)(1 − s) ≥ (1 + f)(1 + cBuy)`, debt cost plus fee minus the slippage term is at most `u + 1/2`; `f = cBuy = 0` is the liquidation bound of `SPEC-LIQ-003` (no premium term, `Q-404`), `f > 0` a helper premium at the listing bound of `SPEC-LIQ-016`. | `SPEC-LIQ-003`, `-005`, `-016`, `LIQ-060` | PROVED |
| MATH-ST-07 | Exact integers, 4 markets × bonuses 10,050…10,500, no premium term: `D − term` is at most one vault unit plus 1. | `SPEC-LIQ-002`…`005` | PROVED (24 cases) |
| MATH-ST-08 | Wrong reading: the subtractive bound leaves a gap above 1 GHO; the largest gap at `D` = 1M GHO is reported (625 GHO at bonus 10,250, 2,500 GHO at 10,500). | `SPEC-LIQ-003` | COUNTEREXAMPLE (20 cases) |
| MATH-ST-09 | Collateral-driven branch (all collateral seized, index 1.05 RAY plus an odd remainder): gap ≤ 3 wei on each market. | `SPEC-LIQ-003`…`005` | PROVED (4 cases) |
| MATH-ST-10 | For every liquidatable HF, Aave's bonus is at least the on-chain minimum bonus, so the minimum bonus is the binding case. | `SPEC-LIQ-003`, `-016`, `SPEC-HUB-005` | PROVED |
| MATH-ST-11 | `s` rounded down gives `bNet(10⁴ − s) ≥ 10⁸` for every `bNet > 10⁴` (no premium term); rounding to nearest breaks it (counterexample). | `SPEC-LIQ-003`, `-016` | PROVED / COUNTEREXAMPLE |
| MATH-ST-12 | Under a 10 % liquidation fee, `s` from `bNet` keeps the gap at two vault units plus 1 wei (the fee cut rounds up once more); `s` from the gross bonus leaves more than 1 GHO. `bNet` lies in `[10⁴, exact net bonus]` and equals `b` at `lf = 0`. | `SPEC-LIQ-001`, `-003` | PROVED / COUNTEREXAMPLE / PROVED |
| MATH-ST-13 | A premium that passes `φ × 10⁴ ≤ maxFlashFeeBps × F` has a rate at most `maxFlashFeeBps` (deleverage and the helper). Listing liveness: the listing check `minLB(10⁴ − smin) ≥ 10⁴(10⁴ + maxFlashFeeBps)` gives `s ≥ smin` at every bonus `≥ minLB` and `bNet(10⁴ − smin) ≥ 10⁴(10⁴ + maxFlashFeeBps)`; the 2.11 example 10,060 / 10,200 / 10,050. | `SPEC-LIQ-002`, `-016`, `REQ-PSTORE-021` | PROVED (61 cases) |
| MATH-ST-113 | Outside Aave's bounds the net bonus saturates at `bNet = 10⁴`: where one of `b − 10⁴`, `10⁴ − lf` is negative and the other is not, the raw formula already gives `bNet ≤ 10⁴` and `s = 0`; without saturation, `b < 10⁴` with `lf > 10⁴` would yield a positive bonus. | `SPEC-LIQ-001`, `-003` | PROVED / COUNTEREXAMPLE |

### `st03_waterfall.py`: payout, fee and the caller's gap

Exact Solidity 0.8 checked arithmetic: every intermediate lies in `[0, 2²⁵⁶)`, inputs below 2¹²⁸; amounts in the debt asset (`Q-333`), flash premium ≤ 100 bps rounded up, borrower surplus included (`Q-337`).

| ID | Statement | Verifies | Result |
|---|---|---|---|
| MATH-ST-14 | With `0 < Kf ≤ X`, `D ≤ Kf` and the floor gap within `maxShortfall`, no checked uint256 operation reverts. | `SPEC-LIQ-009`, `-010`, `SPEC-SET-001`, `LIQ-031` | PROVED |
| MATH-ST-15 | Debt-asset conservation: `Kf + R + shortfall = D + A + B + keeperOut`; LPVaultSwap ends at 0. | `SPEC-LIQ-010`, `-019`, `LIQ-060`, `LIQ-069` | PROVED |
| MATH-ST-16 | `A ≤ S`, and `A = 0` whenever `R_f ≤ D`. | `SPEC-LIQ-008`, `-009` | PROVED |
| MATH-ST-17 | The gap never binds beyond the floor gap: `gap > minRec − R` with `gap > 0` is unreachable while `Kf ≥ D`. | `SPEC-LIQ-010`, `-022`, `SPEC-SET-001` | PROVED |
| MATH-ST-18 | A recovery below `D` is the caller's: `R' < D` gives `keeperOut = Kf − (D − R')` with `A = B = 0`. | `SPEC-SET-001`, `SPEC-LIQ-019` | PROVED |
| MATH-ST-19 | Wrong reading: a gap of `D − R` that ignores the caller funding pulls a top-up the funding already covers. | `SPEC-SET-001` | COUNTEREXAMPLE |
| MATH-ST-20 | Wrong reading: a fee on the realized surplus falls from 18.06 to 15.40 USDC when the caller swaps worse, though `V` is unchanged (the 2.11 example gives `A = 19.5`). | `SPEC-LIQ-008`, `-009` | COUNTEREXAMPLE |
| MATH-ST-51 | No premium term: `S`, `G`, `A`, `kr`, `B` depend on `R`, `minRec`, `V`, `D` only, so callers funding `Kf` or `Kf2 ≥ D` (own balance or a helper loan of any size) get the same split. | `SPEC-LIQ-007` | PROVED |
| MATH-ST-52 | An oversized `debtToCover` returns the leftover `Kf − D` inside `keeperOut`, unswapped. | `SPEC-LIQ-007`, `SPEC-SET-001`, `LIQ-041` | PROVED |
| MATH-ST-53 | A transfer fee on the caller's funding (`Kf < X`) lowers `keeperOut` by exactly the fee and leaves `A`, `B` unchanged (measured amounts; a fee that also applies to Aave's pull reverts in the Hub, `REQ-SWAP-123`). | `SPEC-LIQ-007`, `-010`, `SPEC-SET-001` | PROVED |
| MATH-ST-54 | With `s = 0` the loss is still the caller's: a call that settles has `keeperOut ≥ 0` and `Kf + R' ≥ D`. | `SPEC-SET-001`, `SPEC-LIQ-016` | PROVED |
| MATH-ST-55 | A call that settles has `R' ≥ minRec`, and the caller pays exactly `max(0, minRec − R) ≤ maxShortfall`. | `SPEC-LIQ-019`, `-005` | PROVED |
| MATH-ST-96 | `A + kr + B = S`, `0 ≤ kr ≤ G − A`, `B = max(0, S − G)`, and `keeperOut = Kf + kr` whenever `R' ≥ D`. | `SPEC-LIQ-022`, `-010` | PROVED |
| MATH-ST-97 | The top-up never reaches the borrower: `B = 0` whenever the floor part of the top-up is positive (given `minRec ≤ V`), and `B ≤ max(0, R − V)` always. | `SPEC-LIQ-022`, `-019` | PROVED |
| MATH-ST-121 | A call within its `maxShortfall` always settles: `keeperOut ≥ 0` and `gap ≤ max(0, minRec − R)`, so neither `InsufficientProceeds` check fires (`Q-404`). | `SPEC-SET-001`, `SPEC-LIQ-010`, `-019`, `-007`, `REQ-SWAP-029`, `REQ-SWAP-062` | PROVED |
| MATH-ST-122 | The SettlementMath gap `max(0, D + φ + τ + A + B − Kr − R)` at `φ = τ = 0`, `Kr = Kf` is the gap of `SPEC-SET-001`; wrong reading: a repayment funded outside the measured `Kf` leaves `keeperOut < 0` (counterexample). | `SPEC-SET-001`, `SPEC-LIQ-019`, `-007` | COUNTEREXAMPLE (2) / PROVED |

### `st04_settlement_budget.py`: the rounding gap is the caller's

There is no settlement budget (`Q-397`). These checks keep their IDs and verify the rule that replaces it: `gap = max(0, D + φ + τ + A + B − Kr − R)` is closed by the caller's top-up of `SPEC-LIQ-019`; MATH-ST-21, `-22` and `-58` take `F = D` with no transfer fee.

| ID | Statement | Verifies | Result |
|---|---|---|---|
| MATH-ST-21 | A recovery at or above the floor leaves the caller a loss `D − R` of at most one vault unit + 2 wei + `U` + allowance, for the 2.11 and 3.5 markets at bonuses 10,200 and 10,500, any `D ≤ 10²⁶`. | `SPEC-SET-001`, `SPEC-LIQ-005`, `-019`, `INV-038` | PROVED (4) |
| MATH-ST-22 | Wrong reading: the subtractive bound leaves the caller a loss above 100 units at the floor (626 at `D` = 1M). | `SPEC-SET-001`, `SPEC-LIQ-003` | COUNTEREXAMPLE |
| MATH-ST-23 | Through the helper (`Kf = F ≥ D`), `keeperOut` contains no premium and the helper's net payout falls by exactly `φ − φD` against a loan of `D`; the gap is 0 for every `F ≥ D`. | `SPEC-LIQ-007`, `SPEC-SET-001` | PROVED / COUNTEREXAMPLE |
| MATH-ST-24 | With `Kf ≥ D`: `Kf + R + shortfall = D + A + B + keeperOut`, `keeperOut ≥ 0`, `gap ≤ max(0, minRec − R)` and `shortfall = max(0, minRec − R)`: only the caller and the collateral fund the settlement. | `SPEC-LIQ-010`, `-019`, `SPEC-SET-001`, `INV-038` | PROVED |
| MATH-ST-25 | Wrong reading: without `D ≤ Kf` the gap can exceed the floor gap. | `SPEC-LIQ-019`, `SPEC-SET-001` | COUNTEREXAMPLE |
| MATH-ST-26 | `keeperOut = Kf + kr` when `R' ≥ D` and `Kf − (D − R')` when `R' < D`; `A + kr + B = S`. | `SPEC-SET-001`, `SPEC-LIQ-008`, `-009`, `-022` | PROVED |
| MATH-ST-56 | `shortfall = max(0, minRec − R)` gives `R' ≥ minRec` and `Kf + R' ≥ D + A + B`, and is the least top-up that does both. | `SPEC-LIQ-019`, `SPEC-SET-001`, `SPEC-LIQ-005` | PROVED |
| MATH-ST-57 | The top-up never reaches the borrower: `B = 0` when the floor term is positive, and `B ≤ max(0, R − V)` whichever term binds. | `SPEC-LIQ-019`, `-022`, `SPEC-SET-001` | PROVED |
| MATH-ST-58 | USDC debt, `drawnIndex = 1.5 RAY + 7`, seizure priced from up to 4 base units less debt than Aave pulls, `R = minRec`: the caller's gap ≤ one vault unit + 2 + `U` + allowance + 4 debt units, at bonuses 10,200 and 10,500. | `SPEC-SET-001`, `SPEC-LIQ-019`, `INV-038` | PROVED (2) |
| MATH-ST-59 | `R ≥ minRec` needs no top-up for any `maxShortfall`; boundary: `Kf = D`, `R = D − 1` settles with `keeperOut = Kf − 1`. | `SPEC-SET-001`, `SPEC-LIQ-019`, `REQ-SWAP-005` | PROVED / COUNTEREXAMPLE |
| MATH-ST-60 | Through the helper the net payout is `max(0, keeperOut − F − φ) ≥ 0` after its top-up, and `A`, `B` equal those of a self-funded caller. | `SPEC-LIQ-007`, `-010`, `SPEC-SET-001` | PROVED |
| MATH-ST-99 | Funding `d` more raises `keeperOut` by exactly `d`: oversizing `debtToCover` costs nothing at LPVaultSwap. | `SPEC-SET-001`, `SPEC-LIQ-019`, `REQ-SWAP-005` | PROVED |
| MATH-ST-100 | Dust example: gap 0, `keeperOut = 2.95` USDC, helper top-up 0.0515 USDC; regular example: `keeperOut = 2,020.8`, helper payout 69.825; Lens margin: 2,118.3 and 69.77625. | `SPEC-SET-001`, `SPEC-LIQ-010`, `-019` | COMPUTED |

### `st05_in_kind.py`: no in-kind settlement; the payout escrow

| ID | Statement | Verifies | Result |
|---|---|---|---|
| MATH-ST-27 | The unwound amounts valued at oracle leg prices are never below the LPOracle fair value at any pool price (difference `L(√q − √p)²/√q`), so a spot move never calls for a settlement other than the routed one. | `SPEC-LIQ-011`, `-005`, `REQ-SWAP-025` | PROVED |
| MATH-ST-28 | Payout delivery: LPVaultSwap's balance falls by exactly the amount and the recipient is paid or credited the whole amount, exactly one of the two; wrong reading: escrowing only on a revert loses a payout whose token returns `false`. | `REQ-SWAP-076`, `REQ-ESCROW-018` | PROVED / COUNTEREXAMPLE |
| MATH-ST-29 | Six deposits and claims over three accounts: `totalClaimable` equals the sum of credits and the escrow's balance covers it. | `REQ-ESCROW-003`, `-004`, `-006` | PROVED |
| MATH-ST-30 | A claim pays the whole credit once; a second claim pays nothing. | `REQ-ESCROW-004`, `-005` | PROVED |
| MATH-ST-31 | Wrong reading: credits keyed by account alone let a claim of one token pay out a credit in another. | `REQ-ESCROW-005`, `-006` | COUNTEREXAMPLE |

### `st06_principal_collect.py`: principal-capped collect (uint128 bit-vectors, NFPM 0.7.6 unchecked arithmetic)

| ID | Statement | Verifies | Result |
|---|---|---|---|
| MATH-ST-32 | `collect(max = principal returned by decreaseLiquidity)` returns exactly the principal. | `SPEC-BACK-008`, `INV-033`, `LIQ-023` | PROVED |
| MATH-ST-33 | The depositor's owed amount after the call is owed before plus fees accrued. | `SPEC-BACK-008`, `INV-033`, `FEE-POST-001` | PROVED |
| MATH-ST-34 | Exact even when the shared pool position holds fewer fee wei than the NFPM records. | `SPEC-BACK-008`, `INV-033` | PROVED |
| MATH-ST-35 | After the last liquidity is removed the depositor can still collect owed plus fees. | `SPEC-BACK-008`, `FEE-POST-001` | PROVED |
| MATH-ST-36 | Without the `2¹²⁸` bound the NFPM add wraps; reaching it needs 3.4e20 whole 18-decimal tokens owed on one NFT. | `SPEC-BACK-008` | COUNTEREXAMPLE (out of bounds) |

### `st07_burn_debit.py`: received = burned = share drop = debit

| ID | Statement | Verifies | Result |
|---|---|---|---|
| MATH-ST-37 | With Hub shares = assets, the proxy's share drop, the Hub shares removed, the units received, burned and debited, and the asset-view drop all equal `s`. | `SPEC-BACK-007`, `INV-014`, `LIQ-POST-002` | PROVED |
| MATH-ST-38 | Wrong reading: with shares ≠ assets the asset-view drop differs from the units received by one unit. | `SPEC-BACK-007` | COUNTEREXAMPLE |
| MATH-ST-39 | At A/S = 1.001 the share drop equals the Hub shares removed; at 0.999 (a loss) it does not. | `SPEC-BACK-007` | PROVED / COUNTEREXAMPLE |
| MATH-ST-40 | If A/S rose above 1 after pledge, seizing all of a proxy's shares would yield more units than its credited backing; the `INV-004` gate keeps that state out of every liquidation. | `SPEC-BACK-007`, `INV-004` | COUNTEREXAMPLE (gated) |
| MATH-ST-41 | `Hub.add` and `Hub.remove` keep A = S for any amount. | `INV-004`, `REQ-ADAPTER-037`, `SPEC-BACK-007` | PROVED |

### `st08_seizure_order.py`: allocation over records

| ID | Statement | Verifies | Result |
|---|---|---|---|
| MATH-ST-42 | Greedy debit from the head: if `u ≤ Σ credited`, all of `u` is debited, every record stays ≥ 0 and the total falls by exactly `u` (N = 1, 2, 3, 5, 8). | `SPEC-BACK-006`, `INV-015`, `LIQ-022` | PROVED |
| MATH-ST-43 | At most one record is partially debited, the last one touched (N = 2…8). | `SPEC-BACK-006`, `INV-015` | PROVED |
| MATH-ST-44 | The order credited-descending, lowest ID first is unique for distinct record IDs (N = 5). | `SPEC-BACK-006`, `INV-015` | PROVED |
| MATH-ST-45 | If `u > Σ credited` a remainder is left, so the call must revert (`InsufficientCredit`). | `SPEC-BACK-006`, `REQ-VAULT-055` | COUNTEREXAMPLE (revert path) |

### `st09_deficit_coverage.py`: First-Loss coverage, funded balance and withdrawal

| ID | Statement | Verifies | Result |
|---|---|---|---|
| MATH-ST-46 | Coverage never exceeds the covered Spoke's recorded deficit (ray). | `SPEC-FLR-001`, `DEF-006`, `DEF-POST-001` | PROVED |
| MATH-ST-47 | With `amount = min(maxAmount, ⌈deficit/RAY⌉, fundedBalance())`, the GHO eliminated is ≤ the funded balance and the shares burned are ≤ the shares held, so the `uint120` subtraction never reverts. | `SPEC-FLR-001`, `-002`, `DEF-POST-001` | PROVED |
| MATH-ST-48 | Coverage pays less than 1 wei above the exact deficit. | `SPEC-FLR-001` | PROVED |
| MATH-ST-49 | Other suppliers' share price does not fall. | `SPEC-FLR-001`, `DEF-POST-001` | PROVED |
| MATH-ST-114 | The Hub eliminates exactly the First-Loss Reserve's `amount` (`dE = amount`), so `totalCovered` can be written before the call. | `SPEC-FLR-001`, `REQ-FLR-018` | PROVED |
| MATH-ST-50 | The Hub alone would accept coverage of any Spoke's deficit; the First-Loss Reserve's `COVERAGE_ROLE` and Spoke allowlist carry the restriction. | `SPEC-FLR-001`, `DEF-005` | COUNTEREXAMPLE (Hub only) |
| MATH-ST-61 | A withdrawal of `min(request, fundedBalance())` burns at most the shares held. | `SPEC-FLR-003` | PROVED |
| MATH-ST-62 | `fund(x)` raises `fundedBalance` by between `x − 2` and `x + 1` (two floors), share price between 1 and 2. | `SPEC-FLR-002` | PROVED |

### `st10_leg_minout.py`: per-leg minimums and the shortfall top-up

| ID | Statement | Verifies | Result |
|---|---|---|---|
| MATH-ST-63 | `minOut ≥ 1`, and a leg that meets it loses at most `⌊Vleg·sLeg/10⁴⌋ + Uleg + ⌊allowance/n⌋` against its oracle value (n = 1, 2). | `SPEC-LIQ-018`, `REQ-SWAP-100`, `LIQ-075` | PROVED |
| MATH-ST-64 | At the oracle-implied pool price (`|Σ Vleg − V| ≤ U`, legs of equal value) `Σ minOut ≤ minRec + n + U` (s = 0, 30, 49, 100). Boundary: with the pool away from that price and one leg near 0, that leg's minimum is clamped at 1 and the sum can exceed `minRec + n + U` by up to `⌊allowance/2⌋` (0.5 GHO). | `SPEC-LIQ-018`, `-005` | PROVED (8) / COUNTEREXAMPLE (4) |
| MATH-ST-65 | `s ≤ sLeg ≤ min(9,999, s + maxShortfallBps)`; the relaxation is 0 when `maxShortfall = 0` or `V = 0`. | `SPEC-LIQ-019`, `LIQ-076` | PROVED |
| MATH-ST-66 | Legs that meet their relaxed minimums need a shortfall of at most `maxShortfall + U + 2` (V = 12,422.6, 2,047.5, 3.15 GHO); the recorded maxima are all below `maxShortfall`. | `SPEC-LIQ-019`, `-018` | PROVED (4) |
| MATH-ST-67 | `s_P ≤ 30`; one leg's minimum never exceeds `minPending + 1`; two legs of any split exceed `minPending + 2` by at most `⌊allowance/2⌋` (recorded `[MAX]`). | `SPEC-LIQ-014`, `-018`, `DEF-015` | PROVED (2) |
| MATH-ST-111 | A dust leg (`Vleg ≤ Uleg`) has floor term `⌈Vleg(10⁴ − sLeg)/10⁴⌉ − Uleg ≤ 0`, and is worth less than `Uleg + 1` debt units at the capped leg price (token and debt decimals 18/6, 6/6, 6/18, 18/18). | `REQ-SWAP-121`, `SPEC-LIQ-018`, `-005`, `LIQ-090` | PROVED (5) |

### `st11_buy_leg.py`: flash source checks, the leftover and the cap above the Pool rate (the file keeps its name; the buy leg no longer exists, `Q-333`)

| ID | Statement | Verifies | Result |
|---|---|---|---|
| MATH-ST-68 | A loan that passes the pre-loan checks has `F` ≤ idle liquidity and `costsBps ≤ maxFlashFeeBps`; wrong reading: checking only the quote lets a premium raised to 20 bps before the callback pass a 10 bps cap. | `SPEC-LIQ-015`, `-002`, `REQ-FLASH-002`, `REQ-SWAP-013` | PROVED / COUNTEREXAMPLE |
| MATH-ST-69 | `fee(x) = ⌈x·p/10⁴⌉` is non-decreasing and never below the exact premium, so `φD ≤ φ`. | `SPEC-LIQ-007` | PROVED |
| MATH-ST-70 | With `D ≤ X ≤ K + F` and `keeperOut ≥ 0`, the balance before the flash repayment covers `F + φ`: the leftover needs no swap. | `SPEC-LIQ-017`, `REQ-SWAP-089` | PROVED |
| MATH-ST-115 | The cap sits strictly above the Pool rate. V3.4 rounds half-up; the source's ceiling quote is the binding gate. With the quote `fee(F) = ⌈F·p/10⁴⌉` and the exact check `fee(F)·10⁴ ≤ m·F`: for `m > p` every `F ≥ ⌈10⁴/(m − p)⌉` passes; for `m = p` a loan passes exactly when `10⁴` divides `F·p` (counterexample to "a cap equal to the rate admits every loan": `m = p = 5`, `F = 1,999`, `φ = 1`); for `m < p` every loan fails; with `FLASH_BORROWER` (`p = 0`) every loan passes at every cap, 0 included. The V3.4 half-up charge `⌊(F·p + 5,000)/10⁴⌋` never exceeds the quote, so a loan that passes the quote passes the callback re-check. At launch (`m = 10`, `p = 5`) the largest failing loan is 999 base units (`[MAX]`); the `SPEC-LIQ-015` figures are computed. | `SPEC-LIQ-015`, `SPEC-LIQ-007`, `REQ-FLASH-001`, `REQ-FLASH-003`, `REQ-FLASH-007`, `REQ-PSTORE-024` | PROVED (5) / COUNTEREXAMPLE / COMPUTED |

### `st12_deleverage.py`: repay with collateral

| ID | Statement | Verifies | Result |
|---|---|---|---|
| MATH-ST-71 | `x ≤ cap` and its flash fee give `x + φ ≤ Vnet` (maxFlashFeeBps 0, 1, 9, 30, 100). | `SPEC-LIQ-020` | PROVED (5) |
| MATH-ST-72 | No buy leg: the repayment `x = min(debt, cap)` is the debt asset itself, and with the premium rounded up `x + φ ≤ Vnet + 1` (maxFlashFeeBps 0, 5, 10, 100). | `SPEC-LIQ-020`, `REQ-SWAP-106`, `REQ-SWAP-088` | PROVED (4) |
| MATH-ST-73 | With `ε` in `Vnet`, legs meeting their minimums leave `R` short of `x` by at most `U` + 2 base units (largest 1.98·10¹² wei of an 18-decimal debt asset, below `U`); that case reverts with `DeleverageShortfall` and draws nothing. | `SPEC-LIQ-020`, `-018` | PROVED |
| MATH-ST-74 | While debt remains, the health factor does not fall exactly when `x·HF ≥ V·CF`. | `SPEC-LIQ-020`, `SPEC-PROXY-009` | PROVED |
| MATH-ST-75 | The stated threshold `HF ≥ CF(10⁴ + maxFlashFeeBps)/(10⁴ − s)` does not guarantee `x·HF ≥ V·CF`; the threshold `CF(10⁴ + maxFlashFeeBps)·V/((10⁴ − s)V − 10⁴(U + ε + 2) − maxFlashFeeBps)` does (maxFlashFeeBps 0, 9, 100). `SPEC-LIQ-020` now states the corrected threshold; the plain-ratio check is kept as a deliberate wrong reading. | `SPEC-LIQ-020` | COUNTEREXAMPLE (deliberate; finding 3, resolved) / PROVED (3) |
| MATH-ST-123 | Legs meeting their minimums cover `x + φ` up to `U` + 2 base units with a premium strictly below the cap (maxFlashFeeBps 10 at 9 and 5 bps, 100 at 99 bps); without `ε` in `Vnet` the shortfall can exceed half the allowance at 9 bps. | `SPEC-LIQ-020`, `-018`, `REQ-SWAP-106`, `INV-089` | PROVED (3) / COUNTEREXAMPLE |

### `st13_reserve_sizing.py`: First-Loss reserve sizing (reals)

| ID | Statement | Verifies | Result |
|---|---|---|---|
| MATH-ST-76 | An account at HF ≥ `pauseLossStartHealthFactor` loses at most debt × `lossFactor` over the incident window; over two markets the total loss is ≤ Σ debtCap × lossFactor ≤ reserve. | `SPEC-FLR-004` | PROVED (2) |
| MATH-ST-77 | The tail term `booked × CF_t / minOpeningHealthFactor` bounds the debt of every account that is not yet liquidatable. | `SPEC-FLR-005`, `SPEC-CAP-007` | COUNTEREXAMPLE (deliberate wrong reading; finding 4, resolved: the spec uses `booked × CF_t`, MATH-ST-78) |
| MATH-ST-78 | The tail term `booked × CF_t` does. | `SPEC-FLR-005`, `SPEC-CAP-007` | PROVED |

### `st14_worked_examples.py`: worked examples

| ID | Examples | Verifies | Result |
|---|---|---|---|
| MATH-ST-80 | Net bonus, costs, one- and two-leg slippage | `SPEC-LIQ-001`…`003`, `-016` | COMPUTED |
| MATH-ST-81 | 975-unit seizure and the 3 GHO dust seizure: `c`, `V`, `U`, slippage term, `minRec` | `SPEC-LIQ-004`…`006` | COMPUTED |
| MATH-ST-82 | Flash fee on the covered cost, surplus, Avana fee (also after a self-sandwich), payout and GHO conservation | `SPEC-LIQ-007`…`010` | COMPUTED |
| MATH-ST-83 | Payout escrow: gas per payout, a refused fee escrowed while the caller is paid | `SPEC-LIQ-011`, `REQ-SWAP-076`, `REQ-ESCROW-003`, `-018` | COMPUTED |
| MATH-ST-84 | Pending-settlement floor with USDT at $0.9995: `U = 1.9995·10¹²` wei, `minPending = 82.5273619005` GHO | `SPEC-LIQ-014` | COMPUTED (finding 2, resolved) |
| MATH-ST-85 | Flash of the debt asset: 5 bps premium passes the 10 bps check, 20 bps fails; `s` has no buy-leg term; leftover `X − D`, `F + φ` and the caller-borne `φ − φD`; USDT issuer fee, LitePSM residue, one-sided route depth | `SPEC-LIQ-015`, `-017`, `REQ-SWAP-088`, `REQ-ROUTE-006` | COMPUTED |
| MATH-ST-86 | Leg minimum, shortfall top-up, relaxed legs, USDT transfer fee | `SPEC-LIQ-018`, `-019`, `REQ-ROUTE-008`, `-042` | COMPUTED |
| MATH-ST-87 | Repay with collateral (18-decimal instance, `ε` = 1 GHO): `V`, `Vnet`, `x`, `assetOut`, health factors, threshold | `SPEC-LIQ-020` | COMPUTED |
| MATH-ST-88 | The caller's rounding gap in the dust, funded and surplus cases | `SPEC-SET-001`, `SPEC-LIQ-019` | COMPUTED |
| MATH-ST-89 | Coverage amount and shares (GHO and WETH), funded balance, withdrawal, `DEF-006` | `SPEC-FLR-001`…`003`, `DEF-006` | COMPUTED |
| MATH-ST-90 | Incident loss factor, GHO and WETH reserve needs | `SPEC-FLR-004` | COMPUTED |
| MATH-ST-91 | Tail factor 0.312, covered cap $1,282,051 for the 400,000 GHO reserve, `tail_GHO` 524,160, `tailCoverageBps` 7,631; `REQ-FLR-041` 773,760 and 5,169 | `SPEC-FLR-005`, `REQ-FLR-041`, `SPEC-CAP-008` | COMPUTED |
| MATH-ST-92 | `LIQ-060`: regular and dust cases | `LIQ-060`, `SPEC-LIQ-003`, `-005`, `-009`, `-010`, `SPEC-SET-001` | COMPUTED |
| MATH-ST-93 | `LIQ-068`: GHO debt end to end | `LIQ-068`, `SPEC-HUB-005` | COMPUTED |
| MATH-ST-94 | `LIQ-069`: USDC debt end to end, USDC flash with premium 0, payout in USDC: `V = 5,089.8`, `minOut = 5,037.901998`, `R = 5,085`, `Y = 95`, `A = 19.96`, `Kr = 75.04`, `B = 0`, conservation 10,085 USDC; HF after reaches the 1.10 target (exact 1.1000000000085; the page prints 1.09999) | `LIQ-069`, `LIQ-031`, `SPEC-LIQ-004`, `-005`, `-008`…`-010`, `-017`, `-022` | COMPUTED |
| MATH-ST-95 | 3.7 fee collection and the `DEF-015` pending-settlement proceeds | `FEE-POST-001`, `DEF-015`, `SPEC-LIQ-014` | COMPUTED |

Figures written with fewer digits ("about", "≈", health factors to four decimals) are compared after rounding the exact value half up to the written digits.

### `st15_debt_asset_settlement.py`: debt-asset worked examples, throughput, one-sided stress and the LitePSM gem amount

| ID | Examples | Verifies | Result |
|---|---|---|---|
| MATH-ST-101 | Every USDC-debt figure of 2.11: `s` with no premium term, `V`, `U`, `minRec`, `S`, `A`, `kr`, `B`, `keeperOut` (regular, surplus, sandwich, dust, `PayoutTooLow` at 2,015.5), the helper's premium, top-up and payout, leg minimum, shortfall, repay with collateral, premium checks, Lens margin, the `SPEC-LIQ-016` listing example | `SPEC-LIQ-002`…`-022`, `SPEC-SET-001` | COMPUTED |
| MATH-ST-102 | Throughput: 12 and 30 calls per block, 300 s and 20 s drain, 12 calls in one transaction | `SPEC-LIQ-021`, `REQ-SWAP-118` | COMPUTED |
| MATH-ST-103 | One-sided unwind: 476 bps for two half legs, 909 bps for one full leg, at depth 10V | `REQ-ROUTE-006` | COMPUTED |
| MATH-ST-120 | LitePSM gem amount of a `PegModule` route, for `D < 2¹²⁸` DAI wei, `tout < 10³⁶`, `1 ≤ c ≤ 10¹⁸`: the route's `r` has `cost(r) ≤ D < cost(r + 1)` (the largest amount `D` buys); `g₀ + 2` never fits; no overflow (`(g₀ + 1)·c ≤ D + c`, fee below `D + 10³⁶`); wrong reading `r = g₀` (counterexample expected: `D = 1`, `tout = 1`, `c = 1`); the `REQ-ROUTE-012` examples (1,000.0000005 DAI at `tout = 0`, 1,001 DAI at 0.1 %). Products are fresh variables tied by linear facts, which only weakens the premises | `REQ-ROUTE-012` | PROVED (3) / COUNTEREXAMPLE (deliberate) / COMPUTED |

### `st16_payout_split_gates.py`: payout split, one-leg floor, gates, record cap, windows and reserves, flash lender, flash repayment

| ID | Statement | Verifies | Result |
|---|---|---|---|
| MATH-ST-104 | `A + kr + B = S`; `A, kr, B ≥ 0`; `A ≤ S`; `kr ≤ G − A`; `B = max(0, S − G)`; conservation `Kf + R + shortfall = D + A + B + keeperOut`; 2.11 examples (`A = 19.5`, `kr = 70.8`, `keeperOut = 2,020.8`; `R = 2,052`: `B = 4.5`, `keeperOut = 2,028`). | `SPEC-LIQ-008`…`-010`, `-019`, `-022`, `SPEC-SET-001`, `LIQ-031`, `LIQ-076`, `LIQ-POST-016` | PROVED (3) / COUNTEREXAMPLE (deliberate) / COMPUTED |
| MATH-ST-105 | No buy-leg and no premium term: `bNet(10⁴ − s) ≥ 10⁸` whenever `s > 0`; exhaustive over `bNet` 10,001…20,000; the listing check gives `s ≥ smin`. | `SPEC-LIQ-003`, `-005`, `-016`, `REQ-PSTORE-021`, `LIQ-030` | PROVED (15) / COMPUTED (2) |
| MATH-ST-106 | A moved pool price never reverts a liquidation (`REQ-SWAP-025`, `Q-350`): an unwind of a concentrated range at any pool spot price returns tokens whose oracle value is at least the fair composition value at the oracle price (fair composition is the minimum over spot prices, PROVED over reals); wrong reading that values the tokens at the spot price (counterexample expected); the route mode and the revert decision do not depend on the spot; the `REQ-SWAP-025` example (2,051.25 USDT worth 2,050.224375 USDC ≥ `V`) |
| MATH-ST-107 | Sequencer gate: no liquidation in `Down`, none in `Grace` with `HF ≥ graceHealthFactor`, liquidation runs in `Up`; `settlePending` refused only in `Down`; the `LIQ-089` timeline | `LIQ-086`, `LIQ-POST-018`, `LIQ-F-045`, `LIQ-F-046`, `REQ-SWAP-009`, `LIQ-089` | PROVED (2) / COMPUTED |
| MATH-ST-108 | No minimum debt (`Q-381`): every account with at most 16 records per market is liquidated in one call of at most `G(16) = 1,310,000 + 240,000 × 16 = 5,150,000` gas ≤ 16,777,216; boundary: 64 records is the largest count that fits, 65 does not (counterexample expected); the gas-units figures | `SPEC-CHAIN-001`, `INV-096`, `LIQ-022`, `REQ-AMM-CORE-015`, `LIQ-087` | PROVED / COUNTEREXAMPLE (boundary) / COMPUTED |
| MATH-ST-109 | Three liquidations on different markets, in any order, each settle from their own caller's funding and top-up (`Kf ≥ D`), with no shared pool; examples: the dust call by any caller and through the helper. | `SPEC-SET-001`, `SPEC-LIQ-019`, `REQ-SWAP-073`, `INV-097`, `AMMN-RT-13` | PROVED / COUNTEREXAMPLE / COMPUTED |
| MATH-ST-110 | A deleverage or helper loan that passes the checks draws from no recorded Hub and has a premium rate at most `maxFlashFeeBps`. | `LIQ-POST-020`, `REQ-FLASH-002`, `REQ-FLASH-005`, `REQ-FLASH-006`, `REQ-SWAP-013`, `SPEC-LIQ-015`, `INV-095` | PROVED / COUNTEREXAMPLE (2, deliberate) |
| MATH-ST-111 | Flash repayment by balance delta (`REQ-SWAP-122`): with USDT's fee `min(⌊x·ρ/10⁴⌋, maxFee)`, `ρ ∈ {1, 10, 19}` bps and `maxFee ≤ 50·10⁶`, four top-up transfers bring the source's balance to exactly `owed` for every `owed < 2¹²⁸` (residual 0, delivered = owed, `P ≥ owed`); boundary: three transfers can leave a residual at 19 bps (counterexample expected); the 2.11 example (transfers 5,002,500,000, 5,002,500, 5,002, 5; `P = 5,007,507,507`) | `REQ-SWAP-122`, `REQ-FLASH-003` | PROVED (3) / COUNTEREXAMPLE (boundary) / COMPUTED |
| MATH-ST-112 | Measured conservation with a transfer fee: with the measured `Kf ≤ X` and a fee on the payout transfer, the fee cost `(X − Kf) + payout fee` falls on what the caller receives alone; `A`, `kr`, `B` keep their fee-free values; USDT example `Kf = 4,995`. General form for measured amounts: a fee on the debt asset itself never reaches it on Aave V4, whose Hub refuses the fee-reduced repayment (`InsufficientTransferred`, `REQ-SWAP-123`). | `SPEC-LIQ-010`, `REQ-SWAP-108`, `REQ-SWAP-123`, `REQ-FLASH-003` | PROVED / COUNTEREXAMPLE (deliberate) / COMPUTED |

### `st17_helper_funding.py`: how a flash liquidation helper call is funded

The helper pulls the prefund `X − F + maxShortfall`, approves LPVaultSwap for `X + maxShortfall`, keeps the unused budget `u = maxShortfall − shortfall`, tops up `max(0, F + φ − keeperOut − u)` and pays the rise of its balance; the operator variant bounds `F` by `⌈D × 1.05⌉` and the Safe's net outlay by `⌊D × MAX_TOP_UP_BPS / 10⁴⌋`, and accepts `F = 0`, a call with no loan and no premium (2.11 `REQ-HELPER-003`, `-004`, `-006`, `-007`, `-008`, `-011`).

| ID | Statement | Verifies | Result |
|---|---|---|---|
| MATH-ST-124 | With the prefund and the loan the helper holds `X + maxShortfall ≥ X + shortfall` when LPVaultSwap pulls; the allowance covers both pulls; `keeperOut ≥ 0`, `u ≥ 0`. | `REQ-HELPER-004`, `REQ-HELPER-006`, `SPEC-LIQ-019` | PROVED |
| MATH-ST-125 | `payout = max(0, keeperOut + u − F − φ) ≥ 0`; a top-up and a payout are never both positive. | `REQ-HELPER-007`, `REQ-HELPER-008`, `SPEC-LIQ-019` | PROVED |
| MATH-ST-126 | The payer's net outlay is `outlay − payout = D + A + B − R + φ`; the shortfall pulled cancels. | `REQ-HELPER-011`, `REQ-HELPER-008`, `SPEC-LIQ-010`, `SPEC-LIQ-019` | PROVED |
| MATH-ST-127 | a: a completed operator call costs the Safe at most `⌊D × b / 10⁴⌋`, whatever `X`, `F`, `maxShortfall`, `maxTopUp`; b: a call that gains for the Safe is never refused by the outlay bound; c: a loan within `need` pays at most `⌈need × p / 10⁴⌉` premium; d (wrong reading, review FL-02): a top-up bound on the signer's `X` with no loan or outlay bound lets an oversized loan's 5 bps premium cost the Safe more than `⌊D × b / 10⁴⌋` even when the routes recover above the debt. | `REQ-HELPER-011`, `REQ-HELPER-007`, `SPEC-LIQ-015` | PROVED (3) / COUNTEREXAMPLE (deliberate) |
| MATH-ST-128 | 2.11 examples: the `SPEC-LIQ-019` floor case through the helper (shortfall 123.373998, `keeperOut` 12,297.373998, `u` 76.626002, payout 368 USDC; with `F = 1` USDC 12,372.9995); `need` 2,047.5 USDC; the review PoC loss 4,926.7 USDC; outlay bound 19.5 USDC; losses 50.975 and 10.975 USDC; top-up 101.02375 USDC; the GHO example from the Pool (premium 0.975, payout 69.825 GHO); `F < X` payout 167.325 and `minPayout` 166.5 USDC; the 98 USDC bound at `D = 9,800`. | `REQ-HELPER-006`, `REQ-HELPER-008`, `REQ-HELPER-011`, `REQ-HELPER-015`, `SPEC-LIQ-019` | COMPUTED (17) |
| MATH-ST-129 | The operator's zero loan (`F = 0`, no premium): a: no top-up, payout `keeperOut + u`, net outlay `D + A + B − R`; b: a completed call costs the Safe at most `⌊D × b / 10⁴⌋` and `F ≤ need` holds; c: examples (Bob: payout 2,020.8 USDC, Safe gains 70.8; `R = 1,900`: net outlay 50 USDC, refused; `R = 1,940`: 10 USDC, settles; floor case: payout 12,374 USDC, net 174). MATH-ST-124 to -127 cover `0 ≤ F ≤ X`. | `REQ-HELPER-003`, `REQ-HELPER-004`, `REQ-HELPER-008`, `REQ-HELPER-011`, `SPEC-LIQ-019` | PROVED (2) / COMPUTED (7) |

## Findings

Four properties of the specification failed on 2026-11-10; all four are resolved in the spec text and their checks now pass (finding 1: `FINDING-195`; 2: `FINDING-199`; 3: `FINDING-190`; 4: `FINDING-167`, with `SPEC-FLR-005` changed to `× CF_t / 10⁴`). The other counterexamples are deliberate: wrong readings the specification rules out, out-of-bound states, or boundaries the specification states itself; the old texts of findings 3 and 4 are now kept as such wrong readings.

1. **`SPEC-SET-002` example used parameters at which no draw happens (low; MATH-ST-58).** Resolved, and the settlement budget it concerned no longer exists (`Q-397`); MATH-ST-58 now bounds the caller's rounding gap.

2. **`SPEC-LIQ-014` example omits the USDT price from `U` (low; MATH-ST-84).** With USDT at $0.9995, `U = 10¹² + 999,500,000,000 = 1,999,500,000,000` wei, not `2·10¹²`. Recommended change in [2.11](../../../02-contracts/11-lpvaultswap.md) `SPEC-LIQ-014`, Example: replace "`U = 2·10¹²` wei, and `minPending = 83.5273639 − 0.000002 − 1 = 82.5273619` GHO" with "`U = 1.9995·10¹²` wei, and `minPending = 83.5273639 − 0.0000019995 − 1 = 82.5273619005` GHO". The USDC leg's minimum, 40.576399 GHO, is correct.

3. **`SPEC-LIQ-020` health-factor threshold ignores the unit allowance and rounding (low; MATH-ST-75).** Counterexample: `s = 100`, `maxFlashFeeBps = 0`, `U = 2·10¹²`, `V = 10¹⁸ + 1` wei: `Vnet = x = 0.989998` GHO, and at `HF = CF/0.99` exactly `x·HF = 0.99999798·CF < V·CF`, so the health factor falls (the AaveAdapter's `HealthFactorNotImproved` check then reverts the call). Recommended change in [2.11](../../../02-contracts/11-lpvaultswap.md) `SPEC-LIQ-020`, Why: replace "which the sizing meets for every account with `HF ≥ CF × (10⁴ + maxFlashFeeBps) / (10⁴ − s)` (0.3152 at CF 0.312 and `s = 100`)" with "which the sizing meets for every account with `HF ≥ CF × (10⁴ + maxFlashFeeBps) × V / ((10⁴ − s) × V − 10⁴ × (U + 2) − maxFlashFeeBps)` (0.3152 at CF 0.312, `s = 100` and any repayment above 1 GHO)". MATH-ST-75 proves this threshold.

4. **`SPEC-FLR-005` tail term divides by `minOpeningHealthFactor` (low, guidance only; MATH-ST-77; the same finding as MATH-AR-44b on `SPEC-CAP-007`).** The opening health factor bounds debt only at borrowing; interest and the other leg's price can raise an account's debt to `booked × CF_t` (HF 1) before it is liquidatable, and a complete token failure then loses all of it. Counterexample: booked 1, `CF_t = 0.5`, `minOpeningHealthFactor = 1.5`, debt 0.375 > tail 0.333. Recommended change in [2.14](../../../02-contracts/14-first-loss-reserve.md) `SPEC-FLR-005` (and in `SPEC-CAP-007`(ii), `SPEC-CAP-008`, the `tokenUsdCap` row of [1.5](../../../01-architecture/05-parameters.md) and `Q-249`): replace `× CF_t × 10¹⁴ / minOpeningHealthFactor⌉` with `× CF_t × 10¹⁴ / 10¹⁸⌉` (that is, `× CF_t`), and "an account at the opening health factor then owes at most its collateral value × `CF_t / minOpeningHealthFactor`" with "an account that is not yet liquidatable owes at most its collateral value × `CF_t`". The Example becomes: factor 0.312; a 100,000 GHO reserve covers a token cap of $320,512 less the token's slices; `tail_GHO = min(420,000 × 0.312, 2,000,000) = 131,040` GHO; `tailCoverageBps = ⌊100,000 × 10⁴ / 131,040⌋ = 7,631`; the DAO lowers the USDe cap to at most $300,512 or raises the asset's minimum to 131,040 GHO and funds it. MATH-ST-78 proves the corrected term.

Two results describe the final text without changing it: the decrement in `SPEC-LIQ-020`'s `X*` never fires (MATH-ST-72), and the per-leg minimums add more than rounding to the floor only when one leg's value is near 0, by at most `⌊allowance/2⌋` (MATH-ST-64, MATH-ST-67), a case `SPEC-LIQ-018` already describes as the pool trading away from the oracle price.

## Results

**315 checks after the removal of the settlement budget and of in-kind settlement, the flash-source cap rule, the LitePSM gem amount and the V3.4 half-up premium check (2026-11-10), 323 with the helper funding checks of st17 (2026-11-11), 326 with the operator's zero loan (MATH-ST-129, 2026-11-11): every script exits 0, 0 mismatches, 0 timeouts.** The table gives the re-run of every script on 2026-11-11 (one at a time, from `spec/05-verification`): 290 checks, because st02 now reports 73 checks (49 proved, 24 deliberate counterexamples) plus 20 `[MAX]` searches after the option C rewrite removed the premium terms, and st03, st09 and st12 carry the checks added since (st09 `MATH-ST-114`).

| Script | Checks | Proved | Counterexample | Computed | Mismatch | Exit |
|---|---|---|---|---|---|---|
| st01 | 4 | 2 | 2 | — | — | 0 |
| st02 | 73 | 49 | 24 | — | — | 0 |
| st03 | 17 | 14 | 3 | — | — | 0 |
| st04 | 19 | 16 | 2 | 1 | — | 0 |
| st05 | 6 | 4 | 2 | — | — | 0 |
| st06 | 5 | 4 | 1 | — | — | 0 |
| st07 | 6 | 3 | 3 | — | — | 0 |
| st08 | 11 | 10 | 1 | — | — | 0 |
| st09 | 8 | 7 | 1 | — | — | 0 |
| st10 | 26 | 22 | 4 | — | — | 0 |
| st11 | 11 | 8 | 2 | 1 | — | 0 |
| st12 | 19 | 17 | 2 | — | — | 0 |
| st13 | 4 | 3 | 1 | — | — | 0 |
| st14 | 16 | — | — | 16 | — | 0 |
| st15 | 8 | 3 | 1 | 4 | — | 0 |
| st16 | 46 | 29 | 8 | 9 | — | 0 |
| st17 | 11 | 8 | 1 | 2 | — | 0 |
| **Total** | **290** | **199** | **58** | **33** | **0** | **0** |

### Run log

| Date | Command | Versions | Bounds | Result | Exit |
|---|---|---|---|---|---|
| 2026-11-10 | `.venv/bin/python z3/settlement/<script>.py` for st01…st14, from `spec/05-verification` | Python 3.9.6, z3-solver 4.13.0 | amounts < 2¹²⁸ (waterfall), `D ≤ 10²⁶` wei, shares < 2¹²⁰, 120 s per query; no random seeds | 269 checks as above; slowest script st10 (30 s) | 0 for st01–st03, st05–st11; 1 for st04, st12, st13, st14 (findings 1–4) |
| 2026-11-10 | `.venv/bin/python z3/settlement/<script>.py` for st04, st12, st13, st14, from `spec/05-verification`, after the spec fixes of findings 1–4 | Python 3.9.6, z3-solver 4.13.0 | as above | st04 23 proved, 5 counterexamples, 1 computed; st12 13 / 1; st13 3 / 1; st14 16 computed; every script reports 0 results differing from the documented ones | 0 for all four |
| 2026-11-10 | `.venv/bin/python z3/settlement/<script>.py` for st01…st15, from `spec/05-verification`, after the debt-asset settlement refactor (`Q-333`…`Q-348`) | Python 3.9.6, z3-solver 4.13.0 | as above | 277 checks; st03, st04, st11 and st15 rewritten or extended; 0 differ from documented results | 0 |
| 2026-11-10 | `.venv/bin/python <script>.py` for st01…st16, from `spec/05-verification/z3/settlement` (consolidation: MATH-ST-72, `-85`, `-94` retargeted to the flash of the debt asset with payout in the debt asset; st16 added) | Python 3.9.6, z3-solver 4.13.0 | as above; the informational MATH-ST-64 maximum at s = 30 runs with a 600 s limit | 313 checks; 0 differ from documented results | 0 |
| 2026-11-10 | `.venv/bin/python z3/settlement/st10_leg_minout.py`, from `spec/05-verification`, after the dust-leg rule (`REQ-SWAP-121`) | Python 3.9.6, z3-solver 4.13.0 | as above | st10: 26 checks (MATH-ST-111 added, 5 proved); 0 differ from documented results | 0 |
| 2026-11-10 | `../../.venv/bin/python <script>.py` for st01…st16, from `spec/05-verification/z3/settlement`, after the no-minimum-debt decision (`Q-381`) and the budget reserve, flash-source Hub and transfer-fee rules (`Q-387`, `Q-388`, `Q-390`): MATH-ST-108 rewritten to the record-cap gas fit, MATH-ST-109/110 extended, MATH-ST-111/112 added | Python 3.9.6, z3-solver 4.13.0 | as above | 322 checks (st16: 51); 0 differ from documented results | 0 |
| 2026-11-10 | `../../.venv/bin/python <script>.py` for st01…st16, from `spec/05-verification/z3/settlement`, after the removal of the settlement budget and in-kind settlement (`Q-397`, `Q-401`): st04 and st05 rewritten under their IDs to the caller's rounding gap and the payout escrow; st03, st11, st14, st15, st16 updated | Python 3.9.6, z3-solver 4.13.0 | as above | 303 checks; 0 differ from documented results | 0 |
| 2026-11-10 | `../../.venv/bin/python st11_buy_leg.py`, from `spec/05-verification/z3/settlement`, after the flash-source cap rule (SettlementMath review S3): MATH-ST-115 added | Python 3.9.6, z3-solver 4.13.0 | as above | st11: 10 checks (7 proved, 2 counterexamples, 1 computed) and one `[MAX]` of 999; 0 differ from documented results | 0 |
| 2026-11-10 | `.venv/bin/python z3/settlement/st15_debt_asset_settlement.py`, from `spec/05-verification`: MATH-ST-120 added (LitePSM gem amount, `REQ-ROUTE-012`) | Python 3.9.6, z3-solver 4.13.0 | as above; `D < 2¹²⁸`, `tout < 10³⁶`, `c ≤ 10¹⁸` | st15: 8 checks (3 proved, 1 counterexample, 4 computed); 0 differ from documented results | 0 |
| 2026-11-10 | `../../.venv/bin/python <script>.py` for st03, st04, st12, st14, st15, st16, from `spec/05-verification/z3/settlement`, after the SettlementMath review fixes (S2 settlement gap on the whole flash obligation, S4 `ε` in `Vnet`): MATH-ST-121, `-122`, `-123` added; MATH-ST-17, `-18`, `-26`, `-53`, `-60` restated (a binding gap now settles with `keeperOut = 0`; MATH-ST-53 and `-60` were PROVED for `keeperOut < 0` before) | Python 3.9.6, z3-solver 4.13.0 | as above | st03 18 checks, st04 19, st12 19, st14 16, st15 8, st16 46; 0 differ from documented results | 0 |
| 2026-11-10 | `../../.venv/bin/python st11_buy_leg.py`, from `spec/05-verification/z3/settlement`, after the flash-source review (V3.4 charges half-up; the source's ceiling quote is the binding gate): MATH-ST-115 gains the half-up ≤ quote check | Python 3.9.6, z3-solver 4.13.0 | as above | st11: 11 checks (8 proved, 2 counterexamples, 1 computed) and one `[MAX]` of 999; 0 differ from documented results | 0 |
| 2026-11-10 | `../../.venv/bin/python <script>.py` for st01, st02, st03, st04, st14, st15, st16, from `spec/05-verification/z3/settlement`, after the option C rewrite of 2.11 (`Q-404`: caller-funded liquidation, one entry point, no flash term in any liquidation formula): st02 drops the premium from `s` and proves the listing check implies the `10⁸` bound (MATH-ST-13); st03 and st04 restated on `Kf ≥ D` (the gap never exceeds the floor gap, `keeperOut ≥ 0`, MATH-ST-14…26, -51…60, -96…100, -121, -122); st15 and st16 recompute the 2.11 examples without `φ` (MATH-ST-101, -104, -105, -109, -110, -112); st14 MATH-ST-88 restated | Python 3.9.6, z3-solver 4.13.0 | as above | st01: 4 checks; st02: 73 checks; st03: 17 checks (14 proved, 3 counterexamples); st04: 19 checks; st14: 16 checks; st15: 8 checks; st16: 46 checks; 0 differ from documented results in every script | 0 |
| 2026-11-11 | `../../.venv/bin/python <script>.py` for st15, st14 and st12, one at a time, from `spec/05-verification/z3/settlement`, after the 2026-11-11 decisions: st15 MATH-ST-101 states the `SPEC-LIQ-020` premium the Pool charges (half up, `φ = 1,037,962`, `assetOut = 19,237,965`) beside the ceiling quote 1,037,963, and the 9 bps line under both roundings (2,077,792,405); st14 MATH-ST-83 uses LPVaultSwap's `POST_CALL_GAS = 10,000` (`required = 111,588`, 2.11 `REQ-SWAP-076`); st12 unchanged, re-run for the restated `SPEC-LIQ-020` | Python 3.9.6, z3-solver 4.13.0 | as above | st15: 8 checks; st14: 16 checks; st12: 19 checks; 0 differ from documented results in every script | 0 |
| 2026-11-11 | `../../.venv/bin/python st17_helper_funding.py`, from `spec/05-verification/z3/settlement`, after the helper review fixes (FL-01 shortfall budget through the helper, FL-02 operator bounds on the debt repaid, GHO from the flash minter): st17 added with MATH-ST-124 to MATH-ST-128 | Python 3.9.6, z3-solver 4.13.0 | integers, `X`, `maxShortfall` below 2¹²⁸, `MAX_TOP_UP_BPS ≤ 10⁴`, premium rate ≤ 100 bps | st17: 8 checks (6 proved, 1 counterexample, deliberate, 1 computed); 0 differ from documented results; 1 s | 0 |
| 2026-11-11 | `../../.venv/bin/python st17_helper_funding.py`, from `spec/05-verification/z3/settlement`, after the operator helper accepted `F = 0` (2.11 `REQ-HELPER-003`, `-004`, `-011`): the flow allows `0 ≤ F ≤ X` with no premium at `F = 0`, MATH-ST-129 added | Python 3.9.6, z3-solver 4.13.0 | as above | st17: 11 checks (8 proved, 1 counterexample, deliberate, 2 computed); 0 differ from documented results; 1 s | 0 |
| 2026-11-11 | `../../.venv/bin/python st17_helper_funding.py`, from `spec/05-verification/z3/settlement`, after the helper moved GHO to the Aave V3 Pool, its only lender (2.11 `REQ-HELPER-015`, `REQ-FLASH-010`): the MATH-ST-128 GHO example is the Pool's 5 bps premium, half up (0.975 GHO), with the same payout of 69.825 GHO | Python 3.9.6, z3-solver 4.13.0 | as above | st17: 11 checks (8 proved, 1 counterexample, deliberate, 2 computed); 0 differ from documented results; 1 s | 0 |
