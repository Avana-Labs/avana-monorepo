// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {WindDownState} from "./types/WindDownState.sol";

/// @title IMarketRegistryWindDown
/// @notice The end of a market's life (wind-down and close) and its settlement debt reserve.
/// @dev After `offboardNoticeSeconds` from `offboardedAt`, `stepWindDown` applies the next pre-approved Aave dynamic
/// configuration of the market's reserve, lowering its liquidation threshold linearly over `windDownRampSeconds`
/// (launch 30 days) to `windDownFinalLtBps` (launch 5,000 bps), at most once per `windDownStepSeconds` (launch 1 day).
/// Accounts still below health factor 1 at the end are liquidated through the normal flow. Once no account of the
/// market has debt, `closeMarket` releases its LPOracle, swap routes and keeper duty; every
/// debt-free position stays withdrawable forever because a debt-free withdrawal reads no price (AMMN-FLOW-22).
/// @custom:spec REQ-CONFIG-080, REQ-MREG-033, Q-338, Q-355, Q-358
interface IMarketRegistryWindDown {
    /// @notice A wind-down step lowered the market reserve's liquidation threshold.
    /// @custom:spec REQ-CONFIG-080
    event WindDownStepped(uint256 indexed marketId, uint16 liquidationThresholdBps);

    /// @notice The market reached `Closed`.
    /// @custom:spec REQ-CONFIG-080
    event MarketClosed(uint256 indexed marketId);

    /// @notice A market's settlement debt reserve changed.
    /// @custom:spec REQ-MREG-033
    event SettlementReserveSet(uint256 indexed marketId, uint256 debtReserveId);

    /// @notice The market is not `Offboarding`.
    /// @custom:spec REQ-CONFIG-080
    error MarketNotOffboarding(uint256 marketId);

    /// @notice The notice period or the step interval has not passed.
    /// @param nextAt First timestamp at which the next step is allowed.
    /// @custom:spec REQ-CONFIG-080
    error WindDownStepTooEarly(uint256 nextAt);

    /// @notice An account of the market still has debt (`Collateralization.getMarketDebtFree` is false).
    /// @custom:spec REQ-CONFIG-080
    error MarketHasDebt(uint256 marketId);

    /// @notice Applies the next wind-down step of an `Offboarding` market.
    /// @dev Callable by anyone. Reverts `MarketNotOffboarding` and `WindDownStepTooEarly`. Emits `WindDownStepped`.
    /// @param marketId The market.
    /// @custom:spec REQ-CONFIG-080
    function stepWindDown(
        uint256 marketId
    ) external;

    /// @notice Closes an `Offboarding` market once the notice period has passed and none of its accounts has debt.
    /// @dev Callable by anyone. Reverts `MarketNotOffboarding` unless the market is `Offboarding`,
    /// `WindDownStepTooEarly(offboardedAt + OFFBOARD_NOTICE_SECONDS)` before the notice ends, so a market announced
    /// for offboarding stays open to repay and withdrawal for the whole notice, and `MarketHasDebt` unless
    /// `Collateralization.getMarketDebtFree(vaultToken)` is true for the market's vault token. Sets status `Closed`
    /// and emits `MarketClosed`.
    /// @param marketId The market.
    /// @custom:spec REQ-CONFIG-080, REQ-COLL-040
    function closeMarket(
        uint256 marketId
    ) external;

    /// @notice The wind-down record of a market.
    /// @dev Never reverts; all zeros for a market that never entered `Offboarding`. `offboardedAt` is the time
    /// `setMarketOffboarding` ran, `lastStepAt` the last `stepWindDown` (0 before the first), `startLtBps` the reserve's
    /// collateral factor when offboarding began and `currentLtBps` the threshold the last step announced
    /// (`startLtBps` before the first step).
    /// @param marketId The market.
    /// @return state The market's `WindDownState`.
    /// @custom:spec REQ-CONFIG-080
    function windDownState(
        uint256 marketId
    ) external view returns (WindDownState memory state);

    /// @notice The debt reserve of the market's CDP Spoke into whose asset pending settlement converts.
    /// @dev Set by `listCollateralMarket` to the first debt reserve enabled on the Spoke; LPVaultSwap's `settlePending`
    /// pays the proceeds to that reserve's `coverageSpokeOf(fundingHub, asset)`.
    /// @param marketId The market.
    /// @return debtReserveId The settlement debt reserve.
    /// @custom:spec REQ-MREG-033, Q-338
    function settlementReserve(
        uint256 marketId
    ) external view returns (uint256 debtReserveId);

    /// @notice Changes a market's settlement debt reserve.
    /// @dev `APPLICATION_ADMIN`, normal delay. Reverts `UnknownDebtReserve(spoke, debtReserveId)` unless the reserve
    /// is enabled on the market's Spoke. Emits `SettlementReserveSet`.
    /// @param marketId The market.
    /// @param debtReserveId Enabled debt reserve of the market's Spoke.
    /// @custom:spec REQ-MREG-033, Q-358
    function setSettlementReserve(
        uint256 marketId,
        uint256 debtReserveId
    ) external;
}
