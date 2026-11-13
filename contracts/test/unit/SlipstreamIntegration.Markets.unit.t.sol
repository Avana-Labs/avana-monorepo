// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ClPriceMath} from "../../src/amm/concentrated-liquidity/ClPriceMath.sol";
import {SlipstreamIntegration} from "../../src/amm/slipstream/SlipstreamIntegration.sol";
import {ClMarketConfig} from "../../src/amm/types/ClMarketConfig.sol";
import {IntegrationCapabilities} from "../../src/amm/types/IntegrationCapabilities.sol";
import {PoolKeying} from "../../src/amm/types/PoolKeying.sol";
import {RiskMetadata} from "../../src/amm/types/RiskMetadata.sol";
import {RiskStatus} from "../../src/amm/types/RiskStatus.sol";
import {PositionShape} from "../../src/types/PositionShape.sol";
import {ShapeKind} from "../../src/types/ShapeKind.sol";
import {SlipstreamIntegrationFixture} from "../utils/fixtures/SlipstreamIntegrationFixture.sol";
import {MockCLFactory, MockCLPool, MockSlipstreamNPM} from "../utils/mocks/SlipstreamMocks.sol";
import {MintableToken, NoDecimalsToken} from "../utils/mocks/UniswapV3Mocks.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @notice A Slipstream pool look-alike that is not a clone of the factory's implementation: same interface, own
/// bytecode, settable fields (a fork of the pool, `SPEC-AMM-SLIP-001`).
contract ForkedCLPool {
    address public factory;
    address public token0;
    address public token1;
    int24 public tickSpacing;
    address public nft;
    uint24 public fee = 100;

    constructor(
        address f,
        address t0,
        address t1,
        int24 s,
        address n
    ) {
        (factory, token0, token1, tickSpacing, nft) = (f, t0, t1, s, n);
    }
}

/// @notice Slipstream LPVault deployment, the generation allowlist, market binding, composition, risk metadata and
/// hooks.
/// forge-config: default.isolate = false
contract SlipstreamIntegrationMarketsUnitTest is SlipstreamIntegrationFixture {
    // ─── Deployment and identity ───

    // TEST-108 verifies: REQ-VAULT-155, REQ-VAULT-002, REQ-AMM-SLIP-006, INV-052, INV-017
    // Sources: 2.21 REQ-AMM-SLIP-006 (eight distinct addresses with code, each manager naming its paired factory)
    function test_TEST_108_constructorFailsClosed() public {
        address[4] memory n = _npmList();
        address[4] memory f = _factoryList();
        address l = address(lock);
        vm.expectRevert(InvalidDeployment.selector);
        new SlipstreamIntegration(0, coll, registry, l, timelock, n, f);
        vm.expectRevert(InvalidDeployment.selector);
        new SlipstreamIntegration(1, coll, coll, l, timelock, n, f);
        address[4][7] memory badN;
        address[4][7] memory badF;
        for (uint256 i = 0; i < 7; ++i) {
            (badN[i], badF[i]) = (n, f);
        }
        badN[0][3] = address(0); // zero manager
        badF[1][0] = address(0); // zero factory
        badN[2][1] = alice; // no code
        badN[3][2] = n[1]; // two generations share a manager
        badF[4][3] = address(lock); // a factory equal to an Avana binding
        (badN[5][0], badN[5][1]) = (n[1], n[0]); // managers swapped: each names the other's factory
        badF[6][2] = address(new MockCLFactory()); // a manager whose factory() is another factory
        for (uint256 i = 0; i < 7; ++i) {
            vm.expectRevert(InvalidDeployment.selector);
            new SlipstreamIntegration(1, coll, registry, l, timelock, badN[i], badF[i]);
        }
        // A generation-3 manager that names generation 0's factory, paired with generation 3's.
        MockSlipstreamNPM stray = new MockSlipstreamNPM(address(factories[0]));
        n[3] = address(stray);
        vm.expectRevert(InvalidDeployment.selector);
        new SlipstreamIntegration(1, coll, registry, l, timelock, n, f);
    }

    // TEST-108 verifies: REQ-VAULT-155, REQ-AMM-CORE-001, REQ-AMM-CORE-009, REQ-AMM-SLIP-006, SPEC-AMM-CORE-002
    function test_TEST_108_identityGetters() public {
        assertEq(vault.INTEGRATION_ID(), INTEGRATION);
        assertEq(vault.COLLATERALIZATION(), coll);
        assertEq(vault.MARKET_REGISTRY(), registry);
        assertEq(vault.LOCK(), address(lock));
        assertEq(vault.TIMELOCK(), timelock);
        assertEq(vault.AMM_PROTOCOL(), keccak256("AERODROME_SLIPSTREAM"));
        assertEq(vault.generationCount(), 4);
        for (uint8 g = 0; g < 4; ++g) {
            (address npm, address factory) = vault.generation(g);
            assertEq(npm, address(npms[g]));
            assertEq(factory, address(factories[g]));
        }
        vm.expectRevert(InvalidPool.selector);
        vault.generation(4);
        IntegrationCapabilities memory c = vault.capabilities();
        assertEq(uint8(c.poolKeying), uint8(PoolKeying.Address));
        assertEq(uint8(c.shapeKind), uint8(ShapeKind.TickRange));
        assertTrue(c.hasTwap && c.reentrancyGuarded && !c.nativeToken && !c.rateTokens);
        assertEq(vault.tokenIdOf(_key(3, 42)), 42);
        assertEq(vault.positionKeyOf(3, 42), _key(3, 42));
    }

    // TEST-108 verifies: REQ-VAULT-001, REQ-VAULT-085, REQ-VAULT-097, REQ-VAULT-150, REQ-AMM-SLIP-006, REQ-AMM-SLIP-010, REQ-ACCESS-022, REQ-ACCESS-113
    // Sources: no proxy, owner, pause, sweep, rescue, allowlist setter, stake, claim or generic call entry point exists
    function test_TEST_108_noUpgradeOwnerPauseRescueOrGaugeSurface() public {
        bytes[12] memory probes = [
            abi.encodeWithSignature("proxiableUUID()"),
            abi.encodeWithSignature("upgradeToAndCall(address,bytes)", alice, ""),
            abi.encodeWithSignature("owner()"),
            abi.encodeWithSignature("pause()"),
            abi.encodeWithSignature("sweep(address,address,uint256)", address(usdc), alice, 1),
            abi.encodeWithSignature("rescue(address,address,uint256)", address(usdc), alice, 1),
            abi.encodeWithSignature("multicall(bytes[])", new bytes[](0)),
            abi.encodeWithSignature("execute(address,uint256,bytes)", alice, 0, ""),
            abi.encodeWithSignature("isValidSignature(bytes32,bytes)", bytes32(0), ""),
            abi.encodeWithSignature("setGeneration(uint8,address,address)", 0, alice, alice),
            abi.encodeWithSignature("stake(bytes32)", bytes32(0)),
            abi.encodeWithSignature("getReward(uint256)", 1)
        ];
        for (uint256 i = 0; i < probes.length; ++i) {
            (bool ok,) = address(vault).call(probes[i]);
            assertFalse(ok);
        }
    }

    // ─── bindMarket ───

    // TEST-265 verifies: REQ-AMM-CORE-003, REQ-AMM-SLIP-007, REQ-AMM-SLIP-002, REQ-AMM-SLIP-005, REQ-VAULT-166, SPEC-AMM-SLIP-001, SPEC-UNIT-001
    // Sources: 2.4 SPEC-UNIT-001 examples ([-50, 50] gives 9, full range gives 6); 2.21 storage (fee is never stored)
    function test_TEST_265_bindMarketStoresThePoolRangeAndGeneration() public {
        MockCLPool p = MockCLPool(factories[0].createPool(address(usdc), address(usdt), 1));
        vm.expectEmit(address(vault));
        emit MarketBound(3, address(p), bytes32(0), -10, 10);
        (address[] memory tokens, uint8 d) = _bind(3, address(p), 0, -10, 10);
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
        assertEq(cfg.positionManager, address(npms[0]));
        assertEq(cfg.factory, address(factories[0]));
        assertEq(cfg.fee, 0, "the dynamic fee is never stored");
        assertEq(cfg.tickSpacing, 1);
        assertEq(cfg.maxLiquidityPerTick, ClPriceMath.maxLiquidityPerTick(1));
        assertEq(vault.clMarket(M1).positionManager, address(npms[G1]));
        assertEq(vault.clMarket(M2).positionManager, address(npms[G2]));
        (, d) = _bind(4, address(pool1), G1, -100, 100);
        assertEq(d, 9);
        (, d) = _bind(5, address(pool100), G2, -FULL_100, FULL_100);
        assertEq(d, 6);
    }

    // TEST-265 verifies: REQ-AMM-CORE-003, REQ-VAULT-156, REQ-VAULT-166
    function test_TEST_265_bindMarketCallerAndWriteOnce() public {
        PositionShape memory sh = PositionShape(ShapeKind.TickRange, -50, 50);
        vm.prank(alice);
        vm.expectRevert(NotMarketRegistry.selector);
        vault.bindMarket(9, address(pool1), bytes32(0), sh, _data(G1));
        vm.startPrank(registry);
        vm.expectRevert(abi.encodeWithSelector(MarketBinding.selector, M1));
        vault.bindMarket(M1, address(pool1), bytes32(0), sh, _data(G1));
        vm.expectRevert(abi.encodeWithSelector(MarketBinding.selector, uint256(0)));
        vault.bindMarket(0, address(pool1), bytes32(0), sh, _data(G1));
        vm.stopPrank();
        vm.expectRevert(abi.encodeWithSelector(MarketBinding.selector, uint256(9)));
        vault.marketOf(9);
        vm.expectRevert(abi.encodeWithSelector(MarketBinding.selector, uint256(9)));
        vault.clMarket(9);
    }

    // TEST-265 verifies: REQ-AMM-SLIP-007, REQ-AMM-SLIP-015, REQ-AMM-SLIP-016, SPEC-AMM-SLIP-001, REQ-AMM-CORE-017, INV-017
    // Sources: 2.21 SPEC-AMM-SLIP-001 examples (another generation's manager, a forked pool, an unregistered pool)
    function test_TEST_265_bindMarketRefusesPoolsOutsideThePinnedGeneration() public {
        PositionShape memory sh = PositionShape(ShapeKind.TickRange, -50, 50);
        address t0 = pool1.token0();
        address t1 = pool1.token1();
        ForkedCLPool forked = new ForkedCLPool(address(factories[G1]), t0, t1, 1, address(npms[G1]));
        // A clone deployed by another factory (its own implementation), which the pinned factory never registered.
        MockCLFactory twin = new MockCLFactory();
        twin.setNft(address(npms[G1]));
        address foreignClone = twin.createPool(address(usdc), address(usdt), 1);
        address[3] memory bad = [address(forked), foreignClone, alice];
        for (uint256 i = 0; i < bad.length; ++i) {
            vm.prank(registry);
            vm.expectRevert(InvalidPool.selector);
            vault.bindMarket(10 + i, bad[i], bytes32(0), sh, _data(G1));
        }
        // The right pool named with every other generation: wrong clone implementation, factory and manager.
        for (uint256 g = 0; g < 4; ++g) {
            if (g == G1) continue;
            vm.prank(registry);
            vm.expectRevert(InvalidPool.selector);
            vault.bindMarket(20 + g, address(pool1), bytes32(0), sh, _data(g));
        }
        // A registered clone whose nft() is another generation's manager.
        factories[G1].setNft(address(npms[0]));
        address wrongNft = factories[G1].createPool(address(usdc), address(usdt), 50);
        vm.prank(registry);
        vm.expectRevert(InvalidPool.selector);
        vault.bindMarket(30, wrongNft, bytes32(0), PositionShape(ShapeKind.TickRange, -50, 50), _data(G1));
        // getPool names another address for the pool's own key.
        factories[G1].setNft(address(npms[G1]));
        address p200 = factories[G1].createPool(address(usdc), address(usdt), 200);
        factories[G1].register(t0, t1, 200, address(pool1));
        vm.prank(registry);
        vm.expectRevert(InvalidPool.selector);
        vault.bindMarket(31, p200, bytes32(0), PositionShape(ShapeKind.TickRange, -200, 200), _data(G1));
        // A pool id is refused.
        vm.prank(registry);
        vm.expectRevert(InvalidPool.selector);
        vault.bindMarket(32, address(pool1), bytes32(uint256(1)), sh, _data(G1));
    }

    // TEST-265 verifies: REQ-AMM-SLIP-007, REQ-AMM-CORE-004, SPEC-UNIT-001
    function test_TEST_265_bindMarketRefusesBadListingData() public {
        PositionShape memory sh = PositionShape(ShapeKind.TickRange, -50, 50);
        bytes[7] memory datas = [
            bytes(""),
            abi.encode(uint256(G1)),
            abi.encode(1e8, 1e8),
            abi.encode(uint256(4), 1e8, 1e8),
            abi.encode(uint256(G1) | (1 << 8), 1e8, 1e8),
            abi.encode(uint256(G1), 0, 1e8),
            abi.encode(uint256(G1), 1e8, 1e18 + 1)
        ];
        for (uint256 i = 0; i < datas.length; ++i) {
            vm.prank(registry);
            vm.expectRevert(InvalidPool.selector);
            vault.bindMarket(40 + i, address(pool1), bytes32(0), sh, datas[i]);
        }
        vm.prank(registry);
        vm.expectRevert(InvalidPool.selector);
        vault.bindMarket(47, address(pool1), bytes32(0), sh, abi.encode(uint256(G1), 1e8, 1e8, 1));
        MintableToken d24 = new MintableToken("D24", 24);
        address noDec = factories[G1].createPool(address(new NoDecimalsToken()), address(usdc), 100);
        address big = factories[G1].createPool(address(d24), address(usdc), 100);
        vm.startPrank(registry);
        vm.expectRevert(InvalidPool.selector);
        vault.bindMarket(48, noDec, bytes32(0), PositionShape(ShapeKind.TickRange, -100, 100), _data(G1));
        vm.expectRevert(InvalidPool.selector);
        vault.bindMarket(49, big, bytes32(0), PositionShape(ShapeKind.TickRange, -100, 100), _data(G1));
        vm.stopPrank();
    }

    // TEST-265 verifies: REQ-AMM-SLIP-008, REQ-AMM-SLIP-017, SPEC-BACK-001, REQ-AMM-CORE-003
    // Sources: 2.21 REQ-AMM-SLIP-008 examples (-1,216 on spacing 2,000 and -116 on spacing 100 refused by the signed
    // check; usable ticks [-886,000, 886,000] at spacing 2,000); MATH-AMM-V3-PRICE-05, AMM-A5a–c, HYP-AMM-05
    function test_TEST_265_bindMarketChecksSpacingAndSignedAlignment() public {
        address p2000 = factories[G1].createPool(address(usdc), address(usdt), 2000);
        int24[2][4] memory bad2000 = [
            [int24(-1216), int24(2000)], [int24(-888_000), int24(0)], [int24(0), int24(888_000)], [int24(0), int24(0)]
        ];
        for (uint256 i = 0; i < bad2000.length; ++i) {
            vm.prank(registry);
            vm.expectRevert(InvalidShape.selector);
            vault.bindMarket(
                50 + i, p2000, bytes32(0), PositionShape(ShapeKind.TickRange, bad2000[i][0], bad2000[i][1]), _data(G1)
            );
        }
        (, uint8 d) = _bind(55, p2000, G1, -886_000, 886_000);
        assertEq(d, 6);
        assertEq(vault.clMarket(55).maxLiquidityPerTick, ClPriceMath.maxLiquidityPerTick(2000));
        vm.prank(registry);
        vm.expectRevert(InvalidShape.selector);
        vault.bindMarket(56, address(pool100), bytes32(0), PositionShape(ShapeKind.TickRange, -116, 100), _data(G2));
        _bind(57, address(pool100), G2, -200, 100);
        // A spacing the factory has not enabled is refused, even for a registered clone.
        address p7 = factories[G1].createPool(address(usdc), address(usdt), 7);
        vm.prank(registry);
        vm.expectRevert(InvalidPool.selector);
        vault.bindMarket(58, p7, bytes32(0), PositionShape(ShapeKind.TickRange, -7, 7), _data(G1));
        // Enabled later, the same pool lists.
        factories[G1].enableTickSpacing(7, 300);
        _bind(59, p7, G1, -7, 7);
        vm.startPrank(registry);
        vm.expectRevert(InvalidShape.selector);
        vault.bindMarket(60, address(pool1), bytes32(0), PositionShape(ShapeKind.FullPool, 0, 0), _data(G1));
        vm.stopPrank();
    }

    // TEST-265 verifies: REQ-AMM-SLIP-008, REQ-AMM-SLIP-014, REQ-AMM-SLIP-017
    // Sources: review CL-03 PoC (an enabled spacing of 8,000 bound a market above 2^120 - 1 per tick); 2.21
    // REQ-AMM-SLIP-008 (spacings above 6,931 refused), MATH-AMM-V3-PRICE-05
    function test_TEST_265_bindMarketRefusesSpacingsAboveTheCreditedLiquidityBound() public {
        int24[2] memory refused = [int24(6932), int24(8000)];
        for (uint256 i = 0; i < refused.length; ++i) {
            int24 sp = refused[i];
            factories[G2].enableTickSpacing(sp, 10_000);
            address p = factories[G2].createPool(address(usdc), address(usdt), sp);
            int24 full = (887_272 / sp) * sp;
            vm.prank(registry);
            vm.expectRevert(InvalidPool.selector);
            vault.bindMarket(70 + i, p, bytes32(0), PositionShape(ShapeKind.TickRange, -full, full), _data(G2));
        }
        factories[G2].enableTickSpacing(6931, 10_000);
        address p6931 = factories[G2].createPool(address(usdc), address(usdt), 6931);
        _bind(72, p6931, G2, -887_168, 887_168);
        assertLe(vault.clMarket(72).maxLiquidityPerTick, 2 ** 120 - 1, "REQ-AMM-SLIP-014 bound holds on chain");
    }

    // ─── Composition ───

    // TEST-279 verifies: REQ-AMM-CORE-012, REQ-AMM-SLIP-012, REQ-AMM-SLIP-005, SPEC-AMM-V3-001, SPEC-AMM-CORE-001, INV-078
    // Sources: 2.20 SPEC-AMM-V3-001 examples; 2.21 REQ-AMM-SLIP-012 (the fee plays no part)
    function test_TEST_279_compositionAtTheClampedOraclePriceIgnoresTheFee() public {
        (uint256[] memory a, bool exact) = vault.composition(M1, 1e9, _vec(1e8, 1e8));
        assertTrue(exact);
        assertEq(a[0], 2_496_751);
        assertEq(a[1], 2_496_751);
        (a,) = vault.composition(M1, 1e9, _vec(1e8, 64_000_000));
        assertEq(a[0], 0);
        assertEq(a[1], 4_999_754);
        (uint256[] memory b,) = vault.composition(M2, 5e9, _vec(1e8, 1e8));
        pool100.setFee(30_000);
        pool100.setPrice(20_000);
        pool100.setUnlocked(false);
        (uint256[] memory c,) = vault.composition(M2, 5e9, _vec(1e8, 1e8));
        assertEq(c[0], b[0], "a fee change, a spot move and the pool lock change nothing");
        assertEq(c[1], b[1]);
    }

    // TEST-279 verifies: REQ-AMM-CORE-012, REQ-AMM-CORE-002
    function test_TEST_279_compositionInputChecks() public {
        vm.expectRevert(abi.encodeWithSelector(LengthMismatch.selector, uint256(2), uint256(3)));
        vault.composition(M1, 1, new uint256[](3));
        vm.expectRevert(InvalidPrices.selector);
        vault.composition(M1, 1, _vec(0, 1e8));
        vm.expectRevert(InvalidPrices.selector);
        vault.composition(M1, 1, _vec(1e8, 1e18 + 1));
        vm.expectRevert(InvalidPrices.selector);
        vault.composition(M1, 1, _vec(1e18 + 1, 1e8));
        // MAX_ROUTE_ANSWER = 10^18 itself is a valid price (ORACLE-04: an ETH above $10,000 stays a route value).
        vault.composition(M1, 1, _vec(1e8, 1e18));
        vault.composition(M1, 1, _vec(1e18, 1e8));
        vm.expectRevert(abi.encodeWithSelector(MarketBinding.selector, uint256(77)));
        vault.composition(77, 1, _vec(1e8, 1e8));
        (uint256[] memory a,) = vault.composition(M1, 0, _vec(1e8, 1e8));
        assertEq(a[0] + a[1], 0);
        (uint160 sO, uint160 sUsed, bool clamped) = vault.oracleSqrtPrice(M1, _vec(1e8, 64_000_000));
        assertGt(sO, ClPriceMath.sqrtRatioAtTick(50));
        assertEq(sUsed, ClPriceMath.sqrtRatioAtTick(50));
        assertTrue(clamped);
    }

    // TEST-279 verifies: SPEC-ORC-009, SPEC-ORC-006, SPEC-AMM-V3-001, REQ-AMM-SLIP-012, REQ-ORACLE-104
    // Sources: review CL-01 PoC (a 6- and 18-decimal full-range market with token1 at $5e-8 was quoted at 2e9 times its
    // value); 2.10 SPEC-ORC-009 example (b), MATH-UO-11k
    function test_TEST_279_fullRangeQuoteStaysFairAboveTheTwoTo64Ratio() public {
        (MintableToken t0, MintableToken t1) = _pair6x18();
        MockCLPool pool = MockCLPool(factories[G2].createPool(address(t0), address(t1), 100));
        _bind(3, address(pool), G2, -FULL_100, FULL_100);
        // token1 (18 decimals) falls to 5 * 10^-8 USD: the raw ratio is 2 * 10^19 >= 2^64.
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

    // TEST-279 verifies: SPEC-AMM-V3-001, SPEC-ORC-007, INV-078, REQ-AMM-SLIP-012
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
        pool1.setPrice(spot);
        bytes32 key = _pledge1(alice, units);
        uint256[] memory r =
            abi.decode(_asColl(abi.encodeCall(vault.unwind, (key, units, _zeros(), lpVaultSwap))), (uint256[]));
        uint256 vComp = a[0] * 1e8 / 1e6 + a[1] * p1 / 1e6;
        uint256 vRemoved = r[0] * 1e8 / 1e6 + r[1] * p1 / 1e6;
        assertLe(vComp, vRemoved + 1);
    }

    // ─── Risk metadata and hooks ───

    // TEST-265 verifies: REQ-AMM-CORE-013, REQ-AMM-SLIP-004, REQ-AMM-SLIP-020, REQ-AMM-CORE-008
    // Sources: 2.21 REQ-AMM-SLIP-004 (the lock flag is field 6 of the six-field slot0)
    function test_TEST_265_riskMetadataReadsTheSixFieldSlot0() public {
        bytes32 key = _pledge1(alice, 1e9);
        pool1.setLiquidity(4e12);
        RiskMetadata memory r = vault.riskMetadata(M1, key);
        assertTrue(r.inRange);
        assertTrue(r.readSafe);
        assertEq(r.poolUnits, 4e12);
        assertEq(r.positionUnits, 1e9);
        assertEq(r.avanaUnits, 0);
        pool1.setPrice(50);
        assertFalse(vault.riskMetadata(M1, bytes32(0)).inRange);
        pool1.setPrice(-50);
        assertTrue(vault.riskMetadata(M1, bytes32(0)).inRange);
        pool1.setUnlocked(false);
        assertFalse(vault.riskMetadata(M1, bytes32(0)).readSafe);
        vm.expectRevert(PoolLocked.selector);
        vault.checkReadSafe(M1);
        pool1.setUnlocked(true);
        vault.checkReadSafe(M1);
    }

    // TEST-265 verifies: REQ-AMM-SLIP-013, REQ-AMM-CORE-013, SPEC-CAP-005
    function test_TEST_265_riskStatusHarmonicDepth() public {
        assertFalse(vault.riskStatus(M1, 0).depthAvailable);
        pool1.setObservations(1000, 0, 0, 0, uint160((uint256(1800) << 128) / 2.5e18), false);
        RiskStatus memory s = vault.riskStatus(M1, 1800);
        assertTrue(s.depthAvailable);
        assertApproxEqRel(s.depthUnits, 2.5e18, 1e9);
        pool1.setObservations(1000, 0, 0, 0, 1, true);
        assertFalse(vault.riskStatus(M1, 1800).depthAvailable, "observe reverts (OLD)");
    }

    // TEST-265 verifies: SPEC-ORC-010, SPEC-ORC-022, REQ-AMM-SLIP-013, REQ-AMM-CORE-009
    // Sources: 2.21 (ceil(1,800 / 2) + 1 = 901 observations at Base's 2 s blocks, AMMN-RT-08)
    function test_TEST_265_consistencyDeviationNeeds901Observations() public {
        uint256[] memory peg = _vec(1e8, 1e8);
        pool1.setObservations(901, 0, 1800 * 7, 0, 1, false);
        (uint256 dev, bool ok) = vault.consistencyDeviation(M1, 1800, peg);
        assertTrue(ok);
        assertEq(dev, 7);
        pool1.setObservations(900, 0, 1800 * 7, 0, 1, false);
        (, ok) = vault.consistencyDeviation(M1, 1800, peg);
        assertFalse(ok, "900 observations do not cover 1,800 s at 2 s blocks");
    }

    // TEST-264 verifies: REQ-AMM-CORE-010, REQ-AMM-CORE-012, REQ-AMM-CORE-014
    function test_TEST_264_neutralHooks() public {
        address[] memory providers = vault.rateProviders(M1);
        assertEq(providers.length, 2);
        assertEq(providers[0], address(0));
        assertEq(vault.wrappedNative(), address(0));
        assertTrue(vault.isAllowedPoolHook(address(0)));
        assertFalse(vault.isAllowedPoolHook(alice));
        assertEq(vault.effectiveSupply(M1), 0);
        vm.expectRevert(abi.encodeWithSelector(MarketBinding.selector, uint256(8)));
        vault.rateProviders(8);
        vm.expectRevert(abi.encodeWithSelector(MarketBinding.selector, uint256(8)));
        vault.checkReadSafe(8);
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
