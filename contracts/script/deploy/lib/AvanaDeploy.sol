// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {AvanaPeripheryDeploy} from "./AvanaPeripheryDeploy.sol";
import {AvanaDeployment, ChainInputs} from "./DeployTypes.sol";

/// @title AvanaDeploy
/// @notice The whole Avana deployment of one chain in the order of `script/README.md`, shared by `03_DeployAvana` and
/// the deployment tests: predict every address, deploy, then check every prediction and cross-reference.
abstract contract AvanaDeploy is AvanaPeripheryDeploy {
    /// @notice `POKE_MIN_GAS_FLOOR` and `POKE_MIN_GAS_CEILING` of a two-token concentrated-liquidity LPOracle (1.5).
    uint32 internal constant CL_POKE_MIN_GAS_FLOOR = 900_000;
    uint32 internal constant CL_POKE_MIN_GAS_CEILING = 3_000_000;

    /// @notice Deploys every Avana contract of `c` from the sender, in the deployer's CREATE3 namespace.
    function _deployAvana(
        ChainInputs memory c
    ) internal returns (AvanaDeployment memory d) {
        require(address(create3).code.length != 0, "AvanaCreate3Factory missing: run 00_Factories");
        require(c.keepers.length >= c.keeperFloor, "fewer keepers than keeperFloor");
        Predicted memory p = _predictAll();
        d.factory = address(create3);
        d.deployer = deployer;
        d.timelock = _deployTimelock(c, p);
        d.marketRegistry = _deployMarketRegistry(c, p);
        d.parameterStore = _deployParameterStore(c, p);
        d.riskModule = _deployRiskModule(p);
        d.aaveAdapter = _deployAaveAdapter(p);
        d.lpVaultSwap = _deployLPVaultSwap(c, p);
        _deployImmutables(c, p, d);
        _deployLens(d);
        d.debtOracleImplementation = _deployDebtOracleImplementation(p);
        _deployClOracles(c, p, d);
        _checkPredictions(p, d);
        _checkBlockTime(c, d);
    }

    /// @notice The concentrated-liquidity LPOracle of each integration, the `pricing` it registers (`Q-376`): the
    /// immutable module logic, the four logic contracts of `LPOracleLogicSet` (poke, init, listing, view) and the
    /// implementation, all with the same immutables. Each market's LPOracle is an ERC-1967 proxy of this
    /// implementation, deployed and initialised at listing (`09_ListMarkets`, `MKT-019`).
    /// @dev Uniswap v3 and Slipstream: `LPOracleCLModuleLogic` and `LPOracleCL`, `slot0Words` 7 for Uniswap v3 and 6 for
    /// Slipstream, so every integration has its own set. Uniswap v4: `LPOracleV4ModuleLogic` and `LPOracleV4` with the
    /// PositionManager's WETH9 as the wrapped native token; the logic contracts read the Uniswap v3 reference pool
    /// (`slot0Words` 7).
    function _deployClOracles(
        ChainInputs memory c,
        Predicted memory p,
        AvanaDeployment memory d
    ) internal {
        uint256 n = c.integrations.length;
        d.clOraclePricing = new address[](n);
        d.clOracleModuleLogics = new address[](n);
        d.clOracleLogics = new address[](4 * n);
        for (uint256 i = 0; i < n; ++i) {
            _deployClOracle(c, p, d, i);
        }
    }

    function _deployClOracle(
        ChainInputs memory c,
        Predicted memory p,
        AvanaDeployment memory d,
        uint256 i
    ) private {
        bool v4 = _eq(c.integrations[i].kind, "uniswap-v4");
        uint8 words = _eq(c.integrations[i].kind, "slipstream") ? 6 : 7;
        string memory tag = string.concat(".", vm.toString(c.integrations[i].integrationId));
        bytes memory chainArgs =
            abi.encode(p.timelock, c.blockTime, CL_POKE_MIN_GAS_FLOOR, CL_POKE_MIN_GAS_CEILING, c.hasSequencer);
        // The wrapped native token of a v4 market's native ETH: the PositionManager's WETH9 the LPVault also reads.
        address weth = v4 ? _addressView(c.integrations[i].positionManagers[0], "WETH9()") : address(0);
        address moduleLogic = v4
            ? _deploy(
                string.concat("LPOracleV4ModuleLogic", tag),
                bytes.concat(
                    _artifact("LPOracleV4ModuleLogic.sol", "LPOracleV4ModuleLogic"), chainArgs, abi.encode(weth)
                )
            )
            : _deploy(
                string.concat("LPOracleCLModuleLogic", tag),
                bytes.concat(
                    _artifact("LPOracleCLModuleLogic.sol", "LPOracleCLModuleLogic"), chainArgs, abi.encode(words)
                )
            );
        d.clOracleModuleLogics[i] = moduleLogic;
        bytes memory withModule = bytes.concat(chainArgs, abi.encode(words, moduleLogic));
        string[4] memory names =
            ["LPOracleCLPokeLogic", "LPOracleCLInitLogic", "LPOracleCLListingLogic", "LPOracleCLViewLogic"];
        for (uint256 j = 0; j < 4; ++j) {
            d.clOracleLogics[4 * i + j] = _deploy(
                string.concat(names[j], tag),
                bytes.concat(_artifact(string.concat(names[j], ".sol"), names[j]), withModule)
            );
        }
        // LPOracleLogicSet{poke, init, listing, view}.
        bytes memory set = abi.encode(
            d.clOracleLogics[4 * i],
            d.clOracleLogics[4 * i + 1],
            d.clOracleLogics[4 * i + 2],
            d.clOracleLogics[4 * i + 3]
        );
        d.clOraclePricing[i] = v4
            ? _deploy(
                string.concat("LPOracleV4Implementation", tag),
                bytes.concat(
                    _artifact("LPOracleV4.sol", "LPOracleV4"), chainArgs, abi.encode(moduleLogic), set, abi.encode(weth)
                )
            )
            : _deploy(
                string.concat("LPOracleCLImplementation", tag),
                bytes.concat(_artifact("LPOracleCL.sol", "LPOracleCL"), withModule, set)
            );
    }

    /// @notice The block interval is one value across the chain: the config's `chain.blockTime` is the chain's known
    /// interval (12 s on chains 1 and 11155111, 2 s on 8453, 84532 and 10), and every Uniswap v3 and v4 LPVault's
    /// `BLOCK_TIME` equals the ParameterStore's `CHAIN_BLOCK_TIME`, which sizes `twapMinObservations` (`REQ-AMM-V3-012`).
    function _checkBlockTime(
        ChainInputs memory c,
        AvanaDeployment memory d
    ) internal view {
        uint256 known = block.chainid == 1 || block.chainid == 11_155_111
            ? 12
            : (block.chainid == 8453 || block.chainid == 84_532 || block.chainid == 10 ? 2 : 0);
        require(known == 0 || c.blockTime == known, "chain.blockTime is not the chain's block interval");
        uint256 chainBlockTime = _uintView(d.parameterStore.proxy, "CHAIN_BLOCK_TIME()");
        require(chainBlockTime == c.blockTime, "ParameterStore.CHAIN_BLOCK_TIME != chain.blockTime");
        for (uint256 i = 0; i < d.lpVaults.length; ++i) {
            if (_eq(c.integrations[i].kind, "slipstream")) continue;
            require(
                _uintView(d.lpVaults[i], "BLOCK_TIME()") == chainBlockTime,
                string.concat(
                    "LPVault.",
                    vm.toString(c.integrations[i].integrationId),
                    ".BLOCK_TIME != ParameterStore.CHAIN_BLOCK_TIME"
                )
            );
        }
    }

    function _uintView(
        address target,
        string memory getter
    ) internal view returns (uint256) {
        (bool ok, bytes memory ret) = target.staticcall(abi.encodeWithSignature(getter));
        require(ok && ret.length == 32, string.concat(vm.getLabel(target), ".", getter));
        return abi.decode(ret, (uint256));
    }

    function _addressView(
        address target,
        string memory getter
    ) internal view returns (address a) {
        a = address(uint160(_uintView(target, getter)));
        require(a.code.length != 0, string.concat(getter, " of ", vm.toString(target), " has no code"));
    }

    /// @notice Every address equals its prediction and the immutable cross-references agree.
    function _checkPredictions(
        Predicted memory p,
        AvanaDeployment memory d
    ) internal view {
        require(d.timelock == p.timelock, "timelock");
        require(d.marketRegistry.proxy == p.marketRegistry, "marketRegistry");
        require(d.parameterStore.proxy == p.parameterStore, "parameterStore");
        require(d.riskModule.proxy == p.riskModule, "riskModule");
        require(d.aaveAdapter.proxy == p.aaveAdapter, "aaveAdapter");
        require(d.lpVaultSwap.proxy == p.lpVaultSwap, "lpVaultSwap");
        require(d.lock == p.lock && d.collateralization == p.collateralization, "lock/collateralization");
        require(d.vaultTokenFactory == p.vaultTokenFactory && d.proxyManager == p.proxyManager, "factory/proxyManager");
        require(d.payoutEscrow == p.payoutEscrow && d.flashSource == p.flashSource, "escrow/flashSource");
        require(d.flashLiquidator == p.flashLiquidator, "flashLiquidator");
        _expect(d.lock, "AAVE_ADAPTER()", p.aaveAdapter);
        _expect(d.lock, "LP_VAULT_SWAP()", p.lpVaultSwap);
        _expect(d.collateralization, "LOCK()", p.lock);
        _expect(d.collateralization, "VAULT_TOKEN_FACTORY()", p.vaultTokenFactory);
        _expect(d.vaultTokenFactory, "TIMELOCK()", p.timelock);
        _expect(d.vaultTokenFactory, "COLLATERALIZATION()", p.collateralization);
        _expect(d.payoutEscrow, "LP_VAULT_SWAP()", p.lpVaultSwap);
        _expect(d.marketRegistry.proxy, "PARAMETER_STORE()", p.parameterStore);
        _expect(d.marketRegistry.proxy, "FLASH_LIQUIDATOR()", p.flashLiquidator);
        for (uint256 i = 0; i < d.lpVaults.length; ++i) {
            _expect(d.lpVaults[i], "TIMELOCK()", p.timelock);
            _expect(d.lpVaults[i], "MARKET_REGISTRY()", p.marketRegistry);
        }
    }

    function _expect(
        address target,
        string memory getter,
        address expected
    ) internal view {
        (bool ok, bytes memory ret) = target.staticcall(abi.encodeWithSignature(getter));
        require(
            ok && ret.length == 32 && abi.decode(ret, (address)) == expected,
            string.concat(vm.getLabel(target), ".", getter)
        );
    }
}
