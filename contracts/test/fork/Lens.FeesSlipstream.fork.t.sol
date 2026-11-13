// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {SlipstreamIntegration} from "../../src/amm/slipstream/SlipstreamIntegration.sol";
import {ILens} from "../../src/lens/lens/ILens.sol";
import {PositionFeesView} from "../../src/lens/lens/types/PositionFeesView.sol";
import {Lock} from "../../src/lock/lock/Lock.sol";
import {PositionShape} from "../../src/types/PositionShape.sol";
import {ShapeKind} from "../../src/types/ShapeKind.sol";
import {AvanaTest} from "../utils/AvanaTest.sol";
import {ForkConstants} from "../utils/fixtures/ForkConstants.sol";
import {LensFeesDeploy} from "../utils/fixtures/LensFeesFixture.sol";
import {LensRegistryMock} from "../utils/mocks/LensMocks.sol";
import {LensForkSwapper} from "./Lens.Fees.fork.t.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice The Slipstream position manager's `mint` (an extra `sqrtPriceX96` field) and `approve`.
interface ILensForkSlipstreamMint {
    struct MintParams {
        address token0;
        address token1;
        int24 tickSpacing;
        int24 tickLower;
        int24 tickUpper;
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
        address recipient;
        uint256 deadline;
        uint160 sqrtPriceX96;
    }

    function mint(
        MintParams calldata params
    ) external payable returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1);

    function approve(
        address to,
        uint256 tokenId
    ) external;
}

/// @title LensFeesSlipstreamForkTest
/// @notice `getPositionFees` on a Base fork against the Aero generation's position manager and its WETH/USDC pool of
/// spacing 100: a full-range position takes fees from real swaps, and the Lens's amounts equal what the production
/// Slipstream LPVault's `collectFees` pays. Skipped without `RPC_BASE` or a pinned block.
/// @dev Run with `FOUNDRY_PROFILE=fork forge test --match-contract LensFeesSlipstreamForkTest`.
/// forge-config: default.isolate = false
contract LensFeesSlipstreamForkTest is AvanaTest {
    address internal constant WETH = 0x4200000000000000000000000000000000000006;
    address internal constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address internal constant POOL = 0x2A430bEbD2082d8e05D56d64DEDE8944279bbC24;
    uint8 internal constant GEN = 3;
    int24 internal constant EDGE = 887_200;

    address internal adapter = makeAddr("aaveAdapter");
    address internal coll = makeAddr("collateralization");
    address internal registry = makeAddr("marketRegistry");
    address[4] internal npm = [
        0x827922686190790b37229fd06084350E74485b72,
        0xa990C6a764b73BF43cee5Bb40339c3322FB9D55F,
        0xe1f8cd9AC4e4A65F54f38a5CdAfCA44f6dD68b53,
        0x4857DB576eE0e45F10525eC59527BfD10beeC60b
    ];
    address[4] internal factory = [
        0x5e7BB104d84c7CB9B682AaC2F3d509f5F406809A,
        0xaDe65c38CD4849aDBA595a4323a8C7DdfE89716a,
        0xf8f2eB4940CFE7d13603DDDD87f123820Fc061Ef,
        0x9CB220581b91b0C83223012FE69688b92aD07a76
    ];
    Lock internal lock;
    SlipstreamIntegration internal vault;
    ILens internal lens;
    LensForkSwapper internal swapper;

    function setUp() public {
        string memory rpc = vm.envOr("RPC_BASE", string(""));
        uint256 blockNumber = ForkConstants.baseForkBlock();
        if (bytes(rpc).length == 0 || blockNumber == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpc, blockNumber);
        lock = new Lock(adapter, makeAddr("lpVaultSwap"));
        vault = new SlipstreamIntegration(2, coll, registry, address(lock), makeAddr("timelock"), npm, factory);
        vm.prank(registry);
        vault.bindMarket(
            1,
            POOL,
            bytes32(0),
            PositionShape(ShapeKind.TickRange, -EDGE, EDGE),
            abi.encode(uint256(GEN), uint256(3000e8), uint256(1e8))
        );
        LensRegistryMock reg = new LensRegistryMock();
        reg.setMarket(1, LensFeesDeploy.market(address(vault), 2, POOL, WETH, USDC, -EDGE, EDGE));
        LensFeesDeploy.etchStandIns(adapter, coll);
        lens = LensFeesDeploy.deploy(
            [coll, makeAddr("pm"), adapter, address(lock), address(reg), registry, registry, makeAddr("swap"), coll]
        );
        swapper = new LensForkSwapper();
        deal(WETH, address(swapper), 10_000e18);
        deal(USDC, address(swapper), 30_000_000e6);
    }

    function _asColl(
        bytes memory data
    ) internal {
        vm.prank(adapter);
        lock.acquire();
        vm.prank(coll);
        (bool ok,) = address(vault).call(data);
        require(ok, "Collateralization call");
        vm.prank(adapter);
        lock.release();
    }

    // TEST-247 verifies: REQ-LENS-050
    function test_TEST_247_slipstreamFeesOfALivePositionEqualCollectFees() public {
        deal(WETH, alice, 10e18);
        deal(USDC, alice, 40_000e6);
        vm.startPrank(alice);
        IERC20(WETH).approve(npm[GEN], type(uint256).max);
        IERC20(USDC).approve(npm[GEN], type(uint256).max);
        (uint256 id,,,) = ILensForkSlipstreamMint(npm[GEN])
            .mint(
                ILensForkSlipstreamMint.MintParams(
                    WETH, USDC, 100, -EDGE, EDGE, 10e18, 40_000e6, 0, 0, alice, block.timestamp, 0
                )
            );
        ILensForkSlipstreamMint(npm[GEN]).approve(address(vault), id);
        vm.stopPrank();
        bytes32 key = vault.positionKeyOf(GEN, id);
        _asColl(abi.encodeCall(vault.receivePosition, (1, alice, key)));
        swapper.swap(POOL, true, 100e18);
        swapper.swap(POOL, false, 400_000e6);
        PositionFeesView memory f = lens.getPositionFees(1, key);
        assertTrue(f.supported, "the market's generation and pool");
        assertGt(f.amounts[0] + f.amounts[1], 0, "fees from the swaps");
        uint256 b0 = IERC20(WETH).balanceOf(alice);
        uint256 b1 = IERC20(USDC).balanceOf(alice);
        _asColl(abi.encodeCall(vault.collectFees, (key, alice)));
        assertEq(IERC20(WETH).balanceOf(alice) - b0, f.amounts[0], "WETH = collectFees");
        assertEq(IERC20(USDC).balanceOf(alice) - b1, f.amounts[1], "USDC = collectFees");
    }
}
