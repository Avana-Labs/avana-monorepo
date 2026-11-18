// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {AvanaRoles} from "../../src/governance/roles/AvanaRoles.sol";
import {IParameterStore} from "../../src/policy/parameter-store/IParameterStore.sol";
import {IParameterStoreBase} from "../../src/policy/parameter-store/IParameterStoreBase.sol";
import {MarketDynamicCap} from "../../src/policy/parameter-store/types/ParameterStoreTypes.sol";
import {ParameterStoreFixture} from "../utils/fixtures/ParameterStoreFixture.sol";
import {IAccessManaged} from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";

/// @title ParameterStoreDynamicCapUnitTest
/// @notice The dynamic borrow cap terms of a market (interval, alpha, buffer bounds): never-written values read as
/// zero, the first value written by the loosen setter, field-by-field tighten and loosen directions, the bounds, the
/// roles and the events.
contract ParameterStoreDynamicCapUnitTest is ParameterStoreFixture {
    address internal safe = makeAddr("jointConfigurationSafe");
    uint96 internal constant K = 1000;

    function setUp() public {
        _deployStore();
        _listMarket();
        vm.prank(aaveGovernanceExecutor);
        accessManager.grantRole(AvanaRoles.TIGHTEN_ROLE, safe, 0);
    }

    function _defaultCap() internal pure returns (MarketDynamicCap memory) {
        return MarketDynamicCap(21_600, 2500, 250_000e8, 2_500_000e8);
    }

    function _eq(
        MarketDynamicCap memory a,
        MarketDynamicCap memory b
    ) internal pure {
        assertEq(abi.encode(a), abi.encode(b));
    }

    function _written() internal {
        _tl();
        store.loosenMarketDynamicCap(M, _defaultCap());
    }

    function test_neverWrittenReadsZero() public view {
        _eq(store.marketDynamicCap(M), MarketDynamicCap(0, 0, 0, 0));
    }

    function test_firstValueIsALoosening() public {
        _tl();
        vm.expectRevert(IParameterStoreBase.NotStricter.selector);
        store.tightenMarketDynamicCap(M, _defaultCap());
        _tl();
        vm.expectEmit(address(store));
        emit IParameterStore.MarketDynamicCapSet(M, MarketDynamicCap(0, 0, 0, 0), _defaultCap(), false);
        store.loosenMarketDynamicCap(M, _defaultCap());
        _eq(store.marketDynamicCap(M), _defaultCap());
    }

    function test_tightenEveryFieldDirection() public {
        _written();
        MarketDynamicCap memory v = _defaultCap();
        // Each field moved one step tighter on its own passes.
        v.capInterval += 1;
        _tl();
        store.tightenMarketDynamicCap(M, v);
        v.capAlphaBps -= 1;
        _tl();
        store.tightenMarketDynamicCap(M, v);
        v.capBufferMin -= K;
        _tl();
        store.tightenMarketDynamicCap(M, v);
        v.capBufferMax -= K;
        MarketDynamicCap memory before = store.marketDynamicCap(M);
        _tl();
        vm.expectEmit(address(store));
        emit IParameterStore.MarketDynamicCapSet(M, before, v, true);
        store.tightenMarketDynamicCap(M, v);
        _eq(store.marketDynamicCap(M), v);
        // The same value is not stricter; one field looser fails even with another tighter.
        _tl();
        vm.expectRevert(IParameterStoreBase.NotStricter.selector);
        store.tightenMarketDynamicCap(M, v);
        MarketDynamicCap memory mixed = v;
        mixed.capInterval -= 1;
        mixed.capBufferMax -= K;
        _tl();
        vm.expectRevert(IParameterStoreBase.NotStricter.selector);
        store.tightenMarketDynamicCap(M, mixed);
    }

    function test_loosenEveryFieldDirection() public {
        _written();
        MarketDynamicCap memory v = _defaultCap();
        v.capInterval -= 1;
        _tl();
        store.loosenMarketDynamicCap(M, v);
        v.capAlphaBps += 1;
        _tl();
        store.loosenMarketDynamicCap(M, v);
        v.capBufferMin += K;
        _tl();
        store.loosenMarketDynamicCap(M, v);
        v.capBufferMax += K;
        MarketDynamicCap memory before = store.marketDynamicCap(M);
        _tl();
        vm.expectEmit(address(store));
        emit IParameterStore.MarketDynamicCapSet(M, before, v, false);
        store.loosenMarketDynamicCap(M, v);
        _eq(store.marketDynamicCap(M), v);
        _tl();
        vm.expectRevert(IParameterStoreBase.NotLooser.selector);
        store.loosenMarketDynamicCap(M, v);
        MarketDynamicCap memory mixed = v;
        mixed.capInterval += 1;
        mixed.capBufferMax += K;
        _tl();
        vm.expectRevert(IParameterStoreBase.NotLooser.selector);
        store.loosenMarketDynamicCap(M, mixed);
    }

    function test_boundsOnBothDirections() public {
        MarketDynamicCap memory v = _defaultCap();
        v.capInterval = 3599;
        _tl();
        vm.expectRevert(IParameterStoreBase.OutOfBounds.selector);
        store.loosenMarketDynamicCap(M, v);
        v.capInterval = 604_801;
        _tl();
        vm.expectRevert(IParameterStoreBase.OutOfBounds.selector);
        store.loosenMarketDynamicCap(M, v);
        v = _defaultCap();
        v.capAlphaBps = 10_001;
        _tl();
        vm.expectRevert(IParameterStoreBase.OutOfBounds.selector);
        store.loosenMarketDynamicCap(M, v);
        v = _defaultCap();
        v.capBufferMin = v.capBufferMax + 1;
        _tl();
        vm.expectRevert(IParameterStoreBase.OutOfBounds.selector);
        store.loosenMarketDynamicCap(M, v);
        // The edges are inside.
        v = _defaultCap();
        (v.capInterval, v.capAlphaBps) = (3600, 10_000);
        _tl();
        store.loosenMarketDynamicCap(M, v);
        v.capInterval = 604_800;
        _tl();
        store.tightenMarketDynamicCap(M, v);
        // A tightening that puts the maximum below the minimum is out of bounds, after the direction test.
        MarketDynamicCap memory w = v;
        w.capBufferMax = w.capBufferMin - 1;
        _tl();
        vm.expectRevert(IParameterStoreBase.OutOfBounds.selector);
        store.tightenMarketDynamicCap(M, w);
    }

    function test_stopByTighteningToZero() public {
        _written();
        MarketDynamicCap memory v = _defaultCap();
        (v.capAlphaBps, v.capBufferMin, v.capBufferMax) = (0, 0, 0);
        _tl();
        store.tightenMarketDynamicCap(M, v);
        _eq(store.marketDynamicCap(M), v);
    }

    function test_rolesStewardTightensOnlyTimelockLoosens() public {
        _written();
        MarketDynamicCap memory tight = _defaultCap();
        tight.capBufferMax -= K;
        vm.prank(safe);
        store.tightenMarketDynamicCap(M, tight);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, safe));
        vm.prank(safe);
        store.loosenMarketDynamicCap(M, _defaultCap());
        address stranger = makeAddr("stranger");
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, stranger));
        vm.prank(stranger);
        store.tightenMarketDynamicCap(M, tight);
    }

    function test_unknownMarketReverts() public {
        _tl();
        vm.expectRevert(abi.encodeWithSelector(IParameterStoreBase.UnknownMarket.selector, 9));
        store.loosenMarketDynamicCap(9, _defaultCap());
        _tl();
        vm.expectRevert(abi.encodeWithSelector(IParameterStoreBase.UnknownMarket.selector, 9));
        store.tightenMarketDynamicCap(9, _defaultCap());
    }

    function testFuzz_tightenIsFieldwise(
        uint32 interval,
        uint16 alpha,
        uint96 bmin,
        uint96 bmax
    ) public {
        _written();
        MarketDynamicCap memory old = _defaultCap();
        MarketDynamicCap memory v = MarketDynamicCap(interval, alpha, bmin, bmax);
        bool valid = interval >= 3600 && interval <= 604_800 && alpha <= 10_000 && bmin <= bmax;
        bool noLooser = interval >= old.capInterval && alpha <= old.capAlphaBps && bmin <= old.capBufferMin
            && bmax <= old.capBufferMax;
        bool equal = keccak256(abi.encode(v)) == keccak256(abi.encode(old));
        _tl();
        (bool ok,) = address(store).call(abi.encodeCall(IParameterStore.tightenMarketDynamicCap, (M, v)));
        assertEq(ok, valid && noLooser && !equal, "tighten passes exactly for a valid, stricter value");
        if (ok) _eq(store.marketDynamicCap(M), v);
        else _eq(store.marketDynamicCap(M), old);
    }

    function testFuzz_loosenIsFieldwise(
        uint32 interval,
        uint16 alpha,
        uint96 bmin,
        uint96 bmax
    ) public {
        _written();
        MarketDynamicCap memory old = _defaultCap();
        MarketDynamicCap memory v = MarketDynamicCap(interval, alpha, bmin, bmax);
        bool valid = interval >= 3600 && interval <= 604_800 && alpha <= 10_000 && bmin <= bmax;
        bool noTighter = interval <= old.capInterval && alpha >= old.capAlphaBps && bmin >= old.capBufferMin
            && bmax >= old.capBufferMax;
        bool equal = keccak256(abi.encode(v)) == keccak256(abi.encode(old));
        _tl();
        (bool ok,) = address(store).call(abi.encodeCall(IParameterStore.loosenMarketDynamicCap, (M, v)));
        assertEq(ok, valid && noTighter && !equal, "loosen passes exactly for a valid, looser value");
        if (ok) _eq(store.marketDynamicCap(M), v);
        else _eq(store.marketDynamicCap(M), old);
    }

    function testFuzz_anyValidFirstValueIsALoosening(
        uint32 interval,
        uint16 alpha,
        uint96 a,
        uint96 b
    ) public {
        interval = uint32(bound(interval, 3600, 604_800));
        alpha = uint16(bound(alpha, 0, 10_000));
        (uint96 lo, uint96 hi) = a <= b ? (a, b) : (b, a);
        MarketDynamicCap memory v = MarketDynamicCap(interval, alpha, lo, hi);
        _tl();
        (bool t,) = address(store).call(abi.encodeCall(IParameterStore.tightenMarketDynamicCap, (M, v)));
        assertFalse(t, "no tightening of a never-written value");
        _tl();
        store.loosenMarketDynamicCap(M, v);
        _eq(store.marketDynamicCap(M), v);
    }
}
