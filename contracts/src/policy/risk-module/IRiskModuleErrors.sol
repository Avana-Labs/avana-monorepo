// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {DriftReason} from "../../types/DriftReason.sol";
import {PriceState} from "../../types/PriceState.sol";

/// @title IRiskModuleErrors
/// @notice Errors of the RiskModule's pledge check and borrow-side checks.
interface IRiskModuleErrors {
    /// @notice The market is not Active in the MarketRegistry.
    /// @param marketId Market identifier.
    /// @custom:spec REQ-RISK-009
    error MarketNotActive(uint256 marketId);

    /// @notice The market is Offboarding: no pledge into it and no borrow against it.
    /// @param marketId Market identifier.
    /// @custom:spec REQ-RISK-009, REQ-RISK-014, REQ-ADAPTER-019, REQ-ADAPTER-056, BOR-F-019
    error MarketOffboarding(uint256 marketId);

    /// @notice The market's AMM integration does not report the depositor as the position's owner (preview reason).
    /// @custom:spec REQ-RISK-010
    error NotPositionOwner();

    /// @notice The pool the AMM integration derives on-chain from the position is not the market's pool, or the
    /// position comes from a position manager or factory other than the integration's canonical one.
    /// @custom:spec REQ-RISK-011
    error PoolMismatch();

    /// @notice The position's shape is not exactly the market's shape: for concentrated liquidity, `tickLower` and
    /// `tickUpper` differ from the market's range (AMMN-RT-01). Crediting a narrower range at the market's per-unit
    /// value would overstate it (a $10k narrow position would price at $9.79M).
    /// @custom:spec REQ-RISK-012, Q-376
    error ShapeMismatch();

    /// @notice The position's liquidity is 0.
    /// @custom:spec REQ-RISK-013
    error ZeroLiquidity();

    /// @notice The pledged market's price state is not accepted for this pledge class.
    /// @param state The LPOracle price state as uint8.
    /// @custom:spec REQ-RISK-017, REQ-RISK-048, REQ-RISK-049
    error PriceNotAccepted(uint8 state);

    /// @notice The market's vault-token reserve is paused or frozen on the CDP Spoke (pledge).
    /// @custom:spec REQ-RISK-020
    error AaveReserveUnavailable();

    /// @notice The CDP Spoke is inactive or halted on the vault-token Hub asset.
    /// @custom:spec REQ-RISK-020
    error HubSpokeUnavailable();

    /// @notice The pledge would exceed the Spoke's Hub `addCap` on the vault-token asset.
    /// @custom:spec REQ-RISK-020, SPEC-CAP-006
    error HubAddCapReached();

    /// @notice Enabling the reserve would exceed the Spoke's per-account reserve limit (collateral and debt reserves).
    /// @custom:spec REQ-RISK-020
    error UserReservesLimit();

    /// @notice A cap test of SPEC-CAP-002 failed.
    /// @param capKind Name of the failed cap.
    /// @custom:spec REQ-RISK-021, REQ-RISK-051, SPEC-CAP-002
    error CapExceeded(bytes32 capKind);

    /// @notice The pledge needs the top-up slice but is not eligible for it, or exceeds the restore amount.
    /// @custom:spec REQ-RISK-022, SPEC-CAP-003
    error SliceNotAvailable();

    /// @notice The AMM integration cannot report the pool share (for concentrated liquidity, the pool's observation
    /// history cannot cover `twapWindow`).
    /// @custom:spec REQ-RISK-023, REQ-RISK-052
    error PoolShareUnavailable();

    /// @notice Avana's share of the pool, keyed by pool and summed over every market (range) of that pool on the chain,
    /// would exceed `poolShareMaxBpsOf(poolKey)`: `(poolUnits(poolKey) + L) * 1e4 > poolShareMaxBpsOf(poolKey) * depthUnits`.
    /// @custom:spec REQ-RISK-023, SPEC-CAP-005
    error PoolShareExceeded();

    /// @notice The pledge's value at the served price is below the minimum that applies to it.
    /// @param pledgeUsd `mulDiv(L, price8, 10^d, Floor)`, 8-decimal USD.
    /// @param minPledgeUsd The market's `minPledgeUsd`, or `min(minPledgeUsd, RESCUE_MIN_PLEDGE_USD)` for a rescue
    /// top-up, 8-decimal USD.
    /// @custom:spec REQ-RISK-057, REQ-RISK-064, REQ-RISK-066, REQ-RISK-067, SPEC-CAP-001, Q-230, Q-252
    error BelowMinPledge(uint256 pledgeUsd, uint256 minPledgeUsd);

    /// @notice Liquidation is halted for the account's collateral market: 0 active approved keepers on the chain (Q-400).
    /// @param marketId The first halted market.
    /// @custom:spec REQ-ADAPTER-010, REQ-ADAPTER-054, REQ-RISK-071
    error LiquidationHalted(uint256 marketId);

    /// @notice Some pool token of the account's market, other than a debt asset of the account, has neither a usable
    /// primary nor a usable backup swap route into this debt reserve's asset (REQ-RISK-062, Q-401).
    /// @param debtReserveId The debt reserve.
    /// @custom:spec REQ-RISK-062, REQ-ADAPTER-054, Q-235
    error DebtLiquidationHalted(uint256 debtReserveId);

    /// @notice The Spoke is not approved in the MarketRegistry.
    /// @param spoke The Spoke.
    /// @custom:spec REQ-ADAPTER-011
    error UnknownSpoke(address spoke);

    /// @notice A collateral reserve of the account maps to no Active or Offboarding market on the Spoke.
    /// @param reserveId The reserve.
    /// @custom:spec REQ-ADAPTER-013
    error UnknownCollateral(uint256 reserveId);

    /// @notice An Aave configuration drift check failed.
    /// @param marketId Market identifier, or 0 for a Spoke-wide reason.
    /// @param reason The failed check.
    /// @custom:spec REQ-ADAPTER-014, REQ-ADAPTER-020, REQ-ADAPTER-022, REQ-ADAPTER-057, REQ-ADAPTER-058, REQ-RISK-063, REQ-RISK-069, REQ-RISK-076
    error ConfigDrift(uint256 marketId, DriftReason reason);

    /// @notice A collateral market of the account is not Live.
    /// @param marketId Market identifier.
    /// @param state Its LPOracle price state.
    /// @custom:spec REQ-ADAPTER-015, REQ-ADAPTER-055, REQ-PROXY-063
    error PriceNotLive(uint256 marketId, PriceState state);

    /// @notice A Chainlink input of a collateral market's served price is in the future or older than its
    /// `borrowPriceMaxAge`.
    /// @param feed The Chainlink aggregator proxy.
    /// @param age `block.timestamp - updatedAt` of the source round, seconds.
    /// @custom:spec REQ-ADAPTER-016, REQ-ADAPTER-055, REQ-PROXY-064, SPEC-PROXY-002
    error PriceTooOld(address feed, uint256 age);

    /// @notice A debt reserve's DebtOracle (any asset without a fixed-price source) is not Live, or its served price is in the future or older than
    /// the DebtOracle's `borrowPriceMaxAge()`.
    /// @param debtReserveId The debt reserve.
    /// @param source The reserve's DebtOracle (its Aave price source).
    /// @param age `block.timestamp - servedUpdatedAt`, seconds.
    /// @custom:spec REQ-RISK-061, REQ-PROXY-064, REQ-ADAPTER-055, SPEC-PROXY-002, Q-238, Q-248
    error DebtPriceTooOld(uint256 debtReserveId, address source, uint256 age);

    /// @notice A debt reserve's Aave price source differs from the recorded one.
    /// @param debtReserveId The debt reserve.
    /// @param source The source the AaveOracle reports.
    /// @custom:spec REQ-RISK-061, REQ-PROXY-065, Q-238
    error UnexpectedDebtPriceSource(uint256 debtReserveId, address source);

    /// @notice A collateral reserve of the account is paused on Aave.
    /// @param reserveId The reserve.
    /// @custom:spec REQ-ADAPTER-061, REQ-ADAPTER-062
    error AaveReservePaused(uint256 reserveId);

    /// @notice A debt reserve of the account (or an approved debt reserve, for a new-account pledge) is paused.
    /// @param debtReserveId The debt reserve.
    /// @custom:spec REQ-RISK-019, REQ-RISK-061, REQ-ADAPTER-062
    error DebtReservePaused(uint256 debtReserveId);

    /// @notice A collateral reserve of the account with supplied shares is frozen on Aave at a borrow.
    /// @param reserveId The reserve.
    /// @custom:spec REQ-ADAPTER-019, REQ-PROXY-079, REQ-PROXY-080
    error ReserveFrozen(uint256 reserveId);

    /// @notice Hub added shares differ from added assets for the market's vault-token asset (a new-account pledge, or a
    /// collateral market of the account in a borrow-side check).
    /// @param marketId Market identifier.
    /// @custom:spec REQ-ADAPTER-021, REQ-ADAPTER-058, REQ-RISK-018, REQ-RISK-050
    error HubSharesNotEqualAssets(uint256 marketId);

    /// @notice The health factor after the Spoke call is below the required minimum.
    /// @param healthFactor Health factor read after the Spoke call, WAD.
    /// @param required `max(1e18, hardHealthFloor(marketId), minHealthFactor)`, WAD (Q-398).
    /// @custom:spec REQ-ADAPTER-026, REQ-ADAPTER-059, REQ-PROXY-067, REQ-RISK-068, SPEC-PROXY-001, SPEC-CF-005
    error HealthFactorTooLow(uint256 healthFactor, uint256 required);

    /// @notice A market circuit breaker is tripped (new activity on that market, or by an account holding it).
    /// @param marketId Market identifier.
    /// @param reasons Bitmap of tripped `BreakerReasons`.
    /// @custom:spec REQ-RISK-065, REQ-RISK-073, SPEC-BRK-001, SPEC-BRK-002, SPEC-BRK-003, Q-241
    error BreakerTripped(uint256 marketId, uint32 reasons);

    /// @notice A debt circuit breaker of `(spoke, debtReserveId)` is tripped.
    /// @param spoke The CDP Spoke.
    /// @param debtReserveId The debt reserve.
    /// @param reasons Bitmap of tripped `BreakerReasons`.
    /// @custom:spec REQ-RISK-065, REQ-RISK-073, SPEC-BRK-003, SPEC-BRK-004, Q-241
    error DebtBreakerTripped(address spoke, uint256 debtReserveId, uint32 reasons);

    /// @notice A pledge needed the rescue exemption but is not a rescue top-up.
    /// @param healthFactor The account's health factor before the pledge, WAD (`type(uint256).max` with no debt).
    /// @param usdCharge The pledge's booked charge, 8-decimal USD.
    /// @param restoreBooked The restore amount on the booking basis (SPEC-CAP-003), 8-decimal USD.
    /// @custom:spec REQ-RISK-066, REQ-RISK-074, Q-252
    error NotRescueTopUp(uint256 healthFactor, uint256 usdCharge, uint256 restoreBooked);

    /// @notice The record left by a partial removal with debt is worth less than `minPledgeUsd`.
    /// @param remainingUsd Value of the remaining units at the accepted price, 8-decimal USD.
    /// @param minPledgeUsd The market's minimum, 8-decimal USD.
    /// @custom:spec REQ-RISK-070, REQ-RISK-075, Q-254
    error RecordBelowMinPledge(uint256 remainingUsd, uint256 minPledgeUsd);

    /// @notice `DEFAULT_ADMIN_ROLE` or `APPLICATION_ADMIN` granted to an address other than `TIMELOCK`.
    /// @param role The role.
    /// @param account The rejected grantee.
    /// @custom:spec REQ-RISK-072, Q-259
    error AdminRoleOnlyTimelock(bytes32 role, address account);

    /// @notice The account already holds `AmmConstants.MAX_RECORDS_PER_ACCOUNT_MARKET` (16) open records in its
    /// market. One liquidation of the largest account must fit the per-transaction gas limit: by the gas model of
    /// `SPEC-CHAIN-001`, `G = 1,310,000 + 240,000 × 16 = 5,150,000 <= 16,777,216 / 2`, while an uncapped list of about 125
    /// records needs about 31M gas and could never be liquidated (AMMN-GAS-01).
    /// @param records The account's current record count.
    /// @custom:spec SPEC-CHAIN-001, Q-380, Q-381
    error TooManyRecords(uint256 records);

    /// @notice The AMM integration named by the caller is not the market's integration.
    /// @param marketId The market.
    /// @param integrationId The rejected integration.
    /// @custom:spec REQ-RISK-010, Q-376
    error IntegrationMismatch(uint256 marketId, uint32 integrationId);

    /// @notice Borrow or withdraw-with-debt while the chain's sequencer-uptime feed reports down or is unreadable.
    /// @custom:spec REQ-RISK-081, REQ-RISK-084, REQ-ORACLE-099
    error SequencerDown();

    /// @notice Borrow or withdraw-with-debt during the sequencer grace period after a restart.
    /// @param graceEndsAt First timestamp at which borrowing is allowed again.
    /// @custom:spec REQ-RISK-081, REQ-RISK-084, REQ-ORACLE-099
    error SequencerGrace(uint256 graceEndsAt);

    /// @notice Borrow or withdraw-with-debt while a token's second source (or its active standby) disagrees with the
    /// approved price beyond the deviation band. The market's price state stays Live, so repay, exits and liquidation
    /// continue; either guardian can switch the token to its pre-approved standby with `useStandbySecondSource`.
    /// @param token The underlying token whose second source disagrees.
    /// @custom:spec REQ-ORACLE-100, SPEC-ORC-020, REQ-PSTORE-028, REQ-PSTORE-029, Q-385
    error SecondSourceDisagrees(address token);

    /// @notice `gasleft()` is below `ceil(64 * G / 63) + POST_CALL_GAS` before a gas-limited external call.
    /// @param gasLeft Gas available.
    /// @param required Gas the check requires.
    /// @custom:spec REQ-RISK-089, SPEC-ORC-023
    error InsufficientGas(uint256 gasLeft, uint256 required);

    /// @notice A logic contract given to the implementation constructor reports another kind or other immutables.
    /// @param logic The rejected logic contract.
    /// @custom:spec REQ-RISK-002
    error InvalidLogic(address logic);
}
