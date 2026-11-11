// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {PositionRef} from "../../types/PositionRef.sol";
import {RepayWithCollateralParams} from "./types/RepayWithCollateralParams.sol";

/// @title IAaveAdapterCollateral
/// @notice Borrower entry points that change a pledged record in place: partial removal, re-credit of units added to a
/// pledged position, and repay with collateral. Each acquires the Lock first and releases it last and keeps the
/// market's backing gap unchanged. Token amounts are arrays in the order of the market's `tokens`.
interface IAaveAdapterCollateral {
    /// @notice Removes part of one record's credited units; the position stays in custody.
    /// @dev Order: Lock; `DeadlineExpired`; `ZeroAmount`; `NoProxy`; `IntegrationMismatch`; `LengthMismatch` unless
    /// `minAmounts.length` equals the market's token count; debt-free iff `borrowCount == 0`. With debt only:
    /// `ApplicationPaused` if the market's Hub is Paused, `AddressIsFrozen` for a frozen caller,
    /// `RiskModule.preWithdrawCheck(proxy)`. Read the backing gap; withdraw `units` through `proxy.execute`;
    /// `vaultToken.burn(proxy, units)`; `Collateralization.releasePartial(proxy, vaultToken,
    /// position.positionKey, units, minAmounts)` (reconcile first, `0 < units < credited`, the LPVault unwinds exactly `units` and pays each token
    /// to the depositor of record, each at least its minimum); with debt `RiskModule.checkRemainingRecord`, then
    /// `RiskModule.postHealthCheck` (rescue-excluded, after the debit); backing-gap check; `CollateralReduced`.
    /// Debt-free it reads no MarketRegistry state, pause, freeze, breaker or price.
    /// @param marketId The account's market.
    /// @param position The record's position.
    /// @param units Credited units removed, below the record's credited units after reconciliation.
    /// @param minAmounts Least raw amount of each pool token the removal must return.
    /// @param deadline Last valid `block.timestamp`.
    /// @param minHealthFactor Caller's minimum rescue-excluded health factor after a removal with debt, WAD.
    /// @return amounts Raw amount of each pool token paid to the depositor of record.
    /// @custom:spec REQ-ADAPTER-078, REQ-ADAPTER-069, REQ-ADAPTER-082, REQ-ADAPTER-086, REQ-ADAPTER-089, REQ-RISK-070, SPEC-PROXY-008, WDR-031, Q-254, Q-257, Q-260, Q-376
    function removeLiquidity(
        uint256 marketId,
        PositionRef calldata position,
        uint128 units,
        uint256[] calldata minAmounts,
        uint256 deadline,
        uint256 minHealthFactor
    ) external returns (uint256[] memory amounts);

    /// @notice Credits units added to a pledged position (for concentrated liquidity, Uniswap `increaseLiquidity` on
    /// the custodied position).
    /// @dev Depositor of record only. Order: Lock; `DeadlineExpired`; `NoProxy`; `IntegrationMismatch`;
    /// `ApplicationPaused` under `Paused(MintPathSuspect)` of the market's Hub; `ApplicationFrozen` under Frozen with
    /// `borrowCount == 0`; `requireRescue` under `Paused(General)` or for a frozen caller; read the backing gap;
    /// `Collateralization.recredit(msg.sender, proxy, vaultToken, position.positionKey, topUp, requireRescue)` (reconcile,
    /// `added = live - credited`, top-up checks, new charge basis); `vaultToken.mint(proxy, added)`; supply and enable
    /// through `proxy.execute`; `SupplyIncomplete` unless supplied shares rose by `added`; backing-gap check;
    /// `CollateralRecredited`.
    /// @param marketId The account's market.
    /// @param position The record's position.
    /// @param topUp Integration-encoded LP amount for a fungible-share position; empty for an NFT position, whose
    /// units the depositor adds through the AMM protocol's `increaseLiquidity` before the call.
    /// @param deadline Last valid `block.timestamp`.
    /// @return added Units credited, minted and supplied.
    /// @custom:spec REQ-ADAPTER-079, REQ-ADAPTER-069, REQ-ADAPTER-082, REQ-ADAPTER-083, REQ-ADAPTER-090, REQ-RISK-066, REQ-COLL-037, SPEC-PROXY-008, Q-252, Q-253, Q-254, Q-257, Q-376
    function recredit(
        uint256 marketId,
        PositionRef calldata position,
        bytes calldata topUp,
        uint256 deadline
    ) external returns (uint128 added);

    /// @notice Repays one debt reserve with units released from one record, through LPVaultSwap, with no bonus or Avana
    /// fee; any leftover is paid to the caller in the debt asset.
    /// @dev Order: Lock; `DeadlineExpired`; `ZeroAmount`; `NoProxy`; `ApplicationPaused` if the market's Hub is Paused
    /// with reason `MintPathSuspect` (under `Paused(General)` it stays open: it only reduces debt, AMMN-FLOW-26);
    /// `AddressIsFrozen` for a frozen caller; `IntegrationMismatch`; `UnknownDebtReserve`; `LengthMismatch`;
    /// `NothingToRepay` if the reserve's debt is 0; read `hfBefore`, the backing gap and supplied shares; open the
    /// transient session; call `LP_VAULT_SWAP.deleverage(DeleverageRequest)`, which flash-borrows the debt asset through
    /// the chain's IFlashSource and calls back `deleverageRepay` then `deleverageRelease`; `NoDeleverageSession` unless
    /// both ran; `UnitsMismatch` unless supplied shares fell by `units`; while debt remains,
    /// `HealthFactorNotImproved` unless `hfAfter >= max(hfBefore, minHealthFactor)`; backing-gap check; close the
    /// session; `RepaidWithCollateral`. Reads no circuit breaker; open under Frozen.
    /// @param p The market, record, units, debt reserve, bounds, deadline and minimum health factor.
    /// @return debtRepaid Debt repaid, base units of the debt asset.
    /// @return debtAssetToWallet Debt asset sent to the caller after the flash loan and its premium.
    /// @custom:spec REQ-ADAPTER-080, REQ-ADAPTER-067, REQ-ADAPTER-069, REQ-ADAPTER-082, REQ-ADAPTER-091, SPEC-PROXY-008, SPEC-PROXY-009, REP-013, INV-089, Q-242, Q-255, Q-257, Q-376, Q-379
    function repayWithCollateral(
        RepayWithCollateralParams calldata p
    ) external returns (uint256 debtRepaid, uint256 debtAssetToWallet);
}
