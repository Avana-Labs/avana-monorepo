Function links point to the interface that declares each function.

# Lock lifecycle

The Lock is the chain's single transient mutex with two members, the AaveAdapter and LPVaultSwap: every Avana state change runs inside one holder's call, and every inner contract (Collateralization, LPVault, VaultToken burn paths, swap routes, the payout escrow) accepts calls only while the right member holds it.

## Walkthrough

Setup (Base market 3, Carol's pledge of 3.1 `DEP-029`, then Bob's liquidation of 3.5 `LIQ-069` on Ethereum).

1. **AaveAdapter → [`acquire`](ILock.sol#L64)** as the first step of Carol's `pledge`. [`holder`](ILock.sol#L76) becomes the AaveAdapter; [`isLocked`](ILock.sol#L84) is true for the rest of the transaction. Errors: [`NotMember`](ILock.sol#L46) for any other caller, [`LockHeld`](ILock.sol#L51) if already held, [`DelegateCallNotAllowed`](ILock.sol#L41).
2. **Inside the call**, Collateralization checks `holder() == ADAPTER` ([`LockNotHeld`](../../custody/collateralization/ICollateralizationErrors.sol#L25) otherwise). The LPVault requires Collateralization as caller and a non-zero Lock holder (`ClLPVaultBase._onlyCustodyCaller`: `NotCollateralization`, `LockNotHeld`) before `receivePosition` and its other custody calls; only its `collectFees` requires the holder to be the AaveAdapter. Lens and LPVault views revert `Locked` while the Lock is held, so no view reads a half-written state.
3. **AaveAdapter → [`release`](ILock.sol#L70)** as the last step; the slot is transient, so it is also clear at the end of the transaction. Error: [`NotHolder`](ILock.sol#L56).
4. **LPVaultSwap → [`acquire`](ILock.sol#L64)** at the start of `liquidate` (after the deadline check). Collateralization's `beginSeizure`, `settleSeizure` and `settlePending`, the AaveAdapter's `burnSeized`, the swap routes' `swap` and the escrow's `deposit` all require `holder() == LP_VAULT_SWAP`. A second liquidation entered from a route or a token callback reverts [`LockHeld`](ILock.sol#L51).
5. **Repay with collateral.** The AaveAdapter holds the Lock while LPVaultSwap's `deleverage` runs; swap routes accept the AaveAdapter as holder for that path.
6. **LPVaultSwap → [`release`](ILock.sol#L70)** after the payouts. PayoutEscrow `claim` reverts `LockHeld` while `isLocked()` is true, so a claim never runs inside an Avana call.

## What the UI reads and calls

- Lens: every view reverts `Locked` while the Lock is held; a UI reads after the transaction.
- Events to index: none.
- User calls: none.

## Spec

- [2.16 Lock](../../../../spec/02-contracts/16-lock.md): `REQ-LOCK-001`–`REQ-LOCK-030`, `INV-054`.
