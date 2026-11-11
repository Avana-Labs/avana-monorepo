// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAmmIntegration} from "../../amm/IAmmIntegration.sol";
import {CollateralizationLedger} from "./CollateralizationLedger.sol";
import {ICollateralizationAdapter} from "./ICollateralizationAdapter.sol";
import {ICollateralizationUser} from "./ICollateralizationUser.sol";
import {BackingRecord} from "./types/BackingRecord.sol";

// Every external call in this file goes to the market's registered LPVault, the vault token, the VaultTokenFactory, the
// Aave Hub or Spoke, or (in `pledge` and `recredit`) the RiskModule's view check and the market's LPOracle, while a Lock
// member holds the Lock, so no other code can re-enter Collateralization; the order of calls, writes and events is the
// one 2.3 fixes: custody before the credit is read, balance deltas measured around the call that delivers them, and
// events that report a call's amounts after that call (REQ-VAULT-089, REQ-LOCK-017).
// forge-lint: disable-start(reentrancy-events)
// forge-lint: disable-start(reentrancy-no-eth)
/// @title CollateralizationRelease
/// @notice Adapter path, exit side: withdrawal release, partial removal, deleverage release, zero-credit release and
/// fee collection. Every exit reconciles the account-market first, releases exposure per SPEC-BACK-005 with saturating
/// counters, reads no pause, breaker, freeze, price or policy, and moves the position or principal last.
/// @dev None of these functions checks the Adapter's burn: the Adapter compares the market's backing gap before and
/// after its whole call (REQ-COLL-007).
/// @custom:spec REQ-COLL-007, REQ-COLL-008, REQ-COLL-014, REQ-COLL-017, REQ-COLL-032, REQ-VAULT-068, REQ-VAULT-069, REQ-VAULT-070, REQ-VAULT-071, REQ-VAULT-072, REQ-VAULT-073, REQ-VAULT-075, REQ-VAULT-076, REQ-VAULT-089
abstract contract CollateralizationRelease is
    CollateralizationLedger,
    ICollateralizationAdapter,
    ICollateralizationUser
{
    /// @inheritdoc ICollateralizationAdapter
    /// @custom:spec REQ-VAULT-033, REQ-VAULT-036, REQ-VAULT-043, REQ-VAULT-068, REQ-VAULT-069, REQ-VAULT-070, REQ-VAULT-071, REQ-VAULT-072, REQ-VAULT-073, REQ-VAULT-118, REQ-VAULT-131, REQ-VAULT-143, REQ-COLL-007, SPEC-BACK-005, SPEC-BACK-011
    function release(
        address proxy,
        address vaultToken,
        bytes32 positionKey,
        uint256 units
    ) external override {
        (Ctx memory c, uint256 id, BackingRecord storage r) = _prepareExit(vaultToken, positionKey, proxy, units, 0);
        if (units == 0 || units != r.credited) revert UnitsMismatch();
        _debitRecord(c, r, units);
        emit CollateralReleased(id, positionKey, r.depositor, proxy, vaultToken, units);
        _close(c, id, r);
        _returnPosition(c, positionKey);
    }

    /// @inheritdoc ICollateralizationAdapter
    /// @custom:spec REQ-COLL-014, REQ-COLL-016, REQ-COLL-020, REQ-COLL-023, REQ-VAULT-010, REQ-VAULT-031, REQ-VAULT-032, REQ-VAULT-036, REQ-VAULT-088, REQ-VAULT-131, SPEC-BACK-005, SPEC-BACK-014, SPEC-BACK-015
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
        remaining = credited - units;
        emit RecordReduced(id, units, released);
        address depositor = r.depositor;
        uint256[] memory before = _balances(c, depositor);
        // The amounts returned are the depositor's measured balance deltas, not the LPVault's report (REQ-VAULT-088).
        // forge-lint: disable-next-line(unused-return)
        IAmmIntegration(c.lpVault).releaseToDepositor(positionKey, units, minAmounts);
        amounts = _received(c, depositor, before);
    }

    /// @inheritdoc ICollateralizationAdapter
    /// @custom:spec REQ-COLL-016, REQ-COLL-017, REQ-VAULT-010, REQ-VAULT-031, REQ-VAULT-032, REQ-VAULT-033, REQ-VAULT-036, REQ-VAULT-074, REQ-VAULT-131, SPEC-BACK-005, SPEC-BACK-014
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
    /// @custom:spec REQ-VAULT-033, REQ-VAULT-074, REQ-VAULT-075, REQ-VAULT-076, REQ-VAULT-119, REQ-VAULT-121, REQ-VAULT-132, REQ-VAULT-143, REQ-COLL-011
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
    /// @custom:spec REQ-COLL-032, REQ-VAULT-059, REQ-VAULT-076, REQ-COLL-011
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

    /// @notice Shared start of `release`, `releasePartial` and `releaseForDeleverage`: caller and lock, vault token,
    /// the open record of `positionKey` naming `proxy` in `vaultToken`'s market, and reconciliation with the supplied
    /// shares before the Adapter's withdrawal of `units` (REQ-VAULT-131). `lengthPlusOne` is 0 for `release`, which
    /// removes no units; otherwise `minAmounts.length + 1`, checked against the market's token count, and the pool
    /// lock is checked before any removal.
    /// @custom:spec REQ-VAULT-010, REQ-VAULT-068, REQ-VAULT-113, REQ-VAULT-131, REQ-COLL-028, REQ-LOCK-011
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

    /// @notice The open record of `positionKey`, which must belong to `vaultToken` and name `depositor`.
    /// @custom:spec REQ-VAULT-075, REQ-COLL-011, REQ-COLL-032, REQ-LOCK-011
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
