// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ICollateralizationAdapter} from "../../custody/collateralization/ICollateralizationAdapter.sol";
import {ICollateralizationDebtMark} from "../../custody/collateralization/ICollateralizationDebtMark.sol";
import {ICollateralizationUser} from "../../custody/collateralization/ICollateralizationUser.sol";
import {IAaveV4Spoke} from "../../interfaces/external/aave/IAaveV4Spoke.sol";
import {PositionRef} from "../../types/PositionRef.sol";
import {IRiskModuleChecks} from "../risk-module/IRiskModuleChecks.sol";
import {AaveAdapterSteps} from "./AaveAdapterSteps.sol";
import {AaveAdapterStorage} from "./AaveAdapterStorage.sol";
import {IAaveAdapterLogic} from "./IAaveAdapterLogic.sol";
import {AaveAdapterImmutables} from "./types/AaveAdapterImmutables.sol";
import {AdapterAccount} from "./types/AdapterAccount.sol";

/// @title AaveAdapterExitLogic
/// @notice Bodies of the exits of an account: `withdraw`, `repayAllAndWithdraw`, `collectFees`, `releaseZeroCredit` and
/// `refreshDebtMark`.
/// @dev Reached only by `delegatecall` from the AaveAdapter router (`IAaveAdapterLogic`); every body takes the Lock
/// first and releases it last. Only a withdrawal that leaves debt reads the MarketRegistry (the Hub's pause state and
/// the caller's freeze) and the RiskModule; the debt-free withdrawal, `repayAllAndWithdraw`, fee collection, zero-credit
/// release and the debt mark read only the Adapter's own binding, the vault token's immutables and Aave (Q-260).
/// @custom:spec REQ-ADAPTER-047, REQ-ADAPTER-069, REQ-ADAPTER-071, REQ-ADAPTER-086, REQ-ADAPTER-096, REQ-ADAPTER-097, REQ-ADAPTER-104, REQ-PROXY-033, REQ-PROXY-034, REQ-PROXY-035, REQ-PROXY-036, REQ-PROXY-037, REQ-PROXY-038, REQ-PROXY-039, REQ-PROXY-046, REQ-PROXY-048, REQ-LOCK-007
// Each function carries the body of a selector declared in an IAaveAdapter piece that the router implements; this
// contract inherits no piece, since each piece also declares functions another logic contract serves.
// solhint-disable comprehensive-interface
// Every call made here runs under the Adapter's Lock, which no callee can take again, so none can re-enter the Adapter
// between a call and the event that follows it.
// forge-lint: disable-start(reentrancy-events)
contract AaveAdapterExitLogic is AaveAdapterSteps, IAaveAdapterLogic {
    /// @notice Fixes the implementation immutables; they must equal the router's.
    /// @param im The chain's dependencies.
    /// @custom:spec REQ-ADAPTER-004, REQ-ADAPTER-074
    constructor(
        AaveAdapterImmutables memory im
    ) AaveAdapterStorage(im) {}

    /// @inheritdoc IAaveAdapterLogic
    /// @custom:spec REQ-ADAPTER-004
    function logicConfig() external view override returns (bytes32 kind, bytes32 immutablesHash) {
        return (keccak256("AaveAdapterExitLogic"), _IMMUTABLES_HASH);
    }

    // ─── Withdrawals ───

    /// @notice Body of `withdraw` (REQ-PROXY-033).
    /// @custom:spec REQ-PROXY-033, REQ-PROXY-034, REQ-PROXY-035, REQ-PROXY-036, REQ-PROXY-037, REQ-PROXY-038, REQ-PROXY-039, REQ-ADAPTER-069
    function withdraw(
        uint256 marketId,
        PositionRef calldata position,
        uint256 units,
        uint256 deadline,
        uint256 minHealthFactor
    ) external {
        _onlyDelegated();
        _acquire();
        if (block.timestamp > deadline) revert DeadlineExpired(deadline);
        (address proxy, AdapterAccount memory account) = _accountOf(msg.sender, marketId);
        if (units == 0) revert ZeroAmount();
        _checkIntegration(marketId, account.vaultToken, position.integrationId);
        bool debtFree = _borrowCount(account.spoke, proxy) == 0;
        if (!debtFree) _withDebtGates(account.vaultToken, proxy);
        _withdrawRecord(proxy, account, position.positionKey, units, debtFree, minHealthFactor);
        _release();
    }

    /// @notice Body of `repayAllAndWithdraw` (REQ-ADAPTER-071): repays each named reserve in full, requires the
    /// account debt-free on Aave, then makes a debt-free withdrawal; reads no MarketRegistry state.
    /// @custom:spec REQ-ADAPTER-071, REQ-ADAPTER-076, REQ-ADAPTER-085, REQ-PROXY-071, REQ-ADAPTER-047
    function repayAllAndWithdraw(
        uint256 marketId,
        PositionRef calldata position,
        uint256 units,
        uint256[] calldata debtReserveIds,
        uint256[] calldata maxRepaySpends,
        uint256 deadline
    ) external {
        _onlyDelegated();
        _acquire();
        if (block.timestamp > deadline) revert DeadlineExpired(deadline);
        if (debtReserveIds.length != maxRepaySpends.length) revert LengthMismatch();
        (address proxy, AdapterAccount memory account) = _accountOf(msg.sender, marketId);
        if (units == 0) revert ZeroAmount();
        _checkIntegration(marketId, account.vaultToken, position.integrationId);
        for (uint256 i = 0; i < debtReserveIds.length; ++i) {
            (uint256 spent, uint256 debtAfter, bool moved) =
                _repayDebt(msg.sender, proxy, account.spoke, debtReserveIds[i], maxRepaySpends[i], true);
            if (moved) emit Repaid(msg.sender, msg.sender, marketId, debtReserveIds[i], spent, debtAfter, true);
        }
        if (_borrowCount(account.spoke, proxy) != 0) _revertDebtRemaining(proxy, account.spoke);
        ICollateralizationDebtMark(_COLLATERALIZATION).markDebtFree(proxy);
        _withdrawRecord(proxy, account, position.positionKey, units, true, 0);
        _release();
    }

    /// @dev `DebtRemaining(r, d)` for the first reserve the Spoke reports borrowed (REQ-PROXY-071); runs only on the
    /// failure path, bounded by the Spoke's reserve count (REQ-ADAPTER-051).
    function _revertDebtRemaining(
        address proxy,
        address spoke
    ) private view {
        IAaveV4Spoke sp = IAaveV4Spoke(spoke);
        uint256 count = sp.getReserveCount();
        uint256 r = 0;
        for (; r < count; ++r) {
            // Bounded by the Spoke's reserve count, on the failure path only (REQ-ADAPTER-051); only the borrow flag matters.
            // forge-lint: disable-next-line(unused-return, calls-loop)
            (, bool borrowing) = sp.getUserReserveStatus(r, proxy);
            if (borrowing) break;
        }
        revert DebtRemaining(r, r < count ? sp.getUserTotalDebt(r, proxy) : 0);
    }

    /// @dev Withdrawal of one record (REQ-PROXY-037, REQ-PROXY-038): backing gap, withdrawal and burn, Collateralization
    /// `release` (reconcile, debit, position to the depositor), cleanup when debt-free or the health check with debt,
    /// backing check, `CollateralWithdrawn`.
    function _withdrawRecord(
        address proxy,
        AdapterAccount memory account,
        bytes32 positionKey,
        uint256 units,
        bool debtFree,
        uint256 minHealthFactor
    ) private {
        uint256 reserveId = _reserveIdOf(account.vaultToken);
        int256 gapBefore = _gap(account.vaultToken);
        _withdrawAndBurn(proxy, account.spoke, account.vaultToken, reserveId, units);
        ICollateralizationAdapter(_COLLATERALIZATION).release(proxy, account.vaultToken, positionKey, units);
        uint256 hf = type(uint256).max;
        if (debtFree) _cleanup(proxy, account.spoke, reserveId);
        else hf = IRiskModuleChecks(_RISK_MODULE).postHealthCheck(proxy, minHealthFactor);
        _checkGap(account.vaultToken, gapBefore);
        emit CollateralWithdrawn(msg.sender, account.marketId, account.vaultToken, positionKey, units, !debtFree, hf);
    }

    // ─── Fees, zero-credit release and the debt mark ───

    /// @notice Body of `collectFees` (REQ-ADAPTER-096).
    /// @custom:spec REQ-ADAPTER-096, REQ-ADAPTER-101
    function collectFees(
        uint256 marketId,
        PositionRef calldata position,
        uint256 deadline
    ) external returns (uint256[] memory fees) {
        _onlyDelegated();
        _acquire();
        address vaultToken = _depositorToken(marketId, position, deadline);
        fees = ICollateralizationUser(_COLLATERALIZATION).collectFees(msg.sender, vaultToken, position.positionKey);
        _release();
    }

    /// @notice Body of `releaseZeroCredit` (REQ-ADAPTER-097).
    /// @custom:spec REQ-ADAPTER-097, REQ-ADAPTER-101
    function releaseZeroCredit(
        uint256 marketId,
        PositionRef calldata position,
        uint256 deadline
    ) external {
        _onlyDelegated();
        _acquire();
        address vaultToken = _depositorToken(marketId, position, deadline);
        ICollateralizationUser(_COLLATERALIZATION).releaseZeroCredit(msg.sender, vaultToken, position.positionKey);
        _release();
    }

    /// @notice Body of `refreshDebtMark` (REQ-ADAPTER-104): anyone, moves nothing, reads no Avana stop.
    /// @custom:spec REQ-ADAPTER-104, REQ-COLL-040
    function refreshDebtMark(
        address proxy
    ) external {
        _onlyDelegated();
        _acquire();
        ICollateralizationDebtMark(_COLLATERALIZATION).markDebtFree(proxy);
        _release();
    }

    /// @dev Deadline, the caller's account for the market and the position's integration; returns its vault token.
    function _depositorToken(
        uint256 marketId,
        PositionRef calldata position,
        uint256 deadline
    ) private view returns (address vaultToken) {
        if (block.timestamp > deadline) revert DeadlineExpired(deadline);
        (, AdapterAccount memory account) = _accountOf(msg.sender, marketId);
        vaultToken = account.vaultToken;
        _checkIntegration(marketId, vaultToken, position.integrationId);
    }
}
// forge-lint: disable-end(reentrancy-events)
