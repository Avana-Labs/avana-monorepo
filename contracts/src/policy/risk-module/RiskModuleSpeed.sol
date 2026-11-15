// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {RiskModuleBase} from "./RiskModuleBase.sol";
import {SpeedScope} from "./types/SpeedScope.sol";
import {SpeedWindow} from "./types/SpeedWindow.sol";

/// @title RiskModuleSpeed
/// @notice The storage of the RiskModule's net-flow speed windows (Q-411): the market borrow window in 8-decimal USD, the
/// (funding Hub, debt asset) borrow window in asset base units and the market pledge window in 8-decimal USD, each two
/// τ-long buckets (SPEC-CAP-011) with the window-start base its limit is computed on (SPEC-CAP-012).
/// @dev The windows sit in the ERC-7201 namespace `avana.storage.RiskModule.speed`, apart from OpenZeppelin's role and
/// initializer namespaces. `RiskModuleSpeedLogic` computes every new window from the stored one (read back through
/// `getSpeedWindow`) and the RiskModule stores it: the charges of the AaveAdapter's `preBorrowCheck` and
/// Collateralization's `checkPledge`, the credits of the AaveAdapter's `creditRepay` and Collateralization's
/// `creditWithdraw` (REQ-RISK-095). There is no setter and no reset.
/// @custom:spec REQ-RISK-092, REQ-RISK-093, REQ-RISK-095, REQ-RISK-097, SPEC-CAP-011, SPEC-CAP-012, Q-411
abstract contract RiskModuleSpeed is RiskModuleBase {
    /// @custom:storage-location erc7201:avana.storage.RiskModule.speed
    struct SpeedLayout {
        mapping(uint256 marketId => SpeedWindow) marketBorrow;
        mapping(bytes32 hubAssetKey => SpeedWindow) debtBorrow;
        mapping(uint256 marketId => SpeedWindow) marketPledge;
    }

    /// @dev `keccak256(abi.encode(uint256(keccak256("avana.storage.RiskModule.speed")) - 1)) & ~bytes32(uint256(0xff))`.
    bytes32 private constant _SPEED_SLOT = 0x1858dc028745fe2a4f37a8a31dd3ca321a1f7863f165bffa26e588c97f1ff200;

    /// @dev The namespace.
    function _speed() internal pure returns (SpeedLayout storage $) {
        // ERC-7201 namespaced storage: the slot is a compile-time constant.
        // solhint-disable-next-line no-inline-assembly
        assembly {
            $.slot := _SPEED_SLOT
        }
    }

    /// @dev The stored window of `scope` under `key`.
    function _window(
        SpeedScope scope,
        bytes32 key
    ) internal view returns (SpeedWindow storage w) {
        SpeedLayout storage $ = _speed();
        if (scope == SpeedScope.DebtBorrow) return $.debtBorrow[key];
        if (scope == SpeedScope.MarketBorrow) return $.marketBorrow[uint256(key)];
        return $.marketPledge[uint256(key)];
    }

    /// @dev Stores `w` as the window of `scope` under `key`.
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
