// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IClIntegration} from "../../src/amm/IClIntegration.sol";
import {ClMarketConfig} from "../../src/amm/types/ClMarketConfig.sol";
import {ILPVaultErrors} from "../../src/custody/lp-vault/ILPVaultErrors.sol";
import {IAaveV4Spoke} from "../../src/interfaces/external/aave/IAaveV4Spoke.sol";
import {IMarketRegistryErrors} from "../../src/policy/market-registry/IMarketRegistryErrors.sol";
import {RiskTier} from "../../src/policy/market-registry/types/RiskTier.sol";
import {SpokeDef} from "../../src/policy/market-registry/types/SpokeDef.sol";
import {Market} from "../../src/types/Market.sol";
import {MarketDef} from "../../src/types/MarketDef.sol";
import {PositionShape} from "../../src/types/PositionShape.sol";
import {ShapeKind} from "../../src/types/ShapeKind.sol";
import {MarketRegistryFixture} from "../utils/fixtures/MarketRegistryFixture.sol";
import {UniswapV3IntegrationHarness} from "../utils/harness/UniswapV3IntegrationHarness.sol";
import {RegistryAaveOracleMock, RegistrySpokeMock} from "../utils/mocks/MarketRegistryAaveMocks.sol";
import {RegistryLPOracleMock, RegistryRouteMock} from "../utils/mocks/MarketRegistryMocks.sol";
import {MockNFPM, MockV3Factory} from "../utils/mocks/UniswapV3Mocks.sol";

/// @notice A listing against the real Uniswap v3 LPVault (the deployed contract with the mock factory's pool init code
/// hash, see `UniswapV3IntegrationHarness`) with real listing prices in `integrationData`, instead of the fixture's mock
/// LPVault and empty data: the registry binds the market in the integration, which validates the pool against its
/// factory and fixes the vault-token decimals from the prices; the integration's position manager and factory are
/// recorded and finalized, so routes are accepted and none may run through them.
contract MarketRegistryUniswapV3ListingUnitTest is MarketRegistryFixture {
    uint32 internal constant UNI = 2;
    uint256 internal constant GHO_ON_UNI = 0;

    MockV3Factory internal v3Factory;
    MockNFPM internal nfpm;
    address internal v3Pool;
    UniswapV3IntegrationHarness internal uni;
    RegistrySpokeMock internal uniSpoke;

    function setUp() public {
        _setUpWorld();
        v3Factory = new MockV3Factory();
        nfpm = new MockNFPM(address(v3Factory));
        v3Pool = v3Factory.createPool(address(usdc), address(usdt), 500, 10);
        uni = new UniswapV3IntegrationHarness(
            UNI,
            address(collat),
            address(registry),
            lockAddr,
            address(timelock),
            address(nfpm),
            address(v3Factory),
            v3Factory.poolInitCodeHash()
        );
        vm.label(address(uni), "UniswapV3LPVault");
        address[] memory amm = new address[](2);
        (amm[0], amm[1]) = (address(nfpm), address(v3Factory));
        vm.startPrank(address(timelock));
        factory.registerIntegration(UNI, address(uni));
        registry.registerIntegration(UNI, address(uni), makeAddr("uniPricing"));
        registry.recordIntegrationContracts(UNI, amm);
        registry.finalizeIntegrationContracts(UNI);
        vm.stopPrank();
        _deployUniSpoke();
    }

    /// @dev The CDP Spoke of the Uniswap v3 integration on the Stable LP Hub, with GHO enabled as its debt reserve.
    function _deployUniSpoke() internal {
        uniSpoke = new RegistrySpokeMock();
        RegistryAaveOracleMock o = new RegistryAaveOracleMock();
        uniSpoke.setOracle(address(o));
        uniSpoke.setImplementation(address(spokeImpl));
        o.setSpoke(address(uniSpoke));
        vm.prank(address(timelock));
        registry.deployCdpSpoke(
            SpokeDef({
                approved: false,
                hub: address(hub),
                integrationId: UNI,
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
        uniSpoke.setReserve(GHO_ON_UNI, r, c, d);
        o.setSource(GHO_ON_UNI, address(ghoSource));
        hub.setSpokeConfig(GHO_ASSET, address(uniSpoke), 0, 1_000_000);
        vm.prank(address(timelock));
        registry.enableDebtReserve(address(uniSpoke), _ghoDef());
    }

    function _uniShape() internal pure returns (PositionShape memory) {
        return PositionShape(ShapeKind.TickRange, -50, 50);
    }

    /// @dev The listing prices of the two stablecoins, 8 decimals: USDC $1.0000, USDT $0.9998.
    function _prices() internal pure returns (bytes memory) {
        return abi.encode(uint256(1e8), uint256(0.9998e8));
    }

    /// @dev The unit decimals the integration fixes for the market at `prices`, read by binding in a discarded state.
    function _unitDecimals(
        uint256 marketId,
        bytes memory prices
    ) internal returns (uint8 d) {
        uint256 snap = vm.snapshotState();
        vm.prank(address(registry));
        (, d) = uni.bindMarket(marketId, v3Pool, bytes32(0), _uniShape(), prices);
        vm.revertToState(snap);
    }

    function _uniDef(
        bytes memory integrationData
    ) internal returns (MarketDef memory d, uint8 unitDecimals) {
        uint256 id = registry.marketCount() + 1;
        unitDecimals = _unitDecimals(id, _prices());
        RegistryLPOracleMock lpOracle = new RegistryLPOracleMock(id, address(uni));
        vm.prank(address(timelock));
        address vaultToken = factory.deployVaultToken(
            UNI,
            v3Pool,
            bytes32(0),
            _uniShape(),
            address(hub),
            address(uniSpoke),
            id,
            address(lpOracle),
            unitDecimals,
            "Avana USDC/USDT 0.05%",
            "avUSDC-USDT-5"
        );
        (d.hub, d.spoke, d.integrationId, d.pool, d.shape) = (address(hub), address(uniSpoke), UNI, v3Pool, _uniShape());
        (d.vaultToken, d.lpOracle, d.integrationData) = (vaultToken, address(lpOracle), integrationData);
    }

    // TEST-138 verifies: REQ-CONFIG-078, REQ-CONFIG-029, REQ-CONFIG-030, REQ-CONFIG-031, REQ-CONFIG-008, REQ-MREG-035
    // Sources: decisions of 2026-11-11 (a listing with a real integration and real price `integrationData`)
    function test_TEST_138_listsAgainstTheRealUniswapV3Integration() public {
        (MarketDef memory d, uint8 unitDecimals) = _uniDef(_prices());
        // Without listing prices (the fixture's empty data) the integration refuses the binding, and so the listing.
        d.integrationData = "";
        vm.prank(address(timelock));
        vm.expectRevert(ILPVaultErrors.InvalidPool.selector);
        registry.listCollateralMarket(d);
        d.integrationData = _prices();
        vm.prank(address(timelock));
        uint256 id = registry.listCollateralMarket(d);
        assertEq(id, registry.marketCount());
        Market memory m = registry.getMarket(id);
        assertEq(m.integration, address(uni));
        assertEq(m.integrationId, UNI);
        assertEq(m.pool, v3Pool);
        assertEq(m.decimals, unitDecimals);
        (address t0, address t1) =
            address(usdc) < address(usdt) ? (address(usdc), address(usdt)) : (address(usdt), address(usdc));
        assertEq(m.tokens.length, 2);
        assertEq(m.tokens[0], t0);
        assertEq(m.tokens[1], t1);
        // The integration holds the binding the registry made, with its own position manager and factory.
        (address pool_,, PositionShape memory sh,) = uni.marketOf(id);
        assertEq(pool_, v3Pool);
        assertEq(sh.tickLower, -50);
        assertEq(sh.tickUpper, 50);
        ClMarketConfig memory cfg = IClIntegration(address(uni)).clMarket(id);
        assertEq(cfg.positionManager, address(nfpm));
        assertEq(cfg.factory, address(v3Factory));
        assertEq(cfg.fee, 500);
    }

    // TEST-054 verifies: REQ-CONFIG-040, REQ-MREG-035
    // The market's routes are accepted once the integration's record is finalized; a route through the recorded
    // position manager or factory, or through the market's own pool, is refused.
    function test_TEST_054_routesOfTheRealIntegrationAvoidItsRecordedContracts() public {
        (MarketDef memory d,) = _uniDef(_prices());
        vm.prank(address(timelock));
        uint256 id = registry.listCollateralMarket(d);
        address[3] memory bad = [address(nfpm), address(v3Factory), v3Pool];
        for (uint256 i = 0; i < bad.length; ++i) {
            address[] memory deps = new address[](1);
            deps[0] = bad[i];
            address route = address(new RegistryRouteMock(address(usdc), address(gho), address(lpVaultSwap), deps));
            vm.prank(address(timelock));
            vm.expectRevert(IMarketRegistryErrors.InvalidRoute.selector);
            registry.setRoute(id, address(usdc), address(gho), 0, route);
        }
        address ok = address(_newRoute(address(usdc), address(gho), "otherUniPool"));
        vm.prank(address(timelock));
        registry.setRoute(id, address(usdc), address(gho), 0, ok);
        (address r, bool usable) = registry.getRoute(id, address(usdc), address(gho), 0);
        assertTrue(r == ok && usable);
    }
}
