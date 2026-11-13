# DAO deficit offset lifecycle

The DAO deficit offset is the second loss layer of one `(Hub, debt asset)`: a Coverage Spoke funded by the Aave DAO treasury that eliminates a recorded deficit only once the Avana Umbrella in front of it has a funded balance of zero, or the Aave DAO has deactivated that Umbrella on the Hub so it cannot pay. Aave V4's `Hub.eliminateDeficit` burns the calling Spoke's own added shares, so each layer is its own Spoke and its own Hub position, and nothing writes a deficit down across suppliers.

```mermaid
sequenceDiagram
  autonumber
  actor DAO as Aave DAO
  actor G as COVERAGE_ROLE holder
  participant CS as Avana Umbrella (CoverageSpoke)
  participant DO as DeficitOffsetSpoke
  participant H as Hub
  DAO->>DO: deploy(hub, GHO, ghoAssetId, accessManager, 1,209,600, CS)
  DAO->>DO: setAllowedBorrowSpoke(uniswapV3Stable, true), setFirstLossReserveMinimum(150,000e18)
  DAO->>DO: fund(150,000e18) from the treasury
  DO->>H: add(ghoAssetId, 150,000e18)
  Note over CS,H: a 300,000 GHO deficit is recorded; the Avana Umbrella holds 100,000 GHO
  G->>DO: coverDeficit(uniswapV3Stable, max)
  DO->>CS: fundedBalance() = 100,000e18
  Note right of DO: reverts FirstLossLayerNotExhausted
  G->>CS: coverDeficit(uniswapV3Stable, max)
  CS->>H: eliminateDeficit(ghoAssetId, 100,000e18, uniswapV3Stable)
  G->>DO: coverDeficit(uniswapV3Stable, max)
  DO->>CS: fundedBalance() = 0
  DO->>H: eliminateDeficit(ghoAssetId, 150,000e18, uniswapV3Stable)
  Note over H: 50,000 GHO stays recorded: withdrawals are paid first-come until a layer is refilled
```

## Walkthrough

Ethereum GHO pair on the Stable LP Hub, share price 1 (the numbers of `test_TEST_298_avanaLayerThenDaoOffsetThenResidual` and `test_TEST_299_lossOrderThenFirstComeResidual`): lenders 2,000,000 GHO, Avana Umbrella 100,000 GHO, DAO deficit offset 150,000 GHO.

1. **The Aave DAO deploys [`DeficitOffsetSpoke`](DeficitOffsetSpoke.sol#L34)`(hub, GHO, ghoAssetId, aaveAccessManager, 1,209,600, avanaUmbrella)`.** It runs every Coverage Spoke constructor check, then fixes [`FIRST_LOSS_LAYER`](DeficitOffsetSpoke.sol#L52) ([interface](IDeficitOffsetSpoke.sol#L31)). Errors: [`ZeroAddress`](../coverage-spoke/ICoverageSpokeErrors.sol#L13) for a zero layer, [`FirstLossLayerMismatch`](IDeficitOffsetSpoke.sol#L26) unless the layer's `HUB()`, `ASSET()` and `ASSET_ID()` equal its own.
2. **The DAO's payload registers it** on GHO with `drawCap = 0` and `addCap = MAX_ALLOWED_SPOKE_CAP`, grants it `HUB_DEFICIT_ELIMINATOR_ROLE`, maps [`coverDeficit`](../coverage-spoke/CoverageSpoke.sol#L136) to `COVERAGE_ROLE` and the admin functions to `RESERVE_ADMIN_ROLE`, then calls [`setAllowedBorrowSpoke`](../coverage-spoke/CoverageSpoke.sol#L160)`(uniswapV3Stable, true)` and [`setFirstLossReserveMinimum`](../coverage-spoke/CoverageSpoke.sol#L175)`(150,000e18)`, the `daoDeficitOffset` of the funding ARFC.
3. **The DAO treasury → [`fund`](../coverage-spoke/CoverageSpoke.sol#L116)`(150,000e18)`.** The GHO goes straight to the Hub and the shares are the offset's own Hub position; the Avana Umbrella's shares do not move. Event: [`ReserveFunded`](../coverage-spoke/ICoverageSpoke.sol#L31).
4. **A 300,000 GHO account is liquidated to zero collateral**; the CDP Spoke reports a 300,000 GHO deficit.
5. **`COVERAGE_ROLE` → offset [`coverDeficit`](../coverage-spoke/CoverageSpoke.sol#L136)`(uniswapV3Stable, max)` first**: [`_beforeCover`](DeficitOffsetSpoke.sol#L61) reads the Avana Umbrella's Hub `active` flag (true) and its `fundedBalance()` = 100,000 GHO and reverts [`FirstLossLayerNotExhausted`](IDeficitOffsetSpoke.sol#L21)`(avanaUmbrella, 100,000e18)`; nothing changes.
6. **`COVERAGE_ROLE` → Avana Umbrella `coverDeficit(uniswapV3Stable, max)`**, then in the same batch **→ offset `coverDeficit(uniswapV3Stable, max)`.** The Avana Umbrella covers 100,000 GHO and keeps no share; the offset then covers `min(200,000, 150,000) = 150,000` GHO with its own shares. Events from the offset: [`DeficitCovered`](../coverage-spoke/ICoverageSpoke.sol#L42)`(uniswapV3Stable, caller, 150,000e18, 150,000e18, 200,000e18 × RAY, 50,000e18 × RAY, 0)` and [`ReserveBelowMinimum`](../coverage-spoke/ICoverageSpoke.sol#L56)`(0, 150,000e18)`. A second offset call reverts [`NothingToCover`](../coverage-spoke/ICoverageSpokeErrors.sol#L43) once the deficit is 0.
7. **50,000 GHO stays recorded.** The lenders' shares still read 2,000,000 GHO; once every borrower repays, liquidity is 1,950,000 GHO, the first 1,950,000 GHO withdrawn is paid in full and the last 50,000 GHO of claims waits until Avana Labs or the DAO refills a layer and the coverage caller covers it.
8. **If the Aave DAO deactivates the Avana Umbrella** (it can no longer call `eliminateDeficit`), the offset pays a new deficit at once although the Umbrella still holds its funds: with a 130,000 GHO deficit and the Umbrella deactivated at 100,000 GHO, the offset covers 130,000 GHO and the Umbrella's shares do not move (`test_TEST_298_inactiveFirstLayerLetsOffsetPay`). Reactivated, the Umbrella is first again.
9. **The DAO withdraws from its offset** only through the offset's own [`requestWithdrawal`](../coverage-spoke/CoverageSpoke.sol#L186) and, 14 days later, [`executeWithdrawal`](../coverage-spoke/CoverageSpoke.sol#L214), which reverts [`DeficitOutstanding`](../coverage-spoke/ICoverageSpokeErrors.sol#L70) while an allowlisted Spoke has a recorded deficit.

## UI view

The Lend page shows, per (Hub, asset), the Avana Umbrella's and the DAO deficit offset's funded balances, any deficit left after both, and the backed value per share beside the price Aave pays; while a residual is outstanding it builds no supply and keeps withdrawals open.
