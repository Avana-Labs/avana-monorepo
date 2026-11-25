// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {LPOracle} from "../../src/LPOracle.sol";
import {RiskModule} from "../../src/RiskModule.sol";
import {VaultToken} from "../../src/VaultToken.sol";
import {IAaveV4Spoke} from "../../src/dependencies/aave/IAaveV4Spoke.sol";
import {ILPOracle} from "../../src/interfaces/ILPOracle.sol";
import {IRiskModule} from "../../src/interfaces/IRiskModule.sol";
import {IVaultToken} from "../../src/interfaces/IVaultToken.sol";
import {ClTickMath} from "../../src/libraries/ClTickMath.sol";
import {FloorCreditMath} from "../../src/libraries/FloorCreditMath.sol";
import {LPPriceMath} from "../../src/libraries/LPPriceMath.sol";
import {BandTestFeed, BandTestPriceSpoke, BandTestToken} from "../utils/mocks/BandOracleMocks.sol";
import {
    RiskTestAaveOracle,
    RiskTestFirstLossReserve,
    RiskTestHub,
    RiskTestSpoke,
    RiskTestVault
} from "../utils/mocks/RiskModuleTestMocks.sol";
import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import {IAccessManaged} from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Test} from "forge-std/Test.sol";

/// @notice The RiskModule against an AccessManager, a mock LPVault, Hub, Spoke and Aave oracle, a price Spoke on the
/// real pinned AaveOracle, and the real VaultToken and LPOracle at activation. A WETH/USDC pool at $1,800, tick spacing 10.
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
    BandTestPriceSpoke internal priceSpoke;
    uint256 internal wethId;
    uint256 internal usdcId;
    address internal lm = makeAddr("liquidationModule");
    address internal stranger = makeAddr("stranger");

    function setUp() public {
        am = new AccessManager(address(this));
        weth = new BandTestToken("WETH", 18);
        usdc = new BandTestToken("USDC", 6);
        ethUsd = new BandTestFeed(8, 1800e8);
        usdcUsd = new BandTestFeed(8, 1e8);
        priceSpoke = new BandTestPriceSpoke(8);
        priceSpoke.init();
        wethId = priceSpoke.addReserve(address(weth), 18, address(ethUsd));
        usdcId = priceSpoke.addReserve(address(usdc), 6, address(usdcUsd));
        // The price Spoke's settings the markets copy: WETH 5% and USDC 4.5% max bonus, and its liquidation config.
        priceSpoke.setDynamicReserveConfig(wethId, IAaveV4Spoke.DynamicReserveConfig(8300, 10_500, 0));
        priceSpoke.setDynamicReserveConfig(usdcId, IAaveV4Spoke.DynamicReserveConfig(7800, 10_450, 0));
        priceSpoke.setLiquidationConfig(_aaveLiquidationConfig());
        vault = new RiskTestVault(address(weth), address(usdc), SPACING);
        hub = new RiskTestHub();
        spoke = new RiskTestSpoke();
        aaveOracle = new RiskTestAaveOracle();
        spoke.setOracle(address(aaveOracle));
        spoke.setLiquidationConfig(_aaveLiquidationConfig());
        rm = new RiskModule(address(am), address(vault), lm);
        rm.registerSpoke(address(spoke), address(hub), IRiskModule.SpokeKind.Volatile, address(priceSpoke));
    }

    // ─── Helpers ───

    /// @dev Aave V4's config-engine defaults: target health factor 1.05, max bonus at 0.95, factor 100%.
    function _aaveLiquidationConfig() internal pure returns (IAaveV4Spoke.LiquidationConfig memory) {
        return IAaveV4Spoke.LiquidationConfig(1.05e18, 0.95e18, 10_000);
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
        (p.reserveId0, p.reserveId1) = (wethId, usdcId);
    }

    /// @dev A RiskModule on a vault of the given pair, with the test Spoke registered.
    function _riskModuleOn(
        address token0,
        address token1
    ) internal returns (RiskModule r) {
        r = new RiskModule(address(am), address(new RiskTestVault(token0, token1, SPACING)), lm);
        r.registerSpoke(address(spoke), address(hub), IRiskModule.SpokeKind.Volatile, address(priceSpoke));
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
                    priceSpoke: address(priceSpoke),
                    reserveId0: wethId,
                    reserveId1: usdcId,
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
        address ps = address(priceSpoke);
        vm.expectEmit(address(rm));
        emit IRiskModule.SpokeRegistered(s, address(hub), IRiskModule.SpokeKind.Stable, ps);
        rm.registerSpoke(s, address(hub), IRiskModule.SpokeKind.Stable, ps);
        rm.registerSpoke(s, address(hub), IRiskModule.SpokeKind.Correlated, ps);
        IRiskModule.SpokeConfig memory c = rm.getSpoke(s);
        assertEq(c.hub, address(hub));
        assertEq(uint8(c.kind), uint8(IRiskModule.SpokeKind.Correlated));
        assertEq(c.priceSpoke, ps);
    }

    /// @notice A CDP Spoke's price Spoke is fixed: re-registering it on another price Spoke would reprice the tokens
    /// of markets already listed against the first one's collateral factors.
    function test_registerSpoke_reverts() public {
        address s = makeAddr("s");
        address ps = address(priceSpoke);
        vm.expectRevert(abi.encodeWithSelector(IRiskModule.InvalidSpoke.selector, s));
        rm.registerSpoke(s, address(hub), IRiskModule.SpokeKind.None, ps);
        vm.expectRevert(abi.encodeWithSelector(IRiskModule.InvalidAddress.selector, address(0)));
        rm.registerSpoke(address(0), address(hub), IRiskModule.SpokeKind.Stable, ps);
        vm.expectRevert(abi.encodeWithSelector(IRiskModule.InvalidAddress.selector, address(0)));
        rm.registerSpoke(s, address(hub), IRiskModule.SpokeKind.Stable, address(0));
        vm.expectRevert(abi.encodeWithSelector(IRiskModule.InvalidSpoke.selector, address(spoke)));
        rm.registerSpoke(address(spoke), makeAddr("otherHub"), IRiskModule.SpokeKind.Stable, ps);
        vm.expectRevert(abi.encodeWithSelector(IRiskModule.InvalidSpoke.selector, address(spoke)));
        rm.registerSpoke(address(spoke), address(hub), IRiskModule.SpokeKind.Volatile, makeAddr("otherPriceSpoke"));
    }

    function test_setters_restricted() public {
        vm.startPrank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, stranger));
        rm.registerSpoke(stranger, address(hub), IRiskModule.SpokeKind.Stable, address(priceSpoke));
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
        // A side wider than the whole tick range (2 * 887,272 ticks) is a misconfiguration, never a band.
        vm.expectRevert(abi.encodeWithSelector(IRiskModule.InvalidWidth.selector, 1_774_545, 60));
        rm.setSpokeWidth(IRiskModule.SpokeKind.Stable, IRiskModule.Width(1_774_545, 60));
        rm.setSpokeWidth(IRiskModule.SpokeKind.Stable, IRiskModule.Width(1_774_544, 60));
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
        assertEq(c.priceReserveId0, wethId);
        assertEq(c.priceReserveId1, usdcId);
        assertEq(f.priceReserveId0, wethId);
        assertEq(f.priceReserveId1, usdcId);

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

    /// @notice A per-pool width with one side zero is rejected, not listed as a band that ends at the listing tick
    /// and leaves the price no room on that side.
    function test_listPool_revertsOnOneSidedWidthOverride() public {
        IRiskModule.ListPoolParams memory p = _params();
        p.width = IRiskModule.Width(0, 300);
        vm.expectRevert(abi.encodeWithSelector(IRiskModule.InvalidWidth.selector, 0, 300));
        rm.listPool(p);
        p.width = IRiskModule.Width(300, 0);
        vm.expectRevert(abi.encodeWithSelector(IRiskModule.InvalidWidth.selector, 300, 0));
        rm.listPool(p);
    }

    function test_listPool_stableSpokeDefault() public {
        rm.registerSpoke(address(spoke), address(hub), IRiskModule.SpokeKind.Stable, address(priceSpoke));
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

    /// @dev The listing price in the proposal is 30% above Aave's price at execution: outside a ±1% band.
    function test_listPool_revertsWhenAavePriceOutsideBand() public {
        rm.registerSpoke(address(spoke), address(hub), IRiskModule.SpokeKind.Stable, address(priceSpoke));
        IRiskModule.ListPoolParams memory p = _params();
        p.listingTick += 2624;
        vm.expectPartialRevert(IRiskModule.PriceOutsideBand.selector);
        rm.listPool(p);
    }

    /// @notice No $1 cap of Avana's own: the listing price is Aave's as served. USDC read at $1.05 moves WETH/USDC
    /// 4.9% (about 488 ticks), so a ±1% band written at the $1 price is refused, and one written at Aave's price lists.
    function test_listPool_readsAavePriceAsServed() public {
        rm.registerSpoke(address(spoke), address(hub), IRiskModule.SpokeKind.Stable, address(priceSpoke));
        IRiskModule.ListPoolParams memory p = _params();
        usdcUsd.set(1.05e8);
        vm.expectPartialRevert(IRiskModule.PriceOutsideBand.selector);
        rm.listPool(p);
        p.listingTick = ClTickMath.getTickAtSqrtPrice(LPPriceMath.sqrtPriceX96(1800e8, 1.05e8, 18, 6));
        (uint256 full,) = rm.listPool(p);
        assertEq(rm.getMarket(full).pool, POOL);
    }

    /// @notice Bug hunted: a Volatile listing refused, or listed on a band that misses Aave's price, when that price
    /// sits 30% from the proposal's listing price at execution (the Stable band refuses the same gap, test above). The
    /// Custom band is built around the listing tick and still holds Aave's tick inside `[bandLower, bandUpper)`.
    function test_listPool_volatileBandHoldsAThirtyPercentMove() public {
        IRiskModule.ListPoolParams memory p = _params();
        int24 aaveTick = p.listingTick;
        p.listingTick += 2624;
        (, uint256 custom) = rm.listPool(p);
        IRiskModule.Market memory m = rm.getMarket(custom);
        assertLe(m.bandLower, aaveTick);
        assertGt(m.bandUpper, aaveTick);
        assertLe(m.bandLower, p.listingTick - 10_643);
        assertGe(m.bandUpper, p.listingTick + 10_641);
    }

    function test_listPool_revertsOnNarrowBand() public {
        rm.registerSpoke(address(spoke), address(hub), IRiskModule.SpokeKind.Stable, address(priceSpoke));
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

    /// @notice Attack: a listing names the wrong price reserves (another token's, or the two swapped, which would
    /// price WETH at $1). Invariant: reserve i is the pool's token i on the Spoke's price Spoke. Result: refused.
    function test_listPool_revertsOnWrongPriceReserve() public {
        IRiskModule.ListPoolParams memory p = _params();
        (p.reserveId0, p.reserveId1) = (usdcId, wethId);
        vm.expectRevert(abi.encodeWithSelector(IRiskModule.InvalidPriceReserve.selector, usdcId));
        rm.listPool(p);
        uint256 usdtId = priceSpoke.addReserve(address(new BandTestToken("USDT", 6)), 6, address(usdcUsd));
        (p.reserveId0, p.reserveId1) = (wethId, usdtId);
        vm.expectRevert(abi.encodeWithSelector(IRiskModule.InvalidPriceReserve.selector, usdtId));
        rm.listPool(p);
        (p.reserveId0, p.reserveId1) = (wethId, 99);
        vm.expectRevert(bytes("ReserveNotListed"));
        rm.listPool(p);
    }

    /// @notice Bug hunted: a pool token with more than 18 decimals listed. The listing price math and the vault-token
    /// unit assume at most 18 (10^(18 - d) scale factors), so a 19-decimal token would underflow there or be valued
    /// at a wrong power of ten. Either side of the pair is refused, naming that token.
    function test_listPool_revertsOnATokenAboveEighteenDecimals() public {
        BandTestToken wide = new BandTestToken("WIDE", 19);
        IRiskModule.ListPoolParams memory p = _params();
        RiskModule rm0 = _riskModuleOn(address(wide), address(usdc));
        vm.expectRevert(abi.encodeWithSelector(IRiskModule.InvalidAddress.selector, address(wide)));
        rm0.listPool(p);
        RiskModule rm1 = _riskModuleOn(address(weth), address(wide));
        vm.expectRevert(abi.encodeWithSelector(IRiskModule.InvalidAddress.selector, address(wide)));
        rm1.listPool(p);
    }

    /// @notice Bug hunted: a market listed whose vault token is worth less than $1 even at the largest unit (10^18
    /// liquidity). Its oracle answer would round to almost nothing, so Aave would value the collateral at zero or at
    /// a rounding step. Tokens priced at Aave's floor of one 8-decimal unit ($10^-8) leave no unit worth $1.
    function test_listPool_revertsWhenNoUnitReachesOneDollar() public {
        ethUsd.set(1);
        usdcUsd.set(1);
        IRiskModule.ListPoolParams memory p = _params();
        p.listingTick = ClTickMath.getTickAtSqrtPrice(LPPriceMath.sqrtPriceX96(1, 1, 18, 6));
        vm.expectRevert(abi.encodeWithSelector(IRiskModule.UnitValueTooLow.selector, 1));
        rm.listPool(p);
    }

    /// @notice A reserve of the right token whose recorded decimals differ from the token's is refused.
    function test_listPool_revertsOnReserveDecimalsMismatch() public {
        IRiskModule.ListPoolParams memory p = _params();
        p.reserveId1 = priceSpoke.addReserve(address(usdc), 18, address(usdcUsd));
        vm.expectRevert(abi.encodeWithSelector(IRiskModule.InvalidPriceReserve.selector, p.reserveId1));
        rm.listPool(p);
    }

    /// @notice Aave's own `> 0` check refuses a dead source; a price above $10^10 is refused by the math's bound.
    function test_listPool_revertsOnUnreadablePrice() public {
        IRiskModule.ListPoolParams memory p = _params();
        ethUsd.set(0);
        vm.expectRevert(abi.encodeWithSignature("InvalidPrice(uint256)", wethId));
        rm.listPool(p);
        ethUsd.set(1e18 + 1);
        vm.expectRevert(abi.encodeWithSelector(IRiskModule.InvalidPriceReserve.selector, wethId));
        rm.listPool(p);
    }

    /// @notice Bug hunted: a band past the int24 tick range wrapped by a cast. Around `type(int24).max` the upper edge
    /// is 9,275,880, which wraps to -7,501,336; a wrapped edge could list a band nowhere near the request or report a
    /// wrong one. The band is refused, and the error shows the far edge clamped to the int24 range, the near edge exact.
    function test_listPool_bandPastTheTickRangeReportsClampedEdges() public {
        IRiskModule.ListPoolParams memory p = _params();
        p.width = IRiskModule.Width(887_272, 887_272);
        p.listingTick = type(int24).max;
        // 8,388,607 - 887,272 = 7,501,335, floored to the spacing of 10.
        vm.expectRevert(
            abi.encodeWithSelector(IRiskModule.BandNotNarrowerThanFullRange.selector, int24(7_501_330), type(int24).max)
        );
        rm.listPool(p);
        p.listingTick = type(int24).min;
        // -8,388,608 + 887,272 = -7,501,336, ceiled to the spacing of 10.
        vm.expectRevert(
            abi.encodeWithSelector(
                IRiskModule.BandNotNarrowerThanFullRange.selector, type(int24).min, int24(-7_501_330)
            )
        );
        rm.listPool(p);
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
        // A valid oracle on another WETH reserve of the same price Spoke than the listing named.
        ILPOracle.Params memory op = ILPOracle.Params({
            lpVault: address(vault),
            marketId: full,
            unitDecimals: rm.getMarket(full).unitDecimals,
            priceSpoke: address(priceSpoke),
            reserveId0: priceSpoke.addReserve(address(weth), 18, address(ethUsd)),
            reserveId1: usdcId,
            description: "x"
        });
        _expectActivationFail(full, token, address(new LPOracle(op)), "oracle");
        // A valid oracle on another price Spoke than the CDP Spoke's.
        BandTestPriceSpoke other = new BandTestPriceSpoke(8);
        other.init();
        op.priceSpoke = address(other);
        op.reserveId0 = other.addReserve(address(weth), 18, address(ethUsd));
        op.reserveId1 = other.addReserve(address(usdc), 6, address(usdcUsd));
        _expectActivationFail(full, token, address(new LPOracle(op)), "oracle");
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

    /// @notice Bug hunted: a listing payload that adds the vault token to Aave with the wrong decimals (6 for an
    /// 18-decimal token) makes Aave value each unit 10^12 times too high, so a borrower could draw up to the cap
    /// against nothing. Activation refuses any mismatch between Aave's recorded decimals and the token's.
    function test_activateMarket_refusesWrongAaveDecimals() public {
        (uint256 full,) = _list();
        (address token, address oracle, uint256 reserveId) = _prepare(full);
        uint8 d = IERC20Metadata(token).decimals();
        spoke.setReserveDecimals(reserveId, d == 6 ? 18 : 6);
        _expectActivationFail(full, token, oracle, "decimals");
        spoke.setReserveDecimals(reserveId, d + 1);
        _expectActivationFail(full, token, oracle, "decimals");
        spoke.setReserveDecimals(reserveId, d);
        rm.activateMarket(full, token, oracle);
    }

    /// @notice The LP's max liquidation bonus is the higher of its two tokens' on the price Spoke: a WETH/USDC market
    /// pays at least what Aave pays to liquidate either token it may end up holding.
    function test_activateMarket_copiesTheHigherTokenBonus() public {
        (uint256 full,) = _list();
        (address token, address oracle, uint256 reserveId) = _prepare(full);
        spoke.setBonus(reserveId, 10_450);
        _expectActivationFail(full, token, oracle, "liquidationBonus"); // USDC's, the lower
        priceSpoke.setDynamicReserveConfig(usdcId, IAaveV4Spoke.DynamicReserveConfig(7800, 10_600, 0));
        spoke.setBonus(reserveId, 10_500);
        _expectActivationFail(full, token, oracle, "liquidationBonus"); // WETH's, now the lower
        spoke.setBonus(reserveId, 10_600);
        rm.activateMarket(full, token, oracle);
    }

    /// @notice The CDP Spoke's liquidation config is the price Spoke's, field by field.
    function test_activateMarket_copiesTheLiquidationConfig() public {
        (uint256 full,) = _list();
        (address token, address oracle,) = _prepare(full);
        IAaveV4Spoke.LiquidationConfig memory c = _aaveLiquidationConfig();
        c.targetHealthFactor = 1.1e18;
        spoke.setLiquidationConfig(c);
        _expectActivationFail(full, token, oracle, "liquidationConfig");
        c = _aaveLiquidationConfig();
        c.healthFactorForMaxBonus = 0.9e18;
        spoke.setLiquidationConfig(c);
        _expectActivationFail(full, token, oracle, "liquidationConfig");
        c = _aaveLiquidationConfig();
        c.liquidationBonusFactor = 5000;
        spoke.setLiquidationConfig(c);
        _expectActivationFail(full, token, oracle, "liquidationConfig");
        spoke.setLiquidationConfig(_aaveLiquidationConfig());
        rm.activateMarket(full, token, oracle);
    }

    /// @notice Bug hunted: a vault token with no reserve on the CDP Spoke activated against reserve 0. Aave V4's
    /// `getReserveId` reverts for an unlisted Hub asset and its `getReserve` reverts `ReserveNotListed` for an unlisted
    /// id; if the activation went on after the first revert it would read reserve 0, or fail with Aave's raw error
    /// instead of naming the missing reserve.
    function test_activateMarket_missingAaveReserveOnAStrictSpoke() public {
        (uint256 full,) = _list();
        (address token, address oracle,) = _prepare(full);
        spoke.setStrictReserves(true);
        hub.setAsset(token, 99);
        _expectActivationFail(full, token, oracle, "reserve");
    }

    function test_activateMarket_missingAaveReserve() public {
        (uint256 full,) = _list();
        (address token, address oracle,) = _prepare(full);
        hub.setAsset(token, 99);
        _expectActivationFail(full, token, oracle, "reserve");

        RiskTestHub emptyHub = new RiskTestHub();
        rm.registerSpoke(makeAddr("spoke2"), address(emptyHub), IRiskModule.SpokeKind.Volatile, address(priceSpoke));
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
                priceSpoke: address(priceSpoke),
                reserveId0: wethId,
                reserveId1: usdcId,
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

    /// @notice Bug hunted: one Spoke counted twice in a Hub asset's coverage. A Spoke that lists two reserve ids of
    /// the same Hub asset would add its draw cap twice to the coverage sum (and be removed only once); the second id
    /// is refused.
    function test_setDebtReserve_refusesASecondReserveOfTheSameHubAssetOnOneSpoke() public {
        (RiskTestFirstLossReserve flr,) = _debtSetup();
        spoke.setReserve(4, address(usdc), address(hub), 5);
        vm.expectRevert(abi.encodeWithSelector(IRiskModule.DebtReserveExists.selector, address(spoke), 4));
        rm.setDebtReserve(address(spoke), 4, address(flr));
        assertEq(rm.getDebtReserve(address(spoke), 4).hub, address(0));
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
        rm.registerSpoke(address(spoke2), address(hub), IRiskModule.SpokeKind.Stable, address(priceSpoke));
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
        rm.registerSpoke(address(spoke2), address(hub), IRiskModule.SpokeKind.Stable, address(priceSpoke));
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

    /// @notice Bug hunted: a coverage requirement that overflows reads as small, or makes `coverage()` revert and
    /// with it every view that reads it. With an uncapped Spoke (2^128 whole tokens) and an asset of 40 decimals the
    /// product passes 2^256; the requirement must read as `type(uint256).max`, so borrowing fails closed.
    function test_coverage_overflowingRequirementFailsClosed() public {
        BandTestToken wide = new BandTestToken("WIDE", 40);
        hub.setAsset(address(wide), 6);
        spoke.setReserve(4, address(wide), address(hub), 6);
        RiskTestFirstLossReserve flr = new RiskTestFirstLossReserve(address(wide), address(hub));
        rm.setDebtReserve(address(spoke), 4, address(flr));
        rm.setCoverageRatio(10_000);
        rm.addKeeper(makeAddr("keeper"));
        hub.setDrawCap(6, address(spoke), type(uint40).max);
        flr.setFunded(type(uint128).max);
        (uint256 sum, uint256 required, uint256 funded) = rm.coverage(address(hub), address(wide));
        assertEq(sum, 2 ** 128);
        assertEq(required, type(uint256).max, "overflow reads as the largest requirement");
        assertEq(funded, type(uint128).max);
        vm.expectPartialRevert(IRiskModule.CoverageBelowRatio.selector);
        rm.checkBorrow(address(spoke), 4);
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

    /// @notice Bug hunted: a removed keeper still counted. If removal left the keeper's slot in the list, borrowing
    /// would go on with no keeper watching (checkBorrow only counts the list) and the 16-keeper cap would fill with
    /// stale slots, so governance could not add a replacement.
    function test_removeKeeper_shrinksTheListSoBorrowingStops() public {
        (, uint256 reserveId) = _debtSetup();
        hub.setDrawCap(5, address(spoke), 1000);
        address k = makeAddr("onlyKeeper");
        rm.addKeeper(k);
        rm.checkBorrow(address(spoke), reserveId);
        rm.removeKeeper(k);
        assertEq(rm.getKeepers().length, 0, "the list is empty");
        vm.expectRevert(IRiskModule.NoActiveKeeper.selector);
        rm.checkBorrow(address(spoke), reserveId);
        for (uint256 i = 1; i <= 16; ++i) {
            rm.addKeeper(address(uint160(i)));
        }
        rm.removeKeeper(address(uint160(3)));
        assertEq(rm.getKeepers().length, 15);
        rm.addKeeper(k);
        assertEq(rm.getKeepers().length, 16, "a replacement fits under the cap");
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
