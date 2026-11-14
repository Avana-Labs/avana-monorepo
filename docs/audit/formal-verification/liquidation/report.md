# Liquidation area: internal formal verification report

> **Area:** liquidation · **Check prefix:** `FV-LIQ-` · **Spec state:** pages 2.11–2.14, 2.17, 2.18, 3.5, 3.9 in the debt-asset settlement design (decisions `Q-001`…`Q-348`, re-verified 2026-11-10, section 10) · **Aave V4 pin:** `a3ef63ea6415d25237a9775bf66e76e9993561c2`

## 1. Project summary

### Scope

| Contract / component | Spec | What is modelled |
|---|---|---|
| LPVaultSwap (`liquidate`, `liquidatePermissionless`, `onFlashLoan`, `settlePending`, `deleverage`, keeper list) | 2.11, 3.5 | Every entry check, funding in the debt asset (caller funds and the `IFlashSource` flash loan), the standard Spoke's `liquidationCall`, burn and n-token unwind, swaps into the debt asset, floor, waterfall with the fee / keeper / borrower split, in-kind settlement, payouts, residues, allowances, pending settlement |
| SettlementMath (internal library) | 2.11 `SPEC-LIQ-001`…`022` | Every formula with its exact rounding |
| `IFlashSource` (`AaveV3FlashSource`) | 2.11 `REQ-FLASH-001`…`010` | Pre-loan liquidity and premium checks, the lender gate, callback authentication |
| Swap routes into the debt asset | 2.12 | Access, exact pull, oracle `minOut`, residue return, callbacks |
| Caller top-up (the SettlementBudget is removed, `Q-397`) | 2.11, 2.13 | `shortfall = max(0, minRec − R, D + φD − K − R)` pulled from the caller within `maxShortfall`; no shared pool pays any gap (section 11) |
| Coverage Spokes and Aave's deficit path | 2.14, 3.9; Aave `Hub.eliminateDeficit`, `LiquidationLogic._evaluateDeficit` | Coverage amount, share burn, share price, isolation per asset, withdrawal lifecycle, when a deficit is reported |
| PayoutEscrow (payout escrow, `Q-401`) | 2.18 | Deposit of failed payouts only, claim, direct transfers, reentrancy |
| Aave V4 liquidation sizing | `LiquidationLogic.sol`, `SharesMath.sol` at the pin | Target-HF debt, bonus curve, dust rule, all-collateral branch, `MustNotLeaveDust`, debt rounding |
| Lens liquidation preview | 2.17 `REQ-LENS-016`, `017`, `028`, `029` | Preview formulas against Aave's sizing |

Implementation code did not exist on the run date; every property is proved on the specified behaviour. Tools: Z3 4.13 (Python), Hypothesis 6.112, Quint 0.22 simulator.

### Protocol overview of the area

A liquidation of an Avana account enters only through LPVaultSwap. The CDP Spoke is a standard Aave V4 Spoke; LPVaultSwap calls its 5-argument `liquidationCall(collateralReserveId, debtReserveId, user, debtToCover, false)`, and exclusivity comes from the vault token, whose transfer rule admits a seizure only from the Hub to LPVaultSwap. LPVaultSwap funds the repayment in the debt asset itself, from the caller's funds or a flash loan through the chain's `IFlashSource` (the Aave V3 Pool `flashLoan`, checked for liquidity, premium and lender before the loan and authenticated in the callback). Aave sizes the repayment `D` and the seizure `c`; the debt asset Aave does not take stays in LPVaultSwap and repays the flash loan. LPVaultSwap burns the seized vault tokens, has Collateralization unwind exactly the seized units into the market's n tokens, swaps each token into the debt asset over fixed routes with oracle minimums, requires the recovery floor, draws the SettlementBudget for rounding gaps and pays, in the debt asset, Avana's 20 % share of the oracle gain, the keeper reward and the borrower surplus. Approved keepers may also settle in kind. Deficits that Aave records when an account's last collateral is gone are covered by the Coverage Spoke of each (Hub, debt asset).

## 2. Assessment methodology

- **Rules** are proved over a symbolic pre-state and symbolic inputs: `prove` first finds a witness for the premise (a vacuous premise fails the check), then asks Z3 for a counterexample to the claim; `unsat` is a proof for every input in the stated ranges.
- **Encodings.** Integer floors and ceilings are kept as their two defining inequalities. Claims that need only those inequalities are decided over the reals with nlsat (complete for nonlinear real arithmetic), so they cover every integer input; where a claim needs integrality the real step proves `x < y + 1` and the integer step `x ≤ y` is stated beside it. Waterfall and budget claims are linear integer arithmetic.
- **Inductive invariants** (PayoutEscrow, budget setters, Coverage withdrawal lifecycle): base case plus a step case for every operation that writes the state, on an arbitrary pre-state satisfying the invariant; mapping sums use a hook-maintained ghost.
- **Symbolic execution of LPVaultSwap.** All 170 control paths of the two liquidation entry points (debt kind × funding × route mode × primary or backup per leg × GHO pool leg × sell-back × in-kind delivery or escrow × buy route) run over LPVaultSwap's ledger with symbolic amounts and an arbitrary donated balance per token; each property is proved per path under that path's success condition.
- **Aave sizing** is ported line by line (`aave_ref.py`); the lemmas LPVaultSwap depends on are proved over products of symbolic prices and cross-checked on the exact port with Hypothesis (2,845 successful random liquidations).
- **Two-execution comparison** proves donation independence (FV-LIQ-03k).
- **Multi-actor sequences** are simulated in Quint (10,000 random traces × 25 steps per run); results are labelled randomized.
- **Mutation checks.** Twelve injected bugs (dropped `onFlashLoan` checks, dropped `draw` checks, residue kept, `R` read as an absolute balance, calendar-day buckets, double claim without the reentrancy flag, dropped `REQ-HUB-033` / `REQ-PROXY-043`, the pre-revision buy-delivery rule) are each caught by the rule that targets them.
- **Security context.** Over-seizure and healthy liquidation → T-32, T-33; flash and callback abuse → T-43; budget draining → T-37, T-38, T-39, F-01, F-02; donation and front-running → T-48, F-05; two-leg conservation → T-30, T-31; fee diversion → F-06; bad debt and coverage → T-46, T-47.
- **Fix validation.** Each recommended formula change is itself proved (FV-LIQ-01p, 01p2, 01r, 01y, 04l). A finding's counterexample check fails once the spec text changes and is then replaced by the fix proof.

## 3. General assumptions and simplifications

| Class | Assumption | Discharge |
|---|---|---|
| Tokens | Standard ERC-20, decimals 6–18 (`REQ-ARCH-014`); a remainder transfer may revert, return `false` or run out of gas (modelled as a failure branch) | Listing; FV-LIQ-03l; gas headroom (`REQ-SWAP-076`) is a Foundry test |
| Prices | `Pc, Pdebt > 0` and `< 2^64`; Aave uses the same `Pc`, `HF` and bonus that LPVaultSwap reads in the same call | Price gates (FV-LIQ-03h, 07k); zero prices fail closed (FV-LIQ-07j); same-call equality is a fork test (`TEST-109`…`111`) |
| Amounts | Amounts `< 2^128`, `b < 2^32`, `maxFlashFeeBps ≤ 100`, `drawnIndex ≤ 100 RAY` | `REQ-SWAP-005`; FV-LIQ-01w* |
| Vault-token Hub asset | Shares equal assets at the call | `REQ-SWAP-007`; `PROP-040` |
| Liquidation fee | `liquidationFee = 0` | Borrow Spoke code (`Q-222`); `bNet` proved for `lf > 0` too |
| External contracts | A route pulls exactly its input and returns the debt asset plus a residue of at most its input; the flash source lends exactly `F` and pulls `F + φ`; swap routes pay at most market value | 2.12 route rules; route prover rules (audit-mapping) |
| Sums over borrowers | Escrow sum part proved on 4 borrower slots (each operation touches one slot); per-borrower part unbounded | FV-LIQ-05b/c |
| Budget sequences | Cap sums over 6 symbolic draws; the per-draw step is unbounded (window lemma for all 96 bucket sizes) | FV-LIQ-04d |
| Quint | Value-level model (USD cents), Aave sizing without the dust rule, three accounts, two markets, two debt assets | FV-LIQ-02 proves the integer sizing; Quint results are randomized evidence |
| Gas | Unbounded | `PAYOUT_TRANSFER_GAS` is a Foundry test |

**Unproved assumptions:** same-call equality of `Pc`, `HF` and the bonus between LPVaultSwap's reads and Aave's use (fork test); swap routes pay at most market value (FV-LIQ-07g); the Aave V3 Pool premium follows `percentMul` half up; the value-level Quint model.

## 4. Findings summary

| Severity | Discovered | Open in the final spec (after FV-LIQ-R3) |
|---|---|---|
| Critical | 0 | 0 |
| High | 0 | 0 |
| Medium | 2 | 1 |
| Low | 7 | 2 |
| Informational | 10 | 7 |

`FV-LIQ-F-01`…`F-09` were found in `FV-LIQ-R1` and are resolved in the final spec (section 9). `FV-LIQ-F-10`…`F-19` were found in `FV-LIQ-R3` against the final pages and are open.

### Severity matrix

| Impact \ Likelihood | Low | Medium | High |
|---|---|---|---|
| **High** | Medium | High | Critical |
| **Medium** | Low | Medium | High |
| **Low** | Low | Low | Medium |

## 5. Detailed findings table

| ID | Title | Severity | Status |
|---|---|---|---|
| FV-LIQ-F-01 | Two-leg slippage `s = 0` branch lets the budget pay a buy premium that is not a rounding gap | Low | Resolved in spec (`Q-261`); 01d, 01t, 03v, 06v |
| FV-LIQ-F-02 | The stated per-draw bound omits Aave's debt rounding; `perCallCap ≥ floorRoundingAllowanceGho` leaves no headroom | Low | Resolved in spec (`Q-267`); 01s, 01s2, 04h–04j, 06w |
| FV-LIQ-F-03 | `φD = flashFee(Gcov)` can exceed `φ`, so a budget draw pays the caller | Low | Resolved in spec (`Q-267`); 01o, 01p, 01p2, 06ab |
| FV-LIQ-F-04 | Lens `expectedUnitsSeized` computed from `D`; Aave seizes from `drawnShares × index` | Informational | Resolved in spec (`Q-268`); 02o, 02q, 06bf |
| FV-LIQ-F-05 | A 1-wei repay front-run at Aave's dust boundary reverts the call, contrary to `REQ-SWAP-005` | Low | Resolved in spec (`Q-268`); 02s, 02t, 02v, 06x; later-block and pledge cases → F-13, F-14 |
| FV-LIQ-F-06 | The caller can divert Avana's fee by converting at the floor or selling back below value | Medium | Resolved in spec (`Q-256`); 01y, 06y; sell-back residual → F-10 |
| FV-LIQ-F-07 | `REQ-CONFIG-050` blocks every allowance change once an approved debt reserve's caps are 0 | Low | Resolved in spec (`Q-267`); 04j, 04k |
| FV-LIQ-F-08 | Buy-route over-delivery accepted by 2.12, rejected by mid-edit 2.11 | Informational | Resolved in spec; 03a, 03q |
| FV-LIQ-F-09 | `LIQ-060` dust case seized more than `D × LB` | Informational | Resolved in spec; 06o |
| FV-LIQ-F-10 | An oversized `debtToCover` sold back at the sell-back floor still lowers Avana's fee | Low | Open |
| FV-LIQ-F-11 | The deleverage health-factor threshold of `SPEC-LIQ-020` misses the `U` and rounding terms | Informational | Open |
| FV-LIQ-F-12 | `SPEC-LIQ-018` overstates how close the leg minimums sum to the floor when a leg is dust | Informational | Open |
| FV-LIQ-F-13 | A whole-debt Lens quote reverts `MustNotLeaveDust` once interest accrues before inclusion | Medium | Open |
| FV-LIQ-F-14 | A collateral-limited non-GHO Lens quote reverts after a pledge into the market | Low | Open |
| FV-LIQ-F-15 | `getTailCoverage` overflows when a `drawCap` is unlimited | Informational | Open |
| FV-LIQ-F-16 | The `SPEC-SET-002` example sits in the `s = 0` branch, where no draw is allowed | Informational | Open |
| FV-LIQ-F-17 | The `LIQ-069` / `REQ-LENS-017` account does not give the stated `D` and seizure | Informational | Open |
| FV-LIQ-F-18 | `DEF-006` writes the share burn without the virtual offset | Informational | Open |
| FV-LIQ-F-19 | `LIQ-068` step 1 floors the health factor to 0.9997; the value floors to 0.9996 | Informational | Open |

## 6. Findings

### FV-LIQ-F-01: the two-leg slippage `s = 0` branch lets the budget pay a buy premium

- **Severity:** Low. Impact Medium: budget loss up to the reserve's caps, and large liquidations of that debt revert without caller GHO. Likelihood Low: needs `buySlippageAllowanceBps ≥ minLiquidationBonus − flash costs`, which only the off-chain fork check of `REQ-HUB-037` excludes.
- **Spec rules:** `SPEC-LIQ-016`, `SPEC-SET-001`, `REQ-SWAP-029`, `REQ-PSTORE-006`, `REQ-CONFIG-045`, `REQ-HUB-037`.
- **Violated property:** T-35, "the slippage inequality holds for every bonus and cost in range", and T-39, "each draw is a rounding gap". Checks FV-LIQ-01d, 01t, 06v.
- **Description:** `SPEC-LIQ-016` sets `s = 0` when `bNet × 10⁴ ≤ (10⁴ + costsBps)(10⁴ + cBuy)`. The parameter bounds allow this: `minLiquidationBonus ≥ 200` bps and `buySlippageAllowanceBps ∈ [1, 300]`. In that branch the floor covers `V`, worth about `D × bNet`, while `Gcov` can reach `bound(D) = D × (1 + cBuy)`. So `Bd` grows linearly with `D`.
- **Counterexample (exact integers):**
  - Setup: USDC debt, `cBuy = 300`, bonus 10,200 just below HF 1, so `s = 0`.
  - `D = 2,500` USDC, bought at the bound: `G = Gcov = 2,575` GHO. `V = 2,550` GHO. The routes return exactly `minGho = 2,548.999998` GHO.
  - Result: `Bd = 26.000002` GHO. That is above the 25 GHO per-call cap, so the call reverts.
  - At `D = 2,300` USDC the same call draws 24.000002 GHO from the budget. That is 24 times the rounding bound of `SPEC-SET-002`.
- **Recommendation:**
  1. `REQ-PSTORE-006`, add: "`setBuySlippageAllowanceBps` and `MarketRegistry.approveDebtReserve` MUST revert with `LivenessBound` unless, for every market on the Spoke, `minLB × (10⁴ − slippageAllowanceMinBps) × 10⁴ ≥ 10⁴ × (10⁴ + maxFlashFeeBps) × (10⁴ + buySlippageAllowanceBps)`, with `minLB` from `SPEC-HUB-005`."
  2. `SPEC-SET-001`, add: "When `bNet × 10⁴ ≤ (10⁴ + costsBps)(10⁴ + cBuy)`, LPVaultSwap sets `Bd = 0`, and a call that would need a draw reverts with `InsufficientProceeds`."

### FV-LIQ-F-02: the stated per-draw bound omits Aave's debt rounding

- **Severity:** Low. Impact Low. Likelihood Medium: any honest dust liquidation of a non-GHO debt bought at the bound.
- **Spec rules:** `SPEC-SET-002`, `SPEC-LIQ-005`, `REQ-BUDGET-006`, `REQ-BUDGET-017`, `REQ-CONFIG-050`, 2.13 Purpose.
- **Violated property:** T-39, "each draw ≤ one base unit + 1 wei + `U + floorRoundingAllowanceGho`". Checks FV-LIQ-01s, 06w.
- **Description:**
  - Aave prices the seizure from `drawnShares × drawnIndex + premiumRay`, but pulls `D = rayMulUp(drawnShares, index) + fromRayUp(premium)`.
  - `D` is therefore up to 2 debt units more than the debt the seizure was priced from, and up to `2 + index/RAY` units more on the all-collateral branch (FV-LIQ-02f–i).
  - `bound(D)` also rounds up by 1 wei.
  - The proved bound (FV-LIQ-01r) is `Bd < one vault unit + 2 wei + U + fra + ε × (one debt unit in GHO) × (1 + cBuy)`.
  - Since `perCallCap = fra` is allowed, an honest dust draw can exceed the per-call cap.
- **Counterexample:**
  - Setup: USDC debt, `cBuy = 200`, bonus 10,200 (the two-leg inequality holds with equality), `drawnIndex = 1.5 RAY + 7`, premium 1e-27 USDC.
  - Aave pulls `D = 999,999,999` units.
  - With `R = minGho` and `G = bound(D)`, `Bd = 1.00000353` GHO.
  - The stated bound is 1.000002000000000003 GHO, so the excess is 1.53 × 10¹² wei. With `perCallCap = fra = 1` GHO the call reverts with `PerCallCapExceeded`.
- **Recommendation:**
  1. In `SPEC-SET-002` and the 2.13 Purpose, replace "one vault unit plus 1 wei plus `U + floorRoundingAllowanceGho`" with "one vault unit plus 2 wei plus `U + floorRoundingAllowanceGho` plus `(2 + ⌈drawnIndex / RAY⌉)` debt-asset base units valued at `Pdebt × (1 + buySlippageAllowanceBps)`".
  2. In `REQ-BUDGET-006` and `REQ-BUDGET-017`, require `perCall ≥ 2 × floorRoundingAllowanceGho`.
  3. In `REQ-CONFIG-050`, require `2 × floorRoundingAllowanceGho ≤ perCallCap`.

### FV-LIQ-F-03: `φD = flashFee(Gcov)` can exceed `φ`, so a budget draw pays the caller

- **Severity:** Low. Impact Low. Likelihood Low: needs a non-zero FlashMinter fee for LPVaultSwap.
- **Spec rules:** `SPEC-LIQ-007`, `SPEC-LIQ-010`, `SPEC-SET-001`, `REQ-SWAP-029`, `REQ-BUDGET-004`.
- **Violated property:** `SPEC-LIQ-010`, "When `Bd > 0`, `keeperOut = (Gcov − Gnet) + (φD − φ) ≤ 0`", and T-36. Check FV-LIQ-01o.
- **Description:** When the caller brings GHO (`K > 0`), the flash loan `F` can be smaller than `Gcov`. Then `φD = fee(Gcov) > φ = fee(F)`. The draw covers a fee that was never charged, and the difference `φD − φ` is paid to the caller from budget GHO.
- **Counterexample:** fee 9 bps, `F = 1` wei, `K = 0`, `Gcov = Gnet = 556` wei, `R = 556`. Then `φ = 0`, `φD = 1`, `Bd = 1`, and `keeperOut = 1`.
- **Recommendation:** in `SPEC-LIQ-007`, replace `φD = GhoFlashMinter.flashFee(GHO, Gcov)` with `φD = GhoFlashMinter.flashFee(GHO, min(F, Gcov))`. Proved: `φD ≤ φ` for every fee rate, and `Bd > 0` then implies `keeperOut ≤ 0` (FV-LIQ-01p, 01p2).

### FV-LIQ-F-04: the Lens `expectedUnitsSeized` differs from Aave's seizure

- **Severity:** Informational. It affects previews only; LPVaultSwap measures by balance delta.
- **Spec rules:** `REQ-LENS-029`, `REQ-LENS-017`.
- **Description:** `REQ-LENS-029` computes `⌊D × Pdebt × bonus × 10^dv / (10^dd × Pc × 10⁴)⌋` from `D`. Aave computes the seizure from `drawnShares × drawnIndex + premiumRay ≤ D × RAY`. The two differ by one unit whenever `D` was rounded up, so the exact-equality fork test of `REQ-LENS-017` fails for such accounts.
- **Counterexample (FV-LIQ-02o):** GHO debt, `drawnIndex = 1.5 RAY + 1`, `debtToCover = 100` GHO, `Pc = 2.00`, `dv = 6`, bonus 10,200. Aave pulls `D = 100` GHO and seizes 50,999,999 units; the Lens returns 51,000,000.
- **Recommendation:** `REQ-LENS-029`: "`expectedUnitsSeized` is Aave's `_calculateCollateralToLiquidate` on the `drawnShares` and `premiumDebtRay` that `REQ-LENS-017`'s compiled sizing returns, capped by the supplied shares as in `liquidationCall`."

### FV-LIQ-F-05: a 1-wei repay front-run at Aave's dust boundary reverts the call

- **Severity:** Low. Impact Low: griefing, and the keeper re-previews. Likelihood Medium: any address can repay 1 wei of another account's debt.
- **Spec rules:** `REQ-SWAP-005`, `REQ-LENS-028`.
- **Violated property:** `REQ-SWAP-005`, "a 1-wei repay or a new pledge between preview and inclusion does not make the call revert". Check FV-LIQ-06x.
- **Description:** If the debt left after `debtToCover` sits exactly at Aave's `DUST_LIQUIDATION_THRESHOLD` ($1,000), a 1-wei repay pushes the remainder below it. Aave then requires the whole debt, and `liquidationCall` reverts with `MustNotLeaveDust`.
- **Counterexample (Aave port):** an account with 1,500 GHO of debt at HF 0.70. A call with `debtToCover = 500` GHO succeeds. After someone repays 1 wei, the same call reverts with `MustNotLeaveDust`.
- **Recommendation:**
  1. `REQ-LENS-028`: "For a GHO debt reserve, `params.debtToCover` is the account's whole debt in that reserve (Aave still repays only its target amount). For any other reserve, it is the whole debt when the debt left after the previewed amount is within `dustMarginBps` of `DUST_LIQUIDATION_THRESHOLD`."
  2. `REQ-SWAP-005`, end the last sentence with: "…except when it moves the account across Aave's dust threshold, which the Lens preview avoids (`REQ-LENS-028`)."

### FV-LIQ-F-06: the caller can divert Avana's fee

- **Severity:** Medium. Impact Medium: up to Avana's whole share of a liquidation's surplus, which is Avana's only on-chain revenue. Likelihood Medium: needs a DEX route the caller can sandwich, which `BackupOnly` mode or a DEX primary route provides.
- **Spec rules:** `SPEC-LIQ-008`, `SPEC-LIQ-009`, `REQ-SWAP-089`, `REQ-ROUTE-009`, `REQ-SWAP-022`.
- **Violated property:** the intent of T-36 (Avana takes 20 % of the realized surplus), and requested invariant 5 (every swap limit is derived from the oracle). Checks FV-LIQ-01z, 06y, 06z, 07i.
- **Description:**
  - The fee is `A = ⌊S × 20 %⌋`, with `S = R − Gnet − φD` measured after the caller's own routing.
  - A caller that sandwiches its own conversion keeps the difference outside `R`. Every GHO diverted lowers `A` by 0.2 GHO.
  - The settlement legs are bounded by the recovery floor, but the sell-back has no floor at all. With an oversized `debtToCover`, the whole surplus can be routed out through the sell-back.
- **Counterexample (LIQ-069 numbers):**
  - Converting at the floor, `R = 5,037.902` GHO instead of 5,085: `A` falls from 17 to 7.58 GHO, and the caller's total rises from 68 to 77.42 GHO (FV-LIQ-06y).
  - Oversizing `debtToCover` by 100,000 USDC and selling the leftover back 85 GHO under value through a sandwiched backup route: `A = 0` and `Bd = 0`, and the call succeeds (FV-LIQ-06z).
- **Recommendation:**
  1. `SPEC-LIQ-009`: replace `A = ⌊S × avanaFeeShareBps / 10⁴⌋` with `A = min(⌊max(0, V − Gcov − φD) × avanaFeeShareBps / 10⁴⌋, S)`. Proved (FV-LIQ-01y): while `S` covers it, lowering `R` or raising `Gnet` cannot lower `A`, and `A ≤ S` keeps the no-revert property.
  2. `REQ-SWAP-089`, add: "…and MUST revert with `RecoveryBelowFloor` if `g' < ⌈amount × Pdebt × 10¹⁸ / (10^dd × Pgho)⌉ × (10⁴ − buySlippageAllowanceBps) / 10⁴ − 1`."

### FV-LIQ-F-07: `REQ-CONFIG-050` blocks every allowance change once an approved reserve's caps are 0

- **Severity:** Low. Impact Low: governance cannot lower or raise `floorRoundingAllowanceGho`. Likelihood Medium: `tightenCaps(spoke, r, 0, 0)` closes a reserve, and `REQ-BUDGET-022` lets a newly approved reserve sit with zero caps.
- **Spec rules:** `REQ-CONFIG-050`, `REQ-BUDGET-006`, `REQ-BUDGET-022`.
- **Violated property:** the allowance setters can no longer run (property family F-25). Check FV-LIQ-04k.
- **Counterexample:** allowance 1 GHO; reserve A has `perCallCap = 25` GHO; reserve B is closed with caps (0, 0). Then `tightenFloorRoundingAllowanceGho(0.5 GHO)` reverts with `OutOfBounds`.
- **Recommendation:** in `REQ-CONFIG-050`, write "for every approved debt reserve of every approved Spoke whose caps are not both 0". Proved to keep the cap invariant (FV-LIQ-04l).

### FV-LIQ-F-08: buy-route over-delivery (fixed in the final pages)

`REQ-ROUTE-031` and `REQ-ROUTE-034` let a buy route deliver more than `amountOut`. The mid-edit 2.11 accepted exactly `X` and sold back `X − D`, which would have stranded the extra (FV-LIQ-03t replays that text). The final `REQ-SWAP-088` accepts at least `X`, and `REQ-SWAP-089` sells everything above the pre-buy balance. FV-LIQ-03q and 03a prove the debt-asset balance returns to its start on every path.

### FV-LIQ-F-09: `LIQ-060` dust numbers (fixed in the final pages)

The mid-edit `LIQ-060` seized the last 400,000 units (0.8 GHO of value) for `D = 0.78` GHO. That is more than `D × LB = 0.7956` and impossible under Aave's sizing (T-32). The final text seizes 397,800 units with `V = 0.7956`. FV-LIQ-06o re-verifies every number.

## 7. Formal verification

### Notation

Status labels: Verified · Verified (bounded) · Verified (randomized) · Violated → finding · Accepted violation · Mutant caught. A timeout or a vacuous premise counts as a failure.

### Properties overview

| Target | Family | Contract | Status | Checks |
|---|---|---|---|---|
| T-30 GHO conservation and no revert once Aave and the budget pass | F-21 | LPVaultSwap, SettlementMath | Verified. The no-revert part holds when `Gnet ≤ bound(D)` and `φ ≤ φD` (see F-03) | 01j, 01l, 01m, 01n, 03c, 06k |
| T-31 balance neutrality and zero allowances | F-21/F-06 | LPVaultSwap | Verified on all 170 paths | 03a, 03b, 03m, 03q |
| T-32 no over-seizure | F-17 | LPVaultSwap / Aave | Verified, in a stronger form: no extra unit is needed | 02a–e, 02n |
| T-33 no healthy liquidation | F-17 | LPVaultSwap | Verified | 03h, 08b |
| T-34 conservative floor rounding | F-11 | SettlementMath | Verified | 01f, 01g |
| T-35 effective slippage inequality | F-24/F-11 | SettlementMath | Verified in the `s > 0` branch; violated in the `s = 0` branch → F-01 | 01a–e |
| T-36 Avana fee bounds | F-14/F-21 | LPVaultSwap | Verified; fee diversion → F-06 | 01k, 01l, 03e, 03i |
| T-37 caller top-up replaces the budget (`Q-397`) | F-01/F-14 | LPVaultSwap | Verified. Pulled from the caller only, within `maxShortfall`, minimal; LPVaultSwap's balance unchanged over 6 symbolic calls | 04a–p |
| T-38 a top-up only when `c ≥ 1` | F-02 | LPVaultSwap | Verified | 03d |
| T-39 rounding-gap bound and repeated small calls | F-08/F-11 | SettlementMath | Verified: a `maxShortfall` of twice the allowance covers every honest gap | 01r, 01s, 01s2 |
| T-40 no in-kind settlement (`Q-401`) | F-11/F-14 | LPVaultSwap | Verified: every payout is in the debt asset apart from route residue | 01u, 03e, 06h |
| T-41 PayoutEscrow conservation, failed payouts only | F-05/F-06 | PayoutEscrow | Verified (inductive) | 05a–h, 05g2, 05p, 03l, 08a/b |
| T-42 a failing remainder transfer goes to the escrow | F-20 | LPVaultSwap | Verified | 03l |
| T-43 callbacks and the flash-fee check | F-23 | LPVaultSwap, routes | Verified | 03n, 03o0–2, 03p |
| T-44 route access, `maxGhoIn`, delivery | F-14/F-21 | Routes | Verified | 01h, 03q, 07h |
| T-45 permissionless path | F-03/F-17 | LPVaultSwap | Verified | 01q, 03f |
| T-46 deficits only with no collateral left; coverage bounds | F-17 | Coverage Spoke, Borrow Spoke | Verified, given `REQ-HUB-033` and `REQ-PROXY-043`; both are load-bearing (02l, 02p) | 02k, 05i, 05k, 05l |
| T-47 funded-balance rounding and withdrawal timing | F-07/F-15 | Coverage Spoke | Verified | 05j, 05m, 05n, 05o, 06s |
| T-48 non-interference and donations | F-12 | LPVaultSwap | Verified | 03j, 03k |
| T-49 `settlePending` | F-01/F-14 | LPVaultSwap | Verified | 01v, 03m, 06j |
| T-50 liveness, keeper floor and cap | F-15 | LPVaultSwap | Payout arithmetic, `keeperFloor = 1` and `MAX_KEEPERS = 32` verified; route availability is an assumption | 01m, 03aa–ac, 08a, 08b |
| T-51 deadline and minimum payout | F-03 | LPVaultSwap | Verified | 03g |
| T-52 no overflow or division by zero | F-24 | LPVaultSwap, routes | Verified | 01w0–7 |

**Properties added from this reading:**
- `SPEC-LIQ-003` equals `SPEC-LIQ-016` at `cBuy = 0` (01c).
- Aave never pulls more than `debtToCover` (02j).
- Lower bound on the seizure (02f–i).
- Bonus range (02m).
- `remainingToday` view integrity (04g).
- Invariant between the allowance and every open per-call cap (04h–j).
- Coverage and funding never lower other suppliers' share price (05j, 05m).
- Splitting changes Avana's fee by less than 1 wei per extra call (01x).
- Every liquidation worked example in the spec (06a–u).

### Requested system invariants

| # | Invariant | Result | Checks |
|---|---|---|---|
| 1 | Solvency per debt asset across multi-actor sequences | **Holds when keepers keep liquidating:** every shock of up to 50 % on one token is followed by liquidation, and 10,000 random traces show no shortfall (randomized). **Violated when liquidation is halted across several shocks** (an Aave pause or a stale price): the shortfall then exceeds the reserve. Code cannot guarantee this invariant; it is the cap-sizing rule `SPEC-FLR-004` over the incident window | 08a, 08c |
| 2 | Liquidations never amplify insolvency | **Equity:** falls by at most the bonus paid. Verified. **HF:** does not fall when `HF ≥ LB × CF` of the seized reserve. Below that, HF falls. This is accepted as inherent to a bonus; Aave then seizes everything and records the deficit | 07a, 07b, 07c, 08b |
| 3 | No zero-risk profit loop | Verified: a borrower that liquidates its own account (either entry point, flash or own debt asset, any re-pledge, its own borrower surplus counted) ends with at most `−(A + φ)`, given swap routes pay at most market value | 07g |
| 4 | No insolvency in a single block | **With fixed prices:** borrowing and withdrawing keep HF ≥ 1.05 (control area). **Exception:** liquidating an account with collateral `C < LB × debt` turns positive equity into a deficit of at most `(LB − 1)/LB × C`. Accepted, because `SPEC-FLR-004`'s `lossFactor` already includes `LB_m`. Concrete case: $10,300 of collateral against 10,000 GHO of debt leaves a 190.48 GHO deficit | 07d, 07e, 07f |
| 5 | Every swap limit is oracle-derived and non-zero | **Buy leg:** verified; `maxGhoIn = min(M, bound) > 0`. **Settlement legs:** the per-leg minimum is 0 by design (`REQ-ROUTE-009`), and the aggregate floor is 0 for dust. **Sell-back:** no floor at all → F-06 | 07h, 07i |
| 6 | Oracle outputs of 0, max, jumps | Fails closed. Zero prices make Aave's sizing revert. Cached, Expired, stale, unknown-source and disagreeing prices block the call. Arithmetic bounds hold for prices up to `2^64` | 07j, 07k, 03h, 01w* |
| 7 | 50 % shock to one pool token | Verified. An account with HF ≥ `2 × LB × CF` before the shock (0.655 at CF 0.312 and LB 1.05; 0.464 for a full-range position) is liquidated without a deficit, and the two-leg floor repays the funding up to the rounding draw. Deficits stay per asset (05l) and per account (03j). The only cross-asset coupling is the shared 24-hour total budget window (`PER_24H_CAP_MAX`), which F-01 would let one reserve use up | 07l, 07m, 05l, 03j |

### Bug-class sweep

| Class | Result | Evidence |
|---|---|---|
| Profit from splitting one liquidation into several | Ruled out. After each step, HF rises or the bonus is already at its maximum, and Aave's bonus never increases with HF, so later steps never pay a higher bonus rate. Avana's fee changes by less than 1 wei per extra call, and each draw is bounded per call | 07n, 02m, 01x, 01r |
| Micro-collateral or dust-deficit griefing | Ruled out: every dust gap is paid by the caller of that liquidation, so no Avana balance pays for repeated small calls | 01r, 03f, 04e |
| Liquidation DoS from unrelated pauses, routes or tokens | Ruled out across accounts and markets: the gates read only the account's own markets and debts, the pause state is not read, and a failing remainder transfer goes to the escrow. A stale debt feed blocks every account that holds that debt (by design, `Q-238`). F-05 is the one griefing revert | 03h, 03j, 03l, 06x |
| Rounding in the liquidator's favour | Every rounding favours the protocol except the bounded allowances (`U`, `floorRoundingAllowanceGho`), the 1-wei ceiling of `bound`, and Avana's fee rounding down (under 1 wei). F-03 is the one leak | 01a–h, 01x |
| Over-seizure, or seizing from a healthy account | Ruled out | 02a–e, 03h |
| Stale or manipulated price used in the seizure | Ruled out for stale, unknown-source and disagreeing prices. `V` and the in-kind value use the oracle, never pool spot | 03h, 07k, 01u |
| 1-wei front-running of a keeper call | Donations ruled out (all measurements are deltas). A 1-wei repay at the dust boundary → F-05 | 03k, 06x |
| Budget or coverage drained by repeated small calls | Coverage ruled out: role, allowlist, and `min(maxAmount, deficit, funded balance)`. No budget exists (`Q-397`); each caller tops up its own gap | 05i, 05k, 04e, 01r |
| Conservation broken on the non-GHO two-leg path | Ruled out: the GHO and debt-asset deltas are 0 on every path, including over-delivery and sell-back residue. `LIQ-069` balances exactly: 10,110 GHO in and out, and 5,000 USDC = 4,990 repaid + 10 sold back | 03a, 03c, 03q, 06k |

### Detailed properties

The counts below are those of `FV-LIQ-R1`; section 9 gives the checks and counts of the re-verification against the final pages.


Run everything with `docs/audit/formal-verification/liquidation/run.sh`. Run a single file with `docs/spec/05-verification/.venv/bin/python docs/audit/formal-verification/liquidation/<file>`.

- **FV-LIQ-01, SettlementMath (34 checks):**
  - 01a–e: net bonus, two-leg inequality, `SPEC-LIQ-003` = `016` at `cBuy = 0`, F-01, flash costs.
  - 01f–h: floor rounding and the buy bound.
  - 01i–n: `Gcov`, waterfall and conservation.
  - 01o, 01p, 01p2: F-03 and its fix.
  - 01q: permissionless path.
  - 01r–t: corrected draw bound, F-02, F-01.
  - 01u: in-kind split. 01v: pending floor. 01x: splitting.
  - 01y–z: F-06 and its fix.
  - 01w0–7: arithmetic bounds.
- **FV-LIQ-02, Aave sizing (16 checks):**
  - 02a–e: no over-seizure in each branch.
  - 02f–i: seizure lower bound.
  - 02j: `D ≤ debtToCover`.
  - 02k: deficit only with no collateral left; 02l and 02p are its mutants.
  - 02m: bonus range.
  - 02n: Hypothesis cross-check on the exact port.
  - 02o: F-04.
- **FV-LIQ-03, call flow (22 checks):**
  - 03a–l: per-path proofs.
  - 03m: `settlePending`.
  - 03n–p: callbacks, with three mutants.
  - 03q: over-delivery.
  - 03r, 03s, 03t: mutants.
- **FV-LIQ-04, caller top-up (20 checks, `Q-397`):**
  - 04a–c: the pull, its bound and `maxShortfall = 0`, with three mutants.
  - 04d: the dust example.
  - 04e: balance unchanged over 6 calls; 04f is the shared-pool mutant.
  - 04g: dust-rule sizing of `debtToCover`.
  - 04h–l: setters and F-07.
- **FV-LIQ-05, escrow and coverage (16 checks):**
  - 05a–h, 05p: escrow.
  - 05i–m: coverage.
  - 05n–o: withdrawals.
- **FV-LIQ-06, worked examples and replays (26 checks).**
- **FV-LIQ-07, system properties (14 checks).**
- **FV-LIQ-08, Quint (7 runs, randomized 10,000 × 25):**
  - 08a: live invariants hold.
  - 08b: safety invariants hold with halts.
  - 08c: solvency is violated with halts (expected).
  - 08w1–w4: witnesses that liquidations, deficits, coverage and escrow are all reached.

**Totals in the final run:** 148 checks pass:
- 81 formal proofs, 11 of them each covering all 170 paths;
- 31 exact checks of worked examples, bounds and oracle edge cases;
- 1 Hypothesis cross-check;
- 14 finding counterexamples and replays;
- 2 accepted violations;
- 12 mutants caught;
- 7 Quint runs.

### Comparison with the spec-stage models

These were read only after the models in this folder were complete.

- `z3/settlement/st04_settlement_budget.py`, check MATH-ST-21, proves "per-call draw ≤ one vault unit + 1 wei". That model computes the seizure from the repaid `D`. Aave computes it from `drawnShares × index + premium` and rounds `D` up (FV-LIQ-02f–i), so that model cannot see the excess in F-02.
- `PROP-019` defines `DG` as the GHO the buy leg spent. `SPEC-LIQ-011` defines it at Aave's debt price. The in-kind proofs here follow `SPEC-LIQ-011`.
- `PROP-017` gives `s = min(allowance, 10⁴ − ⌈(10⁴ + f)(10⁴ + cBuy)/b⌉)` without the `s = 0` branch. For small bonuses that value is zero or negative, which is the case behind F-01.

## 8. Spec-ID trace

Each check's tag line (`# FV-LIQ-NN verifies: …`) lists the spec IDs it covers, and `docs/spec/05-verification/trace.py` collects them. Every cited ID exists in the final spec.

## 9. Re-verification against the final spec (FV-LIQ-R3, 2026-11-10)

Every model in this folder was brought up to the final pages 2.11–2.14, 2.17, 2.18, 3.5 and 3.9 (decisions `Q-001`…`Q-278`) and run with `run.sh`. The rules that fix `FV-LIQ-F-01`…`F-09` are now the main rules of each model. The text they replaced is kept as a mutant: each mutant check passes only because the rule that replaced it rejects the old text.

### Run result

- 256 checks pass, 0 fail; `run.sh` exits 0.
- Per file: `FV-LIQ-01` 55, `02` 29, `03` 35, `04` 16, `05` 26, `06` 68, `07` 18 obligations; 9 Quint runs.
- By kind:
  - 196 formal proofs and exact checks: 19 of them hold on every one of the 170 liquidation paths or the 9 `deleverage` paths, and 56 recompute worked examples.
  - 4 Hypothesis cross-checks on the exact Aave port.
  - 30 mutants caught.
  - 3 accepted violations (07c, 07d, 07i2).
  - 14 counterexamples of the new findings `F-10`…`F-19`.
  - 9 Quint runs.
- Run log: `FV-LIQ-R3` in [RUNS.md](RUNS.md).

### What the final rules are proved to do

| Rule (final text) | Result | Checks |
|---|---|---|
| Fee from the oracle value, `A = min(⌊max(0, V − Gcov − φD) × share / 10⁴⌋, S)` (`SPEC-LIQ-009`) | `0 ≤ A ≤ S`. While `S` covers the fee term, `A` is the same however the caller converted, so a self-sandwich within the floor no longer lowers it. LIQ-069 keeps `A = 17.96` GHO when converted at the floor. | 01k, 01y, 01x, 06e, 06y; mutant 01z, 06ym |
| Sell-back floor `minBack` (`REQ-SWAP-089`, `REQ-ROUTE-037`) | `minBack ≥ 1` and at most the leftover's oracle value. A passing sale returns at least that value × (1 − `cBuy`) less 2 wei. | 01ab, 06ai |
| `s = 0` branch (`SPEC-SET-001`, `REQ-SWAP-029`) | No keeper path draws the budget. A completed call has `K + R' ≥ Gcov + φD`, so the caller pays any buy premium. | 01t, 03v, 06v; mutants 01tm, 03z2, 06vm |
| Two-leg liveness (`REQ-PSTORE-021`, `REQ-CONFIG-052`) | At every bonus `≥ minLB`, `s ≥ slippageAllowanceMinBps` and the two-leg inequality holds. With a minimum of at least 1 bps the `s = 0` branch is unreachable. | 01d; mutant 01dm |
| Draw bound and per-call cap (`SPEC-SET-002`, `REQ-BUDGET-006/017`, `REQ-CONFIG-050`) | Every honest draw is at most one vault unit + 2 wei + `U` + `floorRoundingAllowanceGho` + `(2 + ⌈drawnIndex/RAY⌉)` debt units at `Pdebt × (1 + cBuy)`. It fits `perCallCap ≥ 2 × floorRoundingAllowanceGho` whenever the rounding terms are at most the allowance. Setters keep that invariant on every key whose caps are not both 0. | 01r, 01s, 01s2, 04h–04k, 06w, 06ap; mutants 01sm, 04km, 04l, 06wm |
| `φD` on `min(F, Gcov)` (`SPEC-LIQ-007`) | `φD ≤ φ` at every fee rate, so `Bd > 0` implies `keeperOut ≤ 0`. A draw never pays the caller. | 01o, 01p, 01p2, 06g, 06ab; mutants 01om, 06abm |
| Lens whole-debt preview and Aave-formula seizure (`REQ-LENS-017`, `028`, `029`) | `expectedUnitsSeized` and `expectedDebtRepaid` equal Aave's values on the exact port (4,158 random accounts). At the same drawn index, the quoted parameters survive a 1-wei repay, a repay of up to $45 and a pledge. | 02o, 02q, 02s, 02t, 02v, 02v2, 06u, 06x, 06bf; mutants 02r, 02u, 06xm, 06bfm |
| Per-leg minimum output (`SPEC-LIQ-018`, `REQ-SWAP-100`, `INV-083`) | Every settlement and sell-back call on all 170 paths and the 9 `deleverage` paths carries `minOut ≥ 1`. No leg is asked for more than its oracle value. With no leg clamped at 1, the minimums add up to at most `minGho + n + U`. | 01af, 01ag, 03u, 03ad, 07i, 06ac; mutant 03z1 |
| Caller shortfall top-up (`SPEC-LIQ-019`, `REQ-SWAP-101`) | `s ≤ sLeg ≤ min(9,999, s + maxShortfallBps)`, and the relaxation buys at most `maxShortfallGho` of value. After the top-up `R' ≥ minGho`. The pull precedes any draw, and the draw is never larger than at `R = minGho`, so the budget never pays a shortfall. When every leg meets its minimum, a `RecoveryBelowFloor` is left only for the last `n` wei. Conservation holds with the shortfall on all 170 paths. | 01ac, 01ad, 01ae, 01j, 03c, 03w, 06ad, 07g |
| `probeLiquidation` and `reportRecoveryShortfall`; automatic in-kind (`REQ-SWAP-102`, `103`) | A report writes state only for an approved, unfrozen keeper with `PrimaryThenBackup`, no keeper GHO, no shortfall allowance, a probe ending in `ProbeResult`, and `R < minGho`. `shortfallSince ≤ lastShortfallAt ≤ now` is inductive. A gap over one hour restarts the run, and a completed routed liquidation clears it. `autoEnableInKind` runs only with the DAO-approved trigger, in-kind not yet open, and at least `inKindAutoDelay` of reports. | 03aa, 03ab, 03ac, 03y, 06ak |
| Repay with collateral (`SPEC-LIQ-020`, `REQ-SWAP-106`) | The GHO repayment plus its flash fee is covered by `Vnet ≤ V(1 − s)`. For a non-GHO debt, `bound(X*) ≤ min(cap, maxGhoSpend)`, so the one-unit lowering never fires. On all 9 paths every balance returns to its start, every allowance is reset, `ghoOut = R + g' − Gspent − φ ≥ 0`, value leaves only to the wallet, and there is no draw or fee. | 01ah, 01ai, 03ad, 03ae, 03af, 06ae |
| Per-market budget cap (`SPEC-SET-006`, `REQ-BUDGET-024`) | For any market count the MarketRegistry reports, the sub-cap lies in `[100 GHO, max(100 GHO, per24hCap)]`. Over any 6 draws, every market's rolling 24-hour total stays within its sub-cap, alongside the per-reserve and total windows. | 04g, 04m, 04n, 06aq |
| Per-reserve freshness, stale-at-Expired and lower-route valuation (`REQ-SWAP-008`, `091`, `INV-075`, `INV-087`) | On every path, success does not depend on the application pause, any breaker, another market being Expired, another debt being stale, or the borrower's freeze. A frozen caller never succeeds. Collateral served at most its accepted price (lower route, or 1 once Expired) and debt served at least its accepted price give an HF at or below the HF at accepted prices. An account liquidatable at accepted prices therefore stays liquidatable, and a failing price never shields another reserve. | 03h, 03x, 07o, 07p, 07q, 06af; Quint 08w5, 08w6 |
| Address freeze and keeper floor (`REQ-SWAP-105`, `107`) | Removal never leaves fewer than `KEEPER_FLOOR` approved keepers; a freeze checks no floor and may leave 0 active keepers, which halts new borrowing (`Q-400`). A frozen caller never completes a liquidation, while a frozen wallet's account and a paused application are both liquidated in the simulated traces. | 08a, 08b, 08w5, 08w6 |
| Per-asset coverage (2.14, 3.9) | Each Coverage Spoke changes only its own asset's deficit, and coverage and funding never lower other suppliers' share price. The coverage and deficit breakers are per asset and clear as stated. The tail-coverage ratio never overstates. | 05i–05o, 05s–05y, 06at–06ax |
| In-kind escrow with measured deposits (2.18) | The inductive invariant holds with the measured deposit, and claims work under any pause, breaker or freeze. | 05a–05g, 05p, 05r; mutants 05h, 05q |

### New findings

Each finding's counterexample check passes because the counterexample exists. Once the spec text changes, that check fails and is replaced by the check that proves the recommended rule.

**FV-LIQ-F-10, Low: an oversized `debtToCover` sold back at the sell-back floor still lowers Avana's fee.** Checks 01z2 and 06z; the recommended rule is proved by 01y2 and 06z2.
- Rules: `SPEC-LIQ-009`, `REQ-SWAP-089`, `REQ-ROUTE-037`, `INV-086`.
- The sell-back floor allows `cBuy` of the leftover, and the caller chooses the leftover.
- Counterexample on the LIQ-069 numbers:
  - `debtToCover` is oversized by 100,000 USDC, and the extra is bought at par.
  - Selling the 100,010 USDC leftover 85 GHO under value passes `minBack = 99,709.97` GHO − 1 wei.
  - Then `Gnet = 5,085`, `S = 0`, `A = 0` and `Bd = 0`. The call completes.
  - Avana's 17.96 GHO goes to the caller, less the caller's cost of buying the extra USDC.
- Recommendation, in `SPEC-LIQ-009`: `A = min(⌊max(0, V − Gcov − φD) × avanaFeeShareBps / 10⁴⌋, max(0, R' − Gcov − φD))`. Keep `S` and `keeperOut` on `Gnet`. The round trip `Gnet − Gcov` then comes from the caller's payout, or the call reverts with `InsufficientProceeds`, as `SPEC-LIQ-017` intends. Update `INV-036` and `INV-086` to match.

**FV-LIQ-F-11, Informational: the deleverage health-factor threshold misses the `U` and rounding terms.** Check 01aj; the recommended rule is proved by 01ak.
- `SPEC-LIQ-020` says the sizing meets `x × HF ≥ V × CF` for every account with `HF ≥ CF × (10⁴ + maxFlashFeeBps) / (10⁴ − s)`.
- At that exact HF, `x = ⌊(⌊V(1 − s)⌋ − U) / (1 + f)⌋` leaves `x × HF` below `V × CF` by about `U × CF`. The AaveAdapter then reverts with `HealthFactorNotImproved`, so nothing is lost.
- Recommendation: replace the condition with "`HF × (V × (10⁴ − s) − 10⁴ × (U + 2) − maxFlashFeeBps) ≥ CF × V × (10⁴ + maxFlashFeeBps)` (just above 0.31515 at CF 0.312, `s = 100` and 2,100 GHO of units)".

**FV-LIQ-F-12, Informational: `SPEC-LIQ-018` overstates how close the leg minimums sum to the floor.** Check 01ag2; the recommended rule is proved by 01ag3.
- When one leg is worth less than its unit plus `⌊floorRoundingAllowanceGho / n⌋`, that leg's minimum is clamped at 1. The other leg keeps only half the allowance.
- The minimums can then exceed `minGho + n + U` by up to `⌊floorRoundingAllowanceGho / 2⌋ + U` (0.5 GHO at launch).
- Example: leg values of 100 and 0.3 GHO (6-decimal tokens at $1) with `s = 100` give leg minimums of 98.499999 GHO and 1 wei against `minGho = 98.296998` GHO, 0.202999 GHO above `minGho + n + U`.
- Recommendation: replace "`Σ minOutᵢ ≤ minGho + n + U`" with "`Σ minOutᵢ ≤ minGho + n + U` while no leg minimum is clamped at 1, and `≤ minGho + n + 2U + ⌊floorRoundingAllowanceGho / n⌋` in every case". The shortfall top-up relaxes the legs if routes run between the two.

**FV-LIQ-F-13, Medium: a whole-debt Lens quote reverts once interest accrues before inclusion.** Checks 02x and 02x2; the recommended rule is proved by 02w and 02z.
- Rules: `REQ-LENS-028`, `REQ-SWAP-005`.
- Aave's drawn index grows every second, so at inclusion the whole debt is above the quoted `debtToCover`. Aave then requires the whole debt and reverts with `MustNotLeaveDust`.
- This hits every preview whose repayment is the whole debt: small and deeply underwater accounts, the ones that create deficits.
- Counterexample: 900 GHO owed at HF 0.90. The Lens quotes 900 GHO. One block later the index is × 1.00000001 and the debt is 900.000009 GHO, so the call reverts.
- Recommendation, in `REQ-LENS-028`: "`debtToCover = ⌈total × (10⁴ + LENS_DUST_MARGIN_BPS) / 10⁴⌉` with `total = getUserTotalDebt(debtReserveId, proxy)`, for a GHO debt reserve, and for any other reserve when `expectedDebtRepaid` is the whole debt, when the sizing seizes all of the account's supplied shares in the market, or when the remainder is within the margin of `DUST_LIQUIDATION_THRESHOLD`".
- Update the examples to match: 42,478.926 GHO, and 1,113 USDC with `maxGhoSpend` 1,116.339 GHO. Carry the same wording into `REQ-SWAP-005`.

**FV-LIQ-F-14, Low: a collateral-limited non-GHO quote reverts after a pledge.** Checks 02y and 02y2; the same rule as F-13 fixes it (02w, 02z).
- When the seizure takes all of the market's collateral and the remainder is outside the margin, the Lens quotes `expectedDebtRepaid`.
- A pledge raises the debt Aave sizes from the collateral above that quote, and the call reverts.
- Counterexample: 20,000 USDC owed against 400 vault tokens at $2. The Lens quotes 761.904762 USDC; after a $10 pledge, Aave sizes 771.428572 USDC.

**FV-LIQ-F-15, Informational: `getTailCoverage` overflows for an unlimited `drawCap`.** Check 05z.
- `REQ-LENS-034` counts an unlimited `drawCap` as `type(uint256).max`, so `drawCap × Pa` overflows. A checked implementation reverts the view, and it breaks the `2¹²⁸` bound of `SPEC-CAP-008`.
- Recommendation: "when any `drawCap` is Aave's `MAX_ALLOWED_SPOKE_CAP`, `drawCapUsd = type(uint256).max` and the sum is not computed". State it in the overflow line of `SPEC-CAP-008`, and write `SPEC-FLR-005`'s `Σ drawCap` as `Σ drawCap × 10^{d_a}`.

**FV-LIQ-F-16, Informational: the `SPEC-SET-002` example is in the `s = 0` branch.** Check 06w2; the corrected example is checked by 06w3.
- At `cBuy = 200` and a bonus of 10,200, `bNet × 10⁴ = (10⁴)(10⁴ + 200)`, so `s = 0`. In that branch no draw is allowed, and `REQ-PSTORE-021` forbids the listing.
- Recommendation: use `cBuy = 98` (`s = 100`). The draw is then 1.0000035147 GHO, of which about `1.51·10¹²` wei is the debt term (at most `(2 + 2) × 10⁻⁶ × 1.0098` GHO).

**FV-LIQ-F-17, Informational: the `LIQ-069` / `REQ-LENS-017` account does not give the stated `D` and seizure.** Checks 06bb2 and 06bb3; the corrected account is checked by 06bb4.
- The stated account owes 40,456.12 USDC. With it, Aave targets 4,990.0000984 USDC, pulls 4,990,000,099 units and seizes 2,544,900,050.
- Recommendation: make the debt 40,456.119927 USDC in `LIQ-069` and in `REQ-LENS-009`, `017` and `028`. HF stays 0.9997, and Aave pulls exactly 4,990,000,000 units.
- Change the after-state to "35,466.119927 USDC, health factor 1.10". In the GHO variant of `REQ-LENS-028`/`029`, write "≈ 4,990 GHO" and "about 2,544.9 vault tokens".

**FV-LIQ-F-18, Informational: `DEF-006` writes the share burn without the virtual offset.** Check 06ay2.
- The written expression gives 463.707317073170731708. The stated 463.707317073170731713 is the `SPEC-FLR-001` value.
- Recommendation: write "`⌈475.3e18 × (2,000,000e18 + 10⁶) / (2,050,000e18 + 10⁶)⌉ = 463.707317073170731713`".

**FV-LIQ-F-19, Informational: `LIQ-068` step 1 floors the health factor wrongly.** Check 06ba2.
- `282,464 × 0.2812 / 79,452.85 = 0.999698…`, which floors to 0.9996, not the stated 0.9997.
- Recommendation: write "`282,464 × 0.2812 / 79,452.85 ≈ 0.9997`".

### Assumptions added for the final pages

- A settlement route returns at least 1 GHO wei for any input whose oracle value is at least 1 GHO wei. Every leg minimum is at least 1 (FV-LIQ-01af).
- In `deleverage`, `getUserTotalDebt` is read in the same call as the repayment, so a GHO repayment is consumed in full.
- Interest accrual between a Lens preview and inclusion is covered by the recommended rule of F-13. The same-index results of 02s–02v do not cover it.

## 10. Re-verification against the debt-asset settlement design (FV-LIQ-R6, 2026-11-10)

The models now describe the design of 2.11 after `Q-333`…`Q-348`: the flash loan is the debt asset itself through `IFlashSource`, the CDP Spoke is a standard Aave V4 Spoke called with `receiveShares = false`, the unwind returns n token amounts, every leg swaps into the debt asset, and the payout is split in the debt asset between Avana's fee, the keeper reward and the borrower surplus. No buy leg, sell-back or GHO flash mint remains in any model; GHO appears only where the debt reserve is GHO. Check IDs are kept: each check of a retired rule now proves the rule that replaced it, and each old text that is still informative is kept as a mutant.

### Run result

- 266 checks pass, 0 fail; `QNT_SAMPLES=2000 bash run.sh` exits 0 in 113 s.
- Per file: `FV-LIQ-01` 60, `02` 29, `03` 35, `04` 16, `05` 27, `06` 72, `07` 18 obligations; 9 Quint runs (2,000 traces × 25 steps each).
- `FV-LIQ-03` enumerates 62 liquidation paths (flash or caller funding, route mode, primary or backup per leg, token0 being the debt asset, delivery or escrow of each borrower payout) and 6 `deleverage` paths.
- Run log: `FV-LIQ-R6` in [RUNS.md](RUNS.md).

### What the debt-asset rules are proved to do

| Rule | Result | Checks |
|---|---|---|
| Slippage without a buy-leg term (`SPEC-LIQ-003`) and one-leg liveness (`SPEC-LIQ-016`) | `bNet(10⁴ − s) ≥ 10⁴(10⁴ + costs)`; with `minLB(10⁴ − slipMin) ≥ 10⁴(10⁴ + maxFlashFeeBps)`, `s ≥ slipMin` at every bonus Aave can pay. A listing without the check reaches `s = 0` (mutant). | 01b, 01c, 01d, 06c; mutant 01dm |
| Flash pre-loan bound and lender gate (`SPEC-LIQ-015`, `REQ-FLASH-002`, `REQ-FLASH-005`) | A loan is taken only within `maxFlashLoan(T)`, with quoted and charged premium at most `maxFlashFeeBps` of `F`, and from a lender that is neither the home Hub nor the funding Hub; the V3 Pool passes. | 01h, 01ap, 07h, 06m, 03n |
| Covered cost is the debt (`REQ-SWAP-088`, `REQ-SWAP-089`, `SPEC-LIQ-017`) | `Gcov = Gnet = D`; the leftover `X − D` is never swapped and stays outside the `R` window, so an oversized `debtToCover` costs the caller only `φ − φD`. Counting it in `R` would pay the caller's leftover to the borrower (mutant). | 01i, 01ab, 01y2, 03q, 06l, 06ai, 06z2; mutants 01z2, 03t, 06z |
| Payout split (`SPEC-LIQ-022`) | `A + kr + B = S`, all non-negative, `A ≤ S`, `kr ≤ G − A`, `B = max(0, S − G)`, and `B = R' − max(V, D + φD)` when `S > G`. `B = 0` whenever a shortfall was pulled or the budget drew. A keeper paid `S − A` would take the recovery above the oracle value (mutant). | 01al, 01am, 01an, 03c, 06e, 06k; mutant 01ao |
| Conservation in the debt asset (`SPEC-LIQ-010`) | `K + F + R + shortfall + Bd = D + (F + φ) + A + B + keeperOut` on every routed path, with the borrower surplus delivered to the wallet or the PayoutEscrow. | 01j, 03a, 03c, 06e |
| Budget windows (`SPEC-SET-006`) | Per-market window caps set at listing keep their sum within the asset window; a draw that fits its market's window leaves every other market's room unchanged. | 04m, 04n, 06aq |
| Gas guard (`REQ-SWAP-076`, `REQ-SWAP-104`) | `gasleft() ≥ ⌈64·G/63⌉ + POST_CALL_GAS`: 111,588 for a payout (LPVaultSwap's `POST_CALL_GAS` = 10,000, since 2026-11-11; 106,588 at the 5,000 of earlier runs), 86,270 for a breaker report. | 06ah |

### Assumptions for the debt-asset design

- The Aave V3 Pool flash premium is `percentMul(amount, premiumBps)`, rounded half up, and is non-decreasing in the amount, so `φD ≤ φ`.
- In the waterfall proofs of FV-LIQ-01 the fee term is abstracted as any value in `[0, G]`; its exact form `⌊G × share / 10⁴⌋` with `share ≤ 5,000` is proved to lie in that range by FV-LIQ-01al.
- The 2.11 worked examples are recomputed in USDC base units (`dd = 6`); the 3.5 and 2.17 examples on a GHO debt reserve stay in 18-decimal GHO units.

## 11. Re-verification after the parameter decisions (FV-LIQ-R9, 2026-11-10)

The decisions of 2026-11-10 removed the SettlementBudget (`Q-397`), removed in-kind settlement (`Q-401`), moved the price-drop, seizure-surge and route-failure breakers to monitoring alerts (`Q-399`) and set `keeperFloor = 1` with `MAX_KEEPERS = 32` (`Q-400`).

**Why the budget was removed.** The budget paid only the rounding gap `D + φD − K − R` left after a liquidation met its recovery floor. That gap is a few base units, and Aave V4's dust rule makes the repayment that finishes a liquidation predictable before the call. Avana's keeper therefore sizes `debtToCover` and its funding for that amount up front, using the exact flash principal and premium, and pays any gap left at settlement through the shortfall top-up it already had. Removing the budget removes a funded contract, its caps, windows, reserved floors and setters, and the rule that a draw is never paid to the caller (`FV-LIQ-F-01`, `F-02`, `F-03`, `F-07` all concerned the budget's bounds). The cost moves to the caller, bounded by `maxShortfall`.

| Rule | Result | Checks |
|---|---|---|
| Top-up (`SPEC-LIQ-019`) | `shortfall = max(0, minRec − R, D + φD − K − R)`, pulled only from the caller and only within `maxShortfall`; afterwards `R' ≥ minRec` and `K + R' ≥ D + φD`; it is the least such pull and falls as caller funds rise. The rule before `Q-397` (floor term only) reverts every flash-funded dust liquidation (mutant). | 01ad, 01t, 03w, 03v, 04a–c, 04h–k; mutants 03z2, 04b0–2, 04km, 04l |
| Conservation (`SPEC-LIQ-010`) | `K + F + R + shortfall = D + (F + φ) + A + B + keeperOut` on all 56 paths; LPVaultSwap's balance is unchanged over any 6 completed calls; a shared pool loses value (mutant). | 01j, 03a, 03c, 04e, 04m; mutants 04f, 04pm |
| Rounding-gap bound (`SPEC-SET-002`) | The gap is below one vault unit + 2 units + `U` + the allowance + Aave's debt rounding, so a `maxShortfall` of twice the allowance covers it. | 01r, 01s, 01s2, 06w, 06ap |
| No in-kind settlement (`Q-401`) | No path pays a collateral token to the borrower or `feeRecipient`; every failed payout (fee, `keeperOut`, residue, borrower surplus) goes to the escrow and the liquidation completes. | 01u, 03e, 03i, 03l, 05g2, 06h, 06az |
| No breaker report (`Q-399`) | No path calls the MarketRegistry's breaker or shortfall functions; liquidation never reads a breaker. | 03x, 03y, 06ak, 06be |
| Keeper list (`Q-400`) | `addKeeper` stops at 32 approved keepers; `removeKeeper` and `freezeAddress` keep at least one active keeper; zero active keepers stop new borrowing, never `liquidatePermissionless`. | 03aa, 03ab, 03ac, 03ac2, 06am, 08a/b |

FV-LIQ-04's IDs are kept: each budget check now states the property of the top-up that replaced its rule. The earlier findings F-01, F-02, F-03 and F-07 stay in section 6 as history; their rules no longer exist.

