// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAaveV3ACLManager} from "../../interfaces/external/aave/IAaveV3ACLManager.sol";
import {IAaveV3Pool} from "../../interfaces/external/aave/IAaveV3Pool.sol";
import {IAaveV3PoolAddressesProvider} from "../../interfaces/external/aave/IAaveV3PoolAddressesProvider.sol";
import {IMarketRegistry} from "../../policy/market-registry/IMarketRegistry.sol";
import {IFlashLiquidator} from "./IFlashLiquidator.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title FlashLiquidatorLenders
/// @notice The flash liquidation helper's one lender, the chain's Aave V3 Pool: quotes what it can lend and charges,
/// and starts the loan.
/// @dev The Pool is immutable and may not be a recorded Hub, so nothing can redirect a loan.
abstract contract FlashLiquidatorLenders is IFlashLiquidator {
    /// @notice Basis-point denominator.
    uint256 internal constant BPS = 10_000;

    /// @notice Aave V3 `ReserveConfigurationMap` bits read by `maxFlashLoan`; a frozen reserve can still lend.
    uint256 private constant ACTIVE_BIT = 1 << 56;
    uint256 private constant PAUSED_BIT = 1 << 60;
    uint256 private constant FLASHLOAN_ENABLED_BIT = 1 << 63;

    /// @inheritdoc IFlashLiquidator
    address public immutable override POOL;

    /// @inheritdoc IFlashLiquidator
    address public immutable override MARKET_REGISTRY;

    /// @notice Fixes the chain's Aave V3 Pool and MarketRegistry.
    /// @dev Reverts `FlashSourceIsHub` if the MarketRegistry records the Pool as a Hub.
    constructor(
        address pool,
        address marketRegistry
    ) {
        if (pool == address(0) || marketRegistry == address(0)) revert ZeroAddress();
        if (IMarketRegistry(marketRegistry).isRecordedHub(pool)) revert FlashSourceIsHub();
        POOL = pool;
        MARKET_REGISTRY = marketRegistry;
    }

    /// @inheritdoc IFlashLiquidator
    function maxFlashLoan(
        address asset
    ) public view override returns (uint256 available) {
        uint256 data = IAaveV3Pool(POOL).getConfiguration(asset);
        if (data & ACTIVE_BIT == 0 || data & PAUSED_BIT != 0 || data & FLASHLOAN_ENABLED_BIT == 0) return 0;
        address aToken = IAaveV3Pool(POOL).getReserveAToken(asset);
        if (aToken == address(0)) return 0;
        // V3.1+ virtual accounting: the Pool lends only its virtual balance, and only what the aToken holds can move.
        available =
            Math.min(IERC20(asset).balanceOf(aToken), uint256(IAaveV3Pool(POOL).getVirtualUnderlyingBalance(asset)));
    }

    /// @inheritdoc IFlashLiquidator
    function flashPremium(
        address, /* asset: the Pool charges every asset the same premium */
        uint256 amount
    ) public view override returns (uint256 premium) {
        address provider = IAaveV3Pool(POOL).ADDRESSES_PROVIDER();
        address aclManager = IAaveV3PoolAddressesProvider(provider).getACLManager();
        if (IAaveV3ACLManager(aclManager).isFlashBorrower(address(this))) return 0;
        premium = Math.mulDiv(amount, IAaveV3Pool(POOL).FLASHLOAN_PREMIUM_TOTAL(), BPS, Math.Rounding.Ceil);
    }

    /// @notice Borrows `amount` of `asset` from `POOL` with interest-rate mode 0, so it never opens debt.
    function _borrow(
        address asset,
        uint256 amount,
        bytes memory data
    ) internal {
        address[] memory assets = new address[](1);
        assets[0] = asset;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = amount;
        uint256[] memory modes = new uint256[](1);
        IAaveV3Pool(POOL).flashLoan(address(this), assets, amounts, modes, address(this), data, 0);
    }
}
