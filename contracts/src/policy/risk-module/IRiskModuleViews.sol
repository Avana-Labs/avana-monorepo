// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {AccountGateStatus} from "../../types/AccountGateStatus.sol";
import {PledgePreview} from "../../types/PledgePreview.sol";
import {SpeedScope} from "./types/SpeedScope.sol";
import {SpeedView} from "./types/SpeedView.sol";
import {SpeedWindow} from "./types/SpeedWindow.sol";

/// @title IRiskModuleViews
/// @notice Non-reverting previews, formula views and implementation immutables of the RiskModule.
interface IRiskModuleViews {
    /// @notice Runs the checks of `checkPledge` and returns the outcome without reverting.
    /// @dev Must not be called inside a pledge, where Collateralization's lock is held.
    function previewPledge(
        address depositor,
        uint256 marketId,
        bytes32 positionKey
    ) external view returns (PledgePreview memory preview);

    /// @notice Every borrow-side gate outcome for an account, without poking and without reverting.
    function getAccountGateStatus(
        address proxy
    ) external view returns (AccountGateStatus memory status);

    /// @notice Reverts with the first failing gate of a borrow of `debtReserveId` by `proxy`, without the pokes.
    function checkBorrowGate(
        address proxy,
        uint256 debtReserveId
    ) external view;

    /// @notice USD of collateral at the oracle price that restores the account to `rescueHealthFactor`.
    /// @dev Rounded up; 0 when the account has no debt or is at or above that factor.
    /// @return usd 8-decimal USD.
    function usdToRestore(
        address proxy
    ) external view returns (uint256 usd);

    /// @notice LP collateral factor the Spoke reserve may carry at most.
    /// @dev The weakest pool token's collateral factor times `poolRiskFactor`, rounded down.
    /// @return cfBps The collateral factor, bps.
    function expectedCollateralFactorBps(
        uint256 marketId
    ) external view returns (uint256 cfBps);

    /// @notice Health factor below which an indebted account may make a rescue top-up; not a borrow gate.
    /// @return value The factor, WAD.
    function rescueHealthFactor() external pure returns (uint256 value);

    /// @notice MarketRegistry (implementation immutable).
    function MARKET_REGISTRY() external view returns (address marketRegistry);

    /// @notice ParameterStore (implementation immutable).
    function PARAMETER_STORE() external view returns (address parameterStore);

    /// @notice Collateralization, the caller of `checkPledge` (implementation immutable).
    function COLLATERALIZATION() external view returns (address collateralization);

    /// @notice AaveAdapter, the caller of the borrow-side checks (implementation immutable).
    function ADAPTER() external view returns (address adapter);

    /// @notice Live, recovering and latched reasons of a market's circuit breaker.
    /// @dev Never reverts.
    function getBreakerStatus(
        uint256 marketId
    ) external view returns (uint32 reasons, uint64 reopensAt);

    /// @notice Live, recovering and latched reasons of a debt reserve's circuit breaker.
    /// @dev Never reverts.
    function getDebtBreakerStatus(
        address spoke,
        uint256 debtReserveId
    ) external view returns (uint32 reasons, uint64 reopensAt);

    /// @notice Security-freeze conditions of a market that hold now, from live state only.
    /// @dev Never reverts. Excludes latched bits and temporary gates.
    /// @return reasons Bitmap of `BreakerReasons`, within `BreakerReasons.SECURITY`.
    function liveBreakerReasons(
        uint256 marketId
    ) external view returns (uint32 reasons);

    /// @notice Security-freeze conditions of a debt reserve that hold now, from live state only.
    /// @dev Never reverts. Excludes latched bits and temporary gates.
    /// @return reasons Bitmap of `BreakerReasons`, within `BreakerReasons.SECURITY`.
    function liveDebtBreakerReasons(
        address spoke,
        uint256 debtReserveId
    ) external view returns (uint32 reasons);

    /// @notice Most a rescue top-up's minimum value can be.
    /// @return usd 8-decimal USD; changes only with an upgrade.
    function RESCUE_MIN_PLEDGE_USD() external pure returns (uint256 usd);

    /// @notice LPVaultSwap, read for `activeKeeperCount`; new borrowing halts when it is 0.
    function LP_VAULT_SWAP() external view returns (address lpVaultSwap);

    /// @notice The only address that may hold `DEFAULT_ADMIN_ROLE` or `APPLICATION_ADMIN` (implementation immutable).
    function TIMELOCK() external view returns (address timelock);

    /// @notice Debt of an account valued at its debt oracles, 8-decimal USD.
    function debtValueUsd(
        address proxy
    ) external view returns (uint256 usd);

    /// @notice The market and (funding Hub, asset) borrow-speed windows as the next borrow of the reserve sees them.
    /// @dev Never reverts: a failed read returns both views with `unavailable = true`.
    /// @return market The market window, 8-decimal USD.
    /// @return debt The (funding Hub, asset) window, asset base units.
    function getBorrowSpeed(
        uint256 marketId,
        uint256 debtReserveId
    ) external view returns (SpeedView memory market, SpeedView memory debt);

    /// @notice The market's pledge-speed window as the next non-rescue pledge would see it now.
    /// @dev Never reverts; reports `unavailable` while Collateralization's lock is held.
    /// @return pledge The pledge window, 8-decimal USD.
    function getPledgeSpeed(
        uint256 marketId
    ) external view returns (SpeedView memory pledge);

    /// @notice A speed window as stored, not rolled to now.
    /// @param key `bytes32(marketId)` for a market window, `keccak256(abi.encode(hub, asset))` for a debt window.
    function getSpeedWindow(
        SpeedScope scope,
        bytes32 key
    ) external view returns (SpeedWindow memory window);
}
