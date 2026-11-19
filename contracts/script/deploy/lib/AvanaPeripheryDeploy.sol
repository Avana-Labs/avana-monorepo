// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {AvanaCoreDeploy} from "./AvanaCoreDeploy.sol";
import {AvanaDeployment, ChainInputs, IntegrationInput} from "./DeployTypes.sol";

/// @title AvanaPeripheryDeploy
/// @notice Steps 4–10 of the deployment order: the immutable contracts (Lock, Collateralization, the LPVault of each
/// AMM integration, VaultTokenFactory, ProxyManager, PayoutEscrow and the flash source).
abstract contract AvanaPeripheryDeploy is AvanaCoreDeploy {
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
                abi.encode(p.aaveAdapter, p.lpVaultSwap, p.collateralization, p.accessManager, p.marketRegistry)
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
        // The flash liquidation helpers live in the liquidator/ package, outside the protocol: the MarketRegistry only
        // records the public helper's reserved address.
        d.flashLiquidator = p.flashLiquidator;
        d.lpVaults = new address[](c.integrations.length);
        for (uint256 i = 0; i < c.integrations.length; ++i) {
            d.lpVaults[i] = _deployLpVault(c.integrations[i], p, c.blockTime);
        }
    }

    /// @notice One LPVault (step 6): `UniswapV3Integration` with one position manager, factory and the chain's block
    /// interval (12 s on Ethereum and Sepolia, 2 s on Base, Base Sepolia and OP Mainnet; `REQ-AMM-V3-012`),
    /// `SlipstreamIntegration` with the four generations of 2.21, or `UniswapV4Integration` with the PositionManager, the
    /// Uniswap v3 factory of its reference pools and the block interval (it reads the PoolManager and WETH9 from the
    /// PositionManager).
    function _deployLpVault(
        IntegrationInput memory it,
        Predicted memory p,
        uint32 blockTime
    ) internal returns (address) {
        bytes memory base = abi.encode(it.integrationId, p.collateralization, p.marketRegistry, p.lock, p.accessManager);
        string memory name = string.concat("LPVault.", vm.toString(it.integrationId));
        if (_eq(it.kind, "uniswap-v3")) {
            require(it.positionManagers.length == 1 && it.factories.length == 1, "uniswap-v3: one NPM and factory");
            return _deploy3(
                name,
                bytes.concat(
                    _artifact("UniswapV3Integration.sol", "UniswapV3Integration"),
                    base,
                    abi.encode(it.positionManagers[0], it.factories[0], uint256(blockTime))
                )
            );
        }
        if (_eq(it.kind, "uniswap-v4")) {
            require(
                it.positionManagers.length == 1 && it.factories.length == 1,
                "uniswap-v4: one PositionManager and factory"
            );
            return _deploy3(
                name,
                bytes.concat(
                    _artifact("UniswapV4Integration.sol", "UniswapV4Integration"),
                    base,
                    abi.encode(it.positionManagers[0], it.factories[0], uint256(blockTime))
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
}
