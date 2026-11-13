// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {DexPathRoute} from "../../src/liquidation/settlement-routes/DexPathRoute.sol";
import {ISettlementRoute} from "../../src/liquidation/settlement-routes/ISettlementRoute.sol";
import {DexHop, HopKind} from "../../src/liquidation/settlement-routes/types/DexHop.sol";
import {RouteConfig} from "../../src/liquidation/settlement-routes/types/RouteConfig.sol";
import {Lock} from "../../src/lock/lock/Lock.sol";
import {AvanaTest} from "../utils/AvanaTest.sol";
import {LockMember} from "../utils/mocks/LockMember.sol";
import {MockRouteCaller} from "../utils/mocks/SwapRouteMocks.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title CurveLegacyRouteForkTest
/// @notice The legacy Curve hop (2.12 `REQ-ROUTE-046`) on an Ethereum fork, against the 3pool (DAI, USDC, USDT), whose
/// `exchange` returns no data: the constructor's `coins(uint256)` checks pass at the 3pool's indices, a USDT -> USDC
/// swap delivers the measured output to LPVaultSwap with `min_dy = 0`, and wrong indices are refused. The 3pool checks
/// the hop code against a deployed legacy pool; the launch list names no legacy pool (see the skipped test below).
/// Skipped without `RPC_MAINNET`; forks the latest block. LPVaultSwap is the suites' `MockRouteCaller`.
/// @dev Run with `FOUNDRY_PROFILE=fork forge test --match-contract CurveLegacyRouteForkTest`.
contract CurveLegacyRouteForkTest is AvanaTest {
    address internal constant THREE_POOL = 0xbEbc44782C7dB0a1A60Cb6fe97d0b483032FF1C7;
    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address internal constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;

    MockRouteCaller internal swapper;
    LockMember internal adapter;
    Lock internal lock;

    function setUp() public {
        string memory rpc = vm.envOr("RPC_MAINNET", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpc);
        swapper = new MockRouteCaller();
        adapter = new LockMember();
        lock = new Lock(address(adapter), address(swapper));
        swapper.setLock(lock);
        adapter.setLock(lock);
    }

    function _config() internal view returns (RouteConfig memory c) {
        address[] memory pinned = new address[](1);
        pinned[0] = THREE_POOL;
        c = RouteConfig({
            lpVaultSwap: address(swapper),
            lock: address(lock),
            aaveAdapter: address(adapter),
            tokenIn: USDT,
            tokenOut: USDC,
            tokenClassMask: 1 << 1,
            uniswapV3Factory: address(0),
            slipstreamFactory: address(0),
            curveFactory: address(0),
            curveLegacyPools: pinned
        });
    }

    /// @dev An external call, so `vm.expectRevert` applies to it (a `new` of a source contract runs as a cheatcode).
    function deployDexPath(
        RouteConfig memory config,
        DexHop[] memory hops
    ) external returns (DexPathRoute) {
        return new DexPathRoute(config, hops);
    }

    function _hop(
        int128 i,
        int128 j
    ) internal pure returns (DexHop[] memory hops) {
        hops = new DexHop[](1);
        hops[0] = DexHop({kind: HopKind.CurveLegacy, pool: THREE_POOL, tokenOut: USDC, i: i, j: j});
    }

    /// @notice 10,000 USDT through the 3pool (USDT at index 2, USDC at 1): LPVaultSwap receives at least 9,950 USDC,
    /// measured as its balance rise although the pool returns nothing; the route keeps no balance or allowance.
    // TEST-054 verifies: REQ-ROUTE-046, REQ-ROUTE-009, REQ-ROUTE-010, REQ-ROUTE-016
    function test_TEST_054_threePoolLegacyHop() public {
        DexPathRoute route = new DexPathRoute(_config(), _hop(2, 1));
        deal(USDT, address(swapper), 10_000e6);
        uint256 before = IERC20(USDC).balanceOf(address(swapper));
        uint256 out = swapper.swapUnderLock(route, 10_000e6, 9950e6);
        assertEq(IERC20(USDC).balanceOf(address(swapper)) - before, out, "measured output");
        assertGe(out, 9950e6);
        assertEq(IERC20(USDT).balanceOf(address(route)), 0);
        assertEq(IERC20(USDC).balanceOf(address(route)), 0);
        assertEq(IERC20(USDT).allowance(address(route), THREE_POOL), 0);
    }

    /// @notice The 3pool's real `coins(uint256)` refuses wrong indices: DAI at 0 is not USDT, and index 3 does not exist.
    // TEST-054 verifies: REQ-ROUTE-046, REQ-ROUTE-045
    function test_TEST_054_threePoolWrongIndicesRefused() public {
        RouteConfig memory c = _config();
        vm.expectRevert(ISettlementRoute.InvalidRouteConfig.selector);
        this.deployDexPath(c, _hop(0, 1));
        vm.expectRevert(ISettlementRoute.InvalidRouteConfig.selector);
        this.deployDexPath(c, _hop(3, 1));
    }

    /// @notice No legacy Curve pool is named for launch: the Ethereum and Base drafts route only through StableSwap-NG
    /// pools. When the address book pins a legacy pool for a launch route, this test becomes a swap through that pool
    /// at the route's listed size, with its depth measured as `REQ-ROUTE-006` requires.
    // TEST-054 verifies: REQ-ROUTE-046
    function test_TEST_054_legacyCurveLaunchPoolNotYetNamed() public {
        vm.skip(true);
    }
}
