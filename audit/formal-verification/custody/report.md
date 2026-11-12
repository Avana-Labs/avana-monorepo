# Custody area: internal formal verification report

> **Status:** In review · **Owner:** Avana Labs · **Last reviewed:** 2026-11-10 · **Verified artefact:** the specification (no implementation exists yet) · **Reproduce:** `audit/formal-verification/custody/run.sh`

Sections 1–8 report the first run (`FV-CUS-R1`, 2026-11-09, decisions `Q-001`…`Q-240`). Section 9 reports the re-verification against the final spec (`FV-CUS-R3`, 2026-11-10, decisions `Q-001`…`Q-278`). Section 10 reports the re-verification against the AMM-neutral design (`FV-CUS-R5`, 2026-11-10, decisions `Q-001`…`Q-380`), which is the current result of every check. Sections 1–9 are kept as the history of the earlier design: a full-range Uniswap v3 NFT keyed by `tokenId`, one Hub, beacon proxies per wallet and Spoke.

## 1. Project summary

### Scope

The specification text is the object verified; implementation code did not exist on the run date. The pages below were read as final for this run. Hub math was taken from Aave V4 at `a3ef63ea6415d25237a9775bf66e76e9993561c2`.

| Contract (spec page) | Rules and math in scope | Model files |
|---|---|---|
| Collateralization (2.3) | `REQ-COLL-001`…`013`; `REQ-VAULT-006`…`146`; `SPEC-BACK-001`…`012`: full-range check, credited units, records, seizure list, seizure checks, reconcile on exit, pending settlement, exposure counters | `fv_backing.py`, `fv_list.py`, `fv_exposure.py`, `fv_pending.py`, `custody.qnt` |
| LPVault (2.2) | `REQ-VAULT-001`…`005`, `039`…`045`, `064`…`067`, `077`…`099`, `147`…`160`: NFT custody in and out, liquidity removal, fees, stray NFTs | `fv_lpvault.py`, `custody.qnt` |
| Vault token and factory (2.4) | `REQ-VTOKEN-001`…`043`; `SPEC-UNIT-001`…`006` | `fv_token.py`, `fv_arith.py` |
| AaveAdapter mint and burn paths (2.6) | `REQ-ADAPTER-005`, `068`…`070`, `075`; withdrawal order (arch-map R-05) | `fv_backing.py`, `fv_solvency.py` |
| Lock (2.16) | `REQ-LOCK-005`, `010`, `016` as used by custody views and inner calls | `fv_lpvault.py` |
| Flows 3.1 Deposit, 3.7 Collect fees | `DEP-006`…`018` step order; fee collection | `fv_backing.py`, `fv_lpvault.py` |
| Aave V4 Hub (`Hub.sol`, `AssetLogic.sol`, `SharesMath.sol` at `a3ef63e`) | `add`, `remove`, `getAddedAssets`, virtual offsets 10^6 | `fv_hub.py` |

Tools:
- Z3 4.13.0 (Python; exact integers; nonlinear integer and real arithmetic).
- Quint 0.22.4 `quint run`, a randomized simulator (Apalache not used).
- Seeded randomized sampling with exact Uniswap v3 integer amounts.

### Overview of the area

**Pledge.** A full-range Uniswap v3 NFT moves into the immutable LPVault. Collateralization credits its liquidity `L`, read after custody, as a new record. The AaveAdapter mints `L` vault-token units to the depositor's PositionProxy, which supplies them to the Borrow Spoke.

**Withdrawal.** The proxy withdraws the units and the Adapter burns them. Collateralization debits and closes the record, and the LPVault returns the NFT to its depositor of record.

**Liquidation.** LPVaultSwap brackets Aave's `liquidationCall` with `beginSeizure` and `settleSeizure`. The Adapter burns the seized units from LPVaultSwap (`burnSeized`). Collateralization checks that the proxy's share drop and the token's supply drop both equal the debit, then has the LPVault remove exactly that liquidity.

**Unsettled seizures.** Seizures that a non-conforming LPVaultSwap never settles are reconciled on the next exit into a pending-settlement balance. `settlePending` later retires that balance against a burn.

## 2. Assessment methodology

- **Rules and inductive invariants.**
  - Each invariant is proved on the empty market (base case) and preserved by every successful call (step case), with the call's revert conditions as its guard.
  - An invariant that a call's own post-check enforces is never assumed for that call. For example, the backing equality is derived from the effects of `pledge` and `withdraw`, and the Adapter's `BackingMismatch` check is then proved to pass.
  - Every rule also runs a `satisfy` witness. A rule whose hypotheses have no model is reported VACUOUS.
- **Over-approximation.**
  - A debit's allocation over a proxy's records may be any split with `take_i ≤ credited_i` that sums to the debit. `fv_list.py` proves the largest-first walk exact separately, so the backing proofs hold for every allocation, including the specified one.
  - Non-conforming LPVaultSwap behaviour is modelled as four extra calls:
    - a seizure that is never burned or settled;
    - a transfer of held units to the Hub;
    - a `settlePending` without a burn;
    - a `burnSeized` that no settlement follows.
  - A hostile Adapter is modelled where the spec claims a property "for any implementation" (custody, stray NFTs).
- **Two-execution comparison.** Donation independence (T-15) and withdrawal commutation (item 2).
- **Nonlinear lemmas** (ceiling-charge monotonicity, addCap headroom, LP-value bounds) are proved once, then used as hypotheses of the linear inductive steps.
- **Security context** (4.2):

| Attack | Targets / checks |
|---|---|
| ATTACK-001, ATTACK-007 | T-05 (`FV-CUS-05-dup`), T-11 |
| ATTACK-003, 006, 008 | T-11, `FV-CUS-02-*`, finding F-02 |
| ATTACK-004 | `FV-CUS-22-ticks` |
| ATTACK-009, 011 | T-01, T-06, T-07 |
| ATTACK-012 | T-08, T-13, `FV-CUS-27-close` |
| ATTACK-013 | T-12 |
| ATTACK-014, 020 | T-16 |
| ATTACK-015 | `FV-CUS-18-capped` |
| ATTACK-016, 017 | T-02, T-09, `FV-CUS-15-donation` |
| ATTACK-018, 019, 024 | T-10 |
| ATTACK-025, 026 | T-04, T-15, T-20, finding F-01 |
| ATTACK-027 | amounts come only from stored values (`fv_pending.py`); REQ-COLL-009 |
| ATTACK-061 | `FV-CUS-MP-*`, `FV-CUS-12-stop` |

- **Fix validation.** Each finding has `-FIX` checks that apply the recommended spec change and re-run the same rules; they pass in this run.

## 3. General assumptions and simplifications

| Class | Assumption | Discharge |
|---|---|---|
| Bounded structure | `fv_backing.py`: 1 market, 2 proxies, 3 record slots. `fv_list.py`: 5 list slots. `fv_exposure.py`: 3 records over 2 markets sharing a token, 2 depositors. Quint: 3 NFTs, 2 proxies, ≤ 20 steps, 10,000 samples. Each call touches a small fixed set of records, so step cases are not weakened; list proofs are exact for ≤ 5 records. | Implementation-stage prover rules with `loop_iter` ≥ 3 plus a non-optimistic run |
| Aave configuration | Vault-token Hub asset: `drawCap = 0` on every Spoke, `liquidationFee = 0`, no reinvestment controller, no deficit, so `getAddedAssets == liquidity`. Proxies appoint no position manager (`REQ-PROXY-008`). | `PROP-040`; T-78 drift checks |
| NFPM | Abstract liquidity: `increaseLiquidity` is open to anyone and only raises liquidity; only the owner or an approved address lowers it; `collect` pays `min(cap, owed)`; `transferFrom` clears the approval. `fv_lpvalue.py` uses the exact `SqrtPriceMath` amount formulas, with tick square roots computed to 80 digits. | Fork tests on the canonical NFPM |
| Tokens | Standard ERC-20 pool tokens with SafeERC20 (`REQ-ARCH-014`). Fee-on-transfer and hook tokens appear only as witnesses. | Listing checks |
| Prices and amounts | `L < 2^120`, `usdCharge < 2^128`, `price8 < 2^64` (`≤ 2^33` for the reachable charge bound), decimals 6–18 with an even sum, leg prices $0.30–$3.00 in the fuzz | Listing bounds, `SPEC-UNIT-006` |
| Trust | Reviewed Adapter, except where a hostile one is modelled. LPVaultSwap reviewed or non-conforming, as stated per check. Withdraw-with-debt health check (T-58) taken as a guard. | Control area (T-58, T-62, T-64) |
| Arithmetic | Exact integers. Overflow is proved as "exact result < 2^256", which is equivalent to checked `uint256`. | `PROP-043` (SMTChecker) on the code |

**Unproved assumptions:** none of the rows above is discharged inside this folder. Each lists the implementation-stage proof or test that covers it.

## 4. Findings summary

| Severity | Discovered | Confirmed | Fixed in spec |
|---|---|---|---|
| Critical | 0 | — | — |
| High | 0 | — | — |
| Medium | 1 | 1 | 1 (F-01) |
| Low | 1 | 1 | 1 (F-02) |
| Informational | 7 | 7 | 4 (F-03…F-06) |

Severity matrix:

| Impact \ Likelihood | Low | Medium | High |
|---|---|---|---|
| High | Medium (F-01) | High | Critical |
| Medium | Low (F-02) | Medium | High |
| Low | Low | Low | Medium |

| ID | Title | Severity | Status |
|---|---|---|---|
| FV-CUS-F-01 | A `burnSeized` with no settlement breaks the backing equality and blocks every pledge and withdrawal of the market | Medium | Resolved in spec (`Q-257`); verified in `FV-CUS-R3` |
| FV-CUS-F-02 | A hostile Adapter can pledge a stray NFT with the LPVault as depositor | Low | Resolved in spec (`Q-258`); verified in `FV-CUS-R3` |
| FV-CUS-F-03 | INV-027 and T-14 state per-bucket counter sums that slice-first release does not keep | Informational | Resolved in spec; verified in `FV-CUS-R3` |
| FV-CUS-F-04 | Credited value can exceed immediate removal value by Uniswap's per-leg rounding | Informational | Resolved in spec; verified in `FV-CUS-R3` |
| FV-CUS-F-05 | INV-001 says pending liquidity stays in LPVault custody; REQ-VAULT-135 removes it at reconciliation | Informational | Resolved in spec; verified in `FV-CUS-R3` |
| FV-CUS-F-06 | Methodology T-19 omits the reconcile wait while Hub shares ≠ assets | Informational | Resolved in the methodology; verified in `FV-CUS-R3` |
| FV-CUS-F-07 | PROP-065 says nothing lowers the backing gap; SPEC-BACK-012 lets a `settlePending` without a burn lower it | Informational | Open (found in `FV-CUS-R3`) |
| FV-CUS-F-08 | Several rules still list only the exits that existed before partial removal, re-credit and deleverage release | Informational | Open (found in `FV-CUS-R3`) |
| FV-CUS-F-09 | REQ-COLL-018 and REQ-VAULT-089 describe call orders that the specified flows do not follow | Informational | Open (found in `FV-CUS-R3`) |

Sections 5 and 9.3 give the details; findings F-07…F-09 are in section 9.3.

## 5. Detailed findings

### FV-CUS-F-01 — A `burnSeized` with no settlement breaks the backing equality and blocks every pledge and withdrawal of the market

**Severity:** Medium. Impact High: exits halt for a whole market. Likelihood Low: requires a non-conforming LPVaultSwap implementation, which is an upgrade behind the timelock.

**Spec rules involved:**
- `REQ-ADAPTER-069`, `REQ-ADAPTER-070`, `REQ-ADAPTER-075`
- `REQ-VAULT-029`, `REQ-VAULT-139`, `REQ-COLL-012`
- `SPEC-BACK-009`, `SPEC-BACK-012`
- `INV-001` ("any implementation of the other upgradeable contracts"), `INV-045` ("for any LPVaultSwap implementation")
- `PROP-001`, `PROP-054`

**Violated property:**
- T-01, rule `FV-CUS-01-orphanBurn`
- T-19, rule `FV-CUS-19-orphan`
- Quint `FV-CUS-QNT-02`

**Description.**
- `burnSeized` checks only the caller, the Lock holder, the market and `units > 0`. Nothing ties it to a seizure snapshot or a pending settlement.
- A non-conforming LPVaultSwap can therefore have units burned and never call `settleSeizure` or `settlePending`. This is the same trust class reconcile on exit was designed for.
- After such a burn, `totalSupply = totalCredited + pending.units − y`. The Adapter's post-check is an absolute equality, so every later pledge and withdrawal of the market reverts `BackingMismatch`, debt-free withdrawals included.
- No conforming call restores the equality:
  - a conforming `settlePending` must first burn units that LPVaultSwap no longer holds;
  - Collateralization is immutable.
- Only an Adapter upgrade, after 5 days, can change the check.
- In the broken state, a `settlePending(x)` with no burn at all passes `SPEC-BACK-012`'s equality whenever `x` equals the gap. So its stated reason ("proves the Adapter burned exactly `x` in this call") holds only if the equality held before the call.

**Counterexample.** USDC/USDT market.
1. Alice pledges NFT 42 (5,000,000,000) and NFT 7 (4,000,000,000). Supply is 9,000,000,000.
2. A non-conforming LPVaultSwap calls `liquidationCall` on her proxy and receives 1,575,000,000 units. It has the Adapter burn them and never calls Collateralization. Supply is now 7,425,000,000; `totalCredited` is 9,000,000,000; pending is 0.
3. Alice repays and withdraws NFT 7 (`previewRelease(7) = 4,000,000,000`). The proxy withdraws and the Adapter burns, so supply is 3,425,000,000.
4. `release` reconciles 1,575,000,000 from record 1 into pending and debits NFT 7. `totalCredited` is now 3,425,000,000.
5. The check `3,425,000,000 == 3,425,000,000 + 1,575,000,000` fails with `BackingMismatch(3,425,000,000, 3,425,000,000, 1,575,000,000)`.

Every other depositor's withdrawal in that market fails the same way. Z3's minimal instance: supply 3, credited 4, pending 0 after an orphan burn of 1.

**Recommendation (exact spec change).**
1. In `REQ-ADAPTER-069`, replace the absolute equality with: "After every pledge and every withdrawal the Adapter MUST revert with `BackingMismatch(totalSupply, totalCredited, pendingUnits)` unless `totalCredited + pending.units − totalSupply` read after its call into Collateralization equals the same quantity read before its first mint or burn of the call, and `totalSupply ≤ totalCredited + pending.units`."
2. In `INV-001`, `REQ-VAULT-029`, `REQ-VTOKEN-016` and `SPEC-BACK-009`, state: "`totalSupply ≤ totalCredited + pending.units` for any LPVaultSwap implementation, with equality while every `burnSeized` has been followed in the same call by the `settleSeizure` or `settlePending` that debits it."
3. In `SPEC-BACK-012`, `REQ-VAULT-139` and `REQ-COLL-012`, change the check to `vt.totalSupply() + x ≤ totalCredited[vt] + p.units`.

These checks prove the change:
- `FV-CUS-01-FIX-*` (all 31 calls, including every non-conforming one): every unit stays backed.
- `FV-CUS-19-FIX-*` and `FV-CUS-07-FIX-*`: pledges and debt-free withdrawals pass in every reachable state.
- `FV-CUS-01-FIXEQ-*`: conforming calls still keep the equality.

Update `PROP-001`, `PROP-054` and methodology T-01 to match.

### FV-CUS-F-02 — A hostile Adapter can pledge a stray NFT with the LPVault as depositor

**Severity:** Low. Impact Medium: the liquidity of an NFT awaiting its governance return can be borrowed against and seized, and `returnStrayNft` reverts `NotStray` while the NFT is pledged. Likelihood Low: requires a hostile Adapter.

**Spec rules:** `REQ-VAULT-147`, `REQ-VAULT-093`, `REQ-VAULT-094`, `REQ-COLL-005`, `REQ-VAULT-079`…`083`.

**Violated property:** T-11, rule `FV-CUS-11-depositor-hostile`: a recorded depositor is never the LPVault or Collateralization.

**Description.**
- `receiveNft(owner, tokenId)` requires `NFPM.ownerOf(tokenId) == owner`, then calls `transferFrom(owner, LPVault, tokenId)`.
- For a stray NFT, `owner == LPVault` passes, and the LPVault → LPVault transfer succeeds because the owner is the caller.
- `depositorOf` is then the LPVault. `REQ-COLL-005` limits a hostile Adapter to NFTs whose owner approved the LPVault, which this case violates.
- A later `returnNft` would send the NFT to an Avana contract, which `REQ-VAULT-094` forbids.
- A reviewed Adapter passes `msg.sender`, which can never be the LPVault.

**Counterexample.**
1. Stray NFT 99, with liquidity 2,000,000,000, arrives via `safeTransferFrom`.
2. A hostile Adapter calls `Collateralization.pledge(LPVault, eveProxy, vt, 99)`.
3. The ownership check passes, and `transferFrom(LPVault, LPVault, 99)` succeeds.
4. The record credits 2,000,000,000 units to eve's proxy, and eve borrows against them.

**Recommendation.**
- `REQ-VAULT-147`: add "and with `NotTokenOwner` if `owner == address(this)`".
- `REQ-COLL-005` and `REQ-VAULT-007`: add "`pledge` MUST revert with `InvalidDepositor` if `depositor` is `LP_VAULT` or `address(this)`".
- `FV-CUS-11-depositor-FIX` proves the property under this change.

### FV-CUS-F-03 — INV-027 and T-14 state per-bucket counter sums that slice-first release does not keep

**Severity:** Informational.

**Violated property:** `FV-CUS-14-perbucket`, `FV-CUS-14-perbucket-trace`.

**Description.** Slice-first release is intended to refill the slice budget first. As a result, the slice counter does not equal the slice part of the market's open records. What does hold, and is proved with `CounterSaturated` unreachable (`FV-CUS-14-*`):
- `Regular + Slice == Σ remainingCharge` over the market's open records;
- each token and depositor counter equals the sum over its scope;
- `Regular ≤ marketUsdCap` and `Slice ≤ topUpSliceUsd`.

**Counterexample.** Caps are $1,000 regular and $200 slice.
1. Record A, a new account, books $1,000 regular.
2. Record B, an eligible top-up, books $200 slice.
3. A exits in full: slice → 0 and regular → $200, while B still has a $200 slice part.

**Recommendation.** In `INV-027` and T-14, replace the per-counter sentence with: "For each market, regular + slice counters equal Σ remainingCharge over its open records; each token and depositor counter equals Σ remainingCharge over the open records in its scope; regular ≤ marketUsdCap and slice ≤ topUpSliceUsd."

### FV-CUS-F-04 — Credited value can exceed immediate removal value by Uniswap's per-leg rounding

**Severity:** Informational.

**Spec rules:** `SPEC-UNIT-003`, `SPEC-BACK-002`, `SPEC-BACK-008`.

**Violated property:** `FV-CUS-25-exact`.

**Description.**
- With ideal math, the bound holds at every pool price, including manipulation followed by an immediate full withdrawal (`FV-CUS-25-amgm`, `FV-CUS-25-oracle`).
- Uniswap rounds each removed leg down by less than one raw unit, and the LPOracle's `− 1` margin (10^-8 USD per whole token) does not cover that for small positions.
- Over 17,053 samples the largest shortfall was 378 (8-decimal USD), i.e. $0.00000378. No sample exceeded one raw unit per leg plus the two floors (`FV-CUS-25-fuzz`).

**Counterexample.** `L = 1` at pool price 1, both legs $1, 6 decimals: removal returns (0, 0) while the credited value is 199.

**Recommendation.** Add to `SPEC-UNIT-003`: "Removal rounds each leg down by less than one raw unit, so the realizable value of a position can fall short of its LPOracle value by at most one raw unit of each token; the collateral factor and LPVaultSwap's `floorRoundingAllowanceGho` absorb this."

### FV-CUS-F-05 — INV-001 says pending liquidity stays in LPVault custody

**Severity:** Informational.

**Description.** `INV-001` says the liquidity behind pending units "stays in LPVault custody and is released only to LPVaultSwap in the `settlePending` call". `REQ-VAULT-135` instead removes that liquidity at reconciliation and collects its principal to Collateralization, and `REQ-VAULT-139` pays it from Collateralization's balance.

**Recommendation.** Replace the sentence with: "The pool tokens behind pending units, removed and collected at reconciliation, are held by Collateralization and paid only to LPVaultSwap in the `settlePending` call whose burn retires those units."

### FV-CUS-F-06 — Methodology T-19 omits the reconcile wait

**Severity:** Informational.

**Description.** T-19 says only an Aave pause or a Hub halt blocks a debt-free withdrawal. `REQ-VAULT-143` and `INV-045` add a third case: an account with an unsettled seizure must wait while Hub shares ≠ assets.

**Recommendation.** Append to T-19: "and, for an account with an unsettled seizure, while Hub shares ≠ assets (`REQ-VAULT-143`)".

## 6. Bug-class sweep

| Bug class | Result | Evidence |
|---|---|---|
| Rounding that lowers a share or unit rate, or rounds twice between buckets | Ruled out | `FV-CUS-16-rate-add` and `FV-CUS-16-rate-remove` (Hub share price never falls); `FV-CUS-08-backing` (pending backing per remaining unit never falls); `FV-CUS-13-split` (exit charge recomputed from the original basis, so it never accumulates rounding); `FV-CUS-16-add` and `FV-CUS-16-remove` (1:1 units) |
| Sum invariants broken by re-registration, duplicates or self-transfer | Ruled out | `FV-CUS-10-reregister`, `FV-CUS-05-dup`, `FV-CUS-10-transfer(-From)-conserve`, `FV-CUS-12-insertsum` |
| Solvency or backing check skipped on one path | **Found: F-01** | `burnSeized` has no tied settlement. Withdraw-with-debt solvency is checked after the withdrawal (`FV-CUS-29-post`); `FV-CUS-29-order` shows why that order matters. |
| Profit from splitting | Ruled out | `FV-CUS-12-split`, `FV-CUS-13-split`, `FV-CUS-08-sequence`, `FV-CUS-MP-value` (every pledge is ≥ $10) |
| 1-wei front-running or griefing | Ruled out | `FV-CUS-15-donation` (1-unit donations change no debit); T-10 (wallets cannot hold units); `FV-CUS-26-commute`; `FV-CUS-08-noburn` and `REQ-VAULT-145` (a stale pending read can only revert) |
| Donations changing accounting | Ruled out | `FV-CUS-09-*`, `FV-CUS-02-increaseLiquidity`, `FV-CUS-16-donation`; pending amounts come only from stored values |
| Uninitialized or re-initialized proxies | Ruled out in custody | Custody contracts are immutable with constructor bindings; the registry is append-only (`FV-CUS-10-reregister`). PositionProxy initialisation is control-area T-62. A hostile Adapter registering any address is within the stated blast radius (`FV-CUS-10-hostile`). |
| Read-only reentrancy via views | Ruled out | `FV-CUS-24-views` (Collateralization and LPVault views revert for non-holders under the Lock); `FV-CUS-28-reentry` (a token hook inside NFPM `collect` or `decreaseLiquidity` enters no Avana entry point); the vault token has no hooks |

**Additional checks**

1. **LP value.** Proved for ideal math at any pool price, and under CF, sale-impact and price-move margins (`FV-CUS-25-amgm`, `oracle`, `cf`, `move`). Realizable value covers `CF × credited` exactly when `(1 − m)(1 − s) ≥ CF`, a condition the liquidation area sizes. Rounding residue: F-04.
2. **Withdrawals and solvency.** `FV-CUS-29-post`, `debtfree`, `liquidity` and the `order` witness; `FV-CUS-26-commute` and `FV-CUS-26-other` (non-interference). T-19 is broken only by F-01.
3. **Token handling.**
   - `FV-CUS-08-fot` is a witness for why fee-on-transfer tokens must stay excluded: the final settlement would revert.
   - Zero payouts are skipped (`FV-CUS-08-zero`).
   - Blocklisted recipients make the transfer revert with backing and owed fees intact (`REQ-VAULT-126`, `REQ-VAULT-142`, `FV-CUS-28-*`).
   - Reentrancy is ruled out by `FV-CUS-28-reentry`; decimals are T-22.
4. **Accounting.** `FV-CUS-01-*`; `FV-CUS-27-close` (closing reduces credited + pending, and supply, by exactly the released units); rates are monotone (`FV-CUS-16-rate-*`, `FV-CUS-08-backing`).
5. **LP journey.** `FV-CUS-28-journey`: pledge → fees → `collectFees` → donation → withdraw returns all liquidity and every fee, paid or still owed. `FV-CUS-28-<call>`: in every call, custodied liquidity falls only in a debited removal, and owed fees fall only when paid to the depositor. Borrow and repay never touch custody (`REQ-COLL-008`, `REQ-VAULT-087`).

## 7. Formal verification

**Notations:**
- Verified: unsat for all inputs in range.
- Violated: a counterexample was found.
- Holds within bounds: randomized, or bounded structure as stated. `run.sh` prints VERIFIED\* for the randomized Quint runs.

**Run totals:**
- Z3: 305 verified and 6 violated rules: `FV-CUS-01-orphanBurn`, `FV-CUS-19-orphan`, `FV-CUS-11-depositor-hostile`, `FV-CUS-14-perbucket`, `FV-CUS-14-perbucket-trace`, `FV-CUS-25-exact`.
- Quint: `FV-CUS-QNT-01` holds within bounds (10,000 samples × 20 steps); `FV-CUS-QNT-02` is violated (F-01).
- The 7 violated checks are those 6 Z3 rules plus `FV-CUS-QNT-02`.
- `FV-CUS-25-fuzz` holds within bounds (17,053 samples).

### Properties overview

| Target | Family | Contract | Statement | Spec IDs | Status | Checks |
|---|---|---|---|---|---|---|
| T-01 | F-05 | Collateralization, VaultToken | supply = Σ credited + pending | INV-001, SPEC-BACK-009 | **Violated → F-01**; verified for every conforming call and never-settled seizures | `FV-CUS-01-*`, QNT-01/02 |
| T-02 | F-06 | LPVault, Collateralization | live ≥ credited; LPVault owns NFT | INV-002, SPEC-BACK-010 | Verified (any Adapter) | `FV-CUS-02-*` |
| T-03 | F-05 | VaultToken, Hub, Spoke | Hub balance = added assets = Σ shares = supply − LPVaultSwap balance | INV-003 | Verified with a reviewed LPVaultSwap; non-conforming Hub transfer leaves stranded units (accepted, REQ-VTOKEN-031) | `FV-CUS-03-*` |
| T-04 | F-05 | Collateralization | proxy shares = Σ credited; shortfall `max(0, C − S)` | INV-008, INV-058 | Verified (≤ always; = after each exit or settlement) | `FV-CUS-01-*`, `15-ledger`, `20-*` |
| T-05 | F-13 | Collateralization | one open record per tokenId | INV-005, REQ-VAULT-027 | Verified | `FV-CUS-05-dup` |
| T-06 | F-14 | VaultToken | Adapter-only mint and burn; zero address reverts | INV-009, INV-010 | Verified | `FV-CUS-06-*` |
| T-07 | F-01 | Collateralization, Adapter | mint exactly `L`; shares + `L` | SPEC-BACK-002 | Verified | `FV-CUS-07-*` |
| T-08 | F-01 | Collateralization, Adapter | exact burns; pending payout | SPEC-BACK-012 | Verified (conforming); see F-01 | `FV-CUS-08-*` |
| T-09 | F-04 | Collateralization | credited set once, only decreases | INV-006 | Verified | `FV-CUS-09-*` |
| T-10 | F-20 | VaultToken | balances only at allowed recipients | INV-011 | Verified | `FV-CUS-10-*` |
| T-11 | F-06 | LPVault | NFT exits only to its depositor or as a stray | INV-007 | Verified; **stray-pledge path → F-02** | `FV-CUS-11-*` |
| T-12 | F-08 | Collateralization | largest-first debit exact and additive | SPEC-BACK-006, INV-015 | Verified (≤ 5 records) | `FV-CUS-12-*` |
| T-13 | F-08/F-11 | Collateralization | exit charge split-independent | SPEC-BACK-005 | Verified | `FV-CUS-13-*` |
| T-14 | F-05 | Collateralization | counters = Σ charges; no revert | INV-027 | Verified in sum form, saturation unreachable; **wording → F-03** | `FV-CUS-14-*` |
| T-15 | F-12/F-17 | Collateralization | debit = own snapshot; donations irrelevant | INV-014, SPEC-BACK-007 | Verified | `FV-CUS-15-*` |
| T-16 | F-07 | Hub | shares == assets kept | SPEC-HUB-008 | Verified (configuration assumptions) | `FV-CUS-16-*` |
| T-17 | F-02 | Collateralization | zero amounts revert or change nothing | REQ-VAULT-052, REQ-VAULT-141 | Verified | `FV-CUS-17-*` |
| T-18 | F-12/F-03 | LPVault | `collectFees` to depositor; capped collect | INV-033, INV-044 | Verified | `FV-CUS-18-*` |
| T-19 | F-03 | Adapter, Collateralization | debt-free withdrawal liveness | INV-045 | **Violated → F-01** after an orphan burn; wording → F-06 | `FV-CUS-19-*`, `20-*` |
| T-20 | F-01 | Collateralization | reconcile once; skipped while shares ≠ assets | INV-058 | Verified | `FV-CUS-20-*` |
| T-21 | F-24 | custody contracts | no overflow in custody formulas | SPEC-UNIT-006 | Verified (formulas; whole contracts: `PROP-043`) | `FV-CUS-21-*` |
| T-22 | F-13/F-20 | VaultTokenFactory | decimals; full-range ticks | SPEC-UNIT-001, SPEC-BACK-001 | Verified (decimals, ticks); deploy authority and write-once registry left to control-area T-53 | `FV-CUS-22-*` |
| T-23 | F-21 | PositionProxy | balance ± units; approvals back to 0 | SPEC-PROXY-005 | Verified | `FV-CUS-23-*` |
| added | F-05/F-25 | Collateralization | addCap never binds a cap-admitted pledge; minPledgeUsd $10 | SPEC-UNIT-005, INV-069 | Verified | `FV-CUS-14-addcap`, `MP-*` |
| added | F-12 | Collateralization | withdrawals commute and do not interfere | REQ-VAULT-043 | Verified | `FV-CUS-26-*` |
| added | F-19/F-10 | Collateralization, LPVault, Lock | closed under the Lock | REQ-VAULT-091, REQ-LOCK-010 | Verified | `FV-CUS-24-views`, `28-reentry` |
| added | F-06 | LPVault, LPOracle | credited ≤ removal value | SPEC-UNIT-003 | Verified (ideal math); within one raw unit per leg (randomized) → F-04 | `FV-CUS-25-*` |
| added | F-22 | Adapter | solvency after withdraw-with-debt | SPEC-CF-001 | Verified | `FV-CUS-29-*` |

### Detailed properties

Reproduce everything with `./run.sh`, or one file with `spec/05-verification/.venv/bin/python <file>.py` run from the folder.

**Sums and backing (`fv_backing.py`)**
- `FV-CUS-01-base`; `FV-CUS-01-<call>` for 25 conforming and 3 non-conforming calls, all Verified.
- `FV-CUS-01-orphanBurn`: Violated (F-01).
- Fix checks: `FV-CUS-01-FIX-<call>` (31 calls), `FV-CUS-01-FIXEQ-<call>` (28 calls), `FV-CUS-19-FIX-p*`, `FV-CUS-07-FIX-p*`.
- `FV-CUS-03-<call>` (28 calls); `FV-CUS-27-close`.
- Mutations caught:
  - a `burnSeized` with no settlement (the violated rule);
  - dropping `+ units` from `REQ-VAULT-131`, which makes S differ from the preview value and fails `FV-CUS-20-p*`.

**Integrity**
- `FV-CUS-07-p*`, `FV-CUS-15-checks`, `FV-CUS-15-ledger`, `FV-CUS-15-other`, `FV-CUS-08-pending`, `FV-CUS-08-noburn`, `FV-CUS-20-*`, `FV-CUS-17-*`.

**Splitting and rounding**
- `FV-CUS-12-exact`, `bounds`, `prefix`, `stop`, `onepartial`, `revert`, `split`, `splitfail`, `insert`, `insertsum`, `order`, `example`.
- Witness: `FV-CUS-12-unsorted`.
- `FV-CUS-13-mono`, `ends`, `bounded`, `split`, `noexcess`.
- `FV-CUS-08-nooverpay`, `backing`, `final`, `sequence`, `zero`, `example`.

**Counters (`fv_exposure.py`)**
- `FV-CUS-14-pledge-r*m*{n,t}` (12); `exit-r*`, `nosat-r*`, `close-r*` (9).
- `floorbook`, `addcap`.
- `FV-CUS-MP-value`, `charge`, `pos`, `ub`, `ex0`…`ex5`.

**Rate and donations (`fv_hub.py`)**
- `FV-CUS-16-add`, `remove`, `addshares`, `addcap`, `donation`, `rate-add`, `rate-remove`.
- Witness: `drift`.
- `FV-CUS-15-donation`, `FV-CUS-15-inflate`.

**Token (`fv_token.py`)**
- `FV-CUS-10-<call>` (6); `FV-CUS-06-*`; `conserve`; `reregister`; `custodians`.
- Witness: `hostile`.
- `FV-CUS-23-*`, `FV-CUS-22-*`.

**Custody (`fv_lpvault.py`)**
- `FV-CUS-02-<call>` and `FV-CUS-11-<call>` (10 calls each, any Adapter).
- `FV-CUS-18-*`, `FV-CUS-05-dup`.
- `FV-CUS-11-depositor-{hostile (Violated), reviewed, FIX}`.
- `FV-CUS-28-*`, `FV-CUS-24-views`.

**Arithmetic (`fv_arith.py`)**
- `FV-CUS-21-*`; the `pending-mul` witness shows the 512-bit `mulDiv` is needed.

**Value and solvency**
- `FV-CUS-25-*`, `FV-CUS-29-*`.

**Quint**
- `quint run custody.qnt --invariant=inv --max-samples=10000 --max-steps=20 --seed=0x1` (QNT-01).
- The same with `--step=stepOrphan --invariant=backing` (QNT-02, violated after pledge → unsettled seizure → orphan burn).

### Comparison with the spec-stage models

The spec-stage models were read after this run.
- `spec/05-verification/quint/avana.qnt` models a hostile LPVaultSwap that keeps units or debits the wrong proxy. It predates `Q-224`, so it has no `burnSeized` and cannot cover F-01.
- No spec-stage model checks a pledge whose depositor is the LPVault (F-02).
- Every other overlapping property agrees: conforming backing, reconcile on exit, largest-first debit and the exit charge.

## 8. Spec-ID trace

Every model file carries `# FV-CUS-NN verifies: …` lines, citing 130 distinct IDs. Each ID has a definition line in `spec/01-architecture` … `spec/04-security`. `spec/05-verification/trace.py` collects these tags from `audit/formal-verification/**/*.py|*.qnt`.

## 9. Re-verification against the final spec (2026-11-10)

This section reports run `FV-CUS-R3` ([RUNS.md](RUNS.md)). The models were brought up to the final text of pages 2.2 LPVault, 2.3 Collateralization, 2.4 vault tokens, 2.6 AaveAdapter mint and burn paths, 2.16 Lock, 3.1 Deposit, 3.4 Withdraw and 3.7 Collect fees, with decisions `Q-001`…`Q-278` and the interfaces under `contracts/src/custody` and `contracts/src/policy/aave-adapter`.

### 9.1 What the models now cover

**Rules that replaced the first-run rules.** The recommended changes of F-01…F-04 are now in the spec, so the `-FIX` checks became the main checks and the first-run checks of the old text were deleted (`FV-CUS-01-FIX-*`, `FV-CUS-01-FIXEQ-*`, `FV-CUS-19-FIX-*`, `FV-CUS-07-FIX-*`, `FV-CUS-11-depositor-{hostile, reviewed, FIX}`, `FV-CUS-14-perbucket`, `FV-CUS-14-perbucket-trace`, `FV-CUS-25-exact`).
- **Backing** is one-sided: `supply ≤ totalCredited + pending.units` (`INV-001`, `INV-080`, `SPEC-BACK-009`).
- **The Adapter's check** after a pledge, withdrawal, partial removal, re-credit or repay with collateral is the gap check of `REQ-ADAPTER-069` and `SPEC-PROXY-008`: supply ≤ credited + pending, and `G = totalCredited + pending.units − totalSupply` unchanged.
- **`settlePending`** checks `totalSupply + x ≤ totalCredited + pending.units` (`SPEC-BACK-012`).
- **Stray NFTs.** `pledge` refuses the LPVault and Collateralization as depositor, and `receiveNft` refuses the LPVault as owner (`REQ-COLL-005`, `REQ-VAULT-007`, `REQ-VAULT-147`).
- **Exposure counters** are stated in sum form (`INV-027`).
- **LP value.** The rounding bound of `SPEC-UNIT-003` is one raw unit of each token.

**New features modelled.**

| Feature | Rules | Model |
|---|---|---|
| Partial removal | `REQ-COLL-014`, `REQ-ADAPTER-078`, `REQ-VAULT-161`, `INV-088`, `WDR-POST-010` | `fv_backing.py` `op_release_partial` (proxy withdraw, burn, reconcile with `S = shares + units`, `0 < units < credited`, record debit, rescue cap, gap check); `fv_lpvault.py` `releaseLiquidity` (principal only to the depositor of record); Quint `removePartial` |
| Re-credit | `REQ-COLL-015`, `REQ-ADAPTER-079`, `SPEC-BACK-013`, `DEP-021`…`DEP-025` | `fv_backing.py` `op_recredit` (reconcile with current shares, `added = live − credited`, `NothingToRecredit`, `LiquidityAboveBound`, mint and supply of `added`, `SupplyIncomplete`, gap check); `fv_exposure.py` re-credit booking and rebase; `fv_lpvault.py` `recredit`; Quint `recredit` |
| Release for deleverage | `REQ-COLL-017`, `REQ-ADAPTER-080`, `REQ-ADAPTER-081` | `fv_backing.py` `op_deleverage` (reconcile, `0 < units ≤ credited`, close at 0 credited units, Adapter share-drop check, gap check); Quint `deleverage` |
| Rescue units | `SPEC-BACK-014`, `REQ-COLL-016`, `REQ-COLL-018` | `rs_i` and `accountRescueUnits` in `fv_backing.py` and Quint (booked at pledge and re-credit, capped at credited after every debit, dropped at close); the `rescueUnits` formula in `fv_exposure.py`; the `getAccountRescueUnits` Lock exception in `fv_lpvault.py` |
| One-sided backing gap | `INV-080`, `REQ-ADAPTER-069`, `REQ-ADAPTER-075`, `SPEC-PROXY-008`, `SPEC-BACK-012` | Gap accounting for every call, liveness of every Adapter call from states with a positive gap, and exactness of the gap check against a mismatched mint or burn |

Pause reasons, breakers, the address freeze, oracle routes, LPVaultSwap's minimums and fees and the timelock are outside this area: Collateralization reads none of them on any path (`REQ-COLL-008`), and the custody checks hold whatever they return. They are verified in the control and liquidation areas.

### 9.2 Results

| File | Verified | Violated | What it adds for the final spec |
|---|---|---|---|
| `fv_backing.py` | 330 | 1 | One-sided backing over 47 calls (42 conforming, 5 non-conforming), gap accounting (`FV-CUS-01-gap-*`), equality under conforming calls (`FV-CUS-01-eq-*`), rescue-unit invariant (`FV-CUS-33-*`), partial removal (`FV-CUS-30-*`), re-credit (`FV-CUS-31-*`), deleverage release (`FV-CUS-32-*`), gap-check exactness (`FV-CUS-34-*`), liveness after an orphan burn (`FV-CUS-19-orphan*`) |
| `fv_list.py` | 14 | 0 | `FV-CUS-12-keepplace`: a partial removal or re-credit changes one record in place and keeps it linked |
| `fv_exposure.py` | 54 | 0 | Re-credit counter booking (`FV-CUS-14-recredit-r*`), the rebased basis (`FV-CUS-13-rebase-*`, `oldbasis` witness), rescue units (`FV-CUS-33-bound`, `share`, `full`), spec examples |
| `fv_pending.py` | 7 | 0 | Unchanged payout math |
| `fv_hub.py` | 10 | 0 | Unchanged |
| `fv_token.py` | 24 | 0 | Unchanged |
| `fv_lpvault.py` | 47 | 0 | Stray-NFT rule under any Adapter (`FV-CUS-11-depositor`, mutation witness), `releaseLiquidity` (`FV-CUS-18-partial`), re-credit custody (`FV-CUS-31-custody`), the Lock view exceptions (`FV-CUS-24-views`, `FV-CUS-24-rescue`) |
| `fv_arith.py` | 9 | 0 | `FV-CUS-21-rescue-mul`, `FV-CUS-21-rebase-add` |
| `fv_lpvalue.py` | 7 | 0 | `FV-CUS-25-residual` and an exact-rational `FV-CUS-25-fuzz` against the `SPEC-UNIT-003` bound, `FV-CUS-25-example` |
| `fv_solvency.py` | 4 | 0 | Unchanged |
| **Z3 total** | **506** | **1** | 8 of the verified checks are satisfiable witnesses; none is Vacuous or Unknown |
| `custody.qnt` | QNT-01, QNT-02 | — | Both hold within bounds (10,000 samples × 20 steps each) |

**Quint.**
- `FV-CUS-QNT-01` steps through every conforming call and unsettled seizures. It checks `inv`: backing equality, record and account sums, shares ≤ credited, live ≥ credited, custody iff record, units at rest, the rescue-unit bound and sum, and `exitLive` (every open record's `previewRelease` units are at most its proxy's shares).
- `FV-CUS-QNT-02` adds the orphan burn and the `settlePending` without a burn, and checks `invOneSided`, the same invariant with the one-sided backing bound.
- Each new action was shown reachable: a mutant of each that skips the gap check and mints or burns one unit too many is caught within 3,000 samples.

**Mutations caught** (run outside `run.sh`):
- A partial removal that reconciles without adding back the withdrawn units fails `FV-CUS-01-releasePartial(*)`.
- A re-credit that mints one unit more than `added` makes its step hypotheses contradictory through `SupplyIncomplete` (reported Vacuous), and `FV-CUS-34-recredit` rejects it.
- Dropping the rescue-unit cap after a debit fails `FV-CUS-33-*`.
- A deleverage release that never closes fails `FV-CUS-32-close-*`.

`run.sh` exits 1, from `FV-CUS-01-gapmono` (finding F-07).

### 9.3 New findings

#### FV-CUS-F-07 — PROP-065 says nothing lowers the backing gap; SPEC-BACK-012 lets a `settlePending` without a burn lower it

**Severity:** Informational. No unit becomes unbacked. A prover rule written from `PROP-065` cannot pass against the specified `settlePending`, because its environment havocs LPVaultSwap, the same environment in which the orphan burn arises.

**Spec rules:**
- `PROP-065` states "only a `burnSeized` not followed by its debit raises it, and nothing lowers it".
- `SPEC-BACK-012`, `REQ-VAULT-139` and `REQ-COLL-012` admit `settlePending(x)` whenever `totalSupply + x ≤ totalCredited + pending.units`. They state that after an unsettled `burnSeized` "a settlement of `x` up to that gap retires pending units whose vault tokens no longer exist".

**Violated check:** `FV-CUS-01-gapmono` (Z3 minimal instance: supply 0, credited 3, pending 1, `x = 1`; the gap falls from 4 to 3). `FV-CUS-01-gap-settlePending-without-burn` proves the exact effect: the gap falls by `x` and stays ≥ 0. `FV-CUS-01-settlePending-without-burn` proves every remaining unit stays backed.

**Counterexample** (the SPEC-BACK-009 example):
1. A non-conforming LPVaultSwap burns the 1,575,000,000 units it seized from alice and never settles them.
2. Alice withdraws NFT 7. Her withdrawal reconciles the 1,575,000,000 units into pending, leaving `totalCredited = 3,425,000,000`, `pending.units = 1,575,000,000`, `totalSupply = 3,425,000,000` and a gap of 1,575,000,000.
3. LPVaultSwap calls `Collateralization.settlePending(vt, 1,575,000,000)` without a burn. The check `3,425,000,000 + 1,575,000,000 ≤ 3,425,000,000 + 1,575,000,000` passes, and the call pays 1,259,999,999 USDC and 1,968,749,999 USDT raw units.
4. The gap is now 0.

**Recommendation (exact spec change).** In `PROP-065`, replace "only a `burnSeized` not followed by its debit raises it, and nothing lowers it" with: "only a `burnSeized` not followed by its debit raises it, and only a `settlePending(x)` called without a matching burn lowers it, by the units of `x` not burned in that call and never below 0 (`SPEC-BACK-012`)". In its environment column, state that LPVaultSwap's `burnSeized` and `settlePending` calls are havocked as well. `FV-CUS-01-gapmono` then encodes the restated property, which `FV-CUS-01-gap-*` already proves.

#### FV-CUS-F-08 — Several rules still list only the exits that existed before partial removal, re-credit and deleverage release

**Severity:** Informational (text).

**Description.** `SPEC-BACK-009`, `SPEC-BACK-011`, `REQ-VAULT-031` and `REQ-VAULT-140` list every path, and the models follow them (every check in 9.2 passes). The rules below list only the older paths or describe the old pending mechanism:
- `REQ-VAULT-129` lists the `accountCredited` changes as `+L` at `pledge`, `−units` in `settleSeizure` and `release`, and `−shortfall` in reconciliation. It omits `+added` in `recredit` and `−units` in `releasePartial` and `releaseForDeleverage`.
- `REQ-VAULT-130` says only `release` and `releaseZeroCredit` skip reconciliation while Hub shares ≠ assets.
- `REQ-COLL-006` names only `release` and `releaseZeroCredit` as the calls that close a record and return its NFT, although `releaseForDeleverage` also closes a record and returns its NFT.
- `INV-008`, `INV-058` and `PROP-045` name only the withdrawal, zero-credit release and liquidation settlement as the calls that reconcile.
- `INV-058` says `settlePending` "has the LPVault remove the pro-rata liquidity … to LPVaultSwap". The removal happens at reconciliation (`REQ-VAULT-135`); `settlePending` transfers pool tokens from Collateralization's own balance (`REQ-VAULT-139`, and `INV-001` as corrected for F-05).
- In the audit methodology:
  - T-01 states the equality.
  - T-08 states `totalSupply + units == totalCredited + pending`.
  - T-09 says credited only decreases.
  - T-14 uses the per-counter wording of F-03.
  - T-20 lists three reconciling calls.

**Recommendation (exact changes).**
- `REQ-VAULT-129`: "`+L` at `pledge` and `+added` at `recredit`; `−units` in `settleSeizure`, `release`, `releasePartial` and `releaseForDeleverage`; `−shortfall` in reconciliation."
- `REQ-VAULT-130`: "while they differ, `release`, `releasePartial`, `recredit`, `releaseForDeleverage` and `releaseZeroCredit` skip reconciliation".
- `REQ-COLL-006`: "closing a record (`release`, `releaseZeroCredit`, or a `releaseForDeleverage` that debits every credited unit) calls `returnNft` in the same call".
- `INV-008`: "the next withdrawal, partial removal, re-credit, deleverage release, zero-credit release or liquidation settlement of `(p, m)` reconciles it first".
- `INV-058`, first sentence: "In `release`, `releasePartial` and `releaseForDeleverage` (current supply plus the units withdrawn earlier in the same Adapter call), `recredit` and `releaseZeroCredit` (current supply) and `settleSeizure` (the `beginSeizure` snapshot)".
- `INV-058`: replace "has the LPVault remove the pro-rata liquidity (…) to LPVaultSwap" with "transfers the pro-rata pending pool tokens (…) from Collateralization to LPVaultSwap".
- `PROP-045`: the same list of reconciling calls as `REQ-VAULT-140`.
- Methodology:
  - T-01: "`totalSupply ≤ Σ credited + pending` for any LPVaultSwap implementation, with equality while every `burnSeized` is settled in the same call; every Adapter call keeps the gap".
  - T-08: "`totalSupply + units ≤ totalCredited + pending`".
  - T-09: "`credited` is set at pledge, falls only by debits and rises only in `recredit`, to exactly the live liquidity".
  - T-14: the sum form of `INV-027`.
  - T-20: the reconciling calls of `REQ-VAULT-140`.

#### FV-CUS-F-09 — REQ-COLL-018 and REQ-VAULT-089 describe call orders that the specified flows do not follow

**Severity:** Informational (text). No state is observable mid-call: pool tokens are standard ERC-20 tokens with no receiver hooks (`REQ-ARCH-014`), and every other Avana entry point and view is closed under the Lock (`FV-CUS-24-views`, `FV-CUS-24-rescue`, `FV-CUS-28-reentry`).

**Description.**
1. **When the health check reads rescue units.** `REQ-COLL-018` justifies the `getAccountRescueUnits` Lock exception by saying a withdrawal or partial removal "runs the check after the proxy's Spoke withdrawal and before its call into Collateralization". The decided order is the opposite: the check runs after `release` or `releasePartial` has returned, so a withdrawn record's rescue units are not subtracted twice (`REQ-ADAPTER-078`, `REQ-PROXY-038`, `REQ-RISK-068`, `SPEC-CF-005`, `WDR-011`, `WDR-035`; `Q-253`).
2. **Checks-effects-interactions.** `REQ-VAULT-089` says record, counter, total, rescue-unit and pending updates complete before the LPVault removes or releases liquidity. As specified, two steps do not satisfy that:
   - Reconciliation books `pending.amount0` and `amount1` from the balance delta measured around its own `removeLiquidity` (`REQ-VAULT-135`), so those writes come after the call.
   - In `release`, `releasePartial`, `releaseForDeleverage` and `settleSeizure`, reconciliation and its removals run before the call's own debit (`REQ-COLL-014`, `REQ-COLL-017`, `REQ-VAULT-053`, and the 2.3 worked example, where NFT 42's remaining units are debited after the reconciliation's removal).
   - `REQ-COLL-018` and `REQ-LOCK-016` rely on `REQ-VAULT-089` for the claim that the rescue-unit value read is always settled.

**Recommendation (exact changes).**
- `REQ-COLL-018`: replace "a withdrawal or partial removal runs the check after the proxy's Spoke withdrawal and before its call into Collateralization" with "a withdrawal with debt and a partial removal with debt run the check after `release` or `releasePartial` has returned (`REQ-ADAPTER-078`, `REQ-PROXY-038`, `REQ-RISK-068`)".
- `REQ-VAULT-089`: "Collateralization MUST follow checks-effects-interactions: a reconciliation completes its record, counter, total, rescue-unit and `pending.units` updates before its `removeLiquidity` calls and books `pending.amount0` and `amount1` from the balance delta measured around each of them (`REQ-VAULT-135`); the call's own record, counter, total and rescue-unit updates complete before the LPVault returns an NFT or removes or releases liquidity for that debit, and before pool tokens leave in `settlePending`. No code outside Avana runs between those steps, because pool tokens have no receiver hooks (`REQ-ARCH-014`)."

### 9.4 Earlier findings against the final text

| Finding | Final rules read | Checks that pass in `FV-CUS-R3` | Status |
|---|---|---|---|
| F-01 | `REQ-ADAPTER-069`, `REQ-ADAPTER-075`, `SPEC-PROXY-008`, `INV-001`, `INV-080`, `REQ-VAULT-029`, `REQ-VTOKEN-016`, `SPEC-BACK-009`, `SPEC-BACK-012`, `REQ-VAULT-139`, `REQ-COLL-012`, `REQ-COLL-007` | `FV-CUS-01-orphanBurn`, `FV-CUS-01-<call>` (47 calls), `FV-CUS-01-gap-*`, `FV-CUS-01-eq-*`, `FV-CUS-19-orphan`, `FV-CUS-19-orphan-partial`, `FV-CUS-19-orphan-pledge`, `FV-CUS-19-orphan-gapkept`, `FV-CUS-07-p*`, `FV-CUS-20-p*`, `FV-CUS-30-live-p*`, `FV-CUS-31-live-p*`, `FV-CUS-32-live-p*`, `FV-CUS-34-*`, `FV-CUS-08-pending`, `FV-CUS-08-noburn`, `FV-CUS-08-noburn-gap`, `FV-CUS-QNT-02` | Resolved in spec |
| F-02 | `REQ-VAULT-147`, `REQ-COLL-005`, `REQ-VAULT-007`, `REQ-COLL-019` | `FV-CUS-11-depositor` (any Adapter), `FV-CUS-02-pledge`, `FV-CUS-11-depositor-mut` (the check is needed) | Resolved in spec |
| F-03 | `INV-027` (sum form) | `FV-CUS-14-pledge-*`, `FV-CUS-14-exit-*`, `FV-CUS-14-nosat-*`, `FV-CUS-14-close-*`, `FV-CUS-14-recredit-*` | Resolved in spec (methodology T-14 wording: F-08) |
| F-04 | `SPEC-UNIT-003` (one raw unit per leg) | `FV-CUS-25-residual`, `FV-CUS-25-fuzz` (17,053 samples, exact rationals), `FV-CUS-25-example` | Resolved in spec |
| F-05 | `INV-001` (pending pool tokens held by Collateralization) | `FV-CUS-20-*`, `FV-CUS-08-*`, `FV-CUS-QNT-01` | Resolved in spec (`INV-058` wording: F-08) |
| F-06 | Methodology T-19; `INV-045` | `FV-CUS-19-orphan*`, `FV-CUS-20-*`, `FV-CUS-QNT-02` (`exitLive`) | Resolved in the methodology |

### 9.5 Properties overview against the final spec

| Target | Statement | Spec IDs | Status | Checks |
|---|---|---|---|---|
| T-01 | `supply ≤ Σ credited + pending` for any LPVaultSwap; equality while every `burnSeized` is settled; every Adapter call keeps the gap; only the orphan burn raises it | INV-001, INV-080, SPEC-BACK-009 | Verified; "nothing lowers it" → **F-07** | `FV-CUS-01-*`, QNT-01/02 |
| T-02 | live ≥ credited, including partial removal and re-credit | INV-002, SPEC-BACK-010 | Verified (any Adapter) | `FV-CUS-02-*`, `FV-CUS-30-record-*`, `FV-CUS-31-*` |
| T-04 | proxy shares ≤ Σ credited; equal after every reconciling call | INV-008, REQ-VAULT-140 | Verified for all six reconciling calls | `FV-CUS-15-ledger`, `FV-CUS-20-*`, `FV-CUS-30-record-*`, `FV-CUS-31-record-*`, `FV-CUS-32-close-*` |
| T-09 | credited never rises, except a re-credit to exactly the live liquidity; proxy fixed | REQ-VAULT-031, REQ-VAULT-024 | Verified | `FV-CUS-09-*` |
| T-11 | NFT exits only to its depositor or as a stray; a stray is never pledged | REQ-VAULT-147, REQ-COLL-005 | Verified (any Adapter) | `FV-CUS-11-*` |
| T-14 | counters in sum form, re-credit included; no saturation | INV-027 | Verified | `FV-CUS-14-*` |
| T-13 | exit charge on the rebased basis; life total = pledge + re-credit charges | SPEC-BACK-005, SPEC-BACK-013 | Verified | `FV-CUS-13-*` |
| T-19 | debt-free exits pass after an orphan burn | INV-045 | Verified | `FV-CUS-19-*`, QNT-02 `exitLive` |
| Partial removal | record open with credit ≥ 1; burn = debit; principal only to the depositor; other proxies untouched; removing every unit reverts | REQ-COLL-014, REQ-VAULT-161, INV-088 | Verified | `FV-CUS-30-*`, `FV-CUS-18-partial` |
| Re-credit | mint = live − credited; credited = live; reverts with nothing to add | REQ-COLL-015, INV-088 | Verified | `FV-CUS-31-*`, `FV-CUS-17-recredit0` |
| Deleverage release | closes exactly at 0 credited units; burn = debit | REQ-COLL-017 | Verified | `FV-CUS-32-*`, `FV-CUS-17-deleverage0` |
| Rescue units | ≤ credited; account sum; `rescueUnits ≤ L` and covers the slice share | SPEC-BACK-014, REQ-COLL-016 | Verified | `FV-CUS-33-*` |
| Gap-check exactness | a mint or burn off by any `d ≠ 0` reverts `BackingMismatch` | REQ-ADAPTER-069, SPEC-PROXY-008 | Verified | `FV-CUS-34-*` |
| Views under the Lock | only the holder reads ledger views; `getAccountRescueUnits` only under the Adapter; `liquidityOf` only by Collateralization | REQ-VAULT-091, REQ-VAULT-151, REQ-COLL-018 | Verified; timing wording → **F-09** | `FV-CUS-24-*` |
| LP value | credited ≤ realizable + one raw unit per leg | SPEC-UNIT-003 | Verified | `FV-CUS-25-*` |

Targets not listed (T-03, T-05…T-08, T-10, T-12, T-15…T-18, T-20…T-23 and the added rows of section 7) keep the status of section 7 and pass in `FV-CUS-R3`, re-run on the updated call set where they apply (`FV-CUS-03-*` and `FV-CUS-17-*` include the new calls).

### 9.6 Spec-ID trace

The model files cite 161 distinct spec IDs, each defined in `spec/01-architecture` … `spec/04-security`. `trace.py` reports no error from any file in this folder.

## 10. Re-verification against the AMM-neutral design (2026-11-10)

This section reports run `FV-CUS-R5` ([RUNS.md](RUNS.md)) against the rewritten pages 2.2 LPVault, 2.3 Collateralization, 2.4 vault tokens, 2.5 PositionProxy and ProxyManager, 2.16 Lock, 2.19 AMM integration interface and 2.20 Uniswap v3 integration, with decisions `Q-001`…`Q-380`.

### 10.1 What changed in the design and in the models

| Design change | Effect on the custody models | Checks |
|---|---|---|
| One AMM-neutral ledger per chain; records keyed by (`integrationId`, `positionKey`), never `tokenId` | New rule: positions of two integrations that share a key are two records; a second pledge of the same pair is refused. The list, backing, exposure and pending models are unchanged: they never depended on the key type | **new** `FV-CUS-35-key`, `-dup`, `-W` |
| Every amount is an array with one entry per market token, 2 to 8 tokens | The pending payout, the per-unit backing and the split conservation are proved per token index and enumerated for n = 2…8. `fv_pending.py` keeps the two-token example of `SPEC-BACK-012` | **new** `FV-CUS-38-*` |
| Exact range match at pledge (`AMMN-RT-01`), signed tick alignment | A pledge is accepted only on the market's exact range; the witness shows a `[−1, 1]` position credited in a `[−50, 50]` market would be valued 49.9× too high. `FV-CUS-22-ticks` now checks the signed `int24` remainder (`SPEC-BACK-001`), with the `uint24`-cast witness at tick −516 | **new** `FV-CUS-36-*`; **changed** `FV-CUS-22-ticks`, **new** `FV-CUS-22-W` |
| Composition at the oracle price clamped to the range (`SPEC-AMM-V3-001`) | Proved for a bounded range: in range, above and below, the units are worth at least their clamped composition at every spot price. `fv_lpvalue.py` keeps the full-range case, which is the outermost exact range | **new** `FV-CUS-37-*` |
| Vault-token decimals from the value of one credited unit (`SPEC-UNIT-001`) | The old rule `2d = d0 + d1` is replaced by "smallest `d` in [6, 18] with `10^d · v ≥ $1`" | **changed** `FV-CUS-22-decimals` |
| One immutable logic-free PositionProxy per wallet × CDP Spoke × market, CREATE2 over the triple, no beacon and no migration | One market per proxy is inductive over pledges (`proxyMarket` written once); two triples never share a proxy address under CREATE2 collision resistance. `FV-CUS-23-*` (proxy unit movement) is unchanged: the Adapter drives the same supply and withdraw steps through `execute` | **new** `FV-CUS-39-*` |
| Hub-wide caps (token, depositor, pool) as one counter per Hub in the ledger | A pledge on any Spoke of a Hub keeps the Hub's exposure within the cap; two ranges on one pool share one pool counter. The witness shows per-Spoke counters admit three times the cap with three Spokes | **new** `FV-CUS-40-*` |
| At most 16 records per account and market (`AMMN-GAS-01`), 5-slot record | Pledge limit, worst-case seizure gas 5,950,000, the unbounded witness (125 records need more than the transaction cap) and the field widths | **new** `FV-CUS-41-*` |
| Lock with exactly two members, AaveAdapter and LPVaultSwap | Every value-moving Collateralization and LPVault call runs only in a member's call tree; the witness is the superseded direct fee-collection entry. The LPVault surface as 2.2 states it fails the rule for `returnStray`: **F-10** | **new** `FV-CUS-42-*` |
| Custody function names (`receivePosition`, `returnPosition`, `unwind`, `releaseToDepositor`, `collectFees`) | `fv_lpvault.py` and `custody.qnt` keep the Uniswap v3 and Slipstream ERC-721 position model; the old names map one to one (file header of `fv_lpvault.py`). Their guards are unchanged | `FV-CUS-02-*`, `-05-*`, `-11-*`, `-18-*`, `-28-*` unchanged |

Unchanged by the design: the backing invariant and gap rules (T-01), the largest-first list (T-12), the exit charge and counters (T-13, T-14), the Hub share math (T-15, T-16), arithmetic bounds (T-21) and withdraw-with-debt solvency. They are stated per vault token and never assumed one Hub, one AMM protocol or two tokens.

### 10.2 Results

Z3 and enumeration checks all pass except `FV-CUS-42-surface`, which is registered as the open finding F-10 and printed as `OPEN` with its counterexample; it does not fail `run.sh`. Both Quint runs pass. `check_ids.py` (added to `run.sh` in this run) finds every cited spec ID defined. Counts are in [RUNS.md](RUNS.md) `FV-CUS-R5`.

### 10.3 New finding

#### FV-CUS-F-10 — `REQ-LOCK-028` routes the stray-position return through the Adapter; 2.2 makes `returnStray` timelock-only with the Lock free

**Severity:** Informational. The stray position backs no record, so no ledger amount moves; the finding is a contradiction between two rules that an implementer cannot both follow.

**Check:** `FV-CUS-42-surface` encodes the LPVault's position-moving functions with their success guards as 2.2 states them and asks whether each runs only inside a call tree opened by the AaveAdapter or LPVaultSwap, as `REQ-LOCK-028` requires.

**Counterexample:** `lpVaultFunction = returnStray`, outer caller and `msg.sender` = the timelock, `holder = 0`. `REQ-VAULT-165` admits the call (it requires `msg.sender == TIMELOCK` and the Lock free), and it moves a position with no member in the call tree. 2.16's own overview says the same as `REQ-VAULT-165` ("timelock-only `returnStray` neither acquires nor joins the lock").

**Exact spec change:** in `REQ-LOCK-028`, replace "(fee collection, zero-credit release, stray-position return) MUST enter through the AaveAdapter" with "(fee collection and zero-credit release) MUST enter through the AaveAdapter; the one exception is an LPVault's `returnStray`, which moves only a position with no custody entry, is callable only by the chain's timelock and reverts while the Lock is held (`REQ-VAULT-165`)". No change to 2.2.

### 10.4 Earlier findings against the new text

F-01…F-09 stay resolved: the rules they changed kept their IDs and their meaning in the rewrite (`REQ-ADAPTER-069`, `SPEC-BACK-009`, `SPEC-BACK-012`, `PROP-065`, `REQ-VAULT-147`, `REQ-COLL-005`, `INV-027`, `SPEC-UNIT-003`, `INV-001`, `REQ-COLL-018`, `REQ-VAULT-089`), and the checks that showed each resolution pass in `FV-CUS-R5`. F-02 now reads "stray position" where it said "stray NFT"; its guards are `REQ-VAULT-167` (the LPVault refuses itself as owner) and `REQ-COLL-019` (`InvalidDepositor` for the LPVault or Collateralization).

