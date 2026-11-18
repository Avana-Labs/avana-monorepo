// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAaveV4Spoke} from "../../interfaces/external/aave/IAaveV4Spoke.sol";
import {IVaultToken} from "../../vault-token/vault-token/IVaultToken.sol";
import {CollateralizationBase} from "./CollateralizationBase.sol";
import {ICollateralizationDebtMark} from "./ICollateralizationDebtMark.sol";

/// @title CollateralizationDebtMark
/// @notice The indebted mark of an account and the per-market count `closeMarket` reads.
/// @dev A stale mark only delays `closeMarket`; anyone clears it through the AaveAdapter's `refreshDebtMark`.
abstract contract CollateralizationDebtMark is CollateralizationBase, ICollateralizationDebtMark {
    /// @inheritdoc ICollateralizationDebtMark
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
}
