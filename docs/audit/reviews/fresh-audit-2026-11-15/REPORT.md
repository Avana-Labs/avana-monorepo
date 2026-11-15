# Fresh adversarial audit, 2026-11-15

Scope: Avana contracts on `origin/main` at `a024490` (`contracts/src`), checked against `docs/spec`, `docs/governance` and the pinned dependencies in `contracts/dependencies` (Aave V4 `a3ef63e`, Uniswap v3 core and periphery, Slipstream 1.0.0 and main). Uniswap v4 is out of scope. Open PR #71 (head `2ca647d`) was read for its cap and debt-mark changes, and the Medium finding was re-run against it.

Method: a manual review of every state-changing entry point, traced into the real Aave V4 Spoke, Hub and LiquidationLogic code and into the AMM pool and position-manager code. The review was done in four parts: custody and adapter, oracle, liquidation and coverage, and policy and governance. Every candidate was checked against the code before it was reported, and then against `docs/audit/findings-register.md`, `docs/spec/05-verification/03-audit-findings.md`, `docs/spec/04-security/04-design-decisions.md` and `contracts/security/*-triage.json`. Anything already recorded or accepted is listed in section 4 and is not reported as new. Every Medium finding has a passing proof-of-concept test. The tests pass on the unfixed code, so they are kept off `main`: they live on branch `claude/fresh-audit-pocs` (commit `b082463`, `contracts/test/audit/`), and each fix PR ports its test as an inverted regression test (section 9).

## 1. Result

**Security score: 88 / 100.**

No Critical or High finding. No path was found by which an attacker can take user, LP or protocol funds. The score is lowered by one Medium finding, which blocks the rescue mechanism in exactly the stress conditions it is meant for, and by four Low findings: a small leak from deficit coverage, a bypass of a speed control, a fee-bound gap, and a public-helper residue leak.

The core money paths held up under every attack class tried: custody, units-to-vault-token backing, seizure accounting, payout identity and oracle valuation. Each is enforced by balance-delta checks and exact postconditions rather than by assumptions.

| ID | Severity | Contract · function | Title | PoC (branch `claude/fresh-audit-pocs`) |
|---|---|---|---|---|
| M-01 | Medium | `RiskModulePledgeLogic._caps` | A rescue top-up made entirely from the slice is refused once a token (or depositor) counter is at or above its cap | `M01_RescueTopUpTokenCap.audit.t.sol` (3 pass on main, 2 pass on PR #71) |
| L-01 | Low | `LPVaultSwapLiquidationLogic._waterfall` | Borrower surplus is paid out of a liquidation that books a deficit for the First-Loss Reserve to cover | n/a (Low) |
| L-02 | Low | `RiskModule.creditWithdraw` via `CollateralizationRelease` | Pledge-speed window is credited for rescue charges it never charged | n/a |
| L-03 | Low | `ParameterStoreAdminRiskLogic.setAvanaFeeShareBps` | Raising the fee share does not re-check the liquidation fee bound on live markets | n/a |
| L-04 | Low | `FlashLiquidatorBase._forwardTokens` | A standing escrow credit captures later public callers' residues | n/a |
| I-01 | Info | `LPOracleCLPool._meanTick` (`POOL_CALL_GAS`) | `observe` at maximum cardinality uses 90–93k of the 100k cap (measured) | `I01_ObserveGasAtMaxCardinality.audit.t.sol` |
| I-02 | Info | docs | Spec and lifecycle text that contradicts the code | n/a |

## 2. Findings

### M-01 (Medium): a slice-only rescue top-up is refused by a token or depositor counter above its cap

- **Contract and function:** `contracts/src/policy/risk-module/RiskModulePledgeLogic.sol:229-256` (`_caps`), with `RiskModuleMath.fits` (`RiskModuleMath.sol:117-123`) and `CollateralizationBase._book` (`CollateralizationBase.sol:369,371`). On PR #71 head `2ca647d` it is the same code at `RiskModulePledgeLogic.sol:242-251`, `RiskModuleMath.sol:122` and `CollateralizationBase.sol:366`.
- **Defect:**
  - `_caps` tests every token counter with `fits(T_i, regular, tokenUsdCap)`, and the depositor counter with `fits(P, regular, depositorUsdCap)`, where `regular = usdCharge − sliceUsd`.
  - `fits` is `used <= cap && add <= cap − used`, so it fails whenever `used > cap`, even with `add == 0`.
  - A rescue top-up into a full market has `sliceUsd = usdCharge`, so `regular == 0`, yet it is still refused whenever a counter is above its cap.
  - `_book` adds the full `usdCharge`, slice included, to every token counter and the depositor counter. SPEC-CAP-002 and REQ-RISK-025 say so explicitly, so counters above their caps are normal. One slice top-up is enough to lift `T_i` above its cap.
- **Attack path / trigger:** none is needed. It happens in ordinary stress.
  1. Market A is full (`R = marketUsdCap`), and the USDC token counter on the Hub is at its cap.
  2. A borrower at HF 1.02 makes a rescue top-up of $20,000. It passes, since `T = cap` exactly, and it is booked into the slice. `T` becomes `cap + $20,000`.
  3. Every later rescue top-up in any market holding USDC on that Hub now reverts `CapExceeded("TOKEN")`, though its regular part is 0 and the slice has room.
  4. The same happens at once when the steward tightens a token cap below current exposure, and PR #71 allows a tighten to 0. With `tokenUsdCap = 0`, every rescue in every market holding that token is refused.
  5. On main the depositor counter does the same to a borrower's own second rescue. PR #71 removes the depositor counter.
- **Preconditions:** a counter at or above its cap; a market without regular room; a borrower with HF < `rescueHealthFactor` (1.10). These are the conditions the slice exists for (Q-157, Q-252, REQ-RISK-022).
- **Impact in funds:** borrowers who would have restored their health factor are liquidated instead. Each loses the net liquidation bonus on the seized amount, and the Avana fee share is taken from the same bonus. With a 5% bonus, a $100,000 position seized in a $1M stress wave costs the borrower about $5,000. The loss falls on the borrowers in a stress event, not on the protocol. Rated Medium: no theft, but it disables a safety mechanism, can be set off by an ordinary governance action (tighten to 0 in PR #71), and affects every market sharing the token.
- **Proof of concept:** `contracts/test/audit/M01_RescueTopUpTokenCap.audit.t.sol` on branch `claude/fresh-audit-pocs`.
  - `test_M01_sliceOnlyRescueBlockedOnceTokenCounterPassesCap`: the first rescue passes with `sliceUsd = usdCharge`, and the second identical one reverts `CapExceeded("TOKEN")`.
  - `test_M01_tokenCapTightenedBelowExposureBlocksAllRescues`: tightening the cap below current exposure blocks every rescue.
  - `test_M01_depositorCounterAboveCapBlocksOwnSecondRescue`: main only.
  - All three pass on `a024490`; the first two pass on PR #71 head `2ca647d`.
- **Fix:** in `_caps`, run the token test (and, on main, the depositor test) only when `regular != 0`: `if (regular != 0) { for (...) if (!fits(...)) revert ...; }`. Keep the `tokenUsed.length` check outside that condition and leave `fits` unchanged. Correct SPEC-CAP-002 (`T_i + (c − sliceUsd) ≤ tokenUsdCap` applies only when `c − sliceUsd > 0`). Add a test: full market, `T_i ≥ cap`, eligible rescue top-up passes with `sliceUsd = c`.
- **Prior coverage:** SPEC-CAP-002, F-AR-4 and AMMN-FLOW-16 record that slice charges let counters exceed their caps. None records that this then blocks later rescue top-ups. The coordinator was sent the fix for PR #71.

### L-01 (Low): borrower surplus is paid on a liquidation that leaves a deficit

- **Contract and function:**
  - `contracts/src/liquidation/lp-vault-swap/LPVaultSwapLiquidationLogic.sol:222-260` (`_waterfall`).
  - `SettlementMath.payouts` (`SettlementMath.sol:305-318`), where `borrowerSurplus = max(0, R_f − V)`.
- **Attack path:**
  1. An account's collateral can no longer cover its debt.
  2. LPVaultSwap's `liquidationCall` seizes all the vault-token collateral. Aave's `LiquidationLogic` then reports the rest of the debt as a Hub deficit in the same call. The First-Loss Reserve later pays for it through `coverDeficit`.
  3. The waterfall does not know a deficit was booked, so it still pays `B = max(0, R_f − V)` to `walletOf(proxy)`.
  4. `V` values the seized units at the conservative prices: the lower collateral price and the higher debt price. Swaps at market therefore usually recover a little more than `V`.
- **Example:**
  - Debt is 10,000 USDC; the collateral is worth 9,000 at the Aave price; the bonus is 5%.
  - About 8,571 is repaid and about 1,429 becomes a deficit.
  - `V` is about 8,955 and `R` about 8,991, so `B` of about 36 USDC goes to the defaulted borrower while the reserve pays the 1,429.
- **Preconditions:** a liquidation that books a deficit, and swap proceeds above `V`.
- **Impact in funds:** reserve funds leak to defaulted borrowers. The amount is bounded by the oracle spread, typically under 1% of the seized value per deficit liquidation.
- **Fix:**
  - In `_seize`, record whether the account still had debt and no supplied shares after `liquidationCall` (a deficit was reported).
  - In that case, pay `B` to the First-Loss Reserve of the (Hub, asset) pair with `fund`, or add it to the keeper reward, and never to the borrower.
- **Prior coverage:** none found. SPEC-LIQ-022 defines `B` without a deficit case.

### L-02 (Low): the pledge-speed window is credited for rescue charges it never charged

- **Contract and function:**
  - `RiskModule.checkPledge` (`RiskModule.sol:125-128`) charges the `MarketPledge` window only when `!charge.rescue`.
  - `RiskModule.creditWithdraw` (`RiskModule.sol:162-169`) is called from `CollateralizationRelease.sol:42,63,87` with the full released USD charge, including the share that came from rescue top-ups.
- **Attack path:**
  1. While an exemption applies (`Paused(General)`, a non-ORACLE market breaker, a failed pool-share check, or a pledge below the minimum), indebted accounts at HF < 1.10 pledge up to their restore amount as rescue top-ups, which are uncharged.
  2. When the gate clears, they withdraw. Rescue units are left out of the health check, so the withdrawal passes.
  3. Each withdrawal credits the window. For example, 16 accounts each withdrawing a $62,500 rescue top-up remove $1M of other users' window usage, and the attacker can then pledge again inside the same window.
- **Preconditions:** an exemption state, and accounts with debt at HF < 1.10.
- **Impact in funds:** none directly. The pledge-speed control can be bypassed, while caps and borrow-speed windows still bind.
- **Fix:** keep each record's uncharged (rescue) share of `usdCharge` and credit only `released − rescueShare`. Alternatively, record rescue charges in the window without applying the limit.
- **Prior coverage:** none. Net-flow credits came in with commits `83c4101` and `c8b1ef0` (2026-11-15). REQ-RISK-095 still says "a window empties only with time", so the spec also needs updating.

### L-03 (Low): raising `avanaFeeShareBps` does not re-check the fee bound on live markets

- **Contract and function:** `ParameterStoreAdminRiskLogic.setAvanaFeeShareBps` (`ParameterStoreAdminRiskLogic.sol:115-123`), which the steward can call at once.
- **Defect:** activation (`MarketRegistryActivationLogic._checkFeeBound`) and `loosenSlippageAllowanceBps` (`ParameterStoreLoosenLogic.sol:87`) both require `s · minLB ≤ (10⁴ − f)(minLB − 10⁴)`. The fee-share setter does not check it against live markets.
  - Example: with `minLB = 10,500` and `s = 380`, the bound holds at `f = 2,000` (3.99M ≤ 4.00M).
  - At `f = 2,100` it fails (3.99M > 3.95M).
- **Impact in funds:** protocol revenue only. Inside the slippage allowance, a keeper that sandwiches its own legs can then take part of Avana's fee.
- **Fix:** when `value > old`, require `_feeBoundHolds(_minLb(m), s_m, value)` for every live market, or bound `f` by the tightest live market.
- **Prior coverage:** Q-256, FINDING-189 and FV-LIQ-F-10 cover fee erosion inside the bound. This finding is a different way to break the bound itself. Separately, REQ-PSTORE-010 says the fee share changes only at the normal delay, while REQ-ROLE-117 and the code give the steward an immediate setter; the spec should be made consistent.

### L-04 (Low): a standing escrow credit captures later public callers' residues

- **Contract and function:** `FlashLiquidatorBase._forwardTokens` (`FlashLiquidatorBase.sol:481-500`) and `_watch`.
- **Attack path:**
  1. One call leaves `claimable[T][helper] != 0`, for example because its recipient cannot receive `T`.
  2. Every later call sees `w.credits[i] != 0` and skips the auto-claim, so later residues in `T` add to that credit.
  3. Anyone can then call `claimEscrowed(T)`, which sends the whole credit to the claim recipient (`feeRecipient` on the public helper).
- **Impact in funds:** later callers of the public helper lose their dust and route residues in `T`. It is hard to cause on purpose.
- **Fix:** record the credit at the start of the call and claim only the increase, or keep credits per caller.

### I-01 (Info): `observe` at maximum cardinality fits the 100k cap with 7–10% margin

- **Where:** `LPOracleStorage.sol:83` (`POOL_CALL_GAS = 100_000`), used by `LPOracleCLPool._meanTick`.
- **Concern raised:** anyone can raise a pool's observation buffer to 65,535 slots, and the buffer never shrinks. If `observe` then needed more than 100k gas, the consistency check would read as unavailable for good. The market would stay Drifting, blocking borrowing, withdraw-with-debt and every ParameterStore setter for that market.
- **Measured:** `contracts/test/audit/I01_ObserveGasAtMaxCardinality.audit.t.sol` on branch `claude/fresh-audit-pocs`.
  - Setup: a full 65,535-slot buffer of initialized observations, storage cooled, `observe([1800, 0])`.
  - Uniswap v3 pool: 90,173 gas.
  - Slipstream v1 and main pools (real EIP-1167 clones from the pinned factories, implementation cooled): 93,023 gas.
  - These totals include the outer call's cold-account cost. All succeed under the 100k cap.
- **Result:** not exploitable today. The margin is small enough that a future rise in cold-access costs, or a pool fork with a heavier oracle, would break it.
- **Recommendation:** give `observe` its own constant of about 150k, with `POKE_MIN_GAS_FLOOR` adjusted to match, and keep this measurement as a regression test.

### I-02 (Info): documentation that contradicts the code

- `docs/spec/01-architecture/01-protocol-overview.md` step 7 says "Paused and the address freeze refuse" `repayWithCollateral`. The code and REQ-ADAPTER-046/082 refuse it only under `Paused(MintPathSuspect)` and leave it open to frozen wallets.
- `contracts/src/oracle/debt-oracle/LIFECYCLE.md`, step 6 and its diagram: they say Drifting serves `max(primary, alternate, accepted)`. The code serves `max(min(p, b), A)` (`DebtOracleEvaluation._serve`, ORACLE-06).
- `contracts/src/oracle/debt-oracle/LIFECYCLE.md`, step 5: it says LPVaultSwap pokes only the LPOracle. `LPVaultSwapSettlement._checkDebtPrice` also pokes the DebtOracle.
- REQ-PSTORE-010 contradicts REQ-ROLE-117 on the fee-share delay (see L-03).

## 3. Integration assumptions checked against the pinned code

| Assumption | Checked against | Result |
|---|---|---|
| Only LPVaultSwap can complete a liquidation | `Spoke.liquidationCall`, `LiquidationLogic` (receiveShares path line 464-475), `VaultToken.isAllowedTransfer` | Holds. A third-party `receiveShares = false` call reverts on the vault-token transfer rule (Hub → LPVaultSwap or proxy only). `receiveShares = true` needs `receiveSharesEnabled`, and fee shares need `liquidationFee > 0`. The listing AIP sets both off, and the Lens drift check (`LensMarket` 176-188) watches them. These are monitored rather than enforced on-chain; already documented in 4.3. |
| Third parties cannot act on a proxy's Aave account | `Spoke.supply/withdraw/borrow/repay/setUsingAsCollateral` (`onlyPositionManager`), `setUserPositionManagersWithSig` | Holds. `PositionProxy` has no ERC-1271, no fallback and no approvals other than the per-call Spoke approval it resets, so no position manager can be granted. |
| Health factor and price that Avana checks equal what Aave uses | `AaveOracle._getSourcePrice` → `LPOracle.latestAnswer`, `Spoke._processUserAccountData`, user dynamic-config key | Holds. Same `_evaluate` path. Bonus and HF are read with the user's own config key, as `LiquidationLogic` does. |
| `borrowCount == 0` means debt-free | `Spoke.repay` clears the borrowing flag when `drawnShares == 0` (premium is repaid first), deficit path | Holds for the adapter's uses. |
| Vault-token reserve shares equal assets | `Hub.add/remove`, not borrowable | Holds. Checked on-chain each time (`_sharesEqualAssets`) before seizure and reconcile. |
| Custodied position cannot be reduced by others | Uniswap v3 and Slipstream NPM `decreaseLiquidity`/`collect` (`isAuthorizedForToken`), approval cleared on transfer | Holds. `increaseLiquidity` is permissionless but only adds liquidity; the donor loses it to the depositor, and `recredit` is depositor-only. |
| Principal removal does not collect fees | NPM `decreaseLiquidity` → `tokensOwed`; `collect` capped at the removed `(a0, a1)` | Holds (`ClLPVaultCustody._removePrincipal`). |
| Valuation is immune to spot manipulation | `ClPriceMath.oracleSqrtPrice` from feeds, clamped to range; `slot0` used only for the lock flag and cardinality | Holds. Valuing at the oracle price is also a lower bound: `V_P(amounts(S))` is minimised at `S = P`, because `dV/dS = x'(S)(P − S)` with `x' < 0`. |
| Pool read safety | `slot0.unlocked` checked before custody reads, unwinds and releases | Holds. Prevents read-only reentrancy from a swap callback. |
| Slipstream pool authenticity | `_validatePool`: clone codehash of the factory's implementation, `factory.getPool`, `nft()` | Holds. |
| Chainlink handling | Zero, negative, out-of-bounds, future or zero `updatedAt`, heartbeat plus margin, sequencer uptime and grace, length-checked returns, gas guard before each read | Holds. |

## 4. Already recorded (checked, not reported as new)

- **Caps and speed windows:** AMMN-FLOW-16 (cap squatting by debt-free LPs); ATTACK-206 (speed-window griefing); ATTACK-138 (breaker griefing); SPEC-CAP-002 / F-AR-4 (slice charges let counters exceed their caps); Q-314 / AMMN-SM-02 (`drawCap` is a gate on new draws, not a state bound).
- **Liquidation economics:** Q-250 / FINDING-072 (sandwich within the slippage allowance `s`); Q-256 / FINDING-189 / FV-LIQ-F-10 (self-sandwich and oversized `debtToCover` reduce Avana's fee); LIQ-I2 (donation to the flash source); REQ-SWAP-123 (fee-on-transfer debt assets); `MustNotLeaveDust` and whole-debt quote drift; Q-401 (no usable route); SIM-04C / Q-368 / Q-381 (unprofitable accounts).
- **Oracle behaviour:** FV-CTL-F-13 / SM-021 (stale failure timer); AMMN-RT-08 / Q-326 / Q-113 (TWAP buffer griefing); AMMN-FLOW-03 / REQ-ORACLE-099 (sequencer); ORACLE-06 (DebtOracle Drifting price); AMMN-RT-02 / AMMN-FLOW-08 / Q-325 (range-math edges); REQ-ORACLE-103 (one-block Cached hold).
- **Monitored settings and deficit coverage:** the Lens drift check watches `receiveSharesEnabled = false` and `liquidationFee = 0` (4.3 external dependencies); SPEC-FLR-006 / REQ-FLR-048 (dust `fund` before `DaoDeficitOffset.coverDeficit`, which is why both run in one batch).

## 5. State transitions and what can go wrong

All borrower and liquidation entry points run under the transient Lock (`Lock.sol`, one holder: AaveAdapter or LPVaultSwap) and are atomic.

| # | Transition (caller → entry point) | State changed | What can go wrong / checked defence |
|---|---|---|---|
| T1 | Wallet → `AaveAdapter.pledge` | Proxy created (first time); NFT to LPVault; record + `accountCredited`, `totalCredited`, `_poolUnits`, USD counters; vault token minted to proxy and supplied; collateral flag on | Pledging someone else's NFT: `transferFrom(owner = msg.sender)` plus an `ownerOf` check. Wrong pool or range: `_checkPosition`. Pre-filled Aave account at the predicted proxy: `AccountNotEmpty`, and nobody can supply on its behalf. Over-mint: credited is read from live units, and the backing gap is checked before and after. Caps and breakers: `checkPledge`. **M-01** blocks rescues wrongly. |
| T2 | Wallet → `recredit` | Credited grows by `live − credited`; mint and supply | Donated liquidity can be credited only by the depositor, who owns the NFT anyway. Charge and caps as in T1. |
| T3 | Wallet → `borrow` | Debt; borrow nonce; indebted mark; borrow-speed windows | Receiver is an Avana or Aave contract: `_checkReceiver`. Replay: nonce. Price: preBorrowCheck needs a Live price and an agreeing second source. Post-HF check. The proxy forwards exactly the delta and ends at its starting balance. |
| T4 | Anyone → `repay` | Debt down; possibly debt-free mark | Pulls exactly what it uses and refunds the rest (balance-delta checked). Never blocked by pause, freeze or price. Fee-on-transfer: `received` is measured. USDT approve: reset to 0 each time. A third party repaying is harmless. |
| T5 | Wallet → `withdraw` | Vault tokens withdrawn and burned; record closed; NFT returned | Debt-free is decided by `borrowCount == 0`. With debt: pause and freeze gates, preWithdrawCheck, post-HF check with rescue units excluded. Units must equal the record's credit. Backing gap checked. |
| T6 | Wallet → `removeLiquidity` | Partial units burned; liquidity removed to the depositor | `units < credited`; `checkRemainingRecord`; post-HF; per-leg minimums; the pool must be unlocked. |
| T7 | Wallet → `repayAllAndWithdraw` | T4 for listed reserves, then T5 | Must end with `borrowCount == 0`, otherwise it reverts `DebtRemaining`. |
| T8 | Wallet → `repayWithCollateral` → LPVaultSwap `deleverage` → flash → `deleverageRepay` → `deleverageRelease` | Debt down, units released and swapped, flash repaid, rest to wallet | Session binding (proxy, key, units, mins hash, steps), HF ≥ max(before, min), units fell by exactly `units`, premium capped. MEV falls on the user's own minimums. |
| T9 | Depositor → `collectFees` / `releaseZeroCredit` | Fees to depositor; zero-credit record closed | Depositor-only; no principal can leave (fees only); zero credit after reconcile. |
| T10 | Anyone not frozen → `LPVaultSwap.liquidate` | Spoke liquidation; seized units burned; records debited oldest-largest first; liquidity unwound; legs swapped; payouts | HF < 1 (grace HF); fresh, agreeing prices; `Kf` measured; seizure snapshot (`beginSeizure`/`_checkDrops`: shares and supply drops exactly equal units); leg minimums from oracle prices; recovery floor; escrow fallback for blocklisted payees. **L-01**: surplus on deficit. |
| T11 | Any LPVaultSwap or Adapter path → `_reconcile` / `settlePending` | Unsettled shortfall moved to pending | Only reachable when supplied < credited (a seizure not settled). Booked amounts are capped by the removed amounts. |
| T12 | Adapter/LPVaultSwap → `markIndebted` / `markDebtFree`; anyone → `refreshDebtMark` | `indebtedCount` | A stuck mark blocks only `closeMarket`; anyone can clear it. A starved Spoke read re-raises `InsufficientGas`. |
| T13 | Anyone → `LPOracle.poke` / `DebtOracle.poke` | First observation, accepted price, checkpoint, latch | Written only from Live evaluations or round history. A poke inside the pool lock writes nothing. **I-01**: gas margin on `observe`. |
| T14 | Governance (Timelock, steward) → MarketRegistry listing, activation, offboarding, `closeMarket`; ParameterStore tighten/loosen/admin; pause/freeze | Market lifecycle and parameters | Role checks verified on every setter. Tighten paths only tighten. Loosen paths are spaced and stepped. **L-03**: fee-share bound. **M-01** worsened by tighten to 0 in PR #71. |
| T15 | Coverage → `AvanaFirstLossReserve.coverDeficit`, `fund`, withdrawal queue | Reserve balances | `coverDeficit` covers only reported Hub deficits for allowed Spokes; withdrawals are timelocked and keep the reserve minimum. |
| T16 | Keeper → `FlashLiquidator` | Flash loan, liquidate, repay, forward residues | Callback bound to the initiator; single-use context. **L-04** residue capture. |

## 6. Walkthroughs

**LP / borrower, normal path.**
1. Alice approves the LPVault for NFT #7 (USDC/WETH, market range) and calls `pledge`. Her proxy is created at its CREATE2 address with an empty Aave account. The NFT moves to the LPVault, and 5e17 units are credited and supplied as collateral.
2. She borrows 10,000 USDC to herself. She collects fees at any time; principal never leaves custody.
3. She repays all with `repayAllAndWithdraw` and gets the NFT back with any uncollected fees.
4. What could break: a stale or disagreeing feed blocks her borrow but never her repay. A frozen address keeps repay and debt-free exit open.

**Borrower under stress (rescue).**
1. ETH falls and Alice's HF drops to 1.03. The market cap is full, so she tops up from the slice with `recredit` or a new pledge.
2. **M-01:** if another borrower's rescue already lifted the USDC token counter above its cap, or the steward tightened it, her top-up reverts and she is liquidated instead.

**Liquidator.**
1. Bob sees HF 0.97 and calls `liquidate` with `debtToCover` in USDC. LPVaultSwap pulls and measures `Kf`, then calls `liquidationCall`.
2. The seized units are burned, the records are debited, the liquidity is unwound to LPVaultSwap, and the WETH leg is swapped with an oracle-derived minimum.
3. The fee goes to Avana, the borrower gets any surplus, and Bob gets the rest.
4. What could break: no route works (accepted, Q-401); a blocklisted payee goes to escrow; a deficit-booking liquidation still pays borrower surplus (**L-01**).

**Attacker attempts.**

| Attempt | Outcome |
|---|---|
| Direct `liquidationCall` on a proxy to take vault tokens | Reverts on transfer. |
| Pledge another user's approved NFT | `transferFrom(msg.sender…)` fails. |
| Inflate the valuation by moving spot or flash-swapping | No effect; the oracle price is used, and spot only makes the position worth more at fair price. |
| Re-enter through a pool token or callback | Lock held; pool-lock check. |
| Front-run a proxy creation | Deploy is adapter-only; an Aave account cannot be pre-filled. |
| Grow cardinality to DoS the oracle | Measured within budget (**I-01**). |
| Wash withdrawals to reset the pledge-speed window | Possible only with rescue exemptions (**L-02**). |
| Self-sandwich legs | Bounded by `s` (known). |

## 7. Gas and DoS

- **Per-account loops** are bounded by `MAX_RECORDS_PER_ACCOUNT_MARKET = 16` (`_insert`, `_remove`, `_debit`, `_dropHead`). Market-wide record lists use swap-and-pop.
- **Liquidation:** a borrower cannot force a revert.
  - Blocklisted wallets and fee recipients fall back to escrow.
  - Out-of-range positions unwind to one token.
  - A pool locked by a callback makes the call revert and retry.
- **Gas starvation:**
  - Speed credits and debt-mark reads are wrapped with gas floors that re-raise `InsufficientGas` rather than record a false failure.
  - Oracle reads check the gas guard before each call.
  - Observation-buffer growth fits the cap (**I-01**).

## 8. Improvements by priority

**Critical:** none.

**Medium:**
- **M-01:** test token (and depositor) caps only on the regular part, `if (regular != 0)`, and fix SPEC-CAP-002. Do this before PR #71 merges, since #71 allows a tighten to 0.

**Low:**
- **L-01:** send borrower surplus from a deficit-booking liquidation to the First-Loss Reserve.
- **L-02:** credit the pledge-speed window only with charged USD, and update REQ-RISK-095.
- **L-03:** re-check the fee bound over live markets when the fee share rises, and reconcile REQ-PSTORE-010 with REQ-ROLE-117.
- **L-04:** claim only this call's increase of the escrow credit in the public FlashLiquidator.
- **I-01:** give `observe` its own gas constant (about 150k), with `POKE_MIN_GAS_FLOOR` adjusted to match.
- **I-02:** correct the overview's `repayWithCollateral` gating and the DebtOracle lifecycle text.

## 9. Where each fix and regression test lives

The proof-of-concept tests on `claude/fresh-audit-pocs` show the defects and pass on the unfixed code. Each fix PR ports the relevant test with its assertions inverted, so the test then guards the fix. This table is updated as fixes land.

| ID | Fix | Regression test |
|---|---|---|
| M-01 | PR #71 (`contracts/decisions-rest`) | Ported from `M01_RescueTopUpTokenCap.audit.t.sol` in PR #71 |
| L-01 | Audit-fixes PR (pending) | Pending |
| L-02 | Audit-fixes PR (pending) | Pending |
| L-03 | Audit-fixes PR (pending) | Pending |
| L-04 | Audit-fixes PR (pending) | Pending |
| I-01 | Audit-fixes PR (pending) | Ported from `I01_ObserveGasAtMaxCardinality.audit.t.sol` |
| I-02 | Audit-fixes PR (pending) | n/a (documentation) |
