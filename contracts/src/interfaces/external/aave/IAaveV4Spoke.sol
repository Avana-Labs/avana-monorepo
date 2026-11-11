// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAaveV4ExtSload} from "./IAaveV4ExtSload.sol";

/// @title IAaveV4Spoke
/// @notice Calls Avana makes on a CDP Spoke, a standard, unmodified Aave V4 Spoke. LPVaultSwap is the only caller whose
/// `liquidationCall` completes: the seized vault token accepts only LPVaultSwap as recipient, and the listing settings
/// the drift check enforces (`receiveSharesEnabled = false`, `liquidationFee = 0` or paid to Avana's fee receiver, no
/// reinvestment controller) leave no other path.
/// @dev ABI checked against `src/spoke/interfaces/ISpoke.sol` of the pinned Aave V4 dependency (`a3ef63e`); every
/// selector and struct layout here equals the Spoke's. `extSload` comes from `IAaveV4ExtSload`, which the Spoke also
/// implements.
/// @custom:spec REQ-HUB-092, REQ-HUB-094, REQ-HUB-095, Q-281
interface IAaveV4Spoke is IAaveV4ExtSload {
    /// @notice Reserve record.
    /// @dev `hub` is the Hub contract and `flags` a packed `uint8` of reserve flags; both have these ABI types on the
    /// Spoke. `collateralRisk` is in basis points; `dynamicConfigKey` is the latest dynamic-config key.
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
    /// @dev `targetHealthFactor` and `healthFactorForMaxBonus` are 18-decimal; `liquidationBonusFactor` is in basis
    /// points.
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
    /// @dev `riskPremium` is in basis points; `avgCollateralFactor` and `healthFactor` are 18-decimal (1e18 is a health
    /// factor of 1); `totalCollateralValue` is in the oracle's value unit and `totalDebtValueRay` in that unit scaled by
    /// 1e27.
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
    /// @dev Called from a PositionProxy.
    /// @return Supplied shares.
    /// @return Supplied amount.
    function supply(
        uint256 reserveId,
        uint256 amount,
        address onBehalfOf
    ) external returns (uint256, uint256);

    /// @notice Withdraws `amount` of reserve `reserveId` from `onBehalfOf`'s supply to the caller.
    /// @dev Called from a PositionProxy.
    /// @return Withdrawn shares.
    /// @return Withdrawn amount.
    function withdraw(
        uint256 reserveId,
        uint256 amount,
        address onBehalfOf
    ) external returns (uint256, uint256);

    /// @notice Borrows `amount` of reserve `reserveId` against `onBehalfOf`'s account and sends it to the caller.
    /// @dev Called from a PositionProxy.
    /// @return Drawn shares.
    /// @return Drawn amount.
    function borrow(
        uint256 reserveId,
        uint256 amount,
        address onBehalfOf
    ) external returns (uint256, uint256);

    /// @notice Repays up to `amount` of `onBehalfOf`'s debt in reserve `reserveId`, pulled from the caller.
    /// @dev Called from a PositionProxy.
    /// @return Repaid drawn shares.
    /// @return Total amount repaid.
    function repay(
        uint256 reserveId,
        uint256 amount,
        address onBehalfOf
    ) external returns (uint256, uint256);

    /// @notice Liquidates `user`: the caller pays up to `debtToCover` of the debt reserve and receives seized collateral.
    /// @dev Called by LPVaultSwap with `receiveShares = false`. The seized vault token moves from the Hub to the caller,
    /// so its recipient rule reverts the call for every caller other than LPVaultSwap.
    /// @custom:spec REQ-HUB-055, REQ-HUB-092, REQ-SWAP-016
    function liquidationCall(
        uint256 collateralReserveId,
        uint256 debtReserveId,
        address user,
        uint256 debtToCover,
        bool receiveShares
    ) external;

    /// @notice Turns reserve `reserveId` on or off as collateral for `onBehalfOf`.
    /// @dev Called from a PositionProxy.
    function setUsingAsCollateral(
        uint256 reserveId,
        bool usingAsCollateral,
        address onBehalfOf
    ) external;

    /// @notice Spoke-wide liquidation settings.
    /// @dev Read by the MarketRegistry, the ParameterStore and the RiskModule.
    function getLiquidationConfig() external view returns (LiquidationConfig memory);

    /// @notice Number of reserves listed on the Spoke, active or not.
    /// @dev Summarised in the AaveAdapter, LPVaultSwap and RiskModule CVL specs.
    function getReserveCount() external view returns (uint256);

    /// @notice Reserve ID of asset `assetId` of `hub`; reverts when the Spoke has no such reserve.
    /// @dev Read by Collateralization, the MarketRegistry and the ParameterStore.
    function getReserveId(
        address hub,
        uint256 assetId
    ) external view returns (uint256);

    /// @notice Reserve record of `reserveId`.
    /// @dev Read by the MarketRegistry, the ParameterStore and the RiskModule.
    function getReserve(
        uint256 reserveId
    ) external view returns (Reserve memory);

    /// @notice Settings of reserve `reserveId`.
    /// @dev Read by the MarketRegistry and the RiskModule.
    function getReserveConfig(
        uint256 reserveId
    ) external view returns (ReserveConfig memory);

    /// @notice Settings of reserve `reserveId` stored under `dynamicConfigKey`.
    /// @dev Read by the MarketRegistry, the ParameterStore and the RiskModule.
    function getDynamicReserveConfig(
        uint256 reserveId,
        uint32 dynamicConfigKey
    ) external view returns (DynamicReserveConfig memory);

    /// @notice Whether `user` uses reserve `reserveId` as collateral, and whether `user` borrows it.
    /// @dev Summarised in the AaveAdapter, LPVaultSwap and RiskModule CVL specs.
    /// @return True when the reserve is enabled as collateral.
    /// @return True when the reserve is borrowed.
    function getUserReserveStatus(
        uint256 reserveId,
        address user
    ) external view returns (bool, bool);

    /// @notice Supplied shares of `user` in reserve `reserveId`.
    /// @dev Read by Collateralization.
    function getUserSuppliedShares(
        uint256 reserveId,
        address user
    ) external view returns (uint256);

    /// @notice Drawn plus premium debt of `user` in reserve `reserveId`.
    /// @dev Summarised in the AaveAdapter, LPVaultSwap and RiskModule CVL specs.
    function getUserTotalDebt(
        uint256 reserveId,
        address user
    ) external view returns (uint256);

    /// @notice Position of `user` in reserve `reserveId`.
    /// @dev Summarised in the RiskModule CVL spec.
    function getUserPosition(
        uint256 reserveId,
        address user
    ) external view returns (UserPosition memory);

    /// @notice Account summary of `user` under the user's current dynamic configuration.
    /// @dev Read by Collateralization.
    function getUserAccountData(
        address user
    ) external view returns (UserAccountData memory);

    /// @notice Liquidation bonus, in basis points, for `user` in reserve `reserveId` at health factor `healthFactor`
    /// (18-decimal).
    /// @dev Summarised in the LPVaultSwap CVL spec.
    function getLiquidationBonus(
        uint256 reserveId,
        address user,
        uint256 healthFactor
    ) external view returns (uint256);

    /// @notice The Spoke's oracle (`IAaveV4Oracle`).
    /// @dev Read by the MarketRegistry.
    function ORACLE() external view returns (address);

    /// @notice Most reserves a user may hold as collateral, and separately as debt.
    /// @dev Read by the RiskModule and the Aave V4 fixture tests.
    function MAX_USER_RESERVES_LIMIT() external view returns (uint16);
}
