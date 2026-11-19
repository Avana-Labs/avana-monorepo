# Avana Umbrella (First-Loss Reserve) lifecycle

The First-Loss Reserve holds the First-Loss Reserve of one `(Hub, debt asset)` as Hub added shares. Avana Labs funds it, the Aave DAO controls it through its AccessManager, and its shares leave only to eliminate a recorded deficit of an allowlisted CDP Spoke on its own asset, or through a DAO withdrawal after 14 days.

```mermaid
sequenceDiagram
  autonumber
  actor L as Avana Labs
  actor G as COVERAGE_ROLE holder
  actor DAO as Aave DAO
  participant SW as LPVaultSwap
  participant CS as AvanaFirstLossReserve
  participant T as GHO
  participant H as Hub
  L->>CS: fund(400,000e18)
  CS->>T: transferFrom(Avana Labs, Hub, 400,000e18)
  CS->>H: add(ghoAssetId, 400,000e18)
  Note over CS,H: a liquidation leaves a 5,200 GHO deficit on the CDP Spoke
  G->>CS: coverDeficit(uniswapV3Stable, 5,200e18)
  CS->>H: getSpokeDeficitRay(ghoAssetId, uniswapV3Stable)
  CS->>H: eliminateDeficit(ghoAssetId, 5,200e18, uniswapV3Stable)
  Note right of CS: ReserveBelowMinimum while<br/>fundedBalance is below the minimum
  SW->>CS: fund(83.8e18) in settlePending
  DAO->>CS: requestWithdrawal(400,000e18, Avana Labs)
  Note over DAO,CS: 14 days, cancelWithdrawal(1) stops it
  DAO->>CS: executeWithdrawal(1)
  Note right of CS: DeficitOutstanding while an allowlisted<br/>Spoke still has a GHO deficit
  CS->>H: remove(ghoAssetId, min(400,000e18, fundedBalance), Avana Labs)
```

## Walkthrough

Ethereum GHO instance on the Stable LP Hub (illustrative 400,000 GHO minimum; the funding ARFC sets the real one).

1. **Avana deploys [`AvanaFirstLossReserve`](AvanaFirstLossReserve.sol#L56)`(hub, GHO, ghoAssetId, aaveAccessManager, 1,209,600)`** after the Hub lists GHO. The constructor fixes [`HUB`](AvanaFirstLossReserve.sol#L211), [`ASSET`](AvanaFirstLossReserve.sol#L206), [`ASSET_ID`](AvanaFirstLossReserve.sol#L216) and [`RESERVE_WITHDRAWAL_DELAY`](AvanaFirstLossReserve.sol#L221). Errors: [`ZeroAddress`](IAvanaFirstLossReserve.sol#L101), [`InvalidHubAsset`](IAvanaFirstLossReserve.sol#L104) (the Hub does not list GHO with its 18 decimals under that ID), [`InvalidWithdrawalDelay`](IAvanaFirstLossReserve.sol#L107).
2. **The Aave DAO's payload** registers it on GHO with `drawCap = 0` and `addCap = MAX_ALLOWED_SPOKE_CAP` (so yield can never fill a cap and stop `fund`), grants it `HUB_DEFICIT_ELIMINATOR_ROLE`, maps `coverDeficit` to `COVERAGE_ROLE` (granted to Avana's Emergency Guardian and the Aave Protocol Guardian, either able to cover within 72 hours) and the DAO functions to `RESERVE_ADMIN_ROLE`, then calls [`setAllowedBorrowSpoke`](AvanaFirstLossReserve.sol#L114)`(uniswapV3Stable, true)` and [`setFirstLossReserveMinimum`](AvanaFirstLossReserve.sol#L128)`(400,000e18)`. Events: [`BorrowSpokeAllowlistUpdated`](IAvanaFirstLossReserve.sol#L66), [`FirstLossReserveMinimumUpdated`](IAvanaFirstLossReserve.sol#L68). Error: [`BorrowSpokeNotListed`](IAvanaFirstLossReserve.sol#L121) for a Spoke the Hub does not list on GHO.
3. **Avana Labs → [`fund`](AvanaFirstLossReserve.sol#L76)`(400,000e18)`** after approving it. The 400,000 GHO move straight to the Hub, `Hub.add` credits the shares to the First-Loss Reserve, and the Hub's balance rise must equal the amount. Event: [`ReserveFunded`](IAvanaFirstLossReserve.sol#L11). Errors: [`ZeroAmount`](IAvanaFirstLossReserve.sol#L110), [`TransferAmountMismatch`](IAvanaFirstLossReserve.sol#L113); the Hub's `SpokeHalted`, `SpokeNotActive` and, for an amount below one share's value, `InvalidShares`. `enableDebtReserve` can now name the instance and the GHO `drawCap` can rise.
4. **A liquidation leaves an account with no collateral**; the CDP Spoke reports a 5,200 GHO deficit to the Hub.
5. **`COVERAGE_ROLE` → [`coverDeficit`](AvanaFirstLossReserve.sol#L93)`(uniswapV3Stable, 5,200e18)`.** Amount `= min(5,200, ceil(deficitRay / RAY), fundedBalance()) = 5,200 GHO`; `Hub.eliminateDeficit` burns the matching shares, rounded up, and clears the deficit. Event: [`DeficitCovered`](IAvanaFirstLossReserve.sol#L14), then [`ReserveBelowMinimum`](IAvanaFirstLossReserve.sol#L25)`(394,800e18, 400,000e18)`. Errors: [`SpokeNotAllowlisted`](IAvanaFirstLossReserve.sol#L115), [`NothingToCover`](IAvanaFirstLossReserve.sol#L118), the AccessManager's `AccessManagedUnauthorized`. It works while either Spoke is halted.
6. **Monitoring pages on the alert** ([`isBelowMinimum`](AvanaFirstLossReserve.sol#L189) is true); GHO borrows continue unless a guardian trips the debt breaker. Avana Labs calls [`fund`](AvanaFirstLossReserve.sol#L76)`(5,200e18)` and the alert clears with no reset call.
7. **Pending settlement.** LPVaultSwap's [`settlePending`](../../legacy/lp-vault-swap/ILPVaultSwap.sol#L48) recovers 83.8 GHO and calls [`fund`](AvanaFirstLossReserve.sol#L76)`(83.8e18)` like any funder; `ReserveFunded` names LPVaultSwap. An amount below one share's value would revert `InvalidShares`, so `settlePending` carries such an amount to the next settlement instead.
8. **Draw caps cut to 0.** With no GHO draw cap left to cover, the DAO calls [`requestWithdrawal`](AvanaFirstLossReserve.sol#L138)`(400,000e18, avanaLabs)` at `1,780,000,000`; it is executable from `1,781,209,600`. Event: [`WithdrawalRequested`](IAvanaFirstLossReserve.sol#L27). Errors: [`ZeroAmount`](IAvanaFirstLossReserve.sol#L110), [`InvalidRecipient`](IAvanaFirstLossReserve.sol#L124). [`cancelWithdrawal`](AvanaFirstLossReserve.sol#L153) stops a Pending request ([`WithdrawalCancelled`](IAvanaFirstLossReserve.sol#L29)).
9. **After 14 days, the DAO → [`executeWithdrawal`](AvanaFirstLossReserve.sol#L164)`(1)`.** It withdraws `min(400,000e18, fundedBalance())` from the Hub straight to Avana Labs. Event: [`WithdrawalExecuted`](IAvanaFirstLossReserve.sol#L31) and, below the minimum, [`ReserveBelowMinimum`](IAvanaFirstLossReserve.sol#L25). Errors: [`WithdrawalNotPending`](IAvanaFirstLossReserve.sol#L126), [`WithdrawalNotReady`](IAvanaFirstLossReserve.sol#L130), [`DeficitOutstanding`](IAvanaFirstLossReserve.sol#L134) while an allowlisted Spoke still has a recorded GHO deficit (coverage comes first); the Hub's `InsufficientLiquidity`, `SpokeHalted` and `InvalidAmount`. Every revert leaves the request Pending. The totals are signed: with a year of yield the reserve can cover more than was ever funded.

## What the UI reads and calls

- Lens: [`getTailCoverage`](../../lens/lens/ILensRisk.sol#L30)`(asset)`, [`uncoveredDeficit`](../../lens/lens/ILensRisk.sol#L37)`(hub, asset)`.
- Views: [`fundedBalance`](AvanaFirstLossReserve.sol#L184), [`isBelowMinimum`](AvanaFirstLossReserve.sol#L189), [`firstLossReserveMinimum`](IAvanaFirstLossReserve.sol#L64), [`fundedShares`](AvanaFirstLossReserve.sol#L194), [`getWithdrawal`](AvanaFirstLossReserve.sol#L199), [`allowedBorrowSpoke`](IAvanaFirstLossReserve.sol#L141).
- Events to index: `ReserveFunded`, `DeficitCovered`, `ReserveBelowMinimum`, `WithdrawalRequested`, `WithdrawalCancelled`, `WithdrawalExecuted`, `BorrowSpokeAllowlistUpdated`, `FirstLossReserveMinimumUpdated`.
- User calls: none; [`fund`](AvanaFirstLossReserve.sol#L76) is open to anyone but has no user flow.

## Spec

- [2.14 First-Loss Reserve](../../../../docs/spec/02-contracts/14-first-loss-reserve.md): `REQ-FLR-001`–`REQ-FLR-045`, `SPEC-FLR-001`–`SPEC-FLR-003`.
- Flow: [3.9 Deficit Coverage](../../../../docs/spec/03-operations/09-deficit-coverage.md) `DEF-009`, `DEF-011`, `DEF-015`, `DEF-016`, `DEF-017`.
