// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @title ILensSpokeReads
/// @notice Aave V4 Spoke views the Lens reads beyond Avana's minimal `IAaveV4Spoke`.
interface ILensSpokeReads {
    /// @notice Drawn debt and premium debt of `user` on `reserveId`, asset base units (premium rounded up).
    function getUserDebt(
        uint256 reserveId,
        address user
    ) external view returns (uint256 drawn, uint256 premium);

    /// @notice Premium debt of `user` on `reserveId`, asset units scaled by RAY.
    function getUserPremiumDebtRay(
        uint256 reserveId,
        address user
    ) external view returns (uint256 premiumDebtRay);
}
