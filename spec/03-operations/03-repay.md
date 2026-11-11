# 3.3 Repay (FLOW-003)

> **Status:** In review · **Owner:** Avana Labs · **Last reviewed:** 2026-11-10
>
> **Step prefix:** `REP-NNN`

Repay has two paths. Both act on one account: the PositionProxy of one wallet for one (CDP Spoke, market), whose debt reserves may be any asset the Spoke lists (GHO, USDC, USDT, WETH) (`Q-349`).

- **Repay with funds.** Any payer repays one debt reserve of a borrower's account through the AaveAdapter: the borrower itself, another wallet of the borrower, a rescue service or the protocol (`Q-212`, `Q-223`). The payer approves the Adapter, which moves the amount from the payer straight to the borrower's PositionProxy; the Adapter has the proxy repay its own account on the CDP Spoke and refund what Aave did not take. Repay never reads a pause state, the circuit breakers, the address freeze, the sequencer gate or anything else in the MarketRegistry, and never calls the RiskModule, an oracle or the ParameterStore, so no Avana pause, breaker, freeze, price state, gate or registry fault can block it; only Aave itself can (the debt reserve paused, the Hub halting the Spoke, `Q-351`) (`Q-227`, `Q-118`, `Q-140`, `Q-241`, `Q-242`, `Q-260`).
- **Repay with collateral.** The borrower repays one debt reserve with liquidity from one of its own pledged positions: LPVaultSwap flash-borrows the debt asset through the chain's `IFlashSource`, the proxy repays, the proxy withdraws the units, the Adapter burns them, Collateralization has the market's LPVault unwind exactly those units into the market's `n` tokens for LPVaultSwap, which converts every token that is not the debt asset over the swap routes at oracle-bounded prices, repays the flash loan and sends the rest to the wallet in the debt asset. There is no liquidation bonus, no Avana fee and no protocol budget draw (the SettlementBudget does not exist, `Q-397`). Because it can only reduce the account's risk, it runs under `Frozen`, under `Paused(General)`, for a frozen wallet and under the circuit breakers; it is refused under `Paused(MintPathSuspect)`, while the market's price is Cached or Expired, and while the sequencer gate is `Down` (`Q-255`, `Q-356`, `Q-357`).

Adapter behavior belongs to [2.6 Aave Adapter][2.6] (`SPEC-PROXY-003`, `SPEC-PROXY-007`, `SPEC-PROXY-009`); the proxy to [2.5 Position Proxy and Proxy Manager][2.5]; the record release and cap budgets to [2.3 Collateralization][2.3]; the valuation, flash loan and conversion of repay with collateral to [2.11 LPVaultSwap][2.11] (`SPEC-LIQ-020`); the unwind to the market's AMM integration, implemented by its LPVault ([2.2 LP Vault][2.2]); the lock to [2.16 Lock][2.16]; Aave behavior to [2.1 Avana Hub and Spokes][2.1]. Parameters are named as in [1.5][1.5].

## Objective

Move a debt asset to its funding Hub to reduce or clear one debt reserve of the account: any partial amount, or the full live debt of that reserve (drawn plus premium, accrued to the block) under a signed spending cap whose unused part is refunded in the same call (`Q-075`, `Q-153`, `Q-180`, `Q-234`, `Q-269`); or, with collateral, the debt that a stated number of the borrower's own units can pay at oracle value, leaving the account's health factor no lower than before (`Q-255`, `Q-356`).

## Initiator

- Repay with funds: any address. The payer is always `msg.sender` at the Adapter: the Adapter pulls the asset from the payer and the proxy refunds any unconsumed part to the payer, never pulling from or paying the borrower unless the borrower is the caller. A payer can never borrow or move collateral, because those entry points act only on `proxyOf[msg.sender][marketId]` (`Q-107`, `Q-212`, `Q-223`). A frozen address can repay as payer and can be repaid as borrower (`Q-242`).
- Repay with collateral: only the wallet whose proxy holds the record, on its own account (`proxyOf[msg.sender][marketId]`); the unwound tokens leave custody only to LPVaultSwap, whose conversion repays that account and pays the remainder to that wallet (`Q-107`, `Q-255`).

## Inputs

Repay with funds:

| Input | Type | Description | Validation |
|---|---|---|---|
| `borrower` | `address` | The wallet whose account is repaid | Has a proxy for `marketId` (`REP-012`) |
| `marketId` | `uint256` | The market `m`; with `borrower` it names the account (`proxyOf[borrower][m]`) | As above |
| `debtReserveId` | `uint256` | The debt reserve repaid (GHO, USDC, USDT, WETH, …) | Any reserve the Spoke lends; the Spoke's own error for one it does not list (`REP-012`) |
| `maxRepaySpend` | `uint256` | Most of the asset the payer will pay in this call, in its base units. For a repay-all the app sets it, and the approval, to `Lens.quoteRepayAll(borrower, marketId, debtReserveId, deadline)` ([2.17] `REQ-LENS-036`) | Partial with debt: `> 0`. Repay-all: live debt must not exceed it (`REP-005`) |
| `repayAll` | `bool` | `true` clears the live debt of the reserve: the Adapter pulls `maxRepaySpend`, Aave takes the debt, and the rest is refunded in the same call | `REP-005`, `REP-010` |
| `deadline` | `uint256` | Last valid `block.timestamp`, in seconds on every chain | `block.timestamp ≤ deadline` (`REP-003`) |

Returns `spent`. There is no permit path: the payer approves the Adapter for the asset beforehand; any later permit would use EIP-712 with `chainId`, `verifyingContract`, nonces and deadlines, wrapped in try/catch (`Q-119`, `Q-144`). There is no interest fee and no fee-first split (`Q-231`). Avana has no minimum debt, so a partial repay may leave any remainder (`Q-153`, `Q-381`).

Repay with collateral, `AaveAdapter.repayWithCollateral(RepayWithCollateralParams p)` ([2.6] `REQ-ADAPTER-080`):

| Field of `p` | Type | Description | Validation |
|---|---|---|---|
| `marketId` | `uint256` | The market `m` of the caller's account | The caller has a proxy for `m` (`REP-013`) |
| `integrationId`, `positionKey` | `uint32`, `bytes32` | The record whose liquidity repays; `positionKey` with the market's `integrationId` names the position (for Uniswap v3 `bytes32(tokenId)`; for Slipstream `bytes32((uint256(generation) << 248) | tokenId)` with the market's generation) | `integrationId` is the market's; the record belongs to the caller's proxy and market `m` (`REP-014`, `REP-019`) |
| `units` | `uint128` | Credited units to release; releasing every credited unit returns the position | `units > 0` (`REP-013`); at most the record's credited units after reconciliation (`REP-019`) |
| `minAmounts` | `uint256[]` | Per-token minimums of the unwind, one per market token, in each token's base units | Length `n` (`LengthMismatch`); each unwound amount at least its minimum (`REP-019`) |
| `debtReserveId` | `uint256` | The debt reserve repaid | Approved for `spoke` and owed (`REP-014`) |
| `minDebtRepaid` | `uint256` | Least debt the call must repay, in the asset's base units | `x ≥ minDebtRepaid` (`REP-017`) |
| `routeMode` | `uint8` | Which approved swap routes convert the tokens: primary, primary then alternate | `REP-020` |
| `deadline` | `uint256` | Last valid `block.timestamp` | `REP-013` |
| `minHealthFactor` | `uint256` | Least Aave health factor after the call while debt remains, WAD | `REP-021` |

The field that bounded a GHO buy leg is gone: the flash loan is of the debt asset itself, so there is no buy leg. Returns `(debtRepaid, toWallet)`, `toWallet` in the debt asset. The Lens previews it with `previewRepayWithCollateral(wallet, marketId, positionKey, units, debtReserveId)` ([2.17]). It needs no approval of the debt asset (`Q-255`).

## Preconditions

- Repay with funds: the payer approved the Adapter for at least the amount to be pulled (`A.approve(AaveAdapter, x)`; for a repay-all exactly the quoted `maxRepaySpend`) and holds it (`Q-144`, `Q-212`, `Q-223`, `Q-269`).
- Repay with collateral: the caller's account owes the debt reserve, its proxy holds a record with credited units, the market's price and the debt reserve's price are at liquidation freshness, and the flash source holds at least `x` of the debt asset (`Q-255`, `Q-358`).

## Execution Steps

In exact execution order. `Y` is the payer (`msg.sender`), `W` the borrower, `AD` the AaveAdapter, `m` the `marketId` argument, `VT = AD.accountOf(P).vaultToken` the market's vault token, `S = VT.spoke()` the CDP Spoke, `HD` the Spoke's home Hub, `P = proxyOf[W][m]`, `r = debtReserveId`, `HF_r` its funding Hub (equal to `HD` at launch) and `A` its asset. When the borrower repays its own debt, `Y = W`. For repay with collateral `W = msg.sender`, `LS` is LPVaultSwap, `FS` the chain's `IFlashSource`, `CO` Collateralization, `LV` the LPVault of the market's AMM protocol, `n` the market's token count, `reserveId` the vault-token reserve of `VT` on `S`.

### Repay with funds

| Step | Action | Contract (msg.sender) | Notes |
|---|---|---|---|
| `REP-001` | `Y` calls `AD.repay(W, m, r, maxRepaySpend, repayAll, deadline)` | AaveAdapter (`Y`) | The entry point acquires the protocol lock; `Lock.acquire` reverts with `LockHeld(holder)` if it is held. No call to the MarketRegistry (pause states, sequencer gate, circuit breakers, address freeze, approved debt reserves or any other view), the RiskModule, the ParameterStore or any oracle anywhere in this flow ([2.6] `REQ-ADAPTER-047`, `REQ-ADAPTER-086`). The MarketRegistry is upgradeable and trusted only to gate new activity, so a faulty one can never block a repay. Checked by TEST-243, PROP-066. (Source: Q-148, Q-223, Q-227, Q-241, Q-242, Q-260) |
| `REP-002` | Take the caller as the payer | `AD` | No caller check: any `msg.sender` is accepted and becomes the payer `Y` for the pull and the refund. (Source: Q-212) |
| `REP-003` | Check the deadline | `AD` | `block.timestamp ≤ deadline`, in seconds. (Source: Q-075) |
| `REP-012` | Resolve the account | `AD` | `P = proxyOf[W][m]` (`NoProxy(W, m)` if zero). The binding was fixed by CREATE2 at the first pledge and never changes; there is no proxy version to check. The reserve is not checked against the MarketRegistry: the Spoke lends only its own approved set, so a reserve it lists but `P` never borrowed has no debt and the call returns 0 at `REP-005`, and a reserve it does not list makes the Spoke's own view revert, which propagates ([2.6] `REQ-PROXY-027`). (Source: Q-223, Q-260, Q-349) |
| `REP-004` | Read the live debt | `AD` → `S.getUserTotalDebt(r, P)` (view) | `D` = drawn debt plus premium of that reserve, accrued to `block.timestamp`, rounded up as Aave does, in `A`'s base units. (Source: Q-119, Q-180) |
| `REP-005` | Size the pull (`SPEC-PROXY-003`, `SPEC-PROXY-007`) | `AD` | If `D == 0` the call releases the lock and returns `0` with no token movement and no event, for a partial repay and a repay-all alike. Partial with `D > 0`: `maxRepaySpend > 0`, `x = min(maxRepaySpend, D)`. Repay-all with `D > 0`: if `D > maxRepaySpend` it reverts with `RepayExceedsMax(D, maxRepaySpend)` before any transfer; otherwise `x = maxRepaySpend`. A repay-all pulls its whole cap because the debt keeps accruing between signing and inclusion: a cap and approval equal to the debt quoted at signing would always fall short at inclusion, while a cap quoted to the deadline and refunded in the same call succeeds at the first attempt and leaves no standing allowance ([2.6] `REQ-ADAPTER-085`). Checked by HYP-16, HYP-17, QNT-17, TEST-248. (Source: Q-153, Q-169, Q-180, Q-209, Q-212, Q-269) |
| `REP-006` | Move the funds to the proxy | `AD` → `A.transferFrom(Y, P, x)` | `SafeERC20`; `received` = `P`'s balance increase of `A` across the transfer, read by the Adapter. `received == 0` or `received > x` → `UnitsMismatch(x, received)`; a smaller amount, from a token that takes a transfer fee, is accepted and every later step uses `received`, so a fee switched on by an issuer reduces the repayment instead of blocking it. The funds never pass through the Adapter, and are never pulled from `W` unless `Y = W`. (Source: Q-124, Q-212, Q-223, Q-271) |
| `REP-007` | Approve the Spoke | `AD` → `P.execute(A, approve(S, received))` | Exact amount. The proxy is logic-free: it forwards the Adapter's call and nothing else ([2.5]). (Source: Q-035, Q-075, Q-124, Q-271, Q-349) |
| `REP-008` | Repay on the Spoke | `AD` → `P.execute(S, repay(r, received, P))` (`P` at `S`) | `P` repays as its own position owner (`onBehalfOf == P`). Aave checks the reserve is not paused; restores premium first, then drawn debt; pulls what it restores, at most `min(received, D)`, from `P` to `HF_r`; `HF_r.restore` checks the Spoke is active and not halted. When drawn shares reach 0 the reserve's borrowing flag clears. A Hub halt or deactivation of `S` or a pause of `r` stops this step; the Aave payload agreement keeps those for a faulty Spoke and uses freeze plus `drawCap = 0` for containment (`Q-351`, playbook P-16). (Source: Q-118, Q-140, Q-180, Q-269, Q-351) |
| `REP-009` | Measure, refund, reset | `AD` → `P.execute(A, approve(S, 0))`; `AD` → `P.execute(A, transfer(Y, received − spent))` when non-zero | `spent` = `P`'s balance decrease across the Spoke call (`spent ≤ received`); allowance back to 0; `received − spent` returned to `Y` in the same call, a zero refund skipped; `P`'s balance ends at its value before `REP-006` (`BalanceDeltaMismatch()` otherwise), so neither `P` nor `AD` keeps any of the asset. A repay-all whose payer approved exactly `maxRepaySpend` ends with that allowance at 0. Checked by HYP-52, TEST-248. (Source: Q-124, Q-212, Q-217, Q-269, Q-271) |
| `REP-010` | Repay-all completion check | `AD` → `S.getUserTotalDebt(r, P)` (view) | If `repayAll`, the reserve's remaining debt is 0 (`DebtRemaining(r, d)` otherwise, for example when a transfer fee left `received < D`). Other debt reserves of the account are untouched. Checked by HYP-17, MATH-AR-20. (Source: Q-180, Q-234, Q-271) |
| `REP-022` | No idle step after a full repay (`Q-396`) | None (no call) | A repay changes no budget part and makes no Collateralization call. When it leaves `P` with no debt on any reserve, the account's charge stays in `Regular` until the position is withdrawn; there is no `releaseIdle`, `admitIdleCharge` or `Idle` budget. Keeping the repay free of any budget write means no Collateralization state can make a repay fail. Example: `W` repays its whole 8,032.88 GHO on market A; its $50,000 charge stays in `Regular` until `W` withdraws NFT #7. (Source: Q-354, Q-396) |
| `REP-011` | Event and unlock | `AD` | Emits `Repaid(Y, W, m, r, spent, debtAfter, repayAll)`; releases the lock. (Source: Q-076, Q-148, Q-212) |

### No proxy code in the repay path

| Step | Action | Contract (msg.sender) | Notes |
|---|---|---|---|
| `REP-023` | Where repay can and cannot be blocked | AaveAdapter, PositionProxy, CDP Spoke | Aave's `Spoke.repay(reserveId, amount, onBehalfOf)` accepts only `onBehalfOf` itself or a position manager it approved; proxies approve no position manager ([2.1] `REQ-HUB-026`) and the drift check treats any approval as drift (`Q-352`), so a third party cannot repay on the Spoke for `P` directly. Every repay therefore runs `AD.repay` and the proxy's `execute`. The proxy holds no logic, no version and no upgrade path: it forwards the chain's AaveAdapter's calls, so it has nothing that can fall behind or break. All repay logic is in the Adapter, which upgrades through the chain's Timelock; a defect in it is fixed by one upgrade that every existing proxy uses at once, with no re-borrow or re-keyed record (`Q-349`). The parts that can block a repay are the Adapter implementation (fixed by that upgrade) and Aave itself (a reserve pause or a Hub halt, playbook P-16). (Source: Q-223, Q-349, Q-351, Q-352) |

### Repay with collateral

The call preserves: the backing gap of the market (vault-token burn equals the record debit); debt repaid before collateral leaves; flash loan and premium covered by the conversion or the call reverts; no protocol budget draw (the SettlementBudget does not exist, `Q-397`), Avana fee or bonus; and, while any debt remains, an Aave health factor after the call no lower than before it and no lower than `minHealthFactor` (`Q-255`, `Q-257`, `Q-356`).

| Step | Action | Contract (msg.sender) | Notes |
|---|---|---|---|
| `REP-013` | `W` calls `AD.repayWithCollateral(p)` | AaveAdapter (`W`) | Acquires the protocol lock (`LockHeld(holder)` if held); `block.timestamp ≤ p.deadline` (`DeadlineExpired`); `p.units > 0` (`ZeroAmount()`); `P = proxyOf[W][m]` (`NoProxy(W, m)`). Owned by [2.6] `REQ-ADAPTER-080`, [2.16]. (Source: Q-148, Q-255) |
| `REP-015` | Pause reason and sequencer gate | `AD` → `MR.pauseState(HD)`, `MR.pauseReason(HD)`, `ParameterStore.sequencer()` (views) | `Paused(MintPathSuspect)` → `ApplicationPaused()`, because the call burns vault tokens through the path the reason names as suspect. `Paused(General)`, `Frozen`, a frozen `W` and every circuit breaker let it pass: it cannot add debt, it lowers the debt before any collateral leaves, and `REP-021` requires `hfAfter ≥ hfBefore`, so it is the borrower's way to deleverage while keepers can still liquidate (`Q-356`). Sequencer `Down` → `SequencerDown()`: the swap legs would run on prices that have not updated. `Grace` lets it pass. Checked by TEST-229, TEST-239. (Source: Q-241, Q-242, Q-255, Q-356, Q-357) |
| `REP-014` | Market, debt reserve and debt | `AD` → its own binding `accountOf(P)`, `VT.spoke()`, `MR.isApprovedDebtReserve(S, r)`, `S.getUserTotalDebt(r, P)` (views) | `VT = AD.accountOf(P).vaultToken` is non-zero (`UnknownMarket(m)`) and `S = VT.spoke()`; `r` approved for `S` (`UnknownDebtReserve(S, r)`); `D = S.getUserTotalDebt(r, P) > 0` (`NothingToRepay(r)`); `p.minAmounts.length == n` (`LengthMismatch`). The record itself is checked by Collateralization at `REP-019`. (Source: Q-233, Q-255, Q-260) |
| `REP-016` | Snapshot and session | `AD` → `S.getUserAccountData(P)`, `CO.getTotalCredited(VT)`, `CO.getPending(VT)`, `VT.totalSupply()`, `S.getUserSuppliedShares(reserveId, P)` (views); `AD` → `LS.deleverage(req)` | `hfBefore` = Aave's health factor of `P`; `gapBefore = CO.getTotalCredited(VT) + CO.getPending(VT).units − VT.totalSupply()`; `sharesBefore` = `P`'s supplied shares in `reserveId`; the Adapter opens a transient deleverage session `(P, VT, positionKey, units, r)` and calls `LS.deleverage(req)`. (Source: Q-255, Q-257) |
| `REP-017` | Valuation and size | `LS` → LPOracle, DebtOracle, AaveOracle, flash source and Hub views | Liquidation-grade gates for market `m` and reserve `r` only ([2.11] `REQ-SWAP-008`, `REQ-SWAP-091`): `m` not Cached, Expired or in a route disagreement and every input within its feed's `feedHeartbeat + 1,800` s; `r`'s DebtOracle Live within the same rule (a fixed source always passes); Hub shares == assets for `VT`. `V` per `SPEC-LIQ-004` with `c = units`, in `A`'s base units at oracle prices: the composition of `units` at the oracle price vector, `Σ amountᵢ × priceᵢ`, divided by `A`'s price; `s = slippageAllowanceBps` of `m`; `U` per `SPEC-LIQ-005`; `Vnet = ⌊V × (10⁴ − s) / 10⁴⌋ − U`. `x = min(D, ⌊Vnet × 10⁴ / (10⁴ + maxFlashFeeBps)⌋)`, rounded down, so the conversion at the slippage allowance covers the loan and the largest premium accepted. `x ≥ minDebtRepaid` (`DeleverageTooSmall(x, minDebtRepaid)`). The size is fixed by oracle prices, which a pool trade cannot move; a sandwiched pool can only make the conversion fail its minimums. Owned by [2.11] `REQ-SWAP-106`, `SPEC-LIQ-020`. Checked by TEST-239. (Source: Q-247, Q-248, Q-250, Q-255, Q-357) |
| `REP-018` | Flash loan and repay | `LS` → `FS.flashLoan(A, x, HD, context)` → Aave V3 Pool `flashLoan(FS, [A], [x], [0], FS, data, 0)` → `FS.executeOperation` → `LS.onFlashLoan(A, x, φ, context)`; inside it `LS` → `AD.deleverageRepay(P, r, x)` | Before the loan `FS` checks the Pool's idle balance of `A` (`FlashLiquidityShort(available, x)` from `LS` against `FS.maxFlashLoan(A)`, `InsufficientFlashLiquidity(available)` from `FS`) and requires the premium `φ = FS.flashPremium(A, x)` to satisfy `φ × 10⁴ ≤ maxFlashFeeBps × x` (exact integer comparison, `FlashFeeTooHigh(premium, maxPremium)`); `maxFlashFeeBps` is 10 at launch and `φ = 0` once Avana holds the `FLASH_BORROWER` role on the Pool. `LS` reads `FS` from `MarketRegistry.flashSource()`. In the callback `FS` requires the Pool as caller, itself as initiator and one asset; `LS` requires `FS` as caller and its open deleverage context. `AD.deleverageRepay` runs only for LPVaultSwap inside the open session (`NoDeleverageSession()` otherwise); it moves `x` from `LS` to `P`, measures `received`, has `P` repay `received` exactly as `REP-007` to `REP-009` with `LS` as payer, so any unconsumed amount returns to `LS`. The debt falls before any collateral leaves, so the health factor never dips during the call. When the flash source is short or paused the call reverts and the borrower can repay with funds (playbook P-15). Owned by [2.6] `REQ-ADAPTER-081`. (Source: Q-255, Q-271, Q-358) |
| `REP-019` | Release and unwind the units | `LS` → `AD.deleverageRelease(P, (integrationId, positionKey), units, minAmounts)`; `AD` → `P.execute(S, withdraw(reserveId, units, P))`, `VT.burn(P, units)`, `CO.releaseForDeleverage(P, VT, positionKey, units, minAmounts)`; `CO` → `LV.unwind(positionKey, units, minAmounts, LS)`, and `LV.returnPosition(positionKey)` when nothing stays credited | Inside the session only. Aave withdraws `units` to `P` (its own health factor ≥ 1 check applies while debt remains); the Adapter burns them; Collateralization reconciles any unsettled seizure first (path D of [3.4 Withdraw][3.4]), requires `units` at most the record's credited units, debits the record, releases its exposure charge per `SPEC-CAP-004` slice first, caps its rescue units at the credited units left, and has the LPVault remove exactly `units` of liquidity, returning `amounts[0..n−1]` with each `amounts[i] ≥ minAmounts[i]` (`AmountBelowMinimum(i, amount, min)`), principal only, to `LS`. Before the removal the LPVault checks the pool is not inside a callback (the AMM protocol's lock). LPVaultSwap reads no pool spot price (`Q-350`): fair composition is the minimum of the units' oracle value over all pool prices ([2.10](../02-contracts/10-lp-oracle.md) `SPEC-ORC-007`), so a pool pushed off its price before the unwind returns tokens worth at least their oracle value, and each swap leg's oracle `minOutᵢ` bounds what they convert to. A record left with 0 credited units returns its position, with its separated fees, to the depositor of record. Owned by [2.3] `REQ-COLL-017`. (Source: Q-061, Q-201, Q-224, Q-253, Q-255, Q-350) |
| `REP-020` | Conversion, flash repayment, remainder | `LS` → swap routes `convert` for each token `i` with `tokens[i] ≠ A`; `A.approve(FS, x + φ)` via the source's pull | A token equal to `A` needs no swap and counts at face value. Each other token converts into `A` over its approved swap route with its own minimum per `SPEC-LIQ-018` at `slippageAllowanceBps` (`MinOutNotMet(out, minOut)`). `R` = the debt asset held after the legs; `R ≥ x + φ` (`DeleverageShortfall(recovered, owed)`); the loan and premium are repaid to `FS`, which the Pool pulls; `toWallet = R − x − φ` goes to `W` in `A`. No budget draw, keeper payment, Avana fee or bonus; the borrower bears the premium and the conversion cost. `LS` emits `Deleveraged`. (Source: Q-231, Q-250, Q-255, Q-256, Q-358) |
| `REP-021` | Close | `AD` → `S.getUserAccountData(P)`, `S.getUserSuppliedShares(reserveId, P)`, Collateralization and `VT` views | If `borrowCount > 0` after the call: Aave's `hfAfter ≥ max(hfBefore, minHealthFactor)` (`HealthFactorNotImproved(hfBefore, hfAfter)`, `SPEC-PROXY-009`); this is the check that lets the call run under `Paused(General)`, breakers and an address freeze. If the account is debt-free, its charge stays in `Regular` as in `REP-022`; there is no `releaseIdle` (`Q-396`). `P`'s supplied shares in `reserveId` fell by exactly `units`. `VT.totalSupply() ≤ totalCredited + pending.units` with the gap equal to `gapBefore` (`BackingMismatch`, [2.6] `REQ-ADAPTER-069`). Emits `RepaidWithCollateral(W, m, positionKey, units, r, debtRepaid, toWallet, hfBefore, hfAfter)`; closes the session; releases the lock. Checked by TEST-239, TEST-241, PROP-065, PROP-072. (Source: Q-255, Q-257, Q-354, Q-356) |

### Repay availability by state

| State | Repay with funds | Repay with collateral |
|---|---|---|
| Home Hub `None` or `Frozen` | Allowed (`Q-227`) | Allowed (`Q-255`) |
| Home Hub `Paused(General)` | Allowed (`Q-227`) | Allowed when it only reduces debt and `hfAfter ≥ hfBefore` (`Q-356`) |
| Home Hub `Paused(MintPathSuspect)` | Allowed (`Q-252`) | Refused (`ApplicationPaused`, `Q-356`) |
| Payer or borrower is a frozen address | Allowed (`Q-242`) | Allowed for a frozen calling wallet (`Q-356`) |
| A market or debt breaker tripped, including `CONFIG_DRIFT` and `POOL_DEPTH` | Allowed (`Q-241`) | Allowed (`Q-241`, `Q-356`) |
| Sequencer `Down` (Base) | Allowed, including a repay forced in through L1 | Refused (`SequencerDown`, `Q-357`) |
| Sequencer in `Grace` (Base) | Allowed | Allowed |
| MarketRegistry faulty (empty debt set, wrong views) | Allowed (`Q-260`) | Refused or misgated; plain repay stays available |
| Every price state (Live, Drifting, Cached, Expired, grace), USD band breach, stale feeds | Allowed | Allowed while the released market and the repaid reserve are at liquidation freshness and agree; refused when Cached or Expired (`Q-356`) |
| `Offboarding` market, liquidation halt, config drift | Allowed | Allowed; refused when the market's swap routes cannot convert the tokens above their minimums |
| Pool spot off the oracle reference | Allowed | Allowed: no spot check; each swap leg still meets its oracle minimum (`Q-350`) |
| Hub shares ≠ assets | Allowed | Refused |
| Aave vault-token reserve paused | Allowed | Refused by Aave |
| Aave vault-token reserve frozen, the repaid reserve frozen, `drawCap` exhausted | Allowed | Allowed |
| Flash source short or paused for the debt asset | Allowed | Refused (`FlashLiquidityShort`, or the Pool's error; playbook P-15, `Q-358`) |
| No debt in the reserve (including debt another payer cleared first) | Returns `0`, no token movement (`Q-209`, `Q-212`) | Refused (`NothingToRepay`) |
| Payer is not the borrower | Allowed (`Q-212`) | Not possible: the wallet acts on its own account |
| The repaid reserve paused on Aave | Refused by Aave (`ReservePaused`) | Refused by Aave |
| The Hub halts or deactivates the CDP Spoke | Refused by Aave (`SpokeHalted`); playbook P-16 (`Q-351`) | Refused by Aave |
| AaveAdapter implementation broken | Refused; fixed by an Adapter upgrade through the chain's Timelock, used by every proxy at once (`Q-223`, `Q-349`) | Refused |

## Contract Interactions

| Caller → callee.function() | Step | msg.sender at callee | Tokens moved |
|---|---|---|---|
| `Y` → `AD.repay(W, m, r, maxRepaySpend, repayAll, deadline)` | `REP-001` | `Y` | None |
| `AD` → `Lock.acquire()` / `Lock.release()` | `REP-001`, `REP-011`, `REP-013`, `REP-021` | `AD` | None |
| `AD` → `S.getUserTotalDebt(r, P)`, `S.getUserAccountData(P)` | `REP-004`, `REP-010`, `REP-014`, `REP-022` | `AD` | None |
| `AD` → `A.transferFrom(Y, P, x)` | `REP-006` | `AD` | `A` `Y` → `P`, `x` (`received` arrives) |
| `AD` → `P.execute(A, approve(S, received))`, `P.execute(A, approve(S, 0))` | `REP-007`, `REP-009` | `AD`; `P` at `A` | None |
| `AD` → `P.execute(S, repay(r, received, P))` → `A.transferFrom(P, HF_r, spent)`; `HF_r.restore` | `REP-008` | `AD`; `P` at `S`; Spoke at `A` and `HF_r` | `A` `P` → `HF_r`, `spent` |
| `AD` → `P.execute(A, transfer(Y, received − spent))` (only when non-zero) | `REP-009` | `AD`; `P` at `A` | `A` `P` → `Y`, `received − spent` |
| `W` → `AD.repayWithCollateral(p)` | `REP-013` | `W` | None |
| `AD` → `MR.pauseState(HD)`, `MR.pauseReason(HD)`, `ParameterStore.sequencer()`, `AD.accountOf(P).vaultToken`, `VT.spoke()`, `MR.isApprovedDebtReserve`, `CO.getTotalCredited`, `CO.getPending`, `VT.totalSupply`, `S.getUserSuppliedShares` | `REP-014` to `REP-016`, `REP-021` | `AD` | None |
| `AD` → `LS.deleverage(req)` | `REP-016` | `AD` | None |
| `LS` → `FS.flashLoan(A, x, HD, context)` → Aave V3 Pool `flashLoan` → `FS.executeOperation` → `LS.onFlashLoan(A, x, φ, context)` | `REP-018` | `LS`; `FS` at the Pool; Pool at `FS`; `FS` at `LS` | `A` Pool → `FS` → `LS`, `x` |
| `LS` → `AD.deleverageRepay(P, r, x)`; `AD` → `A.transferFrom(LS, P, x)`; `P.execute(S, repay(r, received, P))` | `REP-018` | `LS`; `AD`; `P` | `A` `LS` → `P` → `HF_r`, `spent`; refund `P` → `LS` |
| `LS` → `AD.deleverageRelease(P, (integrationId, positionKey), units, minAmounts)`; `AD` → `P.execute(S, withdraw(reserveId, units, P))`, `VT.burn(P, units)`, `CO.releaseForDeleverage`; `CO` → `LV.unwind(positionKey, units, minAmounts, LS)`, `LV.returnPosition(positionKey)` (all units) | `REP-019` | `LS`; `AD`; `CO` | `VT` `HD` → `P` → burned, `units`; `amounts[0..n−1]` pool → `LS`; position `LV` → depositor when closed |
| `LS` → swap routes `convert` per token `≠ A`; `A.transfer(FS, x + φ)` then the Pool pulls from `FS`; `A.transfer(W, toWallet)` | `REP-020` | `LS`; Pool at `FS` | Tokens `LS` → routes → `A` `LS`; `A` `LS` → `FS` → Pool, `x + φ`; `A` `LS` → `W`, `toWallet` |

## State Changes

| Contract | Step | Storage / balance | Before → After |
|---|---|---|---|
| Asset `A` | `REP-006`, `REP-008`, `REP-009` | `balanceOf(Y)`, `balanceOf(P)`, `balanceOf(HF_r)` | y, p, h → y − `x` + (`received` − `spent`), p, h + `spent` |
| Asset `A` | `REP-006`, `REP-007`, `REP-009` | `allowance(Y, AD)`, `allowance(P, S)` | a, 0 → a − `x`, 0 (0 for a repay-all approved at exactly `maxRepaySpend`) |
| CDP Spoke | `REP-008`, `REP-018` | `P`'s premium debt, drawn shares and borrowing flag in `r` | Reduced by `spent` (premium first); flag cleared at 0 drawn shares |
| Funding Hub `HF_r` | `REP-008`, `REP-018` | `S`'s drawn amount and premium for `A`; Hub liquidity | Reduced by the restored amounts; liquidity + `spent` |
| CDP Spoke, home Hub, `VT` | `REP-019` | `P`'s supplied shares in `reserveId`; Hub `VT` balance; `VT.totalSupply` | − `units` each |
| Collateralization | `REP-019` | Record credited units and rescue units; the account's booked charge and its budget (`Regular` or `Slice`; no `Idle` budget, `Q-396`); `totalCredited[VT]`; `accountCredited[P][VT]`; record deleted when credited reaches 0 | − `units`; − released charge (slice first, saturating); rescue units `min(rescue, credited)` |
| LPVault, AMM position | `REP-019` | Position liquidity; depositor of record when closed | − `units`; cleared and position to the depositor when credited reaches 0 |

## External Calls

Trust boundaries are defined in [1.3 Trust Boundaries][1.3] and [4.3 External Dependencies][4.3].

| External contract | Step | Function | Trust assumption |
|---|---|---|---|
| AaveAdapter (Avana, one per chain, upgradeable through the chain's Timelock, trusted for custody) | `REP-001`…`REP-023` | Entry points, callbacks | Reviewed implementation; repay with funds reads no pause state, sequencer gate, breaker, freeze, registry view or gate (`Q-223`, `Q-227`, `Q-260`) |
| PositionProxy (Avana, logic-free, immutable) | `REP-007`…`REP-009`, `REP-018`, `REP-019` | `execute` | Forwards only the Adapter's calls; no version or upgrade (`Q-349`) |
| Aave V4 CDP Spoke (standard Spoke) and funding Hub (Aave DAO) | `REP-004`, `REP-008`, `REP-010`, `REP-018`, `REP-019`, `REP-021` | `getUserTotalDebt`, `repay`, `withdraw`, `getUserAccountData` | Trusted accounting; only a reserve pause or a Hub halt or deactivation can block repay with funds (`Q-351`) |
| Debt asset (GHO, USDC, USDT, WETH) | `REP-006`…`REP-009`, `REP-018`, `REP-020` | `transferFrom`, `approve`, `transfer` | ERC-20 measured by balance delta; a transfer fee reduces the repayment (`Q-271`); an issuer blocklist on `Y` or `P` can block the transfer |
| Collateralization (Avana, immutable) | `REP-019` | `releaseForDeleverage` | Fixed code |
| MarketRegistry, RiskModule, oracles, ParameterStore | None for repay with funds | None | Not called: a faulty one cannot block repay with funds (`Q-229`, `Q-260`) |
| LPVaultSwap, swap routes (Avana, upgradeable; routes approved per market and token) | `REP-016` to `REP-020` | `deleverage`, `convert` | Oracle-derived minimums on every leg bound the conversion; a shortfall reverts the whole call (`Q-250`, `Q-255`) |
| `IFlashSource` (Avana, per chain, replaceable through the Timelock) and Aave V3 Pool | `REP-018`, `REP-020` | `flashLoan`, `executeOperation` | Liquidity and premium checked before the loan; caller, initiator and context checked in the callback; never the Hub of the Spoke being repaid (`Q-358`) |
| LPVault of the market's AMM protocol (Avana, immutable) | `REP-019` | `unwind`, `returnPosition` | Removes exactly `units` with per-token minimums, only for Collateralization under the lock |

## Events

In emission order. A repay with funds at zero debt emits nothing.

| Contract | Step | Event |
|---|---|---|
| Asset `A` | `REP-006` | `Transfer(Y, P, x)`; `Approval(Y, AD, a − x)` where the token emits it |
| Asset `A` | `REP-007` | `Approval(P, S, received)` |
| Asset `A`, Hub, Spoke | `REP-008` | Hub rate update events, `A` `Transfer(P, HF_r, spent)`, Hub `Restore(assetId, S, drawnShares, premiumDelta, drawnAmount, premiumAmount)`, Spoke `Repay(r, P, P, drawnShares, spent, premiumDelta)` in upstream order |
| Asset `A` | `REP-009` | `Approval(P, S, 0)`; `Transfer(P, Y, received − spent)` when non-zero |
| Collateralization | `REP-022`, `REP-021` | `DebtFree(P, VT, timestamp)` (account left debt-free only) |
| AaveAdapter | `REP-011` | `Repaid(Y, W, m, r, spent, debtAfter, repayAll)` |
| Aave V3 Pool, flash source, swap routes, Spoke, Hub, `VT`, AMM position manager, LPVault, Collateralization | `REP-018` to `REP-020` | Upstream flash, swap, repay and withdraw events; `VT` `Transfer(P, 0, units)`; LPVault `LiquidityUnwound(positionKey, units, amounts)`; Collateralization's record debit event; `PositionReturned` when the record closes; LPVaultSwap `Deleveraged(P, m, r, units, debtRepaid, recovered, flashPremium, toWallet)` |
| AaveAdapter | `REP-021` | `RepaidWithCollateral(W, m, positionKey, units, r, debtRepaid, toWallet, hfBefore, hfAfter)` |

## Failure Conditions

Every failure reverts the whole transaction. Upstream errors pass through unchanged and `packages/protocol` ships the upstream error ABIs (`Q-119`).

| ID | Step | Condition | Result |
|---|---|---|---|
| `REP-F-001` | `REP-001` | Lock already held | `LockHeld(holder)` from the Lock ([2.16]) (Source: Q-148) |
| `REP-F-002` | `REP-002` | `msg.sender` is not the borrower | No failure: repay has no caller check and the caller pays; a payer can never borrow or move collateral (Source: Q-212, Q-223) |
| `REP-F-003` | `REP-003` | `block.timestamp > deadline` | `DeadlineExpired(deadline)` (Source: Q-075) |
| `REP-F-004` | `REP-005` | `D == 0`, partial or repay-all | No failure: returns `0` with no token movement and no event (Source: Q-180, Q-209) |
| `REP-F-005` | `REP-005` | Partial repay with `D > 0` and `maxRepaySpend == 0` | `ZeroAmount()` (Source: Q-075) |
| `REP-F-006` | `REP-005` | Repay-all with `D > maxRepaySpend` | `RepayExceedsMax(D, maxRepaySpend)` before any transfer (Source: Q-180, Q-269) |
| `REP-F-007` | `REP-006` | Payer's allowance to the Adapter or balance below `x` (for a repay-all, below `maxRepaySpend`) | The token's error passes through (Source: Q-119, Q-223, Q-269) |
| `REP-F-008` | `REP-008` | Reserve paused, Spoke inactive or halted on the funding Hub | `ReservePaused`, `SpokeNotActive` or `SpokeHalted` passes through; playbook P-16 (Source: Q-118, Q-140, Q-351) |
| `REP-F-009` | `REP-006`, `REP-009` | Funds received by `P` are 0 or exceed `x`, or `P`'s balance at the end differs from its value before the pull | `UnitsMismatch(x, received)` or `BalanceDeltaMismatch()` from the Adapter; fewer funds than `x` are accepted and repaid (Source: Q-124, Q-271) |
| `REP-F-010` | `REP-010` | Repay-all leaves non-zero debt in the reserve | `DebtRemaining(debtReserveId, debt)` (Source: Q-180) |
| `REP-F-011` | `REP-012`, `REP-004` | `W` has no proxy for market `m`, or `S` does not list `r` | `NoProxy(W, m)`, or the Spoke's error from `getUserTotalDebt` passes through; no MarketRegistry check (Source: Q-223, Q-260) |
| `REP-F-012` | `REP-013` | Lock held, deadline passed, `units == 0`, or no proxy | `LockHeld(holder)`, `DeadlineExpired(deadline)`, `ZeroAmount()` or `NoProxy(W, m)` (Source: Q-075, Q-148, Q-255) |
| `REP-F-013` | `REP-014` | `r` not approved for `S`, no debt in `r`, or `minAmounts` not of length `n` | `UnknownDebtReserve(S, r)`, `NothingToRepay(r)` or `LengthMismatch` (Source: Q-233, Q-255) |
| `REP-F-014` | `REP-015` | Home Hub `Paused(MintPathSuspect)`, or the sequencer gate `Down` | `ApplicationPaused()` or `SequencerDown()`; `Paused(General)`, `Frozen`, a frozen wallet and tripped breakers do not refuse it (Source: Q-252, Q-255, Q-356, Q-357) |
| `REP-F-015` | `REP-014`, `REP-019` | `W` has no proxy bound to `m` in the AaveAdapter, or the record not open, not `P`'s or not `VT`'s | `UnknownMarket(m)`, or Collateralization's `RecordNotFound()`, `NotRecordProxy()` or `InvalidVaultToken()` ([2.3] `REQ-COLL-017`) (Source: Q-255, Q-260) |
| `REP-F-016` | `REP-017` | Market `m` or reserve `r` not at liquidation freshness (Cached, Expired, older than `feedHeartbeat + 1,800` s), in a disagreement, or Hub shares ≠ assets | LPVaultSwap's price or share error ([2.11]) (Source: Q-247, Q-255, Q-356) |
| `REP-F-017` | `REP-017` | `x < minDebtRepaid` | `DeleverageTooSmall(x, minDebtRepaid)` (Source: Q-255) |
| `REP-F-018` | `REP-018` | Flash source short of `A` or paused, the premium with `φ × 10⁴ > maxFlashFeeBps × x`, a callback outside the open session or from another caller, or Aave rejects the repay | `FlashLiquidityShort(available, x)`, `InsufficientFlashLiquidity(available)`, `FlashFeeTooHigh(premium, maxPremium)`, the Pool's error, `NoDeleverageSession()` or Aave's error (Source: Q-255, Q-358) |
| `REP-F-019` | `REP-019` | Aave rejects the withdrawal, `units` above the record's credited units after reconciliation, an unwound amount below its minimum, or the pool inside a callback | Aave's error (`ReservePaused`, `HealthFactorBelowThreshold`), Collateralization's `UnitsMismatch()` ([2.3] `REQ-COLL-017`, `REQ-VAULT-118`), or the LPVault's `AmountBelowMinimum(i, amount, min)` or `PoolLocked`; the whole call reverts, so the repayment and the flash loan are undone (Source: Q-201, Q-255, Q-350) |
| `REP-F-020` | `REP-020` | A leg converts below its minimum, or the conversion does not cover the flash loan and premium | `MinOutNotMet(out, minOut)` or `DeleverageShortfall(recovered, owed)` (Source: Q-250, Q-255) |
| `REP-F-021` | `REP-021` | Debt remains and `hfAfter < max(hfBefore, minHealthFactor)` | `HealthFactorNotImproved(hfBefore, hfAfter)` (Source: Q-255, Q-356) |
| `REP-F-022` | `REP-021` | Supplied shares did not fall by exactly `units`, or the market's backing gap changed | `UnitsMismatch` or `BackingMismatch(totalSupply, totalCredited, pendingUnits)` (Source: Q-224, Q-257) |
| `REP-F-023` | `REP-023` | A third party calls `S.repay(r, amount, P)` directly | The Spoke's `Unauthorized()`: `P` has no position manager; the payer uses `AD.repay` (Source: Q-349, Q-352) |

## Worked Example

Accounts from the [3.2 Borrow][3.2] two-market example on the Ethereum Uniswap v3 Stable CDP Spoke: `P_A` (market A) owes 8,000 GHO and `P_B` (market B) owes 5,000 USDC, both borrowed 30 days ago. At 5.00% (GHO) and 6.00% (USDC) the live debts read in `REP-004` are `D_GHO = 8,032,876,712,328,767,123,288` wei (8,032.876712… GHO) on `P_A` and `D_USDC = 5,024,657,535` base units (5,024.657535 USDC) on `P_B`, each rounded up. `hf_A = 15,600 / 8,032.88 = 1.9420`; `hf_B = 9,000 / (5,024.66 × 0.9999) = 1.7913`.

| Call | Sizing (`SPEC-PROXY-003`, `SPEC-PROXY-007`) | Result |
|---|---|---|
| `repay(W, m_B, r_USDC, 2,000,000,000, false, t+600)` by `W` | `x = min(2,000,000,000, 5,024,657,535)` | `spent = 2,000,000,000`, refund 0; `debtAfter = 3,024,657,535` (at most a few base units above `D − x`); `Repaid(W, W, m_B, r_USDC, 2,000,000,000, 3,024,657,535, false)`. A remainder of any size would be accepted too, because Avana has no minimum debt (`Q-381`) |
| `repay(W, m_A, r_GHO, 8,040e18, true, t+600)` by `W` | `D_GHO ≤ 8,040e18`, `x = 8,040e18` | Pulls 8,040 GHO; Aave takes `spent = 8,032,876,712,328,767,123,288`; refund `7,123,287,671,232,876,712` to `W` in the same call; `P_A` is debt-free and its $50,000 charge stays in `Regular` until `W` withdraws (`REP-022`, `Q-396`) |
| `repay(W, m_B, r_USDC, 5,020,000,000, true, t+600)` before the partial repay | `D_USDC > maxRepaySpend` | Reverts with `RepayExceedsMax(5,024,657,535, 5,020,000,000)` before any transfer |
| A rescue service `R` calls `repay(W, m_A, r_GHO, 3,000e18, false, t+600)` while the Ethereum Stable LP Hub is `Paused(MintPathSuspect)`, a GHO debt breaker is tripped and `W` is a frozen address | `Y = R`, `x = 3,000e18`; no pause, breaker or freeze read | 3,000 GHO pulled from `R`, not from `W`; `Repaid(R, W, m_A, r_GHO, 3,000e18, 5,032.876…e18, false)`; `W`'s collateral did not move |
| `W`'s repay-all of `r_GHO` on `P_A` with cap 8,040e18 lands after `R`'s repay in the same block | `D' = 5,032.876712328767123288` GHO ≤ cap, `x = 8,040e18` | Pulls 8,040 GHO; Aave takes `D'`; `W` gets back `3,007.123287671232876712` GHO; `W` spends less than it signed for, never more ([2.6] `REQ-PROXY-083`) |
| `repay(W, m_B, r_USDC, 1,000,000,000, false, t+600)` after a liquidation cleared the USDC debt | `D = 0` | Returns `0`; no transfer, no approval, no event |
| A keeper calls `S.repay(r_GHO, 1,000e18, P_A)` on the Spoke directly | `REP-023` | Reverts with `Unauthorized()`; the keeper calls `AD.repay` instead |

**Repay-all quoted to the deadline** (`SPEC-PROXY-007`). For the USDC reserve with `D = 5,024,657,535` at 6.00% and a deadline 600 s ahead, the app reads `Lens.quoteRepayAll(W, m_B, r_USDC, t+600) = ⌈5,024,657,535 × (1 + 0.06 × 600 / 31,536,000) × 1.001⌉ = 5,029,687,935` and sets both the approval and `maxRepaySpend` to it. On Ethereum the transaction is included 24 s (2 blocks) later, when `D = 5,024,657,765`: the Adapter pulls 5,029,687,935, Aave takes 5,024,657,765, the proxy refunds 5,030,170 to `W`. On Base the same quote is included 4 s (2 blocks) later, when `D = 5,024,657,573`, and the refund is 5,030,362. Either way the reserve's debt is 0 and `W`'s allowance to the Adapter is 0. Because the size is read in the call, a payer that lands first can only lower what the borrower's own repay keeps.

**Repay with collateral** (`SPEC-LIQ-020`, `SPEC-PROXY-009`). Wallet `V` owes 10,000 USDC (`D = 10,000,000,000`) on its market-A account with CF-weighted collateral of $12,000 (Aave `hf = 1.2000`); USDC is priced at $1.0000 for the example. Record #31 is a Uniswap v3 USDC/USDT exact-range position, $2.00 per whole vault token, `CF = 3,120`; `U = 0.01` USDC (`SPEC-LIQ-005`); `slippageAllowanceBps = 100`. Avana does not yet hold the `FLASH_BORROWER` role on the Ethereum Aave V3 Pool, so the premium is the Pool's 5 bps and `maxFlashFeeBps = 5`. `V` calls `repayWithCollateral` with `units = 1,500,000,000`, `minAmounts = [1,490,000,000, 1,490,000,000]`, `r = r_USDC`, `minDebtRepaid = 2,950,000,000`, `minHealthFactor = 1.30e18`.

| Step | Computation | Result |
|---|---|---|
| At `REP-017` | Composition of 1,500 whole tokens at the oracle price vector: 1,500 USDC + 1,500 USDT, so `V = 3,000` USDC; `⌊3,000 × 9,900 / 10⁴⌋ − 0.01 = 2,969.99`; `x = min(10,000, ⌊2,969.99 × 10⁴ / 10,005⌋)` | `x = 2,968.505747` USDC ≥ `minDebtRepaid` |
| At `REP-018` | Pool idle USDC far above `x`; `φ = ⌈2,968.505747 × 5 / 10⁴⌉ = 1.484253` USDC; `deleverageRepay` repays `x` | USDC debt `7,031.494253` |
| At `REP-019` | Withdraw and burn 1,500,000,000 units; unwind returns `[1,500.000000 USDC, 1,500.000000 USDT]`, each above its minimum | CF-weighted collateral `12,000 − 3,000 × 0.312 = $11,064` |
| At `REP-020` | USDC leg needs no swap; USDT leg converts to 1,499.40 USDC, above its minimum of 1,485; `R = 2,999.40` | `R ≥ x + φ = 2,969.990000`; `toWallet = 2,999.40 − 2,968.505747 − 1.484253 = 29.41` USDC to `V` |
| At `REP-021` | `hfAfter = 11,064 / 7,031.494253 = 1.5735 ≥ max(1.20, 1.30)`; gap unchanged | `RepaidWithCollateral(V, S, VT_A, #31, 1,500,000,000, r_USDC, 2,968,505,747, 29,410,000, 1.20e18, 1.5735e18)` |

With the `FLASH_BORROWER` role the premium is 0, `maxFlashFeeBps` is tightened from 10 to 0 and `x = 2,969.99` USDC. The same call while the Ethereum Stable LP Hub is `Frozen` or `Paused(General)`, while the market's pool-share breaker is tripped, or from a frozen `V` succeeds unchanged, because it only lowers the debt and raises the health factor (`Q-356`); under `Paused(MintPathSuspect)` it reverts with `ApplicationPaused()` and `V` can still repay with funds. With `minDebtRepaid = 3,000,000,000` it reverts with `DeleverageTooSmall(2,968,505,747, 3,000,000,000)`. If a sandwich pushes the pool's spot off the oracle reference before the unwind, the unwound tokens are worth more at oracle prices, not less, and the call continues unless an amount falls below the borrower's own `minAmounts` (`AmountBelowMinimum`); if it pushes a swap leg below its minimum, the call reverts with `MinOutNotMet` and nothing moves.

**Base (Aerodrome Slipstream Stable CDP Spoke).** The same repay with collateral on Base flash-borrows USDC from the Base Aave V3 Pool, whose idle USDC bounds `x` (`FlashLiquidityShort` above it, playbook P-15). While the Base sequencer feed reports down it reverts with `SequencerDown()`, and a plain repay forced in through L1 still succeeds; during the 3,600 s grace after a restart both run.

**Walkthrough.**

- `REP-024` Aerodrome Slipstream on Base (Carol, USDC repay-all). Setup: Carol's account of [3.2 Borrow][3.2] `BOR-022`, 30 days later. At 6.00% the live debt is `D = ⌈5,000,000,000 × (1 + 0.06 × 30 / 365)⌉ = 5,024,657,535` (5,024.657535 USDC) and the health factor is `6,240 / (5,024.657535 × 0.9999) = 1.2420`.
  1. Carol's app shows the debt from `Lens.getAccount(Carol, 3)` ([2.17](../02-contracts/17-lens.md)). She taps "Repay all"; the app calls `Lens.quoteRepayAll(Carol, 3, r_USDC, now + 600)`, which returns `⌈5,024,657,535 × (1 + 0.06 × 600 / 31,536,000) × 1.001⌉ = 5,029,687,935`.
  2. Carol approves the AaveAdapter for exactly 5,029,687,935 USDC base units.
  3. Carol calls `AaveAdapter.repay(Carol, 3, r_USDC, 5,029,687,935, true, now + 600)` ([2.6](../02-contracts/06-aave-adapter.md)); it is included 4 s (2 Base blocks) later. The Adapter takes the Lock and checks the deadline; it reads no pause state, breaker, freeze, oracle or sequencer gate.
  4. The Adapter reads the live debt with `Spoke.getUserTotalDebt(r_USDC, P)`: `D = 5,024,657,573`, which is at most the cap.
  5. The Adapter pulls 5,029,687,935 from Carol to her proxy ([2.5](../02-contracts/05-position-proxy-and-proxy-manager.md)) and measures the receipt.
  6. The proxy approves the Spoke and calls `Spoke.repay(r_USDC, 5,029,687,935, P)`; Aave takes `spent = 5,024,657,573` and restores it to the Base Stable LP Hub's USDC line.
  7. The proxy's allowance returns to 0 and it sends the `5,029,687,935 − 5,024,657,573 = 5,030,362` left over back to Carol in the same call. `Spoke.getUserTotalDebt` reads 0.
  8. Event `Repaid(Carol, Carol, 3, r_USDC, 5,024,657,573, 0, true)`; the Lock is released. The app shows no debt; Carol's NFT can now leave by a debt-free withdrawal, and its charge stays in `Regular` until it does (`Q-396`).
  9. Variants: a partial repay of 2,000 USDC leaves `5,024,657,535 − 2,000,000,000 = 3,024,657,535`, accepted at any size because Avana has no minimum debt (`Q-381`). While the Base sequencer is down, Carol can force the same repay in from L1 and it succeeds, while `repayWithCollateral` reverts `SequencerDown()`.

  Checked by: MATH-AR-39, MATH-AR-40, SYM-158; arithmetic re-computed.

## Postconditions

- `REP-POST-001` — `P`'s debt in `debtReserveId` fell by `spent`, `spent ≤ min(received, D)`, `received ≤ x`, with `x = min(maxRepaySpend, D)` for a partial repay and `x = maxRepaySpend` for a repay-all; the payer `Y` paid `x` and got back `received − spent` in the same call, a net cost of `spent` plus any transfer fee the token took; no funds were pulled from any other address. Checked by HYP-17, HYP-47, TEST-248. (Source: Q-075, Q-180, Q-212, Q-269, Q-271)
- `REP-POST-002` — After a repay-all, `P`'s drawn shares and premium in `debtReserveId` are 0 and that reserve is no longer marked as borrowed; other debt reserves of `P` and every other proxy of the wallet are unchanged. Checked by HYP-17, MATH-AR-20. (Source: Q-180, Q-234)
- `REP-POST-003` — Neither `P` nor the Adapter holds any of the asset from this call, and `P` has no allowance to the Spoke. Checked by HYP-52. (Source: Q-124, Q-223)
- `REP-POST-004` — The repay with funds succeeded whenever the payer had funds and approval and Aave did not block it, whatever the pause state of any Hub and its reason, the sequencer gate, the circuit breakers, the address freeze of payer or borrower, the MarketRegistry's views, price states or RiskModule said; at zero debt it returned `0`. Checked by HYP-16, QNT-14, QNT-17, TEST-243, PROP-066. (Source: Q-118, Q-153, Q-209, Q-212, Q-227, Q-241, Q-242, Q-260, Q-357)
- `REP-POST-005` — A repay with funds changed no vault token, position, record or booked charge; it made no Collateralization write. (Source: Q-224, Q-255, Q-354)
- `REP-POST-006` — A repay by one payer never made a later repay by another payer spend more than the debt left at its own execution. (Source: Q-180, Q-209, Q-212)
- `REP-POST-007` — After a repay-all whose payer approved exactly `maxRepaySpend`, the payer's allowance to the Adapter is 0 and the payer holds the refund `received − spent`. Checked by TEST-248. (Source: Q-269)
- `REP-POST-008` — After a repay with collateral, the debt in `r` fell by `debtRepaid ≥ minDebtRepaid`, no debt was added, and while any debt remains Aave's health factor is at least `max(hfBefore, minHealthFactor)`, in every pause state in which the call ran. Checked by TEST-239, PROP-072. (Source: Q-255, Q-356)
- `REP-POST-009` — After a repay with collateral, `P`'s supplied shares, `VT.totalSupply()` and the record's credited units each fell by exactly `units`, each unwound token amount was at least its minimum, the market's backing gap is unchanged, and the position returned to its depositor of record exactly when no credited units remain. Checked by TEST-239, TEST-241, PROP-065. (Source: Q-255, Q-257)
- `REP-POST-010` — A repay with collateral drew no protocol budget (none exists, `Q-397`), paid no Avana fee, keeper payment or bonus, repaid the flash loan and premium in full, sent `toWallet` in the debt asset to `W` only, and left no debt asset or pool token with the Adapter, `P`, the flash source or LPVaultSwap. Checked by TEST-239, PROP-072. (Source: Q-231, Q-255, Q-358, Q-397)
- `REP-POST-011` — No repay path runs code held in the PositionProxy beyond forwarding the Adapter's calls, and no repay path re-keys a proxy, record, seizure list, rescue counter or nonce. (Source: Q-349)
- `REP-POST-012` — When a repay leaves the account debt-free, its charge stays in `Regular` (or its slice part) until the position is withdrawn; no call moves it to an `Idle` budget, which does not exist (`Q-396`). (Source: Q-354, Q-396)

## Related

- Invariants this flow must preserve ([4.1 Global Invariants][4.1]): repay with funds is available in every pause state, under every breaker, freeze and sequencer state and with any MarketRegistry, unless Aave blocks it; no Avana contract keeps a debt asset or an allowance between transactions; only the Adapter makes a proxy act; any payer may repay through the Adapter; vault-token supply never exceeds credited plus pending backing and each call keeps the gap; repay with collateral never lowers the health factor of an account that keeps debt.
- Attack scenarios ([4.2][4.2]): a faulty RiskModule, pause or MarketRegistry blocking exits, dust donations blocking repay, a repay-all overtaken by interest (handled by the deadline quote and the refund, `Q-269`), a third-party repay front-running the borrower's repay (it only lowers what the borrower pays, `Q-212`), an issuer blocklist on a proxy, a USDT fee switch, a sandwich or spot push around a repay with collateral, a flash source drained before the call, an Aave halt used as containment.
- A partial repay may leave any remainder, because Avana has no minimum debt; Aave's dust rule then makes a partial liquidation of a small debt close it in full, and Avana's own keepers liquidate it at Avana's gas cost (`Q-153`, `Q-381`).
- Decisions: `Q-075`, `Q-118`, `Q-119`, `Q-124`, `Q-140`, `Q-144`, `Q-153`, `Q-169`, `Q-180`, `Q-209`, `Q-212`, `Q-215`, `Q-217`, `Q-223`, `Q-227`, `Q-231`, `Q-233`, `Q-234`, `Q-241`, `Q-242`, `Q-247`, `Q-248`, `Q-250`, `Q-252`, `Q-255`, `Q-257`, `Q-260`, `Q-268`, `Q-269`, `Q-271`, `Q-349`, `Q-350`, `Q-351`, `Q-352`, `Q-354`, `Q-356`, `Q-357`, `Q-358`, `Q-381` in [4.4][4.4].
- Playbooks ([3.6 Emergency Operations][3.6]): P-15 flash liquidity short or paused, P-16 Aave halt of a CDP Spoke, P-17 sequencer outage.
- Related flows: [3.2 Borrow][3.2], [3.4 Withdraw][3.4] (repay-all and withdraw in one call), [3.5 Liquidation][3.5].

[1.3]: ../01-architecture/03-trust-boundaries.md
[1.5]: ../01-architecture/05-parameters.md
[2.1]: ../02-contracts/01-avana-hub-and-spokes.md
[2.2]: ../02-contracts/02-lp-vault.md
[2.3]: ../02-contracts/03-collateralization.md
[2.5]: ../02-contracts/05-position-proxy-and-proxy-manager.md
[2.6]: ../02-contracts/06-aave-adapter.md
[2.7]: ../02-contracts/07-risk-module.md
[2.11]: ../02-contracts/11-lpvaultswap.md
[2.16]: ../02-contracts/16-lock.md
[2.17]: ../02-contracts/17-lens.md
[3.1]: 01-deposit.md
[3.2]: 02-borrow.md
[3.4]: 04-withdraw.md
[3.5]: 05-liquidation.md
[3.6]: 06-emergency-operations.md
[4.1]: ../04-security/01-global-invariants.md
[4.2]: ../04-security/02-attack-scenarios.md
[4.3]: ../04-security/03-external-dependencies.md
[4.4]: ../04-security/04-design-decisions.md
