// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {AccountGateStatus, DriftReason} from "../../types/MarketTypes.sol";
import {PledgeCounters, PledgePreview} from "../../types/PositionTypes.sol";
import {IRiskModuleErrors} from "./IRiskModuleErrors.sol";
import {PledgeCharge, SpeedScope, SpeedView, SpeedWindow} from "./types/RiskModuleTypes.sol";

/// @title IRiskModule
/// @notice Avana's risk checks on one chain: the pledge check and the borrow-side pre- and post-checks.
/// @dev UUPS proxy; only the timelock can upgrade it. Holds no funds and has no setter.
interface IRiskModule is IRiskModuleErrors {
    /// @notice Initializes the proxy storage.
    /// @dev Runs once, with the proxy deployment. Grants `DEFAULT_ADMIN_ROLE` and `APPLICATION_ADMIN` to `timelock`.
    function initialize(
        address timelock
    ) external;

    /// @notice `pokeConfig` found the Spoke's Aave settings drifted.
    event ConfigDriftDetected(address indexed spoke, DriftReason reason);

    /// @notice Pledge eligibility, rescue rule, minimum, breaker, charge and cap check; returns the charge or reverts.
    /// @dev Only Collateralization's call writes the pledge-speed window; any other caller writes nothing.
    /// @param units Units to credit: the position's units for a pledge, the added units for a re-credit.
    /// @param requireRescue True when only a rescue top-up may pass; the AaveAdapter passes false.
    function checkPledge(
        address depositor,
        address proxy,
        uint256 marketId,
        uint32 integrationId,
        bytes32 positionKey,
        uint128 units,
        PledgeCounters calldata counters,
        bool requireRescue
    ) external returns (PledgeCharge memory charge);

    /// @notice Pre-borrow gate over the account's collateral market and every debt reserve of the account.
    /// @dev Anyone may call; only the AaveAdapter's call adds the borrow-speed charges.
    /// @param amount Amount borrowed, base units of the reserve's asset.
    function preBorrowCheck(
        address proxy,
        uint256 debtReserveId,
        uint256 amount
    ) external;

    /// @notice Gives room back in the borrow-speed windows after a repay.
    /// @dev Only the AaveAdapter; reverts `NotSpeedWriter` otherwise.
    /// @param amount Base units the repay took.
    function creditRepay(
        address proxy,
        uint256 debtReserveId,
        uint256 amount
    ) external;

    /// @notice Gives room back in a market's pledge-speed window after a withdrawal.
    /// @dev Only Collateralization; reverts `NotSpeedWriter` otherwise.
    /// @param usd Booked value released, 8-decimal USD.
    function creditWithdraw(
        uint256 marketId,
        uint256 usd
    ) external;

    /// @notice Pre-withdrawal gate for an account with debt.
    /// @dev `preBorrowCheck`'s gates without the Offboarding and frozen-reserve refusals, over every debt reserve held.
    function preWithdrawCheck(
        address proxy
    ) external;

    /// @notice Post-action health gate after a borrow, a withdraw-with-debt or a partial removal with debt.
    /// @dev Reverts unless the rescue-excluded HF >= `max(1e18, minHealthFactor)`.
    /// @param minHealthFactor The caller's minimum, WAD; 0 for none.
    /// @return healthFactor The rescue-excluded health factor, WAD.
    function postHealthCheck(
        address proxy,
        uint256 minHealthFactor
    ) external view returns (uint256 healthFactor);

    /// @notice Spoke-wide and per-market Aave configuration drift checks, including the risk configuration.
    /// @dev Reverts `ConfigDrift` on the first failure; does not require the market to be Active.
    function checkAaveConfig(
        address spoke,
        uint256[] calldata marketIds
    ) external view;

    /// @notice Runs the Aave configuration drift check over every market of a CDP Spoke outside any user call.
    /// @dev Anyone may call. Emits `ConfigDriftDetected` instead of reverting and records nothing: the borrow, withdraw
    /// and pledge checks read the drift live.
    /// @return reason The first drift found, `None` when the settings hold.
    function pokeConfig(
        address spoke
    ) external returns (DriftReason reason);

    /// @notice Whether the market's home Hub has added assets equal to added shares for its vault-token asset, exactly.
    function isHubSharesEqualAssets(
        uint256 marketId
    ) external view returns (bool equal);

    /// @notice Requires the record left by a partial removal with debt to be worth at least `minPledgeUsd`.
    /// @dev Values the units at `lastAcceptedPrice`, rounded down; reverts `RecordBelowMinPledge`.
    function checkRemainingRecord(
        uint256 marketId,
        uint128 remainingUnits
    ) external view;

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

    /// @notice Reasons of a market's circuit breaker that hold now, from live state.
    /// @dev Never reverts.
    /// @return reasons Bitmap of `BreakerReasons`, within `BreakerReasons.MARKET`.
    function getBreakerStatus(
        uint256 marketId
    ) external view returns (uint32 reasons);

    /// @notice Reasons of a debt reserve's circuit breaker that hold now, from live state.
    /// @dev Never reverts.
    /// @return reasons Bitmap of `BreakerReasons`, within `BreakerReasons.DEBT`.
    function getDebtBreakerStatus(
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
