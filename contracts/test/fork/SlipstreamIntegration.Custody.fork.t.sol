// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAmmIntegrationHooks} from "../../src/amm/IAmmIntegrationHooks.sol";
import {SlipstreamIntegration} from "../../src/amm/slipstream/SlipstreamIntegration.sol";
import {ILPVaultErrors} from "../../src/custody/lp-vault/ILPVaultErrors.sol";
import {ICLPool} from "../../src/interfaces/external/aerodrome/ICLPool.sol";
import {Lock} from "../../src/lock/lock/Lock.sol";
import {PositionShape} from "../../src/types/PositionShape.sol";
import {ShapeKind} from "../../src/types/ShapeKind.sol";
import {AvanaTest} from "../utils/AvanaTest.sol";
import {ClPoolMover, IClPoolActions} from "../utils/ClPoolMover.sol";
import {ForkConstants} from "../utils/fixtures/ForkConstants.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice The Slipstream NPM calls the test makes (`mint` ends with `sqrtPriceX96`; identical on the four generations).
interface ISlipNpm {
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

interface ISlipSlot0 {
    function slot0() external view returns (uint160, int24 tick, uint16, uint16, uint16, bool unlocked);
}

/// @title SlipstreamIntegrationCustodyForkTest
/// @notice `TEST-116` for the Aerodrome Slipstream integration on the Base fork, against the Aero generation's live
/// NPM, factory and WETH/USDC spacing-100 pool that the unit tests replace with `MockSlipstreamNPM`, `MockCLFactory` and
/// `MockCLPool`: a live position at the market's exact range is validated and received with its liquidity as the
/// credited units, the same pool at any other range is refused; a permissionless `increaseLiquidity` on the custodied
/// NFT changes no credited unit; after a real 200 WETH swap moves the spot price, `unwind` of half the units with zero
/// minimums returns at least the oracle composition of those units at the listing prices (`composition`, the fair
/// value), all of it to the recipient; `collectFees` leaves the units; inside a real `flash` (pool reentrancy flag set)
/// `checkReadSafe` reverts `PoolLocked` and passes outside it; the position goes back to its depositor. Forks at the
/// pinned Base block when one is set, else at the latest block; skipped without `RPC_BASE`.
/// @dev Run with `FOUNDRY_PROFILE=fork forge test --match-contract SlipstreamIntegrationCustodyForkTest`.
/// forge-config: default.isolate = false
contract SlipstreamIntegrationCustodyForkTest is AvanaTest {
    address internal constant WETH = 0x4200000000000000000000000000000000000006;
    address internal constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    /// @dev Generation 3 (Aero) WETH/USDC spacing 100, the pool `SlipstreamIntegrationForkTest` lists on that generation.
    address internal constant POOL = 0x2A430bEbD2082d8e05D56d64DEDE8944279bbC24;
    uint256 internal constant GEN = 3;
    uint256 internal constant MARKET = 1;
    int24 internal constant SPACING = 100;

    address internal adapter = makeAddr("aaveAdapter");
    address internal coll = makeAddr("collateralization");
    address internal registry = makeAddr("marketRegistry");
    Lock internal lock;
    SlipstreamIntegration internal vault;
    ClPoolMover internal mover;
    address internal npm;
    int24 internal lower;
    int24 internal upper;
    address[4] internal npms = [
        0x827922686190790b37229fd06084350E74485b72,
        0xa990C6a764b73BF43cee5Bb40339c3322FB9D55F,
        0xe1f8cd9AC4e4A65F54f38a5CdAfCA44f6dD68b53,
        0x4857DB576eE0e45F10525eC59527BfD10beeC60b
    ];
    address[4] internal factories = [
        0x5e7BB104d84c7CB9B682AaC2F3d509f5F406809A,
        0xaDe65c38CD4849aDBA595a4323a8C7DdfE89716a,
        0xf8f2eB4940CFE7d13603DDDD87f123820Fc061Ef,
        0x9CB220581b91b0C83223012FE69688b92aD07a76
    ];

    function setUp() public {
        string memory rpc = vm.envOr("RPC_BASE", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        uint256 pin = ForkConstants.baseForkBlock();
        if (pin == 0) vm.createSelectFork(rpc);
        else vm.createSelectFork(rpc, pin);
        lock = new Lock(adapter, makeAddr("lpVaultSwap"));
        vault = new SlipstreamIntegration(2, coll, registry, address(lock), makeAddr("timelock"), npms, factories);
        mover = new ClPoolMover();
        npm = npms[GEN];
        assertEq(ICLPool(POOL).nft(), npm);
        (, int24 tick,,,,) = ISlipSlot0(POOL).slot0();
        int24 base = tick / SPACING * SPACING;
        (lower, upper) = (base - 10 * SPACING, base + 10 * SPACING);
        vm.prank(registry);
        vault.bindMarket(
            MARKET,
            POOL,
            bytes32(0),
            PositionShape(ShapeKind.TickRange, lower, upper),
            abi.encode(GEN, uint256(3000e8), uint256(1e8))
        );
    }

    // TEST-116 verifies: REQ-VAULT-147, REQ-VAULT-149, SPEC-BACK-008, REQ-AMM-SLIP-007
    function test_TEST_116_slipstreamCustodyUnwindAtAMovedSpotAndFees() public {
        (uint256 id, uint128 l) = _mint(alice, lower, upper);
        bytes32 key = vault.positionKeyOf(uint8(GEN), id);

        (uint256 other,) = _mint(alice, lower - SPACING, upper);
        vm.expectRevert(abi.encodeWithSelector(ILPVaultErrors.RangeMismatch.selector, lower - SPACING, upper));
        vault.validatePosition(MARKET, alice, vault.positionKeyOf(uint8(GEN), other));

        assertEq(vault.validatePosition(MARKET, alice, key), l);
        vm.prank(alice);
        ISlipNpm(npm).approve(address(vault), id);
        _lock();
        vm.prank(coll);
        assertEq(vault.receivePosition(MARKET, alice, key), l);
        _unlock();
        assertEq(ISlipNpm(npm).ownerOf(id), address(vault));
        assertEq(vault.unitsOf(key), l);

        // Whether the NPM lets a third party add liquidity or refuses it, the credited units do not move.
        _fund(bob);
        vm.prank(bob);
        try ISlipNpm(npm)
            .increaseLiquidity(ISlipNpm.IncreaseLiquidityParams(id, 1e18, 4000e6, 0, 0, block.timestamp)) {}
            catch {}
        assertEq(vault.unitsOf(key), l, "a donated increase changes no credited unit");

        uint128 x = _unwindHalfAtMovedSpot(key, l);

        _lock();
        vm.prank(coll);
        vault.collectFees(key, alice);
        _unlock();
        assertEq(vault.unitsOf(key), l - x, "fees never take principal");

        deal(WETH, address(mover), 1e18);
        deal(USDC, address(mover), 10e6);
        mover.probeLocked(IClPoolActions(POOL), IAmmIntegrationHooks(address(vault)), MARKET);
        assertTrue(mover.probeRan());
        assertEq(mover.probed(), ILPVaultErrors.PoolLocked.selector, "PoolLocked while the pool is locked");
        vault.checkReadSafe(MARKET);

        _lock();
        vm.prank(coll);
        assertEq(vault.returnPosition(key), alice);
        _unlock();
        assertEq(ISlipNpm(npm).ownerOf(id), alice);
    }

    /// @dev Moves the spot with a real 200 WETH swap, then unwinds half the units with zero minimums to `carol` and
    /// checks the removal is worth at least the fair composition at the listing prices. Pool order: WETH (the lower
    /// address) then USDC, priced 3,000 USD and 1 USD.
    function _unwindHalfAtMovedSpot(
        bytes32 key,
        uint128 l
    ) internal returns (uint128 x) {
        deal(WETH, address(mover), 200e18);
        mover.move(IClPoolActions(POOL), true, 200e18);
        x = l / 2;
        uint256[] memory prices = new uint256[](2);
        (prices[0], prices[1]) = (3000e8, 1e8);
        (uint256[] memory fair,) = vault.composition(MARKET, x, prices);
        uint256 b0 = IERC20(WETH).balanceOf(carol);
        uint256 b1 = IERC20(USDC).balanceOf(carol);
        _lock();
        vm.prank(coll);
        uint256[] memory got = vault.unwind(key, x, new uint256[](2), carol);
        _unlock();
        assertEq(IERC20(WETH).balanceOf(carol) - b0, got[0], "the recipient receives the removed principal");
        assertEq(IERC20(USDC).balanceOf(carol) - b1, got[1]);
        assertGe(
            _usd(got, prices), _usd(fair, prices), "removal at a moved spot is worth at least the fair composition"
        );
        assertEq(vault.unitsOf(key), l - x);
    }

    /// @dev USD value (8 decimals) of pool-order amounts: WETH (18 decimals), then USDC (6).
    function _usd(
        uint256[] memory amounts,
        uint256[] memory prices
    ) internal pure returns (uint256) {
        return amounts[0] * prices[0] / 1e18 + amounts[1] * prices[1] / 1e6;
    }

    function _mint(
        address who,
        int24 lo,
        int24 hi
    ) internal returns (uint256 id, uint128 l) {
        _fund(who);
        vm.prank(who);
        (id, l,,) = ISlipNpm(npm)
            .mint(ISlipNpm.MintParams(WETH, USDC, SPACING, lo, hi, 1e18, 4000e6, 0, 0, who, block.timestamp, 0));
        assertGt(l, 0);
    }

    function _fund(
        address who
    ) internal {
        deal(WETH, who, IERC20(WETH).balanceOf(who) + 2e18);
        deal(USDC, who, IERC20(USDC).balanceOf(who) + 8000e6);
        vm.startPrank(who);
        IERC20(WETH).approve(npm, type(uint256).max);
        IERC20(USDC).approve(npm, type(uint256).max);
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
