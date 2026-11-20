// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ClTickMath} from "../../src/amm/concentrated-liquidity/ClTickMath.sol";
import {ILPVault} from "../../src/custody/lp-vault/ILPVault.sol";
import {FloorCreditMath} from "../../src/custody/lp-vault/libraries/FloorCreditMath.sol";
import {LPVaultTestToken, MockLPVault, MockPositionManager} from "../utils/mocks/LPVaultMocks.sol";
import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import {IAccessManaged} from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {Test} from "forge-std/Test.sol";

/// @notice Shared setup: an LPVault on a mock position manager, one band market `[-1000, 1000]`, the adapter and
/// liquidation roles granted.
abstract contract LPVaultTestBase is Test {
    uint64 internal constant ADAPTER_ROLE = 11;
    uint64 internal constant LIQUIDATION_ROLE = 12;
    bytes32 internal constant POOL = bytes32(uint256(0xA001));
    bytes32 internal constant POOL_B = bytes32(uint256(0xB002));
    int24 internal constant BAND_LOWER = -1000;
    int24 internal constant BAND_UPPER = 1000;
    uint256 internal constant MARKET = 1;
    uint256 internal constant MARKET_B = 2;

    AccessManager internal am;
    LPVaultTestToken internal token0;
    LPVaultTestToken internal token1;
    MockPositionManager internal pm;
    MockLPVault internal vault;

    address internal adapter = makeAddr("adapter");
    address internal liquidator = makeAddr("liquidator");
    address internal user = makeAddr("user");
    address internal account = makeAddr("account");
    address internal account2 = makeAddr("account2");
    address internal recipient = makeAddr("recipient");
    address internal stranger = makeAddr("stranger");

    function setUp() public virtual {
        am = new AccessManager(address(this));
        token0 = new LPVaultTestToken("T0");
        token1 = new LPVaultTestToken("T1");
        pm = new MockPositionManager(token0, token1);
        vault = new MockLPVault(address(am), pm);
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
        vault.setPool(POOL, 10);
        vault.setPool(POOL_B, 10);
        vault.listMarket(MARKET, POOL, BAND_LOWER, BAND_UPPER);
        vault.listMarket(MARKET_B, POOL_B, BAND_LOWER, BAND_UPPER);
        vm.prank(user);
        pm.setApprovalForAll(address(vault), true);
    }

    function _mint(
        bytes32 pool,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity
    ) internal returns (bytes32 key) {
        key = bytes32(pm.mint(user, pool, tickLower, tickUpper, liquidity));
    }

    function _pledge(
        address to,
        uint256 marketId,
        bytes32 key
    ) internal returns (uint128 credit) {
        vm.prank(adapter);
        credit = vault.pledge(user, to, marketId, key);
    }

    function _mintPledge(
        address to,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity
    ) internal returns (bytes32 key, uint128 credit) {
        key = _mint(POOL, tickLower, tickUpper, liquidity);
        credit = _pledge(to, MARKET, key);
    }

    function _floor(
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity
    ) internal pure returns (uint128) {
        return FloorCreditMath.credit(tickLower, tickUpper, BAND_LOWER, BAND_UPPER, liquidity);
    }
}

contract LPVaultUnitTest is LPVaultTestBase {
    // ---------------------------------------------------------------- markets

    function test_listMarket_storesBandAndTokens() public view {
        ILPVault.Market memory m = vault.getMarket(MARKET);
        assertEq(m.pool, POOL);
        assertEq(m.token0, address(token0));
        assertEq(m.token1, address(token1));
        assertEq(m.bandLower, BAND_LOWER);
        assertEq(m.bandUpper, BAND_UPPER);
        assertEq(m.totalCredit, 0);
    }

    function test_listMarket_refusesBadIdsPoolsAndBands() public {
        bytes32 pool = bytes32(uint256(0xC003));
        vault.setPool(pool, 10);
        vm.expectRevert(abi.encodeWithSelector(ILPVault.InvalidMarketId.selector, 0));
        vault.listMarket(0, pool, -100, 100);
        vm.expectRevert(abi.encodeWithSelector(ILPVault.InvalidMarketId.selector, MARKET));
        vault.listMarket(MARKET, pool, -100, 100);
        uint256 tooBig = uint256(type(uint96).max) + 1;
        vm.expectRevert(abi.encodeWithSelector(ILPVault.InvalidMarketId.selector, tooBig));
        vault.listMarket(tooBig, pool, -100, 100);
        bytes32 unknown = bytes32(uint256(0xDEAD));
        vm.expectRevert(abi.encodeWithSelector(ILPVault.InvalidPool.selector, unknown));
        vault.listMarket(3, unknown, -100, 100);
        vm.expectRevert(abi.encodeWithSelector(ILPVault.InvalidPool.selector, bytes32(0)));
        vault.listMarket(3, bytes32(0), -100, 100);
        vm.expectRevert(abi.encodeWithSelector(ILPVault.InvalidBand.selector, int24(-105), int24(100)));
        vault.listMarket(3, pool, -105, 100);
        vm.expectRevert(abi.encodeWithSelector(ILPVault.InvalidBand.selector, int24(100), int24(100)));
        vault.listMarket(3, pool, 100, 100);
        vm.expectRevert(abi.encodeWithSelector(ILPVault.InvalidBand.selector, int24(-887_280), int24(100)));
        vault.listMarket(3, pool, -887_280, 100);
    }

    function test_listMarket_severalMarketsOnOnePool() public {
        // A wide market on the same pool as MARKET; each position chooses its market at pledge.
        vault.listMarket(3, POOL, -400, 400);
        bytes32 a = _mint(POOL, -200, 200, 1e18);
        bytes32 b = _mint(POOL, -200, 200, 1e18);
        uint128 inWide = _pledge(account, MARKET, a);
        uint128 inNarrow = _pledge(account, 3, b);
        assertEq(inNarrow, FloorCreditMath.credit(-200, 200, -400, 400, 1e18));
        assertGt(inNarrow, inWide);
        assertEq(vault.getPosition(b).marketId, 3);
        assertEq(vault.getMarket(3).totalCredit, inNarrow);
        assertEq(vault.getMarket(MARKET).totalCredit, inWide);
        assertEq(vault.accountCredit(account, 3), inNarrow);
        // A position inside MARKET's band but outside market 3's is refused there only.
        bytes32 c = _mint(POOL, -800, 800, 1e18);
        vm.expectRevert(
            abi.encodeWithSelector(
                FloorCreditMath.NotInsideBand.selector, int24(-800), int24(800), int24(-400), int24(400)
            )
        );
        _pledge(account, 3, c);
        _pledge(account, MARKET, c);
    }

    function test_fullRangeMarket_creditsFullRangeLiquidityExactly() public {
        // The usable ticks of spacing 10, rounded toward zero in int24 (a literal expression would keep the fraction).
        int24 spacing = 10;
        int24 lo = (ClTickMath.MIN_TICK / spacing) * spacing;
        int24 hi = (ClTickMath.MAX_TICK / spacing) * spacing;
        vault.listMarket(4, POOL, lo, hi);
        bytes32 full = _mint(POOL, lo, hi, 123_456_789e18);
        assertEq(_pledge(account, 4, full), 123_456_789e18);
        // A narrower position is credited below its liquidity, and a partial removal keeps credit = liquidity.
        bytes32 narrow = _mint(POOL, lo + spacing, hi, 1e18);
        uint128 c = _pledge(account, 4, narrow);
        assertLt(c, 1e18);
        assertGt(c, 0);
        vm.prank(adapter);
        vault.removeLiquidity(full, 456_789e18, 0, 0, recipient);
        ILPVault.Position memory p = vault.getPosition(full);
        assertEq(p.credit, p.liquidity);
    }

    function test_listMarket_restricted() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, stranger));
        vault.listMarket(3, bytes32(uint256(0xC003)), -100, 100);
    }

    // ---------------------------------------------------------------- band check and credit

    function test_pledge_inRangeAndOutOfRangeInsideBand() public {
        // The mock has no price: whether the pool price is inside the position never matters.
        (bytes32 a, uint128 ca) = _mintPledge(account, -500, 500, 1e18);
        (bytes32 b, uint128 cb) = _mintPledge(account, 600, 1000, 1e18);
        (bytes32 c, uint128 cc) = _mintPledge(account, -1000, -990, 1e18);
        assertEq(ca, _floor(-500, 500, 1e18));
        assertEq(cb, _floor(600, 1000, 1e18));
        assertEq(cc, _floor(-1000, -990, 1e18));
        assertEq(vault.getMarket(MARKET).totalCredit, uint256(ca) + cb + cc);
        assertEq(vault.accountCredit(account, MARKET), uint256(ca) + cb + cc);
        assertEq(pm.ownerOf(uint256(a)), address(vault));
        assertEq(pm.ownerOf(uint256(b)), address(vault));
        assertEq(pm.ownerOf(uint256(c)), address(vault));
        ILPVault.Position memory p = vault.getPosition(a);
        assertEq(p.account, account);
        assertEq(p.marketId, MARKET);
        assertEq(p.liquidity, 1e18);
        assertEq(p.credit, ca);
        assertEq(vault.positionsOf(account).length, 3);
    }

    function test_pledge_fullBandCreditsItsLiquidity() public {
        (, uint128 credit) = _mintPledge(account, BAND_LOWER, BAND_UPPER, 1e18);
        assertEq(credit, 1e18);
    }

    function test_pledge_narrowerRangeCreditsLess() public {
        (, uint128 wide) = _mintPledge(account, -800, 800, 1e18);
        (, uint128 narrow) = _mintPledge(account, -100, 100, 1e18);
        assertLt(narrow, wide);
        assertGt(narrow, 0);
    }

    function test_pledge_refusesPositionsLeavingTheBand() public {
        bytes32 below = _mint(POOL, -1010, 0, 1e18);
        vm.expectRevert(
            abi.encodeWithSelector(
                FloorCreditMath.NotInsideBand.selector, int24(-1010), int24(0), BAND_LOWER, BAND_UPPER
            )
        );
        _pledge(account, MARKET, below);
        bytes32 above = _mint(POOL, 0, 1010, 1e18);
        vm.expectRevert(
            abi.encodeWithSelector(
                FloorCreditMath.NotInsideBand.selector, int24(0), int24(1010), BAND_LOWER, BAND_UPPER
            )
        );
        _pledge(account, MARKET, above);
        bytes32 wider = _mint(POOL, -2000, 2000, 1e18);
        vm.expectRevert();
        _pledge(account, MARKET, wider);
        assertEq(pm.ownerOf(uint256(wider)), user);
    }

    function test_previewCredit_matchesPledge() public {
        bytes32 key = _mint(POOL, -300, 700, 5e17);
        uint128 preview = vault.previewCredit(MARKET, key);
        assertEq(_pledge(account, MARKET, key), preview);
    }

    function test_pledge_refusesWrongPoolOwnerAndRepeats() public {
        bytes32 other = _mint(POOL_B, -100, 100, 1e18);
        vm.expectRevert(abi.encodeWithSelector(ILPVault.PoolMismatch.selector, other, POOL_B));
        _pledge(account, MARKET, other);

        bytes32 key = _mint(POOL, -100, 100, 1e18);
        vm.prank(adapter);
        vm.expectRevert(abi.encodeWithSelector(ILPVault.NotTokenOwner.selector, key));
        vault.pledge(stranger, account, MARKET, key);

        _pledge(account, MARKET, key);
        vm.expectRevert(abi.encodeWithSelector(ILPVault.AlreadyPledged.selector, key));
        _pledge(account, MARKET, key);

        bytes32 empty = _mint(POOL, -100, 100, 0);
        vm.expectRevert(abi.encodeWithSelector(ILPVault.ZeroCredit.selector, empty));
        _pledge(account, MARKET, empty);

        vm.expectRevert(abi.encodeWithSelector(ILPVault.MarketNotListed.selector, 9));
        _pledge(account, 9, empty);

        vm.prank(adapter);
        vm.expectRevert(abi.encodeWithSelector(ILPVault.InvalidAddress.selector, address(0)));
        vault.pledge(user, address(0), MARKET, empty);
    }

    function test_pledge_atMost16PerAccount() public {
        for (uint256 i = 0; i < 16; ++i) {
            _mintPledge(account, -100, 100, 1e18);
        }
        bytes32 extra = _mint(POOL, -100, 100, 1e18);
        vm.expectRevert(abi.encodeWithSelector(ILPVault.TooManyPositions.selector, account));
        _pledge(account, MARKET, extra);
        // Another account is not affected.
        _pledge(account2, MARKET, extra);
        assertEq(vault.MAX_POSITIONS(), 16);
    }

    function test_userFlows_restrictedToTheAdapter() public {
        bytes32 key = _mint(POOL, -100, 100, 1e18);
        vm.startPrank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, stranger));
        vault.pledge(user, account, MARKET, key);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, stranger));
        vault.release(key, stranger);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, stranger));
        vault.removeLiquidity(key, 1, 0, 0, stranger);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, stranger));
        vault.addLiquidity(key, stranger, 1, 1, 0, 0);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, stranger));
        vault.collectFees(account, new bytes32[](0), stranger);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, stranger));
        vault.unwind(key, 1, 0, 0, stranger);
        vm.stopPrank();
        // The adapter cannot unwind: that is the liquidation role's.
        vm.prank(adapter);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, adapter));
        vault.unwind(key, 1, 0, 0, adapter);
    }

    // ---------------------------------------------------------------- top-up

    function test_addLiquidity_raisesCreditByTheNewLiquiditysCredit() public {
        (bytes32 key, uint128 c0) = _mintPledge(account, -400, 600, 1e18);
        token0.mint(user, 5e17);
        token1.mint(user, 8e17);
        vm.startPrank(user);
        token0.approve(address(vault), type(uint256).max);
        token1.approve(address(vault), type(uint256).max);
        vm.stopPrank();
        vm.prank(adapter);
        (uint128 liquidity, uint128 credit, uint256 a0, uint256 a1) = vault.addLiquidity(key, user, 5e17, 8e17, 0, 0);
        assertEq(liquidity, 5e17);
        assertEq(credit, _floor(-400, 600, 5e17));
        assertEq(a0, 5e17);
        assertEq(a1, 5e17);
        ILPVault.Position memory p = vault.getPosition(key);
        assertEq(p.liquidity, 15e17);
        assertEq(p.credit, c0 + credit);
        assertLe(p.credit, _floor(-400, 600, 15e17));
        assertEq(vault.getMarket(MARKET).totalCredit, p.credit);
        // The unused token1 went back to the payer; the LPVault keeps nothing.
        assertEq(token1.balanceOf(user), 3e17);
        assertEq(token0.balanceOf(address(vault)), 0);
        assertEq(token1.balanceOf(address(vault)), 0);
    }

    function test_addLiquidity_checksMinimumsAndRecord() public {
        (bytes32 key,) = _mintPledge(account, -400, 600, 1e18);
        token0.mint(user, 1e18);
        token1.mint(user, 1e18);
        vm.startPrank(user);
        token0.approve(address(vault), type(uint256).max);
        token1.approve(address(vault), type(uint256).max);
        vm.stopPrank();
        vm.prank(adapter);
        vm.expectRevert(abi.encodeWithSelector(ILPVault.BelowMinimum.selector, 1, 1e17, 2e17));
        vault.addLiquidity(key, user, 1e18, 1e17, 0, 2e17);
        vm.prank(adapter);
        vm.expectRevert(abi.encodeWithSelector(ILPVault.InvalidAmount.selector, key, 0));
        vault.addLiquidity(key, user, 1e18, 0, 0, 0);
        bytes32 unknown = bytes32(uint256(999));
        vm.prank(adapter);
        vm.expectRevert(abi.encodeWithSelector(ILPVault.NotPledged.selector, unknown));
        vault.addLiquidity(unknown, user, 1, 1, 0, 0);
    }

    function test_pledge_anyTimeTopUpWithMorePositions() public {
        (, uint128 c1) = _mintPledge(account, -100, 100, 1e18);
        (, uint128 c2) = _mintPledge(account, -900, 900, 2e18);
        assertEq(vault.accountCredit(account, MARKET), uint256(c1) + c2);
    }

    // ---------------------------------------------------------------- release

    function test_removeLiquidity_partialLowersCreditInProportion() public {
        (bytes32 key, uint128 credit) = _mintPledge(account, -500, 500, 1e18);
        vm.prank(adapter);
        (uint128 removed, uint256 a0, uint256 a1) = vault.removeLiquidity(key, 25e16, 0, 0, recipient);
        uint128 left = uint128((uint256(credit) * 75e16) / 1e18);
        if (_floor(-500, 500, 75e16) < left) left = _floor(-500, 500, 75e16);
        assertEq(removed, credit - left);
        assertEq(a0, 25e16);
        assertEq(a1, 25e16);
        assertEq(token0.balanceOf(recipient), 25e16);
        assertEq(token1.balanceOf(recipient), 25e16);
        ILPVault.Position memory p = vault.getPosition(key);
        assertEq(p.liquidity, 75e16);
        assertEq(p.credit, left);
        assertLe(p.credit, _floor(-500, 500, 75e16));
        assertEq(vault.getMarket(MARKET).totalCredit, left);
        assertEq(pm.ownerOf(uint256(key)), address(vault));
    }

    function test_removeLiquidity_refusesZeroTooMuchAndBadRecipient() public {
        (bytes32 key,) = _mintPledge(account, -500, 500, 1e18);
        vm.startPrank(adapter);
        vm.expectRevert(abi.encodeWithSelector(ILPVault.InvalidAmount.selector, key, 0));
        vault.removeLiquidity(key, 0, 0, 0, recipient);
        vm.expectRevert(abi.encodeWithSelector(ILPVault.InvalidAmount.selector, key, 1e18 + 1));
        vault.removeLiquidity(key, 1e18 + 1, 0, 0, recipient);
        vm.expectRevert(abi.encodeWithSelector(ILPVault.InvalidAddress.selector, address(vault)));
        vault.removeLiquidity(key, 1, 0, 0, address(vault));
        vm.expectRevert(abi.encodeWithSelector(ILPVault.BelowMinimum.selector, 0, 1e17, 1e17 + 1));
        vault.removeLiquidity(key, 1e17, 1e17 + 1, 0, recipient);
        vm.stopPrank();
    }

    function test_removeLiquidity_wholeRecordLeavesAZeroCreditRecord() public {
        (bytes32 key,) = _mintPledge(account, -500, 500, 1e18);
        vm.prank(adapter);
        vault.removeLiquidity(key, 1e18, 0, 0, recipient);
        ILPVault.Position memory p = vault.getPosition(key);
        assertEq(p.liquidity, 0);
        assertEq(p.credit, 0);
        assertEq(vault.getMarket(MARKET).totalCredit, 0);
        vm.prank(adapter);
        vault.release(key, user);
        assertEq(pm.ownerOf(uint256(key)), user);
    }

    function test_release_returnsTheNftAndClosesTheRecord() public {
        (bytes32 a,) = _mintPledge(account, -500, 500, 1e18);
        (bytes32 b, uint128 cb) = _mintPledge(account, -200, 200, 1e18);
        (bytes32 c,) = _mintPledge(account, -100, 900, 1e18);
        vm.prank(adapter);
        uint128 removed = vault.release(a, recipient);
        assertEq(removed, _floor(-500, 500, 1e18));
        assertEq(pm.ownerOf(uint256(a)), recipient);
        assertEq(vault.getPosition(a).account, address(0));
        bytes32[] memory left = vault.positionsOf(account);
        assertEq(left.length, 2);
        assertTrue((left[0] == b && left[1] == c) || (left[0] == c && left[1] == b));
        vm.prank(adapter);
        vault.release(c, recipient);
        assertEq(vault.positionsOf(account).length, 1);
        assertEq(vault.getMarket(MARKET).totalCredit, cb);
        vm.prank(adapter);
        vm.expectRevert(abi.encodeWithSelector(ILPVault.NotPledged.selector, a));
        vault.release(a, recipient);
        // A released key can be pledged again.
        vm.prank(recipient);
        pm.approve(address(vault), uint256(a));
        vm.prank(adapter);
        vault.pledge(recipient, account2, MARKET, a);
        assertEq(vault.getPosition(a).account, account2);
    }

    function test_release_keepsDonatedLiquidityWithTheNft() public {
        (bytes32 key, uint128 credit) = _mintPledge(account, -500, 500, 1e18);
        pm.donateLiquidity(uint256(key), 3e18);
        assertEq(vault.getPosition(key).credit, credit);
        vm.prank(adapter);
        vault.removeLiquidity(key, 1e18, 0, 0, recipient);
        (,,, uint128 live,,) = pm.pos(uint256(key));
        assertEq(live, 3e18);
    }

    // ---------------------------------------------------------------- liquidation unwind

    function test_unwind_removesTheLiquidityWorthTheCredit() public {
        (bytes32 key, uint128 credit) = _mintPledge(account, -500, 500, 1e18);
        uint128 seize = credit / 3;
        vm.prank(liquidator);
        (uint128 liquidity, uint128 creditRemoved, uint256 a0, uint256 a1) = vault.unwind(key, seize, 0, 0, recipient);
        uint256 expected = (uint256(seize) * 1e18 + credit - 1) / credit;
        assertEq(liquidity, expected);
        assertGe(creditRemoved, seize);
        assertLe(creditRemoved, seize + 10);
        assertEq(a0, liquidity);
        assertEq(a1, liquidity);
        assertEq(token0.balanceOf(recipient), liquidity);
        ILPVault.Position memory p = vault.getPosition(key);
        assertEq(p.credit, credit - creditRemoved);
        assertLe(p.credit, _floor(-500, 500, p.liquidity));
    }

    function test_unwind_capsAtTheRecord() public {
        (bytes32 key, uint128 credit) = _mintPledge(account, -500, 500, 1e18);
        vm.prank(liquidator);
        (uint128 liquidity, uint128 creditRemoved,,) = vault.unwind(key, credit * 2, 0, 0, recipient);
        assertEq(liquidity, 1e18);
        assertEq(creditRemoved, credit);
        assertEq(vault.getPosition(key).credit, 0);
        vm.prank(liquidator);
        vm.expectRevert(abi.encodeWithSelector(ILPVault.InvalidAmount.selector, key, 1));
        vault.unwind(key, 1, 0, 0, recipient);
        vm.prank(liquidator);
        vm.expectRevert(abi.encodeWithSelector(ILPVault.InvalidAmount.selector, key, 0));
        vault.unwind(key, 0, 0, 0, recipient);
    }

    // ---------------------------------------------------------------- fees

    function test_collectFees_severalPositionsEachToTheRecipient() public {
        (bytes32 a, uint128 ca) = _mintPledge(account, -500, 500, 1e18);
        (bytes32 b, uint128 cb) = _mintPledge(account, -100, 100, 1e18);
        (bytes32 c,) = _mintPledge(account, -100, 300, 1e18);
        pm.accrue(uint256(a), 10, 20);
        pm.accrue(uint256(b), 30, 0);
        pm.accrue(uint256(c), 7, 7);
        (uint256 fa0, uint256 fa1) = vault.feesOf(a);
        assertEq(fa0, 10);
        assertEq(fa1, 20);
        bytes32[] memory keys = new bytes32[](2);
        (keys[0], keys[1]) = (a, b);
        vm.prank(adapter);
        (uint256[] memory f0, uint256[] memory f1) = vault.collectFees(account, keys, recipient);
        assertEq(f0[0], 10);
        assertEq(f1[0], 20);
        assertEq(f0[1], 30);
        assertEq(f1[1], 0);
        assertEq(token0.balanceOf(recipient), 40);
        assertEq(token1.balanceOf(recipient), 20);
        // Fees are never collateral: credit is unchanged, and the third position keeps its fees.
        assertEq(vault.getPosition(a).credit, ca);
        assertEq(vault.getPosition(b).credit, cb);
        (uint256 fc0,) = vault.feesOf(c);
        assertEq(fc0, 7);
        (fa0, fa1) = vault.feesOf(a);
        assertEq(fa0 + fa1, 0);
    }

    function test_collectFees_onlyTheAccountsPositions() public {
        (bytes32 a,) = _mintPledge(account, -500, 500, 1e18);
        (bytes32 b,) = _mintPledge(account2, -500, 500, 1e18);
        bytes32[] memory keys = new bytes32[](2);
        (keys[0], keys[1]) = (a, b);
        vm.prank(adapter);
        vm.expectRevert(abi.encodeWithSelector(ILPVault.NotPositionAccount.selector, b, account));
        vault.collectFees(account, keys, recipient);
    }

    function test_feesPaidOnADecreaseAreHeldForThePosition() public {
        pm.setFeesOnDecrease(true);
        (bytes32 key, uint128 credit) = _mintPledge(account, -500, 500, 1e18);
        pm.accrue(uint256(key), 50, 60);
        vm.prank(liquidator);
        (uint128 liquidity,,,) = vault.unwind(key, credit / 2, 0, 0, recipient);
        // The liquidator gets principal only; the fees wait for the owner.
        assertEq(token0.balanceOf(recipient), liquidity);
        assertEq(token1.balanceOf(recipient), liquidity);
        (uint256 h0, uint256 h1) = vault.feesOf(key);
        assertEq(h0, 50);
        assertEq(h1, 60);
        address owner = makeAddr("owner");
        vm.prank(adapter);
        vault.release(key, owner);
        assertEq(token0.balanceOf(owner), 50);
        assertEq(token1.balanceOf(owner), 60);
    }

    function test_feesOf_unknownPositionReverts() public {
        vm.expectRevert(abi.encodeWithSelector(ILPVault.NotPledged.selector, bytes32(uint256(5))));
        vault.feesOf(bytes32(uint256(5)));
    }

    // ---------------------------------------------------------------- guard

    function test_guard_refusesReentryFromTheAmm() public {
        (bytes32 key,) = _mintPledge(account, -500, 500, 1e18);
        // The position manager gets the adapter role, so only the guard can stop it.
        am.grantRole(ADAPTER_ROLE, address(pm), 0);
        pm.setReenter(address(vault), abi.encodeCall(ILPVault.release, (key, address(pm))));
        vm.prank(adapter);
        vm.expectRevert(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector);
        vault.removeLiquidity(key, 1e17, 0, 0, recipient);
        assertFalse(vault.locked());
    }

    function test_guard_locksDuringACall() public {
        (bytes32 key,) = _mintPledge(account, -500, 500, 1e18);
        LockProbe probe = new LockProbe(vault);
        pm.setReenter(address(probe), abi.encodeCall(LockProbe.probe, ()));
        vm.prank(adapter);
        vault.removeLiquidity(key, 1e17, 0, 0, recipient);
        assertTrue(probe.sawLocked());
    }

    // ---------------------------------------------------------------- views

    function test_accountCredit_perMarket() public {
        (, uint128 c1) = _mintPledge(account, -500, 500, 1e18);
        bytes32 keyB = _mint(POOL_B, -500, 500, 2e18);
        uint128 c2 = _pledge(account, MARKET_B, keyB);
        assertEq(vault.accountCredit(account, MARKET), c1);
        assertEq(vault.accountCredit(account, MARKET_B), c2);
        assertEq(vault.getMarket(MARKET_B).totalCredit, c2);
    }
}

/// @notice Records whether the LPVault reports its guard as held when called from inside it.
contract LockProbe {
    ILPVault internal immutable VAULT;
    bool public sawLocked;

    constructor(
        ILPVault vault
    ) {
        VAULT = vault;
    }

    function probe() external {
        sawLocked = VAULT.locked();
    }
}
