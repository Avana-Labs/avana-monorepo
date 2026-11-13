// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {OracleConfig} from "../../types/OracleConfig.sol";
import {SecondSource} from "../../types/SecondSource.sol";
import {LPOracleCLModuleLogic} from "./LPOracleCLModuleLogic.sol";
import {LPOracleCLPool} from "./LPOracleCLPool.sol";
import {ClPriceStateView} from "./types/ClPriceStateView.sol";

/// @title LPOracleCLModuleCaller
/// @notice The pricing-module hooks of the concentrated-liquidity poke, listing and view logic contracts: each hook runs
/// in `LPOracleCLModuleLogic` by delegatecall, in the market proxy's storage, so the module's code is deployed once and
/// each logic contract stays inside EIP-170.
/// @dev The module contract is fixed in the immutable `_MODULE_LOGIC` at construction, which requires its `MODULE_ID()`,
/// its `slot0` layout and its chain constants to match; there is no setter. A failed delegatecall re-raises its revert
/// data (the module's only revert is `InsufficientGas` before a read), so a hook never turns a starved read into a
/// market failure (`SPEC-ORC-023`).
/// Every price vector the core passes has the market's two entries (`initialize` refuses any other token count, and the
/// listing prices and every evaluation's vectors have that length), so the hooks pass them as scalars.
/// @custom:spec REQ-ORACLE-080, REQ-ORACLE-103, REQ-ORACLE-106, SPEC-ORC-023
abstract contract LPOracleCLModuleCaller is LPOracleCLPool {
    /// @dev The implementation's `LPOracleCLModuleLogic`.
    address internal immutable _MODULE_LOGIC;

    /// @notice Fixes the module contract; reverts `MarketMismatch(0)` unless it is an `LPOracleCLModuleLogic` with this
    /// contract's `slot0` layout and chain constants.
    /// @param moduleLogic The implementation's `LPOracleCLModuleLogic`.
    /// @custom:spec REQ-ORACLE-080
    constructor(
        address moduleLogic
    ) {
        bytes32 config = keccak256(
            abi.encode(_TIMELOCK, _CHAIN_BLOCK_TIME, _POKE_MIN_GAS_FLOOR, _POKE_MIN_GAS_CEILING, _HAS_SEQUENCER)
        );
        if (
            moduleLogic == address(0) || moduleLogic.code.length == 0
                || LPOracleCLModuleLogic(moduleLogic).MODULE_ID() != keccak256("avana.LPOracleCLModuleLogic.v1")
                || LPOracleCLModuleLogic(moduleLogic).SLOT0_WORDS() != _SLOT0_WORDS
                || LPOracleCLModuleLogic(moduleLogic).logicConfig() != config
        ) revert MarketMismatch(0);
        _MODULE_LOGIC = moduleLogic;
    }

    /// @notice The module contract this logic contract delegates its pricing hooks to.
    /// @return moduleLogic The `LPOracleCLModuleLogic` fixed at deployment.
    /// @custom:spec REQ-ORACLE-080
    function MODULE_LOGIC() external view returns (address moduleLogic) {
        moduleLogic = _MODULE_LOGIC;
    }

    /// @dev Never reached in a logic contract: `initialize` checks the market in the implementation itself.
    function _initMarket(
        bytes calldata,
        address[] memory
    ) internal pure override returns (bool) {
        return false;
    }

    /// @custom:spec SPEC-ORC-006, REQ-ORACLE-103
    function _composition(
        uint256 units,
        uint256[] memory prices
    ) internal view override returns (bool ok, uint256[] memory amounts) {
        bytes memory r = _module(abi.encodeCall(LPOracleCLModuleLogic.composition, (units, prices[0], prices[1])));
        ok = _word(r, 0) != 0;
        if (!ok) return (false, amounts);
        amounts = new uint256[](2);
        (amounts[0], amounts[1]) = (_word(r, 1), _word(r, 2));
    }

    /// @custom:spec REQ-ORACLE-103, SPEC-ORC-010, REQ-ORACLE-104
    function _poolCheck(
        uint256[] memory quotes,
        uint256[] memory prices,
        uint32 window,
        uint16 toleranceBps
    ) internal view override returns (PoolCheck memory p) {
        bytes memory r = _module(
            abi.encodeCall(
                LPOracleCLModuleLogic.poolCheck, (quotes[0], quotes[1], prices[0], prices[1], window, toleranceBps)
            )
        );
        (p.readOk, p.locked, p.available) = (_word(r, 0) != 0, _word(r, 1) != 0, _word(r, 2) != 0);
        (p.pass, p.deviationBps, p.clamped) = (_word(r, 3) != 0, _word(r, 4), _word(r, 5) != 0);
    }

    /// @custom:spec SPEC-ORC-020, REQ-ORACLE-100
    function _poolTwapPrice(
        uint256 index,
        SecondSource memory source,
        uint256[] memory quotes
    ) internal view override returns (bool ok, uint256 value) {
        bytes memory r = _module(
            abi.encodeCall(
                LPOracleCLModuleLogic.poolTwapPrice, (index, source.poolRef, source.twapWindow, quotes[0], quotes[1])
            )
        );
        (ok, value) = (_word(r, 0) != 0, _word(r, 1));
    }

    /// @custom:spec REQ-ORACLE-100
    function _isOwnPool(
        bytes32 poolRef
    ) internal view override returns (bool own) {
        own = _word(_module(abi.encodeCall(LPOracleCLModuleLogic.isOwnPool, (poolRef))), 0) != 0;
    }

    /// @custom:spec REQ-ORACLE-105
    function _listingChecks(
        OracleConfig calldata config,
        uint256[] memory quotes
    ) internal view override returns (uint256 failedChecks) {
        if (quotes.length != 2) return type(uint256).max;
        failedChecks = _word(
            _module(
                abi.encodeCall(LPOracleCLModuleLogic.listingChecks, (_listingInputs(config), quotes[0], quotes[1]))
            ),
            0
        );
    }

    /// @dev Word `i` of the module's return data. The module is this implementation's own code, fixed at construction,
    /// and each entry point returns a static tuple with at least `i + 1` words, so the read stays in the buffer.
    function _word(
        bytes memory r,
        uint256 i
    ) private pure returns (uint256 v) {
        // Reads word i of a static tuple the module returned in full.
        // solhint-disable-next-line no-inline-assembly
        assembly ("memory-safe") {
            v := mload(add(r, add(0x20, mul(i, 0x20))))
        }
    }

    /// @dev `getClPriceState()`'s report from the module.
    /// @custom:spec REQ-ORACLE-104
    function _clReportOf(
        bool priced,
        uint256[] memory quotes,
        uint256[] memory prices,
        uint32 window,
        uint16 toleranceTicks
    ) internal view returns (ClPriceStateView memory report) {
        report = abi.decode(
            _module(abi.encodeCall(LPOracleCLModuleLogic.clReport, (priced, quotes, prices, window, toleranceTicks))),
            (ClPriceStateView)
        );
    }

    /// @dev Runs `data` in the module contract by delegatecall and returns its return data.
    function _module(
        bytes memory data
    ) internal view returns (bytes memory ret) {
        ret = _asView(_delegate)(data);
    }

    /// @dev The delegatecall of `_module`: re-raises the module's revert data.
    function _delegate(
        bytes memory data
    ) internal returns (bytes memory ret) {
        bool ok;
        // The module is this implementation's own code, fixed at construction; it runs in this proxy's storage.
        // forge-lint: disable-start(controlled-delegatecall)
        // solhint-disable-next-line avoid-low-level-calls
        (ok, ret) = _MODULE_LOGIC.delegatecall(data);
        // forge-lint: disable-end(controlled-delegatecall)
        if (ok) return ret;
        // Re-raises the module's revert data unchanged: `InsufficientGas` before a read, or none when the call itself
        // ran out of gas, which the implementation's entry point reports as `InsufficientGas` (`_forward`).
        // solhint-disable-next-line no-inline-assembly
        assembly ("memory-safe") {
            revert(add(ret, 0x20), mload(ret))
        }
    }

    /// @dev `fn` typed as a view: the module's entry points write nothing and make only static calls.
    function _asView(
        function(bytes memory) returns (bytes memory) fn
    ) private pure returns (function(bytes memory) view returns (bytes memory) out) {
        // Reinterprets the function pointer; the code it points to is unchanged.
        // solhint-disable-next-line no-inline-assembly
        assembly ("memory-safe") {
            out := fn
        }
    }
}
