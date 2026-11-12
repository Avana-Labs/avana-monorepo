// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {MarketStatus} from "../../src/policy/market-registry/types/MarketStatus.sol";
import {IParameterStoreErrors} from "../../src/policy/parameter-store/IParameterStoreErrors.sol";
import {IParameterStoreEvents} from "../../src/policy/parameter-store/IParameterStoreEvents.sol";
import {DebtReserveParams} from "../../src/policy/parameter-store/types/DebtReserveParams.sol";
import {MarketParams} from "../../src/policy/parameter-store/types/MarketParams.sol";
import {Market} from "../../src/types/Market.sol";
import {ParameterStoreFixture} from "../utils/fixtures/ParameterStoreFixture.sol";

/// @notice REQ-PSTORE-017 for each of the six step-limited parameters: the exact step edge with integer
/// comparisons, the spacing measured from the timelock's live `normalDelay`, one key per scope, the order of the
/// step, `addCap` and spacing checks, and the setters that neither check nor update the spacing.
contract ParameterStoreLoosenStepsUnitTest is ParameterStoreFixture {
    uint256 internal constant M2 = 2;
    address internal hub2 = makeAddr("hub2");

    function setUp() public {
        _deployStore(false);
        _listMarket();
        registry.setHub(hub2, true);
        Market memory m = registry.getMarket(M);
        m.pool = makeAddr("pool2");
        m.vaultToken = makeAddr("vaultToken2");
        m.lpOracle = makeAddr("lpOracle2Unused");
        // Market 2's LPOracle holds no code: no setter used here re-runs checkConfig.
        registry.setMarket(M2, m);
        vm.prank(address(timelock));
        store.setInitialMarketCaps(M2, 5_000_000e8, 500_000e8, 1e8);
    }

    function _key(
        bytes32 name,
        bytes32 scope
    ) internal pure returns (bytes32) {
        return keccak256(abi.encode(name, scope));
    }

    function _pair(
        address a,
        address b
    ) internal pure returns (bytes32) {
        return keccak256(abi.encode(a, b));
    }

    function _a(
        address a
    ) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(a)));
    }

    function _call(
        bytes memory data
    ) internal returns (bool ok, bytes memory ret) {
        vm.prank(address(timelock));
        (ok, ret) = address(store).call(data);
    }

    function _accepts(
        bytes memory data
    ) internal {
        (bool ok,) = _call(data);
        assertTrue(ok, "loosening refused");
    }

    function _refuses(
        bytes memory data,
        bytes memory err
    ) internal {
        (bool ok, bytes memory ret) = _call(data);
        assertFalse(ok, "loosening accepted");
        assertEq(ret, err, "wrong loosening error");
    }

    function _tooLarge(
        bytes32 key
    ) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(IParameterStoreErrors.LoosenStepTooLarge.selector, key);
    }

    function _tooSoon(
        bytes32 key,
        uint256 nextAt
    ) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(IParameterStoreErrors.LoosenTooSoon.selector, key, nextAt);
    }

    // ─── Step edges, exact integers ───

    // TEST-225 verifies: REQ-PSTORE-017, REQ-PSTORE-031
    function test_TEST_225_hardFloorStepFromTheTop() public {
        _accepts(abi.encodeCall(store.tightenHardHealthFloor, (M, 1.25e18)));
        bytes32 key = _key("hardHealthFloor", bytes32(M));
        _refuses(abi.encodeCall(store.loosenHardHealthFloor, (M, 1.22e18 - 1)), _tooLarge(key));
        _accepts(abi.encodeCall(store.loosenHardHealthFloor, (M, 1.22e18)));
        assertEq(store.hardHealthFloor(M), 1.22e18);
    }

    // TEST-225 verifies: REQ-PSTORE-017, REQ-PSTORE-031, Q-398
    function test_TEST_225_hardFloorDisableEdges() public {
        bytes32 key = _key("hardHealthFloor", bytes32(M));
        // From 1.03 + 1 wei, off counts as 1.00 and is one wei past the step.
        _accepts(abi.encodeCall(store.tightenHardHealthFloor, (M, 1.03e18 + 1)));
        _refuses(abi.encodeCall(store.loosenHardHealthFloor, (M, 0)), _tooLarge(key));
        _refuses(abi.encodeCall(store.loosenHardHealthFloor, (M, 1e18 - 1)), _tooLarge(key));
        _refuses(abi.encodeCall(store.loosenHardHealthFloor, (M, 1e18)), _tooLarge(key));
        _accepts(abi.encodeCall(store.loosenHardHealthFloor, (M, 1e18 + 1)));
        assertEq(store.hardHealthFloor(M), 1e18 + 1);
        vm.warp(block.timestamp + NORMAL_DELAY);
        // Lowering to exactly 1.00 keeps the floor on at 1.00.
        _accepts(abi.encodeCall(store.loosenHardHealthFloor, (M, 1e18)));
        assertEq(store.hardHealthFloor(M), 1e18);
        vm.warp(block.timestamp + NORMAL_DELAY);
        // From 1.00, any value below it switches the floor off, and the event carries the stored 0.
        _tl();
        vm.expectEmit(address(store));
        emit IParameterStoreEvents.ParameterLoosened("hardHealthFloor", bytes32(M), 1e18, 0, address(timelock));
        store.loosenHardHealthFloor(M, 1e18 - 1);
        assertEq(store.hardHealthFloor(M), 0);
    }

    // TEST-225 verifies: REQ-PSTORE-017, REQ-CONFIG-052
    function test_TEST_225_slippageStepFromZero() public {
        MarketParams memory p = store.getMarketParams(M);
        (p.slippageAllowanceBps, p.slippageAllowanceMinBps) = (0, 0);
        vm.prank(address(timelock));
        store.setInitialMarketParams(M, p);
        bytes32 key = _key("slippageAllowanceBps", bytes32(M));
        _refuses(abi.encodeCall(store.loosenSlippageAllowanceBps, (M, 26)), _tooLarge(key));
        _accepts(abi.encodeCall(store.loosenSlippageAllowanceBps, (M, 25)));
        assertEq(store.getMarketParams(M).slippageAllowanceBps, 25);
    }

    // TEST-225 verifies: REQ-PSTORE-017, REQ-RISK-043
    function test_TEST_225_capStepRoundsNothingUp() public {
        // From 3, 1.5 × 3 = 4.5: 4 is within one step, 5 is not.
        _accepts(abi.encodeCall(store.setInitialMarketCaps, (M, 3, 0, 1)));
        bytes32 key = _key("marketUsdCap", bytes32(M));
        _refuses(abi.encodeCall(store.loosenMarketUsdCap, (M, 5)), _tooLarge(key));
        _accepts(abi.encodeCall(store.loosenMarketUsdCap, (M, 4)));
        assertEq(store.marketUsdCap(M), 4);
        // From 2, exactly 3 is the edge.
        _accepts(abi.encodeCall(store.setInitialHubCaps, (hub2, 2)));
        bytes32 dep = _key("depositorUsdCap", _a(hub2));
        _refuses(abi.encodeCall(store.loosenDepositorUsdCap, (hub2, 4)), _tooLarge(dep));
        _accepts(abi.encodeCall(store.loosenDepositorUsdCap, (hub2, 3)));
        assertEq(store.depositorUsdCap(hub2), 3);
        _accepts(abi.encodeCall(store.setInitialTokenCap, (hub2, usdt, 7)));
        bytes32 tok = _key("tokenUsdCap", _pair(hub2, usdt));
        _refuses(abi.encodeCall(store.loosenTokenUsdCap, (hub2, usdt, 11)), _tooLarge(tok));
        _accepts(abi.encodeCall(store.loosenTokenUsdCap, (hub2, usdt, 10)));
        assertEq(store.tokenUsdCap(hub2, usdt), 10);
    }

    // TEST-225 verifies: REQ-PSTORE-017
    function test_TEST_225_sliceBaseIsTheLargerOfSliceAndTenthOfCap() public {
        bytes32 key = _key("topUpSliceUsd", bytes32(M));
        // Slice 200 above a tenth (100) of the cap 1,000: base 200, edge 300.
        _accepts(abi.encodeCall(store.setInitialMarketCaps, (M, 1000, 200, 1)));
        _refuses(abi.encodeCall(store.loosenTopUpSliceUsd, (M, 301)), _tooLarge(key));
        _accepts(abi.encodeCall(store.loosenTopUpSliceUsd, (M, 300)));
        vm.warp(block.timestamp + NORMAL_DELAY);
        // Slice 50 below a tenth: base 100, edge 150.
        _accepts(abi.encodeCall(store.setInitialMarketCaps, (M, 1000, 50, 1)));
        _refuses(abi.encodeCall(store.loosenTopUpSliceUsd, (M, 151)), _tooLarge(key));
        _accepts(abi.encodeCall(store.loosenTopUpSliceUsd, (M, 150)));
        vm.warp(block.timestamp + NORMAL_DELAY);
        // The tenth is floored: ⌊1,009 / 10⌋ = 100, edge 150.
        _accepts(abi.encodeCall(store.setInitialMarketCaps, (M, 1009, 0, 1)));
        _refuses(abi.encodeCall(store.loosenTopUpSliceUsd, (M, 151)), _tooLarge(key));
        _accepts(abi.encodeCall(store.loosenTopUpSliceUsd, (M, 150)));
        assertEq(store.topUpSliceUsd(M), 150);
    }

    // ─── Spacing ───

    // TEST-225 verifies: REQ-PSTORE-017, SPEC-GOV-011, Q-246, REQ-ACCESS-049
    function test_TEST_225_everyStepLimitedSetterIsSpaced() public {
        _accepts(abi.encodeCall(store.tightenHardHealthFloor, (M, 1.2e18)));
        uint256 t = block.timestamp;
        bytes[6] memory first = [
            abi.encodeCall(store.loosenHardHealthFloor, (M, 1.18e18)),
            abi.encodeCall(store.loosenSlippageAllowanceBps, (M, 110)),
            abi.encodeCall(store.loosenMarketUsdCap, (M, 6_000_000e8)),
            abi.encodeCall(store.loosenTopUpSliceUsd, (M, 600_000e8)),
            abi.encodeCall(store.loosenTokenUsdCap, (address(hub), usdc, 21_000_000e8)),
            abi.encodeCall(store.loosenDepositorUsdCap, (address(hub), 1_100_000e8))
        ];
        bytes[6] memory second = [
            abi.encodeCall(store.loosenHardHealthFloor, (M, 1.16e18)),
            abi.encodeCall(store.loosenSlippageAllowanceBps, (M, 120)),
            abi.encodeCall(store.loosenMarketUsdCap, (M, 7_000_000e8)),
            abi.encodeCall(store.loosenTopUpSliceUsd, (M, 700_000e8)),
            abi.encodeCall(store.loosenTokenUsdCap, (address(hub), usdc, 22_000_000e8)),
            abi.encodeCall(store.loosenDepositorUsdCap, (address(hub), 1_200_000e8))
        ];
        bytes32[6] memory keys = [
            _key("hardHealthFloor", bytes32(M)),
            _key("slippageAllowanceBps", bytes32(M)),
            _key("marketUsdCap", bytes32(M)),
            _key("topUpSliceUsd", bytes32(M)),
            _key("tokenUsdCap", _pair(address(hub), usdc)),
            _key("depositorUsdCap", _a(address(hub)))
        ];
        for (uint256 i = 0; i < first.length; ++i) {
            assertEq(store.lastLoosenedAt(keys[i]), 0);
            _accepts(first[i]);
            assertEq(store.lastLoosenedAt(keys[i]), t, "loosening not stamped");
        }
        vm.warp(t + NORMAL_DELAY - 1);
        for (uint256 i = 0; i < second.length; ++i) {
            _refuses(second[i], _tooSoon(keys[i], t + NORMAL_DELAY));
        }
        vm.warp(t + NORMAL_DELAY);
        for (uint256 i = 0; i < second.length; ++i) {
            _accepts(second[i]);
            assertEq(store.lastLoosenedAt(keys[i]), t + NORMAL_DELAY);
        }
    }

    // TEST-225 verifies: REQ-PSTORE-017, REQ-CONFIG-053, INV-090
    function test_TEST_225_spacingFollowsTheLiveNormalDelay() public {
        // The timelock's normal delay is lowered to its 4-day minimum by its own operation.
        _run(_self(abi.encodeCall(timelock.setNormalDelay, (MIN_NORMAL_DELAY))), bytes32("delay"));
        assertEq(timelock.normalDelay(), MIN_NORMAL_DELAY);
        bytes32 key = _key("marketUsdCap", bytes32(M));
        uint256 t = block.timestamp;
        _accepts(abi.encodeCall(store.loosenMarketUsdCap, (M, 6_000_000e8)));
        vm.warp(t + MIN_NORMAL_DELAY - 1);
        _refuses(abi.encodeCall(store.loosenMarketUsdCap, (M, 7_000_000e8)), _tooSoon(key, t + MIN_NORMAL_DELAY));
        vm.warp(t + MIN_NORMAL_DELAY);
        _accepts(abi.encodeCall(store.loosenMarketUsdCap, (M, 7_000_000e8)));
    }

    // TEST-225 verifies: REQ-PSTORE-017, REQ-PSTORE-026, Q-246
    function test_TEST_225_eachScopeHasItsOwnKey() public {
        _accepts(abi.encodeCall(store.loosenMarketUsdCap, (M, 6_000_000e8)));
        // Another market, another name on the same market, another Hub and another token are all unspaced.
        _accepts(abi.encodeCall(store.loosenMarketUsdCap, (M2, 6_000_000e8)));
        _accepts(abi.encodeCall(store.loosenTopUpSliceUsd, (M, 600_000e8)));
        _accepts(abi.encodeCall(store.loosenSlippageAllowanceBps, (M, 125)));
        _accepts(abi.encodeCall(store.setInitialTokenCap, (address(hub), usdt, 1_000_000e8)));
        _accepts(abi.encodeCall(store.setInitialTokenCap, (hub2, usdc, 1_000_000e8)));
        _accepts(abi.encodeCall(store.loosenTokenUsdCap, (address(hub), usdc, 21_000_000e8)));
        _accepts(abi.encodeCall(store.loosenTokenUsdCap, (address(hub), usdt, 1_500_000e8)));
        _accepts(abi.encodeCall(store.loosenTokenUsdCap, (hub2, usdc, 1_500_000e8)));
        _accepts(abi.encodeCall(store.setInitialHubCaps, (hub2, 1_000_000e8)));
        _accepts(abi.encodeCall(store.loosenDepositorUsdCap, (address(hub), 1_100_000e8)));
        _accepts(abi.encodeCall(store.loosenDepositorUsdCap, (hub2, 1_500_000e8)));
        // Each is now spaced on its own key only.
        uint256 next = block.timestamp + NORMAL_DELAY;
        _refuses(
            abi.encodeCall(store.loosenMarketUsdCap, (M2, 7_000_000e8)),
            _tooSoon(_key("marketUsdCap", bytes32(M2)), next)
        );
        _refuses(
            abi.encodeCall(store.loosenTokenUsdCap, (hub2, usdc, 2_000_000e8)),
            _tooSoon(_key("tokenUsdCap", _pair(hub2, usdc)), next)
        );
    }

    // ─── What does not touch the spacing ───

    // TEST-225 verifies: REQ-PSTORE-017, REQ-CONFIG-071
    function test_TEST_225_tighteningNeitherChecksNorStamps() public {
        bytes32 key = _key("marketUsdCap", bytes32(M));
        uint256 t = block.timestamp;
        _accepts(abi.encodeCall(store.loosenMarketUsdCap, (M, 6_000_000e8)));
        vm.warp(t + 1);
        _accepts(abi.encodeCall(store.tightenMarketUsdCap, (M, 5_500_000e8)));
        assertEq(store.lastLoosenedAt(key), t, "tightening stamped the key");
        // The spacing still runs from the loosening.
        _refuses(abi.encodeCall(store.loosenMarketUsdCap, (M, 5_600_000e8)), _tooSoon(key, t + NORMAL_DELAY));
    }

    // TEST-225 verifies: REQ-PSTORE-017, REQ-RISK-041
    function test_TEST_225_initialWritesNeitherCheckNorStamp() public {
        bytes32 key = _key("marketUsdCap", bytes32(M));
        uint256 t = block.timestamp;
        _accepts(abi.encodeCall(store.loosenMarketUsdCap, (M, 6_000_000e8)));
        vm.warp(t + 1);
        // A repeated listing write raises the cap at once, without the step or the spacing.
        _accepts(abi.encodeCall(store.setInitialMarketCaps, (M, 50_000_000e8, 500_000e8, 1e8)));
        assertEq(store.marketUsdCap(M), 50_000_000e8);
        assertEq(store.lastLoosenedAt(key), t);
        _refuses(abi.encodeCall(store.loosenMarketUsdCap, (M, 51_000_000e8)), _tooSoon(key, t + NORMAL_DELAY));
    }

    // TEST-225 verifies: REQ-PSTORE-017, REQ-PSTORE-016, REQ-PSTORE-018, REQ-PSTORE-020, REQ-PSTORE-030
    function test_TEST_225_unsteppedLooseningsRunBackToBack() public {
        vm.startPrank(address(timelock));
        store.tightenPoolShareMaxBps(5000);
        store.tightenPoolShareMaxBpsOf(M, 1000);
        store.tightenMaxShortfallBps(100);
        store.tightenDebtStressRiseBps(usdc, 3000);
        store.tightenGateRecoverySeconds(7200);
        store.tightenRouteDepthThreshold(M, usdc, gho, 0, 1_000_000e8);
        store.setDebtAssetParams(gho, DebtReserveParams(1e18));
        store.tightenFloorRoundingAllowance(gho, 1);
        // Each of these loosens twice in the same block, far beyond any step.
        store.loosenPoolShareMaxBps(6000);
        store.loosenPoolShareMaxBps(10_000);
        store.loosenPoolShareMaxBpsOf(M, 2000);
        store.loosenPoolShareMaxBpsOf(M, 10_000);
        store.loosenMinPledgeUsd(M, 5e8);
        store.loosenMinPledgeUsd(M, 0);
        store.loosenMaxShortfallBps(1000);
        store.loosenMaxShortfallBps(5000);
        store.loosenDebtStressRiseBps(usdc, 1000);
        store.loosenDebtStressRiseBps(usdc, 100);
        store.loosenGateRecoverySeconds(3600);
        store.loosenGateRecoverySeconds(600);
        store.loosenBreakerDeficitMax(address(hub), gho, 1e18);
        store.loosenBreakerDeficitMax(address(hub), gho, 100_000e18);
        store.loosenRouteDepthThreshold(M, usdc, gho, 0, 500_000e8);
        store.loosenRouteDepthThreshold(M, usdc, gho, 0, 1);
        store.loosenFloorRoundingAllowance(gho, 2);
        store.loosenFloorRoundingAllowance(gho, 1e18);
        vm.stopPrank();
        assertEq(store.poolShareMaxBps(), 10_000);
        assertEq(store.maxShortfallBps(), 5000);
        assertEq(store.gateRecoverySeconds(), 600);
        assertEq(store.breakerDeficitMax(address(hub), gho), 100_000e18);
        assertEq(store.floorRoundingAllowance(gho), 1e18);
        assertEq(store.lastLoosenedAt(_key("poolShareMaxBps", bytes32(0))), 0);
        assertEq(store.lastLoosenedAt(_key("maxShortfallBps", bytes32(0))), 0);
    }

    // ─── Check order ───

    // TEST-225 verifies: REQ-PSTORE-017, REQ-CONFIG-067
    function test_TEST_225_stepBeforeSpacing() public {
        bytes32 key = _key("slippageAllowanceBps", bytes32(M));
        _accepts(abi.encodeCall(store.loosenSlippageAllowanceBps, (M, 110)));
        // Too large and too soon: the step is reported.
        _refuses(abi.encodeCall(store.loosenSlippageAllowanceBps, (M, 200)), _tooLarge(key));
        // A refused step leaves the stamp where it was.
        assertEq(store.lastLoosenedAt(key), block.timestamp);
    }

    // TEST-225 verifies: REQ-PSTORE-017, SPEC-CAP-006, REQ-RISK-044
    function test_TEST_225_addCapBeforeSpacing() public {
        _activate();
        bytes32 key = _key("marketUsdCap", bytes32(M));
        _accepts(abi.encodeCall(store.loosenMarketUsdCap, (M, 6_000_000e8)));
        hub.setAddCap(1);
        // Too soon and addCap too small: addCap is reported, so the operation names the real blocker.
        _refuses(
            abi.encodeCall(store.loosenMarketUsdCap, (M, 7_000_000e8)),
            abi.encodeWithSelector(IParameterStoreErrors.AddCapTooSmall.selector)
        );
        hub.setAddCap(type(uint40).max);
        _refuses(
            abi.encodeCall(store.loosenMarketUsdCap, (M, 7_000_000e8)), _tooSoon(key, block.timestamp + NORMAL_DELAY)
        );
    }

    // ─── addCap edges on a live market ───

    // TEST-225 verifies: SPEC-CAP-006, REQ-RISK-044
    function test_TEST_225_addCapCeilingDivisionEdge() public {
        _activate();
        // Floor $3: (7,500,000 + 500,000) × 1e8 / 3e8 = 2,666,666.67, so 2,666,667 whole tokens are needed.
        _accepts(abi.encodeCall(store.setStressFloorUsd, (M, 2e8)));
        assertEq(store.stressFloorUsd(M), 2e8);
        registry.setStatus(M, MarketStatus.Registered);
        _accepts(abi.encodeCall(store.setInitialMarketCaps, (M, 5_000_000e8, 500_000e8, 3e8)));
        _activate();
        hub.setAddCap(2_666_666);
        _refuses(
            abi.encodeCall(store.loosenMarketUsdCap, (M, 7_500_000e8)),
            abi.encodeWithSelector(IParameterStoreErrors.AddCapTooSmall.selector)
        );
        hub.setAddCap(2_666_667);
        _accepts(abi.encodeCall(store.loosenMarketUsdCap, (M, 7_500_000e8)));
        assertEq(store.marketUsdCap(M), 7_500_000e8);
    }

    // TEST-225 verifies: SPEC-CAP-006, REQ-RISK-044, REQ-RISK-045
    function test_TEST_225_offboardingMarketKeepsTheAddCapCheck() public {
        registry.setStatus(M, MarketStatus.Offboarding);
        hub.setAddCap(5_499_999);
        _refuses(
            abi.encodeCall(store.loosenTopUpSliceUsd, (M, 500_000e8 + 1)),
            abi.encodeWithSelector(IParameterStoreErrors.AddCapTooSmall.selector)
        );
        // Cancelled and Closed markets have no Hub asset to protect.
        registry.setStatus(M, MarketStatus.Cancelled);
        _accepts(abi.encodeCall(store.loosenTopUpSliceUsd, (M, 500_000e8 + 1)));
    }

    // TEST-272 verifies: REQ-RISK-045, SPEC-CAP-006, REQ-ACCESS-050
    function test_TEST_272_stressFloorLowerAndRaiseRules() public {
        _activate();
        // (5,000,000 + 500,000) / $0.50 = 11,000,000 whole tokens for a floor of 0.5e8.
        hub.setAddCap(10_999_999);
        _refuses(
            abi.encodeCall(store.setStressFloorUsd, (M, 0.5e8)),
            abi.encodeWithSelector(IParameterStoreErrors.AddCapTooSmall.selector)
        );
        hub.setAddCap(11_000_000);
        _accepts(abi.encodeCall(store.setStressFloorUsd, (M, 0.5e8)));
        // A raise needs zero supply: one vault-token unit outstanding refuses it with the market named.
        vaultToken.setSupply(1);
        _refuses(
            abi.encodeCall(store.setStressFloorUsd, (M, 1e8)),
            abi.encodeWithSelector(IParameterStoreErrors.SupplyNotZero.selector, M)
        );
        vaultToken.setSupply(0);
        _tl();
        vm.expectEmit(address(store));
        emit IParameterStoreEvents.StressFloorSet(M, 0.5e8, 1e8);
        store.setStressFloorUsd(M, 1e8);
        // Setting the same floor again checks neither rule.
        vaultToken.setSupply(1);
        hub.setAddCap(1);
        _accepts(abi.encodeCall(store.setStressFloorUsd, (M, 1e8)));
    }

    // TEST-225 verifies: REQ-RISK-043, REQ-CONFIG-051, REQ-CONFIG-067
    function test_TEST_225_everyLoosenSetterRefusesTheCurrentValue() public {
        vm.startPrank(address(timelock));
        store.tightenHardHealthFloor(M, 1.1e18);
        store.tightenDebtStressRiseBps(usdc, 500);
        store.tightenRouteDepthThreshold(M, usdc, gho, 0, 5e8);
        store.setDebtAssetParams(gho, DebtReserveParams(1e17));
        store.loosenBreakerDeficitMax(address(hub), gho, 1e18);
        vm.stopPrank();
        bytes32 key = keccak256(abi.encode(uint32(1), address(pool), bytes32(0)));
        bytes memory notLooser = abi.encodeWithSelector(IParameterStoreErrors.NotLooser.selector);
        bytes[15] memory same = [
            abi.encodeCall(store.loosenHardHealthFloor, (M, 1.1e18)),
            abi.encodeCall(store.loosenSlippageAllowanceBps, (M, 100)),
            abi.encodeCall(store.loosenFloorRoundingAllowance, (gho, 1e17)),
            abi.encodeCall(store.loosenRouteDepthThreshold, (M, usdc, gho, 0, 5e8)),
            abi.encodeCall(store.loosenMarketUsdCap, (M, 5_000_000e8)),
            abi.encodeCall(store.loosenTopUpSliceUsd, (M, 500_000e8)),
            abi.encodeCall(store.loosenTokenUsdCap, (address(hub), usdc, 20_000_000e8)),
            abi.encodeCall(store.loosenDepositorUsdCap, (address(hub), 1_000_000e8)),
            abi.encodeCall(store.loosenPoolShareMaxBps, (10_000)),
            abi.encodeCall(store.loosenMinPledgeUsd, (M, 10e8)),
            abi.encodeCall(store.loosenPoolShareMaxBpsOf, (M, store.poolShareMaxBpsOf(key))),
            abi.encodeCall(store.loosenMaxShortfallBps, (1000)),
            abi.encodeCall(store.loosenDebtStressRiseBps, (usdc, 500)),
            abi.encodeCall(store.loosenGateRecoverySeconds, (1800)),
            abi.encodeCall(store.loosenBreakerDeficitMax, (address(hub), gho, 1e18))
        ];
        for (uint256 i = 0; i < same.length; ++i) {
            _refuses(same[i], notLooser);
        }
        // Nothing was stamped by the refusals.
        assertEq(store.lastLoosenedAt(_key("marketUsdCap", bytes32(M))), 0);
        assertEq(store.lastLoosenedAt(_key("hardHealthFloor", bytes32(M))), 0);
    }
}

