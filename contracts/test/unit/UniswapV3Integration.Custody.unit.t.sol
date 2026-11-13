// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ClPriceMath} from "../../src/amm/concentrated-liquidity/ClPriceMath.sol";
import {FeeMode} from "../../src/amm/types/FeeMode.sol";
import {UniswapV3IntegrationFixture} from "../utils/fixtures/UniswapV3IntegrationFixture.sol";
import {MintableToken, MockNFPM} from "../utils/mocks/UniswapV3Mocks.sol";
import {IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Uniswap v3 LPVault custody: pledge, return, exact-unit removal with the principal-capped collect, partial
/// release, fee collection, the top-up refusal, custody views under the Lock and re-entry from a pool token.
/// forge-config: default.isolate = false
contract UniswapV3IntegrationCustodyUnitTest is UniswapV3IntegrationFixture {
    // ─── receivePosition ───

    // TEST-010 verifies: REQ-AMM-CORE-005, REQ-VAULT-147, REQ-VAULT-167, REQ-VAULT-011, REQ-VAULT-154, INV-006, DEP-008
    // Sources: 5.1 TEST-010 (the LPVault's part: custody, depositor of record, units read after custody)
    function test_TEST_010_receivePositionTakesCustodyFromTheOwner() public {
        bytes32 key = _mint1(alice, 1e9);
        _lock();
        vm.expectEmit(address(vault));
        emit PositionReceived(key, M1, alice, 1e9);
        vm.prank(coll);
        uint128 units = vault.receivePosition(M1, alice, key);
        _unlock();
        assertEq(units, 1e9);
        assertEq(nfpm.ownerOf(uint256(key)), address(vault));
        assertEq(vault.depositorOf(key), alice);
        assertEq(vault.marketOfPosition(key), M1);
        assertTrue(vault.isInCustody(key));
        assertEq(vault.unitsOf(key), 1e9);
        assertEq(nfpm.getApproved(uint256(key)), address(0), "the pull clears the per-token approval");
    }

    // TEST-011 verifies: REQ-VAULT-156, REQ-VAULT-157, REQ-VAULT-150, REQ-AMM-CORE-005, INV-091
    function test_TEST_011_receiveRefusesOtherCallersAndAFreeLock() public {
        bytes32 key = _mint1(alice, 1e9);
        vm.prank(alice);
        vm.expectRevert(NotCollateralization.selector);
        vault.receivePosition(M1, alice, key);
        vm.prank(coll);
        vm.expectRevert(LockNotHeld.selector);
        vault.receivePosition(M1, alice, key);
        _lock();
        vm.prank(adapter);
        vm.expectRevert(NotCollateralization.selector);
        vault.receivePosition(M1, alice, key);
        vm.prank(coll);
        vm.expectRevert(abi.encodeWithSelector(MarketBinding.selector, uint256(99)));
        vault.receivePosition(99, alice, key);
        _unlock();
        // LPVaultSwap holding the Lock is also a held Lock (seizure path).
        vm.prank(lpVaultSwap);
        lock.acquire();
        vm.prank(coll);
        assertEq(vault.receivePosition(M1, alice, key), 1e9);
        vm.prank(lpVaultSwap);
        lock.release();
    }

    // TEST-011 verifies: REQ-VAULT-101, REQ-VAULT-147, REQ-AMM-CORE-005, REQ-VAULT-153, ATTACK-003, Q-258
    // Sources: 5.1 TEST-011 (owner checks: per-token operator, setApprovalForAll holder, the LPVault itself)
    function test_TEST_011_receiveRequiresTheOwner() public {
        bytes32 key = _mint1(alice, 1e9);
        vm.prank(alice);
        nfpm.setApprovalForAll(bob, true);
        _lock();
        vm.startPrank(coll);
        vm.expectRevert(NotTokenOwner.selector);
        vault.receivePosition(M1, bob, key);
        vm.expectRevert(NotTokenOwner.selector);
        vault.receivePosition(M1, address(vault), key);
        vm.stopPrank();
        _unlock();
        // Without the owner's approval the NFPM's own error passes through.
        bytes32 k2 = bytes32(nfpm.mint(carol, pool500.token0(), pool500.token1(), 500, -50, 50, 1e9));
        _lock();
        vm.prank(coll);
        vm.expectRevert(
            abi.encodeWithSelector(IERC721Errors.ERC721InsufficientApproval.selector, address(vault), uint256(k2))
        );
        vault.receivePosition(M1, carol, k2);
        _unlock();
    }

    // TEST-011 verifies: REQ-VAULT-008, REQ-VAULT-009, REQ-AMM-CORE-006, REQ-AMM-CORE-016, REQ-VAULT-173, REQ-AMM-V3-009, INV-005, ATTACK-001, REQ-RISK-012, REQ-RISK-027
    // Sources: 5.1 TEST-011, TEST-279 (exact range); AMM-A6a–c
    function test_TEST_011_receiveRequiresThePoolAndTheExactRange() public {
        bytes32 other = _mint(alice, pool3000, -60, 60, 1e9);
        bytes32 narrow = _mint(alice, pool500, -40, 50, 1e9);
        bytes32 wide = _mint(alice, pool500, -60, 50, 1e9);
        bytes32 upper = _mint(alice, pool500, -50, 60, 1e9);
        uint256 orphanId = nfpm.mint(alice, address(usdc), address(0xdead), 500, -50, 50, 1e9);
        _lock();
        vm.startPrank(coll);
        vm.expectRevert(PoolMismatch.selector);
        vault.receivePosition(M1, alice, other);
        vm.expectRevert(PoolMismatch.selector);
        vault.receivePosition(M1, alice, bytes32(orphanId));
        vm.expectRevert(abi.encodeWithSelector(RangeMismatch.selector, int24(-40), int24(50)));
        vault.receivePosition(M1, alice, narrow);
        vm.expectRevert(abi.encodeWithSelector(RangeMismatch.selector, int24(-60), int24(50)));
        vault.receivePosition(M1, alice, wide);
        vm.expectRevert(abi.encodeWithSelector(RangeMismatch.selector, int24(-50), int24(60)));
        vault.receivePosition(M1, alice, upper);
        vm.stopPrank();
        _unlock();
    }

    // TEST-011 verifies: REQ-VAULT-012, REQ-AMM-CORE-005, REQ-AMM-V3-010, REQ-AMM-CORE-018, REQ-AMM-V3-003
    function test_TEST_011_receiveRefusesZeroUnitsAndALockedPool() public {
        bytes32 empty = _mint1(alice, 0);
        bytes32 key = _mint1(bob, 1e9);
        _lock();
        vm.prank(coll);
        vm.expectRevert(ZeroUnits.selector);
        vault.receivePosition(M1, alice, empty);
        pool500.setUnlocked(false);
        vm.prank(coll);
        vm.expectRevert(PoolLocked.selector);
        vault.receivePosition(M1, bob, key);
        _unlock();
        vm.expectRevert(PoolLocked.selector);
        vault.validatePosition(M1, bob, key);
    }

    // TEST-011 verifies: REQ-AMM-CORE-005, REQ-RISK-031, ATTACK-001
    function test_TEST_011_validatePositionAndASecondPledge() public {
        bytes32 key = _mint1(alice, 7e8);
        assertEq(vault.validatePosition(M1, alice, key), 7e8);
        assertEq(vault.positionOwner(key), alice);
        assertEq(vault.positionOwner(bytes32(uint256(999))), address(0), "unknown token");
        _receive(M1, alice, key);
        assertEq(vault.positionOwner(key), address(vault));
        // A custodied NFT is owned by the LPVault, so no owner can pledge it again into any market.
        _lock();
        vm.prank(coll);
        vm.expectRevert(NotTokenOwner.selector);
        vault.receivePosition(M1, alice, key);
        _unlock();
    }

    // ─── returnPosition ───

    // TEST-016 verifies: REQ-AMM-CORE-007, REQ-VAULT-148, REQ-VAULT-168, REQ-VAULT-094, REQ-VAULT-077, INV-045
    function test_TEST_016_returnSendsTheWholeNftToTheDepositor() public {
        bytes32 key = _pledge1(alice, 1e9);
        nfpm.increaseLiquidity(uint256(key), 5e8);
        nfpm.accrue(uint256(key), 12_400_000, 0);
        _lock();
        vm.expectEmit(address(vault));
        emit PositionReturned(key, alice);
        vm.prank(coll);
        address d = vault.returnPosition(key);
        _unlock();
        assertEq(d, alice);
        assertEq(nfpm.ownerOf(uint256(key)), alice);
        assertEq(vault.depositorOf(key), address(0));
        assertEq(vault.marketOfPosition(key), 0);
        (,,,,,,, uint128 l,,, uint128 owed0,) = nfpm.positions(uint256(key));
        assertEq(l, 1.5e9, "donated liquidity goes back with the NFT");
        assertEq(owed0, 12_400_000, "owed fees go back with the NFT");
    }

    // TEST-016 verifies: REQ-VAULT-158, REQ-VAULT-156, REQ-VAULT-157
    function test_TEST_016_returnRefusals() public {
        bytes32 key = _pledge1(alice, 1e9);
        vm.prank(coll);
        vm.expectRevert(LockNotHeld.selector);
        vault.returnPosition(key);
        _lock();
        vm.prank(alice);
        vm.expectRevert(NotCollateralization.selector);
        vault.returnPosition(key);
        vm.prank(coll);
        vm.expectRevert(NotInCustody.selector);
        vault.returnPosition(bytes32(uint256(77)));
        _unlock();
    }

    // ─── unwind and releaseToDepositor ───

    // TEST-058 verifies: REQ-VAULT-149, REQ-VAULT-169, REQ-VAULT-057, REQ-VAULT-058, REQ-VAULT-067, REQ-VAULT-095, SPEC-BACK-008, ATTACK-015
    // Sources: 5.1 TEST-058; MATH-ST-32…35
    function test_TEST_058_unwindRemovesExactUnitsAndCollectsOnlyPrincipal() public {
        bytes32 key = _pledge1(alice, 1e12);
        nfpm.accrue(uint256(key), 3_000_000, 4_000_000);
        uint256 b0 = _token0().balanceOf(lpVaultSwap);
        uint256 b1 = _token1().balanceOf(lpVaultSwap);
        uint256[] memory amounts =
            abi.decode(_asColl(abi.encodeCall(vault.unwind, (key, 4e11, _zeros(), lpVaultSwap))), (uint256[]));
        (,,,,,,, uint128 l,,, uint128 owed0, uint128 owed1) = nfpm.positions(uint256(key));
        assertEq(l, 6e11, "exactly the units asked");
        assertEq(owed0, 3_000_000, "fees stay owed to the NFT");
        assertEq(owed1, 4_000_000);
        assertGt(amounts[0], 0);
        assertEq(_token0().balanceOf(lpVaultSwap) - b0, amounts[0], "principal of token0 to the recipient");
        assertEq(_token1().balanceOf(lpVaultSwap) - b1, amounts[1]);
        assertEq(_token0().balanceOf(address(vault)), 0, "the LPVault holds no pool token");
        // After the last liquidity leaves, the depositor still collects every owed fee.
        _asColl(abi.encodeCall(vault.unwind, (key, 6e11, _zeros(), lpVaultSwap)));
        uint256[] memory fees = abi.decode(_asColl(abi.encodeCall(vault.collectFees, (key, alice))), (uint256[]));
        assertEq(fees[0], 3_000_000);
        assertEq(fees[1], 4_000_000);
    }

    // TEST-058 verifies: REQ-VAULT-149, REQ-VAULT-159, REQ-AMM-CORE-008, REQ-AMM-CORE-002, REQ-AMM-V3-010
    function test_TEST_058_unwindRefusals() public {
        bytes32 key = _pledge1(alice, 1e12);
        _lock();
        vm.startPrank(coll);
        vm.expectRevert(InvalidRecipient.selector);
        vault.unwind(key, 1, _zeros(), address(0));
        vm.expectRevert(InvalidRecipient.selector);
        vault.unwind(key, 1, _zeros(), address(vault));
        vm.expectRevert(abi.encodeWithSelector(LengthMismatch.selector, uint256(2), uint256(3)));
        vault.unwind(key, 1, new uint256[](3), lpVaultSwap);
        vm.expectRevert(NotInCustody.selector);
        vault.unwind(bytes32(uint256(42)), 1, _zeros(), lpVaultSwap);
        pool500.setUnlocked(false);
        vm.expectRevert(PoolLocked.selector);
        vault.unwind(key, 1, _zeros(), lpVaultSwap);
        vm.expectRevert(PoolLocked.selector);
        vault.releaseToDepositor(key, 1, _zeros());
        vm.stopPrank();
        _unlock();
        vm.prank(coll);
        vm.expectRevert(LockNotHeld.selector);
        vault.unwind(key, 1, _zeros(), lpVaultSwap);
    }

    // TEST-177 verifies: REQ-VAULT-058, SPEC-BACK-008, Q-217
    // Sources: 5.1 TEST-177 (a collection whose every cap is zero is never called)
    function test_TEST_177_zeroAmountRemovalSkipsTheCollect() public {
        bytes32 key = _pledge1(alice, 1e12);
        uint256 collects = nfpm.collectCalls();
        uint256[] memory amounts =
            abi.decode(_asColl(abi.encodeCall(vault.unwind, (key, 1, _zeros(), lpVaultSwap))), (uint256[]));
        assertEq(amounts[0], 0);
        assertEq(amounts[1], 0);
        assertEq(nfpm.collectCalls(), collects, "no collect with two zero caps");
        (,,,,,,, uint128 l,,,,) = nfpm.positions(uint256(key));
        assertEq(l, 1e12 - 1, "the unit is still removed");
    }

    // TEST-237 verifies: REQ-VAULT-161, REQ-VAULT-170, REQ-VAULT-099, REQ-VAULT-163, REQ-AMM-V3-011, SPEC-BACK-008, INV-088
    // Sources: 5.1 TEST-237 (the LPVault's part: principal only to the depositor, the depositor's minimums)
    function test_TEST_237_releaseToDepositorPaysOnlyTheDepositor() public {
        bytes32 key = _pledge1(alice, 1e12);
        nfpm.accrue(uint256(key), 1_000_000, 0);
        vm.expectRevert(bytes("Price slippage check"));
        this.callAsColl(abi.encodeCall(vault.releaseToDepositor, (key, 1e11, _vec(1e12, 0))));
        uint256 before = _token0().balanceOf(alice);
        uint256[] memory amounts =
            abi.decode(_asColl(abi.encodeCall(vault.releaseToDepositor, (key, 1e11, _vec(1, 1)))), (uint256[]));
        assertEq(_token0().balanceOf(alice) - before, amounts[0]);
        (,,,,,,, uint128 l,,, uint128 owed0,) = nfpm.positions(uint256(key));
        assertEq(l, 9e11);
        assertEq(owed0, 1_000_000, "fees stay owed");
        assertEq(vault.depositorOf(key), alice, "the position stays in custody");
    }

    // TEST-237 verifies: REQ-VAULT-163, REQ-AMM-CORE-007
    // Sources: a position manager that reports less than the minimum without its own check
    function test_TEST_237_belowMinimumWhenTheManagerSkipsItsCheck() public {
        bytes32 key = _pledge1(alice, 1e12);
        nfpm.setOverride(true, 5, 7);
        _lock();
        vm.prank(coll);
        vm.expectRevert(abi.encodeWithSelector(BelowMinimum.selector, uint256(1), uint256(7), uint256(8)));
        vault.releaseToDepositor(key, 1e9, _vec(5, 8));
        _unlock();
    }

    /// @dev Lets `vm.expectRevert` target a whole Lock session.
    function callAsColl(
        bytes memory data
    ) external returns (bytes memory) {
        return _asColl(data);
    }

    // ─── collectFees ───

    // TEST-017 verifies: REQ-AMM-CORE-010, REQ-VAULT-064, REQ-VAULT-065, REQ-VAULT-172, REQ-VAULT-066, INV-044, FEE-001, FEE-006
    // Sources: 5.1 TEST-017 (owed principal from before the pledge is paid with the fees; liquidity unchanged)
    function test_TEST_017_collectFeesPaysEveryOwedAmountToTheDepositor() public {
        bytes32 key = _mint1(alice, 1e12);
        nfpm.accrue(uint256(key), 50_000_000, 0); // principal owed at pledge, never credited
        _receive(M1, alice, key);
        nfpm.accrue(uint256(key), 3_000_000, 2_000_000);
        uint256 b0 = _token0().balanceOf(alice);
        pool500.setUnlocked(false); // the LPVault reads no pool state for fees
        _lock();
        vm.expectEmit(address(vault));
        emit FeesCollected(key, alice, _vec(53_000_000, 2_000_000));
        vm.prank(coll);
        uint256[] memory fees = vault.collectFees(key, alice);
        _unlock();
        assertEq(fees[0], 53_000_000);
        assertEq(_token0().balanceOf(alice) - b0, 53_000_000);
        assertEq(vault.unitsOf(key), 1e12, "no unit changes");
        // A zero result pays 0 and does not revert.
        fees = abi.decode(_asColl(abi.encodeCall(vault.collectFees, (key, alice))), (uint256[]));
        assertEq(fees[0] + fees[1], 0);
    }

    // TEST-017 verifies: REQ-VAULT-064, REQ-VAULT-120, REQ-VAULT-156, REQ-VAULT-157
    function test_TEST_017_collectFeesRefusals() public {
        bytes32 key = _pledge1(alice, 1e12);
        _lock();
        vm.startPrank(coll);
        vm.expectRevert(NotDepositor.selector);
        vault.collectFees(key, bob);
        vm.expectRevert(NotInCustody.selector);
        vault.collectFees(bytes32(uint256(55)), alice);
        vm.stopPrank();
        vm.prank(alice);
        vm.expectRevert(NotCollateralization.selector);
        vault.collectFees(key, alice);
        _unlock();
        vm.prank(coll);
        vm.expectRevert(LockNotHeld.selector);
        vault.collectFees(key, alice);
    }

    // TEST-017 verifies: REQ-VAULT-064, REQ-VAULT-150, REQ-AMM-CORE-010
    // Sources: review CL-04 PoC (fee collection accepted under LPVaultSwap's Lock); 2.2 REQ-VAULT-064 (the AaveAdapter)
    function test_TEST_017_collectFeesNeedsTheAaveAdapterAsLockHolder() public {
        bytes32 key = _pledge1(alice, 1e12);
        nfpm.accrue(uint256(key), 7, 9);
        vm.prank(lpVaultSwap);
        lock.acquire();
        vm.prank(coll);
        vm.expectRevert(LockNotHeld.selector);
        vault.collectFees(key, alice);
        vm.prank(lpVaultSwap);
        lock.release();
        uint256[] memory fees = abi.decode(_asColl(abi.encodeCall(vault.collectFees, (key, alice))), (uint256[]));
        assertEq(fees[0] + fees[1], 16, "the AaveAdapter's session collects");
    }

    // TEST-238 verifies: REQ-AMM-CORE-011, REQ-COLL-037
    function test_TEST_238_topUpIsNotSupportedForNfts() public {
        bytes32 key = _pledge1(alice, 1e12);
        _lock();
        vm.prank(coll);
        vm.expectRevert(TopUpNotSupported.selector);
        vault.topUpPosition(key, alice, hex"01");
        vm.prank(alice);
        vm.expectRevert(NotCollateralization.selector);
        vault.topUpPosition(key, alice, hex"01");
        _unlock();
    }

    // ─── Custody views ───

    // TEST-222 verifies: REQ-VAULT-151, REQ-VAULT-160, REQ-AMM-CORE-009, REQ-VAULT-162, REQ-VAULT-171
    function test_TEST_222_custodyViewsRefuseOutsidersWhileTheLockIsHeld() public {
        bytes32 key = _pledge1(alice, 1e9);
        nfpm.increaseLiquidity(uint256(key), 1);
        _lock();
        vm.expectRevert(Locked.selector);
        vault.depositorOf(key);
        vm.expectRevert(Locked.selector);
        vault.marketOfPosition(key);
        vm.expectRevert(Locked.selector);
        vault.isInCustody(key);
        vm.expectRevert(Locked.selector);
        vault.unitsOf(key);
        vm.startPrank(coll);
        assertEq(vault.depositorOf(key), alice);
        assertEq(vault.unitsOf(key), 1e9 + 1, "live units include added liquidity");
        vm.expectRevert(NotInCustody.selector);
        vault.unitsOf(bytes32(uint256(1234)));
        pool500.setUnlocked(false);
        vm.expectRevert(PoolLocked.selector);
        vault.unitsOf(key);
        vm.stopPrank();
        _unlock();
        // Lock free: anyone reads; the pool lock is checked only under the Lock.
        assertEq(vault.unitsOf(key), 1e9 + 1);
        // Views that never revert on the Lock.
        _lock();
        vault.composition(M1, 1e9, _vec(1e8, 1e8));
        vault.marketOf(M1);
        vault.riskMetadata(M1, key);
        vault.capabilities();
        _unlock();
    }

    // TEST-222 verifies: REQ-VAULT-067, REQ-VAULT-150, REQ-VAULT-151, ATTACK-092
    // Sources: 5.1 TEST-222 (a pool token with a transfer hook re-enters during the principal payout)
    function test_TEST_222_reentryFromAPoolTokenDuringTheCollectChangesNothing() public {
        bytes32 key = _pledge1(alice, 1e12);
        bytes32 other = _mint1(bob, 1e9);
        MintableToken t0 = _token0();
        t0.setHook(address(vault), abi.encodeCall(vault.depositorOf, (key)));
        _asColl(abi.encodeCall(vault.unwind, (key, 1e11, _zeros(), lpVaultSwap)));
        assertTrue(t0.hookReverted(), "custody view refused mid-call");
        assertEq(bytes4(t0.hookResult()), Locked.selector);
        t0.setHook(address(vault), abi.encodeCall(vault.receivePosition, (M1, bob, other)));
        _asColl(abi.encodeCall(vault.unwind, (key, 1e11, _zeros(), lpVaultSwap)));
        assertEq(bytes4(t0.hookResult()), NotCollateralization.selector);
        t0.setHook(address(vault), abi.encodeCall(vault.collectFees, (key, alice)));
        _asColl(abi.encodeCall(vault.releaseToDepositor, (key, 1e11, _zeros())));
        assertEq(bytes4(t0.hookResult()), NotCollateralization.selector);
        assertEq(nfpm.ownerOf(uint256(other)), bob);
        assertEq(vault.unitsOf(key), 7e11);
    }

    // TEST-074 verifies: REQ-VAULT-095, SPEC-BACK-008, Q-061
    // Sources: 5.1 TEST-074 (the LPVault's part: split removals never return more than one removal)
    function testFuzz_TEST_074_splitUnwindNeverReturnsMore(
        uint128 total,
        uint8 pieces,
        int24 tickSeed
    ) public {
        total = uint128(bound(total, 1e6, 1e20));
        pieces = uint8(bound(pieces, 2, 12));
        pool500.setPrice(int24(bound(int256(tickSeed), -60, 60)));
        bytes32 a = _pledge1(alice, total);
        bytes32 b = _pledge1(bob, total);
        uint256[] memory whole =
            abi.decode(_asColl(abi.encodeCall(vault.unwind, (a, total, _zeros(), lpVaultSwap))), (uint256[]));
        uint256 s0;
        uint256 s1;
        uint128 left = total;
        for (uint256 i = 0; i < pieces; ++i) {
            uint128 take = i + 1 == pieces ? left : total / pieces;
            left -= take;
            uint256[] memory part =
                abi.decode(_asColl(abi.encodeCall(vault.unwind, (b, take, _zeros(), lpVaultSwap))), (uint256[]));
            s0 += part[0];
            s1 += part[1];
        }
        assertLe(s0, whole[0]);
        assertLe(s1, whole[1]);
        assertEq(vault.unitsOf(b), 0);
    }

    // TEST-058 verifies: REQ-VAULT-095, REQ-VAULT-149, SPEC-BACK-008
    function testFuzz_TEST_058_unwindTakesExactlyTheUnits(
        uint128 liquidity,
        uint128 take
    ) public {
        liquidity = uint128(bound(liquidity, 1, ClPriceMath.MAX_SQRT_RATIO >> 64));
        take = uint128(bound(take, 1, liquidity));
        bytes32 key = _pledge1(alice, liquidity);
        nfpm.accrue(uint256(key), 11, 13);
        _asColl(abi.encodeCall(vault.unwind, (key, take, _zeros(), lpVaultSwap)));
        (,,,,,,, uint128 l,,, uint128 owed0, uint128 owed1) = nfpm.positions(uint256(key));
        assertEq(l, liquidity - take);
        assertEq(owed0, 11);
        assertEq(owed1, 13);
    }

    // TEST-017 verifies: REQ-VAULT-126, REQ-VAULT-064, REQ-AMM-CORE-010
    // Sources: 2.2 REQ-VAULT-126 (the upstream error, no state change, position and fee claim intact)
    /// @notice A pool token that refuses the depositor (a blocklist) and a position manager that reverts in `collect`
    /// (a pool inside a callback) make `collectFees` revert with the upstream error unchanged; the position stays in
    /// custody with its depositor, units and owed fees, and the next collection pays every owed amount.
    /// @dev Kills: the LPVault catching, re-wrapping or partly applying a failed fee collection.
    function test_TEST_017_upstreamRevertKeepsPositionAndFeeClaim() public {
        bytes32 key = _pledge1(alice, 1e12);
        nfpm.accrue(uint256(key), 3_000_000, 2_000_000);
        bytes memory blocked = abi.encodeWithSignature("Blocklisted(address)", alice);
        vm.mockCallRevert(address(_token0()), abi.encodeWithSelector(IERC20.transfer.selector, alice), blocked);
        _lock();
        vm.prank(coll);
        vm.expectRevert(blocked);
        vault.collectFees(key, alice);
        _unlock();
        vm.clearMockedCalls();
        vm.mockCallRevert(address(nfpm), abi.encodeWithSelector(MockNFPM.collect.selector), bytes("LOK"));
        _lock();
        vm.prank(coll);
        vm.expectRevert(bytes("LOK"));
        vault.collectFees(key, alice);
        _unlock();
        vm.clearMockedCalls();
        assertEq(nfpm.ownerOf(uint256(key)), address(vault), "still in custody");
        assertEq(vault.depositorOf(key), alice, "same depositor");
        assertEq(vault.unitsOf(key), 1e12, "same units");
        (,,,,,,,,,, uint128 owed0, uint128 owed1) = nfpm.positions(uint256(key));
        assertEq(owed0, 3_000_000, "fees still owed");
        assertEq(owed1, 2_000_000);
        uint256[] memory fees = abi.decode(_asColl(abi.encodeCall(vault.collectFees, (key, alice))), (uint256[]));
        assertEq(fees[0], 3_000_000, "the claim is intact");
        assertEq(fees[1], 2_000_000);
        assertEq(uint8(vault.capabilities().feeMode), uint8(FeeMode.Separate), "fees are collected, not rolled in");
    }
}
