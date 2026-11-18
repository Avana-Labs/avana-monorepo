// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {PositionShape, ShapeKind} from "../../src/types/PositionTypes.sol";
import {UniswapV4IntegrationFixture} from "../utils/fixtures/UniswapV4IntegrationFixture.sol";
import {IPermit2Approve, IV4TestPositionManager} from "../utils/fixtures/UniswapV4WorldFixture.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// @title UniswapV4IntegrationCrossProtocolTest
/// @notice The Uniswap v4 LPVault against positions and pools of other deployments: a position of a second
/// PositionManager on the same PoolManager, a pool initialized only on another PoolManager, and the Uniswap v3 pool of
/// the same pair are refused, as the Uniswap v3 and Slipstream LPVaults refuse another protocol's or generation's
/// positions and pools (5.1 `TEST-265`).
/// forge-config: default.isolate = false
contract UniswapV4IntegrationCrossProtocolTest is UniswapV4IntegrationFixture {
    IV4TestPositionManager internal posm2;

    function setUp() public override {
        super.setUp();
        posm2 = IV4TestPositionManager(
            deployCode(
                "out-univ4/PositionManager.sol/PositionManager.json",
                abi.encode(address(pm), permit2, uint256(100_000), address(0), address(weth))
            )
        );
        vm.label(address(posm2), "SecondPositionManager");
        IPermit2Approve(permit2).approve(address(usdc), address(posm2), type(uint160).max, type(uint48).max);
        IPermit2Approve(permit2).approve(address(usdt), address(posm2), type(uint160).max, type(uint48).max);
    }

    /// @dev Mints a market-1 position to `owner` through the second PositionManager.
    function _mintOnSecond(
        address owner
    ) internal returns (uint256 tokenId) {
        tokenId = posm2.nextTokenId();
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(
            stableKey, M1_LOWER, M1_UPPER, uint256(1e15), type(uint128).max, type(uint128).max, owner, bytes("")
        );
        params[1] = abi.encode(stableKey.currency0, stableKey.currency1);
        posm2.modifyLiquidities(abi.encode(abi.encodePacked(A_MINT_POSITION, A_SETTLE_PAIR), params), block.timestamp);
    }

    // TEST-265 verifies: REQ-AMM-V4-002, REQ-VAULT-124, REQ-AMM-CORE-003, ATTACK-178
    /// @notice An NFT of another PositionManager of the same PoolManager, pool and range, sent to the LPVault, reverts
    /// `UnsupportedNft`: only its own PositionManager may call its receiver hook.
    function test_TEST_265_anotherPositionManagersNftIsRefused() public {
        uint256 id = _mintOnSecond(alice);
        vm.prank(alice);
        vm.expectRevert(UnsupportedNft.selector);
        IERC721(address(posm2)).safeTransferFrom(alice, address(vault), id);
        assertEq(posm2.ownerOf(id), alice, "the NFT never reached the LPVault");
    }

    // TEST-265 verifies: REQ-AMM-V4-001, REQ-AMM-V4-007, REQ-AMM-CORE-003
    /// @notice A market on a key initialized only on another PoolManager (uninitialized on the LPVault's) and a market
    /// naming the pair's Uniswap v3 pool by address are refused `InvalidPool`.
    function test_TEST_265_poolsOfOtherDeploymentsAreRefused() public {
        IPoolManager pm2 =
            IPoolManager(deployCode("out-univ4/PoolManager.sol/PoolManager.json", abi.encode(address(this))));
        PoolKey memory other = PoolKey(stableKey.currency0, stableKey.currency1, 3000, 60, stableKey.hooks);
        pm2.initialize(other, uint160(1) << 96);
        PositionShape memory shape = PositionShape(ShapeKind.TickRange, -60, 60);
        vm.startPrank(registry);
        vm.expectRevert(InvalidPool.selector);
        vault.bindMarket(9, address(0), _poolId(other), shape, _bindData(other, address(stableRef), ONE, ONE));
        vm.expectRevert(InvalidPool.selector);
        vault.bindMarket(
            10, address(stableRef), _poolId(stableKey), shape, _bindData(stableKey, address(stableRef), ONE, ONE)
        );
        vm.stopPrank();
    }
}
