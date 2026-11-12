// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {RiskStatus} from "../../src/amm/types/RiskStatus.sol";
import {ICollateralizationViews} from "../../src/custody/collateralization/ICollateralizationViews.sol";
import {IAaveV4Spoke} from "../../src/interfaces/external/aave/IAaveV4Spoke.sol";
import {IMarketRegistryErrors} from "../../src/policy/market-registry/IMarketRegistryErrors.sol";
import {MarketStatus} from "../../src/policy/market-registry/types/MarketStatus.sol";
import {IParameterStoreErrors} from "../../src/policy/parameter-store/IParameterStoreErrors.sol";
import {IPoolObservations} from "../../src/policy/parameter-store/IPoolObservations.sol";
import {FeedDef} from "../../src/policy/parameter-store/types/FeedDef.sol";
import {MarketParams} from "../../src/policy/parameter-store/types/MarketParams.sol";
import {OracleInputsLayout} from "../../src/policy/parameter-store/types/OracleInputsLayout.sol";
import {MarketDef} from "../../src/types/MarketDef.sol";
import {PledgeCounters} from "../../src/types/PledgeCounters.sol";
import {PositionShape} from "../../src/types/PositionShape.sol";
import {RouteSlot} from "../../src/types/RouteSlot.sol";
import {ShapeKind} from "../../src/types/ShapeKind.sol";
import {ParameterStoreRegistryFixture} from "../utils/fixtures/ParameterStoreRegistryFixture.sol";
import {RegistryLPOracleMock, RegistryRouteMock} from "../utils/mocks/MarketRegistryMocks.sol";
import {MockAggregator} from "../utils/mocks/ParameterStoreMocks.sol";

/// @notice The real ParameterStore against the real MarketRegistry: every scope check, route read, debt-reserve scan
/// and liveness evaluation of the store reads the registry's own records, and the registry's listing and
/// activation read the store's values back.
contract ParameterStoreMarketRegistryIntegrationTest is ParameterStoreRegistryFixture {
    uint256 internal constant VT_ASSET = 1;
    uint256 internal constant VT_RESERVE = 1;
    bytes internal oob = abi.encodeWithSelector(IParameterStoreErrors.OutOfBounds.selector);

    function setUp() public {
        _setUpWorld();
    }

    function _refuses(
        bytes memory data,
        bytes memory err
    ) internal {
        vm.prank(address(timelock));
        (bool ok, bytes memory ret) = address(store).call(data);
        assertFalse(ok, "store accepted");
        assertEq(ret, err, "wrong error");
    }

    // ─── Wiring ───

    // TEST-062 verifies: REQ-PSTORE-001, REQ-PSTORE-011
    function test_TEST_062_storeAndRegistryNameEachOther() public view {
        assertEq(registry.PARAMETER_STORE(), address(store));
        assertEq(store.MARKET_REGISTRY(), address(registry));
        assertEq(store.TIMELOCK(), address(timelock));
        assertEq(registry.TIMELOCK(), address(timelock));
    }

    // TEST-062 verifies: REQ-CONFIG-056
    function test_TEST_062_feeRecipientRefusesEveryRegistryRecord() public {
        address[17] memory bad = [
            address(registry),
            address(store),
            registry.AAVE_ADAPTER(),
            registry.COLLATERALIZATION(),
            registry.PROXY_MANAGER(),
            registry.LP_VAULT_SWAP(),
            registry.VAULT_TOKEN_FACTORY(),
            registry.RISK_MODULE(),
            registry.LOCK(),
            registry.PAYOUT_ESCROW(),
            registry.FLASH_LIQUIDATOR(),
            registry.STANDARD_SPOKE_IMPLEMENTATION(),
            registry.flashSource(),
            address(hub),
            address(spoke),
            address(ghoCoverage),
            address(ghoSource)
        ];
        for (uint256 i = 0; i < bad.length; ++i) {
            _refuses(
                abi.encodeCall(store.setFeeRecipient, (bad[i])),
                abi.encodeWithSelector(IParameterStoreErrors.InvalidFeeRecipient.selector, bad[i])
            );
        }
        // The integration's LPVault is recorded by the registry as integration 1.
        _refuses(
            abi.encodeCall(store.setFeeRecipient, (address(lpVault))),
            abi.encodeWithSelector(IParameterStoreErrors.InvalidFeeRecipient.selector, address(lpVault))
        );
        vm.prank(address(timelock));
        store.setFeeRecipient(daoTreasury);
        assertEq(store.feeRecipient(), daoTreasury);
    }

    // ─── Scope checks read the registry ───

    // TEST-272 verifies: REQ-RISK-044, REQ-PSTORE-026, REQ-PSTORE-022
    function test_TEST_272_hubAndSpokeScopesFollowTheRegistry() public {
        address other = makeAddr("otherHub");
        _refuses(
            abi.encodeCall(store.setInitialHubCaps, (other, 1e8)),
            abi.encodeWithSelector(IParameterStoreErrors.UnknownHub.selector, other)
        );
        vm.prank(address(timelock));
        store.setInitialHubCaps(address(hub), 1_000_000e8);
        assertEq(store.depositorUsdCap(address(hub)), 1_000_000e8);
        vm.prank(address(timelock));
        store.setInitialTokenCap(address(hub), address(usdc), 20_000_000e8);
        _refuses(
            abi.encodeCall(store.setLiquidationExpectations, (other, 1.1e18, 200)),
            abi.encodeWithSelector(IParameterStoreErrors.UnknownSpoke.selector, other)
        );
        vm.prank(address(timelock));
        store.setLiquidationExpectations(address(spoke), 1.1e18, 200);
        assertEq(store.aaveTargetHealthFactor(address(spoke)), 1.1e18);
        // A token the registry never listed.
        address dai = makeAddr("DAI");
        _refuses(
            abi.encodeCall(store.setTokenCollateralFactorBps, (dai, 5000)),
            abi.encodeWithSelector(IParameterStoreErrors.TokenNotListed.selector, dai)
        );
    }

    // ─── Routes: the tolerance bound reads the registry's three routes ───

    // TEST-250 verifies: REQ-CONFIG-024, REQ-MREG-027, REQ-CONFIG-052
    function test_TEST_250_toleranceBoundFromTheRegistryRoutes() public {
        // Primary 25, alternate 25 + 25 = 50, standby 25: max(75, 75, 50) + 50 = 125.
        assertEq(store.feedAgreementToleranceMinBps(address(usdc)), 125);
        _refuses(
            abi.encodeCall(store.setFeedAgreementToleranceBps, (address(usdc), 124)),
            abi.encodeWithSelector(IParameterStoreErrors.LivenessBound.selector)
        );
        vm.prank(address(timelock));
        store.setFeedAgreementToleranceBps(address(usdc), 125);
        assertEq(store.feedAgreementToleranceBps(address(usdc)), 125);
    }

    // TEST-250 verifies: REQ-CONFIG-024, REQ-MREG-027, REQ-CONFIG-027
    function test_TEST_250_registryRefusesRoutesTheStoreToleranceCannotCover() public {
        // A new standby of 100 bps raises USDC's bound to max(75, 150, 125) + 50 = 200 > 150.
        address wide = address(new MockAggregator(8, 1e6, 1e12));
        vm.prank(address(timelock));
        store.setFeed(wide, _wideFeed());
        address[] memory p = new address[](1);
        address[] memory a = new address[](2);
        address[] memory s = new address[](1);
        p[0] = routeFeeds[address(usdc)][0];
        (a[0], a[1]) = (routeFeeds[address(usdc)][1], routeFeeds[address(usdc)][2]);
        s[0] = wide;
        vm.prank(address(timelock));
        vm.expectRevert(abi.encodeWithSelector(IMarketRegistryErrors.ListingCheckFailed.selector, bytes32("tolerance")));
        registry.setPriceSource(address(usdc), p, a, s);
        // Raising the store's tolerance first lets the same route change through.
        vm.prank(address(timelock));
        store.setFeedAgreementToleranceBps(address(usdc), 200);
        uint64 version = registry.priceRouteVersion(address(usdc));
        vm.prank(address(timelock));
        registry.setPriceSource(address(usdc), p, a, s);
        assertEq(registry.priceRouteVersion(address(usdc)), version + 1);
        assertEq(store.feedAgreementToleranceMinBps(address(usdc)), 200);
    }

    function _wideFeed() internal pure returns (FeedDef memory d) {
        d = _feedDef();
        d.feedDeviationThresholdBps = 100;
    }

    // ─── Debt reserves: the allowance and the deficit threshold read the registry ───

    // TEST-246 verifies: REQ-CONFIG-050, REQ-PSTORE-006, Q-397
    function test_TEST_246_allowanceFromTheRegistryReserve() public {
        vm.prank(address(timelock));
        store.loosenFloorRoundingAllowance(address(gho), 1e18);
        assertEq(store.floorRoundingAllowance(address(gho)), 1e18);
        // The reserve's price source moves to $2: the bound halves.
        ghoSource.setAnswer(2e8);
        _refuses(abi.encodeCall(store.loosenFloorRoundingAllowance, (address(gho), 1e18 + 1)), oob);
        // A reverting or non-positive price makes the bound zero: fail closed.
        ghoSource.setAnswer(0);
        _refuses(abi.encodeCall(store.loosenFloorRoundingAllowance, (address(gho), 1e18 + 1)), oob);
        // A listed token no approved reserve lends.
        _refuses(
            abi.encodeCall(store.loosenFloorRoundingAllowance, (address(usdc), 1)),
            abi.encodeWithSelector(IParameterStoreErrors.TokenNotListed.selector, address(usdc))
        );
    }

    // TEST-228 verifies: REQ-PSTORE-016, Q-399, Q-402
    function test_TEST_228_deficitThresholdBoundedByTheCoverageMinimum() public {
        vm.mockCall(
            address(ghoCoverage), abi.encodeWithSignature("firstLossReserveMinimum()"), abi.encode(uint256(100_000e18))
        );
        vm.prank(address(timelock));
        store.loosenBreakerDeficitMax(address(hub), address(gho), 10_000e18);
        _refuses(abi.encodeCall(store.loosenBreakerDeficitMax, (address(hub), address(gho), 100_000e18 + 1)), oob);
        vm.prank(address(timelock));
        store.loosenBreakerDeficitMax(address(hub), address(gho), 100_000e18);
        assertEq(store.breakerDeficitMax(address(hub), address(gho)), 100_000e18);
        // USDT has no reserve funded by the Hub.
        _refuses(
            abi.encodeCall(store.loosenBreakerDeficitMax, (address(hub), address(usdt), 1)),
            abi.encodeWithSelector(IParameterStoreErrors.UnknownDebtReserve.selector, address(0), 0)
        );
    }

    // ─── A market through listing and activation ───

    function _listMarket() internal returns (uint256 id, address vaultToken, RegistryLPOracleMock lpOracle) {
        id = registry.marketCount() + 1;
        lpOracle = new RegistryLPOracleMock(id, address(lpVault));
        vm.prank(address(timelock));
        vaultToken = factory.deployVaultToken(
            V3,
            pool,
            bytes32(0),
            PositionShape(ShapeKind.TickRange, -50, 50),
            address(hub),
            address(spoke),
            id,
            address(lpOracle),
            18,
            "Avana USDC/USDT",
            "avUSDC-USDT"
        );
        MarketDef memory d;
        d.hub = address(hub);
        d.spoke = address(spoke);
        d.integrationId = V3;
        d.pool = pool;
        d.shape = PositionShape(ShapeKind.TickRange, -50, 50);
        d.vaultToken = vaultToken;
        d.lpOracle = address(lpOracle);
        vm.prank(address(timelock));
        id = registry.listCollateralMarket(d);
    }

    /// @dev The store's listing writes of the market (the pool's observation buffer and the integration's depth read
    /// are answered by mocked calls), the Aave payload and the swap routes into GHO.
    function _storeListing(
        uint256 id,
        address vaultToken
    ) internal {
        vm.mockCall(
            pool,
            abi.encodeWithSelector(IPoolObservations.slot0.selector),
            abi.encode(uint160(2 ** 96), int24(0), uint16(0), uint16(1000), uint16(1000), uint8(0), true)
        );
        RiskStatus memory st;
        st.depthAvailable = true;
        st.depthUnits = 1;
        vm.mockCall(address(lpVault), abi.encodeWithSignature("riskStatus(uint256,uint32)"), abi.encode(st));
        MarketParams memory p;
        (p.twapWindow, p.consistencyToleranceBps, p.slippageAllowanceBps, p.slippageAllowanceMinBps) =
        (1800, 50, 250, 30);
        (p.poolRiskFactor, p.minPledgeUsd) = (4000, 10e8);
        vm.startPrank(address(timelock));
        store.setTokenCollateralFactorBps(address(usdc), 7800);
        store.setTokenCollateralFactorBps(address(usdt), 7500);
        store.setInitialMarketParams(id, p);
        store.setInitialMarketCaps(id, 1_000_000e8, 100_000e8, 1e8);
        store.setLiquidationExpectations(address(spoke), 1.1e18, 200);
        vm.stopPrank();
        hub.setAsset(vaultToken, VT_ASSET);
        hub.setSpokeConfig(VT_ASSET, address(spoke), 2_000_000, 0);
        IAaveV4Spoke.Reserve memory r;
        (r.underlying, r.hub, r.assetId, r.decimals) = (vaultToken, address(hub), uint16(VT_ASSET), 18);
        IAaveV4Spoke.ReserveConfig memory c;
        IAaveV4Spoke.DynamicReserveConfig memory dyn;
        (dyn.collateralFactor, dyn.maxLiquidationBonus) = (2500, 10_500);
        spoke.setReserve(VT_RESERVE, r, c, dyn);
        spoke.setLiquidationConfig(1.1e18, 5000);
        _route(id, address(usdc), 0, "dexA");
        _route(id, address(usdc), 1, "dexB");
        _route(id, address(usdt), 0, "dexC");
        _route(id, address(usdt), 1, "dexD");
    }

    function _route(
        uint256 id,
        address token,
        uint8 kind,
        string memory dep
    ) internal {
        address[] memory deps = new address[](1);
        deps[0] = makeAddr(dep);
        address route = address(new RegistryRouteMock(token, address(gho), address(lpVaultSwap), deps));
        vm.prank(address(timelock));
        registry.setRoute(id, token, address(gho), uint8(kind), route);
    }

    function _activeMarket() internal returns (uint256 id, address vaultToken, RegistryLPOracleMock lpOracle) {
        (id, vaultToken, lpOracle) = _listMarket();
        _storeListing(id, vaultToken);
        vm.prank(address(timelock));
        registry.activateMarket(id);
    }

    // TEST-250 verifies: REQ-PSTORE-004, REQ-PSTORE-012, REQ-RISK-041, REQ-PSTORE-011
    function test_TEST_250_listingWritesFollowTheRegistryStatus() public {
        (uint256 id, address vaultToken,) = _listMarket();
        assertEq(uint8(registry.getMarket(id).status), uint8(MarketStatus.Registered));
        _storeListing(id, vaultToken);
        assertEq(store.getMarketParams(id).poolRiskFactor, 4000);
        assertEq(store.twapMinObservations(id), 151);
        vm.prank(address(timelock));
        registry.activateMarket(id);
        assertEq(uint8(registry.getMarket(id).status), uint8(MarketStatus.Active));
        // Active: the listing writes are closed.
        MarketParams memory p = store.getMarketParams(id);
        _refuses(
            abi.encodeCall(store.setInitialMarketParams, (id, p)),
            abi.encodeWithSelector(IParameterStoreErrors.NotInListing.selector)
        );
        _refuses(
            abi.encodeCall(store.setInitialMarketCaps, (id, 1e8, 0, 1e8)),
            abi.encodeWithSelector(IParameterStoreErrors.NotInListing.selector)
        );
        // An identifier the registry never assigned.
        _refuses(
            abi.encodeCall(store.tightenMinPledgeUsd, (id + 1, 20e8)),
            abi.encodeWithSelector(IParameterStoreErrors.UnknownMarket.selector, id + 1)
        );
    }

    // TEST-245 verifies: REQ-PSTORE-021, REQ-PSTORE-024, REQ-PSTORE-015, REQ-CONFIG-052, REQ-ACCESS-095
    function test_TEST_245_livenessThroughTheRegistryAndSpoke() public {
        (uint256 id,,) = _activeMarket();
        // minLB = 10,000 + ⌊500 × 5,000 / 10⁴⌋ = 10,250.
        assertTrue(store.liquidationLivenessHolds(address(spoke), id, GHO_RESERVE));
        assertFalse(store.liquidationLivenessHolds(address(spoke), id, 7), "unapproved reserve");
        // Floor 200: 10,250 × 9,800 = 100,450,000 = 10⁴ × 10,045, so a flash ceiling of 45 holds with equality.
        vm.prank(address(timelock));
        store.setSlippageAllowanceMinBps(id, 200);
        vm.prank(address(timelock));
        store.setMaxFlashFeeBps(45);
        _refuses(
            abi.encodeCall(store.setMaxFlashFeeBps, (46)),
            abi.encodeWithSelector(IParameterStoreErrors.LivenessBound.selector)
        );
        // At 45, raising the floor one more bp breaks the pair.
        _refuses(
            abi.encodeCall(store.setSlippageAllowanceMinBps, (id, 201)),
            abi.encodeWithSelector(IParameterStoreErrors.LivenessBound.selector)
        );
        // An Aave bonus cut after activation is drift: the view turns false, and only lowerings still pass.
        IAaveV4Spoke.Reserve memory r = spoke.getReserve(VT_RESERVE);
        IAaveV4Spoke.DynamicReserveConfig memory dyn;
        (dyn.collateralFactor, dyn.maxLiquidationBonus) = (2500, 10_100);
        spoke.setReserve(VT_RESERVE, r, spoke.getReserveConfig(VT_RESERVE), dyn);
        assertFalse(store.liquidationLivenessHolds(address(spoke), id, GHO_RESERVE));
        vm.prank(address(timelock));
        store.setMaxFlashFeeBps(0);
        vm.prank(address(timelock));
        store.setSlippageAllowanceMinBps(id, 30);
    }

    // TEST-225 verifies: SPEC-CAP-006, REQ-RISK-044, REQ-PSTORE-017
    function test_TEST_225_capLoosenOnALiveMarketReadsTheHubAndCounters() public {
        (uint256 id, address vaultToken,) = _activeMarket();
        PledgeCounters memory c;
        c.regularUsed = 1_200_000e8;
        vm.mockCall(
            registry.COLLATERALIZATION(),
            abi.encodeCall(ICollateralizationViews.getCounters, (vaultToken, address(0))),
            abi.encode(c)
        );
        // (max(1,500,000, 1,200,000) + 100,000) / $1 = 1,600,000 ≤ addCap 2,000,000.
        vm.prank(address(timelock));
        store.loosenMarketUsdCap(id, 1_500_000e8);
        vm.warp(block.timestamp + NORMAL_DELAY);
        hub.setSpokeConfig(VT_ASSET, address(spoke), 2_149_999, 0);
        // The step allows 2,250,000 (1.5 × 1,500,000); with the slice that needs 2,350,000 whole tokens of addCap.
        _refuses(
            abi.encodeCall(store.loosenMarketUsdCap, (id, 2_250_000e8)),
            abi.encodeWithSelector(IParameterStoreErrors.AddCapTooSmall.selector)
        );
        hub.setSpokeConfig(VT_ASSET, address(spoke), 2_350_000, 0);
        vm.prank(address(timelock));
        store.loosenMarketUsdCap(id, 2_250_000e8);
        assertEq(store.marketUsdCap(id), 2_250_000e8);
    }

    // TEST-250 verifies: REQ-PSTORE-033, REQ-CONFIG-072, REQ-MREG-027, REQ-ORACLE-100
    function test_TEST_250_inputsFollowTheRegistryRoutesInForce() public {
        (uint256 id,, RegistryLPOracleMock lpOracle) = _activeMarket();
        address[] memory toks = new address[](1);
        toks[0] = address(usdc);
        uint256[] memory w = store.getOracleInputs(address(lpOracle), toks, false);
        uint256 k = OracleInputsLayout.HEAD_WORDS;
        assertEq(w[0], id);
        assertEq(w[k], 150, "tolerance");
        assertEq(w[k + 1], registry.priceRouteVersion(address(usdc)), "route version");
        assertEq(w[k + 2], uint256(RouteSlot.None));
        assertEq(w[k + 3], 1, "primary legs");
        assertEq(w[k + 4], 2, "alternate legs");
        assertEq(w[k + 5], uint160(routeFeeds[address(usdc)][0]), "primary feed");
        // A guardian puts the standby in place of the primary: the store serves it in that slot at once.
        vm.prank(emergencyGuardian);
        registry.useStandbyRoute(address(usdc), RouteSlot.Primary);
        w = store.getOracleInputs(address(lpOracle), toks, false);
        assertEq(w[k + 1], registry.priceRouteVersion(address(usdc)));
        assertEq(w[k + 2], uint256(RouteSlot.Primary));
        assertEq(w[k + 3], 1);
        assertEq(w[k + 5], uint160(routeFeeds[address(usdc)][3]), "standby served as primary");
    }

    // TEST-250 verifies: REQ-PSTORE-009, REQ-PSTORE-013, REQ-CONFIG-047
    function test_TEST_250_storeRechecksTheRegistryMarketsLpOracle() public {
        (uint256 id,, RegistryLPOracleMock lpOracle) = _activeMarket();
        lpOracle.setFailed(4);
        _refuses(
            abi.encodeCall(store.setCachedWindow, (1800)),
            abi.encodeWithSelector(IParameterStoreErrors.OracleConfigRejected.selector, address(lpOracle), 4)
        );
        _refuses(
            abi.encodeCall(store.setConsistencyToleranceBps, (id, 60)),
            abi.encodeWithSelector(IParameterStoreErrors.OracleConfigRejected.selector, address(lpOracle), 4)
        );
        // The tightening runs: check 4 failed before it.
        vm.prank(address(timelock));
        store.tightenConsistencyToleranceBps(id, 40);
        assertEq(store.getMarketParams(id).consistencyToleranceBps, 40);
    }
}
