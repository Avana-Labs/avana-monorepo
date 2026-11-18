// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {PositionRef} from "../../types/PositionRef.sol";

/// @title IAaveAdapterSettlement
/// @notice Steps LPVaultSwap asks the Adapter to run; none reads the MarketRegistry, pause, freeze or a breaker.
interface IAaveAdapterSettlement {
    /// @notice Burns `units` of a market's vault token from LPVaultSwap's balance.
    /// @dev Only LPVaultSwap while it holds the Lock; reads no pause state, so liquidation always runs.
    function burnSeized(
        uint256 marketId,
        address vaultToken,
        uint256 units
    ) external;

    /// @notice Repays `amount` of the session's debt reserve on the session's proxy with funds from LPVaultSwap.
    /// @dev Only LPVaultSwap inside the Adapter's open deleverage session.
    /// @param amount Debt asset LPVaultSwap provides, base units.
    function deleverageRepay(
        address proxy,
        uint256 debtReserveId,
        uint256 amount
    ) external returns (uint256 repaid);

    /// @notice Withdraws and burns the session's units and has Collateralization release them to LPVaultSwap.
    /// @dev Same caller and session checks as `deleverageRepay`; runs only after it.
    /// @param minAmounts Least raw amount of each pool token, market token order.
    function deleverageRelease(
        address proxy,
        PositionRef calldata position,
        uint128 units,
        uint256[] calldata minAmounts
    ) external returns (uint256[] memory amounts, bool closed);
}
