// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {AvanaRoles} from "../../src/governance/roles/AvanaRoles.sol";
import {IParameterStoreErrors} from "../../src/policy/parameter-store/IParameterStoreErrors.sol";
import {IParameterStoreSpeed} from "../../src/policy/parameter-store/IParameterStoreSpeed.sol";
import {MarketSpeedLimits} from "../../src/policy/parameter-store/types/MarketSpeedLimits.sol";
import {SpeedLimit} from "../../src/policy/parameter-store/types/SpeedLimit.sol";
import {ParameterStoreFixture} from "../utils/fixtures/ParameterStoreFixture.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

/// @title ParameterStoreSpeedUnitTest
/// @notice The speed-limit parameters of 2.9 (REQ-PSTORE-035, REQ-PSTORE-036): never-written values read as zero, the
/// first value written by the loosen setter, field-by-field tighten and loosen directions, the bounds, the roles and
/// the events.
contract ParameterStoreSpeedUnitTest is ParameterStoreFixture {
    address internal safe = makeAddr("jointConfigurationSafe");
    uint96 internal constant K = 1000;

    function setUp() public {
        _deployStore(false);
        _listMarket();
        vm.prank(address(timelock));
        store.grantRole(AvanaRoles.APPLICATION_RISK_STEWARD, safe);
    }

    function _launch() internal pure returns (MarketSpeedLimits memory) {
        return MarketSpeedLimits(21_600, 2500, 2500, 250_000e8, 2_500_000e8, 1_000_000e8, 10_000_000e8);
    }

    function _debt() internal pure returns (SpeedLimit memory) {
        return SpeedLimit(2500, 21_600, 500_000e18, 5_000_000e18);
    }

    function _eq(
        MarketSpeedLimits memory a,
        MarketSpeedLimits memory b
    ) internal pure {
        assertEq(abi.encode(a), abi.encode(b));
    }

    function _written() internal {
        _tl();
        store.loosenMarketSpeedLimits(M, _launch());
        _tl();
        store.loosenDebtSpeedLimit(address(hub), gho, _debt());
    }

    // TEST-325 verifies: REQ-PSTORE-035, REQ-RISK-096
    function test_TEST_325_neverWrittenReadsZero() public view {
        _eq(store.marketSpeedLimits(M), MarketSpeedLimits(0, 0, 0, 0, 0, 0, 0));
        SpeedLimit memory d = store.debtSpeedLimit(address(hub), gho);
        assertEq(abi.encode(d), abi.encode(SpeedLimit(0, 0, 0, 0)));
    }

    // TEST-325 verifies: REQ-PSTORE-036, REQ-CONFIG-049
    function test_TEST_325_firstValueIsALoosening() public {
        _tl();
        vm.expectRevert(IParameterStoreErrors.NotStricter.selector);
        store.tightenMarketSpeedLimits(M, _launch());
        _tl();
        vm.expectEmit(address(store));
        emit IParameterStoreSpeed.MarketSpeedLimitsSet(M, MarketSpeedLimits(0, 0, 0, 0, 0, 0, 0), _launch(), false);
        store.loosenMarketSpeedLimits(M, _launch());
        _eq(store.marketSpeedLimits(M), _launch());
        _tl();
        vm.expectRevert(IParameterStoreErrors.NotStricter.selector);
        store.tightenDebtSpeedLimit(address(hub), gho, _debt());
        _tl();
        vm.expectEmit(address(store));
        emit IParameterStoreSpeed.DebtSpeedLimitSet(address(hub), gho, SpeedLimit(0, 0, 0, 0), _debt(), false);
        store.loosenDebtSpeedLimit(address(hub), gho, _debt());
        assertEq(abi.encode(store.debtSpeedLimit(address(hub), gho)), abi.encode(_debt()));
    }

    // TEST-325 verifies: REQ-PSTORE-036, REQ-CONFIG-049
    function test_TEST_325_tightenEveryFieldDirection() public {
        _written();
        MarketSpeedLimits memory v = _launch();
        // Each field moved one step tighter on its own passes.
        v.window += 1;
        _tl();
        store.tightenMarketSpeedLimits(M, v);
        v.borrowRateBps -= 1;
        _tl();
        store.tightenMarketSpeedLimits(M, v);
        v.pledgeRateBps -= 1;
        _tl();
        store.tightenMarketSpeedLimits(M, v);
        v.borrowMinUsd -= K;
        _tl();
        store.tightenMarketSpeedLimits(M, v);
        v.borrowMaxUsd -= K;
        _tl();
        store.tightenMarketSpeedLimits(M, v);
        v.pledgeMinUsd -= K;
        _tl();
        store.tightenMarketSpeedLimits(M, v);
        v.pledgeMaxUsd -= K;
        MarketSpeedLimits memory before = store.marketSpeedLimits(M);
        _tl();
        vm.expectEmit(address(store));
        emit IParameterStoreSpeed.MarketSpeedLimitsSet(M, before, v, true);
        store.tightenMarketSpeedLimits(M, v);
        _eq(store.marketSpeedLimits(M), v);
        // The same value is not stricter; one field looser fails even with another tighter.
        _tl();
        vm.expectRevert(IParameterStoreErrors.NotStricter.selector);
        store.tightenMarketSpeedLimits(M, v);
        MarketSpeedLimits memory mixed = v;
        mixed.window -= 1;
        mixed.borrowMaxUsd -= K;
        _tl();
        vm.expectRevert(IParameterStoreErrors.NotStricter.selector);
        store.tightenMarketSpeedLimits(M, mixed);
    }

    // TEST-325 verifies: REQ-PSTORE-036, REQ-CONFIG-049
    function test_TEST_325_loosenEveryFieldDirection() public {
        _written();
        MarketSpeedLimits memory v = _launch();
        v.window -= 1;
        _tl();
        store.loosenMarketSpeedLimits(M, v);
        v.borrowRateBps += 1;
        v.pledgeRateBps += 1;
        v.borrowMinUsd += K;
        v.borrowMaxUsd += K;
        v.pledgeMinUsd += K;
        v.pledgeMaxUsd += K;
        _tl();
        store.loosenMarketSpeedLimits(M, v);
        _eq(store.marketSpeedLimits(M), v);
        _tl();
        vm.expectRevert(IParameterStoreErrors.NotLooser.selector);
        store.loosenMarketSpeedLimits(M, v);
        MarketSpeedLimits memory mixed = v;
        mixed.window += 10;
        mixed.borrowMaxUsd += K;
        _tl();
        vm.expectRevert(IParameterStoreErrors.NotLooser.selector);
        store.loosenMarketSpeedLimits(M, mixed);
    }

    // TEST-325 verifies: REQ-PSTORE-035, REQ-PSTORE-036
    function test_TEST_325_boundsOnBothDirections() public {
        MarketSpeedLimits memory v = _launch();
        v.window = 3599;
        _tl();
        vm.expectRevert(IParameterStoreErrors.OutOfBounds.selector);
        store.loosenMarketSpeedLimits(M, v);
        v.window = 604_801;
        _tl();
        vm.expectRevert(IParameterStoreErrors.OutOfBounds.selector);
        store.loosenMarketSpeedLimits(M, v);
        v = _launch();
        v.borrowRateBps = 10_001;
        _tl();
        vm.expectRevert(IParameterStoreErrors.OutOfBounds.selector);
        store.loosenMarketSpeedLimits(M, v);
        v = _launch();
        v.borrowMinUsd = v.borrowMaxUsd + 1;
        _tl();
        vm.expectRevert(IParameterStoreErrors.OutOfBounds.selector);
        store.loosenMarketSpeedLimits(M, v);
        v = _launch();
        v.pledgeMinUsd = v.pledgeMaxUsd + 1;
        _tl();
        vm.expectRevert(IParameterStoreErrors.OutOfBounds.selector);
        store.loosenMarketSpeedLimits(M, v);
        // The edges are inside.
        v = _launch();
        (v.window, v.borrowRateBps, v.pledgeRateBps) = (3600, 10_000, 10_000);
        _tl();
        store.loosenMarketSpeedLimits(M, v);
        v.window = 604_800;
        _tl();
        store.tightenMarketSpeedLimits(M, v);
        // A tightening below a minimum's maximum is out of bounds, after the direction test.
        MarketSpeedLimits memory w = v;
        w.borrowMaxUsd = w.borrowMinUsd - 1;
        _tl();
        vm.expectRevert(IParameterStoreErrors.OutOfBounds.selector);
        store.tightenMarketSpeedLimits(M, w);
        // Debt scope bounds.
        SpeedLimit memory d = _debt();
        d.rateBps = 10_001;
        _tl();
        vm.expectRevert(IParameterStoreErrors.OutOfBounds.selector);
        store.loosenDebtSpeedLimit(address(hub), gho, d);
        d = _debt();
        d.min = d.max + 1;
        _tl();
        vm.expectRevert(IParameterStoreErrors.OutOfBounds.selector);
        store.loosenDebtSpeedLimit(address(hub), gho, d);
        d = _debt();
        d.window = 3599;
        _tl();
        vm.expectRevert(IParameterStoreErrors.OutOfBounds.selector);
        store.loosenDebtSpeedLimit(address(hub), gho, d);
    }

    // TEST-325 verifies: REQ-PSTORE-036
    function test_TEST_325_stopByTighteningToZero() public {
        _written();
        MarketSpeedLimits memory v = _launch();
        (v.borrowRateBps, v.borrowMinUsd, v.borrowMaxUsd) = (0, 0, 0);
        _tl();
        store.tightenMarketSpeedLimits(M, v);
        _eq(store.marketSpeedLimits(M), v);
        SpeedLimit memory d = SpeedLimit(0, 21_600, 0, 0);
        _tl();
        store.tightenDebtSpeedLimit(address(hub), gho, d);
        assertEq(abi.encode(store.debtSpeedLimit(address(hub), gho)), abi.encode(d));
    }

    // TEST-325 verifies: REQ-PSTORE-036, REQ-PSTORE-002
    function test_TEST_325_rolesStewardTightensOnlyTimelockLoosens() public {
        _written();
        MarketSpeedLimits memory tight = _launch();
        tight.borrowMaxUsd -= K;
        vm.prank(safe);
        store.tightenMarketSpeedLimits(M, tight);
        SpeedLimit memory dt = _debt();
        dt.max -= K;
        vm.prank(safe);
        store.tightenDebtSpeedLimit(address(hub), gho, dt);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, safe, AvanaRoles.APPLICATION_ADMIN
            )
        );
        vm.prank(safe);
        store.loosenMarketSpeedLimits(M, _launch());
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, safe, AvanaRoles.APPLICATION_ADMIN
            )
        );
        vm.prank(safe);
        store.loosenDebtSpeedLimit(address(hub), gho, _debt());
        address stranger = makeAddr("stranger");
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, AvanaRoles.APPLICATION_ADMIN
            )
        );
        vm.prank(stranger);
        store.tightenMarketSpeedLimits(M, tight);
    }

    // TEST-325 verifies: REQ-PSTORE-036
    function test_TEST_325_unknownScopesRevert() public {
        _tl();
        vm.expectRevert(abi.encodeWithSelector(IParameterStoreErrors.UnknownMarket.selector, 9));
        store.loosenMarketSpeedLimits(9, _launch());
        _tl();
        vm.expectRevert(abi.encodeWithSelector(IParameterStoreErrors.UnknownMarket.selector, 9));
        store.tightenMarketSpeedLimits(9, _launch());
        address noHub = makeAddr("noHub");
        _tl();
        vm.expectRevert(abi.encodeWithSelector(IParameterStoreErrors.UnknownHub.selector, noHub));
        store.loosenDebtSpeedLimit(noHub, gho, _debt());
        _tl();
        vm.expectRevert(abi.encodeWithSelector(IParameterStoreErrors.UnknownHub.selector, noHub));
        store.tightenDebtSpeedLimit(noHub, gho, _debt());
        address noAsset = makeAddr("noAsset");
        _tl();
        vm.expectRevert(abi.encodeWithSelector(IParameterStoreErrors.UnknownDebtReserve.selector, address(0), 0));
        store.loosenDebtSpeedLimit(address(hub), noAsset, _debt());
    }

    // TEST-325 verifies: REQ-PSTORE-036, REQ-CONFIG-049
    function testFuzz_TEST_325_directionIsFieldwise(
        uint32 window,
        uint16 br,
        uint16 pr,
        uint96 bmin,
        uint96 bmax,
        uint96 pmin,
        uint96 pmax
    ) public {
        _written();
        MarketSpeedLimits memory old = _launch();
        MarketSpeedLimits memory v = MarketSpeedLimits(window, br, pr, bmin, bmax, pmin, pmax);
        bool valid = window >= 3600 && window <= 604_800 && br <= 10_000 && pr <= 10_000 && bmin <= bmax && pmin <= pmax;
        bool noLooser = window >= old.window && br <= old.borrowRateBps && pr <= old.pledgeRateBps
            && bmin <= old.borrowMinUsd && bmax <= old.borrowMaxUsd && pmin <= old.pledgeMinUsd
            && pmax <= old.pledgeMaxUsd;
        bool equal = keccak256(abi.encode(v)) == keccak256(abi.encode(old));
        _tl();
        (bool ok,) = address(store).call(abi.encodeCall(IParameterStoreSpeed.tightenMarketSpeedLimits, (M, v)));
        assertEq(ok, valid && noLooser && !equal, "tighten passes exactly for a valid, stricter value");
        if (ok) _eq(store.marketSpeedLimits(M), v);
        else _eq(store.marketSpeedLimits(M), old);
    }

    // TEST-325 verifies: REQ-PSTORE-036, REQ-CONFIG-049
    function test_TEST_325_debtTightenEveryFieldDirection() public {
        _written();
        SpeedLimit memory v = _debt();
        v.window += 1;
        _tl();
        store.tightenDebtSpeedLimit(address(hub), gho, v);
        v.rateBps -= 1;
        _tl();
        store.tightenDebtSpeedLimit(address(hub), gho, v);
        v.min -= K;
        _tl();
        store.tightenDebtSpeedLimit(address(hub), gho, v);
        SpeedLimit memory before = store.debtSpeedLimit(address(hub), gho);
        v.max -= K;
        _tl();
        vm.expectEmit(address(store));
        emit IParameterStoreSpeed.DebtSpeedLimitSet(address(hub), gho, before, v, true);
        store.tightenDebtSpeedLimit(address(hub), gho, v);
        assertEq(abi.encode(store.debtSpeedLimit(address(hub), gho)), abi.encode(v));
        _tl();
        vm.expectRevert(IParameterStoreErrors.NotStricter.selector);
        store.tightenDebtSpeedLimit(address(hub), gho, v);
        SpeedLimit memory mixed = v;
        mixed.window -= 1;
        mixed.max -= K;
        _tl();
        vm.expectRevert(IParameterStoreErrors.NotStricter.selector);
        store.tightenDebtSpeedLimit(address(hub), gho, mixed);
    }

    // TEST-325 verifies: REQ-PSTORE-036, REQ-CONFIG-049
    function test_TEST_325_debtLoosenEveryFieldDirection() public {
        _written();
        SpeedLimit memory v = _debt();
        v.window -= 1;
        _tl();
        store.loosenDebtSpeedLimit(address(hub), gho, v);
        v.rateBps += 1;
        _tl();
        store.loosenDebtSpeedLimit(address(hub), gho, v);
        v.min += K;
        _tl();
        store.loosenDebtSpeedLimit(address(hub), gho, v);
        SpeedLimit memory before = store.debtSpeedLimit(address(hub), gho);
        v.max += K;
        _tl();
        vm.expectEmit(address(store));
        emit IParameterStoreSpeed.DebtSpeedLimitSet(address(hub), gho, before, v, false);
        store.loosenDebtSpeedLimit(address(hub), gho, v);
        assertEq(abi.encode(store.debtSpeedLimit(address(hub), gho)), abi.encode(v));
        _tl();
        vm.expectRevert(IParameterStoreErrors.NotLooser.selector);
        store.loosenDebtSpeedLimit(address(hub), gho, v);
        SpeedLimit memory mixed = v;
        mixed.window += 1;
        mixed.max += K;
        _tl();
        vm.expectRevert(IParameterStoreErrors.NotLooser.selector);
        store.loosenDebtSpeedLimit(address(hub), gho, mixed);
    }

    // TEST-325 verifies: REQ-PSTORE-036, REQ-CONFIG-049
    function test_TEST_325_largeBorrowPathIsALooseningThenATightening() public {
        _written();
        MarketSpeedLimits memory raised = _launch();
        raised.borrowMaxUsd = 20_000_000e8;
        _tl();
        store.loosenMarketSpeedLimits(M, raised);
        assertEq(store.marketSpeedLimits(M).borrowMaxUsd, 20_000_000e8);
        // The steward brings it back at once; no spacing or step limit applies either way.
        vm.prank(safe);
        store.tightenMarketSpeedLimits(M, _launch());
        _eq(store.marketSpeedLimits(M), _launch());
        _tl();
        store.loosenMarketSpeedLimits(M, raised);
        assertEq(store.marketSpeedLimits(M).borrowMaxUsd, 20_000_000e8, "a second raise right away");
    }

    // TEST-325 verifies: REQ-PSTORE-035
    function test_TEST_325_scopesAreIndependent() public {
        _written();
        address other = makeAddr("otherAsset");
        assertEq(abi.encode(store.debtSpeedLimit(address(hub), other)), abi.encode(SpeedLimit(0, 0, 0, 0)));
        assertEq(abi.encode(store.debtSpeedLimit(makeAddr("otherHub"), gho)), abi.encode(SpeedLimit(0, 0, 0, 0)));
        _eq(store.marketSpeedLimits(M + 1), MarketSpeedLimits(0, 0, 0, 0, 0, 0, 0));
        MarketSpeedLimits memory v = _launch();
        v.pledgeMaxUsd -= K;
        _tl();
        store.tightenMarketSpeedLimits(M, v);
        assertEq(abi.encode(store.debtSpeedLimit(address(hub), gho)), abi.encode(_debt()), "debt scope untouched");
    }

    // TEST-325 verifies: REQ-PSTORE-036, REQ-CONFIG-049
    function testFuzz_TEST_325_debtDirectionIsFieldwise(
        uint16 rate,
        uint32 window,
        uint96 lo,
        uint96 hi,
        bool loosen
    ) public {
        _written();
        SpeedLimit memory old = _debt();
        SpeedLimit memory v = SpeedLimit(rate, window, lo, hi);
        bool valid = window >= 3600 && window <= 604_800 && rate <= 10_000 && lo <= hi;
        bool equal = keccak256(abi.encode(v)) == keccak256(abi.encode(old));
        bool noLooser = window >= old.window && rate <= old.rateBps && lo <= old.min && hi <= old.max;
        bool noTighter = window <= old.window && rate >= old.rateBps && lo >= old.min && hi >= old.max;
        _tl();
        bool ok;
        if (loosen) {
            (ok,) =
                address(store).call(abi.encodeCall(IParameterStoreSpeed.loosenDebtSpeedLimit, (address(hub), gho, v)));
            assertEq(ok, valid && noTighter && !equal, "loosen passes exactly for a valid, looser value");
        } else {
            (ok,) =
                address(store).call(abi.encodeCall(IParameterStoreSpeed.tightenDebtSpeedLimit, (address(hub), gho, v)));
            assertEq(ok, valid && noLooser && !equal, "tighten passes exactly for a valid, stricter value");
        }
        assertEq(abi.encode(store.debtSpeedLimit(address(hub), gho)), abi.encode(ok ? v : old));
    }

    // TEST-325 verifies: REQ-PSTORE-036, REQ-CONFIG-049
    function testFuzz_TEST_325_marketLoosenIsFieldwise(
        uint32 window,
        uint16 br,
        uint16 pr,
        uint96 bmin,
        uint96 bmax,
        uint96 pmin,
        uint96 pmax
    ) public {
        _written();
        MarketSpeedLimits memory old = _launch();
        MarketSpeedLimits memory v = MarketSpeedLimits(window, br, pr, bmin, bmax, pmin, pmax);
        bool valid = window >= 3600 && window <= 604_800 && br <= 10_000 && pr <= 10_000 && bmin <= bmax && pmin <= pmax;
        bool noTighter = window <= old.window && br >= old.borrowRateBps && pr >= old.pledgeRateBps
            && bmin >= old.borrowMinUsd && bmax >= old.borrowMaxUsd && pmin >= old.pledgeMinUsd
            && pmax >= old.pledgeMaxUsd;
        bool equal = keccak256(abi.encode(v)) == keccak256(abi.encode(old));
        _tl();
        (bool ok,) = address(store).call(abi.encodeCall(IParameterStoreSpeed.loosenMarketSpeedLimits, (M, v)));
        assertEq(ok, valid && noTighter && !equal, "loosen passes exactly for a valid, looser value");
        if (ok) _eq(store.marketSpeedLimits(M), v);
        else _eq(store.marketSpeedLimits(M), old);
    }

    // TEST-325 verifies: REQ-PSTORE-036, REQ-RISK-096
    function testFuzz_TEST_325_anyValidFirstValueIsALoosening(
        uint32 window,
        uint16 br,
        uint16 pr,
        uint96 a,
        uint96 b
    ) public {
        window = uint32(bound(window, 3600, 604_800));
        br = uint16(bound(br, 0, 10_000));
        pr = uint16(bound(pr, 0, 10_000));
        (uint96 lo, uint96 hi) = a <= b ? (a, b) : (b, a);
        MarketSpeedLimits memory v = MarketSpeedLimits(window, br, pr, lo, hi, lo, hi);
        _tl();
        (bool t,) = address(store).call(abi.encodeCall(IParameterStoreSpeed.tightenMarketSpeedLimits, (M, v)));
        assertFalse(t, "no tightening of a never-written scope");
        _tl();
        store.loosenMarketSpeedLimits(M, v);
        _eq(store.marketSpeedLimits(M), v);
    }
}
