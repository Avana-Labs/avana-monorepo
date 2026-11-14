// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAaveV4Spoke} from "../../src/interfaces/external/aave/IAaveV4Spoke.sol";
import {IMarketRegistryErrors} from "../../src/policy/market-registry/IMarketRegistryErrors.sol";
import {MarketDef} from "../../src/types/MarketDef.sol";
import {PositionShape} from "../../src/types/PositionShape.sol";
import {ShapeKind} from "../../src/types/ShapeKind.sol";
import {MarketRegistryFixture} from "../utils/fixtures/MarketRegistryFixture.sol";
import {RegistryFeedMock, RegistryLPOracleMock, RegistryTokenMock} from "../utils/mocks/MarketRegistryMocks.sol";

/// @notice The arithmetic guards of listing and activation: the raw-price bound of a two-token pool against its exact
/// integer form, the primary-route answer of a two-leg route, the common-mode guard over every pair of alternate and
/// standby routes, the listing margin and the bonus bound at activation, each at its exact edge.
contract MarketRegistryListingMathUnitTest is MarketRegistryFixture {
    uint256 internal attempts;

    function setUp() public {
        _setUpWorld();
    }

    function _expectListing(
        bytes32 check
    ) internal {
        vm.expectRevert(abi.encodeWithSelector(IMarketRegistryErrors.ListingCheckFailed.selector, check));
    }

    /// @dev Lists a stable token of `decimals` whose primary route is one 8-decimal feed answering `answer`.
    function _tokenWithPrimary(
        uint8 decimals,
        int256 answer,
        string memory label
    ) internal returns (address t) {
        t = address(new RegistryTokenMock(decimals));
        (address[] memory p, address[] memory a, address[] memory s) = _routes(label);
        RegistryFeedMock(p[0]).setAnswer(answer);
        vm.prank(address(timelock));
        registry.listToken(t, _tokenDef(p, a, s));
    }

    function _pool(
        address t0,
        address t1
    ) internal {
        address[] memory toks = new address[](2);
        (toks[0], toks[1]) = (t0, t1);
        lpVault.setPoolTokens(toks, 18);
    }

    /// @dev Lists the pool under a fresh shape (each attempt gets its own market key and vault token).
    function _tryList() internal returns (bool ok, bytes memory ret) {
        ++attempts;
        int24 w = int24(int256(10 * attempts));
        PositionShape memory sh = PositionShape(ShapeKind.TickRange, -w, w);
        (address vt, RegistryLPOracleMock o) = _deployTokenAndOracle(registry.marketCount() + 1, sh);
        MarketDef memory d = _marketDef(vt, address(o));
        d.shape = sh;
        vm.prank(address(timelock));
        (ok, ret) = address(registry).call(abi.encodeCall(registry.listCollateralMarket, (d)));
    }

    // ─── Raw-price bound (REQ-CONFIG-035) ───

    /// @dev The exact bound: 10^4 x a0 x 10^d1 < 2^128 x a1 x 10^d0, evaluated without overflow (when the right side
    /// exceeds 2^256 it exceeds the left side, which always fits).
    function _rawPriceHolds(
        uint256 a0,
        uint256 a1,
        uint8 d0,
        uint8 d1
    ) internal pure returns (bool) {
        uint256 lhs = 1e4 * a0 * 10 ** uint256(d1);
        uint256 rhs = (uint256(1) << 128) * a1;
        uint256 scale = 10 ** uint256(d0);
        if (rhs > type(uint256).max / scale) return true;
        return lhs < rhs * scale;
    }

    // TEST-139 verifies: REQ-CONFIG-035, REQ-CONFIG-029
    // Sources: 5.1 TEST-139
    function testFuzz_TEST_139_rawPriceBoundMatchesItsExactForm(
        uint96 a0Seed,
        uint96 a1Seed,
        uint8 d0Seed,
        uint8 d1Seed
    ) public {
        uint256 a0 = bound(a0Seed, 1, 2 ** 96 - 1);
        uint256 a1 = bound(a1Seed, 1, 2 ** 96 - 1);
        uint8 d0 = uint8(bound(d0Seed, 0, 36));
        uint8 d1 = uint8(bound(d1Seed, 0, 36));
        address t0 = _tokenWithPrimary(d0, int256(a0), "t0");
        address t1 = _tokenWithPrimary(d1, int256(a1), "t1");
        _pool(t0, t1);
        (bool ok, bytes memory ret) = _tryList();
        if (_rawPriceHolds(a0, a1, d0, d1)) {
            assertTrue(ok, "a pool inside the bound was refused");
        } else {
            assertFalse(ok);
            assertEq(
                ret, abi.encodeWithSelector(IMarketRegistryErrors.ListingCheckFailed.selector, bytes32("rawPrice"))
            );
        }
    }

    // TEST-139 verifies: REQ-CONFIG-035
    // The bound is strict: with d0 = 0, d1 = 18 and a1 = 1, a0 = 2^128 / 10^22 rounded up fails and one less passes.
    function test_TEST_139_rawPriceEdgeIsStrict() public {
        // 10^4 x a0 x 10^18 < 2^128 <=> a0 <= floor((2^128 - 1) / 10^22).
        uint256 edge = ((uint256(1) << 128) - 1) / 1e22;
        address t0 = _tokenWithPrimary(0, int256(edge + 1), "t0");
        address t1 = _tokenWithPrimary(18, 1, "t1");
        _pool(t0, t1);
        (bool ok, bytes memory ret) = _tryList();
        assertFalse(ok);
        assertEq(ret, abi.encodeWithSelector(IMarketRegistryErrors.ListingCheckFailed.selector, bytes32("rawPrice")));
        RegistryFeedMock(registry.getToken(t0).primaryRoute[0]).setAnswer(int256(edge));
        (ok,) = _tryList();
        assertTrue(ok);
    }

    // TEST-139 verifies: REQ-CONFIG-035
    // INTEG-04: WBTC (8 decimals) as token0 against an 18-decimal $1 stable lists at $184,467 (where the former 2^64
    // bound refused it), at $10M and at the MAX_ROUTE_ANSWER price ($10^10).
    function test_TEST_139_rawPriceAdmitsWbtcAgainstAnEighteenDecimalStable() public {
        int256[3] memory btc = [int256(184_467e8), int256(10_000_000e8), int256(1e18)];
        for (uint256 i = 0; i < 3; ++i) {
            address wbtc = _tokenWithPrimary(8, btc[i], "wbtc");
            address dai = _tokenWithPrimary(18, 1e8, "dai");
            _pool(wbtc, dai);
            (bool ok, bytes memory ret) = _tryList();
            assertTrue(ok, string(ret));
        }
    }

    // TEST-139 verifies: REQ-CONFIG-035
    // A primary answer of 0, below 0 or at 2^96 on either token fails the bound.
    function test_TEST_139_rawPriceRefusesUnusableAnswers() public {
        int256[3] memory bad = [int256(0), int256(-5), int256(2 ** 96)];
        for (uint256 i = 0; i < 3; ++i) {
            address t0 = _tokenWithPrimary(6, 1e8, "t0");
            address t1 = _tokenWithPrimary(6, bad[i], "t1");
            _pool(t0, t1);
            (bool ok, bytes memory ret) = _tryList();
            assertFalse(ok);
            assertEq(
                ret, abi.encodeWithSelector(IMarketRegistryErrors.ListingCheckFailed.selector, bytes32("rawPrice"))
            );
            _pool(t1, t0);
            (ok, ret) = _tryList();
            assertFalse(ok, "either side");
        }
    }

    // TEST-139 verifies: REQ-CONFIG-035
    // A two-leg primary route multiplies its legs at their own decimals: TOKEN/ETH at 18 decimals x ETH/USD at 8
    // decimals. TOKEN has 0 decimals; against an 18-decimal $1 token the bound fails from a TOKEN price of
    // 2^128 x 10^8 / (10^4 x 10^18), about 3.4 x 10^24 at 8 decimals.
    function test_TEST_139_twoLegPrimaryAnswer() public {
        address t0 = address(new RegistryTokenMock(0));
        RegistryFeedMock legA = new RegistryFeedMock(18, 1e12);
        RegistryFeedMock legB = new RegistryFeedMock(8, 3000e8);
        ps.setFeed(address(legA), 18, 86_400, 25, 25);
        ps.setFeed(address(legB), 8, 86_400, 25, 25);
        (, address[] memory a, address[] memory s) = _routes("t0");
        address[] memory p = new address[](2);
        (p[0], p[1]) = (address(legA), address(legB));
        vm.prank(address(timelock));
        registry.listToken(t0, _tokenDef(p, a, s));
        _pool(t0, _tokenWithPrimary(18, 1e8, "t1"));
        // 10^-6 ETH x 3,000 USD = 0.003 USD: 300,000 at 8 decimals.
        (bool ok,) = _tryList();
        assertTrue(ok);
        // 1 ETH x 2 x 10^15 USD = 2 x 10^15 USD: 2 x 10^23, inside the bound only because the first leg is 1.
        legA.setAnswer(1e18);
        legB.setAnswer(2e23);
        (ok,) = _tryList();
        assertTrue(ok, "the first leg scales the second");
        // 20 ETH x 2 x 10^15 USD = 4 x 10^16 USD: 4 x 10^24 >= 3.4 x 10^24.
        legA.setAnswer(20e18);
        bytes memory ret;
        (ok, ret) = _tryList();
        assertFalse(ok);
        assertEq(ret, abi.encodeWithSelector(IMarketRegistryErrors.ListingCheckFailed.selector, bytes32("rawPrice")));
    }

    // TEST-139 verifies: REQ-CONFIG-035
    // Pools of three or more tokens are not bound by the two-token raw-price check.
    function test_TEST_139_rawPriceOnlyForTwoTokens() public {
        address big = _tokenWithPrimary(6, int256(2 ** 90), "big");
        address[] memory toks = new address[](3);
        (toks[0], toks[1], toks[2]) = (big, address(usdc), address(usdt));
        lpVault.setPoolTokens(toks, 18);
        (bool ok,) = _tryList();
        assertTrue(ok);
    }

    // ─── Common-mode guard (REQ-CONFIG-034) ───

    // TEST-139 verifies: REQ-CONFIG-034, REQ-CONFIG-021
    // Two pool tokens may share a primary feed but never an alternate or standby feed in any of the four pairings
    // (alternate-alternate, alternate-standby, standby-alternate, standby-standby).
    function test_TEST_139_commonModeEveryPairing() public {
        address[] memory usdcAlt = registry.getToken(address(usdc)).alternateRoute;
        address[] memory usdcStandby = registry.getToken(address(usdc)).standbyRoute;
        address[] memory usdcPrimary = registry.getToken(address(usdc)).primaryRoute;
        for (uint256 k = 0; k < 5; ++k) {
            address t = address(new RegistryTokenMock(6));
            (address[] memory p, address[] memory a, address[] memory s) = _routes("t");
            if (k == 0) a[1] = usdcAlt[1];
            if (k == 1) a[0] = usdcStandby[0];
            if (k == 2) s[0] = usdcAlt[0];
            if (k == 3) s[0] = usdcStandby[0];
            if (k == 4) p[0] = usdcPrimary[0];
            vm.prank(address(timelock));
            registry.listToken(t, _tokenDef(p, a, s));
            _pool(address(usdc), t);
            (bool ok, bytes memory ret) = _tryList();
            if (k == 4) {
                assertTrue(ok, "a shared primary feed is allowed");
            } else {
                assertFalse(ok);
                assertEq(
                    ret,
                    abi.encodeWithSelector(IMarketRegistryErrors.ListingCheckFailed.selector, bytes32("commonMode"))
                );
            }
        }
    }

    // TEST-139 verifies: REQ-CONFIG-034
    // The guard covers every pair of a pool, not only neighbours: tokens 0 and 2 of three sharing a standby fail.
    function test_TEST_139_commonModeNonAdjacentPair() public {
        address t = address(new RegistryTokenMock(6));
        (address[] memory p, address[] memory a,) = _routes("t");
        address[] memory s = registry.getToken(address(usdc)).standbyRoute;
        vm.prank(address(timelock));
        registry.listToken(t, _tokenDef(p, a, s));
        address[] memory toks = new address[](3);
        (toks[0], toks[1], toks[2]) = (address(usdc), address(usdt), t);
        lpVault.setPoolTokens(toks, 18);
        (bool ok, bytes memory ret) = _tryList();
        assertFalse(ok);
        assertEq(ret, abi.encodeWithSelector(IMarketRegistryErrors.ListingCheckFailed.selector, bytes32("commonMode")));
    }

    // ─── Activation edges ───

    function _activationReady() internal returns (uint256 id) {
        address vt;
        (id, vt,) = _listMarket();
        _prepareActivation(id, vt);
    }

    function _activateExpect(
        uint256 id,
        bytes32 check
    ) internal {
        vm.prank(address(timelock));
        if (check != bytes32(0)) {
            vm.expectRevert(abi.encodeWithSelector(IMarketRegistryErrors.ActivationCheckFailed.selector, id, check));
        }
        registry.activateMarket(id);
    }

    // TEST-138 verifies: REQ-CONFIG-036, SPEC-CF-004, Q-150
    // Sources: 5.1 TEST-138, MATH-UO-28
    // The listing margin 10^4 - CF_LP > sum of deviation and drift over a route's legs is strict: the widest route here
    // is the two-leg alternate at 2 x (25 + 25) = 100 bps, so CF_LP = 9,899 passes and 9,900 fails.
    function test_TEST_138_listingMarginEdgeIsStrict() public {
        uint256 id = _activationReady();
        uint256 snap = vm.snapshotState();
        rm.setCfLp(9900);
        _activateExpect(id, "listingMargin");
        rm.setCfLp(10_000);
        _activateExpect(id, "listingMargin");
        rm.setCfLp(9899);
        _activateExpect(id, bytes32(0));
        vm.revertToState(snap);
        // Widening one standby leg by a single bp moves the edge down by one.
        address s = registry.getToken(address(usdt)).standbyRoute[0];
        ps.setFeed(s, 8, 86_400, 75, 26);
        rm.setCfLp(9899);
        _activateExpect(id, "listingMargin");
        rm.setCfLp(9898);
        _activateExpect(id, bytes32(0));
    }

    // TEST-138 verifies: REQ-CONFIG-045, SPEC-CF-004, Q-270
    // The bonus bound ceil(maxLB x CF / 10^4) < 10^4 rounds up: at CF 7,500, maxLB 13,332 passes (9,999) and 13,333
    // fails (ceil(9,999.75) = 10,000).
    function test_TEST_138_bonusBoundRoundsUp() public {
        uint256 id = _activationReady();
        IAaveV4Spoke.DynamicReserveConfig memory d;
        (d.collateralFactor, d.maxLiquidationBonus) = (7500, 13_333);
        spoke.setDynamic(VT_RESERVE, d);
        _activateExpect(id, "bonusBound");
        d.maxLiquidationBonus = 13_332;
        spoke.setDynamic(VT_RESERVE, d);
        // The minimum bonus floor((13,332 - 10^4) x 5,000 / 10^4) = 1,666 clears the expected 200.
        _activateExpect(id, bytes32(0));
    }

    // TEST-138 verifies: REQ-CONFIG-044, REQ-CONFIG-047
    // CF equal to CF_LP passes; one above fails; a bonus below 100 % (maxLB < 10^4) fails the minimum-bonus check.
    function test_TEST_138_collateralFactorAndBonusEdges() public {
        uint256 id = _activationReady();
        IAaveV4Spoke.DynamicReserveConfig memory d;
        (d.collateralFactor, d.maxLiquidationBonus) = (8001, 10_500);
        spoke.setDynamic(VT_RESERVE, d);
        _activateExpect(id, "collateralFactor");
        (d.collateralFactor, d.maxLiquidationBonus) = (8000, 9999);
        spoke.setDynamic(VT_RESERVE, d);
        _activateExpect(id, "minBonus");
        (d.collateralFactor, d.maxLiquidationBonus) = (8000, 10_500);
        spoke.setDynamic(VT_RESERVE, d);
        _activateExpect(id, bytes32(0));
    }
}
