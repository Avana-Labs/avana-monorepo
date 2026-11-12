// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {PauseState} from "../../types/PauseState.sol";
import {PriceView} from "../../types/PriceView.sol";
import {DebtPriceView} from "./types/DebtPriceView.sol";
import {LiquidationPreview} from "./types/LiquidationPreview.sol";

/// @title ILensLiquidation
/// @notice Price, application-state and liquidation views of the Lens: a market's price state, a debt reserve's price
/// state, the application pause state, and the liquidation preview with ready-to-send parameters.
interface ILensLiquidation {
    /// @notice Returns a market's price state report.
    /// @dev `price` is the served price (`latestAnswer()`), `acceptedPrice` the last accepted one; served is at most
    /// accepted whenever the state is not Live (lower routes during a disagreement, 1 while Expired).
    /// @param vaultToken The market.
    /// @return priceView State, liquidation state, reasons, served and accepted price, inputs, deviations, disagreement
    /// and grace fields.
    /// @custom:spec REQ-LENS-015, Q-247
    function getPriceState(
        address vaultToken
    ) external view returns (PriceView memory priceView);

    /// @notice Returns a debt reserve's Aave price source, price and freshness for borrowing and liquidation.
    /// @dev The call reverts with `UnknownDebtReserve(spoke, debtReserveId)` unless the MarketRegistry approves the reserve for
    /// `spoke`. A reserve on a DebtOracle reports its state, served and accepted price; served is at least accepted
    /// whenever the state is not Live. A fixed-price source (such as GHO) reports `fixedPrice`, age 0 and both flags true.
    /// @param spoke The CDP Spoke.
    /// @param debtReserveId The debt reserve.
    /// @return priceView Source, price (USD, 8 decimals), source timestamp, age and freshness flags.
    /// @custom:spec REQ-LENS-030, REQ-LENS-032, Q-238, Q-247, Q-248
    function getDebtPriceState(
        address spoke,
        uint256 debtReserveId
    ) external view returns (DebtPriceView memory priceView);

    /// @notice Returns a Hub's pause state held by the MarketRegistry.
    /// @dev Liquidation, pending settlement, repay, fee collection and debt-free withdrawal are open in every state.
    /// @param hub The Hub.
    /// @return state `None`, `Frozen` or `Paused`.
    /// @custom:spec REQ-LENS-031, Q-227
    function getApplicationState(
        address hub
    ) external view returns (PauseState state);

    /// @notice Returns a Hub's pause reason.
    /// @dev `Paused(General)` admits rescue top-ups only; `Paused(MintPathSuspect)` refuses every pledge, top-up and
    /// re-credit.
    /// @return reason `PauseReason` ordinal: 0 None, 1 General, 2 MintPathSuspect.
    /// @param hub The Hub.
    /// @custom:spec REQ-LENS-031, Q-252
    function getPauseReason(
        address hub
    ) external view returns (uint8 reason);

    /// @notice Returns every liquidation gate, Aave's sizing and ready-to-send `LiquidationParams` for one account,
    /// collateral market and debt reserve, with the expected seizure, recovery floor, gross and net payout and the loss
    /// the caller may bear, all in the debt asset.
    /// @dev The proxy's market is the AaveAdapter's binding `accountOf(proxy)`. The call reverts with
    /// `UnknownProxy(proxy)` unless the Adapter created the proxy and the market's vault token reports
    /// `isValidProxy(proxy)` and with `UnknownDebtReserve(spoke, debtReserveId)` unless the reserve is enabled for the
    /// proxy's Spoke. Gates read fresh
    /// prices only for the seized market and the repaid reserve; other reserves count at their served prices.
    /// `expectedDebtRepaid` follows the pinned Aave V4 liquidation formulas (target health factor, dynamic bonus, caps, dust
    /// rule). `params.debtToCover` is `ceil(total * (1e4 + LENS_DUST_MARGIN_BPS) / 1e4)`, with `total` the whole debt,
    /// when `expectedDebtRepaid` is the whole debt, when the sizing seizes all
    /// of the account's supplied shares in the market, or when the remainder would be within `LENS_DUST_MARGIN_BPS` of
    /// Aave's dust threshold; `expectedDebtRepaid` otherwise.
    /// `params`: `routeMode = PrimaryThenBackup` if every primary swap route is usable else `BackupOnly`,
    /// empty `minAmounts`, `deadline` as passed, `minPayout = 0`, `maxShortfall = 0`; all amounts are 0 when the health
    /// factor is at least 1e18. `expectedUnitsSeized` is Aave's `_calculateCollateralToLiquidate` on the sized drawn
    /// shares and premium, capped by the supplied shares, less the liquidation fee. The caller funds `debtToCover`
    /// itself; the preview reads no flash source and quotes no loan (a helper's caller reads the helper's quotes).
    /// `expectedPayout` is `keeperOut` for that funding with every route at the oracle value, `expectedNetPayout` the
    /// reward beyond the returned funding and `expectedCallerLoss` the amount the payout can fall below the funding.
    /// `pauseState` is informational.
    /// Advisory only: LPVaultSwap recomputes and enforces every check.
    /// @param proxy The account's proxy; its market is the AaveAdapter's binding `accountOf(proxy)`.
    /// @param debtReserveId The debt reserve to repay.
    /// @param deadline The deadline copied into `params`.
    /// @return preview Gates, sizing, parameters and expected amounts.
    /// @custom:spec REQ-LENS-016, REQ-LENS-017, REQ-LENS-028, REQ-LENS-029, REQ-LENS-032, REQ-LENS-033, Q-232, Q-235, Q-247, Q-251, Q-268, Q-404
    function previewLiquidation(
        address proxy,
        uint256 debtReserveId,
        uint256 deadline
    ) external view returns (LiquidationPreview memory preview);
}
