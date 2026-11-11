// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {CollateralizationLedger} from "./CollateralizationLedger.sol";
import {ICollateralizationSeizure} from "./ICollateralizationSeizure.sol";
import {Pending} from "./types/Pending.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

// Every external call in this file goes to the market's registered LPVault, the vault token, the VaultTokenFactory, the
// Aave Hub or Spoke, or (in `pledge` and `recredit`) the RiskModule's view check and the market's LPOracle, while a Lock
// member holds the Lock, so no other code can re-enter Collateralization; the order of calls, writes and events is the
// one 2.3 fixes: custody before the credit is read, balance deltas measured around the call that delivers them, and
// events that report a call's amounts after that call (REQ-VAULT-089, REQ-LOCK-017).
// forge-lint: disable-start(reentrancy-events)
// forge-lint: disable-start(reentrancy-no-eth)
/// @title CollateralizationPending
/// @notice Pending settlement: LPVaultSwap retires burned units of an unsettled seizure and receives the matching
/// pro-rata share of the market tokens Collateralization holds for them (SPEC-BACK-012).
/// @dev The one-sided supply check `totalSupply + units <= totalCredited + pending.units` proves no market token leaves
/// for a unit still in circulation, for any LPVaultSwap implementation (Q-257). LPVaultSwap sizes `units` from a
/// `getPending` read before it takes the Lock; the bound is re-checked here under the Lock, so a stale read can only
/// revert (REQ-VAULT-145, REQ-LOCK-007).
/// @custom:spec REQ-VAULT-137, REQ-VAULT-138, REQ-VAULT-139, REQ-VAULT-141, REQ-VAULT-142, REQ-VAULT-145, REQ-VAULT-146, REQ-COLL-012, REQ-LOCK-007, SPEC-BACK-012
abstract contract CollateralizationPending is CollateralizationLedger, ICollateralizationSeizure {
    using SafeERC20 for IERC20;

    /// @inheritdoc ICollateralizationSeizure
    /// @custom:spec REQ-VAULT-137, REQ-VAULT-138, REQ-VAULT-139, REQ-VAULT-141, REQ-VAULT-142, REQ-VAULT-145, REQ-VAULT-146, REQ-COLL-003, REQ-COLL-012, SPEC-BACK-009, SPEC-BACK-012
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
            // Inherent: one pending amount per market token, at most 8.
            // forge-lint: disable-next-line(costly-loop)
            if (out != 0) p.amounts[i] = held - out;
        }
        p.units = pendingUnits - units;
        emit PendingSettled(vaultToken, units, amounts);
        for (uint256 i = 0; i < n; ++i) {
            if (amounts[i] != 0) IERC20(c.tokens[i]).safeTransfer(_LP_VAULT_SWAP, amounts[i]);
        }
    }
}
// forge-lint: disable-end(reentrancy-no-eth)
// forge-lint: disable-end(reentrancy-events)
