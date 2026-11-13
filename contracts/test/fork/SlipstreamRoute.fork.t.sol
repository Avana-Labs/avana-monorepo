// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {DexPathRoute} from "../../src/liquidation/settlement-routes/DexPathRoute.sol";
import {ISettlementRoute} from "../../src/liquidation/settlement-routes/ISettlementRoute.sol";
import {DexHop, HopKind} from "../../src/liquidation/settlement-routes/types/DexHop.sol";
import {RouteConfig} from "../../src/liquidation/settlement-routes/types/RouteConfig.sol";
import {Lock} from "../../src/lock/lock/Lock.sol";
import {AvanaTest} from "../utils/AvanaTest.sol";
import {ForkConstants} from "../utils/fixtures/ForkConstants.sol";
import {LockMember} from "../utils/mocks/LockMember.sol";
import {MockRouteCaller} from "../utils/mocks/SwapRouteMocks.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IForkBaseFeed {
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}

/// @title SlipstreamRouteForkTest
/// @notice `TEST-120` on the Base fork: a `DexPath` swap route through a real Aerodrome Slipstream pool, the external the
/// unit tests replace with `SwapRouteMocks`' `MockCLPool` and `MockPoolFactory`. The route accepts the WETH/USDC pool
/// (spacing 100) only with the factory that deployed it (`getPool(token0, token1, tickSpacing)`) and refuses it under
/// another generation's factory; it is a volatile-class route (WETH has a route of its own class, not a stable one);
/// 10 WETH swapped through it pays LPVaultSwap at least 97 % of the Chainlink ETH/USD value in USDC, measured as
/// LPVaultSwap's balance rise, and the route keeps no balance or allowance. Forks at the pinned Base block when one is
/// set, else at the latest block; skipped without `RPC_BASE`. LPVaultSwap is the suites' `MockRouteCaller`.
/// @dev Run with `FOUNDRY_PROFILE=fork forge test --match-contract SlipstreamRouteForkTest`.
contract SlipstreamRouteForkTest is AvanaTest {
    address internal constant WETH = 0x4200000000000000000000000000000000000006;
    address internal constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    /// @dev Slipstream generation 0 (Initial): its WETH/USDC spacing-100 pool and factory; the Aero factory for the refusal.
    address internal constant POOL = 0xb2cc224c1c9feE385f8ad6a55b4d94E92359DC59;
    address internal constant FACTORY = 0x5e7BB104d84c7CB9B682AaC2F3d509f5F406809A;
    address internal constant OTHER_FACTORY = 0x9CB220581b91b0C83223012FE69688b92aD07a76;
    address internal constant ETH_USD = 0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70;
    uint8 internal constant STABLE = 1;
    uint8 internal constant VOLATILE = 3;

    MockRouteCaller internal swapper;
    LockMember internal adapter;
    Lock internal lock;

    function setUp() public {
        string memory rpc = vm.envOr("RPC_BASE", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        uint256 pin = ForkConstants.baseForkBlock();
        if (pin == 0) vm.createSelectFork(rpc);
        else vm.createSelectFork(rpc, pin);
        swapper = new MockRouteCaller();
        adapter = new LockMember();
        lock = new Lock(address(adapter), address(swapper));
        swapper.setLock(lock);
        adapter.setLock(lock);
    }

    // TEST-120 verifies: Q-062, Q-187
    function test_TEST_120_wethToUsdcThroughASlipstreamPool() public {
        DexPathRoute route = new DexPathRoute(_config(FACTORY), _hop());
        assertTrue(route.supportsTokenClass(VOLATILE), "a volatile-class route");
        assertFalse(route.supportsTokenClass(STABLE), "not a stable-class route");

        (, int256 ethUsd,,,) = IForkBaseFeed(ETH_USD).latestRoundData();
        assertGt(ethUsd, 0);
        uint256 amount = 10e18;
        // 10 WETH at the 8-decimal ETH/USD answer, in 6-decimal USDC: 10 × answer / 100.
        uint256 fair = 10 * uint256(ethUsd) / 100;
        uint256 minOut = fair * 97 / 100;
        deal(WETH, address(swapper), amount);
        uint256 before = IERC20(USDC).balanceOf(address(swapper));
        uint256 out = swapper.swapUnderLock(route, amount, minOut);
        assertEq(IERC20(USDC).balanceOf(address(swapper)) - before, out, "measured output");
        assertGe(out, minOut, "at least 97 % of the Chainlink value");
        assertEq(IERC20(WETH).balanceOf(address(route)), 0);
        assertEq(IERC20(USDC).balanceOf(address(route)), 0);
        assertEq(IERC20(WETH).allowance(address(route), POOL), 0);
    }

    // TEST-120 verifies: Q-187
    function test_TEST_120_poolRefusedUnderAnotherGenerationsFactory() public {
        vm.expectRevert(ISettlementRoute.InvalidRouteConfig.selector);
        this.deployDexPath(_config(OTHER_FACTORY), _hop());
    }

    /// @dev An external call, so `vm.expectRevert` applies to the constructor.
    function deployDexPath(
        RouteConfig memory config,
        DexHop[] memory hops
    ) external returns (DexPathRoute) {
        return new DexPathRoute(config, hops);
    }

    function _config(
        address slipstreamFactory
    ) internal view returns (RouteConfig memory c) {
        c = RouteConfig({
            lpVaultSwap: address(swapper),
            lock: address(lock),
            aaveAdapter: address(adapter),
            tokenIn: WETH,
            tokenOut: USDC,
            tokenClassMask: uint8(1 << VOLATILE),
            uniswapV3Factory: address(0),
            slipstreamFactory: slipstreamFactory,
            curveFactory: address(0),
            curveLegacyPools: new address[](0)
        });
    }

    function _hop() internal pure returns (DexHop[] memory hops) {
        hops = new DexHop[](1);
        hops[0] = DexHop({kind: HopKind.ConcentratedLiquidity, pool: POOL, tokenOut: USDC, i: 0, j: 0});
    }
}
