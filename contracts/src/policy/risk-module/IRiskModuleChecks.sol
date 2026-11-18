// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {DriftReason} from "../../types/DriftReason.sol";
import {PledgeCounters} from "../../types/PledgeCounters.sol";
import {PledgeCharge} from "./types/PledgeCharge.sol";

/// @title IRiskModuleChecks
/// @notice The pledge check, the borrow-side pre- and post-checks, and the Aave drift and Hub shares checks.
interface IRiskModuleChecks {
    /// @notice `pokeConfig` found the Spoke's Aave settings drifted.
    event ConfigDriftDetected(address indexed spoke, DriftReason reason);

    /// @notice `pokeBreakers` evaluated a market and its Spoke's debt reserves.
    event BreakersPoked(uint256 indexed marketId, uint32 reasons);

    /// @notice Pledge eligibility, rescue rule, minimum, breaker, charge and cap check; returns the charge or reverts.
    /// @dev Only Collateralization's call writes the pledge-speed window; any other caller writes nothing.
    /// @param units Units to credit: the position's units for a pledge, the added units for a re-credit.
    /// @param requireRescue True under `Paused(General)` or for a frozen depositor: only a rescue top-up passes.
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
    /// @dev `preBorrowCheck`'s gates without the Offboarding and frozen refusals, over every debt reserve held.
    function preWithdrawCheck(
        address proxy
    ) external;

    /// @notice Post-action health gate after a borrow, a withdraw-with-debt or a partial removal with debt.
    /// @dev Reverts unless the rescue-excluded HF >= `max(1e18, hardHealthFloor(marketId), minHealthFactor)`.
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
    /// @dev Anyone may call. Emits `ConfigDriftDetected` instead of reverting.
    /// @return reason The first drift found, `None` when the settings hold.
    function pokeConfig(
        address spoke
    ) external returns (DriftReason reason);

    /// @notice Records the breaker conditions of a market and of every enabled debt reserve of its Spoke.
    /// @dev Anyone may call. Never reverts because a condition holds.
    function pokeBreakers(
        uint256 marketId
    ) external returns (uint32 reasons);

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
}
