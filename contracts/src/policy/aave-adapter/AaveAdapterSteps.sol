// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ICollateralization} from "../../custody/collateralization/ICollateralization.sol";
import {IAaveV4Hub} from "../../interfaces/external/aave/IAaveV4Hub.sol";
import {IAaveV4Spoke} from "../../interfaces/external/aave/IAaveV4Spoke.sol";
import {IPositionProxy} from "../../proxy/position-proxy/IPositionProxy.sol";
import {PauseReason, PauseState} from "../../types/MarketTypes.sol";
import {IVaultToken} from "../../vault-token/vault-token/IVaultToken.sol";
import {IMarketRegistry} from "../market-registry/IMarketRegistry.sol";
import {IRiskModule} from "../risk-module/IRiskModule.sol";
import {AaveAdapterStorage} from "./AaveAdapterStorage.sol";
import {AdapterAccount} from "./types/AaveAdapterTypes.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

/// @title AaveAdapterSteps
/// @notice Account steps the Adapter runs through a proxy's `execute`, the backing-gap reads and the shared gates.
/// @dev Amounts are checked as balance deltas within each step; every approval is exact and reset to 0.
// The repay steps may run inside `repayAllAndWithdraw`'s loop, bounded by the caller and the Spoke's reserve limit.
// forge-lint: disable-start(calls-loop, require-revert-in-loop)
// Every call here runs under the Adapter's Lock, so no callee can re-enter before the following event.
// forge-lint: disable-start(reentrancy-events)
abstract contract AaveAdapterSteps is AaveAdapterStorage {
    using SafeERC20 for IERC20;

    function _accountOf(
        address wallet,
        uint256 marketId
    ) internal view returns (address proxy, AdapterAccount memory account) {
        proxy = _s().proxyOf[wallet][marketId];
        if (proxy == address(0)) revert NoProxy(wallet, marketId);
        account = _s().accountOf[proxy];
    }

    function _checkIntegration(
        uint256 marketId,
        address vaultToken,
        uint32 integrationId
    ) internal view {
        if (IVaultToken(vaultToken).integrationId() != integrationId) {
            revert IntegrationMismatch(marketId, integrationId);
        }
    }

    function _reserveIdOf(
        address vaultToken
    ) internal view returns (uint256 reserveId) {
        address hub = IVaultToken(vaultToken).hub();
        reserveId =
            IAaveV4Spoke(IVaultToken(vaultToken).spoke()).getReserveId(hub, IAaveV4Hub(hub).getAssetId(vaultToken));
    }

    function _borrowCount(
        address spoke,
        address proxy
    ) internal view returns (uint256 count) {
        count = IAaveV4Spoke(spoke).getUserAccountData(proxy).borrowCount;
    }

    function _pauseOf(
        address hub
    ) internal view returns (PauseState state, PauseReason reason) {
        state = IMarketRegistry(_MARKET_REGISTRY).pauseState(hub);
        if (state == PauseState.Paused) reason = IMarketRegistry(_MARKET_REGISTRY).pauseReason(hub);
    }

    function _isFrozen(
        address account
    ) internal view returns (bool frozen) {
        frozen = IMarketRegistry(_MARKET_REGISTRY).isFrozenAddress(account);
    }

    function _withDebtGates(
        address vaultToken,
        address proxy
    ) internal {
        (PauseState state,) = _pauseOf(IVaultToken(vaultToken).hub());
        if (state == PauseState.Paused) revert ApplicationPaused();
        if (_isFrozen(msg.sender)) revert AddressIsFrozen(msg.sender);
        IRiskModule(_RISK_MODULE).preWithdrawCheck(proxy);
    }

    function _backing(
        address vaultToken
    ) internal view returns (uint256 supply, uint256 credited, uint256 pending) {
        ICollateralization coll = ICollateralization(_COLLATERALIZATION);
        supply = IVaultToken(vaultToken).totalSupply();
        credited = coll.getTotalCredited(vaultToken);
        pending = coll.getPending(vaultToken).units;
    }

    /// @dev The gap `G = totalCredited + pending.units - totalSupply`, read before the call's first change.
    function _gap(
        address vaultToken
    ) internal view returns (int256 gap) {
        (uint256 supply, uint256 credited, uint256 pending) = _backing(vaultToken);
        gap = SafeCast.toInt256(credited) + SafeCast.toInt256(pending) - SafeCast.toInt256(supply);
    }

    function _checkGap(
        address vaultToken,
        int256 gapBefore
    ) internal view {
        (uint256 supply, uint256 credited, uint256 pending) = _backing(vaultToken);
        if (
            supply > credited + pending
                || SafeCast.toInt256(credited) + SafeCast.toInt256(pending) - SafeCast.toInt256(supply) != gapBefore
        ) revert BackingMismatch(supply, credited, pending);
    }

    function _exec(
        address proxy,
        address target,
        bytes memory data
    ) internal returns (bytes memory result) {
        result = IPositionProxy(proxy).execute(target, data);
    }

    /// @dev A token call the proxy makes, with SafeERC20's return-value rule.
    function _tokenCall(
        address proxy,
        address token,
        bytes memory data
    ) internal {
        bytes memory ret = IPositionProxy(proxy).execute(token, data);
        if (ret.length != 0 && !abi.decode(ret, (bool))) revert SafeERC20.SafeERC20FailedOperation(token);
    }

    function _supply(
        address proxy,
        address spoke,
        address vaultToken,
        uint256 reserveId,
        uint256 marketId,
        uint256 units
    ) internal {
        uint256 sharesBefore = IAaveV4Spoke(spoke).getUserSuppliedShares(reserveId, proxy);
        uint256 shares = _supplyExact(proxy, spoke, vaultToken, reserveId, units);
        IAaveV4Spoke sp = IAaveV4Spoke(spoke);
        uint256 sharesAfter = sp.getUserSuppliedShares(reserveId, proxy);
        if (sharesAfter < sharesBefore || sharesAfter - sharesBefore != units) revert SupplyIncomplete();
        // Only the collateral flag matters here; the borrowing flag is Aave's.
        // forge-lint: disable-next-line(unused-return)
        (bool enabled,) = sp.getUserReserveStatus(reserveId, proxy);
        if (!enabled) {
            _exec(proxy, spoke, abi.encodeCall(IAaveV4Spoke.setUsingAsCollateral, (reserveId, true, proxy)));
            // forge-lint: disable-next-line(unused-return)
            (enabled,) = sp.getUserReserveStatus(reserveId, proxy);
            if (!enabled) revert CollateralNotEnabled(reserveId);
        }
        emit CollateralSupplied(proxy, marketId, units, shares);
    }

    function _supplyExact(
        address proxy,
        address spoke,
        address vaultToken,
        uint256 reserveId,
        uint256 units
    ) private returns (uint256 shares) {
        uint256 balanceBefore = IERC20(vaultToken).balanceOf(proxy);
        _tokenCall(proxy, vaultToken, abi.encodeCall(IERC20.approve, (spoke, units)));
        bytes memory ret = _exec(proxy, spoke, abi.encodeCall(IAaveV4Spoke.supply, (reserveId, units, proxy)));
        _tokenCall(proxy, vaultToken, abi.encodeCall(IERC20.approve, (spoke, 0)));
        uint256 balanceAfter = IERC20(vaultToken).balanceOf(proxy);
        if (
            balanceAfter > balanceBefore || balanceBefore - balanceAfter != units
                || IERC20(vaultToken).allowance(proxy, spoke) != 0
        ) revert BalanceDeltaMismatch();
        (shares,) = abi.decode(ret, (uint256, uint256));
    }

    function _withdrawAndBurn(
        address proxy,
        address spoke,
        address vaultToken,
        uint256 reserveId,
        uint256 units
    ) internal {
        uint256 balanceBefore = IERC20(vaultToken).balanceOf(proxy);
        bytes memory ret = _exec(proxy, spoke, abi.encodeCall(IAaveV4Spoke.withdraw, (reserveId, units, proxy)));
        (, uint256 withdrawn) = abi.decode(ret, (uint256, uint256));
        if (withdrawn != units) revert UnitsMismatch(units, withdrawn);
        uint256 balanceAfter = IERC20(vaultToken).balanceOf(proxy);
        uint256 received = balanceAfter > balanceBefore ? balanceAfter - balanceBefore : 0;
        if (received != units) revert UnitsMismatch(units, received);
        IVaultToken(vaultToken).burn(proxy, units);
    }

    function _cleanup(
        address proxy,
        address spoke,
        uint256 reserveId
    ) internal {
        IAaveV4Spoke sp = IAaveV4Spoke(spoke);
        if (sp.getUserSuppliedShares(reserveId, proxy) != 0) return;
        // Only the collateral flag matters here; the account is debt-free.
        // forge-lint: disable-next-line(unused-return)
        (bool enabled,) = sp.getUserReserveStatus(reserveId, proxy);
        if (!enabled || sp.getReserveConfig(reserveId).paused) return;
        _exec(proxy, spoke, abi.encodeCall(IAaveV4Spoke.setUsingAsCollateral, (reserveId, false, proxy)));
        emit CollateralDisabled(proxy, reserveId);
    }

    /// @dev Returns what arrived, so a fee-charging asset repays what arrived.
    function _pull(
        address asset,
        address payer,
        address proxy,
        uint256 amount
    ) internal returns (uint256 received) {
        uint256 balanceBefore = IERC20(asset).balanceOf(proxy);
        // `payer` is the repay's `msg.sender` or LPVaultSwap itself, never a third party.
        // forge-lint: disable-next-line(arbitrary-send-erc20)
        IERC20(asset).safeTransferFrom(payer, proxy, amount);
        uint256 balanceAfter = IERC20(asset).balanceOf(proxy);
        received = balanceAfter > balanceBefore ? balanceAfter - balanceBefore : 0;
        if (received == 0 || received > amount) revert UnitsMismatch(amount, received);
    }

    function _repayStep(
        address proxy,
        address spoke,
        address asset,
        uint256 debtReserveId,
        uint256 amount,
        address payer
    ) internal returns (uint256 spent) {
        uint256 start = IERC20(asset).balanceOf(proxy);
        _tokenCall(proxy, asset, abi.encodeCall(IERC20.approve, (spoke, amount)));
        _exec(proxy, spoke, abi.encodeCall(IAaveV4Spoke.repay, (debtReserveId, amount, proxy)));
        uint256 afterRepay = IERC20(asset).balanceOf(proxy);
        if (afterRepay > start || start - afterRepay > amount) revert BalanceDeltaMismatch();
        spent = start - afterRepay;
        _tokenCall(proxy, asset, abi.encodeCall(IERC20.approve, (spoke, 0)));
        uint256 refund = amount - spent;
        if (refund != 0) _tokenCall(proxy, asset, abi.encodeCall(IERC20.transfer, (payer, refund)));
        // Exact end balance and zero allowance are the step's postcondition.
        // forge-lint: disable-next-line(incorrect-strict-equality)
        if (IERC20(asset).balanceOf(proxy) != start - amount || IERC20(asset).allowance(proxy, spoke) != 0) {
            revert BalanceDeltaMismatch();
        }
        _creditSpeed(proxy, debtReserveId, spent);
    }

    function _creditSpeed(
        address proxy,
        uint256 debtReserveId,
        uint256 spent
    ) internal {
        if (spent == 0) return;
        uint256 left = gasleft();
        if (left < SPEED_CREDIT_FLOOR) revert InsufficientGas(left, SPEED_CREDIT_FLOOR);
        // A failed credit only leaves the window fuller than the net debt; it must not block the repay.
        // solhint-disable-next-line no-empty-blocks
        try IRiskModule(_RISK_MODULE).creditRepay{gas: SPEED_CREDIT_GAS}(proxy, debtReserveId, spent) {} catch {}
    }

    /// @dev Moves nothing at zero debt; a repay-all above its cap reverts before any transfer.
    function _repayDebt(
        address payer,
        address proxy,
        address spoke,
        uint256 debtReserveId,
        uint256 maxRepaySpend,
        bool repayAll
    ) internal returns (uint256 spent, uint256 debtAfter, bool moved) {
        uint256 debt = IAaveV4Spoke(spoke).getUserTotalDebt(debtReserveId, proxy);
        if (debt == 0) return (0, 0, false);
        if (repayAll && debt > maxRepaySpend) revert RepayExceedsMax(debt, maxRepaySpend);
        spent =
            _pullAndRepay(payer, proxy, spoke, debtReserveId, repayAll || maxRepaySpend < debt ? maxRepaySpend : debt);
        debtAfter = IAaveV4Spoke(spoke).getUserTotalDebt(debtReserveId, proxy);
        if (repayAll && debtAfter != 0) revert DebtRemaining(debtReserveId, debtAfter);
        moved = true;
    }

    function _pullAndRepay(
        address payer,
        address proxy,
        address spoke,
        uint256 debtReserveId,
        uint256 amount
    ) internal returns (uint256 spent) {
        address asset = IAaveV4Spoke(spoke).getReserve(debtReserveId).underlying;
        uint256 received = _pull(asset, payer, proxy, amount);
        spent = _repayStep(proxy, spoke, asset, debtReserveId, received, payer);
    }
}
// forge-lint: disable-end(reentrancy-events)
// forge-lint: disable-end(calls-loop, require-revert-in-loop)
