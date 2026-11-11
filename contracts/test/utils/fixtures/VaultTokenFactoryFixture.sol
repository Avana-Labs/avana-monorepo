// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {PositionShape} from "../../../src/types/PositionShape.sol";
import {ShapeKind} from "../../../src/types/ShapeKind.sol";
import {VaultTokenFactory} from "../../../src/vault-token/vault-token-factory/VaultTokenFactory.sol";
import {CollateralizationLockMock} from "../mocks/CollateralizationLockMock.sol";
import {LPVaultIdentityMock} from "../mocks/LPVaultIdentityMock.sol";
import {TimelockFixture} from "./TimelockFixture.sol";

/// @title VaultTokenFactoryFixture
/// @notice The chain's VaultTokenFactory behind the launch AvanaTimelock, with the Uniswap v3 LPVault registered as
/// integration 1 and the full-range USDC/USDT listing of 2.4 (`marketId` 4, 6 decimals) ready to deploy.
/// @dev The AaveAdapter, Hub, CDP Spoke, LPOracle and pool are plain addresses: the factory and the token never call
/// them. Collateralization and the LPVault are mocks answering the identity getters `registerIntegration` reads.
abstract contract VaultTokenFactoryFixture is TimelockFixture {
    uint32 internal constant V3_ID = 1;
    uint32 internal constant SLIPSTREAM_ID = 2;
    bytes32 internal constant UNISWAP_V3 = keccak256("UNISWAP_V3");
    bytes32 internal constant AERODROME_SLIPSTREAM = keccak256("AERODROME_SLIPSTREAM");
    uint256 internal constant MARKET_ID = 4;
    uint8 internal constant DECIMALS = 6;
    int24 internal constant FULL_LOWER = -887_270;
    int24 internal constant FULL_UPPER = 887_270;
    string internal constant NAME =
        "Avana LP Ethereum Uniswap v3 USDC/USDT 0.01% full range (-887270 to 887270) market 4";
    string internal constant SYMBOL = "avLP-4";

    /// @notice One `deployVaultToken` argument list, without name and symbol.
    struct Listing {
        uint32 integrationId;
        address pool;
        bytes32 poolId;
        PositionShape shape;
        address hub;
        address spoke;
        uint256 marketId;
        address lpOracle;
        uint8 decimals;
    }

    address internal adapter = makeAddr("aaveAdapter");
    address internal lock = makeAddr("lock");
    address internal hub = makeAddr("stableLpHub");
    address internal spoke = makeAddr("uniswapV3StableSpoke");
    address internal successorSpoke = makeAddr("uniswapV3StableSpoke2");
    address internal lpOracle = makeAddr("lpOracleUsdcUsdt");
    address internal pool = makeAddr("usdcUsdtPool");

    VaultTokenFactory internal factory;
    CollateralizationLockMock internal collateralization;
    LPVaultIdentityMock internal v3Vault;

    function _deployFactory() internal {
        _deployTimelock();
        collateralization = new CollateralizationLockMock(lock);
        vm.label(address(collateralization), "Collateralization");
        factory = new VaultTokenFactory(
            adapter, address(lpVaultSwap), address(collateralization), address(timelock), address(marketRegistry)
        );
        vm.label(address(factory), "VaultTokenFactory");
        collateralization.setCore(address(factory), adapter, address(lpVaultSwap));
        v3Vault = _vault(V3_ID, UNISWAP_V3);
        vm.label(address(v3Vault), "UniswapV3LPVault");
    }

    function _vault(
        uint32 id,
        bytes32 protocol
    ) internal returns (LPVaultIdentityMock) {
        return new LPVaultIdentityMock(
            id, address(collateralization), lock, protocol, address(timelock), address(marketRegistry)
        );
    }

    function _register(
        uint32 id,
        address vault
    ) internal {
        vm.prank(address(timelock));
        factory.registerIntegration(id, vault);
    }

    function _fullRange() internal pure returns (PositionShape memory) {
        return PositionShape(ShapeKind.TickRange, FULL_LOWER, FULL_UPPER);
    }

    function _listing() internal view returns (Listing memory l) {
        l = Listing({
            integrationId: V3_ID,
            pool: pool,
            poolId: bytes32(0),
            shape: _fullRange(),
            hub: hub,
            spoke: spoke,
            marketId: MARKET_ID,
            lpOracle: lpOracle,
            decimals: DECIMALS
        });
    }

    function _deployCall(
        Listing memory l
    ) internal view returns (bytes memory) {
        return abi.encodeCall(
            factory.deployVaultToken,
            (
                l.integrationId,
                l.pool,
                l.poolId,
                l.shape,
                l.hub,
                l.spoke,
                l.marketId,
                l.lpOracle,
                l.decimals,
                NAME,
                SYMBOL
            )
        );
    }

    /// @notice Calls `deployVaultToken` as `caller` (the prank covers only that call) and returns the token address.
    function _deployAs(
        address caller,
        Listing memory l
    ) internal returns (address token) {
        vm.prank(caller);
        token = factory.deployVaultToken(
            l.integrationId, l.pool, l.poolId, l.shape, l.hub, l.spoke, l.marketId, l.lpOracle, l.decimals, NAME, SYMBOL
        );
    }

    function _deploy(
        Listing memory l
    ) internal returns (address) {
        return _deployAs(address(timelock), l);
    }

    function _key(
        Listing memory l
    ) internal view returns (bytes32) {
        return factory.marketKeyOf(l.integrationId, l.pool, l.poolId, l.shape);
    }
}
