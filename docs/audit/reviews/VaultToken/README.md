# VaultToken review

| Item | Value |
|---|---|
| Date | 2026-11-10 |
| Contract | `src/vault-token/vault-token/VaultToken.sol` |
| Spec | [2.4 Vault Tokens](../../../spec/02-contracts/04-vault-tokens.md) |
| Method | Independent adversarial review: the reviewer receives only the spec page and the code, writes a PoC test for every finding it can demonstrate, and reports findings by severity |
| Result | Code correct; specification findings and hardening points |

## Findings

| # | Severity | Finding | Decision | Status |
|---|---|---|---|---|
| 1 | Spec | A non-zero Aave `liquidationFee` on a vault-token reserve pays the fee as Hub shares with no token transfer; the receiver can never withdraw them, and the share-drop check would revert every fee-paying liquidation | `liquidationFee = 0` on every vault-token reserve, with no alternative; the "or paid to Avana's fee receiver" option removed; the DAO's share comes from LPVaultSwap's settlement proceeds. Updates `REQ-VTOKEN-006`/`025`, the `IVaultToken` NatSpec, `INV-093`, `REQ-HUB-003`/`029`/`092`, `ATTACK-014`, `TEST-185`/`268`, plus a fork test of the PoC | decided |
| 2 | Spec | A third party can complete a dust liquidation that seizes zero collateral | Stated in `INV-013`, `INV-041` and `ATTACK-028` | decided |
| 3 | Spec | The seizure bound of `REQ-VTOKEN-013`, `INV-009` and `ATTACK-022` was misstated | Corrected | decided |
| 4 | Hardening | Zero-amount `transferFrom` by anyone succeeds | Zero-amount transfers refused | decided |
| 5 | Hardening | A binding equal to the token's own address is accepted | Refused | decided |
| 6 | Spec | Proxy keying: Aave V4 computes one health factor per account over all its collaterals | One proxy per (wallet, CDP Spoke, market) kept; stale (wallet, Spoke) text in `REQ-VTOKEN-039`, `REQ-ROLE-095`, `TEST-187`, `REQ-PROXY-044` and the Hypothesis model corrected; binding map written one way in `Q-307`, `INV-064`, `REQ-PROXY-053` | decided |

## Also decided

Stale `ATTACK-021`/`022`/`023`/`027`, `INV-003`, `REQ-VTOKEN-010`/`025` and `PROP-008` text; Certora `loop_iter` of at least 7 for the constructor; the Halmos `PROP-009` reserved set; the listed test gaps.

## PoC tests

- `VaultTokenPoC.t.sol` with `PoCBase.sol` (real local Aave V4): `test_poc_thirdPartyDustLiquidationSucceeds`, `test_poc_thirdPartyFeeOnlyLiquidationSucceeds`, `test_poc_zeroTransferFromByAnyone`, `test_poc_hostileAdapterEoaLiquidator`

The PoC files are copied from the review workspace into [`poc/`](poc/). Each one demonstrates its finding against the code as reviewed, with imports at their review-time paths; for each fixed finding, a regression test in `contracts/test/` asserts the fixed behavior.
