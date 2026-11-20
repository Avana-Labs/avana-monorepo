// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ClTickMath} from "../../src/integrations/shared/ClTickMath.sol";
import {IUniswapV4Integration} from "../../src/integrations/uniswap-v4/interfaces/IUniswapV4Integration.sol";
import {UniswapV4Integration} from "../../src/integrations/uniswap-v4/UniswapV4Integration.sol";
import {UniswapV4State} from "../../src/integrations/uniswap-v4/UniswapV4State.sol";
import {ILPVault} from "../../src/vault/interfaces/ILPVault.sol";
import {FloorCreditMath} from "../../src/vault/libraries/FloorCreditMath.sol";
import {
    IUniswapV4PoolManager,
    UniswapV4PoolKey
} from "../../src/dependencies/uniswap-v4/IUniswapV4PoolManager.sol";
import {ClTestToken} from "../utils/fixtures/ClPoolFixture.sol";
import {UniswapV4WorldFixture} from "../utils/fixtures/UniswapV4WorldFixture.sol";
import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// @notice The Uniswap v4 LPVault on the real PoolManager and PositionManager: pledge, top-up, partial removal with
/// fees held for the position, unwind, fee collection and release, on an ERC-20 pair and on a native-ETH pair.
contract LPVaultUniswapV4IntegrationTest is UniswapV4WorldFixture {
    uint64 internal constant ADAPTER_ROLE = 11;
    uint64 internal constant LIQUIDATION_ROLE = 12;
    int24 internal constant BAND_LOWER = -6000;
    int24 internal constant BAND_UPPER = 6000;
    uint256 internal constant MARKET = 1;
    uint256 internal constant NATIVE_MARKET = 2;

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
