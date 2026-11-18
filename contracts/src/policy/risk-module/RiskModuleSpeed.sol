// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {RiskModuleBase} from "./RiskModuleBase.sol";
import {SpeedScope} from "./types/SpeedScope.sol";
import {SpeedWindow} from "./types/SpeedWindow.sol";

/// @title RiskModuleSpeed
/// @notice Storage of the RiskModule's net-flow speed windows: market borrow, debt borrow and market pledge.
/// @dev ERC-7201 namespace `avana.storage.RiskModule.speed`; there is no setter and no reset.
abstract contract RiskModuleSpeed is RiskModuleBase {
    /// @custom:storage-location erc7201:avana.storage.RiskModule.speed
    struct SpeedLayout {
        mapping(uint256 marketId => SpeedWindow) marketBorrow;
        mapping(bytes32 hubAssetKey => SpeedWindow) debtBorrow;
        mapping(uint256 marketId => SpeedWindow) marketPledge;
    }

    bytes32 private constant _SPEED_SLOT = 0x1858dc028745fe2a4f37a8a31dd3ca321a1f7863f165bffa26e588c97f1ff200;

    function _speed() internal pure returns (SpeedLayout storage $) {
        // ERC-7201 namespaced storage: the slot is a compile-time constant.
        // solhint-disable-next-line no-inline-assembly
        assembly {
            $.slot := _SPEED_SLOT
        }
    }

    function _window(
        SpeedScope scope,
        bytes32 key
    ) internal view returns (SpeedWindow storage w) {
        SpeedLayout storage $ = _speed();
        if (scope == SpeedScope.DebtBorrow) return $.debtBorrow[key];
        if (scope == SpeedScope.MarketBorrow) return $.marketBorrow[uint256(key)];
        return $.marketPledge[uint256(key)];
    }

    function _putWindow(
        SpeedScope scope,
        bytes32 key,
        SpeedWindow memory w
    ) internal {
        SpeedWindow storage s = _window(scope, key);
        s.start = w.start;
        s.prev = w.prev;
        s.curr = w.curr;
        s.base = w.base;
        s.opened = w.opened;
    }
}
