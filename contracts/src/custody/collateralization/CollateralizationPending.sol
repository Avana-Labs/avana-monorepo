// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {CollateralizationLedger} from "./CollateralizationLedger.sol";
import {ICollateralizationSeizure} from "./ICollateralizationSeizure.sol";
import {Pending} from "./types/Pending.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

// External calls go only to known protocol contracts while a Lock member holds the Lock, so nothing can re-enter.
// forge-lint: disable-start(reentrancy-events)
// forge-lint: disable-start(reentrancy-no-eth)
/// @title CollateralizationPending
/// @notice Pending settlement: LPVaultSwap retires burned units for a pro-rata share of the market tokens held.
/// @dev The supply check ensures no market token leaves for a unit still in circulation.
abstract contract CollateralizationPending is CollateralizationLedger, ICollateralizationSeizure {
    using SafeERC20 for IERC20;

    /// @inheritdoc ICollateralizationSeizure
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
}
// forge-lint: disable-end(reentrancy-no-eth)
// forge-lint: disable-end(reentrancy-events)
