// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {UniswapV3Integration} from "../../src/amm/uniswap-v3/UniswapV3Integration.sol";
import {INonfungiblePositionManager} from "../../src/interfaces/external/uniswap/INonfungiblePositionManager.sol";
import {IUniswapV3Pool} from "../../src/interfaces/external/uniswap/IUniswapV3Pool.sol";
import {IUniswapV3SwapCallback} from "../../src/interfaces/external/uniswap/IUniswapV3SwapCallback.sol";
import {ILens} from "../../src/lens/lens/ILens.sol";
import {PositionFeesView} from "../../src/lens/lens/types/PositionFeesView.sol";
import {Lock} from "../../src/lock/lock/Lock.sol";
import {PositionShape} from "../../src/types/PositionShape.sol";
import {ShapeKind} from "../../src/types/ShapeKind.sol";
import {AvanaTest} from "../utils/AvanaTest.sol";
import {ForkConstants} from "../utils/fixtures/ForkConstants.sol";
import {LensFeesDeploy} from "../utils/fixtures/LensFeesFixture.sol";
import {LensRegistryMock} from "../utils/mocks/LensMocks.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Swaps through a Uniswap v3 pool and pays it from its own balance in the callback.
contract LensForkSwapper is IUniswapV3SwapCallback {
    function swap(
        address pool,
        bool zeroForOne,
        int256 amount
    ) external {
        uint160 limit = zeroForOne ? 4_295_128_740 : 1_461_446_703_485_210_103_287_273_052_203_988_822_378_723_970_341;
        IUniswapV3Pool(pool).swap(address(this), zeroForOne, amount, limit, abi.encode(pool));
    }

    function uniswapV3SwapCallback(
        int256 amount0Delta,
        int256 amount1Delta,
        bytes calldata data
    ) external {
        address pool = abi.decode(data, (address));
        require(msg.sender == pool, "pool");
        // forge-lint: disable-next-line(unsafe-typecast)
        if (amount0Delta > 0) IERC20(IUniswapV3Pool(pool).token0()).transfer(pool, uint256(amount0Delta));
        // forge-lint: disable-next-line(unsafe-typecast)
        if (amount1Delta > 0) IERC20(IUniswapV3Pool(pool).token1()).transfer(pool, uint256(amount1Delta));
    }
}

/// @title LensFeesForkTest
/// @notice `getPositionFees` on an Ethereum fork against the canonical Uniswap v3 NFPM and the USDC/USDT 0.01 % pool:
/// a full-range position takes fees from real swaps in both directions, and the Lens's amounts equal what the
/// production LPVault's `collectFees` pays its depositor in the same block, before and after an earlier collect.
/// Skipped without `RPC_MAINNET` or a pinned block.
/// @dev Run with `FOUNDRY_PROFILE=fork forge test --match-contract LensFeesForkTest`.
/// forge-config: default.isolate = false
contract LensFeesForkTest is AvanaTest {
    address internal constant NFPM = 0xC36442b4a4522E871399CD717aBDD847Ab11FE88;
    address internal constant FACTORY = 0x1F98431c8aD98523631AE4a59f267346ea31F984;
    address internal constant POOL = 0x3416cF6C708Da44DB2624D63ea0AAef7113527C6;
    int24 internal constant FULL = 887_272;

    address internal adapter = makeAddr("aaveAdapter");
    address internal coll = makeAddr("collateralization");
    address internal registry = makeAddr("marketRegistry");
    Lock internal lock;
    UniswapV3Integration internal vault;
    ILens internal lens;
    LensForkSwapper internal swapper;
    address internal token0;
    address internal token1;

    function setUp() public {
        string memory rpc = vm.envOr("RPC_MAINNET", string(""));
        uint256 blockNumber = ForkConstants.mainnetForkBlock();
        if (bytes(rpc).length == 0 || blockNumber == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpc, blockNumber);
        lock = new Lock(adapter, makeAddr("lpVaultSwap"));
        vault = new UniswapV3Integration(1, coll, registry, address(lock), makeAddr("timelock"), NFPM, FACTORY, 12);
        vm.prank(registry);
        vault.bindMarket(1, POOL, bytes32(0), PositionShape(ShapeKind.TickRange, -FULL, FULL), abi.encode(1e8, 1e8));
        (token0, token1) = (IUniswapV3Pool(POOL).token0(), IUniswapV3Pool(POOL).token1());
        LensRegistryMock reg = new LensRegistryMock();
        reg.setMarket(1, LensFeesDeploy.market(address(vault), 1, POOL, token0, token1, -FULL, FULL));
        LensFeesDeploy.etchStandIns(adapter, coll);
        lens = LensFeesDeploy.deploy(
            [coll, makeAddr("pm"), adapter, address(lock), address(reg), registry, registry, makeAddr("swap"), coll]
        );
        swapper = new LensForkSwapper();
        deal(token0, address(swapper), 50_000_000e6);
        deal(token1, address(swapper), 50_000_000e6);
    }

    function _mintAndPledge() internal returns (bytes32 key) {
        deal(token0, alice, 100_000e6);
        deal(token1, alice, 100_000e6);
        vm.startPrank(alice);
        IERC20(token0).approve(NFPM, type(uint256).max);
        IERC20(token1).approve(NFPM, type(uint256).max);
        (uint256 id,,,) = INonfungiblePositionManager(NFPM)
            .mint(
                INonfungiblePositionManager.MintParams(
                    token0, token1, 100, -FULL, FULL, 100_000e6, 100_000e6, 0, 0, alice, block.timestamp
                )
            );
        INonfungiblePositionManager(NFPM).approve(address(vault), id);
        vm.stopPrank();
        key = bytes32(id);
        _asColl(abi.encodeCall(vault.receivePosition, (1, alice, key)));
    }

    function _asColl(
        bytes memory data
    ) internal returns (bytes memory out) {
        vm.prank(adapter);
        lock.acquire();
        vm.prank(coll);
        bool ok;
        (ok, out) = address(vault).call(data);
        require(ok, "Collateralization call");
        vm.prank(adapter);
        lock.release();
    }

    function _collect(
        bytes32 key
    ) internal returns (uint256 a0, uint256 a1) {
        uint256 b0 = IERC20(token0).balanceOf(alice);
        uint256 b1 = IERC20(token1).balanceOf(alice);
        _asColl(abi.encodeCall(vault.collectFees, (key, alice)));
        (a0, a1) = (IERC20(token0).balanceOf(alice) - b0, IERC20(token1).balanceOf(alice) - b1);
    }

    // TEST-247 verifies: REQ-LENS-050
    function test_TEST_247_feesOfALivePositionEqualCollectFees() public {
        bytes32 key = _mintAndPledge();
        swapper.swap(POOL, true, 5_000_000e6);
        swapper.swap(POOL, false, 7_000_000e6);
        PositionFeesView memory f = lens.getPositionFees(1, key);
        assertTrue(f.supported, "a position of the market's pool");
        assertTrue(f.inCustody, "pledged");
        assertGt(f.amounts[0], 0, "token0 fees from the first swap");
        assertGt(f.amounts[1], 0, "token1 fees from the second swap");
        (uint256 a0, uint256 a1) = _collect(key);
        assertEq(f.amounts[0], a0, "token0 = collectFees");
        assertEq(f.amounts[1], a1, "token1 = collectFees");
        // After the collect only new swaps count.
        swapper.swap(POOL, true, 2_000_000e6);
        f = lens.getPositionFees(1, key);
        assertEq(f.amounts[1], 0, "no token1 fee since the collect");
        (a0, a1) = _collect(key);
        assertEq(f.amounts[0], a0, "token0 after the second swap");
        assertEq(a1, 0, "token1");
    }
}
