# Independent contract reviews

Every contract gets an independent adversarial review as soon as it compiles. The reviewer receives only the contract's spec page and its code, not the author's reasoning, writes a PoC test for each finding it can demonstrate, and reports findings by the severity scale of [audit/README.md](../README.md#findings). Each finding is fixed in code, fixed in the spec, or accepted with its reason, and the decision is recorded with the contract's gate. One folder per contract: the findings table and the PoC tests (`poc/`).

| Contract | Folder | Date | Critical | High | Medium | Low | Info / spec | Status |
|---|---|---|---|---|---|---|---|---|
| Lock | [Lock](Lock/) | 2026-11-10 | 0 | 0 | 0 | points applied | points applied | fixed |
| AvanaTimelock | [AvanaTimelock](AvanaTimelock/) | 2026-11-10 | 0 | 0 | 2 | 5 | — | fixed |
| LPPriceMath | [LPPriceMath](LPPriceMath/) | 2026-11-10 | 0 | 0 | 2 | 5 | 1 Informational | fixed |
| SettlementMath | [SettlementMath](SettlementMath/) | 2026-11-10 | 0 | 0 | 0 | 0 | S1–S5, A1–A4 | fixed (S1 accepted) |
| VaultToken | [VaultToken](VaultToken/) | 2026-11-10 | 0 | 0 | 0 | 0 | 4 spec, 2 hardening | decided |
| ParameterStore | [ParameterStore](ParameterStore/) | 2026-11-10 | 0 | 0 | 1 | 3 | 6 | decided |
| VaultTokenFactory | [VaultTokenFactory](VaultTokenFactory/) | 2026-11-10 | 0 | 0 | 0 | 2 | 1 | decided |
| PayoutEscrow | [PayoutEscrow](PayoutEscrow/) | 2026-11-10 | 0 | 0 | 0 | 3 | 1 | decided |
| PositionProxy and ProxyManager | [PositionProxy-and-ProxyManager](PositionProxy-and-ProxyManager/) | 2026-11-10 | 0 | 0 | 0 | 1 | 3 | decided |
| CoverageSpoke | [CoverageSpoke](CoverageSpoke/) | 2026-11-10 | 0 | 0 | 1 | 1 | trust and spec points | decided |
| AaveV3FlashSource | [AaveV3FlashSource](AaveV3FlashSource/) | 2026-11-10 | 0 | 1 | 1 | 0 | 1 spec | fixed (spec text decided) |
| MarketRegistry | [MarketRegistry](MarketRegistry/) | 2026-11-10 | 0 | 0 | 2 (one Medium/Low) | 6 | 4 | decided |
| Collateralization | [Collateralization](Collateralization/) | 2026-11-10 | 0 | 0 | 0 | 1 | 4 | decided |
| Swap routes | [swap-routes](swap-routes/) | 2026-11-10 | 0 | 0 | 1 | 3 | 1 | decided (one Low accepted) |
| Uniswap v3 LPVault (UniswapV3Integration) | [cl-lpvaults](cl-lpvaults/) | 2026-11-11 | 0 | 0 | 0 | 1 (CL-01) | CL-04; spec S1, S6, S8, S9 | open |
| Slipstream LPVault (SlipstreamIntegration) | [cl-lpvaults](cl-lpvaults/) | 2026-11-11 | 0 | 0 | 0 | 2 (CL-01, CL-03) | CL-02, CL-04, CL-05; spec S1–S8 | open |
| DebtOracle | [DebtOracle](DebtOracle/) | 2026-11-11 | 0 | 0 | 0 | 0 | DO-01, DO-02, DO-03; spec S1–S7 | open |
| Flash liquidation helper (FlashLiquidator, OperatorFlashLiquidator) | [FlashLiquidator](FlashLiquidator/) | 2026-11-11 | 0 | 0 | 2 (FL-01, FL-02) | 1 (FL-03) | spec S1–S5 | open |

"Decided" means the decision is recorded; this table does not yet record the code, spec and test changes as re-checked by the contract gate (tests, Halmos, fast tier, traceability).

## Statuses

| Status | Meaning |
|---|---|
| open | The findings are recorded; no decision has been taken yet |
| fixed | The change is in the code or the spec, with a test or check that fails without it |
| decided | The decision is recorded; the change is not yet recorded as re-checked |
| accepted | The behavior stays, with its bound and reason written into the spec |
