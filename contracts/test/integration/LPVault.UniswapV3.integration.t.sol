// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {INonfungiblePositionManager} from "../../src/dependencies/uniswap/INonfungiblePositionManager.sol";
import {UniswapV3Integration} from "../../src/integrations/UniswapV3Integration.sol";
import {ILPVault} from "../../src/interfaces/ILPVault.sol";
import {INfpmPositions} from "../../src/interfaces/INfpmPositions.sol";
import {ClTickMath} from "../../src/libraries/ClTickMath.sol";
import {FloorCreditMath} from "../../src/libraries/FloorCreditMath.sol";
import {AmmParityChecks} from "../utils/AmmParityChecks.sol";
import {ClPoolFixture, ClTestToken, IClPool} from "../utils/fixtures/ClPoolFixture.sol";
import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";

/// @notice The pool reads the parity fuzz makes beyond `IClPool`.
interface IV3PoolGrowth {
    function feeGrowthGlobal1X128() external view returns (uint256);
}

/// @notice The Uniswap v3 LPVault on the real factory, pools and NonfungiblePositionManager of the pinned releases:
/// band check, floor credit, top-up through the NFPM, partial and full release, unwind and per-position fees.
contract LPVaultUniswapV3IntegrationTest is ClPoolFixture, AmmParityChecks {
    uint64 internal constant ADAPTER_ROLE = 11;
    uint64 internal constant LIQUIDATION_ROLE = 12;
    uint24 internal constant FEE = 3000;
    int24 internal constant BAND_LOWER = -6000;
    int24 internal constant BAND_UPPER = 6000;
    uint256 internal constant MARKET = 1;
    uint24 internal constant PARITY_FEE = 500;
    uint256 internal constant PARITY_MARKET = 2;

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

    /// @notice Bug hunted: a constructor that accepts a zero, code-less or self-referencing NFPM or factory. Every
    /// pledge reads positions from the NFPM and checks pools against the factory, so such a vault could never price
    /// a position, or would trust whatever answers at that address.
    function test_constructor_refusesAZeroCodelessOrSameNfpmAndFactory() public {
        vm.expectRevert(ILPVault.InvalidDeployment.selector);
        new UniswapV3Integration(address(am), address(0), address(factory));
        vm.expectRevert(ILPVault.InvalidDeployment.selector);
        new UniswapV3Integration(address(am), address(nfpm), address(0));
        vm.expectRevert(ILPVault.InvalidDeployment.selector);
        new UniswapV3Integration(address(am), address(nfpm), address(nfpm));
        vm.expectRevert(ILPVault.InvalidDeployment.selector);
        new UniswapV3Integration(address(am), makeAddr("codelessNfpm"), address(factory));
    }

    /// @notice Bug hunted: a look-alike pool listed as a market. A contract that answers the pool reads with the real
    /// tokens, fee and tick spacing, but is not the factory's pool (or names another factory), would let its owner
    /// set the price and fee growth the vault reads.
    function test_listMarket_refusesALookAlikePool() public {
        bytes32 otherFactory = _word(address(new LookAlikeV3Pool(pool, FEE, makeAddr("otherFactory"))));
        vm.expectRevert(abi.encodeWithSelector(ILPVault.InvalidPool.selector, otherFactory));
        vault.listMarket(2, otherFactory, BAND_LOWER, BAND_UPPER);
        bytes32 sameFactory = _word(address(new LookAlikeV3Pool(pool, FEE, address(factory))));
        vm.expectRevert(abi.encodeWithSelector(ILPVault.InvalidPool.selector, sameFactory));
        vault.listMarket(2, sameFactory, BAND_LOWER, BAND_UPPER);
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

    /// @notice Bug hunted: fees of an NFPM position whose liquidity was all removed are reported or paid twice. With
    /// no live liquidity the view must read only what the vault holds for the position and what the NFPM still owes,
    /// and one collect must pay exactly that, with nothing left for a second.
    function test_fees_ofADrainedPositionArePaidOnce() public {
        (bytes32 key, uint128 l0) = _mintPosition(-1200, 1200);
        _pledge(key);
        _trade();
        (uint256 f0, uint256 f1) = vault.feesOf(key);
        assertGt(f0 + f1, 0);
        vm.prank(adapter);
        vault.removeLiquidity(key, l0, 0, 0, recipient);
        (uint256 g0, uint256 g1) = vault.feesOf(key);
        assertEq(g0, f0, "token0 fees after the drain");
        assertEq(g1, f1, "token1 fees after the drain");
        bytes32[] memory keys = new bytes32[](1);
        keys[0] = key;
        address owner = makeAddr("owner");
        vm.startPrank(adapter);
        vault.collectFees(account, keys, owner);
        vault.collectFees(account, keys, owner);
        vm.stopPrank();
        assertEq(t0.balanceOf(owner), f0);
        assertEq(t1.balanceOf(owner), f1);
        (g0, g1) = vault.feesOf(key);
        assertEq(g0 + g1, 0);
    }

    // ─── Custody and position identity ───

    /// @notice Bug hunted: an out-of-range token ID (never minted, or a key past every ID) reads as an empty position
    /// and gets a record or credit without custody. The real NFPM refuses the read, so pledge and preview revert.
    function test_pledge_refusesAnIdTheNfpmNeverMinted() public {
        bytes32[2] memory keys = [bytes32(uint256(999)), bytes32(type(uint256).max)];
        for (uint256 i; i < keys.length; ++i) {
            vm.prank(adapter);
            vm.expectRevert(bytes("Invalid token ID"));
            vault.pledge(lp, account, MARKET, keys[i]);
            vm.expectRevert(bytes("Invalid token ID"));
            vault.previewCredit(MARKET, keys[i]);
        }
    }

    /// @notice Bug hunted: a position its owner already transferred away is pledged for the old owner, or a position
    /// the vault holds is pledged again under a second record.
    function test_pledge_refusesATransferredOrAlreadyPledgedPosition() public {
        (bytes32 key,) = _mintPosition(-600, 600);
        address buyer = makeAddr("buyer");
        vm.prank(lp);
        nfpm.transferFrom(lp, buyer, uint256(key));
        vm.prank(adapter);
        vm.expectRevert(abi.encodeWithSelector(ILPVault.NotTokenOwner.selector, key));
        vault.pledge(lp, account, MARKET, key);

        vm.prank(buyer);
        nfpm.setApprovalForAll(address(vault), true);
        vm.prank(adapter);
        uint128 credit = vault.pledge(buyer, account, MARKET, key);
        address[2] memory froms = [buyer, address(vault)];
        for (uint256 i; i < froms.length; ++i) {
            vm.prank(adapter);
            vm.expectRevert(abi.encodeWithSelector(ILPVault.AlreadyPledged.selector, key));
            vault.pledge(froms[i], makeAddr("secondAccount"), MARKET, key);
        }
        assertEq(vault.getMarket(MARKET).totalCredit, credit);
        assertEq(vault.positionsOf(makeAddr("secondAccount")).length, 0);
    }

    /// @notice Bug hunted: an NFT sent straight to the vault, with no pledge, gets a record or credit, or a way out to
    /// someone. `safeTransferFrom` is refused (the vault has no receiver hook); a plain transfer leaves it with no
    /// record, and neither a pledge nor a release can move it.
    function test_unsolicitedNft_getsNoRecordAndCannotBeTakenOut() public {
        (bytes32 key,) = _mintPosition(-600, 600);
        vm.prank(lp);
        vm.expectRevert();
        nfpm.safeTransferFrom(lp, address(vault), uint256(key));
        vm.prank(lp);
        nfpm.transferFrom(lp, address(vault), uint256(key));
        assertEq(vault.getPosition(key).account, address(0));
        vm.startPrank(adapter);
        vm.expectRevert(abi.encodeWithSelector(ILPVault.NotTokenOwner.selector, key));
        vault.pledge(address(vault), account, MARKET, key);
        vm.expectRevert(abi.encodeWithSelector(ILPVault.NotTokenOwner.selector, key));
        vault.pledge(lp, account, MARKET, key);
        vm.expectRevert(abi.encodeWithSelector(ILPVault.NotPledged.selector, key));
        vault.release(key, lp);
        vm.stopPrank();
        vm.prank(liquidator);
        vm.expectRevert(abi.encodeWithSelector(ILPVault.NotPledged.selector, key));
        vault.unwind(key, 1, 0, 0, liquidator);
        assertEq(vault.getMarket(MARKET).totalCredit, 0);
        assertEq(nfpm.ownerOf(uint256(key)), address(vault));
    }

    /// @notice Bug hunted: a release to a contract runs its ERC-721 receiver hook, which re-enters the vault to take
    /// another position. The vault moves NFTs only by `transferFrom`, so no hook runs.
    function test_release_toAContractRunsNoReceiverHook() public {
        (bytes32 key,) = _mintPosition(-600, 600);
        (bytes32 other,) = _mintPosition(-1200, 1200);
        _pledge(key);
        _pledge(other);
        ReenteringReceiver receiver =
            new ReenteringReceiver(address(vault), abi.encodeCall(ILPVault.release, (other, makeAddr("thief"))));
        am.grantRole(ADAPTER_ROLE, address(receiver), 0);
        vm.prank(adapter);
        vault.release(key, address(receiver));
        assertEq(nfpm.ownerOf(uint256(key)), address(receiver));
        assertFalse(receiver.called());
        assertEq(nfpm.ownerOf(uint256(other)), address(vault));
        assertEq(vault.getPosition(other).account, account);
    }

    /// @notice Bug hunted: `increaseLiquidity` called straight on the NFPM for a pledged NFT (the NFPM lets anyone)
    /// inflates the credit, a later Avana top-up counts it twice, or an unwind takes it. The record and market credit do
    /// not move, the top-up is credited its own liquidity alone, an unwind of all the credit removes only the record's
    /// liquidity, and the release returns the NFT with the rest.
    function test_directIncreaseLiquidity_isNotCreditedAndStaysWithTheNft() public {
        (bytes32 key, uint128 l0) = _mintPosition(-1200, 1200);
        uint128 c0 = _pledge(key);
        address stranger = makeAddr("stranger");
        t0.mint(stranger, 1e20);
        t1.mint(stranger, 1e20);
        vm.startPrank(stranger);
        t0.approve(address(nfpm), type(uint256).max);
        t1.approve(address(nfpm), type(uint256).max);
        (uint128 extra,,) = nfpm.increaseLiquidity(
            INonfungiblePositionManager.IncreaseLiquidityParams({
                tokenId: uint256(key),
                amount0Desired: 1e18,
                amount1Desired: 1e18,
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp
            })
        );
        vm.stopPrank();
        assertGt(extra, 0);
        ILPVault.Position memory p = vault.getPosition(key);
        assertEq(p.liquidity, l0);
        assertEq(p.credit, c0);
        assertEq(vault.getMarket(MARKET).totalCredit, c0);
        (,,, uint128 live) = vault.positionInfo(key);
        assertEq(live, l0 + extra);

        vm.prank(adapter);
        (uint128 added, uint128 credit,,) = vault.addLiquidity(key, lp, 1e18, 1e18, 0, 0);
        assertEq(credit, FloorCreditMath.credit(-1200, 1200, BAND_LOWER, BAND_UPPER, added));
        assertEq(vault.getPosition(key).liquidity, l0 + added);
        assertEq(vault.getMarket(MARKET).totalCredit, c0 + credit);

        vm.prank(liquidator);
        vault.unwind(key, type(uint128).max, 0, 0, recipient);
        (,,, live) = vault.positionInfo(key);
        assertEq(live, extra);
        assertEq(vault.getMarket(MARKET).totalCredit, 0);
        vm.prank(adapter);
        vault.release(key, lp);
        assertEq(nfpm.ownerOf(uint256(key)), lp);
        assertEq(INfpmPositions(address(nfpm)).positions(uint256(key)).liquidity, extra);
    }

    /// @notice Bug hunted: a newcomer mints and pledges a wide position, swaps the price far through an earlier LP's
    /// range, then burns, and takes part of the earlier LP's liquidity, credit or fees.
    function test_mintHugeSwapBurn_takesNothingFromEarlierLps() public {
        (bytes32 key, uint128 l0) = _mintPosition(-1200, 1200);
        uint128 c0 = _pledge(key);
        (bytes32 keyB, uint128 lB) = _mintPosition(-6000, 6000);
        address attackerAccount = makeAddr("attackerAccount");
        vm.prank(adapter);
        vault.pledge(lp, attackerAccount, MARKET, keyB);
        _swapTo(pool, ClTickMath.getSqrtPriceAtTick(5000));
        (uint256 f0, uint256 f1) = vault.feesOf(key);
        assertGt(f0 + f1, 0);
        vm.startPrank(adapter);
        vault.removeLiquidity(keyB, lB, 0, 0, recipient);
        vault.release(keyB, lp);
        vm.stopPrank();

        ILPVault.Position memory p = vault.getPosition(key);
        assertEq(p.liquidity, l0);
        assertEq(p.credit, c0);
        assertEq(vault.getMarket(MARKET).totalCredit, c0);
        assertEq(INfpmPositions(address(nfpm)).positions(uint256(key)).liquidity, l0);
        (uint256 g0, uint256 g1) = vault.feesOf(key);
        assertEq(g0, f0);
        assertEq(g1, f1);
        bytes32[] memory keys = new bytes32[](1);
        keys[0] = key;
        address owner = makeAddr("owner");
        vm.prank(adapter);
        vault.collectFees(account, keys, owner);
        assertEq(t0.balanceOf(owner), f0);
        assertEq(t1.balanceOf(owner), f1);
    }

    // ─── Upstream parity (fuzzed) ───

    /// @notice Bug hunted: Avana's own fee-growth arithmetic (`NfpmLPVault._uncollectedFees`: growth inside from the
    /// outside values of both ticks, by where the current tick is), the amounts its oracle uses (`LPPriceMath.amounts`)
    /// or the floor credit drifting from the pinned Uniswap v3 pool and NonfungiblePositionManager. A random sequence of
    /// swaps crosses the position's and the band's ticks in both directions (stopping exactly on a tick and one tick to
    /// either side too), with top-ups and partial removals in between, and the pool's global fee growth optionally
    /// starts at 2^256 − 10^36 so it wraps mid-run. After every step, for a position inside the band and one on exactly
    /// the band: fees and principal equal what the manager pays, to the wei, and the credit's band amounts are worth at
    /// most the principal at the pool's price.
    /// forge-config: default.fuzz.runs = 256
    /// forge-config: ci.fuzz.runs = 1000
    function testFuzz_parity_feesPrincipalAndCreditMatchTheNfpm(
        uint256 seed,
        bool wrapGrowth
    ) public {
        IClPool p = IClPool(factory.createPool(address(t0), address(t1), PARITY_FEE));
        p.initialize(ClTickMath.getSqrtPriceAtTick(0));
        if (wrapGrowth) {
            // UniswapV3Pool storage: slot0 at 0, feeGrowthGlobal0X128 at 1, feeGrowthGlobal1X128 at 2.
            vm.store(address(p), bytes32(uint256(1)), bytes32(type(uint256).max - 1e36));
            vm.store(address(p), bytes32(uint256(2)), bytes32(type(uint256).max - 1e36));
            assertEq(IV3PoolGrowth(address(p)).feeGrowthGlobal1X128(), type(uint256).max - 1e36);
        }
        actor.mint(p, -887_270, 887_270, 1e18);
        vault.listMarket(PARITY_MARKET, _word(address(p)), BAND_LOWER, BAND_UPPER);

        int24 lo = int24(int256(seed % 1200)) * 10 - 6000;
        int24 hi = lo + 10 + int24(int256((seed >> 16) % uint256(int256((BAND_UPPER - lo) / 10)))) * 10;
        hi = hi > BAND_UPPER ? BAND_UPPER : hi;
        (bytes32 keyA,) = _mintPositionAt(PARITY_FEE, lo, hi);
        (bytes32 keyB, uint128 lB) = _mintPositionAt(PARITY_FEE, BAND_LOWER, BAND_UPPER);
        vm.startPrank(adapter);
        vault.pledge(lp, account, PARITY_MARKET, keyA);
        assertEq(vault.pledge(lp, account, PARITY_MARKET, keyB), lB, "a position on exactly the band is credited L");
        vm.stopPrank();

        int24[4] memory edges = [lo, hi, BAND_LOWER, BAND_UPPER];
        for (uint256 i = 0; i < 8; ++i) {
            uint256 r = uint256(keccak256(abi.encode(seed, i)));
            bytes32 k = (r >> 8) % 2 == 0 ? keyA : keyB;
            uint256 action = r % 5;
            if (action < 3) {
                _swapTo(p, ClTickMath.getSqrtPriceAtTick(_parityTarget(r >> 16, edges)));
            } else if (action == 3) {
                vm.prank(adapter);
                vault.addLiquidity(k, lp, 1e17, 1e17, 0, 0);
            } else {
                uint128 l = vault.getPosition(k).liquidity / 3;
                if (l > 0) {
                    vm.prank(adapter);
                    vault.removeLiquidity(k, l, 0, 0, recipient);
                }
            }
            _checkNfpmParity(vault, address(nfpm), address(p), keyA, uint256(keyA), PARITY_MARKET);
            _checkNfpmParity(vault, address(nfpm), address(p), keyB, uint256(keyB), PARITY_MARKET);
        }
        // The view is what a real collect pays, not only what a rolled-back one does.
        _swapTo(p, ClTickMath.getSqrtPriceAtTick(_parityTarget(seed >> 40, edges)));
        (uint256 v0, uint256 v1) = vault.feesOf(keyA);
        address owner = makeAddr("parityOwner");
        bytes32[] memory keys = new bytes32[](1);
        keys[0] = keyA;
        vm.prank(adapter);
        vault.collectFees(account, keys, owner);
        assertEq(t0.balanceOf(owner), v0, "token0 paid as viewed");
        assertEq(t1.balanceOf(owner), v1, "token1 paid as viewed");
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

    function _mintPosition(
        int24 tickLower,
        int24 tickUpper
    ) internal returns (bytes32 key, uint128 liquidity) {
        return _mintPositionAt(FEE, tickLower, tickUpper);
    }

    function _mintPositionAt(
        uint24 fee,
        int24 tickLower,
        int24 tickUpper
    ) internal returns (bytes32 key, uint128 liquidity) {
        uint256 tokenId;
        vm.prank(lp);
        (tokenId, liquidity,,) = nfpm.mint(
            INonfungiblePositionManager.MintParams({
                token0: address(t0),
                token1: address(t1),
                fee: fee,
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

/// @dev An ERC-721 receiver whose hook calls `target` with `data` and records that it ran.
contract ReenteringReceiver {
    address internal immutable TARGET;
    bytes internal data;
    bool public called;

    constructor(
        address target,
        bytes memory data_
    ) {
        (TARGET, data) = (target, data_);
    }

    function onERC721Received(
        address,
        address,
        uint256,
        bytes calldata
    ) external returns (bytes4) {
        called = true;
        // The outcome is read from the vault's state by the test.
        // forge-lint: disable-next-line(unchecked-call)
        (bool ok,) = TARGET.call(data);
        ok;
        return this.onERC721Received.selector;
    }
}

/// @dev Answers the pool reads of `UniswapV3Integration._poolInfo` with a real pool's tokens, fee and tick spacing and
/// a chosen factory, without being that factory's pool.
contract LookAlikeV3Pool {
    address public immutable token0;
    address public immutable token1;
    uint24 public immutable fee;
    int24 public immutable tickSpacing;
    address public immutable factory;

    constructor(
        IClPool real,
        uint24 fee_,
        address factory_
    ) {
        token0 = real.token0();
        token1 = real.token1();
        fee = fee_;
        tickSpacing = real.tickSpacing();
        factory = factory_;
    }
}
