// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAmmIntegrationHooks} from "../../src/amm/IAmmIntegrationHooks.sol";
import {UniswapV3Integration} from "../../src/amm/uniswap-v3/UniswapV3Integration.sol";
import {ILPVaultErrors} from "../../src/custody/lp-vault/ILPVaultErrors.sol";
import {Lock} from "../../src/lock/lock/Lock.sol";
import {PositionShape} from "../../src/types/PositionShape.sol";
import {ShapeKind} from "../../src/types/ShapeKind.sol";
import {AvanaTest} from "../utils/AvanaTest.sol";
import {ClPoolMover, IClPoolActions} from "../utils/ClPoolMover.sol";
import {ForkConstants} from "../utils/fixtures/ForkConstants.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @notice The canonical NonfungiblePositionManager calls the test makes.
interface IV3Npm {
    struct MintParams {
        address token0;
        address token1;
        uint24 fee;
        int24 tickLower;
        int24 tickUpper;
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
        address recipient;
        uint256 deadline;
    }

    struct IncreaseLiquidityParams {
        uint256 tokenId;
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
        uint256 deadline;
    }

    function mint(
        MintParams calldata params
    ) external payable returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1);
    function increaseLiquidity(
        IncreaseLiquidityParams calldata params
    ) external payable returns (uint128 liquidity, uint256 amount0, uint256 amount1);
    function approve(
        address to,
        uint256 tokenId
    ) external;
    function ownerOf(
        uint256 tokenId
    ) external view returns (address);
}

interface IV3Slot0 {
    function slot0() external view returns (uint160, int24 tick, uint16, uint16, uint16, uint8, bool unlocked);
}

/// @title UniswapV3IntegrationCustodyForkTest
/// @notice `TEST-116` for the Uniswap v3 integration on the Ethereum fork, against the canonical NonfungiblePositionManager,
/// factory and USDC/USDT 0.01 % pool that the unit tests replace with `MockNFPM`, `MockV3Factory` and `MockV3Pool`: a
/// live position at the market's exact range is validated and received with its liquidity as the credited units, the
/// same pair at any other range is refused; a permissionless `increaseLiquidity` on the custodied NFT changes no credited
/// unit; after a real 20,000,000 USDC swap moves the spot price, `unwind` of half the units with zero minimums returns at
/// least the oracle composition of those units at $1 per token (`composition`, the fair value), all of it to the
/// recipient; `collectFees` leaves the units; inside a real `flash` (pool reentrancy flag set) `checkReadSafe` reverts
/// `PoolLocked`, and passes outside it; the position goes back to its depositor. Forks at the pinned Ethereum block when
/// one is set, else at the latest block; skipped without `RPC_MAINNET`.
/// @dev Run with `FOUNDRY_PROFILE=fork forge test --match-contract UniswapV3IntegrationCustodyForkTest`.
/// forge-config: default.isolate = false
contract UniswapV3IntegrationCustodyForkTest is AvanaTest {
    using SafeERC20 for IERC20;

    address internal constant NFPM = 0xC36442b4a4522E871399CD717aBDD847Ab11FE88;
    address internal constant FACTORY = 0x1F98431c8aD98523631AE4a59f267346ea31F984;
    address internal constant POOL = 0x3416cF6C708Da44DB2624D63ea0AAef7113527C6;
    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address internal constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    uint256 internal constant MARKET = 1;

    address internal adapter = makeAddr("aaveAdapter");
    address internal coll = makeAddr("collateralization");
    address internal registry = makeAddr("marketRegistry");
    Lock internal lock;
    UniswapV3Integration internal vault;
    ClPoolMover internal mover;
    int24 internal lower;
    int24 internal upper;

    function setUp() public {
        string memory rpc = vm.envOr("RPC_MAINNET", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        uint256 pin = ForkConstants.mainnetForkBlock();
        if (pin == 0) vm.createSelectFork(rpc);
        else vm.createSelectFork(rpc, pin);
        lock = new Lock(adapter, makeAddr("lpVaultSwap"));
        vault = new UniswapV3Integration(1, coll, registry, address(lock), makeAddr("timelock"), NFPM, FACTORY, 12);
        mover = new ClPoolMover();
        (, int24 tick,,,,,) = IV3Slot0(POOL).slot0();
        (lower, upper) = (tick - 20, tick + 20);
        vm.prank(registry);
        vault.bindMarket(
            MARKET, POOL, bytes32(0), PositionShape(ShapeKind.TickRange, lower, upper), abi.encode(1e8, 1e8)
        );
    }

    // TEST-116 verifies: REQ-VAULT-147, REQ-VAULT-149, SPEC-BACK-008, REQ-VAULT-012
    function test_TEST_116_uniswapV3CustodyUnwindAtAMovedSpotAndFees() public {
        (uint256 id, uint128 l) = _mint(alice, lower, upper);
        bytes32 key = bytes32(id);

        // Any other range of the same pool is refused.
        (uint256 other,) = _mint(alice, lower - 1, upper);
        vm.expectRevert(abi.encodeWithSelector(ILPVaultErrors.RangeMismatch.selector, lower - 1, upper));
        vault.validatePosition(MARKET, alice, bytes32(other));

        // Received at the exact range: the credited units are the position's liquidity.
        assertEq(vault.validatePosition(MARKET, alice, key), l);
        vm.prank(alice);
        IV3Npm(NFPM).approve(address(vault), id);
        _lock();
        vm.prank(coll);
        assertEq(vault.receivePosition(MARKET, alice, key), l);
        _unlock();
        assertEq(IV3Npm(NFPM).ownerOf(id), address(vault));
        assertEq(vault.unitsOf(key), l);

        // A permissionless liquidity increase on the custodied NFT credits nothing.
        _fund(bob, 10_000e6);
        vm.startPrank(bob);
        IV3Npm(NFPM).increaseLiquidity(IV3Npm.IncreaseLiquidityParams(id, 5000e6, 5000e6, 0, 0, block.timestamp));
        vm.stopPrank();
        assertEq(vault.unitsOf(key), l, "a donated increase changes no credited unit");

        // Move the spot price with a real swap, then unwind half the units with zero minimums.
        uint128 x = _unwindHalfAtMovedSpot(key, l);

        // Fees never take principal.
        _lock();
        vm.prank(coll);
        vault.collectFees(key, alice);
        _unlock();
        assertEq(vault.unitsOf(key), l - x, "fees never take principal");

        // The pool's reentrancy flag blocks the integration's reads; outside the flash they pass.
        _fund(address(mover), 10e6);
        mover.probeLocked(IClPoolActions(POOL), IAmmIntegrationHooks(address(vault)), MARKET);
        assertTrue(mover.probeRan());
        assertEq(mover.probed(), ILPVaultErrors.PoolLocked.selector, "PoolLocked while the pool is locked");
        vault.checkReadSafe(MARKET);

        _lock();
        vm.prank(coll);
        assertEq(vault.returnPosition(key), alice);
        _unlock();
        assertEq(IV3Npm(NFPM).ownerOf(id), alice);
    }

    /// @dev Moves the spot with a real 20,000,000 USDC swap, then unwinds half the units with zero minimums to `carol`
    /// and checks the removal is worth at least the fair composition at $1 per token (both tokens have 6 decimals).
    function _unwindHalfAtMovedSpot(
        bytes32 key,
        uint128 l
    ) internal returns (uint128 x) {
        deal(USDC, address(mover), 20_000_000e6);
        mover.move(IClPoolActions(POOL), true, 20_000_000e6);
        x = l / 2;
        uint256[] memory prices = new uint256[](2);
        (prices[0], prices[1]) = (1e8, 1e8);
        (uint256[] memory fair,) = vault.composition(MARKET, x, prices);
        uint256 b0 = IERC20(USDC).balanceOf(carol);
        uint256 b1 = IERC20(USDT).balanceOf(carol);
        _lock();
        vm.prank(coll);
        uint256[] memory got = vault.unwind(key, x, new uint256[](2), carol);
        _unlock();
        assertEq(IERC20(USDC).balanceOf(carol) - b0, got[0], "the recipient receives the removed principal");
        assertEq(IERC20(USDT).balanceOf(carol) - b1, got[1]);
        assertGe(got[0] + got[1], fair[0] + fair[1], "removal at a moved spot is worth at least the fair composition");
        assertEq(vault.unitsOf(key), l - x);
    }

    function _mint(
        address who,
        int24 lo,
        int24 hi
    ) internal returns (uint256 id, uint128 l) {
        _fund(who, 20_000e6);
        vm.prank(who);
        (id, l,,) = IV3Npm(NFPM)
            .mint(IV3Npm.MintParams(USDC, USDT, 100, lo, hi, 10_000e6, 10_000e6, 0, 0, who, block.timestamp));
        assertGt(l, 0);
    }

    /// @dev Deals both tokens to `who` and approves the NFPM (USDT needs the zero-first, no-return approve).
    function _fund(
        address who,
        uint256 amount
    ) internal {
        deal(USDC, who, IERC20(USDC).balanceOf(who) + amount);
        deal(USDT, who, IERC20(USDT).balanceOf(who) + amount);
        vm.startPrank(who);
        IERC20(USDC).forceApprove(NFPM, type(uint256).max);
        IERC20(USDT).forceApprove(NFPM, type(uint256).max);
        vm.stopPrank();
    }

    function _lock() internal {
        vm.prank(adapter);
        lock.acquire();
    }

    function _unlock() internal {
        vm.prank(adapter);
        lock.release();
    }
}
