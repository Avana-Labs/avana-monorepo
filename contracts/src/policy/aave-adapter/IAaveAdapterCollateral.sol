// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {PositionRef} from "../../types/PositionRef.sol";
import {RepayWithCollateralParams} from "./types/RepayWithCollateralParams.sol";

/// @title IAaveAdapterCollateral
/// @notice Borrower entry points that change a pledged record in place; amounts follow the market's `tokens` order.
interface IAaveAdapterCollateral {
    /// @notice Removes part of one record's credited units; the position stays in custody.
    /// @param units Credited units removed; must be below the record's credited units.
    /// @param minHealthFactor Caller's minimum rescue-excluded health factor after a removal with debt, WAD.
    /// @return amounts Raw amount of each pool token paid to the depositor of record.
    function removeLiquidity(
        uint256 marketId,
        PositionRef calldata position,
        uint128 units,
        uint256[] calldata minAmounts,
        uint256 deadline,
        uint256 minHealthFactor
    ) external returns (uint256[] memory amounts);

    /// @notice Credits units added to a pledged position.
    /// @dev Depositor of record only.
    /// @param topUp Integration-encoded LP amount for a fungible-share position; empty for an NFT position.
    function recredit(
        uint256 marketId,
        PositionRef calldata position,
        bytes calldata topUp,
        uint256 deadline
    ) external returns (uint128 added);

    /// @notice Repays one debt reserve with units released from one record, via LPVaultSwap's flash deleverage.
    /// @dev While debt remains, reverts unless the health factor ends >= `max(before, minHealthFactor)`.
    function repayWithCollateral(
        RepayWithCollateralParams calldata p
    ) external returns (uint256 debtRepaid, uint256 debtAssetToWallet);
}
