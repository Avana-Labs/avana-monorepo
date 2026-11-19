// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAaveV4Spoke} from "../../interfaces/external/aave/IAaveV4Spoke.sol";
import {ICollateralization} from "../../legacy/ICollateralization.sol";
import {PositionRef} from "../../types/PositionTypes.sol";
import {IRiskModule} from "../risk-module/IRiskModule.sol";
import {AaveAdapterSteps} from "./AaveAdapterSteps.sol";
import {AaveAdapterStorage} from "./AaveAdapterStorage.sol";
import {IAaveAdapterLogic} from "./IAaveAdapterLogic.sol";
import {AaveAdapterImmutables, AdapterAccount} from "./types/AaveAdapterTypes.sol";

/// @title AaveAdapterExitLogic
/// @notice Bodies of `withdraw`, `repayAllAndWithdraw`, `collectFees`, `releaseZeroCredit` and `refreshDebtMark`.
// The router implements the IAaveAdapter pieces; this contract only carries bodies.
// solhint-disable comprehensive-interface
// Every call here runs under the Adapter's Lock, so no callee can re-enter before the following event.
// forge-lint: disable-start(reentrancy-events)
contract AaveAdapterExitLogic is AaveAdapterSteps, IAaveAdapterLogic {
    constructor(
        AaveAdapterImmutables memory im
    ) AaveAdapterStorage(im) {}

    /// @inheritdoc IAaveAdapterLogic
    function logicConfig() external view override returns (bytes32 kind, bytes32 immutablesHash) {
        return (keccak256("AaveAdapterExitLogic"), _IMMUTABLES_HASH);
    }

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
        if (!debtFree) IRiskModule(_RISK_MODULE).preWithdrawCheck(proxy);
        _withdrawRecord(proxy, account, position.positionKey, units, debtFree, minHealthFactor);
        _release();
    }

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
        ICollateralization(_COLLATERALIZATION).markDebtFree(proxy);
        _withdrawRecord(proxy, account, position.positionKey, units, true, 0);
        _release();
    }

    /// @dev Reverts `DebtRemaining` for the first reserve the Spoke reports borrowed; runs only on the failure path.
    function _revertDebtRemaining(
        address proxy,
        address spoke
    ) private view {
        IAaveV4Spoke sp = IAaveV4Spoke(spoke);
        uint256 count = sp.getReserveCount();
        uint256 r = 0;
        for (; r < count; ++r) {
            // Bounded by the Spoke's reserve count; only the borrow flag matters.
            // forge-lint: disable-next-line(unused-return, calls-loop)
            (, bool borrowing) = sp.getUserReserveStatus(r, proxy);
            if (borrowing) break;
        }
        revert DebtRemaining(r, r < count ? sp.getUserTotalDebt(r, proxy) : 0);
    }

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
        ICollateralization(_COLLATERALIZATION).release(proxy, account.vaultToken, positionKey, units);
        uint256 hf = type(uint256).max;
        if (debtFree) _cleanup(proxy, account.spoke, reserveId);
        else hf = IRiskModule(_RISK_MODULE).postHealthCheck(proxy, minHealthFactor);
        _checkGap(account.vaultToken, gapBefore);
        emit CollateralWithdrawn(msg.sender, account.marketId, account.vaultToken, positionKey, units, !debtFree, hf);
    }

    function collectFees(
        uint256 marketId,
        PositionRef calldata position,
        uint256 deadline
    ) external returns (uint256[] memory fees) {
        _onlyDelegated();
        _acquire();
        address vaultToken = _depositorToken(marketId, position, deadline);
        fees = ICollateralization(_COLLATERALIZATION).collectFees(msg.sender, vaultToken, position.positionKey);
        _release();
    }

    function releaseZeroCredit(
        uint256 marketId,
        PositionRef calldata position,
        uint256 deadline
    ) external {
        _onlyDelegated();
        _acquire();
        address vaultToken = _depositorToken(marketId, position, deadline);
        ICollateralization(_COLLATERALIZATION).releaseZeroCredit(msg.sender, vaultToken, position.positionKey);
        _release();
    }

    function refreshDebtMark(
        address proxy
    ) external {
        _onlyDelegated();
        _acquire();
        ICollateralization(_COLLATERALIZATION).markDebtFree(proxy);
        _release();
    }

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
