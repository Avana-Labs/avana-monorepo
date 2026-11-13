// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ClPriceMath} from "../../src/amm/concentrated-liquidity/ClPriceMath.sol";
import {ClMarketConfig} from "../../src/amm/types/ClMarketConfig.sol";
import {IntegrationCapabilities} from "../../src/amm/types/IntegrationCapabilities.sol";
import {PoolKeying} from "../../src/amm/types/PoolKeying.sol";
import {RiskMetadata} from "../../src/amm/types/RiskMetadata.sol";
import {RiskStatus} from "../../src/amm/types/RiskStatus.sol";
import {UniswapV3Integration} from "../../src/amm/uniswap-v3/UniswapV3Integration.sol";
import {PositionShape} from "../../src/types/PositionShape.sol";
import {ShapeKind} from "../../src/types/ShapeKind.sol";
import {UniswapV3IntegrationFixture} from "../utils/fixtures/UniswapV3IntegrationFixture.sol";
import {UniswapV3IntegrationHarness} from "../utils/harness/UniswapV3IntegrationHarness.sol";
import {MintableToken, MockNFPM, MockV3Factory, MockV3Pool, NoDecimalsToken} from "../utils/mocks/UniswapV3Mocks.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @notice A pool look-alike whose immutables are settable: passes `factory()` and `getPool` once registered, but is
/// not at the factory's CREATE2 address.
contract FakeV3Pool {
    address public factory;
    address public token0;
    address public token1;
    uint24 public fee;
    int24 public tickSpacing;

    constructor(
        address f,
        address t0,
        address t1,
        uint24 fee_,
        int24 s
    ) {
        (factory, token0, token1, fee, tickSpacing) = (f, t0, t1, fee_, s);
    }
}

/// @notice Uniswap v3 LPVault deployment, market binding, composition, risk metadata and hooks.
/// forge-config: default.isolate = false
contract UniswapV3IntegrationMarketsUnitTest is UniswapV3IntegrationFixture {
    // ─── Deployment and identity ───

    // TEST-108 verifies: REQ-VAULT-155, REQ-AMM-V3-001, REQ-VAULT-002, INV-052
    function test_TEST_108_constructorFailsClosed() public {
        address n = address(nfpm);
        address f = address(v3Factory);
        address l = address(lock);
        vm.expectRevert(InvalidDeployment.selector);
        new UniswapV3Integration(0, coll, registry, l, timelock, n, f, 12);
        vm.expectRevert(InvalidDeployment.selector);
        new UniswapV3Integration(1, address(0), registry, l, timelock, n, f, 12);
        vm.expectRevert(InvalidDeployment.selector);
        new UniswapV3Integration(1, coll, coll, l, timelock, n, f, 12);
        vm.expectRevert(InvalidDeployment.selector);
        new UniswapV3Integration(1, coll, registry, l, l, n, f, 12);
        vm.expectRevert(InvalidDeployment.selector);
        new UniswapV3Integration(1, coll, registry, l, timelock, address(0), f, 12);
        vm.expectRevert(InvalidDeployment.selector);
        new UniswapV3Integration(1, coll, registry, l, timelock, n, n, 12);
        vm.expectRevert(InvalidDeployment.selector);
        new UniswapV3Integration(1, coll, registry, l, timelock, n, timelock, 12);
        vm.expectRevert(InvalidDeployment.selector);
        new UniswapV3Integration(1, coll, registry, l, timelock, alice, f, 12);
        // An NFPM whose factory() is another factory.
        MockNFPM wrong = new MockNFPM(address(new MockV3Factory()));
        vm.expectRevert(InvalidDeployment.selector);
        new UniswapV3Integration(1, coll, registry, l, timelock, address(wrong), f, 12);
    }

    // TEST-108 verifies: REQ-VAULT-155, REQ-AMM-CORE-001, REQ-AMM-CORE-002, REQ-AMM-CORE-009, REQ-AMM-V3-001, SPEC-AMM-CORE-002
    // Sources: VaultTokenFactory review (2026-11-10): registration reads TIMELOCK, MARKET_REGISTRY, AMM_PROTOCOL, keying
    function test_TEST_108_identityGetters() public view {
        assertEq(vault.INTEGRATION_ID(), INTEGRATION);
        assertEq(vault.COLLATERALIZATION(), coll);
        assertEq(vault.MARKET_REGISTRY(), registry);
        assertEq(vault.LOCK(), address(lock));
        assertEq(vault.TIMELOCK(), timelock);
        assertEq(vault.NFPM(), address(nfpm));
        assertEq(vault.FACTORY(), address(v3Factory));
        assertEq(vault.AMM_PROTOCOL(), keccak256("UNISWAP_V3"));
        assertTrue(vault.AMM_PROTOCOL() != bytes32(0));
        IntegrationCapabilities memory c = vault.capabilities();
        assertEq(uint8(c.poolKeying), uint8(PoolKeying.Address));
        assertEq(uint8(c.shapeKind), uint8(ShapeKind.TickRange));
        assertTrue(c.hasTwap && c.reentrancyGuarded && !c.nativeToken && !c.rateTokens);
        assertEq(vault.tokenIdOf(bytes32(uint256(42))), 42);
    }

    // TEST-108 verifies: REQ-VAULT-001, REQ-VAULT-085, REQ-VAULT-097, REQ-VAULT-150, REQ-ACCESS-010, REQ-ACCESS-022, REQ-ACCESS-113
    // Sources: no proxy, owner, pause, sweep, rescue, multicall, generic call or ERC-1271 entry point exists
    function test_TEST_108_noUpgradeOwnerPauseOrRescueSurface() public {
        bytes[10] memory probes = [
            abi.encodeWithSignature("proxiableUUID()"),
            abi.encodeWithSignature("upgradeToAndCall(address,bytes)", alice, ""),
            abi.encodeWithSignature("owner()"),
            abi.encodeWithSignature("pause()"),
            abi.encodeWithSignature("sweep(address,address,uint256)", address(usdc), alice, 1),
            abi.encodeWithSignature("rescue(address,address,uint256)", address(usdc), alice, 1),
            abi.encodeWithSignature("multicall(bytes[])", new bytes[](0)),
            abi.encodeWithSignature("execute(address,uint256,bytes)", alice, 0, ""),
            abi.encodeWithSignature("isValidSignature(bytes32,bytes)", bytes32(0), ""),
            abi.encodeWithSignature("acquire()")
        ];
        for (uint256 i = 0; i < probes.length; ++i) {
            (bool ok,) = address(vault).call(probes[i]);
            assertFalse(ok);
        }
    }

    // ─── bindMarket ───

    // TEST-264 verifies: REQ-AMM-CORE-003, REQ-AMM-V3-002, REQ-VAULT-166, SPEC-UNIT-001, SPEC-ORC-005
    // Sources: 2.4 SPEC-UNIT-001 examples ([-50, 50] gives 9, full range gives 6)
    function test_TEST_264_bindMarketStoresThePoolAndRange() public {
        MockV3Pool p = MockV3Pool(v3Factory.createPool(address(usdc), address(usdt), 100, 1));
        vm.expectEmit(address(vault));
        emit MarketBound(3, address(p), bytes32(0), -10, 10);
        (address[] memory tokens, uint8 d) = _bind(3, address(p), -10, 10);
        assertEq(d, 10, "[-10, 10] gives 10 decimals");
        assertEq(tokens[0], p.token0());
        assertEq(tokens[1], p.token1());
        (address pool, bytes32 poolId, PositionShape memory sh, address[] memory t) = vault.marketOf(3);
        assertEq(pool, address(p));
        assertEq(poolId, bytes32(0));
        assertEq(uint8(sh.kind), uint8(ShapeKind.TickRange));
        assertEq(sh.tickLower, -10);
        assertEq(sh.tickUpper, 10);
        assertEq(t.length, 2);
        ClMarketConfig memory cfg = vault.clMarket(3);
        assertEq(cfg.positionManager, address(nfpm));
        assertEq(cfg.factory, address(v3Factory));
        assertEq(cfg.fee, 100);
        assertEq(cfg.tickSpacing, 1);
        assertEq(cfg.maxLiquidityPerTick, ClPriceMath.maxLiquidityPerTick(1));
        (, d) = _bind(4, address(pool500), -100, 100);
        assertEq(d, 9);
        (, d) = _bind(5, address(pool3000), -887_220, 887_220);
        assertEq(d, 6);
    }

    // TEST-264 verifies: REQ-AMM-CORE-003, REQ-VAULT-156, REQ-VAULT-166
    function test_TEST_264_bindMarketCallerAndWriteOnce() public {
        PositionShape memory sh = PositionShape(ShapeKind.TickRange, -50, 50);
        vm.prank(alice);
        vm.expectRevert(NotMarketRegistry.selector);
        vault.bindMarket(9, address(pool500), bytes32(0), sh, abi.encode(1e8, 1e8));
        vm.startPrank(registry);
        vm.expectRevert(abi.encodeWithSelector(MarketBinding.selector, M1));
        vault.bindMarket(M1, address(pool500), bytes32(0), sh, abi.encode(1e8, 1e8));
        vm.expectRevert(abi.encodeWithSelector(MarketBinding.selector, uint256(0)));
        vault.bindMarket(0, address(pool500), bytes32(0), sh, abi.encode(1e8, 1e8));
        vm.stopPrank();
        vm.expectRevert(abi.encodeWithSelector(MarketBinding.selector, uint256(9)));
        vault.marketOf(9);
        vm.expectRevert(abi.encodeWithSelector(MarketBinding.selector, uint256(9)));
        vault.clMarket(9);
    }

    // TEST-264 verifies: REQ-AMM-V3-002, REQ-AMM-V3-008, REQ-AMM-CORE-017, REQ-AMM-CORE-004, INV-017
    // Sources: 2.20 REQ-AMM-V3-002 (factory, getPool, CREATE2 address, standard spacing); AMMN-RT-15
    function test_TEST_264_bindMarketRefusesNonCanonicalPools() public {
        PositionShape memory sh = PositionShape(ShapeKind.TickRange, -60, 60);
        bytes memory data = abi.encode(1e8, 1e8);
        MockV3Factory otherFactory = new MockV3Factory();
        address foreign = otherFactory.createPool(address(usdc), address(usdt), 3000, 60);
        address t0 = pool500.token0();
        address t1 = pool500.token1();
        FakeV3Pool fake = new FakeV3Pool(address(v3Factory), t0, t1, 10_000, 200);
        v3Factory.register(t0, t1, 10_000, address(fake));
        address odd = v3Factory.createPool(address(usdc), address(usdt), 2500, 50);
        address mismatched = v3Factory.createPool(address(usdc), address(usdt), 100, 60);
        address[6] memory bad = [address(0), alice, foreign, address(fake), odd, mismatched];
        for (uint256 i = 0; i < bad.length; ++i) {
            vm.prank(registry);
            vm.expectRevert(InvalidPool.selector);
            vault.bindMarket(10 + i, bad[i], bytes32(0), sh, data);
        }
        vm.prank(registry);
        vm.expectRevert(InvalidPool.selector);
        vault.bindMarket(20, address(pool3000), bytes32(uint256(1)), sh, data);
        // getPool names another address for the pool's own key.
        address p = v3Factory.createPool(address(usdc), address(usdt), 10_000, 200);
        v3Factory.register(t0, t1, 10_000, address(fake));
        vm.prank(registry);
        vm.expectRevert(InvalidPool.selector);
        vault.bindMarket(21, p, bytes32(0), PositionShape(ShapeKind.TickRange, -200, 200), data);
    }

    // TEST-264 verifies: REQ-AMM-V3-002, REQ-AMM-CORE-004, SPEC-UNIT-001
    function test_TEST_264_bindMarketRefusesBadListingData() public {
        PositionShape memory sh = PositionShape(ShapeKind.TickRange, -60, 60);
        bytes[5] memory datas = [
            bytes(""), abi.encode(uint256(1e8)), abi.encode(0, 1e8), abi.encode(1e8, 1e12 + 1), abi.encode(1e8, 1e8, 1)
        ];
        for (uint256 i = 0; i < datas.length; ++i) {
            vm.prank(registry);
            vm.expectRevert(InvalidPool.selector);
            vault.bindMarket(30 + i, address(pool3000), bytes32(0), sh, datas[i]);
        }
        // Tokens: no decimals() or more than 18 decimals. A pair whose whole token is worth less than $1 even at d = 18
        // now lists with a unit exponent k > 0 (SPEC-ORC-005).
        MintableToken d24 = new MintableToken("D24", 24);
        MintableToken d18a = new MintableToken("A18", 18);
        MintableToken d18b = new MintableToken("B18", 18);
        address noDec = v3Factory.createPool(address(new NoDecimalsToken()), address(usdc), 3000, 60);
        address big = v3Factory.createPool(address(d24), address(usdc), 3000, 60);
        address cheap = v3Factory.createPool(address(d18a), address(d18b), 3000, 60);
        vm.startPrank(registry);
        vm.expectRevert(InvalidPool.selector);
        vault.bindMarket(40, noDec, bytes32(0), sh, abi.encode(1e8, 1e8));
        vm.expectRevert(InvalidPool.selector);
        vault.bindMarket(41, big, bytes32(0), sh, abi.encode(1e8, 1e8));
        (, uint8 dCheap) = vault.bindMarket(
            42, cheap, bytes32(0), PositionShape(ShapeKind.TickRange, -887_220, 887_220), abi.encode(1, 1)
        );
        vm.stopPrank();
        assertGt(vault.unitExponent(42), 0, "a $0.00000001 pair lists through k");
        assertLe(dCheap, 18);
    }

    // TEST-264 verifies: SPEC-BACK-001, REQ-AMM-CORE-003, REQ-AMM-V3-008, REQ-ORACLE-105
    // Sources: 2.20 SPEC-BACK-001 example (-516 on spacing 10 refused), VaultTokenFactory review (canonical shapes)
    function test_TEST_264_bindMarketRefusesMalformedShapes() public {
        int24[2][6] memory bad = [
            [int24(-516), int24(500)],
            [int24(50), int24(50)],
            [int24(60), int24(50)],
            [int24(-887_280), int24(0)],
            [int24(0), int24(887_280)],
            [int24(-55), int24(50)]
        ];
        for (uint256 i = 0; i < bad.length; ++i) {
            vm.prank(registry);
            vm.expectRevert(InvalidShape.selector);
            vault.bindMarket(
                50 + i,
                address(pool500),
                bytes32(0),
                PositionShape(ShapeKind.TickRange, bad[i][0], bad[i][1]),
                abi.encode(1e8, 1e8)
            );
        }
        vm.startPrank(registry);
        vm.expectRevert(InvalidShape.selector);
        vault.bindMarket(
            60, address(pool500), bytes32(0), PositionShape(ShapeKind.FullPool, 0, 0), abi.encode(1e8, 1e8)
        );
        vm.expectRevert(InvalidShape.selector);
        vault.bindMarket(61, address(pool500), bytes32(0), PositionShape(ShapeKind.None, -50, 50), abi.encode(1e8, 1e8));
        vm.stopPrank();
        // Every aligned negative tick is accepted.
        _bind(62, address(pool500), -520, 500);
    }

    // ─── Composition ───

    // TEST-279 verifies: REQ-AMM-CORE-012, REQ-AMM-V3-005, SPEC-AMM-V3-001, SPEC-AMM-CORE-001, INV-078
    // Sources: 2.19 SPEC-AMM-CORE-001 example, 2.20 SPEC-AMM-V3-001 examples, TEST-279 (clamp, no ×2.97 value)
    function test_TEST_279_compositionAtTheClampedOraclePrice() public {
        (uint256[] memory a, bool exact) = vault.composition(M1, 1e9, _vec(1e8, 1e8));
        assertTrue(exact);
        assertEq(a[0], 2_496_751);
        assertEq(a[1], 2_496_751);
        assertEq(a[0] * 1e8 / 1e6 + a[1] * 1e8 / 1e6, 499_350_200, "worth $4.99");
        (a,) = vault.composition(M1, 1e9, _vec(1e8, 64_000_000));
        assertEq(a[0], 0);
        assertEq(a[1], 4_999_754, "above the range: all token1, worth $3.19");
        (a,) = vault.composition(M2, 5e9, _vec(1e8, 1e8));
        assertEq(a[0], 4_999_999_998);
        assertEq(a[1], 4_999_999_998);
        (a,) = vault.composition(M2, 5e9, _vec(1e8, 64_000_000));
        assertEq(a[0], 3_999_999_998);
        assertEq(a[1], 6_249_999_998);
        // The pool's own state never enters: spot moved and pool locked give the same amounts.
        pool3000.setPrice(20_000);
        pool3000.setUnlocked(false);
        (uint256[] memory b,) = vault.composition(M2, 5e9, _vec(1e8, 64_000_000));
        assertEq(b[0], a[0]);
        assertEq(b[1], a[1]);
    }

    // TEST-279 verifies: REQ-AMM-CORE-012, REQ-AMM-CORE-002, REQ-AMM-V3-005
    function test_TEST_279_compositionInputChecks() public {
        vm.expectRevert(abi.encodeWithSelector(LengthMismatch.selector, uint256(2), uint256(3)));
        vault.composition(M1, 1, new uint256[](3));
        vm.expectRevert(InvalidPrices.selector);
        vault.composition(M1, 1, _vec(0, 1e8));
        vm.expectRevert(InvalidPrices.selector);
        vault.composition(M1, 1, _vec(1e8, 1e12 + 1));
        vm.expectRevert(abi.encodeWithSelector(MarketBinding.selector, uint256(77)));
        vault.composition(77, 1, _vec(1e8, 1e8));
        (uint256[] memory a,) = vault.composition(M1, 0, _vec(1e8, 1e8));
        assertEq(a[0] + a[1], 0, "zero units hold nothing");
    }

    // TEST-279 verifies: SPEC-ORC-009, SPEC-ORC-006, REQ-ORACLE-104
    function test_TEST_279_oracleSqrtPriceReportsTheClamp() public view {
        (uint160 sO, uint160 sUsed, bool clamped) = vault.oracleSqrtPrice(M1, _vec(1e8, 1e8));
        assertEq(sO, 2 ** 96);
        assertEq(sUsed, 2 ** 96);
        assertFalse(clamped);
        (sO, sUsed, clamped) = vault.oracleSqrtPrice(M1, _vec(1e8, 64_000_000));
        assertGt(sO, ClPriceMath.sqrtRatioAtTick(50));
        assertEq(sUsed, ClPriceMath.sqrtRatioAtTick(50));
        assertTrue(clamped);
        (sO, sUsed, clamped) = vault.oracleSqrtPrice(M1, _vec(64_000_000, 1e8));
        assertEq(sUsed, ClPriceMath.sqrtRatioAtTick(-50));
        assertTrue(clamped);
    }

    // TEST-279 verifies: SPEC-ORC-009, SPEC-ORC-006, SPEC-AMM-V3-001, REQ-AMM-V3-005, REQ-ORACLE-104
    // Sources: review CL-01 PoC (the same market on the full range of the 0.3% tier); 2.10 SPEC-ORC-009 example (b)
    function test_TEST_279_fullRangeQuoteStaysFairAboveTheTwoTo64Ratio() public {
        (MintableToken t0, MintableToken t1) = _pair6x18();
        MockV3Pool pool = MockV3Pool(v3Factory.createPool(address(t0), address(t1), 3000, 60));
        _bind(3, address(pool), -FULL_60, FULL_60);
        (uint256 p0, uint256 p1, uint256 units) = (1e8, 5, 5e15);
        (uint160 sO, uint160 sUsed, bool clamped) = vault.oracleSqrtPrice(3, _vec(p0, p1));
        assertEq(sO, 354_319_114_228_591_420_592_203_432_319_359_385_600, "the root, not MAX_SQRT_RATIO - 1");
        assertEq(sUsed, sO, "inside the full range");
        assertFalse(clamped);
        (uint256[] memory c,) = vault.composition(3, units, _vec(p0, p1));
        (uint256 quoted, uint256 fair) = _quotedAndFair6x18(c, units, p0, p1);
        assertGt(c[0], 0, "both tokens, not all token1 at the top of the range");
        assertLe(quoted, fair, "never above the fair value");
        assertGe(quoted * 1e6, fair * (1e6 - 1), "within 1 ppm of the fair value ($2.24)");
    }

    // TEST-279 verifies: SPEC-AMM-V3-001, SPEC-ORC-007, INV-078, REQ-AMM-V3-005
    // Sources: AMM-A1a (removal at any spot is worth at least the composition), AMM-A3f
    function testFuzz_TEST_279_compositionNeverAboveWhatARemovalReturns(
        uint128 units,
        int24 spotSeed,
        uint256 p1Seed
    ) public {
        units = uint128(bound(units, 1e6, 1e22));
        uint256 p1 = bound(p1Seed, 50_000_000, 150_000_000);
        int24 spot = int24(bound(int256(spotSeed), -2000, 2000));
        (uint256[] memory a,) = vault.composition(M1, units, _vec(1e8, p1));
        pool500.setPrice(spot);
        bytes32 key = _pledge1(alice, units);
        uint256[] memory r =
            abi.decode(_asColl(abi.encodeCall(vault.unwind, (key, units, _zeros(), lpVaultSwap))), (uint256[]));
        // Value at oracle prices, 8 decimals, of the composition against the removal (both tokens 6 decimals).
        uint256 vComp = a[0] * 1e8 / 1e6 + a[1] * p1 / 1e6;
        uint256 vRemoved = r[0] * 1e8 / 1e6 + r[1] * p1 / 1e6;
        assertLe(vComp, vRemoved + 1, "a pushed spot never makes the removal worth less than the quote");
    }

    // ─── Risk metadata and hooks ───

    // TEST-264 verifies: REQ-AMM-CORE-013, REQ-AMM-V3-006, REQ-AMM-CORE-008
    function test_TEST_264_riskMetadataRangeAndPoolLock() public {
        bytes32 key = _pledge1(alice, 1e9);
        pool500.setLiquidity(4e12);
        RiskMetadata memory r = vault.riskMetadata(M1, key);
        assertTrue(r.inRange);
        assertTrue(r.readSafe);
        assertEq(r.poolUnits, 4e12);
        assertEq(r.positionUnits, 1e9);
        assertEq(r.avanaUnits, 0);
        assertEq(r.poolShareBps, 0);
        pool500.setPrice(50);
        assertFalse(vault.riskMetadata(M1, bytes32(0)).inRange, "upper tick is outside");
        pool500.setPrice(-50);
        assertTrue(vault.riskMetadata(M1, bytes32(0)).inRange, "lower tick is inside");
        pool500.setPrice(-51);
        r = vault.riskMetadata(M1, bytes32(0));
        assertFalse(r.inRange);
        assertEq(r.positionUnits, 0);
        pool500.setUnlocked(false);
        assertFalse(vault.riskMetadata(M1, bytes32(0)).readSafe);
        vm.expectRevert(PoolLocked.selector);
        vault.checkReadSafe(M1);
        pool500.setUnlocked(true);
        vault.checkReadSafe(M1);
    }

    // TEST-264 verifies: REQ-AMM-CORE-013, REQ-AMM-V3-006, SPEC-CAP-005
    function test_TEST_264_riskStatusHarmonicDepth() public {
        assertFalse(vault.riskStatus(M1, 0).depthAvailable, "zero window");
        pool500.setObservations(200, 0, 0, 0, uint160((uint256(1800) << 128) / 2.5e18), false);
        RiskStatus memory s = vault.riskStatus(M1, 1800);
        assertTrue(s.depthAvailable);
        assertApproxEqRel(s.depthUnits, 2.5e18, 1e9);
        pool500.setObservations(200, 0, 0, 0, 0, false);
        assertFalse(vault.riskStatus(M1, 1800).depthAvailable, "no seconds-per-liquidity change");
        pool500.setObservations(200, 0, 0, 0, 1, true);
        assertFalse(vault.riskStatus(M1, 1800).depthAvailable, "observe reverts (OLD)");
    }

    // TEST-264 verifies: SPEC-ORC-010, SPEC-ORC-022, REQ-AMM-CORE-009
    function test_TEST_264_consistencyDeviationInTicks() public {
        uint256[] memory peg = _vec(1e8, 1e8);
        pool500.setObservations(151, 0, 1800 * 7, 0, 1, false);
        (uint256 dev, bool ok) = vault.consistencyDeviation(M1, 1800, peg);
        assertTrue(ok);
        assertEq(dev, 7, "mean tick 7 against the oracle tick 0");
        pool500.setObservations(151, 0, -1800 * 9 - 1, 0, 1, false);
        (dev, ok) = vault.consistencyDeviation(M1, 1800, peg);
        assertEq(dev, 10, "rounds toward negative infinity");
        pool500.setObservations(150, 0, 0, 0, 1, false);
        (, ok) = vault.consistencyDeviation(M1, 1800, peg);
        assertFalse(ok, "151 observations needed at 12 s blocks");
        pool500.setObservations(151, 0, 0, 0, 1, true);
        (, ok) = vault.consistencyDeviation(M1, 1800, peg);
        assertFalse(ok, "observe reverts");
        (, ok) = vault.consistencyDeviation(M1, 0, peg);
        assertFalse(ok);
        vm.expectRevert(abi.encodeWithSelector(LengthMismatch.selector, uint256(2), uint256(1)));
        vault.consistencyDeviation(M1, 1800, new uint256[](1));
    }

    // TEST-264 verifies: REQ-AMM-CORE-010, REQ-AMM-CORE-012, REQ-AMM-CORE-014
    function test_TEST_264_neutralHooks() public {
        address[] memory providers = vault.rateProviders(M1);
        assertEq(providers.length, 2);
        assertEq(providers[0], address(0));
        assertEq(providers[1], address(0));
        assertEq(vault.wrappedNative(), address(0));
        assertTrue(vault.isAllowedPoolHook(address(0)));
        assertFalse(vault.isAllowedPoolHook(alice));
        assertEq(vault.effectiveSupply(M1), 0);
        vm.expectRevert(abi.encodeWithSelector(MarketBinding.selector, uint256(8)));
        vault.rateProviders(8);
        vm.expectRevert(abi.encodeWithSelector(MarketBinding.selector, uint256(8)));
        vault.effectiveSupply(8);
        vm.expectRevert(abi.encodeWithSelector(MarketBinding.selector, uint256(8)));
        vault.checkReadSafe(8);
        vm.expectRevert(abi.encodeWithSelector(MarketBinding.selector, uint256(8)));
        vault.riskStatus(8, 1800);
    }

    // TEST-264 verifies: REQ-AMM-V3-002
    function test_TEST_264_harnessDiffersOnlyInTheInitCodeHash() public {
        UniswapV3Integration prod = new UniswapV3Integration(
            INTEGRATION, coll, registry, address(lock), timelock, address(nfpm), address(v3Factory), 12
        );
        assertEq(prod.POOL_INIT_CODE_HASH(), 0xe34f199b19b2b4f47f68442619d555527d244f78a3297ea89325f843f87b8b54);
        // The production contract refuses a mock pool: its CREATE2 address is not the canonical one.
        vm.prank(registry);
        vm.expectRevert(InvalidPool.selector);
        prod.bindMarket(
            1, address(pool500), bytes32(0), PositionShape(ShapeKind.TickRange, -50, 50), abi.encode(1e8, 1e8)
        );
        UniswapV3IntegrationHarness h = vault;
        assertEq(h.POOL_INIT_CODE_HASH(), prod.POOL_INIT_CODE_HASH());
    }

    /// @dev A 6-decimal token0 and an 18-decimal token1 (pool order by address).
    function _pair6x18() internal returns (MintableToken t0, MintableToken t1) {
        t1 = new MintableToken("T18", 18);
        t0 = new MintableToken("T6", 6);
        while (address(t0) > address(t1)) {
            t0 = new MintableToken("T6", 6);
        }
    }

    /// @dev Value in 8 decimals of a 6/18-decimal composition, and the fair value `2 * L * sqrt(p0 * p1 / 10^24)` of a
    /// full-range position of `units` (the ideal full range; the tick-bounded range holds `1 - 1.2e-10` of it here).
    function _quotedAndFair6x18(
        uint256[] memory c,
        uint256 units,
        uint256 p0,
        uint256 p1
    ) internal pure returns (uint256 quoted, uint256 fair) {
        quoted = c[0] * p0 / 1e6 + c[1] * p1 / 1e18;
        fair = 2 * units * Math.sqrt(p0 * p1 * 1e12) / 1e18;
    }
}
