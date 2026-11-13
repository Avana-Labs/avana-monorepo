// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {WindDownState} from "./types/WindDownState.sol";

/// @title IMarketRegistryWindDown
/// @notice The end of a market's life (offboarding notice and close) and its settlement debt reserve.
/// @dev `setMarketOffboarding` freezes new exposure and starts a public notice of `OFFBOARD_NOTICE_SECONDS` (5 days);
/// the record publishes the target liquidation threshold `⌊startLtBps × 5,000 / 10,000⌋` bps (half the threshold at
/// offboarding) and the earliest date
/// `offboardedAt + 5 days`. After the notice the Aave DAO lowers the market reserve's liquidation threshold once, to
/// the target, in its own payload; Avana applies no Aave configuration itself. Accounts below health factor 1 then are
/// liquidated through the normal flow. Once no account of the
/// market has debt, `closeMarket` releases its LPOracle, swap routes and keeper duty; every
/// debt-free position stays withdrawable forever because a debt-free withdrawal reads no price (AMMN-FLOW-22).
/// @custom:spec REQ-CONFIG-080, REQ-MREG-033, Q-338, Q-355, Q-358
interface IMarketRegistryWindDown {
    /// @notice The market reached `Closed`.
    /// @custom:spec REQ-CONFIG-080
    event MarketClosed(uint256 indexed marketId);

    /// @notice A market's settlement debt reserve changed.
    /// @custom:spec REQ-MREG-033
    event SettlementReserveSet(uint256 indexed marketId, uint256 debtReserveId);

    /// @notice The market is not `Offboarding`.
    /// @custom:spec REQ-CONFIG-080
    error MarketNotOffboarding(uint256 marketId);

    /// @notice The offboarding notice has not passed.
    /// @param notBefore First timestamp at which the market may close, `offboardedAt + OFFBOARD_NOTICE_SECONDS`.
    /// @custom:spec REQ-CONFIG-080
    error OffboardNoticeRunning(uint256 notBefore);

    /// @notice An account of the market still has debt (`Collateralization.getMarketDebtFree` is false).
    /// @custom:spec REQ-CONFIG-080
    error MarketHasDebt(uint256 marketId);

    /// @notice Closes an `Offboarding` market once the notice period has passed and none of its accounts has debt.
    /// @dev Callable by anyone. Reverts `MarketNotOffboarding` unless the market is `Offboarding`,
    /// `OffboardNoticeRunning(offboardedAt + OFFBOARD_NOTICE_SECONDS)` before the notice ends, so a market announced
    /// for offboarding stays open to repay and withdrawal for the whole notice, and `MarketHasDebt` unless
    /// `Collateralization.getMarketDebtFree(vaultToken)` is true for the market's vault token. Sets status `Closed`
    /// and emits `MarketClosed`.
    /// @param marketId The market.
    /// @custom:spec REQ-CONFIG-080, REQ-COLL-040
    function closeMarket(
        uint256 marketId
    ) external;

    /// @notice The offboarding record of a market.
    /// @dev Never reverts; all zeros for a market that never entered `Offboarding`. `offboardedAt` is the time
    /// `setMarketOffboarding` ran (the earliest date of the Aave DAO's one threshold drop and of `closeMarket` is
    /// `offboardedAt + 5 days`), `unusedLastStepAt` is always 0, `startLtBps` the reserve's collateral factor when
    /// offboarding began and `targetLtBps` the published target, `⌊startLtBps × 5,000 / 10,000⌋`.
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
