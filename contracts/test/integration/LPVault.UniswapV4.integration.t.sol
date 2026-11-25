// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IUniswapV4PoolManager, UniswapV4PoolKey} from "../../src/dependencies/uniswap-v4/IUniswapV4PoolManager.sol";
import {UniswapV4Integration} from "../../src/integrations/UniswapV4Integration.sol";
import {UniswapV4State} from "../../src/integrations/UniswapV4State.sol";
import {ILPVault} from "../../src/interfaces/ILPVault.sol";
import {IUniswapV4Integration} from "../../src/interfaces/IUniswapV4Integration.sol";
import {ClTickMath} from "../../src/libraries/ClTickMath.sol";
import {FloorCreditMath} from "../../src/libraries/FloorCreditMath.sol";
import {LPPriceMath} from "../../src/libraries/LPPriceMath.sol";
import {AmmParityChecks} from "../utils/AmmParityChecks.sol";
import {ClTestToken} from "../utils/fixtures/ClPoolFixture.sol";
import {UniswapV4WorldFixture, V4TestSubscriber} from "../utils/fixtures/UniswapV4WorldFixture.sol";
import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// @notice The upstream lens the parity fuzz compares Avana's fee-growth reads with.
interface IV4StateView {
    function getFeeGrowthInside(
        bytes32 poolId,
        int24 tickLower,
        int24 tickUpper
    ) external view returns (uint256 feeGrowthInside0X128, uint256 feeGrowthInside1X128);
}

/// @notice The Uniswap v4 LPVault on the real PoolManager and PositionManager: pledge, top-up, partial removal with
/// fees held for the position, unwind, fee collection and release, on an ERC-20 pair and on a native-ETH pair.
contract LPVaultUniswapV4IntegrationTest is UniswapV4WorldFixture, AmmParityChecks {
    uint64 internal constant ADAPTER_ROLE = 11;
    uint64 internal constant LIQUIDATION_ROLE = 12;
    int24 internal constant BAND_LOWER = -6000;
    int24 internal constant BAND_UPPER = 6000;
    uint256 internal constant MARKET = 1;
    uint256 internal constant NATIVE_MARKET = 2;
    uint256 internal constant PARITY_MARKET = 3;

    UniswapV4Integration internal vault;
    AccessManager internal am;
    PoolKey internal key;
    PoolKey internal nativeKey;
    ClTestToken internal t0;
    ClTestToken internal t1;

    address internal adapter = makeAddr("adapter");
    address internal liquidator = makeAddr("liquidator");
    address internal account = makeAddr("account");
    address internal recipient = makeAddr("recipient");

    function setUp() public {
        _deployV4World();
        (ClTestToken a, ClTestToken b, bool aIsToken0) = _sortedTokens("TKA", 18, "TKB", 18);
        (t0, t1) = aIsToken0 ? (a, b) : (b, a);
        key = _key(address(t0), address(t1), 3000, 60);
        _initPool(key, 1e8, 1e8, 18, 18);
        nativeKey = _key(address(0), address(t1), 3000, 60);
        _initPool(nativeKey, 1e8, 1e8, 18, 18);
        _mintV4(address(this), key, -60_000, 60_000, 1e21);
        _mintV4(address(this), nativeKey, -60_000, 60_000, 1e21);

        am = new AccessManager(address(this));
        vault = new UniswapV4Integration(address(am), address(posm));
        bytes4[] memory adapterSelectors = new bytes4[](5);
        adapterSelectors[0] = ILPVault.pledge.selector;
        adapterSelectors[1] = ILPVault.addLiquidity.selector;
        adapterSelectors[2] = ILPVault.removeLiquidity.selector;
        adapterSelectors[3] = ILPVault.release.selector;
        adapterSelectors[4] = ILPVault.collectFees.selector;
        am.setTargetFunctionRole(address(vault), adapterSelectors, ADAPTER_ROLE);
        bytes4[] memory unwindSelector = new bytes4[](1);
        unwindSelector[0] = ILPVault.unwind.selector;
        am.setTargetFunctionRole(address(vault), unwindSelector, LIQUIDATION_ROLE);
        am.grantRole(ADAPTER_ROLE, adapter, 0);
        am.grantRole(LIQUIDATION_ROLE, liquidator, 0);
        vault.listMarket(MARKET, vault.registerPool(_v4Key(key)), BAND_LOWER, BAND_UPPER);
        vault.listMarket(NATIVE_MARKET, vault.registerPool(_v4Key(nativeKey)), BAND_LOWER, BAND_UPPER);

        IERC721(address(posm)).setApprovalForAll(address(vault), true);
        t0.approve(address(vault), type(uint256).max);
        t1.approve(address(vault), type(uint256).max);
        weth.deposit{value: 1e24}();
        IERC20(address(weth)).approve(address(vault), type(uint256).max);
    }

    function test_registerPool_refusesHookedOrUninitializedPools() public {
        UniswapV4PoolKey memory hooked = _v4Key(key);
        hooked.hooks = address(0xBEEF);
        vm.expectRevert(
            abi.encodeWithSelector(IUniswapV4Integration.UnsupportedPool.selector, keccak256(abi.encode(hooked)))
        );
        vault.registerPool(hooked);
        UniswapV4PoolKey memory fresh = _v4Key(_key(address(t0), address(t1), 500, 10));
        vm.expectRevert(
            abi.encodeWithSelector(IUniswapV4Integration.UnsupportedPool.selector, keccak256(abi.encode(fresh)))
        );
        vault.registerPool(fresh);
        bytes32 unregistered = keccak256(abi.encode(fresh));
        vm.expectRevert(abi.encodeWithSelector(ILPVault.InvalidPool.selector, unregistered));
        vault.listMarket(3, unregistered, BAND_LOWER, BAND_UPPER);
        assertEq(vault.getMarket(NATIVE_MARKET).token0, address(weth));
    }

    /// @notice Bug hunted: a vault built on a missing PositionManager, or on one whose PoolManager or WETH is not a
    /// contract. Every position read goes to the PoolManager's storage and the native leg wraps into WETH, so such a
    /// vault reads zeros (no position, no fees) instead of failing at deployment.
    function test_constructor_refusesAMissingPositionManagerPoolManagerOrWeth() public {
        vm.expectRevert(ILPVault.InvalidDeployment.selector);
        new UniswapV4Integration(address(am), address(0));
        vm.expectRevert(ILPVault.InvalidDeployment.selector);
        new UniswapV4Integration(address(am), makeAddr("codelessPositionManager"));
        address noPm = address(new V4PositionManagerStub(makeAddr("codelessPoolManager"), address(weth)));
        vm.expectRevert(ILPVault.InvalidDeployment.selector);
        new UniswapV4Integration(address(am), noPm);
        address noWeth = address(new V4PositionManagerStub(address(pm), makeAddr("codelessWeth")));
        vm.expectRevert(ILPVault.InvalidDeployment.selector);
        new UniswapV4Integration(address(am), noWeth);
    }

    /// @notice Bug hunted: a token id the PositionManager never minted read as a position. Its packed info is zero,
    /// which decodes to ticks 0 and 0 in pool 0; the vault must report no pool and refuse the pledge rather than
    /// credit or record it.
    function test_pledge_refusesATokenNeverMinted() public {
        bytes32 never = bytes32(uint256(1e9));
        (bytes32 pool, int24 lower, int24 upper, uint128 liquidity) = vault.positionInfo(never);
        assertEq(pool, bytes32(0));
        assertEq(int256(lower) + int256(upper), 0);
        assertEq(liquidity, 0);
        vm.prank(adapter);
        vm.expectRevert(abi.encodeWithSelector(ILPVault.PoolMismatch.selector, never, bytes32(0)));
        vault.pledge(address(this), account, MARKET, never);
    }

    /// @notice Bug hunted: a top-up that buys no liquidity still takes the caller's tokens. An in-range position needs
    /// both tokens, so token0 alone buys nothing; the vault must refuse it before any token moves.
    function test_addLiquidity_oneSidedInRangeTopUpIsRefused() public {
        (bytes32 pk, uint128 l0) = _position(key, -1200, 1200, 1e20);
        _pledge(pk, MARKET);
        uint256 before0 = t0.balanceOf(address(this));
        uint256 before1 = t1.balanceOf(address(this));
        vm.prank(adapter);
        vm.expectRevert(abi.encodeWithSelector(ILPVault.InvalidAmount.selector, pk, uint128(0)));
        vault.addLiquidity(pk, address(this), 1e18, 0, 0, 0);
        assertEq(t0.balanceOf(address(this)), before0);
        assertEq(t1.balanceOf(address(this)), before1);
        assertEq(vault.getPosition(pk).liquidity, l0);
    }

    /// @notice Bug hunted: fees of a position whose liquidity was all removed are paid twice, or the collect on it
    /// reverts and locks the fees held at the removal. A drained position has no live liquidity, so the view and the
    /// collect must report only the held fees, once.
    function test_collectFees_onADrainedPositionPaysTheHeldFeesOnce() public {
        (bytes32 pk, uint128 l0) = _position(key, -1200, 1200, 1e20);
        _pledge(pk, MARKET);
        _washV4(key, 1e20);
        (uint256 f0, uint256 f1) = vault.feesOf(pk);
        assertGt(f0 + f1, 0);
        vm.prank(adapter);
        vault.removeLiquidity(pk, l0, 0, 0, recipient);
        assertEq(_live(key, pk), 0);
        (uint256 g0, uint256 g1) = vault.feesOf(pk);
        assertEq(g0, f0, "held token0 fees still reported");
        assertEq(g1, f1, "held token1 fees still reported");
        bytes32[] memory keys = new bytes32[](1);
        keys[0] = pk;
        address owner = makeAddr("owner");
        vm.prank(adapter);
        vault.collectFees(account, keys, owner);
        assertEq(t0.balanceOf(owner), f0);
        assertEq(t1.balanceOf(owner), f1);
        vm.prank(adapter);
        vault.collectFees(account, keys, owner);
        assertEq(t0.balanceOf(owner), f0, "a second collect pays nothing");
        assertEq(t1.balanceOf(owner), f1, "a second collect pays nothing");
        (g0, g1) = vault.feesOf(pk);
        assertEq(g0 + g1, 0);
    }

    function test_pledge_creditsTheFloor() public {
        (bytes32 k, uint128 l) = _position(key, -1200, 1200, 1e20);
        uint128 credit = _pledge(k, MARKET);
        assertEq(credit, FloorCreditMath.credit(-1200, 1200, BAND_LOWER, BAND_UPPER, l));
        assertEq(IERC721(address(posm)).ownerOf(uint256(k)), address(vault));
        (bytes32 outside,) = _position(key, -6600, 0, 1e20);
        vm.prank(adapter);
        vm.expectRevert(
            abi.encodeWithSelector(
                FloorCreditMath.NotInsideBand.selector, int24(-6600), int24(0), BAND_LOWER, BAND_UPPER
            )
        );
        vault.pledge(address(this), account, MARKET, outside);
        (bytes32 otherPool,) = _position(nativeKey, -1200, 1200, 1e20);
        vm.prank(adapter);
        vm.expectRevert(
            abi.encodeWithSelector(ILPVault.PoolMismatch.selector, otherPool, keccak256(abi.encode(nativeKey)))
        );
        vault.pledge(address(this), account, MARKET, otherPool);
    }

    function test_addLiquidity_asOwnerThroughThePositionManager() public {
        _checkAddLiquidity(key, MARKET, address(t0), address(t1));
    }

    function test_addLiquidity_nativePair() public {
        _checkAddLiquidity(nativeKey, NATIVE_MARKET, address(weth), address(t1));
    }

    function test_removeLiquidity_holdsFeesAndSendsPrincipal() public {
        _checkRemoveAndFees(key, MARKET, address(t0), address(t1));
    }

    function test_removeLiquidity_nativePairPaysWrapped() public {
        _checkRemoveAndFees(nativeKey, NATIVE_MARKET, address(weth), address(t1));
    }

    function test_collectFees_severalPositionsMatchTheView() public {
        (bytes32 a,) = _position(key, -1200, 1200, 1e20);
        (bytes32 b,) = _position(key, -600, 600, 1e20);
        _pledge(a, MARKET);
        _pledge(b, MARKET);
        _washV4(key, 1e20);
        (uint256 fa0, uint256 fa1) = vault.feesOf(a);
        (uint256 fb0, uint256 fb1) = vault.feesOf(b);
        assertGt(fa0 + fa1, 0);
        assertGt(fb0 + fb1, 0);
        bytes32[] memory keys = new bytes32[](2);
        (keys[0], keys[1]) = (a, b);
        vm.prank(adapter);
        (uint256[] memory f0, uint256[] memory f1) = vault.collectFees(account, keys, recipient);
        assertEq(f0[0], fa0);
        assertEq(f1[0], fa1);
        assertEq(f0[1], fb0);
        assertEq(f1[1], fb1);
        assertEq(t0.balanceOf(recipient), fa0 + fb0);
        assertEq(t1.balanceOf(recipient), fa1 + fb1);
        assertEq(t0.balanceOf(address(vault)), 0);
    }

    /// @notice A position earns both token fees while the price crosses its range, then is checked above, below and
    /// inside the range: the view equals the PositionManager payout at each stop, including outside-growth ordering.
    function test_feesOf_matchesCollectAboveBelowAndBackInRange() public {
        (bytes32 pk,) = _position(key, -600, 600, 1e20);
        _pledge(pk, MARKET);
        _washV4(key, 1e20);
        (uint256 f0, uint256 f1) = vault.feesOf(pk);
        assertGt(f0, 0, "fees accrued in token0 while price crossed the range");
        assertGt(f1, 0, "fees accrued in token1 while price crossed the range");
        _checkFeesPaid(pk, 1500);
        _checkFeesPaid(pk, -1500);
        _checkFeesPaid(pk, 0);
    }

    /// @notice Fees earned before a top-up stay the position's: they are taken and held first, not spent on the new
    /// liquidity, so the payer pays the whole top-up and the owner still collects the fees.
    function test_addLiquidity_keepsTheFeesEarnedBefore() public {
        (bytes32 pk,) = _position(key, -1200, 1200, 1e20);
        _pledge(pk, MARKET);
        _washV4(key, 1e20);
        (uint256 f0, uint256 f1) = vault.feesOf(pk);
        assertGt(f0, 0);
        assertGt(f1, 0);
        vm.prank(adapter);
        vault.addLiquidity(pk, address(this), 1e18, 1e18, 0, 0);
        (uint256 g0, uint256 g1) = vault.feesOf(pk);
        assertEq(g0, f0, "token0 fees kept");
        assertEq(g1, f1, "token1 fees kept");
        bytes32[] memory keys = new bytes32[](1);
        keys[0] = pk;
        address owner = makeAddr("owner");
        vm.prank(adapter);
        vault.collectFees(account, keys, owner);
        assertEq(t0.balanceOf(owner), f0);
        assertEq(t1.balanceOf(owner), f1);
    }

    /// @notice A top-up bound by token1 takes only the token0 it uses and returns the rest, on an ERC-20 pair and on a
    /// native-ETH pair (whose unused ETH is wrapped back), and leaves nothing in the PositionManager.
    function test_addLiquidity_token1BoundReturnsTheUnusedToken0() public {
        _checkAddToken1Bound(key, MARKET, address(t0), address(t1));
        _checkAddToken1Bound(nativeKey, NATIVE_MARKET, address(weth), address(t1));
    }

    /// @notice A top-up of a range below the price takes only token1, and the liquidity added is what that token1 buys.
    function test_addLiquidity_belowThePriceTakesOnlyToken1() public {
        (bytes32 pk, uint128 l0) = _position(key, -1200, -600, 1e20);
        _pledge(pk, MARKET);
        uint256 before1 = t1.balanceOf(address(this));
        vm.prank(adapter);
        (uint128 added,, uint256 a0, uint256 a1) = vault.addLiquidity(pk, address(this), 1e18, 1e18, 0, 0);
        assertGt(added, 0);
        assertEq(a0, 0, "a range below the price holds no token0");
        assertLe(a1, 1e18);
        assertGt(a1, 1e18 - 1e6, "nearly all of the token1 is used");
        assertEq(before1 - t1.balanceOf(address(this)), a1);
        assertEq(vault.getPosition(pk).liquidity, l0 + added);
        assertEq(_live(key, pk), l0 + added);
    }

    /// @notice The gas of a cold partial unwind on the real PoolManager and PositionManager, which the liquidation
    /// profitability suite (`LiquidationProfitability.AaveV4.integration.t.sol`) compares with the v3 unwind to give the
    /// v4 break-even position size. Bug hunted: an unwind so costly that a liquidation through it cannot pay its gas.
    function test_unwindGas_coldPartial() public {
        (bytes32 k,) = _position(key, BAND_LOWER, BAND_UPPER, 1e22);
        uint128 credit = _pledge(k, MARKET);
        vm.cool(address(vault));
        vm.cool(address(posm));
        vm.cool(address(pm));
        vm.cool(address(t0));
        vm.cool(address(t1));
        vm.cool(recipient);
        uint256 g = gasleft();
        vm.prank(liquidator);
        vault.unwind(k, credit / 3, 0, 0, recipient);
        uint256 used = g - gasleft();
        emit log_named_uint("gas: cold partial unwind, Uniswap v4", used);
        assertLt(used, 400_000);
    }

    function test_unwindThenRelease() public {
        (bytes32 k,) = _position(key, -1200, 1200, 1e20);
        uint128 credit = _pledge(k, MARKET);
        _washV4(key, 1e20);
        vm.prank(liquidator);
        (uint128 liquidity, uint128 removed, uint256 a0, uint256 a1) = vault.unwind(k, credit / 3, 0, 0, recipient);
        assertGt(liquidity, 0);
        assertGe(removed, credit / 3);
        assertEq(t0.balanceOf(recipient), a0);
        assertEq(t1.balanceOf(recipient), a1);
        (uint256 h0, uint256 h1) = vault.feesOf(k);
        assertGt(h0 + h1, 0);
        address owner = makeAddr("owner");
        vm.prank(adapter);
        vault.release(k, owner);
        assertEq(IERC721(address(posm)).ownerOf(uint256(k)), owner);
        assertEq(t0.balanceOf(owner), h0);
        assertEq(t1.balanceOf(owner), h1);
        assertEq(t0.balanceOf(address(vault)), 0);
        assertEq(t1.balanceOf(address(vault)), 0);
    }

    // ─── Custody and position identity ───

    /// @notice Bug hunted: a position of another pool with the same two currencies (another fee and tick spacing) is
    /// credited in this market, whose pool it is not.
    function test_pledge_refusesThePositionOfAnotherPoolOfTheSameCurrencies() public {
        PoolKey memory twin = _key(address(t0), address(t1), 500, 10);
        _initPool(twin, 1e8, 1e8, 18, 18);
        vault.registerPool(_v4Key(twin));
        (bytes32 pk,) = _position(twin, -1200, 1200, 1e20);
        vm.prank(adapter);
        vm.expectRevert(abi.encodeWithSelector(ILPVault.PoolMismatch.selector, pk, _poolId(twin)));
        vault.pledge(address(this), account, MARKET, pk);
        assertEq(IERC721(address(posm)).ownerOf(uint256(pk)), address(this));
    }

    /// @notice Bug hunted: liquidity added straight to a pledged position by its former owner, bypassing Avana,
    /// inflates the credit or is lost. The PositionManager lets only the NFT's owner or approved address (the vault)
    /// change the position, and the PoolManager keys it by the PositionManager, so no one else can add to it.
    function test_directIncrease_isRefusedByThePositionManager() public {
        (bytes32 pk, uint128 l0) = _position(key, -1200, 1200, 1e20);
        uint128 c0 = _pledge(pk, MARKET);
        bytes memory actions = abi.encodePacked(uint8(0x00), A_SETTLE_PAIR);
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(uint256(pk), uint256(1e18), type(uint128).max, type(uint128).max, bytes(""));
        params[1] = abi.encode(key.currency0, key.currency1);
        vm.expectRevert();
        posm.modifyLiquidities(abi.encode(actions, params), block.timestamp);
        assertEq(_live(key, pk), l0);
        assertEq(vault.getPosition(pk).credit, c0);
        assertEq(vault.getMarket(MARKET).totalCredit, c0);
    }

    /// @notice Bug hunted: a subscriber set on a position before its pledge re-enters the vault from the
    /// `notifyUnsubscribe` call the PositionManager makes on the transfer, and takes another position or leaves the
    /// record without custody. The guard refuses it, the PositionManager swallows the failure, and the pledge lands
    /// with custody and record together and no subscriber left.
    function test_subscriber_cannotReenterThroughThePledgeTransfer() public {
        (bytes32 other,) = _position(key, -600, 600, 1e20);
        _pledge(other, MARKET);
        (bytes32 pk,) = _position(key, -1200, 1200, 1e20);
        ReenteringSubscriber sub =
            new ReenteringSubscriber(address(vault), abi.encodeCall(ILPVault.release, (other, makeAddr("thief"))));
        // Worst case: the subscriber holds the adapter role, so only the guard can stop it.
        am.grantRole(ADAPTER_ROLE, address(sub), 0);
        posm.subscribe(uint256(pk), address(sub), "");
        uint128 credit = _pledge(pk, MARKET);
        assertTrue(sub.unsubscribed());
        assertFalse(sub.reentryOk());
        assertEq(bytes4(sub.reentryReturn()), ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector);
        assertEq(IERC721(address(posm)).ownerOf(uint256(pk)), address(vault));
        assertEq(IERC721(address(posm)).ownerOf(uint256(other)), address(vault));
        assertEq(vault.getPosition(pk).credit, credit);
        assertEq(vault.getPosition(other).account, account);
    }

    /// @notice Bug hunted: a vault call made from inside a PoolManager `unlock` (an attacker's callback, mid-swap)
    /// changes a position at a price the attacker set. The PositionManager cannot unlock again, so the call reverts and
    /// the record does not move.
    function test_unlockCallback_cannotChangeAPosition() public {
        (bytes32 pk, uint128 l0) = _position(key, -1200, 1200, 1e20);
        uint128 c0 = _pledge(pk, MARKET);
        am.grantRole(ADAPTER_ROLE, address(v4Actor), 0);
        (bool ok,) =
            v4Actor.callInside(address(vault), abi.encodeCall(ILPVault.removeLiquidity, (pk, l0 / 2, 0, 0, recipient)));
        assertFalse(ok);
        (ok,) = v4Actor.callInside(address(vault), abi.encodeCall(ILPVault.release, (pk, recipient)));
        assertFalse(ok);
        assertEq(vault.getPosition(pk).liquidity, l0);
        assertEq(vault.getPosition(pk).credit, c0);
        assertEq(IERC721(address(posm)).ownerOf(uint256(pk)), address(vault));
    }

    /// @notice Bug hunted: the PositionManager's unlock path reached from outside an operation Avana started. An
    /// attacker inside its own PoolManager `unlock` calls `modifyLiquiditiesWithoutUnlock` to decrease a pledged
    /// position and take the tokens, or calls the PositionManager's `unlockCallback` itself, or sends an
    /// `unlockCallback` to the vault. The PositionManager checks the NFT's approval against the attacker and the
    /// callback's caller against the PoolManager, and the vault has no callback, so every call fails and the position,
    /// its record and the attacker's balances do not move.
    function test_unlockPathFromOutside_cannotDecreaseAPledgedPosition() public {
        (bytes32 pk, uint128 l0) = _position(key, -1200, 1200, 1e20);
        uint128 c0 = _pledge(pk, MARKET);
        bytes memory actions = abi.encodePacked(uint8(0x01), uint8(0x11));
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(uint256(pk), uint256(l0), uint128(0), uint128(0), bytes(""));
        params[1] = abi.encode(key.currency0, key.currency1, address(v4Actor));
        uint256 b0 = t0.balanceOf(address(v4Actor));
        uint256 b1 = t1.balanceOf(address(v4Actor));

        (bool ok, bytes memory ret) = v4Actor.callInside(
            address(posm), abi.encodeWithSignature("modifyLiquiditiesWithoutUnlock(bytes,bytes[])", actions, params)
        );
        assertFalse(ok, "decrease of a token the attacker is not approved for");
        assertEq(ret, abi.encodeWithSignature("NotApproved(address)", address(v4Actor)));
        (ok, ret) = v4Actor.callInside(
            address(posm), abi.encodeWithSignature("unlockCallback(bytes)", abi.encode(actions, params))
        );
        assertEq(ret, abi.encodeWithSignature("NotPoolManager()"));
        assertFalse(ok, "only the PoolManager calls the PositionManager back");
        (ok,) = v4Actor.callInside(
            address(vault), abi.encodeWithSignature("unlockCallback(bytes)", abi.encode(actions, params))
        );
        assertFalse(ok, "the vault has no unlock callback");
        (ok,) = address(vault).call(abi.encodeWithSignature("unlockCallback(bytes)", abi.encode(actions, params)));
        assertFalse(ok);

        assertEq(_live(key, pk), l0);
        assertEq(vault.getPosition(pk).liquidity, l0);
        assertEq(vault.getPosition(pk).credit, c0);
        assertEq(t0.balanceOf(address(v4Actor)), b0);
        assertEq(t1.balanceOf(address(v4Actor)), b1);
        assertEq(IERC721(address(posm)).ownerOf(uint256(pk)), address(vault));
    }

    /// @notice Bug hunted: tokens left in the PositionManager (anyone can send them; its SWEEP returns them to whoever
    /// calls next) come back to the vault in a top-up's sweep and are netted against the payer's spend. The vault then
    /// reports less than the pool took, so the payer's minimums misfire, and a stray balance above the amount used
    /// makes every top-up revert. A top-up must report and charge exactly what the pool took.
    function test_addLiquidity_strayTokensInThePositionManagerDoNotSkewTheTopUp() public {
        _checkStrayTokens(key, MARKET, address(t0), address(t1));
        _checkStrayTokens(nativeKey, NATIVE_MARKET, address(weth), address(t1));
    }

    /// @notice Bug hunted: raw ETH left in the PositionManager netted against the payer of a native-pair top-up. The
    /// fee batch that runs first wraps and sweeps that ETH out, except on a position with no live liquidity, where no
    /// fee batch runs; there the increase batch wraps it with the rest and sweeps it to the vault. It must count on
    /// the before side: otherwise a stray above the amount used reverts every top-up of an emptied position, and a
    /// smaller one is reported and charged as if the payer had not paid it.
    function test_addLiquidity_rawEthInThePositionManagerOnAnEmptiedNativePosition() public {
        (bytes32 pk, uint128 l0) = _position(nativeKey, -1200, 1200, 1e20);
        _pledge(pk, NATIVE_MARKET);
        vm.prank(adapter);
        vault.removeLiquidity(pk, l0, 0, 0, recipient);
        assertEq(_live(nativeKey, pk), 0);
        vm.deal(address(posm), 5e18);
        uint256[4] memory before = [
            address(pm).balance, t1.balanceOf(address(pm)), weth.balanceOf(address(this)), t1.balanceOf(address(this))
        ];
        uint256 vaultWeth = weth.balanceOf(address(vault));
        vm.prank(adapter);
        (uint128 added,, uint256 a0, uint256 a1) = vault.addLiquidity(pk, address(this), 1e18, 3e18, 0, 0);
        assertGt(added, 0);
        assertEq(a0, address(pm).balance - before[0], "ETH reported as the pool took it");
        assertEq(a1, t1.balanceOf(address(pm)) - before[1], "token1 reported as the pool took it");
        assertEq(before[2] - weth.balanceOf(address(this)), a0, "payer charged the ETH the pool took");
        assertEq(before[3] - t1.balanceOf(address(this)), a1, "payer charged the token1 the pool took");
        assertEq(weth.balanceOf(address(vault)), vaultWeth + 5e18, "the stray ETH stays in the vault, wrapped");
        assertEq(_live(nativeKey, pk), added);
    }

    /// @notice Bug hunted: a newcomer mints and pledges a wide position, swaps the price far through an earlier LP's
    /// range, then burns, and takes part of the earlier LP's liquidity, credit or fees.
    function test_mintHugeSwapBurn_takesNothingFromEarlierLps() public {
        (bytes32 pk, uint128 l0) = _position(key, -1200, 1200, 1e20);
        uint128 c0 = _pledge(pk, MARKET);
        (bytes32 pkB, uint128 lB) = _position(key, -6000, 6000, 1e21);
        vm.prank(adapter);
        vault.pledge(address(this), makeAddr("attackerAccount"), MARKET, pkB);
        _swapV4To(key, ClTickMath.getSqrtPriceAtTick(5000));
        (uint256 f0, uint256 f1) = vault.feesOf(pk);
        assertGt(f0 + f1, 0);
        vm.startPrank(adapter);
        vault.removeLiquidity(pkB, lB, 0, 0, recipient);
        vault.release(pkB, recipient);
        vm.stopPrank();
        assertEq(_live(key, pk), l0);
        assertEq(vault.getPosition(pk).liquidity, l0);
        assertEq(vault.getPosition(pk).credit, c0);
        assertEq(vault.getMarket(MARKET).totalCredit, c0);
        (uint256 g0, uint256 g1) = vault.feesOf(pk);
        assertEq(g0, f0);
        assertEq(g1, f1);
        bytes32[] memory keys = new bytes32[](1);
        keys[0] = pk;
        address owner = makeAddr("owner");
        vm.prank(adapter);
        vault.collectFees(account, keys, owner);
        assertEq(t0.balanceOf(owner), f0);
        assertEq(t1.balanceOf(owner), f1);
    }

    /// @dev Leaves 5 tokens of each currency (wrapped and raw ETH for a native pair) in the PositionManager, then tops
    /// up by 1 and 3 and checks that the payer paid, and the vault reported, exactly what the PoolManager received.
    function _checkStrayTokens(
        PoolKey memory k,
        uint256 marketId,
        address token0,
        address token1
    ) internal {
        (bytes32 pk, uint128 l0) = _position(k, -1200, 1200, 1e20);
        _pledge(pk, marketId);
        IERC20(token0).transfer(address(posm), 5e18);
        IERC20(token1).transfer(address(posm), 5e18);
        if (Currency.unwrap(k.currency0) == address(0)) vm.deal(address(posm), 5e18);
        uint256[4] memory before = [
            _poolManagerHeld(k, token0),
            IERC20(token1).balanceOf(address(pm)),
            IERC20(token0).balanceOf(address(this)),
            IERC20(token1).balanceOf(address(this))
        ];
        vm.prank(adapter);
        (uint128 added,, uint256 a0, uint256 a1) = vault.addLiquidity(pk, address(this), 1e18, 3e18, 0, 0);
        assertGt(a0, 0);
        assertEq(a0, _poolManagerHeld(k, token0) - before[0], "token0 reported as the pool took it");
        assertEq(a1, IERC20(token1).balanceOf(address(pm)) - before[1], "token1 reported as the pool took it");
        assertEq(before[2] - IERC20(token0).balanceOf(address(this)), a0, "payer charged the token0 the pool took");
        assertEq(before[3] - IERC20(token1).balanceOf(address(this)), a1, "payer charged the token1 the pool took");
        assertEq(vault.getPosition(pk).liquidity, l0 + added);
        assertEq(_live(k, pk), l0 + added);
    }

    /// @dev What the PoolManager holds of the pair's currency0: native ETH for a native pair.
    function _poolManagerHeld(
        PoolKey memory k,
        address token0
    ) internal view returns (uint256) {
        return Currency.unwrap(k.currency0) == address(0) ? address(pm).balance : IERC20(token0).balanceOf(address(pm));
    }

    function _checkAddLiquidity(
        PoolKey memory k,
        uint256 marketId,
        address token0,
        address token1
    ) internal {
        (bytes32 pk, uint128 l0) = _position(k, -1200, 1200, 1e20);
        uint128 c0 = _pledge(pk, marketId);
        uint256 before0 = IERC20(token0).balanceOf(address(this));
        uint256 before1 = IERC20(token1).balanceOf(address(this));
        vm.prank(adapter);
        (uint128 added, uint128 credit, uint256 a0, uint256 a1) =
            vault.addLiquidity(pk, address(this), 1e18, 3e18, 0, 0);
        assertGt(added, 0);
        assertEq(credit, FloorCreditMath.credit(-1200, 1200, BAND_LOWER, BAND_UPPER, added));
        assertEq(before0 - IERC20(token0).balanceOf(address(this)), a0);
        assertEq(before1 - IERC20(token1).balanceOf(address(this)), a1);
        assertLe(a0, 1e18);
        assertLe(a1, 3e18);
        ILPVault.Position memory p = vault.getPosition(pk);
        assertEq(p.liquidity, l0 + added);
        assertEq(p.credit, c0 + credit);
        assertEq(_live(k, pk), p.liquidity);
        assertEq(IERC20(token0).balanceOf(address(vault)), 0);
        assertEq(IERC20(token1).balanceOf(address(vault)), 0);
    }

    /// @dev Swaps `key` to `tick`, then checks that `collectFees` pays exactly `feesOf`, and that some fee was earned.
    function _checkFeesPaid(
        bytes32 pk,
        int24 tick
    ) internal {
        _swapV4To(key, ClTickMath.getSqrtPriceAtTick(tick));
        (uint256 v0, uint256 v1) = vault.feesOf(pk);
        assertGt(v0 + v1, 0, "fees earned on the way");
        uint256 b0 = t0.balanceOf(recipient);
        uint256 b1 = t1.balanceOf(recipient);
        bytes32[] memory keys = new bytes32[](1);
        keys[0] = pk;
        vm.prank(adapter);
        vault.collectFees(account, keys, recipient);
        assertEq(t0.balanceOf(recipient) - b0, v0, "token0 paid as viewed");
        assertEq(t1.balanceOf(recipient) - b1, v1, "token1 paid as viewed");
    }

    function _checkAddToken1Bound(
        PoolKey memory k,
        uint256 marketId,
        address token0,
        address token1
    ) internal {
        (bytes32 pk,) = _position(k, -1200, 1200, 1e20);
        _pledge(pk, marketId);
        uint256 before0 = IERC20(token0).balanceOf(address(this));
        uint256 before1 = IERC20(token1).balanceOf(address(this));
        vm.prank(adapter);
        (uint128 added,, uint256 a0, uint256 a1) = vault.addLiquidity(pk, address(this), 3e18, 1e18, 0, 0);
        assertGt(added, 0);
        assertEq(before0 - IERC20(token0).balanceOf(address(this)), a0);
        assertEq(before1 - IERC20(token1).balanceOf(address(this)), a1);
        assertGt(a1, 1e18 - 1e6, "token1 binds");
        assertLt(a0, 2e18, "the unused token0 comes back");
        assertEq(address(posm).balance, 0, "no ETH left in the PositionManager");
        assertEq(IERC20(token0).balanceOf(address(posm)), 0);
        assertEq(IERC20(token1).balanceOf(address(posm)), 0);
        assertEq(IERC20(token0).balanceOf(address(vault)), 0);
        assertEq(IERC20(token1).balanceOf(address(vault)), 0);
    }

    function _checkRemoveAndFees(
        PoolKey memory k,
        uint256 marketId,
        address token0,
        address token1
    ) internal {
        (bytes32 pk, uint128 l0) = _position(k, -1200, 1200, 1e20);
        uint128 c0 = _pledge(pk, marketId);
        _washV4(k, 1e20);
        (uint256 f0, uint256 f1) = vault.feesOf(pk);
        assertGt(f0 + f1, 0);
        vm.prank(adapter);
        (uint128 removed, uint256 a0, uint256 a1) = vault.removeLiquidity(pk, l0 / 2, 0, 0, recipient);
        assertGt(a0 + a1, 0);
        assertEq(IERC20(token0).balanceOf(recipient), a0);
        assertEq(IERC20(token1).balanceOf(recipient), a1);
        assertEq(vault.getPosition(pk).credit, c0 - removed);
        // The fees taken with the removal are held for the position, and the view still reports them.
        (uint256 g0, uint256 g1) = vault.feesOf(pk);
        assertEq(g0, f0);
        assertEq(g1, f1);
        assertEq(IERC20(token0).balanceOf(address(vault)), f0);
        assertEq(IERC20(token1).balanceOf(address(vault)), f1);
        bytes32[] memory keys = new bytes32[](1);
        keys[0] = pk;
        address owner = makeAddr("owner");
        vm.prank(adapter);
        vault.collectFees(account, keys, owner);
        assertEq(IERC20(token0).balanceOf(owner), f0);
        assertEq(IERC20(token1).balanceOf(owner), f1);
        assertEq(IERC20(token0).balanceOf(address(vault)), 0);
    }

    // ─── Upstream parity (fuzzed) ───

    /// @notice Bug hunted: Avana's own reads of the PoolManager (`UniswapV4State`: the pool and tick slots through
    /// `extsload`, fee growth inside by where the current tick is, the unchecked growth differences), the amounts its
    /// oracle uses or the floor credit drifting from the pinned v4 PoolManager, PositionManager and StateView. A random
    /// sequence of swaps crosses the position's and the band's ticks in both directions (stopping exactly on a tick and
    /// one tick to either side), with top-ups and partial removals (whose fees the vault holds) in between, and the
    /// pool's global fee growth optionally starts at 2^256 − 10^36 so it wraps mid-run. After every step, for a
    /// position inside the band and one on exactly the band: fee growth inside equals StateView's, `feesOf` equals what
    /// `collectFees` pays, the principal equals what the PositionManager pays for the whole liquidity, to the wei, and
    /// the credit's band amounts are worth at most that principal at the pool's price.
    /// forge-config: default.fuzz.runs = 256
    /// forge-config: ci.fuzz.runs = 1000
    function testFuzz_parity_feesPrincipalAndCreditMatchThePositionManager(
        uint256 seed,
        bool wrapGrowth
    ) public {
        PoolKey memory k = _key(address(t0), address(t1), 500, 10);
        _initPool(k, 1e8, 1e8, 18, 18);
        if (wrapGrowth) {
            // Pool.State: slot0, then feeGrowthGlobal0X128 and feeGrowthGlobal1X128.
            bytes32 state = UniswapV4State.poolStateSlot(_poolId(k));
            vm.store(address(pm), bytes32(uint256(state) + 1), bytes32(type(uint256).max - 1e36));
            vm.store(address(pm), bytes32(uint256(state) + 2), bytes32(type(uint256).max - 1e36));
        }
        _mintV4(address(this), k, -887_270, 887_270, 1e20);
        vault.listMarket(PARITY_MARKET, vault.registerPool(_v4Key(k)), BAND_LOWER, BAND_UPPER);

        int24 lo = int24(int256(seed % 1200)) * 10 - 6000;
        int24 hi = lo + 10 + int24(int256((seed >> 16) % uint256(int256((BAND_UPPER - lo) / 10)))) * 10;
        hi = hi > BAND_UPPER ? BAND_UPPER : hi;
        (bytes32 keyA,) = _position(k, lo, hi, 1e20);
        (bytes32 keyB, uint128 lB) = _position(k, BAND_LOWER, BAND_UPPER, 1e20);
        _pledge(keyA, PARITY_MARKET);
        assertEq(_pledge(keyB, PARITY_MARKET), lB, "a position on exactly the band is credited L");

        int24[4] memory edges = [lo, hi, BAND_LOWER, BAND_UPPER];
        for (uint256 i = 0; i < 8; ++i) {
            uint256 r = uint256(keccak256(abi.encode(seed, i)));
            bytes32 pk = (r >> 8) % 2 == 0 ? keyA : keyB;
            uint256 action = r % 5;
            if (action < 3) {
                _swapV4To(k, ClTickMath.getSqrtPriceAtTick(_parityTarget(r >> 16, edges)));
            } else if (action == 3) {
                vm.prank(adapter);
                vault.addLiquidity(pk, address(this), 1e17, 1e17, 0, 0);
            } else {
                uint128 l = vault.getPosition(pk).liquidity / 3;
                if (l > 0) {
                    vm.prank(adapter);
                    vault.removeLiquidity(pk, l, 0, 0, recipient);
                }
            }
            _checkV4Parity(k, keyA, lo, hi);
            _checkV4Parity(k, keyB, BAND_LOWER, BAND_UPPER);
        }
    }

    function _checkV4Parity(
        PoolKey memory k,
        bytes32 pk,
        int24 lower,
        int24 upper
    ) internal {
        {
            (uint256 in0, uint256 in1) =
                UniswapV4State.feeGrowthInside(IUniswapV4PoolManager(address(pm)), _poolId(k), lower, upper);
            (uint256 up0, uint256 up1) = IV4StateView(stateView).getFeeGrowthInside(_poolId(k), lower, upper);
            assertEq(in0, up0, "fee growth inside token0 differs from StateView");
            assertEq(in1, up1, "fee growth inside token1 differs from StateView");
        }
        (uint256 f0, uint256 f1) = vault.feesOf(pk);
        (uint160 s,) = _slot0V4(k);
        uint128 live = _live(k, pk);
        uint256 snap = vm.snapshotState();
        address probe = makeAddr("parityProbe");
        bytes32[] memory keys = new bytes32[](1);
        keys[0] = pk;
        vm.prank(adapter);
        vault.collectFees(account, keys, probe);
        assertEq(t0.balanceOf(probe), f0, "feesOf token0 differs from what collectFees pays");
        assertEq(t1.balanceOf(probe), f1, "feesOf token1 differs from what collectFees pays");
        uint256 p0;
        uint256 p1;
        if (live > 0) {
            bytes[] memory params = new bytes[](2);
            params[0] = abi.encode(uint256(pk), uint256(live), uint128(0), uint128(0), bytes(""));
            params[1] = abi.encode(address(t0), address(t1), probe);
            vm.prank(address(vault));
            posm.modifyLiquidities(abi.encode(abi.encodePacked(uint8(0x01), uint8(0x11)), params), block.timestamp);
            (p0, p1) = (t0.balanceOf(probe) - f0, t1.balanceOf(probe) - f1);
        }
        vm.revertToState(snap);
        (uint256 a0, uint256 a1) =
            LPPriceMath.amounts(s, ClTickMath.getSqrtPriceAtTick(lower), ClTickMath.getSqrtPriceAtTick(upper), live);
        assertEq(a0, p0, "position amount0 differs from the PositionManager's decrease");
        assertEq(a1, p1, "position amount1 differs from the PositionManager's decrease");
        _checkCreditWithin(vault, pk, PARITY_MARKET, s, p0, p1);
    }

    /// @dev A swap target: one of the edges or a tick in [-9000, 9000], then moved by -1, 0 or +1 tick.
    function _parityTarget(
        uint256 r,
        int24[4] memory edges
    ) internal pure returns (int24 t) {
        uint256 idx = r % 5;
        t = idx < 4 ? edges[idx] : int24(int256((r >> 8) % 18_001)) - 9000;
        t += int24(int256((r >> 40) % 3)) - 1;
    }

    function _position(
        PoolKey memory k,
        int24 lower,
        int24 upper,
        uint128 liquidity
    ) internal returns (bytes32 pk, uint128 live) {
        pk = bytes32(_mintV4(address(this), k, lower, upper, liquidity));
        live = _live(k, pk);
        assertEq(live, liquidity);
    }

    function _pledge(
        bytes32 pk,
        uint256 marketId
    ) internal returns (uint128 credit) {
        vm.prank(adapter);
        credit = vault.pledge(address(this), account, marketId, pk);
    }

    function _live(
        PoolKey memory k,
        bytes32 pk
    ) internal view returns (uint128) {
        (, uint256 info) = posm.getPoolAndPositionInfo(uint256(pk));
        // 24-bit two's-complement fields at offsets 8 and 32.
        // forge-lint: disable-next-line(unsafe-typecast)
        int24 lower = int24(int256(info >> 8));
        // forge-lint: disable-next-line(unsafe-typecast)
        int24 upper = int24(int256(info >> 32));
        return UniswapV4State.positionLiquidity(
            IUniswapV4PoolManager(address(pm)), _poolId(k), UniswapV4State.positionId(address(posm), lower, upper, pk)
        );
    }

    function _v4Key(
        PoolKey memory k
    ) internal pure returns (UniswapV4PoolKey memory) {
        return UniswapV4PoolKey(
            Currency.unwrap(k.currency0), Currency.unwrap(k.currency1), k.fee, k.tickSpacing, address(k.hooks)
        );
    }
}

/// @dev A subscriber whose `notifyUnsubscribe` calls `target` with `data` and keeps the outcome.
contract ReenteringSubscriber is V4TestSubscriber {
    address internal immutable TARGET;
    bytes internal data;
    bool public unsubscribed;
    bool public reentryOk;
    bytes public reentryReturn;

    constructor(
        address target,
        bytes memory data_
    ) {
        (TARGET, data) = (target, data_);
    }

    function notifyUnsubscribe(
        uint256
    ) external override {
        unsubscribed = true;
        (reentryOk, reentryReturn) = TARGET.call(data);
    }
}

/// @dev A PositionManager that names the given PoolManager and WETH and has nothing else.
contract V4PositionManagerStub {
    address public immutable poolManager;
    address public immutable WETH9;

    constructor(
        address poolManager_,
        address weth_
    ) {
        poolManager = poolManager_;
        WETH9 = weth_;
    }
}
