// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {AvanaPeripheryDeploy} from "./AvanaPeripheryDeploy.sol";
import {AvanaDeployment, ChainInputs} from "./DeployTypes.sol";
import {console2} from "forge-std/console2.sol";

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
        d.clOraclePricing = _deployClOraclePricing(c, p);
        _checkPredictions(p, d);
    }

    /// @notice One concentrated-liquidity LPOracle implementation per chain (with its poke, listing and view logic),
    /// the `pricing` each concentrated-liquidity integration registers. Zero, with a message, while `LPOracleCL` is not
    /// in the build: the integrations are then left out of the wiring operation and no market can be listed.
    /// @dev `slot0Words` is 7 for Uniswap v3 and 6 for Slipstream, so a chain with both protocols needs one
    /// implementation per protocol; the first integration's protocol is the one deployed here, and `04_ConfigureAccess`
    /// refuses a second protocol without its own implementation.
    function _deployClOraclePricing(
        ChainInputs memory c,
        Predicted memory p
    ) internal returns (address impl) {
        if (!_hasArtifact(CL_ORACLE_FILE, CL_ORACLE)) {
            console2.log("BLOCKED: LPOracleCL is not in this build (src/oracle/lp-oracle/LPOracleCL.sol).");
            console2.log("  Integrations are deployed but not registered; no market can be listed until it lands.");
            return address(0);
        }
        if (c.integrations.length == 0) return address(0);
        uint8 words = _eq(c.integrations[0].kind, "slipstream") ? 6 : 7;
        bytes memory args =
            abi.encode(p.timelock, c.blockTime, CL_POKE_MIN_GAS_FLOOR, CL_POKE_MIN_GAS_CEILING, c.hasSequencer, words);
        address poke =
            _deploy("LPOracleCLPokeLogic", bytes.concat(_artifact("LPOracleCLLogic.sol", "LPOracleCLPokeLogic"), args));
        address listing = _deploy(
            "LPOracleCLListingLogic", bytes.concat(_artifact("LPOracleCLLogic.sol", "LPOracleCLListingLogic"), args)
        );
        address views =
            _deploy("LPOracleCLViewLogic", bytes.concat(_artifact("LPOracleCLLogic.sol", "LPOracleCLViewLogic"), args));
        impl = _deploy(
            "LPOracleCLImplementation",
            bytes.concat(_artifact(CL_ORACLE_FILE, CL_ORACLE), args, abi.encode(poke, listing, views))
        );
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
