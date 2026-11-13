// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {CollateralizationLedger} from "./CollateralizationLedger.sol";
import {ICollateralizationSeizure} from "./ICollateralizationSeizure.sol";

// Every external call in this file goes to the market's registered LPVault, the vault token, the VaultTokenFactory, the
// Aave Hub or Spoke, or (in `pledge` and `recredit`) the RiskModule's view check and the market's LPOracle, while a Lock
// member holds the Lock, so no other code can re-enter Collateralization; the order of calls, writes and events is the
// one 2.3 fixes: custody before the credit is read, balance deltas measured around the call that delivers them, and
// events that report a call's amounts after that call (REQ-VAULT-089, REQ-LOCK-017).
// forge-lint: disable-start(reentrancy-events)
// forge-lint: disable-start(reentrancy-no-eth)
/// @title CollateralizationSeizure
/// @notice LPVaultSwap's seizure path: `beginSeizure` snapshots the proxy's supplied shares and the vault token's
/// supply in transient storage before `Spoke.liquidationCall`; `settleSeizure` proves the supply drop equals the
/// seized units and the share drop covers them, reconciles any earlier unsettled seizure together with the units Aave
/// paid as its liquidation fee (into the pending balance), debits the records largest-first and has the LPVault unwind
/// exactly the seized units to LPVaultSwap.
/// @dev The snapshot is taken by Collateralization itself; no caller-supplied value is accepted (REQ-VAULT-049). It
/// lives in transient storage, so a liquidation that never settles leaves nothing behind for the next transaction. A
/// liquidation by anyone but LPVaultSwap never reaches this contract: if it seizes units the vault token refuses the
/// Hub's transfer, and a dust liquidation that seizes 0 units moves no supplied share, so it leaves no shortfall.
/// @custom:spec REQ-VAULT-046, REQ-VAULT-047, REQ-VAULT-048, REQ-VAULT-049, REQ-VAULT-050, REQ-VAULT-051, REQ-VAULT-052, REQ-VAULT-053, REQ-VAULT-060, REQ-VAULT-062, REQ-VAULT-063, REQ-VAULT-133, SPEC-BACK-007, INV-014
abstract contract CollateralizationSeizure is CollateralizationLedger, ICollateralizationSeizure {
    /// @inheritdoc ICollateralizationSeizure
    /// @custom:spec REQ-VAULT-046, REQ-VAULT-047, REQ-VAULT-048, REQ-VAULT-049, REQ-VAULT-112, REQ-VAULT-113, REQ-VAULT-114, REQ-VAULT-115, REQ-COLL-003, REQ-COLL-010, SPEC-BACK-007
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
    /// @custom:spec REQ-VAULT-010, REQ-VAULT-043, REQ-VAULT-050, REQ-VAULT-051, REQ-VAULT-052, REQ-VAULT-053, REQ-VAULT-054, REQ-VAULT-055, REQ-VAULT-056, REQ-VAULT-059, REQ-VAULT-060, REQ-VAULT-061, REQ-VAULT-062, REQ-VAULT-116, REQ-VAULT-117, REQ-VAULT-133, REQ-VAULT-146, REQ-COLL-028, SPEC-BACK-005, SPEC-BACK-006, SPEC-BACK-007, SPEC-BACK-011
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
        // SPEC-BACK-007: the units Aave moved to its fee receiver inside the Hub left the proxy's shares without
        // reaching LPVaultSwap; reconciling against `sharesBefore - feeUnits` debits them with any earlier shortfall
        // and moves their principal into the pending balance, so the backing gap is unchanged.
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

    /// @notice Checks the active snapshot names `proxy` and `vaultToken`, that the vault token's supply drop since
    /// `beginSeizure` equals `units` and that the proxy's share drop is at least `units` (SPEC-BACK-007); returns the
    /// excess `feeUnits`, the liquidation-fee shares Aave moved to its fee receiver inside the Hub (no vault token
    /// left the Hub for them, which the exact supply drop proves).
    /// @custom:spec REQ-VAULT-050, REQ-VAULT-051, REQ-VAULT-115, REQ-VAULT-116, SPEC-BACK-007, INV-014
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
        // An Aave fee is a part of a seizure, so a share drop with no seized units is never one (TEST-131).
        if (sharesAfter > shares0 || shares0 - sharesAfter < units || (units == 0 && sharesAfter != shares0)) {
            revert DebitMismatch();
        }
        uint256 supplyAfter = _supply(vaultToken);
        uint256 supplyDrop = supplyAfter > supply0 ? 0 : supply0 - supplyAfter;
        if (supplyAfter > supply0 || supplyDrop != units) revert SupplyDropMismatch(units, supplyDrop);
        sharesBefore = shares0;
        feeUnits = shares0 - sharesAfter - units;
    }

    /// @notice Debits the seized units largest-first, clears the snapshot, then has the LPVault unwind each debited
    /// record's units to LPVaultSwap with zero per-record minimums; returns the summed principal.
    /// @custom:spec REQ-VAULT-053, REQ-VAULT-054, REQ-VAULT-060, REQ-VAULT-062, SPEC-BACK-006, SPEC-BACK-008
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
