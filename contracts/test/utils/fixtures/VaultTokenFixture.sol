// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {VaultTokenBindings} from "../../../src/types/VaultTokenBindings.sol";
import {VaultToken} from "../../../src/vault-token/vault-token/VaultToken.sol";
import {AvanaTest} from "../AvanaTest.sol";

/// @title VaultTokenFixture
/// @notice One vault token on its own, with every binding at a labelled address: the full-range USDC/USDT market of
/// 2.4 (6 decimals, market 4, integration 1) as the factory would deploy it in the listing batch.
/// @dev The Hub, CDP Spoke, AaveAdapter, LPVaultSwap, Collateralization, LPVault and LPOracle are plain addresses that
/// tests prank as; the token never calls them. Proxies are plain addresses the Adapter registers.
abstract contract VaultTokenFixture is AvanaTest {
    bytes32 internal constant MARKET_KEY = keccak256("avana.test.market.usdc-usdt.full-range");
    uint32 internal constant INTEGRATION_ID = 1;
    uint256 internal constant MARKET_ID = 4;
    uint8 internal constant DECIMALS = 6;
    string internal constant NAME = "Avana USDC/USDT Uniswap v3 Full Range";
    string internal constant SYMBOL = "avUSDC-USDT-v3";

    address internal lpVault = makeAddr("lpVault");
    address internal hub = makeAddr("hub");
    address internal spoke = makeAddr("cdpSpoke");
    address internal lpOracle = makeAddr("lpOracle");
    address internal adapter = makeAddr("aaveAdapter");
    address internal lpVaultSwap = makeAddr("lpVaultSwap");
    address internal collateralization = makeAddr("collateralization");

    address internal proxyA = makeAddr("proxyA");
    address internal proxyB = makeAddr("proxyB");
    address internal wallet = makeAddr("wallet");

    VaultToken internal token;

    function _bindings() internal view returns (VaultTokenBindings memory b) {
        b = VaultTokenBindings({
            marketKey: MARKET_KEY,
            integrationId: INTEGRATION_ID,
            integration: lpVault,
            hub: hub,
            spoke: spoke,
            marketId: MARKET_ID,
            lpOracle: lpOracle,
            adapter: adapter,
            lpVaultSwap: lpVaultSwap,
            collateralization: collateralization,
            decimals: DECIMALS,
            name: NAME,
            symbol: SYMBOL
        });
    }

    function _deployToken() internal {
        token = new VaultToken(_bindings());
        vm.label(address(token), "VaultToken");
    }

    function _register(
        address proxy
    ) internal {
        vm.prank(adapter);
        token.addValidProxy(proxy);
    }

    function _mint(
        address proxy,
        uint256 amount
    ) internal {
        vm.prank(adapter);
        token.mint(proxy, amount);
    }

    /// @notice A pledge's movement: register, mint to the proxy, and supply to the Hub through the Spoke's
    /// `transferFrom` on the proxy's exact allowance.
    function _pledge(
        address proxy,
        uint256 amount
    ) internal {
        if (!token.isValidProxy(proxy)) _register(proxy);
        _mint(proxy, amount);
        vm.prank(proxy);
        token.approve(spoke, amount);
        vm.prank(spoke);
        token.transferFrom(proxy, hub, amount);
    }
}
