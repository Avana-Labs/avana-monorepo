// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ICollateralizationViews} from "../../custody/collateralization/ICollateralizationViews.sol";
import {IAaveV4Hub} from "../../interfaces/external/aave/IAaveV4Hub.sol";
import {IAaveV4Spoke} from "../../interfaces/external/aave/IAaveV4Spoke.sol";
import {IPositionProxy} from "../../proxy/position-proxy/IPositionProxy.sol";
import {PauseReason} from "../../types/PauseReason.sol";
import {PauseState} from "../../types/PauseState.sol";
import {IVaultToken} from "../../vault-token/vault-token/IVaultToken.sol";
import {IMarketRegistryFreeze} from "../market-registry/IMarketRegistryFreeze.sol";
import {IMarketRegistryPause} from "../market-registry/IMarketRegistryPause.sol";
import {IRiskModuleChecks} from "../risk-module/IRiskModuleChecks.sol";
import {AaveAdapterStorage} from "./AaveAdapterStorage.sol";
import {AdapterAccount} from "./types/AdapterAccount.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

/// @title AaveAdapterSteps
/// @notice The account steps the Adapter runs through a proxy's `execute` (supply, borrow, repay, withdrawal and
/// collateral cleanup), the backing-gap reads and the shared gates, used by the three logic contracts.
/// @dev Every amount is checked as a balance delta of the proxy within the step (REQ-PROXY-013), never as an absolute
/// balance, so a token donated to a proxy blocks and changes nothing. Every approval is exact and reset to 0 in the same
/// step. The fixed target and selector set (REQ-PROXY-008): on the Spoke `supply`, `setUsingAsCollateral`, `borrow`,
/// `repay` and `withdraw`; on the vault token and the debt asset `approve(spoke, x)` and `transfer`.
/// @custom:spec REQ-ADAPTER-006, REQ-ADAPTER-007, REQ-ADAPTER-069, REQ-ADAPTER-099, REQ-PROXY-008, REQ-PROXY-010, REQ-PROXY-013, REQ-PROXY-042, REQ-PROXY-043, REQ-PROXY-046, REQ-PROXY-047, REQ-PROXY-087, REQ-PROXY-088, REQ-PROXY-089, SPEC-PROXY-004, SPEC-PROXY-008
// The repay steps run once per debt reserve named in `repayAllAndWithdraw`, a list bounded by the caller and by the
// Spoke's per-account reserve limit (REQ-ADAPTER-051), so any call or revert below may sit inside that loop.
// forge-lint: disable-start(calls-loop, require-revert-in-loop)
// Every call made here runs under the Adapter's Lock, which no callee can take again (REQ-LOCK-007), so none can
// re-enter the Adapter between a call and the event that follows it.
// forge-lint: disable-start(reentrancy-events)
abstract contract AaveAdapterSteps is AaveAdapterStorage {
    using SafeERC20 for IERC20;

    /// @dev The caller's account for a market, or `NoProxy(wallet, marketId)`.
    function _accountOf(
        address wallet,
        uint256 marketId
    ) internal view returns (address proxy, AdapterAccount memory account) {
        proxy = _s().proxyOf[wallet][marketId];
        if (proxy == address(0)) revert NoProxy(wallet, marketId);
        account = _s().accountOf[proxy];
    }

    /// @dev `IntegrationMismatch` unless the position names the vault token's own AMM integration.
    function _checkIntegration(
        uint256 marketId,
        address vaultToken,
        uint32 integrationId
    ) internal view {
        if (IVaultToken(vaultToken).integrationId() != integrationId) {
            revert IntegrationMismatch(marketId, integrationId);
        }
    }

    /// @dev The vault token's reserve on its Spoke, derived from the token's immutables and Aave (REQ-ADAPTER-068).
    function _reserveIdOf(
        address vaultToken
    ) internal view returns (uint256 reserveId) {
        address hub = IVaultToken(vaultToken).hub();
        reserveId =
            IAaveV4Spoke(IVaultToken(vaultToken).spoke()).getReserveId(hub, IAaveV4Hub(hub).getAssetId(vaultToken));
    }

    /// @dev Aave's debt-free test: the account borrows no reserve (REQ-PROXY-034).
    function _borrowCount(
        address spoke,
        address proxy
    ) internal view returns (uint256 count) {
        count = IAaveV4Spoke(spoke).getUserAccountData(proxy).borrowCount;
    }

    /// @dev The pause state of a Hub and, only when Paused, its reason.
    function _pauseOf(
        address hub
    ) internal view returns (PauseState state, PauseReason reason) {
        state = IMarketRegistryPause(_MARKET_REGISTRY).pauseState(hub);
        if (state == PauseState.Paused) reason = IMarketRegistryPause(_MARKET_REGISTRY).pauseReason(hub);
    }

    /// @dev True for a frozen address.
    function _isFrozen(
        address account
    ) internal view returns (bool frozen) {
        frozen = IMarketRegistryFreeze(_MARKET_REGISTRY).isFrozenAddress(account);
    }

    /// @dev Gates of a withdrawal or removal that leaves debt (REQ-PROXY-036): `ApplicationPaused` while the market's
    /// Hub is Paused for either reason, `AddressIsFrozen` for a frozen caller, then the RiskModule's pre-check.
    function _withDebtGates(
        address vaultToken,
        address proxy
    ) internal {
        (PauseState state,) = _pauseOf(IVaultToken(vaultToken).hub());
        if (state == PauseState.Paused) revert ApplicationPaused();
        if (_isFrozen(msg.sender)) revert AddressIsFrozen(msg.sender);
        IRiskModuleChecks(_RISK_MODULE).preWithdrawCheck(proxy);
    }

    // ─── Backing gap (SPEC-PROXY-008) ───

    /// @dev `totalSupply`, `totalCredited` and `pending.units` of a market.
    function _backing(
        address vaultToken
    ) internal view returns (uint256 supply, uint256 credited, uint256 pending) {
        ICollateralizationViews coll = ICollateralizationViews(_COLLATERALIZATION);
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

    /// @dev `BackingMismatch` unless `totalSupply <= totalCredited + pending.units` and the gap is unchanged.
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

    // ─── Account steps through `execute` ───

    /// @dev One call the proxy makes.
    function _exec(
        address proxy,
        address target,
        bytes memory data
    ) internal returns (bytes memory result) {
        result = IPositionProxy(proxy).execute(target, data);
    }

    /// @dev A token call the proxy makes, with SafeERC20's return-value rule (the proxy checks the target has code).
    function _tokenCall(
        address proxy,
        address token,
        bytes memory data
    ) internal {
        bytes memory ret = IPositionProxy(proxy).execute(token, data);
        if (ret.length != 0 && !abi.decode(ret, (bool))) revert SafeERC20.SafeERC20FailedOperation(token);
    }

    /// @dev Supply step (REQ-PROXY-042, REQ-PROXY-043, REQ-PROXY-047): approve exactly `units`, supply, reset the
    /// approval, check the proxy's vault-token balance fell by `units` with no allowance left, the supplied shares rose
    /// by exactly `units`, and the reserve is enabled as collateral.
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

    /// @dev Approve exactly `units`, supply them on the proxy's own account, reset the approval; `BalanceDeltaMismatch`
    /// unless the proxy's vault-token balance fell by exactly `units` and no allowance is left. Returns the shares the
    /// Spoke reports.
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

    /// @dev Withdrawal step (REQ-PROXY-089, REQ-PROXY-037): the Spoke pays `units` to the proxy, checked as both the
    /// returned amount and the proxy's balance delta, and the Adapter burns exactly those units from the proxy.
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

    /// @dev Collateral cleanup (REQ-PROXY-046) of a debt-free account: once its supplied shares are 0 and the reserve
    /// is not paused, disable the reserve as collateral.
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

    /// @dev Moves `amount` of `asset` from `payer` to the proxy and returns what arrived (`UnitsMismatch` if nothing or
    /// more than `amount`), so a fee switched on later repays what arrived (Q-271).
    function _pull(
        address asset,
        address payer,
        address proxy,
        uint256 amount
    ) internal returns (uint256 received) {
        uint256 balanceBefore = IERC20(asset).balanceOf(proxy);
        // `payer` is the repay's `msg.sender` or, in `deleverageRepay`, LP_VAULT_SWAP itself; never a third party.
        // forge-lint: disable-next-line(arbitrary-send-erc20)
        IERC20(asset).safeTransferFrom(payer, proxy, amount);
        uint256 balanceAfter = IERC20(asset).balanceOf(proxy);
        received = balanceAfter > balanceBefore ? balanceAfter - balanceBefore : 0;
        if (received == 0 || received > amount) revert UnitsMismatch(amount, received);
    }

    /// @dev Repay step (REQ-PROXY-088): approve exactly `amount`, repay on the proxy's own account, reset the approval,
    /// refund `amount - spent` to the payer when non-zero, and check the proxy ends `amount` below its start.
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
        // The exact balance and a zero allowance are the step's postcondition (REQ-PROXY-088), not a value a donation sets.
        // forge-lint: disable-next-line(incorrect-strict-equality)
        if (IERC20(asset).balanceOf(proxy) != start - amount || IERC20(asset).allowance(proxy, spoke) != 0) {
            revert BalanceDeltaMismatch();
        }
    }

    /// @dev Repay steps of `repay` and `repayAllAndWithdraw` (SPEC-PROXY-003, SPEC-PROXY-007): reads the live debt `D`;
    /// returns with nothing moved at `D == 0`; a repay-all above its cap reverts before any transfer and otherwise pulls
    /// the cap; a partial repay pulls `min(cap, D)`; Aave takes at most the live debt and the rest returns to `payer`.
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

    /// @dev Pulls `amount` of the reserve's asset from `payer` to the proxy and runs the repay step with what arrived.
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
