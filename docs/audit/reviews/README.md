# Independent contract reviews

Independent adversarial reviews. Reviews of contracts removed in the core refactor are in git history. The reviewer receives only the contract's spec page and its code, not the author's reasoning, writes a PoC test for each finding it can demonstrate, and reports findings by the severity scale of [docs/audit/README.md](../README.md#findings). Each finding is fixed in code, fixed in the spec, or accepted with its reason, and the decision is recorded with the contract's gate. One folder per contract: the findings table and the PoC tests (`poc/`).

| Contract | Folder | Date | Critical | High | Medium | Low | Info / spec | Status |
|---|---|---|---|---|---|---|---|---|
| LPPriceMath | [LPPriceMath](LPPriceMath/) | 2026-11-10 | 0 | 0 | 2 | 5 | 1 Informational | fixed |
| VaultToken | [VaultToken](VaultToken/) | 2026-11-10 | 0 | 0 | 0 | 0 | 4 spec, 2 hardening | decided |
| Uniswap v3 LPVault (UniswapV3Integration) | [cl-lpvaults](cl-lpvaults/) | 2026-11-11 | 0 | 0 | 0 | 1 (CL-01) | CL-04; spec S1, S6, S8, S9 | fixed (re-checked on main 2026-11-14) |
| Slipstream LPVault (SlipstreamIntegration) | [cl-lpvaults](cl-lpvaults/) | 2026-11-11 | 0 | 0 | 0 | 2 (CL-01, CL-03) | CL-02, CL-04, CL-05; spec S1–S8 | fixed (re-checked on main 2026-11-14) |
| Uniswap v4 LPVault and LPOracle module (UniswapV4Integration, UniswapV4State, LPOracleV4) | [uniswap-v4](uniswap-v4/) | 2026-11-15 | 0 | 0 | 2 (V4-01, V4-02) | 2 (V4-03, V4-04) | V4-05, V4-06; spec S1–S10 | fixed or decided, S8 open |
| Flash liquidation helper (FlashLiquidator, OperatorFlashLiquidator) | [FlashLiquidator](FlashLiquidator/) | 2026-11-11 | 0 | 0 | 2 (FL-01, FL-02) | 1 (FL-03) | spec S1–S5 | fixed (re-checked on main 2026-11-14) |
| Whole protocol, fresh adversarial audit (main `a024490`); PoCs in commit `b082463` | [fresh-audit-2026-11-15](fresh-audit-2026-11-15/REPORT.md) | 2026-11-15 | 0 | 0 | 1 (M-01) | 5 (L-01–L-04, I-01) | I-02 | decided (M-01 in #71; the rest in #80) |

"Decided" means the decision is recorded; this table does not yet record the code, spec and test changes as re-checked by the contract gate (tests, Halmos, fast tier, traceability).

## Statuses

| Status | Meaning |
|---|---|
| open | The findings are recorded; no decision has been taken yet |
| fixed | The change is in the code or the spec, with a test or check that fails without it |
| decided | The decision is recorded; the change is not yet recorded as re-checked |
| accepted | The behavior stays, with its bound and reason written into the spec |
