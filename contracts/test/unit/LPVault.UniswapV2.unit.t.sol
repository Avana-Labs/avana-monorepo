// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ClTickMath} from "../../src/integrations/shared/ClTickMath.sol";
import {UniswapV2Integration} from "../../src/integrations/uniswap-v2/UniswapV2Integration.sol";
import {UniswapV2Positions} from "../../src/integrations/uniswap-v2/UniswapV2Positions.sol";
import {IUniswapV2Positions} from "../../src/integrations/uniswap-v2/interfaces/IUniswapV2Positions.sol";
import {ILPVault} from "../../src/vault/interfaces/ILPVault.sol";
import {FloorCreditMath} from "../../src/vault/libraries/FloorCreditMath.sol";
import {UniswapV2TestBase} from "../utils/UniswapV2TestBase.sol";
import {
    FakeUniswapV2Pair,
    IMockUniswapV2Callee,
    MockUniswapV2Factory,
    RebasingToken
} from "../utils/mocks/UniswapV2Mocks.sol";
import {MintableToken} from "../utils/mocks/UniswapV3Mocks.sol";
import {FeeOnTransferToken} from "../utils/mocks/hostile/FeeOnTransferToken.sol";
import {IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @notice Flash-swap borrower that reads the vault's credit and live liquidity of a position mid-swap, then repays.
contract FlashReader is IMockUniswapV2Callee {
    UniswapV2Integration internal immutable VAULT;
    bytes32 internal immutable KEY;
    uint128 public creditDuring;
    uint128 public liquidityDuring;

    constructor(
        UniswapV2Integration vault,
        bytes32 key
    ) {
        (VAULT, KEY) = (vault, key);
    }

    function uniswapV2Call(
        address,
        uint256 amount0,
        uint256 amount1,
        bytes calldata data
    ) external {
        creditDuring = VAULT.previewCredit(1, KEY);
        (,,, liquidityDuring) = VAULT.positionInfo(KEY);
        (address t0, address t1, uint256 repay0, uint256 repay1) =
            abi.decode(data, (address, address, uint256, uint256));
        MintableToken(t0).mint(msg.sender, repay0 > amount0 ? repay0 - amount0 : 0);
        MintableToken(t1).mint(msg.sender, repay1 > amount1 ? repay1 - amount1 : 0);
        IERC20(t0).transfer(msg.sender, amount0);
        IERC20(t1).transfer(msg.sender, amount1);
    }
}

/// @notice The Uniswap v2 LPVault and its position wrapper against a v2-core pair, each test an attack.
contract LPVaultUniswapV2UnitTest is UniswapV2TestBase {
    uint256 internal constant SEED = 1000e18;

    function setUp() public {
        _deploy(address(new MintableToken("A", 18)), address(new MintableToken("B", 18)), SEED, SEED);
    }

    // ─── Malformed deployments and pairs ───

    function test_constructor_refusesAFakeWrapperOrFactory() public {
        vm.expectRevert(IUniswapV2Positions.InvalidFactory.selector);
        new UniswapV2Positions(attacker);
        vm.expectRevert(ILPVault.InvalidDeployment.selector);
        new UniswapV2Integration(address(am), attacker, address(factory));
        vm.expectRevert(ILPVault.InvalidDeployment.selector);
        new UniswapV2Integration(address(am), address(positions), address(0));
        UniswapV2Positions otherWrapper = new UniswapV2Positions(address(new MockUniswapV2Factory()));
        vm.expectRevert(ILPVault.InvalidDeployment.selector);
        new UniswapV2Integration(address(am), address(otherWrapper), address(factory));
        assertEq(vault.POSITIONS(), address(positions));
        assertEq(vault.FACTORY(), address(factory));
        assertEq(positions.FACTORY(), address(factory));
        assertEq(vault.TICK_SPACING(), 1);
    }

    function test_listMarket_refusesMalformedPairs() public {
        FakeUniswapV2Pair fake = new FakeUniswapV2Pair(t0, t1);
        bytes32[3] memory words =
            [_word(address(fake)), _word(attacker), bytes32(uint256(uint160(address(pair))) | (1 << 200))];
        for (uint256 i = 0; i < 3; ++i) {
            vm.expectRevert(abi.encodeWithSelector(ILPVault.InvalidPool.selector, words[i]));
            vault.listMarket(2, words[i], ClTickMath.MIN_TICK, ClTickMath.MAX_TICK);
        }
    }

    function test_wrap_refusesPairsOutsideTheFactoryAndEmptyPulls() public {
        FakeUniswapV2Pair fake = new FakeUniswapV2Pair(t0, t1);
        fake.mintLp(attacker, 1e30);
        vm.startPrank(attacker);
        fake.approve(address(positions), 1e30);
        vm.expectRevert(abi.encodeWithSelector(IUniswapV2Positions.InvalidPair.selector, address(fake)));
        positions.wrap(address(fake), 1e30, attacker);
        vm.expectRevert(abi.encodeWithSelector(IUniswapV2Positions.InvalidPair.selector, attacker));
        positions.wrap(attacker, 1, attacker);
        vm.expectRevert(abi.encodeWithSelector(IUniswapV2Positions.InvalidAmount.selector, 1, 0));
        positions.wrap(address(pair), 0, attacker);
        vm.expectRevert(abi.encodeWithSelector(IUniswapV2Positions.UnknownPosition.selector, 7));
        positions.increase(7, 1);
        vm.stopPrank();
    }

    function test_unwrap_refusesTheftAndOverdraw() public {
        bytes32 key = _wrap(user, _lp(user, 10e18, 10e18));
        uint256 id = uint256(key);
        uint256 held = _held(key);
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721InsufficientApproval.selector, attacker, id));
        positions.unwrap(id, 1, attacker);
        vm.startPrank(user);
        vm.expectRevert(abi.encodeWithSelector(IUniswapV2Positions.InvalidAmount.selector, id, held + 1));
        positions.unwrap(id, held + 1, user);
        vm.expectRevert(abi.encodeWithSelector(IUniswapV2Positions.InvalidAmount.selector, id, 0));
        positions.unwrap(id, 0, user);
        vm.stopPrank();

        // Once pledged, the former owner cannot pull the LP out from under the credit.
        vm.prank(adapter);
        vault.pledge(user, account, FULL, key);
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721InsufficientApproval.selector, user, id));
        positions.unwrap(id, 1, user);

        // Anyone may top a position up; the LP that arrived is what is held.
        uint256 extra = _lp(attacker, 1e18, 1e18);
        vm.startPrank(attacker);
        pair.approve(address(positions), extra);
        assertEq(positions.increase(id, extra), extra);
        vm.stopPrank();
        assertEq(_held(key), held + extra);
    }

    // ─── Credit ───

    function test_pledge_creditIsTheSqrtKShare_andOnlyFullRangeFits() public {
        bytes32 key = _wrap(user, _lp(user, 40e18, 10e18));
        (uint112 r0, uint112 r1,) = pair.getReserves();
        uint256 expected = Math.mulDiv(_held(key), Math.sqrt(uint256(r0) * r1), pair.totalSupply());
        assertEq(vault.previewCredit(FULL, key), expected);

        // A Custom range market of the same pair cannot take a full-range v2 position.
        vault.listMarket(2, _word(address(pair)), -6000, 6000);
        vm.prank(adapter);
        vm.expectRevert(
            abi.encodeWithSelector(
                FloorCreditMath.NotInsideBand.selector, ClTickMath.MIN_TICK, ClTickMath.MAX_TICK, -6000, 6000
            )
        );
        vault.pledge(user, account, 2, key);

        // A key the wrapper never minted reads as pool 0.
        vm.prank(adapter);
        vm.expectRevert(abi.encodeWithSelector(ILPVault.PoolMismatch.selector, bytes32(uint256(99)), bytes32(0)));
        vault.pledge(user, account, FULL, bytes32(uint256(99)));

        vm.prank(adapter);
        assertEq(vault.pledge(user, account, FULL, key), expected);
        (bytes32 pool, int24 lo, int24 hi, uint128 live) = vault.positionInfo(key);
        assertEq(pool, _word(address(pair)));
        assertEq(lo, ClTickMath.MIN_TICK);
        assertEq(hi, ClTickMath.MAX_TICK);
        assertEq(live, expected);
        assertEq(vault.liquidityOf(address(pair), 0), 0);
    }

    function test_flashSwap_movesNoCredit() public {
        (bytes32 key, uint128 credit) = _position(user, 100e18, 100e18);
        FlashReader reader = new FlashReader(vault, key);
        (uint112 r0,,) = pair.getReserves();
        uint256 out = uint256(r0) * 9 / 10;
        // Borrow 90% of token0 and repay it with the fee: the price inside the callback is what an attacker would use.
        pair.swap(out, 0, address(reader), abi.encode(t0, t1, out * 1000 / 997 + 1, uint256(0)));
        assertEq(reader.creditDuring(), credit);
        assertEq(reader.liquidityDuring(), credit);
        // A real swap that moves the price 100x leaves k, and so the credit, at least where it was.
        _swap(attacker, true, 9000e18);
        (,,, uint128 live) = vault.positionInfo(key);
        assertGe(live, credit);
        assertLe(live, uint256(credit) * 1005 / 1000);
        assertEq(vault.getPosition(key).credit, credit);
    }

    function test_donationAndSync_raiseCreditByLessThanTheDonation() public {
        (bytes32 key, uint128 credit) = _position(attacker, 1000e18, 1000e18);
        uint256 donation = 500e18;
        // Unsynced donation: reserves, and so credit, unchanged; `skim` takes it back out.
        MintableToken(t0).mint(address(pair), donation);
        (,,, uint128 live) = vault.positionInfo(key);
        assertEq(live, credit);
        pair.sync();
        (,,, live) = vault.positionInfo(key);
        // Value of full-range liquidity L at the fair price 1 is at most 2L token1; the attacker's half share of the
        // pool gains less than the donation it paid for.
        assertGt(live, credit);
        assertLt(2 * (uint256(live) - credit), donation);
    }

    function test_protocolFee_pendingMintIsCounted() public {
        factory.setFeeTo(makeAddr("feeTo"));
        // Fee on but no kLast yet: nothing pending.
        assertEq(vault.liquidityOf(address(pair), 1e18), 1e18);
        bytes32 key = _wrap(user, _lp(user, 100e18, 100e18));
        uint256 small = _lp(other, 1e18, 1e18);
        for (uint256 i = 0; i < 6; ++i) {
            _swap(attacker, i % 2 == 0, 400e18);
        }
        (,,, uint128 before) = vault.positionInfo(key);
        // Any mint or burn now runs `_mintFee`, which dilutes every holder; the credit read before already saw it.
        vm.startPrank(other);
        pair.transfer(address(pair), small);
        pair.burn(other);
        vm.stopPrank();
        (,,, uint128 afterMint) = vault.positionInfo(key);
        assertLe(before, afterMint);
        assertApproxEqAbs(before, afterMint, 2);
        // With the fee switched off again the pending kLast no longer counts.
        factory.setFeeTo(address(0));
        (,,, uint128 off) = vault.positionInfo(key);
        assertGe(off, afterMint);
    }

    // ─── Liquidity changes ───

    function test_addLiquidity_sandwichHitsTheMinimum_andTopUpIsCredited() public {
        (bytes32 key, uint128 credit) = _position(user, 100e18, 100e18);
        MintableToken(t0).mint(user, 60e18);
        MintableToken(t1).mint(user, 80e18);
        vm.startPrank(user);
        IERC20(t0).approve(address(vault), type(uint256).max);
        IERC20(t1).approve(address(vault), type(uint256).max);
        vm.stopPrank();

        // A swap ahead of the top-up moves the reserve ratio; the minimum stops the user adding at it.
        _swap(attacker, true, 400e18);
        vm.prank(adapter);
        vm.expectRevert();
        vault.addLiquidity(key, user, 50e18, 50e18, 49e18, 49e18);

        // token1 binds first; the token0 left over goes back to the payer.
        vm.prank(adapter);
        (uint128 added, uint128 creditAdded, uint256 a0, uint256 a1) = vault.addLiquidity(key, user, 50e18, 1e18, 0, 0);
        assertEq(a1, 1e18);
        assertLt(a0, 50e18);
        assertEq(creditAdded, added);
        assertEq(_bal(t0, user), 60e18 - a0);
        assertEq(vault.getPosition(key).credit, credit + creditAdded);
        assertEq(_bal(t0, address(vault)), 0);
        assertEq(_bal(t1, address(vault)), 0);

        // token0 binds first.
        vm.prank(adapter);
        (,, a0, a1) = vault.addLiquidity(key, user, 1e18, 70e18, 0, 0);
        assertEq(a0, 1e18);
        assertLt(a1, 70e18);
    }

    function test_unwind_dustPaysNothingAndKeepsTheLP() public {
        // Donated-and-synced reserves make one LP wei worth many liquidity units.
        MintableToken(t0).mint(address(pair), 30_000e18);
        MintableToken(t1).mint(address(pair), 30_000e18);
        pair.sync();
        (bytes32 key,) = _position(user, 10e18, 10e18);
        uint256 held = _held(key);
        vm.prank(adapter);
        (uint128 l, uint128 removed, uint256 a0, uint256 a1) = vault.unwind(key, 1, 0, 0, recipient);
        assertEq(l, 1);
        assertEq(removed, 1);
        assertEq(a0 + a1, 0);
        assertEq(_held(key), held);
    }

    function test_unwind_dustOnASkewedPairPaysNothingInsteadOfReverting() public {
        (bytes32 key,) = _position(user, 100e18, 100e18);
        // A price pushed to an extreme leaves so little token1 that one LP wei redeems none of it; `burn` would revert
        // and block the liquidation, so the dust stays in the position instead.
        _swap(attacker, true, 1e33);
        uint256 held = _held(key);
        vm.prank(adapter);
        (,, uint256 a0, uint256 a1) = vault.unwind(key, 1, 0, 0, recipient);
        assertEq(a0 + a1, 0);
        assertEq(_held(key), held);
    }

    function test_unwind_liquidatorGetsAProportionalShare() public {
        (bytes32 key, uint128 credit) = _position(user, 100e18, 100e18);
        (bytes32 keyB,) = _position(other, 50e18, 50e18);
        for (uint256 i = 0; i < 4; ++i) {
            _swap(attacker, i % 2 == 0, 300e18);
        }
        uint256 held = _held(key);
        uint256 heldB = _held(keyB);
        vm.prank(adapter);
        (uint128 l,, uint256 a0, uint256 a1) = vault.unwind(key, credit / 4, 0, 0, recipient);
        assertEq(_held(key), held - held * l / credit);
        assertEq(_held(keyB), heldB);
        assertEq(_bal(t0, recipient), a0);
        assertEq(_bal(t1, recipient), a1);

        // Full removal by the owner burns everything the position still held.
        uint128 all = vault.getPosition(keyB).liquidity;
        vm.prank(adapter);
        vault.removeLiquidity(keyB, all, 0, 0, other);
        assertEq(_held(keyB), 0);
    }

    function test_collectFees_extractsNothing_andReleaseReturnsTheGrownLP() public {
        (bytes32 key, uint128 credit) = _position(user, 100e18, 100e18);
        for (uint256 i = 0; i < 4; ++i) {
            _swap(attacker, i % 2 == 0, 300e18);
        }
        uint256 held = _held(key);
        // Fees compound into k: nothing to collect separately, and the LP stays whole.
        bytes32[] memory keys = new bytes32[](1);
        keys[0] = key;
        (uint256 f0, uint256 f1) = vault.feesOf(key);
        assertEq(f0 + f1, 0);
        vm.prank(adapter);
        (uint256[] memory c0, uint256[] memory c1) = vault.collectFees(account, keys, recipient);
        assertEq(c0[0] + c1[0], 0);
        assertEq(_held(key), held);

        vm.prank(adapter);
        assertEq(vault.release(key, user), credit);
        assertEq(positions.ownerOf(uint256(key)), user);
        (,,, uint128 live) = vault.positionInfo(key);
        assertGt(live, credit);
    }

    function test_reentrancy_hookTokenCannotReenterDuringBurn() public {
        (bytes32 key, uint128 credit) = _position(user, 100e18, 100e18);
        (bytes32 keyB,) = _position(other, 100e18, 100e18);
        // Worst case: the hooked token holds the adapter role and tries to release another position mid-unwind.
        am.grantRole(ADAPTER_ROLE, t0, 0);
        MintableToken(t0).setHook(address(vault), abi.encodeCall(ILPVault.release, (keyB, attacker)));
        vm.prank(adapter);
        vault.unwind(key, credit, 0, 0, recipient);
        assertTrue(MintableToken(t0).hookReverted());
        assertEq(bytes4(MintableToken(t0).hookResult()), ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector);
        assertEq(positions.ownerOf(uint256(keyB)), address(vault));
        assertEq(_held(key), 0);
    }
}

/// @notice Hostile tokens in the pair: the vault pays only what it measured and never from another position.
contract LPVaultUniswapV2HostileTokenUnitTest is UniswapV2TestBase {
    function test_feeOnTransfer_unwindPaysOnlyWhatArrived() public {
        FeeOnTransferToken fot = new FeeOnTransferToken(100);
        _deploy(address(fot), address(new MintableToken("B", 18)), 1000e18, 1000e18);
        (bytes32 key, uint128 credit) = _position(user, 100e18, 100e18);
        (bytes32 keyB,) = _position(other, 100e18, 100e18);
        uint256 heldB = _held(keyB);
        vm.prank(adapter);
        (,, uint256 a0, uint256 a1) = vault.unwind(key, credit / 2, 0, 0, recipient);
        assertGt(a0, 0);
        assertGt(a1, 0);
        assertEq(_bal(t0, address(vault)), 0);
        assertEq(_bal(t1, address(vault)), 0);
        assertEq(_held(keyB), heldB);
        // The recipient got what the vault measured, less the token's own fee on the last hop.
        address fotToken = address(fot);
        uint256 got = _bal(fotToken, recipient) + _bal(fotToken == t0 ? t1 : t0, recipient);
        assertLe(got, a0 + a1);
    }

    function test_negativeRebaseAndSync_unwindTakesOnlyTheOwnLP() public {
        RebasingToken reb = new RebasingToken();
        _deploy(address(reb), address(new MintableToken("B", 18)), 1000e18, 1000e18);
        (bytes32 key, uint128 credit) = _position(user, 100e18, 100e18);
        (bytes32 keyB,) = _position(other, 100e18, 100e18);
        uint256 heldB = _held(keyB);
        reb.rebase(5000);
        pair.sync();
        // The live liquidity fell under the record: the risk is visible, and the unwind still only burns this position.
        (,,, uint128 live) = vault.positionInfo(key);
        assertLt(live, credit);
        vm.prank(adapter);
        vault.unwind(key, credit, 0, 0, recipient);
        assertEq(_held(key), 0);
        assertEq(_held(keyB), heldB);
        assertEq(_bal(t0, address(vault)), 0);
        assertEq(_bal(t1, address(vault)), 0);
    }
}
