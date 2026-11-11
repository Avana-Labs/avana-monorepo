// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ClPriceMath} from "../../src/amm/concentrated-liquidity/ClPriceMath.sol";
import {SlipstreamIntegrationFixture} from "../utils/fixtures/SlipstreamIntegrationFixture.sol";
import {MockSlipstreamNPM} from "../utils/mocks/SlipstreamMocks.sol";
import {MintableToken} from "../utils/mocks/UniswapV3Mocks.sol";
import {IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

/// @notice Slipstream LPVault custody: pledge across generations, the gauge check, return, exact-unit removal with the
/// principal-capped collect, partial release, fee collection, the top-up refusal, custody views under the Lock and
/// re-entry from a pool token.
/// forge-config: default.isolate = false
contract SlipstreamIntegrationCustodyUnitTest is SlipstreamIntegrationFixture {
    // ─── receivePosition ───

    // TEST-010 verifies: REQ-AMM-CORE-005, REQ-VAULT-147, REQ-VAULT-167, REQ-VAULT-011, REQ-VAULT-154, REQ-AMM-SLIP-001, REQ-AMM-SLIP-003, INV-006, DEP-008
    // Sources: 5.1 TEST-010 (the LPVault's part), 3.1 DEP-029 (Slipstream pledge)
    function test_TEST_010_receivePositionTakesCustodyFromTheOwner() public {
        bytes32 key = _mint1(alice, 1e9);
        assertEq(uint256(key) >> 248, G1, "the generation is the key's high byte");
        _lock();
        vm.expectEmit(address(vault));
        emit PositionReceived(key, M1, alice, 1e9);
        vm.prank(coll);
        uint128 units = vault.receivePosition(M1, alice, key);
        _unlock();
        assertEq(units, 1e9);
        assertEq(_npm1().ownerOf(_id(key)), address(vault));
        assertEq(vault.depositorOf(key), alice);
        assertEq(vault.marketOfPosition(key), M1);
        assertTrue(vault.isInCustody(key));
        assertEq(vault.unitsOf(key), 1e9);
        assertEq(_npm1().getApproved(_id(key)), address(0), "the pull clears the per-token approval");
        assertEq(vault.positionOwner(key), address(vault));
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
        vm.prank(lpVaultSwap);
        lock.acquire();
        vm.prank(coll);
        assertEq(vault.receivePosition(M1, alice, key), 1e9);
        vm.prank(lpVaultSwap);
        lock.release();
    }

    // TEST-011 verifies: REQ-VAULT-101, REQ-VAULT-147, REQ-AMM-CORE-005, REQ-VAULT-153, ATTACK-003, Q-258
    function test_TEST_011_receiveRequiresTheOwner() public {
        bytes32 key = _mint1(alice, 1e9);
        vm.prank(alice);
        _npm1().setApprovalForAll(bob, true);
        _lock();
        vm.startPrank(coll);
        vm.expectRevert(NotTokenOwner.selector);
        vault.receivePosition(M1, bob, key);
        vm.expectRevert(NotTokenOwner.selector);
        vault.receivePosition(M1, address(vault), key);
        vm.stopPrank();
        _unlock();
        uint256 id2 = _npm1().mint(carol, pool1.token0(), pool1.token1(), 1, -50, 50, 1e9);
        bytes32 k2 = _key(G1, id2);
        _lock();
        vm.prank(coll);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721InsufficientApproval.selector, address(vault), id2));
        vault.receivePosition(M1, carol, k2);
        _unlock();
    }

    // TEST-011 verifies: REQ-VAULT-008, REQ-VAULT-009, REQ-AMM-CORE-006, REQ-AMM-CORE-016, REQ-AMM-SLIP-002, REQ-AMM-SLIP-018, INV-005, ATTACK-001
    // Sources: 5.1 TEST-011, TEST-279 (exact range); 2.21 REQ-AMM-SLIP-002 (pool by tick spacing)
    function test_TEST_011_receiveRequiresThePoolAndTheExactRange() public {
        address spacing50 = factories[G1].createPool(address(usdc), address(usdt), 50);
        bytes32 other = _mint(alice, G1, pool1, -50, 50, 1e9);
        // Same pair and ticks, spacing 50: getPool resolves the spacing-50 pool, not the market's.
        uint256 otherId = _npm1().mint(alice, pool1.token0(), pool1.token1(), 50, -50, 50, 1e9);
        bytes32 narrow = _mint(alice, G1, pool1, -40, 50, 1e9);
        bytes32 wide = _mint(alice, G1, pool1, -60, 50, 1e9);
        bytes32 upper = _mint(alice, G1, pool1, -50, 60, 1e9);
        uint256 orphanId = _npm1().mint(alice, address(usdc), address(0xdead), 1, -50, 50, 1e9);
        vm.prank(alice);
        _npm1().setApprovalForAll(address(vault), true);
        assertTrue(spacing50 != address(pool1));
        _lock();
        vm.startPrank(coll);
        vm.expectRevert(PoolMismatch.selector);
        vault.receivePosition(M1, alice, _key(G1, otherId));
        vm.expectRevert(PoolMismatch.selector);
        vault.receivePosition(M1, alice, _key(G1, orphanId));
        vm.expectRevert(abi.encodeWithSelector(RangeMismatch.selector, int24(-40), int24(50)));
        vault.receivePosition(M1, alice, narrow);
        vm.expectRevert(abi.encodeWithSelector(RangeMismatch.selector, int24(-60), int24(50)));
        vault.receivePosition(M1, alice, wide);
        vm.expectRevert(abi.encodeWithSelector(RangeMismatch.selector, int24(-50), int24(60)));
        vault.receivePosition(M1, alice, upper);
        assertEq(vault.receivePosition(M1, alice, other), 1e9);
        vm.stopPrank();
        _unlock();
    }

    // TEST-265 verifies: REQ-AMM-SLIP-001, REQ-AMM-SLIP-007, REQ-AMM-SLIP-018, REQ-AMM-SLIP-006, INV-005, INV-017
    // Sources: 2.21 REQ-AMM-SLIP-001 (the manager comes from the key; token IDs overlap across generations)
    function test_TEST_265_aPositionOfAnotherGenerationIsRefused() public {
        // The same token ID, pair, spacing and ticks on generations 0, 1 and 3: only generation 2 matches market 1.
        uint256 id = 7777;
        for (uint8 g = 0; g < 4; ++g) {
            npms[g].mintId(id, alice, pool1.token0(), pool1.token1(), 1, -50, 50, 1e9 + g);
            vm.prank(alice);
            npms[g].approve(address(vault), id);
        }
        _lock();
        vm.startPrank(coll);
        for (uint8 g = 0; g < 4; ++g) {
            if (g == G1) continue;
            vm.expectRevert(PoolMismatch.selector);
            vault.receivePosition(M1, alice, _key(g, id));
        }
        assertEq(vault.receivePosition(M1, alice, _key(G1, id)), 1e9 + G1, "units come from the key's manager");
        vm.stopPrank();
        _unlock();
        for (uint8 g = 0; g < 4; ++g) {
            assertEq(npms[g].ownerOf(id), g == G1 ? address(vault) : alice, "only the key's manager moved an NFT");
        }
        assertFalse(vault.isInCustody(_key(0, id)), "keys of one token ID differ per generation");
    }

    // TEST-265 verifies: REQ-AMM-SLIP-001, REQ-AMM-SLIP-007, REQ-AMM-SLIP-018, INV-005
    // Sources: review CL-02 PoC (generation 0's factory resolving market 1's pool); 2.21 REQ-AMM-SLIP-007 (the key's
    // generation must equal the market's, whatever another generation's factory returns)
    function test_TEST_265_theKeysGenerationMustBeTheMarketsEvenIfItsFactoryResolvesThePool() public {
        factories[0].register(pool1.token0(), pool1.token1(), 1, address(pool1));
        uint256 id = npms[0].mint(alice, pool1.token0(), pool1.token1(), 1, M1_LOWER, M1_UPPER, 1e9);
        vm.prank(alice);
        npms[0].approve(address(vault), id);
        bytes32 key0 = _key(0, id);
        vm.expectRevert(PoolMismatch.selector);
        vault.validatePosition(M1, alice, key0);
        _lock();
        vm.prank(coll);
        vm.expectRevert(PoolMismatch.selector);
        vault.receivePosition(M1, alice, key0);
        _unlock();
        assertEq(npms[0].ownerOf(id), alice, "nothing moved");
        assertFalse(vault.isInCustody(key0));
    }

    // TEST-265 verifies: REQ-AMM-SLIP-001, REQ-AMM-SLIP-018, REQ-VAULT-124
    // Sources: 2.21 REQ-AMM-SLIP-001 (a generation byte outside the allowlist names no manager)
    function test_TEST_265_aKeyOutsideTheAllowlistIsUnsupported() public {
        bytes32 bad = _key(4, 1);
        bytes32 worse = bytes32(type(uint256).max);
        vm.expectRevert(UnsupportedNft.selector);
        vault.positionOwner(bad);
        vm.expectRevert(UnsupportedNft.selector);
        vault.validatePosition(M1, alice, worse);
        _lock();
        vm.prank(coll);
        vm.expectRevert(UnsupportedNft.selector);
        vault.receivePosition(M1, alice, bad);
        _unlock();
        vm.prank(timelock);
        vm.expectRevert(UnsupportedNft.selector);
        vault.returnStray(bad, alice);
        vm.expectRevert(NotInCustody.selector);
        vault.unitsOf(bad);
        assertEq(vault.tokenIdOf(bad), 1);
    }

    // TEST-265 verifies: REQ-AMM-SLIP-009, REQ-AMM-SLIP-019, REQ-AMM-SLIP-010, REQ-AMM-CORE-005, REQ-VAULT-147
    // Sources: 2.21 REQ-AMM-SLIP-009 (owner check refuses the staker; the gauge named as owner is encumbered)
    function test_TEST_265_aStakedPositionIsRefused() public {
        bytes32 key = _mint1(alice, 1e9);
        uint256 id = _id(key);
        vm.startPrank(alice);
        _npm1().approve(address(gauge1), id);
        gauge1.deposit(id);
        vm.stopPrank();
        assertTrue(vault.isStaked(M1, id));
        assertEq(vault.positionOwner(key), address(gauge1));
        _lock();
        vm.startPrank(coll);
        vm.expectRevert(NotTokenOwner.selector);
        vault.receivePosition(M1, alice, key);
        vm.expectRevert(PositionEncumbered.selector);
        vault.receivePosition(M1, address(gauge1), key);
        vm.stopPrank();
        _unlock();
        vm.expectRevert(PositionEncumbered.selector);
        vault.validatePosition(M1, address(gauge1), key);
        // Unstaked again, the same NFT is accepted from its owner.
        vm.startPrank(alice);
        gauge1.withdraw(id);
        _npm1().approve(address(vault), id);
        vm.stopPrank();
        assertFalse(vault.isStaked(M1, id));
        assertEq(_receive(M1, alice, key), 1e9);
        assertFalse(vault.isStaked(M1, id), "a custodied position is never staked");
    }

    // TEST-265 verifies: REQ-AMM-SLIP-009, REQ-AMM-SLIP-019
    // Sources: 2.21 REQ-AMM-SLIP-009 (a failing gauge read, or no gauge, neither blocks nor admits; the voter is never read)
    function test_TEST_265_theGaugeCheckNeverRevertsAndNeverReadsTheVoter() public {
        bytes32 a = _mint1(alice, 1e9);
        vm.expectCall(factories[G1].voter(), abi.encodeWithSignature("isGauge(address)", alice), 0);
        pool1.setGaugeReverts(true);
        assertFalse(vault.isStaked(M1, _id(a)));
        assertEq(vault.validatePosition(M1, alice, a), 1e9);
        assertEq(_receive(M1, alice, a), 1e9);
        pool1.setGaugeReverts(false);
        pool1.setGauge(address(0));
        bytes32 b = _mint1(bob, 2e9);
        assertFalse(vault.isStaked(M1, _id(b)));
        assertEq(_receive(M1, bob, b), 2e9);
        assertFalse(vault.isStaked(M1, 424_242), "unknown token");
        vm.expectRevert(abi.encodeWithSelector(MarketBinding.selector, uint256(9)));
        vault.isStaked(9, 1);
        // A market of the Aero generation, whose voter's isGauge reverts, takes custody as well.
        bytes32 c = _mint(carol, G2, pool100, -FULL_100, FULL_100, 3e9);
        assertEq(_receive(M2, carol, c), 3e9);
    }

    // TEST-011 verifies: REQ-VAULT-012, REQ-AMM-CORE-005, REQ-AMM-CORE-018, REQ-AMM-SLIP-004, REQ-AMM-SLIP-020
    function test_TEST_011_receiveRefusesZeroUnitsAndALockedPool() public {
        bytes32 empty = _mint1(alice, 0);
        bytes32 key = _mint1(bob, 1e9);
        _lock();
        vm.prank(coll);
        vm.expectRevert(ZeroUnits.selector);
        vault.receivePosition(M1, alice, empty);
        pool1.setUnlocked(false);
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
        assertEq(vault.positionOwner(_key(G1, 999)), address(0), "unknown token");
        _receive(M1, alice, key);
        _lock();
        vm.prank(coll);
        vm.expectRevert(NotTokenOwner.selector);
        vault.receivePosition(M1, alice, key);
        _unlock();
    }

    // ─── returnPosition ───

    // TEST-016 verifies: REQ-AMM-CORE-007, REQ-VAULT-148, REQ-VAULT-168, REQ-VAULT-094, REQ-VAULT-077, REQ-AMM-SLIP-001, INV-045
    function test_TEST_016_returnSendsTheWholeNftToTheDepositor() public {
        bytes32 key = _pledge1(alice, 1e9);
        _npm1().increaseLiquidity(_id(key), 5e8);
        _npm1().accrue(_id(key), 12_400_000, 0);
        _lock();
        vm.expectEmit(address(vault));
        emit PositionReturned(key, alice);
        vm.prank(coll);
        address d = vault.returnPosition(key);
        _unlock();
        assertEq(d, alice);
        assertEq(_npm1().ownerOf(_id(key)), alice);
        assertEq(vault.depositorOf(key), address(0));
        assertEq(vault.marketOfPosition(key), 0);
        (,,,,,,, uint128 l,,, uint128 owed0,) = _npm1().positions(_id(key));
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
        vault.returnPosition(_key(G1, 77));
        _unlock();
    }

    // ─── unwind and releaseToDepositor ───

    // TEST-058 verifies: REQ-VAULT-149, REQ-VAULT-169, REQ-VAULT-057, REQ-VAULT-058, REQ-VAULT-067, REQ-VAULT-095, REQ-AMM-SLIP-001, SPEC-BACK-008, ATTACK-015
    // Sources: 5.1 TEST-058; MATH-ST-32…35; 3.5 LIQ-089
    function test_TEST_058_unwindRemovesExactUnitsAndCollectsOnlyPrincipal() public {
        bytes32 key = _pledge1(alice, 1e12);
        _npm1().accrue(_id(key), 3_000_000, 4_000_000);
        uint256 b0 = _token0().balanceOf(lpVaultSwap);
        uint256 b1 = _token1().balanceOf(lpVaultSwap);
        uint256[] memory amounts =
            abi.decode(_asColl(abi.encodeCall(vault.unwind, (key, 4e11, _zeros(), lpVaultSwap))), (uint256[]));
        (,,,,,,, uint128 l,,, uint128 owed0, uint128 owed1) = _npm1().positions(_id(key));
        assertEq(l, 6e11, "exactly the units asked");
        assertEq(owed0, 3_000_000, "fees stay owed to the NFT");
        assertEq(owed1, 4_000_000);
        assertGt(amounts[0], 0);
        assertEq(_token0().balanceOf(lpVaultSwap) - b0, amounts[0]);
        assertEq(_token1().balanceOf(lpVaultSwap) - b1, amounts[1]);
        assertEq(_token0().balanceOf(address(vault)), 0, "the LPVault holds no pool token");
        _asColl(abi.encodeCall(vault.unwind, (key, 6e11, _zeros(), lpVaultSwap)));
        uint256[] memory fees = abi.decode(_asColl(abi.encodeCall(vault.collectFees, (key, alice))), (uint256[]));
        assertEq(fees[0], 3_000_000);
        assertEq(fees[1], 4_000_000);
    }

    // TEST-058 verifies: REQ-VAULT-149, REQ-VAULT-159, REQ-AMM-CORE-008, REQ-AMM-SLIP-020
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
        vault.unwind(_key(G1, 42), 1, _zeros(), lpVaultSwap);
        pool1.setUnlocked(false);
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
    function test_TEST_177_zeroAmountRemovalSkipsTheCollect() public {
        bytes32 key = _pledge1(alice, 1e12);
        uint256 collects = _npm1().collectCalls();
        uint256[] memory amounts =
            abi.decode(_asColl(abi.encodeCall(vault.unwind, (key, 1, _zeros(), lpVaultSwap))), (uint256[]));
        assertEq(amounts[0] + amounts[1], 0);
        assertEq(_npm1().collectCalls(), collects, "no collect with two zero caps");
        assertEq(_liquidity(key), 1e12 - 1, "the unit is still removed");
    }

    // TEST-237 verifies: REQ-VAULT-161, REQ-VAULT-170, REQ-VAULT-099, REQ-VAULT-163, SPEC-BACK-008, INV-088
    function test_TEST_237_releaseToDepositorPaysOnlyTheDepositor() public {
        bytes32 key = _pledge1(alice, 1e12);
        _npm1().accrue(_id(key), 1_000_000, 0);
        vm.expectRevert(bytes("PSC"));
        this.callAsColl(abi.encodeCall(vault.releaseToDepositor, (key, 1e11, _vec(1e12, 0))));
        uint256 before = _token0().balanceOf(alice);
        uint256[] memory amounts =
            abi.decode(_asColl(abi.encodeCall(vault.releaseToDepositor, (key, 1e11, _vec(1, 1)))), (uint256[]));
        assertEq(_token0().balanceOf(alice) - before, amounts[0]);
        (,,,,,,, uint128 l,,, uint128 owed0,) = _npm1().positions(_id(key));
        assertEq(l, 9e11);
        assertEq(owed0, 1_000_000, "fees stay owed");
        assertEq(vault.depositorOf(key), alice);
    }

    // TEST-237 verifies: REQ-VAULT-163, REQ-AMM-CORE-007
    function test_TEST_237_belowMinimumWhenTheManagerSkipsItsCheck() public {
        bytes32 key = _pledge1(alice, 1e12);
        _npm1().setOverride(true, 5, 7);
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

    // TEST-017 verifies: REQ-AMM-CORE-010, REQ-VAULT-064, REQ-VAULT-065, REQ-VAULT-172, REQ-VAULT-066, REQ-AMM-SLIP-011, INV-044, FEE-001, FEE-006, FEE-009
    // Sources: 5.1 TEST-017; 3.7 FEE-009 (Slipstream fees are the unstaked share, paid in full to the depositor)
    function test_TEST_017_collectFeesPaysEveryOwedAmountToTheDepositor() public {
        bytes32 key = _mint1(alice, 1e12);
        _npm1().accrue(_id(key), 50_000_000, 0);
        _receive(M1, alice, key);
        _npm1().accrue(_id(key), 16_500_000, 15_950_000);
        uint256 b0 = _token0().balanceOf(alice);
        pool1.setUnlocked(false);
        _lock();
        vm.expectEmit(address(vault));
        emit FeesCollected(key, alice, _vec(66_500_000, 15_950_000));
        vm.prank(coll);
        uint256[] memory fees = vault.collectFees(key, alice);
        _unlock();
        assertEq(fees[0], 66_500_000);
        assertEq(_token0().balanceOf(alice) - b0, 66_500_000);
        assertEq(vault.unitsOf(key), 1e12, "no unit changes");
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
        vault.collectFees(_key(G1, 55), alice);
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
        _npm1().accrue(_id(key), 7, 9);
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

    // TEST-222 verifies: REQ-VAULT-151, REQ-VAULT-160, REQ-AMM-CORE-009, REQ-VAULT-162, REQ-VAULT-171, REQ-AMM-SLIP-020
    function test_TEST_222_custodyViewsRefuseOutsidersWhileTheLockIsHeld() public {
        bytes32 key = _pledge1(alice, 1e9);
        _npm1().increaseLiquidity(_id(key), 1);
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
        pool1.setUnlocked(false);
        vm.expectRevert(PoolLocked.selector);
        vault.unitsOf(key);
        vm.stopPrank();
        _unlock();
        assertEq(vault.unitsOf(key), 1e9 + 1);
        _lock();
        vault.composition(M1, 1e9, _vec(1e8, 1e8));
        vault.marketOf(M1);
        vault.riskMetadata(M1, key);
        vault.isStaked(M1, _id(key));
        vault.capabilities();
        _unlock();
    }

    // TEST-222 verifies: REQ-VAULT-067, REQ-VAULT-150, REQ-VAULT-151, ATTACK-092
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
        assertEq(_npm1().ownerOf(_id(other)), bob);
        assertEq(vault.unitsOf(key), 7e11);
    }

    // TEST-074 verifies: REQ-VAULT-095, SPEC-BACK-008, Q-061
    function testFuzz_TEST_074_splitUnwindNeverReturnsMore(
        uint128 total,
        uint8 pieces,
        int24 tickSeed
    ) public {
        total = uint128(bound(total, 1e6, 1e20));
        pieces = uint8(bound(pieces, 2, 12));
        pool1.setPrice(int24(bound(int256(tickSeed), -60, 60)));
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
        _npm1().accrue(_id(key), 11, 13);
        _asColl(abi.encodeCall(vault.unwind, (key, take, _zeros(), lpVaultSwap)));
        (,,,,,,, uint128 l,,, uint128 owed0, uint128 owed1) = _npm1().positions(_id(key));
        assertEq(l, liquidity - take);
        assertEq(owed0, 11);
        assertEq(owed1, 13);
    }

    // TEST-265 verifies: REQ-AMM-SLIP-001, SPEC-AMM-CORE-002
    function testFuzz_TEST_265_keyEncodingRoundTrips(
        uint8 gen,
        uint256 tokenId
    ) public {
        tokenId = bound(tokenId, 0, (uint256(1) << 248) - 1);
        if (gen >= 4) {
            vm.expectRevert(UnsupportedNft.selector);
            vault.positionKeyOf(gen, tokenId);
            return;
        }
        bytes32 key = vault.positionKeyOf(gen, tokenId);
        assertEq(uint256(key) >> 248, gen);
        assertEq(vault.tokenIdOf(key), tokenId);
        MockSlipstreamNPM n = npms[gen];
        vm.expectRevert(UnsupportedNft.selector);
        vault.positionKeyOf(gen, tokenId | (uint256(1) << 248));
        assertEq(address(n), _npmList()[gen]);
    }
}
