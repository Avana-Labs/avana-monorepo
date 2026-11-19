// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ClTickMath} from "../../src/amm/concentrated-liquidity/ClTickMath.sol";
import {FloorCreditMath} from "../../src/custody/lp-vault/libraries/FloorCreditMath.sol";
import {ILPOracle} from "../../src/oracle/ILPOracle.sol";
import {LPOracle} from "../../src/oracle/LPOracle.sol";
import {LPPriceMath} from "../../src/oracle/LPPriceMath.sol";
import {IRiskModule} from "../../src/policy/risk-module/IRiskModule.sol";
import {RiskModule} from "../../src/policy/risk-module/RiskModule.sol";
import {IVaultToken} from "../../src/vault-token/IVaultToken.sol";
import {VaultToken} from "../../src/vault-token/VaultToken.sol";
import {BandTestFeed, BandTestToken} from "../utils/mocks/BandOracleMocks.sol";
import {
    RiskTestAaveOracle,
    RiskTestFirstLossReserve,
    RiskTestHub,
    RiskTestSpoke,
    RiskTestVault
} from "../utils/mocks/RiskModuleTestMocks.sol";
import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import {IAccessManaged} from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import {Test} from "forge-std/Test.sol";

/// @notice The RiskModule against an AccessManager, a mock LPVault, Hub, Spoke and Aave oracle, real Chainlink-style
/// feeds, and the real VaultToken and LPOracle at activation. A WETH/USDC pool at $1,800, tick spacing 10.
contract RiskModuleMarketsUnitTest is Test {
    bytes32 internal constant POOL = bytes32(uint256(0xB001));
    int24 internal constant SPACING = 10;
    uint16 internal constant LTV = 7500;

    AccessManager internal am;
    RiskModule internal rm;
    RiskTestVault internal vault;
    RiskTestHub internal hub;
    RiskTestSpoke internal spoke;
    RiskTestAaveOracle internal aaveOracle;
    BandTestToken internal weth;
    BandTestToken internal usdc;
    BandTestFeed internal ethUsd;
    BandTestFeed internal usdcUsd;
    address internal lm = makeAddr("liquidationModule");
    address internal stranger = makeAddr("stranger");

    function setUp() public {
        am = new AccessManager(address(this));
        weth = new BandTestToken("WETH", 18);
        usdc = new BandTestToken("USDC", 6);
        ethUsd = new BandTestFeed(8, 1800e8);
        usdcUsd = new BandTestFeed(8, 1e8);
        vault = new RiskTestVault(address(weth), address(usdc), SPACING);
        hub = new RiskTestHub();
        spoke = new RiskTestSpoke();
        aaveOracle = new RiskTestAaveOracle();
        spoke.setOracle(address(aaveOracle));
        rm = new RiskModule(address(am), address(vault), lm);
        rm.registerSpoke(address(spoke), address(hub), IRiskModule.SpokeKind.Volatile);
    }

    // ─── Helpers ───

    function _route(
        address feed,
        bool stable
    ) internal pure returns (ILPOracle.TokenFeeds memory t) {
        t.feeds = new address[](1);
        t.feeds[0] = feed;
        t.usdStable = stable;
    }

    function _chainlinkTick() internal view returns (int24) {
        return ClTickMath.getTickAtSqrtPrice(LPPriceMath.sqrtPriceX96(uint256(ethUsd.answer()), 1e8, 18, 6));
    }

    function _params() internal view returns (IRiskModule.ListPoolParams memory p) {
        p.pool = POOL;
        p.spoke = address(spoke);
        p.tickSpacing = SPACING;
        p.listingTick = _chainlinkTick();
        p.ltvBps = LTV;
        p.token0 = _route(address(ethUsd), false);
        p.token1 = _route(address(usdcUsd), true);
    }

    function _list() internal returns (uint256 full, uint256 custom) {
        return rm.listPool(_params());
    }

    /// @dev Deploys the market's vault token and oracle and sets up its Aave reserve as a correct listing would.
    function _prepare(
        uint256 id
    ) internal returns (address token, address oracle, uint256 reserveId) {
        IRiskModule.Market memory m = rm.getMarket(id);
        token = address(
            new VaultToken(
                IVaultToken.Params({
                    name: "Avana test",
                    symbol: "avT",
                    decimals: m.unitDecimals,
                    marketId: id,
                    hub: address(hub),
                    liquidationModule: lm,
                    authority: address(am)
                })
            )
        );
        oracle = address(
            new LPOracle(
                ILPOracle.Params({
                    lpVault: address(vault),
                    marketId: id,
                    unitDecimals: m.unitDecimals,
                    token0: _route(address(ethUsd), false),
                    token1: _route(address(usdcUsd), true),
                    description: "test"
                })
            )
        );
        reserveId = 40 + id;
        uint16 assetId = uint16(20 + id);
        hub.setAsset(token, assetId);
        spoke.setReserve(reserveId, token, address(hub), assetId);
        spoke.setDynamic(reserveId, LTV, 0);
        aaveOracle.setSource(reserveId, oracle);
    }

    function _expectActivationFail(
        uint256 id,
        address token,
        address oracle,
        bytes32 reason
    ) internal {
        vm.expectRevert(abi.encodeWithSelector(IRiskModule.ActivationCheckFailed.selector, id, reason));
        rm.activateMarket(id, token, oracle);
    }

    // ─── Construction and Spokes ───

    function test_constructor_setsDefaults() public view {
        assertEq(rm.LP_VAULT(), address(vault));
        assertEq(rm.LIQUIDATION_MODULE(), lm);
        assertEq(rm.authority(), address(am));
        IRiskModule.Width memory w = rm.spokeWidth(IRiskModule.SpokeKind.Stable);
        assertEq(w.below, 101);
        assertEq(w.above, 100);
        w = rm.spokeWidth(IRiskModule.SpokeKind.Correlated);
        assertEq(w.below, 513);
        assertEq(w.above, 488);
        w = rm.spokeWidth(IRiskModule.SpokeKind.Volatile);
        assertEq(w.below, 10_643);
        assertEq(w.above, 10_641);
    }

    function test_constructor_revertsOnZero() public {
        vm.expectRevert(abi.encodeWithSelector(IRiskModule.InvalidAddress.selector, address(0)));
        new RiskModule(address(am), address(0), lm);
        vm.expectRevert(abi.encodeWithSelector(IRiskModule.InvalidAddress.selector, address(0)));
        new RiskModule(address(am), address(vault), address(0));
    }

    function test_defaultWidths_matchTheirPriceFactors() public pure {
        // 1.0001^-101 ≈ 0.99, 1.0001^100 ≈ 1.01; ±5%; 0.345x to 2.898x.
        assertApproxEqRel(_factor(-101), 0.99e18, 0.0001e18);
        assertApproxEqRel(_factor(100), 1.01e18, 0.0001e18);
        assertApproxEqRel(_factor(-513), 0.95e18, 0.0001e18);
        assertApproxEqRel(_factor(488), 1.05e18, 0.0001e18);
        assertApproxEqRel(_factor(-10_643), 0.345e18, 0.0001e18);
        assertApproxEqRel(_factor(10_641), 2.898e18, 0.0001e18);
    }

    function _factor(
        int24 tick
    ) internal pure returns (uint256) {
        uint256 s = ClTickMath.getSqrtPriceAtTick(tick);
        return s * s / 2 ** 96 * 1e18 / 2 ** 96;
    }

    function test_registerSpoke() public {
        address s = makeAddr("s");
        vm.expectEmit(address(rm));
        emit IRiskModule.SpokeRegistered(s, address(hub), IRiskModule.SpokeKind.Stable);
        rm.registerSpoke(s, address(hub), IRiskModule.SpokeKind.Stable);
        rm.registerSpoke(s, address(hub), IRiskModule.SpokeKind.Correlated);
        IRiskModule.SpokeConfig memory c = rm.getSpoke(s);
        assertEq(c.hub, address(hub));
        assertEq(uint8(c.kind), uint8(IRiskModule.SpokeKind.Correlated));
    }

    function test_registerSpoke_reverts() public {
        address s = makeAddr("s");
        vm.expectRevert(abi.encodeWithSelector(IRiskModule.InvalidSpoke.selector, s));
        rm.registerSpoke(s, address(hub), IRiskModule.SpokeKind.None);
        vm.expectRevert(abi.encodeWithSelector(IRiskModule.InvalidAddress.selector, address(0)));
        rm.registerSpoke(address(0), address(hub), IRiskModule.SpokeKind.Stable);
        vm.expectRevert(abi.encodeWithSelector(IRiskModule.InvalidSpoke.selector, address(spoke)));
        rm.registerSpoke(address(spoke), makeAddr("otherHub"), IRiskModule.SpokeKind.Stable);
    }

    function test_setters_restricted() public {
        vm.startPrank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, stranger));
        rm.registerSpoke(stranger, address(hub), IRiskModule.SpokeKind.Stable);
        IRiskModule.ListPoolParams memory p = _params();
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, stranger));
        rm.listPool(p);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, stranger));
        rm.addKeeper(stranger);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, stranger));
        rm.setFee(0, stranger);
        vm.stopPrank();
    }

    function test_setSpokeWidth() public {
        vm.expectEmit(address(rm));
        emit IRiskModule.SpokeWidthSet(IRiskModule.SpokeKind.Stable, 50, 60);
        rm.setSpokeWidth(IRiskModule.SpokeKind.Stable, IRiskModule.Width(50, 60));
        assertEq(rm.spokeWidth(IRiskModule.SpokeKind.Stable).above, 60);
        vm.expectRevert(abi.encodeWithSelector(IRiskModule.InvalidWidth.selector, 0, 60));
        rm.setSpokeWidth(IRiskModule.SpokeKind.Stable, IRiskModule.Width(0, 60));
        vm.expectRevert(abi.encodeWithSelector(IRiskModule.InvalidSpoke.selector, address(0)));
        rm.setSpokeWidth(IRiskModule.SpokeKind.None, IRiskModule.Width(1, 1));
    }

    // ─── listPool ───

    function test_listPool_listsTwoMarkets() public {
        int24 t = _chainlinkTick();
        (uint256 full, uint256 custom) = _list();
        assertEq(full, 1);
        assertEq(custom, 2);

        IRiskModule.Market memory f = rm.getMarket(full);
        assertEq(f.pool, POOL);
        assertEq(f.spoke, address(spoke));
        assertEq(f.bandLower, -887_270);
        assertEq(f.bandUpper, 887_270);
        assertEq(f.ltvBps, LTV);
        assertEq(uint8(f.kind), uint8(IRiskModule.MarketKind.FullRange));
        assertFalse(f.active);

        IRiskModule.Market memory c = rm.getMarket(custom);
        assertEq(uint8(c.kind), uint8(IRiskModule.MarketKind.CustomRange));
        assertEq(c.ltvBps, LTV);
        assertEq(c.bandLower % SPACING, 0);
        assertEq(c.bandUpper % SPACING, 0);
        assertLe(c.bandLower, t - 10_643);
        assertGt(c.bandLower, t - 10_643 - SPACING);
        assertGe(c.bandUpper, t + 10_641);
        assertLt(c.bandUpper, t + 10_641 + SPACING);
        assertEq(c.feedsHash, f.feedsHash);

        assertEq(vault.getMarket(full).bandLower, f.bandLower);
        assertEq(vault.getMarket(custom).bandUpper, c.bandUpper);
        IRiskModule.PoolMarkets memory pm = rm.marketsOf(POOL);
        assertEq(pm.fullRange, full);
        assertEq(pm.customRange, custom);
    }

    function test_listPool_unitDecimals_wholeTokenAtLeastOneDollar() public {
        (uint256 full, uint256 custom) = _list();
        for (uint256 id = full; id <= custom; ++id) {
            IRiskModule.Market memory m = rm.getMarket(id);
            (, address oracle,) = _prepare(id);
            uint256 answer = uint256(LPOracle(oracle).latestAnswer());
            assertGe(answer, 1e8, "whole token >= $1");
            if (m.unitDecimals > 6) assertLt(answer / 10, 1e8, "one decimal fewer < $1");
        }
    }

    function test_listPool_againGivesNewPair() public {
        _list();
        (uint256 full, uint256 custom) = _list();
        assertEq(full, 3);
        assertEq(custom, 4);
        assertEq(rm.marketsOf(POOL).customRange, 4);
        assertEq(rm.getMarket(2).pool, POOL);
    }

    function test_listPool_widthOverride() public {
        IRiskModule.ListPoolParams memory p = _params();
        p.width = IRiskModule.Width(200, 300);
        (, uint256 custom) = rm.listPool(p);
        IRiskModule.Market memory c = rm.getMarket(custom);
        assertLe(c.bandLower, p.listingTick - 200);
        assertGe(c.bandUpper, p.listingTick + 300);
        assertLt(c.bandUpper - c.bandLower, 500 + 2 * SPACING);
    }

    function test_listPool_stableSpokeDefault() public {
        rm.registerSpoke(address(spoke), address(hub), IRiskModule.SpokeKind.Stable);
        (, uint256 custom) = _list();
        IRiskModule.Market memory c = rm.getMarket(custom);
        assertLt(c.bandUpper - c.bandLower, 201 + 2 * SPACING);
    }

    function test_listPool_emits() public {
        IRiskModule.ListPoolParams memory p = _params();
        vm.expectEmit(true, true, false, false, address(rm));
        emit IRiskModule.MarketListed(1, POOL, IRiskModule.MarketKind.FullRange, 0, 0, 0);
        vm.expectEmit(true, true, false, false, address(rm));
        emit IRiskModule.MarketListed(2, POOL, IRiskModule.MarketKind.CustomRange, 0, 0, 0);
        vm.expectEmit(address(rm));
        emit IRiskModule.PoolListed(POOL, address(spoke), 1, 2, p.listingTick, LTV);
        rm.listPool(p);
    }

    function test_listPool_revertsOnUnregisteredSpoke() public {
        IRiskModule.ListPoolParams memory p = _params();
        p.spoke = stranger;
        vm.expectRevert(abi.encodeWithSelector(IRiskModule.SpokeNotRegistered.selector, stranger));
        rm.listPool(p);
    }

    function test_listPool_revertsOnLtv() public {
        IRiskModule.ListPoolParams memory p = _params();
        p.ltvBps = 0;
        vm.expectRevert(abi.encodeWithSelector(IRiskModule.InvalidLtv.selector, 0));
        rm.listPool(p);
        p.ltvBps = 10_000;
        vm.expectRevert(abi.encodeWithSelector(IRiskModule.InvalidLtv.selector, 10_000));
        rm.listPool(p);
    }

    function test_listPool_revertsOnSpacing() public {
        IRiskModule.ListPoolParams memory p = _params();
        p.tickSpacing = 0;
        vm.expectRevert(abi.encodeWithSelector(IRiskModule.InvalidTickSpacing.selector, int24(0)));
        rm.listPool(p);
    }

    /// @dev The listing price in the proposal is 30% above the Chainlink price at execution: outside a ±1% band.
    function test_listPool_revertsWhenChainlinkPriceOutsideBand() public {
        rm.registerSpoke(address(spoke), address(hub), IRiskModule.SpokeKind.Stable);
        IRiskModule.ListPoolParams memory p = _params();
        p.listingTick += 2624;
        vm.expectPartialRevert(IRiskModule.PriceOutsideBand.selector);
        rm.listPool(p);
    }

    function test_listPool_volatileBandHoldsAThirtyPercentMove() public {
        IRiskModule.ListPoolParams memory p = _params();
        p.listingTick += 2624;
        rm.listPool(p);
    }

    function test_listPool_revertsOnNarrowBand() public {
        rm.registerSpoke(address(spoke), address(hub), IRiskModule.SpokeKind.Stable);
        IRiskModule.ListPoolParams memory p = _params();
        p.tickSpacing = 200;
        p.listingTick = 0;
        vm.expectPartialRevert(IRiskModule.BandTooNarrow.selector);
        rm.listPool(p);
    }

    function test_listPool_revertsOnBandReachingFullRange() public {
        IRiskModule.ListPoolParams memory p = _params();
        p.listingTick = 880_000;
        vm.expectPartialRevert(IRiskModule.BandNotNarrowerThanFullRange.selector);
        rm.listPool(p);
        p.width = IRiskModule.Width(887_272, 887_272);
        p.listingTick = 0;
        vm.expectPartialRevert(IRiskModule.BandNotNarrowerThanFullRange.selector);
        rm.listPool(p);
    }

    function test_listPool_revertsOnBadFeeds() public {
        IRiskModule.ListPoolParams memory p = _params();
        p.token0.feeds = new address[](0);
        vm.expectRevert(abi.encodeWithSelector(IRiskModule.InvalidPriceFeed.selector, address(0)));
        rm.listPool(p);
        p = _params();
        ethUsd.set(0);
        vm.expectRevert(abi.encodeWithSelector(IRiskModule.InvalidPriceFeed.selector, address(ethUsd)));
        rm.listPool(p);
    }

    function test_listPool_twoFeedRoute() public {
        BandTestFeed ethPerUnit = new BandTestFeed(18, 1e18);
        IRiskModule.ListPoolParams memory p = _params();
        p.token0.feeds = new address[](2);
        p.token0.feeds[0] = address(ethPerUnit);
        p.token0.feeds[1] = address(ethUsd);
        (uint256 full,) = rm.listPool(p);
        assertEq(rm.getMarket(full).feedsHash, keccak256(abi.encode(p.token0.feeds, p.token1.feeds)));
    }

    // ─── Activation ───

    function test_activateMarket() public {
        (uint256 full,) = _list();
        (address token, address oracle, uint256 reserveId) = _prepare(full);
        vm.expectEmit(address(rm));
        emit IRiskModule.MarketActivated(full, token, reserveId, oracle);
        rm.activateMarket(full, token, oracle);
        IRiskModule.Market memory m = rm.getMarket(full);
        assertTrue(m.active);
        assertEq(m.vaultToken, token);
        assertEq(m.lpOracle, oracle);
        assertEq(m.reserveId, reserveId);
        vm.expectRevert(abi.encodeWithSelector(IRiskModule.MarketAlreadyActive.selector, full));
        rm.activateMarket(full, token, oracle);
    }

    function test_activateMarket_revertsUnlisted() public {
        vm.expectRevert(abi.encodeWithSelector(IRiskModule.MarketNotListed.selector, 9));
        rm.activateMarket(9, address(1), address(2));
    }

    function test_activateMarket_vaultTokenChecks() public {
        (uint256 full, uint256 custom) = _list();
        (address token, address oracle,) = _prepare(full);
        (address otherToken,,) = _prepare(custom);
        _expectActivationFail(full, otherToken, oracle, "vaultToken");
        _expectActivationFail(full, stranger, oracle, "vaultToken");
        VaultToken wrongDecimals = new VaultToken(
            IVaultToken.Params("x", "x", rm.getMarket(full).unitDecimals + 1, full, address(hub), lm, address(am))
        );
        _expectActivationFail(full, address(wrongDecimals), oracle, "vaultToken");
        VaultToken wrongLm = new VaultToken(
            IVaultToken.Params("x", "x", rm.getMarket(full).unitDecimals, full, address(hub), stranger, address(am))
        );
        _expectActivationFail(full, address(wrongLm), oracle, "vaultToken");
        token;
    }

    function test_activateMarket_oracleChecks() public {
        (uint256 full, uint256 custom) = _list();
        (address token,,) = _prepare(full);
        (, address otherOracle,) = _prepare(custom);
        _expectActivationFail(full, token, otherOracle, "oracle");
        _expectActivationFail(full, token, stranger, "oracle");
        LPOracle otherFeeds = new LPOracle(
            ILPOracle.Params({
                lpVault: address(vault),
                marketId: full,
                unitDecimals: rm.getMarket(full).unitDecimals,
                token0: _route(address(ethUsd), false),
                token1: _route(address(ethUsd), true),
                description: "x"
            })
        );
        _expectActivationFail(full, token, address(otherFeeds), "oracle");
    }

    function test_activateMarket_aaveChecks() public {
        (uint256 full,) = _list();
        (address token, address oracle, uint256 reserveId) = _prepare(full);
        uint256 assetId = 20 + full;

        hub.setDrawCap(assetId, address(spoke), 1);
        _expectActivationFail(full, token, oracle, "drawCap");
        hub.setDrawCap(assetId, address(spoke), 0);

        spoke.setReceiveShares(reserveId, true);
        _expectActivationFail(full, token, oracle, "receiveShares");
        spoke.setReceiveShares(reserveId, false);

        spoke.setDynamic(reserveId, LTV, 1);
        _expectActivationFail(full, token, oracle, "liquidationFee");
        spoke.setDynamic(reserveId, LTV - 1, 0);
        _expectActivationFail(full, token, oracle, "ltv");
        spoke.setDynamic(reserveId, LTV, 0);

        aaveOracle.setSource(reserveId, stranger);
        _expectActivationFail(full, token, oracle, "priceSource");
        aaveOracle.setSource(reserveId, oracle);

        spoke.setReserve(reserveId, stranger, address(hub), uint16(assetId));
        _expectActivationFail(full, token, oracle, "reserve");
        spoke.setReserve(reserveId, token, address(hub), uint16(assetId));

        rm.activateMarket(full, token, oracle);
    }

    function test_activateMarket_missingAaveReserve() public {
        (uint256 full,) = _list();
        (address token, address oracle,) = _prepare(full);
        hub.setAsset(token, 99);
        _expectActivationFail(full, token, oracle, "reserve");

        RiskTestHub emptyHub = new RiskTestHub();
        rm.registerSpoke(makeAddr("spoke2"), address(emptyHub), IRiskModule.SpokeKind.Volatile);
        IRiskModule.ListPoolParams memory p = _params();
        p.spoke = makeAddr("spoke2");
        (uint256 full2,) = rm.listPool(p);
        VaultToken t2 = new VaultToken(
            IVaultToken.Params("x", "x", rm.getMarket(full2).unitDecimals, full2, address(emptyHub), lm, address(am))
        );
        LPOracle o2 = new LPOracle(
            ILPOracle.Params({
                lpVault: address(vault),
                marketId: full2,
                unitDecimals: rm.getMarket(full2).unitDecimals,
                token0: _route(address(ethUsd), false),
                token1: _route(address(usdcUsd), true),
                description: "x"
            })
        );
        _expectActivationFail(full2, address(t2), address(o2), "hubAsset");
    }

    // ─── Eligibility and credit ───

    function test_routeOf() public {
        (uint256 full, uint256 custom) = _list();
        IRiskModule.Market memory c = rm.getMarket(custom);
        assertEq(rm.routeOf(POOL, -887_270, 887_270), full);
        assertEq(rm.routeOf(POOL, c.bandLower, c.bandUpper), custom);
        assertEq(rm.routeOf(POOL, c.bandLower + 10, c.bandUpper - 10), custom);
        assertEq(rm.routeOf(POOL, c.bandLower - 10, c.bandUpper), 0);
        assertEq(rm.routeOf(POOL, c.bandLower, c.bandLower), 0);
        assertEq(rm.routeOf(bytes32(uint256(7)), -887_270, 887_270), 0);
    }

    function test_isEligible() public {
        (uint256 full, uint256 custom) = _list();
        IRiskModule.Market memory c = rm.getMarket(custom);
        assertTrue(rm.isEligible(full, c.bandLower - 100, c.bandUpper + 100));
        assertTrue(rm.isEligible(custom, c.bandLower, c.bandUpper));
        assertFalse(rm.isEligible(custom, c.bandLower - 10, c.bandUpper));
        assertFalse(rm.isEligible(custom, c.bandUpper, c.bandUpper));
        vm.expectRevert(abi.encodeWithSelector(IRiskModule.MarketNotListed.selector, 5));
        rm.isEligible(5, 0, 10);
    }

    function test_creditOf() public {
        (uint256 full, uint256 custom) = _list();
        IRiskModule.Market memory c = rm.getMarket(custom);
        uint128 l = 1e18;
        // A position on the band's own ticks earns its liquidity, less rounding (at most 2 base units of a token).
        assertApproxEqRel(rm.creditOf(full, -887_270, 887_270, l), l, 1e6);
        assertLe(rm.creditOf(full, -887_270, 887_270, l), l);
        assertApproxEqRel(rm.creditOf(custom, c.bandLower, c.bandUpper, l), l, 1e6);
        assertLe(rm.creditOf(custom, c.bandLower, c.bandUpper, l), l);
        int24 a = c.bandLower + 2000;
        int24 b = c.bandUpper - 2000;
        assertEq(rm.creditOf(custom, a, b, l), FloorCreditMath.credit(a, b, c.bandLower, c.bandUpper, l));
        assertLt(rm.creditOf(custom, a, b, l), l);
        vm.expectRevert(
            abi.encodeWithSelector(
                FloorCreditMath.NotInsideBand.selector, c.bandLower - 10, b, c.bandLower, c.bandUpper
            )
        );
        rm.creditOf(custom, c.bandLower - 10, b, l);
    }

    // ─── Debt reserves and coverage ───

    function _debtSetup() internal returns (RiskTestFirstLossReserve flr, uint256 reserveId) {
        reserveId = 3;
        hub.setAsset(address(usdc), 5);
        spoke.setReserve(reserveId, address(usdc), address(hub), 5);
        flr = new RiskTestFirstLossReserve(address(usdc), address(hub));
        rm.setDebtReserve(address(spoke), reserveId, address(flr));
    }

    function test_setDebtReserve() public {
        (RiskTestFirstLossReserve flr, uint256 reserveId) = _debtSetup();
        IRiskModule.DebtReserve memory d = rm.getDebtReserve(address(spoke), reserveId);
        assertEq(d.hub, address(hub));
        assertEq(d.asset, address(usdc));
        assertEq(d.assetId, 5);
        assertEq(d.firstLossReserve, address(flr));
        vm.expectRevert(abi.encodeWithSelector(IRiskModule.DebtReserveExists.selector, address(spoke), reserveId));
        rm.setDebtReserve(address(spoke), reserveId, address(flr));
    }

    function test_setDebtReserve_reverts() public {
        hub.setAsset(address(usdc), 5);
        spoke.setReserve(3, address(usdc), address(hub), 5);
        RiskTestFirstLossReserve wrong = new RiskTestFirstLossReserve(address(weth), address(hub));
        vm.expectRevert(abi.encodeWithSelector(IRiskModule.InvalidFirstLossReserve.selector, address(wrong)));
        rm.setDebtReserve(address(spoke), 3, address(wrong));
        vm.expectRevert(abi.encodeWithSelector(IRiskModule.InvalidFirstLossReserve.selector, address(0)));
        rm.setDebtReserve(address(spoke), 3, address(0));
        vm.expectRevert(abi.encodeWithSelector(IRiskModule.DebtReserveNotListed.selector, address(spoke), 8));
        rm.setDebtReserve(address(spoke), 8, address(wrong));
        vm.expectRevert(abi.encodeWithSelector(IRiskModule.SpokeNotRegistered.selector, stranger));
        rm.setDebtReserve(stranger, 3, address(wrong));
    }

    function test_setDebtReserve_oneFirstLossReservePerPair() public {
        _debtSetup();
        RiskTestSpoke spoke2 = new RiskTestSpoke();
        rm.registerSpoke(address(spoke2), address(hub), IRiskModule.SpokeKind.Stable);
        spoke2.setReserve(1, address(usdc), address(hub), 5);
        RiskTestFirstLossReserve other = new RiskTestFirstLossReserve(address(usdc), address(hub));
        vm.expectRevert(abi.encodeWithSelector(IRiskModule.InvalidFirstLossReserve.selector, address(other)));
        rm.setDebtReserve(address(spoke2), 1, address(other));
    }

    function test_coverage_andCheckBorrow() public {
        (RiskTestFirstLossReserve flr, uint256 reserveId) = _debtSetup();
        rm.setCoverageRatio(1000);
        hub.setDrawCap(5, address(spoke), 1_000_000);

        vm.expectRevert(IRiskModule.NoActiveKeeper.selector);
        rm.checkBorrow(address(spoke), reserveId);
        rm.addKeeper(makeAddr("keeper"));

        (uint256 sum, uint256 required, uint256 funded) = rm.coverage(address(hub), address(usdc));
        assertEq(sum, 1_000_000);
        assertEq(required, 100_000e6);
        assertEq(funded, 0);
        vm.expectRevert(
            abi.encodeWithSelector(IRiskModule.CoverageBelowRatio.selector, address(hub), address(usdc), 100_000e6, 0)
        );
        rm.checkBorrow(address(spoke), reserveId);

        flr.setFunded(100_000e6);
        rm.checkBorrow(address(spoke), reserveId);

        // A second Spoke borrowing the same asset adds its draw cap.
        RiskTestSpoke spoke2 = new RiskTestSpoke();
        rm.registerSpoke(address(spoke2), address(hub), IRiskModule.SpokeKind.Stable);
        spoke2.setReserve(1, address(usdc), address(hub), 5);
        rm.setDebtReserve(address(spoke2), 1, address(flr));
        hub.setDrawCap(5, address(spoke2), 500_000);
        (sum, required,) = rm.coverage(address(hub), address(usdc));
        assertEq(sum, 1_500_000);
        assertEq(required, 150_000e6);
        vm.expectPartialRevert(IRiskModule.CoverageBelowRatio.selector);
        rm.checkBorrow(address(spoke), reserveId);

        rm.removeDebtReserve(address(spoke2), 1);
        rm.checkBorrow(address(spoke), reserveId);
        vm.expectRevert(abi.encodeWithSelector(IRiskModule.DebtReserveNotListed.selector, address(spoke2), 1));
        rm.checkBorrow(address(spoke2), 1);
        vm.expectRevert(abi.encodeWithSelector(IRiskModule.DebtReserveNotListed.selector, address(spoke2), 1));
        rm.removeDebtReserve(address(spoke2), 1);
    }

    function test_coverage_uncappedNeverCovered() public {
        (RiskTestFirstLossReserve flr, uint256 reserveId) = _debtSetup();
        rm.setCoverageRatio(1);
        rm.addKeeper(makeAddr("keeper"));
        hub.setDrawCap(5, address(spoke), type(uint40).max);
        flr.setFunded(type(uint128).max);
        (uint256 sum, uint256 required,) = rm.coverage(address(hub), address(usdc));
        assertEq(sum, 2 ** 128);
        assertGt(required, type(uint128).max);
        vm.expectPartialRevert(IRiskModule.CoverageBelowRatio.selector);
        rm.checkBorrow(address(spoke), reserveId);
    }

    function test_coverage_zeroRatioOrNoSpokes() public {
        (uint256 sum, uint256 required, uint256 funded) = rm.coverage(address(hub), address(usdc));
        assertEq(sum + required + funded, 0);
        (, uint256 reserveId) = _debtSetup();
        hub.setDrawCap(5, address(spoke), 1000);
        rm.addKeeper(makeAddr("keeper"));
        rm.checkBorrow(address(spoke), reserveId);
    }

    function test_setCoverageRatio() public {
        vm.expectEmit(address(rm));
        emit IRiskModule.CoverageRatioSet(2500);
        rm.setCoverageRatio(2500);
        assertEq(rm.coverageRatioBps(), 2500);
        vm.expectRevert(abi.encodeWithSelector(IRiskModule.InvalidCoverageRatio.selector, 10_001));
        rm.setCoverageRatio(10_001);
    }

    // ─── Fee and keepers ───

    function test_setFee() public {
        address r = makeAddr("treasury");
        vm.expectEmit(address(rm));
        emit IRiskModule.FeeSet(5000, r);
        rm.setFee(5000, r);
        assertEq(rm.feeShareBps(), 5000);
        assertEq(rm.feeRecipient(), r);
        vm.expectRevert(abi.encodeWithSelector(IRiskModule.InvalidFee.selector, 5001, r));
        rm.setFee(5001, r);
        vm.expectRevert(abi.encodeWithSelector(IRiskModule.InvalidFee.selector, 100, address(0)));
        rm.setFee(100, address(0));
    }

    function test_keepers() public {
        address k1 = makeAddr("k1");
        address k2 = makeAddr("k2");
        vm.expectEmit(address(rm));
        emit IRiskModule.KeeperAdded(k1);
        rm.addKeeper(k1);
        rm.addKeeper(k2);
        assertTrue(rm.isKeeper(k1));
        assertEq(rm.getKeepers().length, 2);
        vm.expectRevert(abi.encodeWithSelector(IRiskModule.InvalidKeeper.selector, k1));
        rm.addKeeper(k1);
        vm.expectRevert(abi.encodeWithSelector(IRiskModule.InvalidKeeper.selector, address(0)));
        rm.addKeeper(address(0));
        vm.expectEmit(address(rm));
        emit IRiskModule.KeeperRemoved(k1);
        rm.removeKeeper(k1);
        assertFalse(rm.isKeeper(k1));
        assertEq(rm.getKeepers()[0], k2);
        vm.expectRevert(abi.encodeWithSelector(IRiskModule.InvalidKeeper.selector, k1));
        rm.removeKeeper(k1);
    }

    function test_keepers_max() public {
        for (uint256 i = 1; i <= 16; ++i) {
            rm.addKeeper(address(uint160(i)));
        }
        vm.expectRevert(IRiskModule.TooManyKeepers.selector);
        rm.addKeeper(address(17));
        assertEq(rm.MAX_KEEPERS(), 16);
        assertEq(rm.MAX_FEE_SHARE_BPS(), 5000);
        assertEq(rm.MIN_BAND_SPACINGS(), 4);
    }
}
