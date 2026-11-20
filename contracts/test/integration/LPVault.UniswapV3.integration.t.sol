// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {INonfungiblePositionManager} from "../../src/dependencies/uniswap/INonfungiblePositionManager.sol";
import {ClTickMath} from "../../src/integrations/shared/ClTickMath.sol";
import {INfpmPositions} from "../../src/integrations/shared/interfaces/INfpmPositions.sol";
import {UniswapV3Integration} from "../../src/integrations/uniswap-v3/UniswapV3Integration.sol";
import {ILPVault} from "../../src/vault/interfaces/ILPVault.sol";
import {FloorCreditMath} from "../../src/vault/libraries/FloorCreditMath.sol";
import {ClPoolFixture, ClTestToken, IClPool} from "../utils/fixtures/ClPoolFixture.sol";
import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";

/// @notice The Uniswap v3 LPVault on the real factory, pools and NonfungiblePositionManager of the pinned releases:
/// band check, floor credit, top-up through the NFPM, partial and full release, unwind and per-position fees.
contract LPVaultUniswapV3IntegrationTest is ClPoolFixture {
    uint64 internal constant ADAPTER_ROLE = 11;
    uint64 internal constant LIQUIDATION_ROLE = 12;
    uint24 internal constant FEE = 3000;
    int24 internal constant BAND_LOWER = -6000;
    int24 internal constant BAND_UPPER = 6000;
    uint256 internal constant MARKET = 1;

    INonfungiblePositionManager internal nfpm;
    UniswapV3Integration internal vault;
    AccessManager internal am;
    IClPool internal pool;
    ClTestToken internal t0;
    ClTestToken internal t1;

    address internal adapter = makeAddr("adapter");
    address internal liquidator = makeAddr("liquidator");
    address internal lp = makeAddr("lp");
    address internal account = makeAddr("account");
    address internal recipient = makeAddr("recipient");

    function setUp() public {
        _deployFactory();
        (ClTestToken a, ClTestToken b, bool aIsToken0) = _sortedTokens("TKA", 18, "TKB", 18);
        (t0, t1) = aIsToken0 ? (a, b) : (b, a);
        pool = _createPool(t0, t1, FEE, 1e8, 1e8, 1, 1e18);
        nfpm = INonfungiblePositionManager(
            _constructInPlace(
                makeAddr("NonfungiblePositionManager"),
                bytes.concat(
                    vm.getCode("out-univ3-periphery/NonfungiblePositionManager.sol/NonfungiblePositionManager.json"),
                    abi.encode(address(factory), makeAddr("WETH9"), address(0))
                )
            )
        );
        am = new AccessManager(address(this));
        vault = new UniswapV3Integration(address(am), address(nfpm), address(factory));
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
        vault.listMarket(MARKET, _word(address(pool)), BAND_LOWER, BAND_UPPER);

        t0.mint(lp, 1e30);
        t1.mint(lp, 1e30);
        vm.startPrank(lp);
        t0.approve(address(nfpm), type(uint256).max);
        t1.approve(address(nfpm), type(uint256).max);
        t0.approve(address(vault), type(uint256).max);
        t1.approve(address(vault), type(uint256).max);
        nfpm.setApprovalForAll(address(vault), true);
        vm.stopPrank();
    }

    function test_constructor_refusesAMismatchedFactory() public {
        vm.expectRevert(ILPVault.InvalidDeployment.selector);
        new UniswapV3Integration(address(am), address(nfpm), makeAddr("otherFactory"));
        vm.expectRevert(ILPVault.InvalidDeployment.selector);
        new UniswapV3Integration(address(0), address(nfpm), address(factory));
    }

    function test_listMarket_refusesANonCanonicalPool() public {
        // A contract that is not a pool fails its first pool read.
        bytes32 fake = _word(address(new ClTestToken("X", 18)));
        vm.expectRevert();
        vault.listMarket(2, fake, BAND_LOWER, BAND_UPPER);
        bytes32 eoa = _word(makeAddr("notAContract"));
        vm.expectRevert(abi.encodeWithSelector(ILPVault.InvalidPool.selector, eoa));
        vault.listMarket(2, eoa, BAND_LOWER, BAND_UPPER);
        bytes32 dirty = bytes32(uint256(_word(address(pool))) | (uint256(1) << 200));
        vm.expectRevert(abi.encodeWithSelector(ILPVault.InvalidPool.selector, dirty));
        vault.listMarket(2, dirty, BAND_LOWER, BAND_UPPER);
        bytes32 tenSpacing = _word(address(_createPool(t0, t1, 500, 1e8, 1e8, 1, 0)));
        vm.expectRevert(abi.encodeWithSelector(ILPVault.InvalidBand.selector, int24(-6005), BAND_UPPER));
        vault.listMarket(2, tenSpacing, -6005, BAND_UPPER);
        vault.listMarket(2, tenSpacing, -6010, BAND_UPPER);
        ILPVault.Market memory m = vault.getMarket(MARKET);
        assertEq(m.token0, address(t0));
        assertEq(m.token1, address(t1));
    }

    function test_pledge_creditsTheFloorInRangeOrNot() public {
        (bytes32 inRange, uint128 lIn) = _mintPosition(-600, 600);
        (bytes32 above, uint128 lAbove) = _mintPosition(1200, 6000);
        uint128 cIn = _pledge(inRange);
        uint128 cAbove = _pledge(above);
        assertEq(cIn, FloorCreditMath.credit(-600, 600, BAND_LOWER, BAND_UPPER, lIn));
        assertEq(cAbove, FloorCreditMath.credit(1200, 6000, BAND_LOWER, BAND_UPPER, lAbove));
        assertEq(nfpm.ownerOf(uint256(inRange)), address(vault));
        assertEq(vault.getMarket(MARKET).totalCredit, uint256(cIn) + cAbove);
    }

    function test_pledge_refusesAPositionLeavingTheBand() public {
        (bytes32 key,) = _mintPosition(-6600, 600);
        vm.prank(adapter);
        vm.expectRevert(
            abi.encodeWithSelector(
                FloorCreditMath.NotInsideBand.selector, int24(-6600), int24(600), BAND_LOWER, BAND_UPPER
            )
        );
        vault.pledge(lp, account, MARKET, key);
    }

    function test_pledge_refusesAnotherPoolsPosition() public {
        IClPool other = _createPool(t0, t1, 500, 1e8, 1e8, 1, 1e18);
        vm.prank(lp);
        (uint256 tokenId, uint128 liquidity,,) = nfpm.mint(
            INonfungiblePositionManager.MintParams({
                token0: address(t0),
                token1: address(t1),
                fee: 500,
                tickLower: -600,
                tickUpper: 600,
                amount0Desired: 1e18,
                amount1Desired: 1e18,
                amount0Min: 0,
                amount1Min: 0,
                recipient: lp,
                deadline: block.timestamp
            })
        );
        assertGt(liquidity, 0);
        vm.prank(adapter);
        vm.expectRevert(abi.encodeWithSelector(ILPVault.PoolMismatch.selector, bytes32(tokenId), _word(address(other))));
        vault.pledge(lp, account, MARKET, bytes32(tokenId));
    }

    function test_addLiquidity_throughTheNfpmAsOwner() public {
        (bytes32 key, uint128 l0) = _mintPosition(-1200, 1200);
        uint128 c0 = _pledge(key);
        uint256 before0 = t0.balanceOf(lp);
        uint256 before1 = t1.balanceOf(lp);
        vm.prank(adapter);
        (uint128 added, uint128 credit, uint256 a0, uint256 a1) = vault.addLiquidity(key, lp, 2e18, 3e18, 0, 0);
        assertGt(added, 0);
        assertEq(credit, FloorCreditMath.credit(-1200, 1200, BAND_LOWER, BAND_UPPER, added));
        assertEq(before0 - t0.balanceOf(lp), a0);
        assertEq(before1 - t1.balanceOf(lp), a1);
        assertEq(t0.balanceOf(address(vault)), 0);
        assertEq(t1.balanceOf(address(vault)), 0);
        ILPVault.Position memory p = vault.getPosition(key);
        assertEq(p.liquidity, l0 + added);
        assertEq(p.credit, c0 + credit);
        assertLe(p.credit, FloorCreditMath.credit(-1200, 1200, BAND_LOWER, BAND_UPPER, p.liquidity));
        assertEq(INfpmPositions(address(nfpm)).positions(uint256(key)).liquidity, p.liquidity);
    }

    function test_removeLiquidity_partialThenRelease() public {
        (bytes32 key, uint128 l0) = _mintPosition(-1200, 1200);
        uint128 c0 = _pledge(key);
        vm.prank(adapter);
        (uint128 removed, uint256 a0, uint256 a1) = vault.removeLiquidity(key, l0 / 4, 0, 0, recipient);
        assertGt(a0, 0);
        assertGt(a1, 0);
        assertEq(t0.balanceOf(recipient), a0);
        assertEq(t1.balanceOf(recipient), a1);
        ILPVault.Position memory p = vault.getPosition(key);
        assertEq(p.liquidity, l0 - l0 / 4);
        assertEq(p.credit, c0 - removed);
        assertEq(t0.balanceOf(address(vault)), 0);
        vm.prank(adapter);
        uint128 rest = vault.release(key, lp);
        assertEq(rest, p.credit);
        assertEq(nfpm.ownerOf(uint256(key)), lp);
        assertEq(vault.getMarket(MARKET).totalCredit, 0);
    }

    function test_unwind_sendsBothTokensToTheLiquidator() public {
        (bytes32 key,) = _mintPosition(-1200, 1200);
        uint128 c0 = _pledge(key);
        vm.prank(liquidator);
        (uint128 liquidity, uint128 creditRemoved, uint256 a0, uint256 a1) = vault.unwind(key, c0 / 2, 0, 0, recipient);
        assertGt(liquidity, 0);
        assertGe(creditRemoved, c0 / 2);
        assertEq(t0.balanceOf(recipient), a0);
        assertEq(t1.balanceOf(recipient), a1);
        assertGt(a0 + a1, 0);
    }

    function test_fees_viewMatchesCollectOnSeveralPositions() public {
        (bytes32 a,) = _mintPosition(-1200, 1200);
        (bytes32 b,) = _mintPosition(-600, 1800);
        (bytes32 c,) = _mintPosition(3000, 6000);
        uint128 ca = _pledge(a);
        _pledge(b);
        _pledge(c);
        _trade();
        (uint256 fa0, uint256 fa1) = vault.feesOf(a);
        (uint256 fb0, uint256 fb1) = vault.feesOf(b);
        (uint256 fc0, uint256 fc1) = vault.feesOf(c);
        assertGt(fa0 + fa1, 0);
        assertGt(fb0 + fb1, 0);
        assertEq(fc0 + fc1, 0);
        bytes32[] memory keys = new bytes32[](3);
        (keys[0], keys[1], keys[2]) = (a, b, c);
        vm.prank(adapter);
        (uint256[] memory f0, uint256[] memory f1) = vault.collectFees(account, keys, recipient);
        assertEq(f0[0], fa0);
        assertEq(f1[0], fa1);
        assertEq(f0[1], fb0);
        assertEq(f1[1], fb1);
        assertEq(t0.balanceOf(recipient), fa0 + fb0);
        assertEq(t1.balanceOf(recipient), fa1 + fb1);
        assertEq(vault.getPosition(a).credit, ca);
        (fa0, fa1) = vault.feesOf(a);
        assertEq(fa0 + fa1, 0);
    }

    /// @notice A position opened after the pool earned fees, then left above and below by the price: at each stop the
    /// view equals what the NonfungiblePositionManager pays, so the fees reported for an out-of-range position (above:
    /// growth `upper - lower`, below: `lower - upper`, back inside after both ticks were crossed) are the real ones.
    function test_fees_viewMatchesCollectAboveBelowAndBackInRange() public {
        _trade();
        (bytes32 k,) = _mintPosition(-600, 600);
        _pledge(k);
        _checkFeesPaid(k, 1500);
        _checkFeesPaid(k, -1500);
        _checkFeesPaid(k, 0);
    }

    /// @dev Swaps to `tick`, then checks that `collectFees` pays exactly `feesOf`, and that some fee was earned.
    function _checkFeesPaid(
        bytes32 k,
        int24 tick
    ) internal {
        _swapTo(pool, ClTickMath.getSqrtPriceAtTick(tick));
        (uint256 v0, uint256 v1) = vault.feesOf(k);
        assertGt(v0 + v1, 0, "fees earned on the way");
        uint256 b0 = t0.balanceOf(recipient);
        uint256 b1 = t1.balanceOf(recipient);
        bytes32[] memory keys = new bytes32[](1);
        keys[0] = k;
        vm.prank(adapter);
        vault.collectFees(account, keys, recipient);
        assertEq(t0.balanceOf(recipient) - b0, v0, "token0 paid as viewed");
        assertEq(t1.balanceOf(recipient) - b1, v1, "token1 paid as viewed");
    }

    function test_fees_stayWithThePositionThroughAPartialRemoval() public {
        (bytes32 key, uint128 l0) = _mintPosition(-1200, 1200);
        _pledge(key);
        _trade();
        (uint256 f0, uint256 f1) = vault.feesOf(key);
        vm.prank(adapter);
        (, uint256 a0, uint256 a1) = vault.removeLiquidity(key, l0 / 2, 0, 0, recipient);
        assertEq(t0.balanceOf(recipient), a0);
        assertEq(t1.balanceOf(recipient), a1);
        (uint256 g0, uint256 g1) = vault.feesOf(key);
        assertEq(g0, f0);
        assertEq(g1, f1);
    }

    function _mintPosition(
        int24 tickLower,
        int24 tickUpper
    ) internal returns (bytes32 key, uint128 liquidity) {
        uint256 tokenId;
        vm.prank(lp);
        (tokenId, liquidity,,) = nfpm.mint(
            INonfungiblePositionManager.MintParams({
                token0: address(t0),
                token1: address(t1),
                fee: FEE,
                tickLower: tickLower,
                tickUpper: tickUpper,
                amount0Desired: 1e18,
                amount1Desired: 1e18,
                amount0Min: 0,
                amount1Min: 0,
                recipient: lp,
                deadline: block.timestamp
            })
        );
        key = bytes32(tokenId);
    }

    function _pledge(
        bytes32 key
    ) internal returns (uint128 credit) {
        vm.prank(adapter);
        credit = vault.pledge(lp, account, MARKET, key);
    }

    /// @dev Moves the price up and back inside `[-1200, 1200]`, which pays fees to the positions around tick 0.
    function _trade() internal {
        _swapTo(pool, ClTickMath.getSqrtPriceAtTick(900));
        _swapTo(pool, ClTickMath.getSqrtPriceAtTick(-900));
        _swapTo(pool, ClTickMath.getSqrtPriceAtTick(0));
    }

    function _word(
        address a
    ) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(a)));
    }

    function _constructInPlace(
        address at,
        bytes memory initCode
    ) internal returns (address) {
        vm.etch(at, initCode);
        (bool ok, bytes memory runtime) = at.call("");
        require(ok && runtime.length != 0, "constructor reverted");
        vm.etch(at, runtime);
        return at;
    }
}
