// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IClIntegration} from "../../src/amm/IClIntegration.sol";
import {ClMarketConfig} from "../../src/amm/types/AmmTypes.sol";
import {IUniswapV4Integration} from "../../src/amm/uniswap-v4/IUniswapV4Integration.sol";
import {ILPVaultBase} from "../../src/custody/lp-vault/ILPVaultBase.sol";
import {IAaveV4Spoke} from "../../src/interfaces/external/aave/IAaveV4Spoke.sol";
import {UniswapV4PoolKey} from "../../src/interfaces/external/uniswap-v4/IUniswapV4PoolManager.sol";
import {IMarketRegistryBase} from "../../src/policy/market-registry/IMarketRegistryBase.sol";
import {RiskTier, SpokeDef} from "../../src/policy/market-registry/types/MarketRegistryTypes.sol";
import {Market, MarketDef} from "../../src/types/MarketTypes.sol";
import {PositionShape, ShapeKind} from "../../src/types/PositionTypes.sol";
import {IClFactory, IClPool} from "../utils/fixtures/ClPoolFixture.sol";
import {MarketRegistryFixture} from "../utils/fixtures/MarketRegistryFixture.sol";
import {TestWETH9} from "../utils/fixtures/UniswapV4WorldFixture.sol";
import {RegistryAaveOracleMock, RegistrySpokeMock} from "../utils/mocks/MarketRegistryAaveMocks.sol";
import {RegistryLPOracleMock, RegistryRouteMock} from "../utils/mocks/MarketRegistryMocks.sol";

/// @notice The PoolManager's `initialize` (v4-core v4.0.0; `Currency` and `IHooks` are addresses).
interface IV4PoolManagerInitialize {
    function initialize(
        UniswapV4PoolKey memory key,
        uint160 sqrtPriceX96
    ) external returns (int24 tick);
}

/// @title MarketRegistryUniswapV4ListingUnitTest
/// @notice A listing against the real Uniswap v4 LPVault, on the pinned PoolManager, PositionManager and Uniswap v3
/// factory (the reference pools'), with the PoolKey, reference pool and listing prices in `integrationData`: the
/// registry binds the market in the integration by `PoolId` with no pool address, the integration validates the key
/// against its PoolManager and the reference pool against the factory, and fixes the vault-token decimals; the
/// PositionManager and its PoolManager are recorded and finalized, so routes are accepted and none may run through
/// them. The same suite as the Uniswap v3 listing's.
contract MarketRegistryUniswapV4ListingUnitTest is MarketRegistryFixture {
    uint32 internal constant UNI4 = 3;
    uint256 internal constant GHO_ON_UNI4 = 0;

    address internal poolManager;
    address internal positionManager;
    address internal refFactory;
    address internal refPool;
    UniswapV4PoolKey internal key;
    bytes32 internal poolId;
    IUniswapV4Integration internal uni4;
    RegistrySpokeMock internal uni4Spoke;

    function setUp() public {
        _setUpWorld();
        address weth = address(new TestWETH9());
        poolManager = deployCode("out-univ4/PoolManager.sol/PoolManager.json", abi.encode(address(this)));
        address permit2 = deployCode("out-permit2/Permit2.sol/Permit2.json");
        positionManager = deployCode(
            "out-univ4/PositionManager.sol/PositionManager.json",
            abi.encode(poolManager, permit2, uint256(100_000), address(0), weth)
        );
        refFactory = deployCode("out-univ3/UniswapV3Factory.sol/UniswapV3Factory.json");
        (address t0, address t1) =
            address(usdc) < address(usdt) ? (address(usdc), address(usdt)) : (address(usdt), address(usdc));
        refPool = IClFactory(refFactory).createPool(t0, t1, 500);
        IClPool(refPool).initialize(uint160(1) << 96);
        key = UniswapV4PoolKey(t0, t1, 100, 1, address(0));
        poolId = keccak256(abi.encode(key));
        IV4PoolManagerInitialize(poolManager).initialize(key, uint160(1) << 96);
        // The registry's token mocks have no supply; the LPVault requires one below 2^127 (`REQ-AMM-V4-009`).
        vm.mockCall(address(usdc), abi.encodeWithSignature("totalSupply()"), abi.encode(uint256(1e18)));
        vm.mockCall(address(usdt), abi.encodeWithSignature("totalSupply()"), abi.encode(uint256(1e18)));
        uni4 = IUniswapV4Integration(
            deployCode(
                "UniswapV4Integration.sol:UniswapV4Integration",
                abi.encode(
                    UNI4,
                    address(collat),
                    address(registry),
                    lockAddr,
                    address(accessManager),
                    positionManager,
                    refFactory,
                    uint256(12)
                )
            )
        );
        vm.label(address(uni4), "UniswapV4LPVault");
        address[] memory amm = new address[](2);
        (amm[0], amm[1]) = (positionManager, poolManager);
        vm.startPrank(governor);
        factory.registerIntegration(UNI4, address(uni4));
        registry.recordIntegrationContracts(UNI4, amm);
        registry.finalizeIntegrationContracts(UNI4);
        vm.stopPrank();
        _deployUni4Spoke();
    }

    /// @dev The CDP Spoke of the Uniswap v4 integration on the Stable LP Hub, with GHO enabled as its debt reserve.
    function _deployUni4Spoke() internal {
        uni4Spoke = new RegistrySpokeMock();
        RegistryAaveOracleMock o = new RegistryAaveOracleMock();
        uni4Spoke.setOracle(address(o));
        uni4Spoke.setImplementation(address(spokeImpl));
        o.setSpoke(address(uni4Spoke));
        vm.prank(governor);
        registry.deployCdpSpoke(
            SpokeDef({
                approved: false,
                hub: address(hub),
                integrationId: UNI4,
                riskTier: RiskTier.Stable,
                implementation: address(spokeImpl),
                aaveOracle: address(o)
            })
        );
        IAaveV4Spoke.Reserve memory r;
        (r.underlying, r.hub, r.assetId, r.decimals) = (address(gho), address(hub), uint16(GHO_ASSET), 18);
        IAaveV4Spoke.ReserveConfig memory c;
        c.borrowable = true;
        IAaveV4Spoke.DynamicReserveConfig memory d;
        uni4Spoke.setReserve(GHO_ON_UNI4, r, c, d);
        o.setSource(GHO_ON_UNI4, address(ghoSource));
        hub.setSpokeConfig(GHO_ASSET, address(uni4Spoke), 0, 1_000_000);
        vm.prank(governor);
        registry.enableDebtReserve(address(uni4Spoke), _ghoDef());
    }

    function _v4Shape() internal pure returns (PositionShape memory) {
        return PositionShape(ShapeKind.TickRange, -50, 50);
    }

    /// @dev The PoolKey, the reference pool and the listing prices of the two stablecoins (8 decimals: USDC $1.0000,
    /// USDT $0.9998).
    function _data() internal view returns (bytes memory) {
        return abi.encode(key, refPool, uint256(1e8), uint256(0.9998e8));
    }

    /// @dev The unit decimals the integration fixes for the market, read by binding in a discarded state.
    function _unitDecimals(
        uint256 marketId
    ) internal returns (uint8 d) {
        uint256 snap = vm.snapshotState();
        vm.prank(address(registry));
        (, d) = uni4.bindMarket(marketId, address(0), poolId, _v4Shape(), _data());
        vm.revertToState(snap);
    }

    function _uni4Def(
        bytes memory integrationData
    ) internal returns (MarketDef memory d, uint8 unitDecimals) {
        uint256 id = registry.marketCount() + 1;
        unitDecimals = _unitDecimals(id);
        RegistryLPOracleMock lpOracle = new RegistryLPOracleMock(id, address(uni4));
        vm.prank(governor);
        address vaultToken = factory.deployVaultToken(
            UNI4,
            address(0),
            poolId,
            _v4Shape(),
            address(hub),
            address(uni4Spoke),
            id,
            address(lpOracle),
            unitDecimals,
            "Avana USDC/USDT v4 0.01%",
            "avUSDC-USDT-v4-1"
        );
        (d.hub, d.spoke, d.integrationId, d.pool, d.poolId, d.shape) =
        (address(hub), address(uni4Spoke), UNI4, address(0), poolId, _v4Shape());
        (d.vaultToken, d.lpOracle, d.integrationData) = (vaultToken, address(lpOracle), integrationData);
    }

    // TEST-138 verifies: REQ-CONFIG-078, REQ-CONFIG-029, REQ-CONFIG-030, REQ-CONFIG-008, REQ-MREG-035, REQ-AMM-V4-001, REQ-AMM-V4-007
    /// @notice Without the PoolKey data the integration refuses the binding, and so the listing; with it the market is
    /// listed by `PoolId` with no pool address, and the integration holds the key, the reference pool and its own
    /// PositionManager and PoolManager.
    function test_TEST_138_listsAgainstTheRealUniswapV4Integration() public {
        (MarketDef memory d, uint8 unitDecimals) = _uni4Def(_data());
        d.integrationData = "";
        vm.prank(governor);
        vm.expectRevert(ILPVaultBase.InvalidPool.selector);
        registry.listCollateralMarket(d);
        d.integrationData = _data();
        vm.prank(governor);
        uint256 id = registry.listCollateralMarket(d);
        assertEq(id, registry.marketCount());
        Market memory m = registry.getMarket(id);
        assertEq(m.integration, address(uni4));
        assertEq(m.integrationId, UNI4);
        assertEq(m.pool, address(0), "no pool address");
        assertEq(m.poolId, poolId, "the PoolId");
        assertEq(m.decimals, unitDecimals);
        assertEq(m.tokens.length, 2);
        assertEq(m.tokens[0], key.currency0);
        assertEq(m.tokens[1], key.currency1);
        (address pool_, bytes32 poolId_, PositionShape memory sh,) = uni4.marketOf(id);
        assertEq(pool_, address(0));
        assertEq(poolId_, poolId);
        assertEq(sh.tickLower, -50);
        assertEq(sh.tickUpper, 50);
        IUniswapV4Integration.V4Market memory v = uni4.v4Market(id);
        assertEq(keccak256(abi.encode(v.key)), poolId, "the stored key hashes to the PoolId");
        assertEq(v.referencePool, refPool);
        ClMarketConfig memory cfg = IClIntegration(address(uni4)).clMarket(id);
        assertEq(cfg.positionManager, positionManager);
        assertEq(cfg.factory, poolManager, "the PoolManager in the factory slot");
        assertEq(cfg.fee, 100);
    }

    // TEST-054 verifies: REQ-CONFIG-040, REQ-MREG-035
    /// @notice The market's routes are accepted once the integration's record is finalized; a route through the
    /// recorded PositionManager or PoolManager is refused, one through another pool is accepted.
    function test_TEST_054_routesOfTheRealIntegrationAvoidItsRecordedContracts() public {
        (MarketDef memory d,) = _uni4Def(_data());
        vm.prank(governor);
        uint256 id = registry.listCollateralMarket(d);
        address[2] memory bad = [positionManager, poolManager];
        for (uint256 i = 0; i < bad.length; ++i) {
            address[] memory deps = new address[](1);
            deps[0] = bad[i];
            address route = address(new RegistryRouteMock(address(usdc), address(gho), address(lpVaultSwap), deps));
            vm.prank(governor);
            vm.expectRevert(IMarketRegistryBase.InvalidRoute.selector);
            registry.setRoute(id, address(usdc), address(gho), 0, route);
        }
        address ok = address(_newRoute(address(usdc), address(gho), "otherPool"));
        vm.prank(governor);
        registry.setRoute(id, address(usdc), address(gho), 0, ok);
        (address r, bool usable) = registry.getRoute(id, address(usdc), address(gho), 0);
        assertTrue(r == ok && usable);
    }
}
