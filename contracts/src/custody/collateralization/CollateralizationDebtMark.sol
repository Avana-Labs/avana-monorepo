// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAaveV4Spoke} from "../../interfaces/external/aave/IAaveV4Spoke.sol";
import {IVaultToken} from "../../vault-token/vault-token/IVaultToken.sol";
import {CollateralizationBase} from "./CollateralizationBase.sol";
import {ICollateralizationDebtMark} from "./ICollateralizationDebtMark.sol";

/// @title CollateralizationDebtMark
/// @notice The indebted mark of an account and the per-market count `closeMarket` reads (Q-355).
/// @dev The mark moves no charge. A proxy's market is the vault token of its first pledge. `markDebtFree` reads the
/// Spoke only for a marked account; a failing read with at least `DEBT_MARK_GAS_FLOOR` gas left changes nothing, and
/// one with less reverts `InsufficientGas`, so a caller cannot starve the read to keep a mark set. A mark left set by a
/// failing read, or by a debt that left without an Avana call, is cleared by anyone through the AaveAdapter's
/// `refreshDebtMark(proxy)`, so a stale mark only delays `closeMarket` and never blocks a repay or a liquidation.
/// @custom:spec REQ-COLL-038, REQ-COLL-039, REQ-COLL-040, Q-355, Q-396
abstract contract CollateralizationDebtMark is CollateralizationBase, ICollateralizationDebtMark {
    /// @inheritdoc ICollateralizationDebtMark
    /// @custom:spec REQ-COLL-039, REQ-VAULT-086
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

    /// @inheritdoc ICollateralizationDebtMark
    /// @custom:spec REQ-COLL-040, REQ-VAULT-086
    function markDebtFree(
        address proxy
    ) external override {
        address holder = _holder();
        if (msg.sender != _ADAPTER && msg.sender != _LP_VAULT_SWAP) revert NotAdapter();
        if (holder != msg.sender) revert LockNotHeld();
        if (!indebted[proxy]) return;
        address vt = proxyMarket[proxy];
        // A failing or short read changes nothing: the mark only delays `closeMarket` until `refreshDebtMark`
        // (REQ-COLL-040). A failure with little gas left may be the caller's starvation of the read, so it reverts.
        (bool ok, bytes memory data) =
            IVaultToken(vt).spoke().staticcall(abi.encodeCall(IAaveV4Spoke.getUserAccountData, (proxy)));
        if (!ok) {
            uint256 left = gasleft();
            if (left < DEBT_MARK_GAS_FLOOR) revert InsufficientGas(left, DEBT_MARK_GAS_FLOOR);
            return;
        }
        if (data.length < 224) return;
        (,,,,,, uint256 borrowCount) = abi.decode(data, (uint256, uint256, uint256, uint256, uint256, uint256, uint256));
        if (borrowCount != 0) return;
        indebted[proxy] = false;
        --indebtedCount[vt];
    }
}
