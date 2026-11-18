// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {CollateralizationLedger} from "./CollateralizationLedger.sol";
import {ICollateralizationSeizure} from "./ICollateralizationSeizure.sol";

// External calls go only to known protocol contracts while a Lock member holds the Lock, so nothing can re-enter.
// forge-lint: disable-start(reentrancy-events)
// forge-lint: disable-start(reentrancy-no-eth)
/// @title CollateralizationSeizure
/// @notice LPVaultSwap's seizure path: snapshot before `Spoke.liquidationCall`, then debit and unwind the records.
/// @dev The snapshot is in transient storage and takes no caller-supplied value.
abstract contract CollateralizationSeizure is CollateralizationLedger, ICollateralizationSeizure {
    /// @inheritdoc ICollateralizationSeizure
    function beginSeizure(
        address proxy,
        address vaultToken
    ) external override {
        _onlyLPVaultSwap();
        Ctx memory c = _load(vaultToken);
        _withReserve(c);
        if (!_sharesEqualAssets(c)) revert SharesNotEqualAssets();
        (address active,,,,) = _loadSnapshot();
        if (active != address(0)) revert SeizureActive();
        _checkProxy(vaultToken, proxy);
        _storeSnapshot(proxy, vaultToken, c.reserveId, _supplied(c, proxy), _supply(vaultToken));
    }

    /// @inheritdoc ICollateralizationSeizure
    function settleSeizure(
        address proxy,
        address vaultToken,
        uint256 units,
        uint256[] calldata minAmounts
    ) external override returns (uint256[] memory amounts) {
        _onlyLPVaultSwap();
        (Ctx memory c, uint256 sharesBefore, uint256 feeUnits) = _checkDrops(proxy, vaultToken, units);
        _checkLength(c, minAmounts.length);
        if (units == 0) {
            _storeSnapshot(address(0), address(0), 0, 0, 0);
            return new uint256[](c.tokens.length);
        }
        _checkReadSafe(c);
        // Aave's liquidation-fee units left the proxy without reaching LPVaultSwap; reconcile moves them to pending.
        _reconcile(c, proxy, sharesBefore - feeUnits);
        uint256 count;
        (amounts, count) = _settleDebits(c, proxy, units);
        uint256 n = amounts.length;
        uint256 index = n;
        for (uint256 i = 0; i < n; ++i) {
            if (amounts[i] < minAmounts[i]) {
                index = i;
                break;
            }
        }
        if (index != n) revert BelowMinimum(index, amounts[index], minAmounts[index]);
        emit SeizureSettled(proxy, vaultToken, units, amounts, count);
    }

    /// @dev Returns the excess share drop as `feeUnits`, the liquidation fee Aave kept inside the Hub.
    function _checkDrops(
        address proxy,
        address vaultToken,
        uint256 units
    ) private view returns (Ctx memory c, uint256 sharesBefore, uint256 feeUnits) {
        (address snapProxy, address snapToken,, uint256 shares0, uint256 supply0) = _loadSnapshot();
        if (snapProxy == address(0) || snapProxy != proxy || snapToken != vaultToken) revert SeizureMismatch();
        c = _load(vaultToken);
        _withReserve(c);
        uint256 sharesAfter = _supplied(c, proxy);
        // An Aave fee is part of a seizure, so a share drop with no seized units is never one.
        if (sharesAfter > shares0 || shares0 - sharesAfter < units || (units == 0 && sharesAfter != shares0)) {
            revert DebitMismatch();
        }
        uint256 supplyAfter = _supply(vaultToken);
        uint256 supplyDrop = supplyAfter > supply0 ? 0 : supply0 - supplyAfter;
        if (supplyAfter > supply0 || supplyDrop != units) revert SupplyDropMismatch(units, supplyDrop);
        sharesBefore = shares0;
        feeUnits = shares0 - sharesAfter - units;
    }

    function _settleDebits(
        Ctx memory c,
        address proxy,
        uint256 units
    ) private returns (uint256[] memory amounts, uint256 count) {
        Debit[] memory debits;
        (debits, count) = _debit(c, proxy, units);
        _storeSnapshot(address(0), address(0), 0, 0, 0);
        uint256 n = c.tokens.length;
        amounts = new uint256[](n);
        uint256[] memory zeros = new uint256[](n);
        for (uint256 k = 0; k < count; ++k) {
            Debit memory d = debits[k];
            uint256[] memory got = _unwind(c, d.positionKey, d.take, zeros, _LP_VAULT_SWAP);
            for (uint256 i = 0; i < n; ++i) {
                amounts[i] += got[i];
            }
            emit RecordDebited(
                d.recordId, d.positionKey, proxy, c.vaultToken, d.take, d.creditedAfter, got, d.capReleased
            );
        }
    }
}
// forge-lint: disable-end(reentrancy-no-eth)
// forge-lint: disable-end(reentrancy-events)
