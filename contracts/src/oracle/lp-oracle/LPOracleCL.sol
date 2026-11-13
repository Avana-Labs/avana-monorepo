// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ILPOracleCL} from "./ILPOracleCL.sol";
import {LPOracle} from "./LPOracle.sol";
import {LPOracleCLModule} from "./LPOracleCLModule.sol";
import {LPOracleCLModuleCaller} from "./LPOracleCLModuleCaller.sol";
import {LPOracleCLPool} from "./LPOracleCLPool.sol";
import {ClPriceStateView} from "./types/ClPriceStateView.sol";
import {LPOracleLogicSet} from "./types/LPOracleLogicSet.sol";

/// @title LPOracleCL
/// @notice The LPOracle implementation of every concentrated-liquidity market of one AMM protocol on one chain: the
/// AMM-neutral price-state core (`LPOracle`) with the concentrated-liquidity pricing module compiled in (2.10
/// Concentrated-liquidity pricing). Uniswap v3 markets on Ethereum deploy it with `slot0Words = 7`, Aerodrome
/// Slipstream markets on Base with `slot0Words = 6`; every market of that protocol is an ERC-1967 proxy of it.
/// @dev The four logic contracts (`LPOracleCLPokeLogic`, `LPOracleCLInitLogic`, `LPOracleCLListingLogic`,
/// `LPOracleCLViewLogic`) carry the
/// same module and must report the same chain constants (`logicConfig`), the same `slot0` layout and the same
/// `LPOracleCLModuleLogic` (the pricing module, run by delegatecall), else the
/// constructor reverts `MarketMismatch(0)`. `getClPriceState()` runs in the view logic like every evaluation view.
/// Example: a full-range USDC/USDT market on spacing 1 at $1 per token serves `199,999,600` per whole vault token
/// (`d = 6`), and moving the pool's spot price leaves it unchanged.
/// @custom:spec REQ-ORACLE-042, REQ-ORACLE-080, REQ-ORACLE-103, REQ-ORACLE-104, REQ-AMM-V3-005, REQ-AMM-SLIP-005, Q-321
contract LPOracleCL is LPOracle, LPOracleCLModule, ILPOracleCL {
    /// @dev The implementation's `LPOracleCLModuleLogic`, the same for its three logic contracts.
    address internal immutable _MODULE_LOGIC;

    /// @notice Fixes the chain constants, the `slot0` layout and the three logic contracts.
    /// @param timelock The chain's AvanaTimelock.
    /// @param chainBlockTime Seconds per block (12 on Ethereum, 2 on Base).
    /// @param pokeMinGasFloor `POKE_MIN_GAS_FLOOR`.
    /// @param pokeMinGasCeiling `POKE_MIN_GAS_CEILING`.
    /// @param hasSequencer True on an L2 with a sequencer-uptime feed.
    /// @param slot0Words 7 for Uniswap v3, 6 for Aerodrome Slipstream.
    /// @param moduleLogic The implementation's `LPOracleCLModuleLogic` (checked by its `MODULE_ID`).
    /// @param logics The poke, initialization (`LPOracleCLInitLogic`), listing and view logic contracts.
    /// @custom:spec REQ-ORACLE-078, REQ-ORACLE-080, REQ-ORACLE-097, REQ-AMM-V3-003, REQ-AMM-SLIP-003
    constructor(
        address timelock,
        uint32 chainBlockTime,
        uint32 pokeMinGasFloor,
        uint32 pokeMinGasCeiling,
        bool hasSequencer,
        uint8 slot0Words,
        address moduleLogic,
        LPOracleLogicSet memory logics
    )
        LPOracle(timelock, chainBlockTime, pokeMinGasFloor, pokeMinGasCeiling, hasSequencer, logics)
        LPOracleCLPool(slot0Words)
    {
        if (
            !_sameModule(logics.pokeLogic, slot0Words, moduleLogic)
                || !_sameModule(logics.initLogic, slot0Words, moduleLogic)
                || !_sameModule(logics.listingLogic, slot0Words, moduleLogic)
                || !_sameModule(logics.viewLogic, slot0Words, moduleLogic)
        ) revert MarketMismatch(0);
        _MODULE_LOGIC = moduleLogic;
    }

    /// @notice The module contract every logic contract of this implementation delegates its pricing hooks to.
    /// @return moduleLogic The `LPOracleCLModuleLogic` fixed at deployment.
    /// @custom:spec REQ-ORACLE-080
    function MODULE_LOGIC() external view returns (address moduleLogic) {
        moduleLogic = _MODULE_LOGIC;
    }

    /// @dev `logic` decodes the same `slot0` layout and delegates to the same module contract.
    function _sameModule(
        address logic,
        uint8 slot0Words,
        address moduleLogic
    ) private view returns (bool) {
        return LPOracleCLPool(logic).SLOT0_WORDS() == slot0Words
            && LPOracleCLModuleCaller(logic).MODULE_LOGIC() == moduleLogic;
    }

    /// @inheritdoc ILPOracleCL
    /// @custom:spec REQ-ORACLE-042, REQ-ORACLE-104, REQ-AMM-V3-005, REQ-AMM-SLIP-005
    function getClPriceState() external view override returns (ClPriceStateView memory report) {
        _forward(_VIEW_LOGIC);
        return report;
    }
}
