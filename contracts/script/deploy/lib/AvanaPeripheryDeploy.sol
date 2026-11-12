// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {AvanaCoreDeploy} from "./AvanaCoreDeploy.sol";
import {AvanaDeployment, ChainInputs, IntegrationInput} from "./DeployTypes.sol";

/// @title AvanaPeripheryDeploy
/// @notice Steps 4–11 of the deployment order: the immutable contracts (Lock, Collateralization, the LPVault of each
/// AMM integration, VaultTokenFactory, ProxyManager, PayoutEscrow, the flash source and the flash liquidation
/// helpers), the Lens, the DebtOracle implementation and the concentrated-liquidity LPOracle implementation.
abstract contract AvanaPeripheryDeploy is AvanaCoreDeploy {
    /// @notice Source file and contract name of the concentrated-liquidity LPOracle implementation, its logic contracts
    /// and the LPOracle `slot0` word counts; the contract is written separately and wired here by name.
    string internal constant CL_ORACLE_FILE = "LPOracleCL.sol";
    string internal constant CL_ORACLE = "LPOracleCL";

    function _deployImmutables(
        ChainInputs memory c,
        Predicted memory p,
        AvanaDeployment memory d
    ) internal {
        d.lock = _deploy3("Lock", bytes.concat(_artifact("Lock.sol", "Lock"), abi.encode(p.aaveAdapter, p.lpVaultSwap)));
        d.collateralization = _deploy3(
            "Collateralization",
            bytes.concat(
                _artifact("Collateralization.sol", "Collateralization"),
                abi.encode(p.aaveAdapter, p.lpVaultSwap, p.riskModule, p.lock, p.vaultTokenFactory)
            )
        );
        d.vaultTokenFactory = _deploy3(
            "VaultTokenFactory",
            bytes.concat(
                _artifact("VaultTokenFactory.sol", "VaultTokenFactory"),
                abi.encode(p.aaveAdapter, p.lpVaultSwap, p.collateralization, p.timelock, p.marketRegistry)
            )
        );
        d.proxyManager = _deploy3(
            "ProxyManager",
            bytes.concat(_artifact("ProxyManager.sol", "ProxyManager"), abi.encode(p.aaveAdapter, p.marketRegistry))
        );
        d.payoutEscrow = _deploy3(
            "PayoutEscrow",
            bytes.concat(_artifact("PayoutEscrow.sol", "PayoutEscrow"), abi.encode(p.lpVaultSwap, p.lock))
        );
        d.flashSource = _deploy3(
            "AaveV3FlashSource",
            bytes.concat(
                _artifact("AaveV3FlashSource.sol", "AaveV3FlashSource"),
                abi.encode(c.aave.v3Pool, p.lpVaultSwap, p.parameterStore)
            )
        );
        d.flashLiquidator = _deploy3(
            "FlashLiquidator",
            bytes.concat(
                _artifact("FlashLiquidator.sol", "FlashLiquidator"),
                abi.encode(c.aave.v3Pool, p.lpVaultSwap, p.marketRegistry, p.parameterStore)
            )
        );
        d.operatorHelpers = new address[](c.operatorHelpers.length);
        for (uint256 i = 0; i < c.operatorHelpers.length; ++i) {
            d.operatorHelpers[i] = _deploy3(
                string.concat("OperatorFlashLiquidator.", vm.toString(i)),
                bytes.concat(
                    _artifact("OperatorFlashLiquidator.sol", "OperatorFlashLiquidator"),
                    abi.encode(
                        c.aave.v3Pool,
                        p.lpVaultSwap,
                        p.marketRegistry,
                        p.parameterStore,
                        c.operatorHelpers[i].signer,
                        c.operatorHelpers[i].fundingSafe,
                        c.operatorHelpers[i].maxTopUpBps
                    )
                )
            );
        }
        d.lpVaults = new address[](c.integrations.length);
        for (uint256 i = 0; i < c.integrations.length; ++i) {
            d.lpVaults[i] = _deployLpVault(c.integrations[i], p);
        }
    }

    /// @notice One LPVault (step 6): `UniswapV3Integration` with one position manager and factory, or
    /// `SlipstreamIntegration` with the four generations of 2.21.
    function _deployLpVault(
        IntegrationInput memory it,
        Predicted memory p
    ) internal returns (address) {
        bytes memory base = abi.encode(it.integrationId, p.collateralization, p.marketRegistry, p.lock, p.timelock);
        string memory name = string.concat("LPVault.", vm.toString(it.integrationId));
        if (_eq(it.kind, "uniswap-v3")) {
            require(it.positionManagers.length == 1 && it.factories.length == 1, "uniswap-v3: one NPM and factory");
            return _deploy3(
                name,
                bytes.concat(
                    _artifact("UniswapV3Integration.sol", "UniswapV3Integration"),
                    base,
                    abi.encode(it.positionManagers[0], it.factories[0])
                )
            );
        }
        require(_eq(it.kind, "slipstream"), string.concat("unknown integration kind ", it.kind));
        require(it.positionManagers.length == 4 && it.factories.length == 4, "slipstream: four generations");
        address[4] memory npms =
            [it.positionManagers[0], it.positionManagers[1], it.positionManagers[2], it.positionManagers[3]];
        address[4] memory factories = [it.factories[0], it.factories[1], it.factories[2], it.factories[3]];
        return _deploy3(
            name,
            bytes.concat(
                _artifact("SlipstreamIntegration.sol", "SlipstreamIntegration"), base, abi.encode(npms, factories)
            )
        );
    }

    /// @notice Step 11: the Lens over its eight modules and Aave's liquidation sizing (`REQ-LENS-001`).
    function _deployLens(
        AvanaDeployment memory d
    ) internal {
        d.lensAaveSizing = _deploy("LensAaveSizing", _artifactIn("out-aave", "LensAaveSizing.sol", "LensAaveSizing"));
        address[9] memory c9;
        (c9[0], c9[1], c9[2]) = (d.collateralization, d.proxyManager, d.aaveAdapter.proxy);
        (c9[3], c9[4], c9[5]) = (d.lock, d.marketRegistry.proxy, d.parameterStore.proxy);
        (c9[6], c9[7], c9[8]) = (d.riskModule.proxy, d.lpVaultSwap.proxy, d.payoutEscrow);
        bytes memory core = abi.encode(c9);
        string[8] memory names = [
            "LensAccountModule",
            "LensMarketModule",
            "LensPriceModule",
            "LensLiquidationModule",
            "LensRiskModule",
            "LensPreviewModule",
            "LensMarketsModule",
            "LensPositionsModule"
        ];
        d.lensModules = new address[](8);
        for (uint256 i = 0; i < 8; ++i) {
            bytes memory args = i == 3 ? bytes.concat(core, abi.encode(d.lensAaveSizing)) : core;
            d.lensModules[i] =
                _deploy(names[i], bytes.concat(_artifact(string.concat(names[i], ".sol"), names[i]), args));
        }
        address[8] memory m;
        for (uint256 i = 0; i < 8; ++i) {
            m[i] = d.lensModules[i];
        }
        d.lens = _deploy3("Lens", bytes.concat(_artifact("Lens.sol", "Lens"), abi.encode(m)));
    }

    /// @notice The DebtOracle implementation every non-GHO debt reserve's proxy uses (`REQ-DEBTORACLE-001`); proxies are
    /// created at debt-reserve listing, because `initialize` reads the listed asset.
    function _deployDebtOracleImplementation(
        Predicted memory p
    ) internal returns (address) {
        return _deploy(
            "DebtOracleImplementation", bytes.concat(_artifact("DebtOracle.sol", "DebtOracle"), abi.encode(p.timelock))
        );
    }
}
