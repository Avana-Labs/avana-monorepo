// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAaveV4ExtSload} from "./IAaveV4ExtSload.sol";

/// @title IAaveV4Spoke
/// @notice Calls Avana makes on a CDP Spoke, a standard, unmodified Aave V4 Spoke.
/// @dev ABI-equal to the pinned Aave V4 `ISpoke` (`a3ef63e`).
interface IAaveV4Spoke is IAaveV4ExtSload {
    /// @notice Reserve record.
    /// @dev `flags` is a packed `uint8` of reserve flags; `collateralRisk` is in basis points.
    struct Reserve {
        address underlying;
        address hub;
        uint16 assetId;
        uint8 decimals;
        uint24 collateralRisk;
        uint8 flags;
        uint32 dynamicConfigKey;
    }

    /// @notice Reserve settings Avana checks at listing and in the drift check.
    /// @dev `collateralRisk` is in basis points.
    struct ReserveConfig {
        uint24 collateralRisk;
        bool paused;
        bool frozen;
        bool borrowable;
        bool receiveSharesEnabled;
    }

    /// @notice Reserve settings stored per dynamic-config key.
    /// @dev All three are in basis points; a `maxLiquidationBonus` of 10,000 is a bonus of zero.
    struct DynamicReserveConfig {
        uint16 collateralFactor;
        uint32 maxLiquidationBonus;
        uint16 liquidationFee;
    }

    /// @notice Spoke-wide liquidation settings.
    /// @dev `targetHealthFactor` and `healthFactorForMaxBonus` are 18-decimal.
    struct LiquidationConfig {
        uint128 targetHealthFactor;
        uint64 healthFactorForMaxBonus;
        uint16 liquidationBonusFactor;
    }

    /// @notice A user's position in one reserve.
    /// @dev `premiumOffsetRay` is in asset units scaled by 1e27; `dynamicConfigKey` is the key the position uses.
    struct UserPosition {
        uint120 drawnShares;
        uint120 premiumShares;
        int200 premiumOffsetRay;
        uint120 suppliedShares;
        uint32 dynamicConfigKey;
    }

    /// @notice A user's account summary across the Spoke.
    /// @dev `healthFactor` is 18-decimal; `totalDebtValueRay` is scaled by 1e27.
    struct UserAccountData {
        uint256 riskPremium;
        uint256 avgCollateralFactor;
        uint256 healthFactor;
        uint256 totalCollateralValue;
        uint256 totalDebtValueRay;
        uint256 activeCollateralCount;
        uint256 borrowCount;
    }

    /// @notice Supplies `amount` of reserve `reserveId` for `onBehalfOf`, pulled from the caller.
    /// @return Supplied shares.
    /// @return Supplied amount.
    function supply(
        uint256 reserveId,
        uint256 amount,
        address onBehalfOf
    ) external returns (uint256, uint256);

    /// @notice Withdraws `amount` of reserve `reserveId` from `onBehalfOf`'s supply to the caller.
    /// @return Withdrawn shares.
    /// @return Withdrawn amount.
    function withdraw(
        uint256 reserveId,
        uint256 amount,
        address onBehalfOf
    ) external returns (uint256, uint256);

    /// @notice Borrows `amount` of reserve `reserveId` against `onBehalfOf`'s account and sends it to the caller.
    /// @return Drawn shares.
    /// @return Drawn amount.
    function borrow(
        uint256 reserveId,
        uint256 amount,
        address onBehalfOf
    ) external returns (uint256, uint256);

    /// @notice Repays up to `amount` of `onBehalfOf`'s debt in reserve `reserveId`, pulled from the caller.
    /// @return Repaid drawn shares.
    /// @return Total amount repaid.
    function repay(
        uint256 reserveId,
        uint256 amount,
        address onBehalfOf
    ) external returns (uint256, uint256);

    /// @notice Liquidates `user`: the caller pays up to `debtToCover` and receives seized collateral.
    /// @dev The seized vault token's recipient rule reverts the call for every caller other than LPVaultSwap.
    function liquidationCall(
        uint256 collateralReserveId,
        uint256 debtReserveId,
        address user,
        uint256 debtToCover,
        bool receiveShares
    ) external;

    /// @notice Turns reserve `reserveId` on or off as collateral for `onBehalfOf`.
    function setUsingAsCollateral(
        uint256 reserveId,
        bool usingAsCollateral,
        address onBehalfOf
    ) external;

    /// @notice Spoke-wide liquidation settings.
    function getLiquidationConfig() external view returns (LiquidationConfig memory);

    /// @notice Number of reserves listed on the Spoke, active or not.
    function getReserveCount() external view returns (uint256);

    /// @notice Reserve ID of asset `assetId` of `hub`; reverts when the Spoke has no such reserve.
    function getReserveId(
        address hub,
        uint256 assetId
    ) external view returns (uint256);

    /// @notice Reserve record of `reserveId`.
    function getReserve(
        uint256 reserveId
    ) external view returns (Reserve memory);

    /// @notice Settings of reserve `reserveId`.
    function getReserveConfig(
        uint256 reserveId
    ) external view returns (ReserveConfig memory);

    /// @notice Settings of reserve `reserveId` stored under `dynamicConfigKey`.
    function getDynamicReserveConfig(
        uint256 reserveId,
        uint32 dynamicConfigKey
    ) external view returns (DynamicReserveConfig memory);

    /// @notice Whether `user` uses reserve `reserveId` as collateral, and whether `user` borrows it.
    /// @return True when the reserve is enabled as collateral.
    /// @return True when the reserve is borrowed.
    function getUserReserveStatus(
        uint256 reserveId,
        address user
    ) external view returns (bool, bool);

    /// @notice Supplied shares of `user` in reserve `reserveId`.
    function getUserSuppliedShares(
        uint256 reserveId,
        address user
    ) external view returns (uint256);

    /// @notice Drawn plus premium debt of `user` in reserve `reserveId`.
    function getUserTotalDebt(
        uint256 reserveId,
        address user
    ) external view returns (uint256);

    /// @notice Position of `user` in reserve `reserveId`.
    function getUserPosition(
        uint256 reserveId,
        address user
    ) external view returns (UserPosition memory);

    /// @notice Account summary of `user` under the user's current dynamic configuration.
    function getUserAccountData(
        address user
    ) external view returns (UserAccountData memory);

    /// @notice Liquidation bonus, in basis points, for `user` in reserve `reserveId` at health factor `healthFactor`
    /// (18-decimal).
    function getLiquidationBonus(
        uint256 reserveId,
        address user,
        uint256 healthFactor
    ) external view returns (uint256);

    /// @notice The Spoke's oracle (`IAaveV4Oracle`).
    function ORACLE() external view returns (address);

    /// @notice Most reserves a user may hold as collateral, and separately as debt.
    function MAX_USER_RESERVES_LIMIT() external view returns (uint16);
}
