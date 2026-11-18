// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {OracleConfig, SecondSource} from "../../types/OracleTypes.sol";
import {LPOracleCLModuleLogic} from "./LPOracleCLModuleLogic.sol";
import {LPOracleCLPool} from "./LPOracleCLPool.sol";
import {ClPriceStateView} from "./LPOracleTypes.sol";

/// @title LPOracleCLModuleCaller
/// @notice Runs a logic contract's concentrated-liquidity pricing hooks in `LPOracleCLModuleLogic` by delegatecall.
/// @dev A failed delegatecall re-raises its revert data, so a starved read never becomes a market failure.
abstract contract LPOracleCLModuleCaller is LPOracleCLPool {
    address internal immutable _MODULE_LOGIC;

    /// @notice Sets the module contract; reverts `MarketMismatch(0)` unless its id, layout and chain constants match.
    constructor(
        address moduleLogic
    ) {
        bytes32 config = keccak256(
            abi.encode(_TIMELOCK, _CHAIN_BLOCK_TIME, _POKE_MIN_GAS_FLOOR, _POKE_MIN_GAS_CEILING, _HAS_SEQUENCER)
        );
        if (moduleLogic == address(0) || moduleLogic.code.length == 0) revert MarketMismatch(0);
        bytes32 id = LPOracleCLModuleLogic(moduleLogic).MODULE_ID();
        if (
            (id != keccak256("avana.LPOracleCLModuleLogic.v1") && id != keccak256("avana.LPOracleV4ModuleLogic.v1"))
                || LPOracleCLModuleLogic(moduleLogic).SLOT0_WORDS() != _SLOT0_WORDS
                || LPOracleCLModuleLogic(moduleLogic).logicConfig() != config
        ) revert MarketMismatch(0);
        _MODULE_LOGIC = moduleLogic;
    }

    /// @notice The module contract this logic contract delegates its pricing hooks to.
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

    function _isOwnPool(
        bytes32 poolRef
    ) internal view override returns (bool own) {
        own = _word(_module(abi.encodeCall(LPOracleCLModuleLogic.isOwnPool, (poolRef))), 0) != 0;
    }

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

    /// @dev Word `i` of the module's return data; each entry point returns a static tuple of at least `i + 1` words.
    function _word(
        bytes memory r,
        uint256 i
    ) private pure returns (uint256 v) {
        // solhint-disable-next-line no-inline-assembly
        assembly ("memory-safe") {
            v := mload(add(r, add(0x20, mul(i, 0x20))))
        }
    }

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
        // Re-raises the module's revert data unchanged; an out-of-gas failure has none.
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
