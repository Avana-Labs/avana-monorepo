// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {WindDownState} from "./types/WindDownState.sol";

/// @title IMarketRegistryWindDown
/// @notice The end of a market's life (offboarding notice and close) and its settlement debt reserve.
/// @dev The Aave DAO, not this registry, lowers the reserve's liquidation threshold after the notice.
interface IMarketRegistryWindDown {
    event MarketClosed(uint256 indexed marketId);

    event SettlementReserveSet(uint256 indexed marketId, uint256 debtReserveId);

    error MarketNotOffboarding(uint256 marketId);

    /// @notice The offboarding notice has not passed.
    /// @param notBefore First timestamp at which the market may close.
    error OffboardNoticeRunning(uint256 notBefore);

    /// @notice An account of the market still has debt (`Collateralization.getMarketDebtFree` is false).
    error MarketHasDebt(uint256 marketId);

    /// @notice Closes an `Offboarding` market once the notice period has passed and none of its accounts has debt.
    /// @dev Callable by anyone.
    function closeMarket(
        uint256 marketId
    ) external;

    /// @notice The offboarding record of a market.
    /// @dev Never reverts; all zeros for a market that never entered `Offboarding`.
    function windDownState(
        uint256 marketId
    ) external view returns (WindDownState memory state);

    /// @notice The debt reserve of the market's CDP Spoke into whose asset pending settlement converts.
    /// @dev Defaults to the Spoke's first enabled debt reserve at listing.
    function settlementReserve(
        uint256 marketId
    ) external view returns (uint256 debtReserveId);

    /// @notice Changes a market's settlement debt reserve.
    /// @dev `APPLICATION_ADMIN` only. The reserve must be enabled on the market's Spoke.
    function setSettlementReserve(
        uint256 marketId,
        uint256 debtReserveId
    ) external;
}
