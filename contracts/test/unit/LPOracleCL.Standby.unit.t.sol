// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {AvanaRoles} from "../../src/governance/roles/AvanaRoles.sol";
import {ILPOracleErrors} from "../../src/oracle/lp-oracle/ILPOracleErrors.sol";
import {ILPOracleEvents} from "../../src/oracle/lp-oracle/ILPOracleEvents.sol";
import {LPOracleCL} from "../../src/oracle/lp-oracle/LPOracleCL.sol";
import {PriceState} from "../../src/types/PriceState.sol";
import {PriceStateView} from "../../src/types/PriceStateView.sol";
import {RouteSlot} from "../../src/types/RouteSlot.sol";
import {LPOracleCLDeployer, LPOracleCLFixture} from "../utils/fixtures/LPOracleCLFixture.sol";
import {OracleFeedMock, ReadMode} from "../utils/mocks/LPOracleMocks.sol";

/// @title LPOracleCLStandbyTest
/// @notice The real concentrated-liquidity LPOracle on a real Uniswap v3 pool under the guardian's standby route switch
/// (the disagreement window restarts, the failure timer never does), the admin-role grant rule, and an upgrade through
/// the timelock while seizure runs at the oracle's price.
contract LPOracleCLStandbyTest is LPOracleCLFixture {
    uint256 internal constant ONE = 1e8;
    uint256 internal constant T1 = T0 + 60;
    uint256 internal constant LOW = 97_500_000;
    uint256 internal constant STANDBY_BIT = 13;

    function _stable() internal {
        _deployClMarket(_usdcUsdt());
        vm.warp(T1);
        vm.roll(block.number + 1);
        _setPrices(ONE, ONE);
    }

    function _next(
        uint256 at
    ) internal {
        vm.warp(at);
        vm.roll(block.number + 1);
    }

    // ─── TEST-231: standby switch ───

    // TEST-231 verifies: REQ-ORACLE-094, REQ-ORACLE-095, REQ-ORACLE-084, ATTACK-140, Q-248
    // Sources: 5.1 TEST-231 (LPOracle part: on the next poke the switch restarts the stored disagreement start)
    /// @notice Token1's alternate disagrees from `T1` and the first poke stores `T1`. At `T1 + 1,000` the guardian
    /// switches token1's alternate slot to a standby that also disagrees and the MarketRegistry bumps its route
    /// version: a view at once reports the standby in force and measures the window from now; the poke that observes
    /// the version emits `PriceRouteVersionObserved(1, 0, 1)` and restarts the stored start at `T1 + 1,000`. A
    /// standby that agrees makes the market Live in the same block.
    function test_TEST_231_standbySwitchRestartsTheDisagreementStart() public {
        _stable();
        a1Feed.push(int256(LOW), T1);
        oracle.poke();
        assertEq(_state().disagreeSince, T1);
        _next(T1 + 1000);
        p0Feed.push(int256(ONE), T1 + 1000);
        p1Feed.push(int256(ONE), T1 + 1000);
        OracleFeedMock standby = _feed("standby", 97_000_000);
        registry.setRoutes(address(token1), _one(address(p1Feed)), _one(address(standby)), RouteSlot.Alternate);
        registry.bumpVersion(address(token1));
        PriceStateView memory v = _state();
        assertEq(v.disagreeSince, 0, "a view after a version change measures from now");
        assertTrue(_has(v.reasons, STANDBY_BIT), "ANY_TOKEN_ON_STANDBY");
        assertEq(uint8(v.tokens[1].replaced), uint8(RouteSlot.Alternate), "the standby is in force at once");
        assertEq(v.tokens[1].routeVersion, 1);
        vm.expectEmit(address(oracle));
        emit ILPOracleEvents.PriceRouteVersionObserved(1, 0, 1);
        oracle.poke();
        assertEq(_state().disagreeSince, T1 + 1000, "restarted at the observing poke");
        standby.push(int256(ONE), T1 + 1000);
        v = _state();
        assertEq(uint8(v.state), uint8(PriceState.Live), "an agreeing standby: Live at once");
        assertFalse(v.liquidationPaused);
    }

    // TEST-231 verifies: REQ-ORACLE-095, SPEC-ORC-013, Q-248
    /// @notice Token1's routes fail at `T1` and a poke records the failure; a switch to a standby that also fails never
    /// resets the failure start, so the market is Expired on the original schedule (`T1 + cachedWindow`). A switch
    /// never forces Live: the market is Live again only once a route of token1 reads.
    function test_TEST_231_switchNeverDelaysCachedOrExpired() public {
        _stable();
        p1Feed.setMode(p1Feed.latestRoundData.selector, ReadMode.Revert);
        a1Feed.setMode(a1Feed.latestRoundData.selector, ReadMode.Revert);
        oracle.poke();
        uint64 failureStart = _state().failureStart;
        assertEq(uint8(_state().state), uint8(PriceState.Cached));
        assertGt(failureStart, 0);
        OracleFeedMock standby = _feed("standby", ONE);
        standby.setMode(standby.latestRoundData.selector, ReadMode.Revert);
        registry.setRoutes(address(token1), _one(address(standby)), _one(address(a1Feed)), RouteSlot.Primary);
        registry.bumpVersion(address(token1));
        _next(T1 + 2000);
        oracle.poke();
        PriceStateView memory v = _state();
        assertEq(v.failureStart, failureStart, "a version change never resets the failure start");
        assertEq(uint8(v.state), uint8(PriceState.Cached), "the switch never forces Live");
        vm.warp(uint256(failureStart) + 3600);
        assertEq(uint8(_state().state), uint8(PriceState.Expired), "Expired on the original schedule");
        standby.setMode(standby.latestRoundData.selector, ReadMode.Normal);
        standby.push(int256(ONE), block.timestamp);
        a1Feed.setMode(a1Feed.latestRoundData.selector, ReadMode.Normal);
        a1Feed.push(int256(ONE), block.timestamp);
        _setPrices(ONE, ONE);
        assertTrue(uint8(_state().state) != uint8(PriceState.Expired), "a reading route ends the outage");
    }

    // ─── TEST-242: admin roles only for the timelock ───

    // TEST-242 verifies: REQ-ORACLE-097, REQ-ACCESS-153, Q-259
    // Sources: 5.1 TEST-242 (LPOracle part)
    /// @notice On the LPOracle proxy the timelock holds `DEFAULT_ADMIN_ROLE` and `APPLICATION_ADMIN`; granting either to
    /// any other account reverts `AdminRoleOnlyTimelock(role, a)`, including when the timelock itself executes the
    /// grant, and an outsider's grant is refused too. Re-granting the timelock is allowed and changes nothing.
    function test_TEST_242_adminRolesOnlyForTheTimelock() public {
        _stable();
        bytes32 admin = AvanaRoles.APPLICATION_ADMIN;
        bytes32 root = oracle.DEFAULT_ADMIN_ROLE();
        assertTrue(oracle.hasRole(root, tl));
        assertTrue(oracle.hasRole(admin, tl));
        address[3] memory others = [alice, address(oracle), address(store)];
        for (uint256 i = 0; i < others.length; ++i) {
            vm.prank(tl);
            vm.expectRevert(abi.encodeWithSelector(ILPOracleErrors.AdminRoleOnlyTimelock.selector, admin, others[i]));
            oracle.grantRole(admin, others[i]);
            vm.prank(tl);
            vm.expectRevert(abi.encodeWithSelector(ILPOracleErrors.AdminRoleOnlyTimelock.selector, root, others[i]));
            oracle.grantRole(root, others[i]);
        }
        vm.prank(alice);
        vm.expectRevert();
        oracle.grantRole(admin, alice);
        assertFalse(oracle.hasRole(admin, alice));
        assertFalse(oracle.hasRole(root, alice));
        vm.prank(tl);
        oracle.grantRole(admin, tl);
        assertTrue(oracle.hasRole(admin, tl));
    }

    // ─── TEST-284: upgrade while liquidation runs ───

    // TEST-284 verifies: REQ-ORACLE-101, INV-099, Q-327
    // Sources: 5.1 TEST-284 (LPOracle part: an LPOracle upgrade through the timelock keeps the proxy address and every
    // view LPVaultSwap reads, and seizure keeps running at the LPOracle's price)
    /// @notice A Live market whose seizure is open is upgraded through the timelock to a new implementation: the proxy
    /// address, the served price, `liquidationPaused`, `liquidationPriceMaxAge`, the valuation prices of
    /// `getTokenPrices()` and the accepted price LPVaultSwap reads are the same before and after, in the same block, so
    /// a liquidation priced from the LPOracle is unaffected. Only the timelock can upgrade.
    function test_TEST_284_upgradeKeepsTheViewsLiquidationReads() public {
        _stable();
        oracle.poke();
        address before = address(oracle);
        PriceStateView memory v0 = _state();
        assertFalse(v0.liquidationPaused, "seizure open");
        (uint256[] memory prices0, uint64 at0, PriceState s0) = oracle.getTokenPrices();
        (uint256 acc0, uint64 accAt0) = oracle.lastAcceptedPrice();
        uint32 liqAge0 = oracle.liquidationPriceMaxAge();
        LPOracleCL next = LPOracleCLDeployer.deploy(tl, BLOCK_TIME, POKE_FLOOR, POKE_CEILING, false, 7);
        vm.prank(alice);
        vm.expectRevert();
        oracle.upgradeToAndCall(address(next), "");
        vm.prank(tl);
        oracle.upgradeToAndCall(address(next), "");
        assertEq(address(oracle), before, "same proxy address: the vault token's lpOracle() and the Aave source");
        PriceStateView memory v1 = _state();
        (uint256[] memory prices1, uint64 at1, PriceState s1) = oracle.getTokenPrices();
        (uint256 acc1, uint64 accAt1) = oracle.lastAcceptedPrice();
        assertEq(v1.answer, v0.answer, "served price");
        assertEq(oracle.latestAnswer(), v0.answer, "latestAnswer");
        assertEq(v1.liquidationPaused, v0.liquidationPaused, "liquidationPaused");
        assertEq(uint8(v1.state), uint8(v0.state), "state");
        assertEq(oracle.liquidationPriceMaxAge(), liqAge0, "liquidation age");
        assertEq(abi.encode(prices1, at1, s1), abi.encode(prices0, at0, s0), "getTokenPrices");
        assertEq(abi.encode(acc1, accAt1), abi.encode(acc0, accAt0), "accepted price");
        assertEq(uint8(oracle.poke()), uint8(PriceState.Live), "poke() still runs");
    }
}
