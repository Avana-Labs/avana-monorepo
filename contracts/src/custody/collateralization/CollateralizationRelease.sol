// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAmmIntegration} from "../../amm/IAmmIntegration.sol";
import {IRiskModuleChecks} from "../../policy/risk-module/IRiskModuleChecks.sol";
import {CollateralizationLedger} from "./CollateralizationLedger.sol";
import {ICollateralizationAdapter} from "./ICollateralizationAdapter.sol";
import {ICollateralizationUser} from "./ICollateralizationUser.sol";
import {BackingRecord} from "./types/BackingRecord.sol";

// External calls go only to known protocol contracts while a Lock member holds the Lock, so nothing can re-enter.
// forge-lint: disable-start(reentrancy-events)
// forge-lint: disable-start(reentrancy-no-eth)
/// @title CollateralizationRelease
/// @notice Adapter path, exit side: release, partial removal, deleverage release, zero-credit release and fees.
/// @dev Exits read no pause, price or policy. The Adapter, not this contract, checks its own burn.
abstract contract CollateralizationRelease is
    CollateralizationLedger,
    ICollateralizationAdapter,
    ICollateralizationUser
{
    /// @inheritdoc ICollateralizationAdapter
    function release(
        address proxy,
        address vaultToken,
        bytes32 positionKey,
        uint256 units
    ) external override {
        (Ctx memory c, uint256 id, BackingRecord storage r) = _prepareExit(vaultToken, positionKey, proxy, units, 0);
        if (units == 0 || units != r.credited) revert UnitsMismatch();
        _creditSpeed(c.marketId, _windowed(r, _debitRecord(c, r, units)));
        emit CollateralReleased(id, positionKey, r.depositor, proxy, vaultToken, units);
        _close(c, id, r);
        _returnPosition(c, positionKey);
    }

    /// @inheritdoc ICollateralizationAdapter
    function releasePartial(
        address proxy,
        address vaultToken,
        bytes32 positionKey,
        uint128 units,
        uint256[] calldata minAmounts
    ) external override returns (uint128 remaining, uint256[] memory amounts) {
        (Ctx memory c, uint256 id, BackingRecord storage r) =
            _prepareExit(vaultToken, positionKey, proxy, units, minAmounts.length + 1);
        uint128 credited = r.credited;
        if (units == 0) revert UnitsMismatch();
        if (units >= credited) revert PartialRemovalTooLarge(units, credited);
        uint256 released = _debitRecord(c, r, units);
        _creditSpeed(c.marketId, _windowed(r, released));
        remaining = credited - units;
        emit RecordReduced(id, units, released);
        address depositor = r.depositor;
        uint256[] memory before = _balances(c, depositor);
        // The amounts returned are the depositor's measured balance deltas, not the LPVault's report.
        // forge-lint: disable-next-line(unused-return)
        IAmmIntegration(c.lpVault).releaseToDepositor(positionKey, units, minAmounts);
        amounts = _received(c, depositor, before);
    }

    /// @inheritdoc ICollateralizationAdapter
    function releaseForDeleverage(
        address proxy,
        address vaultToken,
        bytes32 positionKey,
        uint128 units,
        uint256[] calldata minAmounts
    ) external override returns (uint256[] memory amounts, bool closed) {
        (Ctx memory c, uint256 id, BackingRecord storage r) =
            _prepareExit(vaultToken, positionKey, proxy, units, minAmounts.length + 1);
        if (units == 0 || units > r.credited) revert UnitsMismatch();
        uint256 released = _debitRecord(c, r, units);
        _creditSpeed(c.marketId, _windowed(r, released));
        closed = r.credited == 0;
        emit RecordReduced(id, units, released);
        if (closed) {
            emit CollateralReleased(id, positionKey, r.depositor, proxy, vaultToken, units);
            _close(c, id, r);
        }
        amounts = _unwind(c, positionKey, units, minAmounts, _LP_VAULT_SWAP);
        if (closed) _returnPosition(c, positionKey);
    }

    /// @inheritdoc ICollateralizationUser
    function releaseZeroCredit(
        address depositor,
        address vaultToken,
        bytes32 positionKey
    ) external override {
        _onlyAdapter();
        Ctx memory c = _load(vaultToken);
        (uint256 id, BackingRecord storage r) = _depositorRecord(c, positionKey, depositor);
        address proxy = r.proxy;
        _withReserve(c);
        _reconcile(c, proxy, _supplied(c, proxy));
        if (r.credited != 0) revert RecordHasCredit();
        emit CollateralReleased(id, positionKey, depositor, proxy, vaultToken, 0);
        _close(c, id, r);
        _returnPosition(c, positionKey);
    }

    /// @inheritdoc ICollateralizationUser
    function collectFees(
        address depositor,
        address vaultToken,
        bytes32 positionKey
    ) external override returns (uint256[] memory amounts) {
        _onlyAdapter();
        Ctx memory c = _load(vaultToken);
        _depositorRecord(c, positionKey, depositor);
        amounts = IAmmIntegration(c.lpVault).collectFees(positionKey, depositor);
    }

    /// @dev `lengthPlusOne` is 0 for `release`; otherwise `minAmounts.length + 1`, and the pool lock is checked.
    function _prepareExit(
        address vaultToken,
        bytes32 positionKey,
        address proxy,
        uint256 units,
        uint256 lengthPlusOne
    ) private returns (Ctx memory c, uint256 id, BackingRecord storage r) {
        _onlyAdapter();
        c = _load(vaultToken);
        (id, r) = _record(c, positionKey);
        if (r.proxy != proxy) revert NotRecordProxy();
        _checkMarket(c, r);
        if (lengthPlusOne != 0) {
            _checkLength(c, lengthPlusOne - 1);
            _checkReadSafe(c);
        }
        _withReserve(c);
        _reconcile(c, proxy, _supplied(c, proxy) + units);
    }

    /// @dev The part of `released` USD the pledge window was charged, rounded down.
    function _windowed(
        BackingRecord storage r,
        uint256 released
    ) private view returns (uint256) {
        return released * r.windowedBps / WINDOW_BPS;
    }

    /// @notice Gives the booked value a withdrawal released back to the market's pledge-speed window.
    function _creditSpeed(
        uint256 marketId,
        uint256 usd
    ) private {
        if (usd == 0) return;
        uint256 left = gasleft();
        if (left < SPEED_CREDIT_FLOOR) revert InsufficientGas(left, SPEED_CREDIT_FLOOR);
        // A failed credit only leaves the window fuller than the net pledges; it must not block the exit.
        // solhint-disable-next-line no-empty-blocks
        try IRiskModuleChecks(_RISK_MODULE).creditWithdraw{gas: SPEED_CREDIT_GAS}(marketId, usd) {} catch {}
    }

    function _depositorRecord(
        Ctx memory c,
        bytes32 positionKey,
        address depositor
    ) private view returns (uint256 id, BackingRecord storage r) {
        (id, r) = _record(c, positionKey);
        _checkMarket(c, r);
        if (r.depositor != depositor) revert NotDepositor();
    }
}
// forge-lint: disable-end(reentrancy-no-eth)
// forge-lint: disable-end(reentrancy-events)
