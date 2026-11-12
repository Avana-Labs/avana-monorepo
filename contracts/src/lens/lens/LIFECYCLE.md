Function links point to the interface that declares each function.

# Lens lifecycle

The Lens is the read-only view contract for the app, keepers and monitoring: it assembles account, market, price, risk and liquidation state from every Avana contract and returns previews sized to stay valid until a transaction's deadline; no contract relies on it.

## Walkthrough

Carol's app on Base (market 3, from 3.1 `DEP-029`, 3.2 `BOR-022`, 3.3 `REP-024`), then a keeper on Ethereum (3.5 `LIQ-069`).

1. **Before the pledge: [`getPriceState`](ILensLiquidation.sol#L22)`(3)`** (Live; USDC/USD 72,000 s old, fresh until 88,200 s), [`getCapHeadroom`](ILensMarket.sol#L53)`(3, Carol)` ($4,000,000 `Regular` room, `minPledgeUsd` $10), [`getApplicationState`](ILensLiquidation.sol#L44) (None), [`predictProxy`](ILensAccount.sol#L20)`(Carol, 3)`.
2. **After the pledge: [`getAccount`](ILensAccount.sol#L32)`(Carol, 3)`**: collateral $20,000, CF-weighted $6,240, no debt; [`getRecords`](ILensAccount.sol#L47) lists record 1 with 10,000,000,000 units.
3. **Borrow screen: [`previewBorrowRecommended`](ILensPreview.sol#L42)`(Carol, 3, r_USDC, now + 600)`** returns the recommended 5,673.29 USDC (`6,240 / 1.10 / 0.9999`) and the maximum 6,209.56 USDC (`6,240 / 1.0050011 / 0.9999`, from [`previewBorrowMax`](ILensPreview.sol#L21)); [`getDebtPriceState`](ILensLiquidation.sol#L34) shows the USDC round 30,000 s old. The optional hard floor is off, so the maximum is sized to HF 1.00.
4. **Repay screen: [`quoteRepayAll`](ILensPreview.sol#L57)`(Carol, 3, r_USDC, now + 600)`** = `⌈5,024,657,535 × (1 + 0.06 × 600 / 31,536,000) × 1.001⌉` = 5,029,687,935; the app sets the approval and `maxRepaySpend` to it.
5. **Top-up screen: [`previewRecredit`](ILensPreview.sol#L73)`(m, key)`** returns `added = 2,500,000,000`, `usdCharge = $5,000`, `rescueOnly = false`.
6. **Deleverage screen: [`previewRepayWithCollateral`](ILensPreview.sol#L91)`(V, m_A, key31, 1,500,000,000, r_USDC)`** returns 2,968.505747 USDC repaid, 29.41 USDC to V and HF 1.5735; `(0, 0, hf)` when the call would revert.
7. **Keeper: [`previewLiquidation`](ILensLiquidation.sol#L84)`(Q, 2, now + 120)`** returns the gates, `debtToCover = 1,950e6`, 975 expected seized vault tokens, the floor 2,026.02, `expectedPayout` 2,028 USDC at the oracle value (the 1,950 USDC funding back plus 78 USDC, `expectedNetPayout`) and `expectedCallerLoss = 0`, with `LiquidationParams` ready to send; a keeper using the flash liquidation helper reads the helper's premium quote itself. Errors: [`UnknownProxy`](ILensErrors.sol#L28), [`UnknownDebtReserve`](ILensErrors.sol#L23).
8. **Payout escrow: [`getEscrowClaimable`](ILensAccount.sol#L63)`(feeRecipient, [USDC])`** returns 320 USDC after 40 escrowed fees of 8 USDC.
9. **Monitoring: [`getBreakerStatus`](ILensRisk.sol#L21), [`getDebtBreakerStatus`](ILensRisk.sol#L31), [`isFrozenAddress`](ILensRisk.sol#L40), [`getPauseReason`](ILensLiquidation.sol#L54), [`checkBacking`](ILensMarket.sol#L20), [`checkRecordBacking`](ILensMarket.sol#L33), [`getPendingSettlement`](ILensMarket.sol#L43), [`getTailCoverage`](ILensRisk.sol#L50), [`uncoveredDeficit`](ILensRisk.sol#L59), [`getHubAssetExposure`](ILensRisk.sol#L69).** Every view reverts [`Locked`](ILensErrors.sol#L12) while the Lock is held and [`LimitTooHigh`](ILensErrors.sol#L17) above [`LENS_MAX_PAGE`](ILens.sol#L38).

## What the UI reads and calls

- Lens: every function above; it is the UI's main read surface.
- Events to index: none (view-only contract).
- User calls: none; every result is advisory and the target contract re-checks it.

## Spec

- [2.17 Lens](../../../../spec/02-contracts/17-lens.md): `REQ-LENS-016`, `REQ-LENS-017`, `REQ-LENS-027`–`REQ-LENS-044`, `SPEC-LIQ-020`, `SPEC-CF-005`.
- Flows: [3.1](../../../../spec/03-operations/01-deposit.md) `DEP-029`, [3.2](../../../../spec/03-operations/02-borrow.md) `BOR-022`, [3.3](../../../../spec/03-operations/03-repay.md) `REP-024`, [3.5](../../../../spec/03-operations/05-liquidation.md) `LIQ-068`.
