// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

// External calls go only to known protocol contracts while a Lock member holds the Lock, so nothing can re-enter.

/// @title CollateralizationSeizure
/// @notice LPVaultSwap's seizure path: snapshot before `Spoke.liquidationCall`, then debit and unwind the records.
/// @dev The snapshot is in transient storage and takes no caller-supplied value.

import {IAaveV4Spoke} from "../../interfaces/external/aave/IAaveV4Spoke.sol";
import {IVaultToken} from "../../vault-token/vault-token/IVaultToken.sol";
import {CollateralizationBase} from "./CollateralizationBase.sol";
import {CollateralizationLedger} from "./CollateralizationLedger.sol";
import {ICollateralization} from "./ICollateralization.sol";
import {Pending} from "./types/CollateralizationTypes.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

// forge-lint: disable-start(reentrancy-events)
// forge-lint: disable-start(reentrancy-no-eth)
abstract contract CollateralizationSeizure is CollateralizationLedger, ICollateralization {
    // forge-lint: disable-start(reentrancy-events)
    // forge-lint: disable-start(reentrancy-no-eth)
    using SafeERC20 for IERC20;

    /// @inheritdoc ICollateralization
    function settlePending(
        address vaultToken,
        uint256 units
    ) external override returns (uint256[] memory amounts) {
        _onlyLPVaultSwap();
        Ctx memory c = _load(vaultToken);
        (address active,,,,) = _loadSnapshot();
        if (active != address(0)) revert SeizureActive();
        Pending storage p = pending[vaultToken];
        uint256 pendingUnits = p.units;
        if (units == 0 || units > pendingUnits) revert PendingExceeded();
        uint256 supply = _supply(vaultToken);
        uint256 limit = totalCredited[vaultToken] + pendingUnits;
        if (supply + units > limit) revert SupplyDropMismatch(limit - units, supply);
        uint256 n = c.tokens.length;
        amounts = new uint256[](n);
        for (uint256 i = 0; i < n; ++i) {
            uint256 held = p.amounts[i];
            uint256 out = units == pendingUnits ? held : Math.mulDiv(held, units, pendingUnits);
            amounts[i] = out;
            // One pending amount per market token, at most 8.
            // forge-lint: disable-next-line(costly-loop)
            if (out != 0) p.amounts[i] = held - out;
        }
        p.units = pendingUnits - units;
        emit PendingSettled(vaultToken, units, amounts);
        for (uint256 i = 0; i < n; ++i) {
            if (amounts[i] != 0) IERC20(c.tokens[i]).safeTransfer(_LP_VAULT_SWAP, amounts[i]);
        }
    }

    // forge-lint: disable-end(reentrancy-no-eth)
    // forge-lint: disable-end(reentrancy-events)

    /// @inheritdoc ICollateralization
    function markIndebted(
        address proxy
    ) external override {
        _onlyAdapter();
        address vt = proxyMarket[proxy];
        if (vt == address(0)) revert UnknownProxy(proxy);
        if (indebted[proxy]) return;
        indebted[proxy] = true;
        ++indebtedCount[vt];
    }

    /// @inheritdoc ICollateralization
    function markDebtFree(
        address proxy
    ) external override {
        address holder = _holder();
        if (msg.sender != _ADAPTER && msg.sender != _LP_VAULT_SWAP) revert NotAdapter();
        if (holder != msg.sender) revert LockNotHeld();
        if (!indebted[proxy]) return;
        address vt = proxyMarket[proxy];
        // A failing read keeps the mark; a failure with little gas left may be caller starvation, so it reverts.
        (bool ok, bytes memory data) =
            IVaultToken(vt).spoke().staticcall(abi.encodeCall(IAaveV4Spoke.getUserAccountData, (proxy)));
        if (!ok) {
            uint256 left = gasleft();
            if (left < DEBT_MARK_GAS_FLOOR) revert InsufficientGas(left, DEBT_MARK_GAS_FLOOR);
            // An oracle inside the read starved by the caller's gas limit: revert rather than keep the mark.
            // forge-lint: disable-next-line(unsafe-typecast)
            if (data.length >= 4 && bytes4(data) == InsufficientGas.selector) {
                revert InsufficientGas(left, DEBT_MARK_GAS_FLOOR);
            }
            return;
        }
        if (data.length < 224) return;
        (,,,,,, uint256 borrowCount) = abi.decode(data, (uint256, uint256, uint256, uint256, uint256, uint256, uint256));
        if (borrowCount != 0) return;
        indebted[proxy] = false;
        --indebtedCount[vt];
    }

    /// @inheritdoc ICollateralization
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

    /// @inheritdoc ICollateralization
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
