// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {UniswapV3IntegrationFixture} from "../utils/fixtures/UniswapV3IntegrationFixture.sol";
import {MintableToken, NftHolder, OtherNft} from "../utils/mocks/UniswapV3Mocks.sol";
import {IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

/// @notice Uniswap v3 LPVault and value it never asked for: pushed and stray NFTs, liquidity a third party adds to a
/// custodied NFT, ERC-20 and ETH donations, and position-manager approvals. None of them changes a custody entry, a
/// unit read, a reported amount or a composition, and no code path reads a balance of the LPVault.
/// forge-config: default.isolate = false
contract UniswapV3IntegrationDonationsUnitTest is UniswapV3IntegrationFixture {
    // ─── Stray NFTs ───

    // TEST-015 verifies: REQ-VAULT-078, REQ-VAULT-093, REQ-VAULT-003, REQ-VAULT-152, ATTACK-006
    // Sources: 5.1 TEST-015 (pushed NFT recorded as stray only, never credited or pledgeable)
    function test_TEST_015_pushedNftIsOnlyAStray() public {
        bytes32 key = _mint1(alice, 1e9);
        vm.expectEmit(address(vault));
        emit StrayReceived(key, alice, alice);
        vm.prank(alice);
        nfpm.safeTransferFrom(alice, address(vault), uint256(key));
        assertEq(nfpm.ownerOf(uint256(key)), address(vault));
        assertEq(vault.depositorOf(key), address(0));
        assertEq(vault.marketOfPosition(key), 0);
        assertFalse(vault.isInCustody(key));
        vm.expectRevert(NotInCustody.selector);
        vault.unitsOf(key);
        _lock();
        vm.startPrank(coll);
        vm.expectRevert(NotTokenOwner.selector);
        vault.receivePosition(M1, alice, key);
        vm.expectRevert(NotTokenOwner.selector);
        vault.receivePosition(M1, address(vault), key);
        vm.expectRevert(NotInCustody.selector);
        vault.returnPosition(key);
        vm.expectRevert(NotInCustody.selector);
        vault.unwind(key, 1, _zeros(), lpVaultSwap);
        vm.expectRevert(NotInCustody.selector);
        vault.collectFees(key, alice);
        vm.stopPrank();
        _unlock();
    }

    // TEST-015 verifies: REQ-VAULT-124, REQ-VAULT-078
    function test_TEST_015_onlyTheNfpmMayPush() public {
        OtherNft other = new OtherNft();
        other.mint(alice, 1);
        vm.prank(alice);
        vm.expectRevert(UnsupportedNft.selector);
        other.safeTransferFrom(alice, address(vault), 1);
        vm.expectRevert(UnsupportedNft.selector);
        vault.onERC721Received(alice, alice, 1, "");
    }

    // TEST-015 verifies: REQ-VAULT-165, REQ-VAULT-079, REQ-VAULT-080, REQ-VAULT-083, REQ-VAULT-122, REQ-VAULT-123, INV-007, ATTACK-006
    // TEST-166 verifies: REQ-VAULT-082, REQ-VAULT-084, Q-228
    // Sources: 5.1 TEST-015, TEST-166 (timelock-only, the stray condition at execution, no timer of its own)
    function test_TEST_015_returnStrayOnlyThroughTheTimelockForAStray() public {
        bytes32 stray = _mint1(alice, 1e9);
        vm.prank(alice);
        nfpm.transferFrom(alice, address(vault), uint256(stray)); // pushed without a hook: still stray
        bytes32 pledged = _pledge1(bob, 1e9);
        vm.prank(alice);
        vm.expectRevert(NotTimelock.selector);
        vault.returnStray(stray, alice);
        vm.prank(governanceMultisig);
        vm.expectRevert(NotTimelock.selector);
        vault.returnStray(stray, alice);
        vm.startPrank(timelock);
        vm.expectRevert(InvalidRecipient.selector);
        vault.returnStray(stray, address(0));
        vm.expectRevert(InvalidRecipient.selector);
        vault.returnStray(stray, address(vault));
        vm.expectRevert(NotStray.selector);
        vault.returnStray(pledged, alice);
        vm.expectRevert(NotStray.selector);
        vault.returnStray(bytes32(uint256(9999)), alice); // unknown token
        vm.stopPrank();
        bytes32 elsewhere = _mint1(carol, 1);
        vm.prank(timelock);
        vm.expectRevert(NotStray.selector);
        vault.returnStray(elsewhere, alice); // not held by the LPVault
        _lock();
        vm.prank(timelock);
        vm.expectRevert(Locked.selector);
        vault.returnStray(stray, alice);
        _unlock();
        vm.expectEmit(address(vault));
        emit StrayReturned(stray, carol);
        vm.prank(timelock);
        vault.returnStray(stray, carol);
        assertEq(nfpm.ownerOf(uint256(stray)), carol);
    }

    // TEST-015 verifies: REQ-VAULT-083, REQ-VAULT-079, ATTACK-006
    // Sources: a return scheduled for a stray that is pledged before execution reverts NotStray; a closed record's NFT
    // sent back later is a stray again.
    function test_TEST_015_strayConditionIsEvaluatedAtExecution() public {
        bytes32 key = _pledge1(alice, 1e9);
        _asColl(abi.encodeCall(vault.returnPosition, (key)));
        vm.prank(alice);
        nfpm.transferFrom(alice, address(vault), uint256(key));
        vm.prank(timelock);
        vault.returnStray(key, alice);
        // Pledged again before a second scheduled return executes: refused.
        vm.prank(alice);
        nfpm.approve(address(vault), uint256(key));
        _receive(M1, alice, key);
        vm.prank(timelock);
        vm.expectRevert(NotStray.selector);
        vault.returnStray(key, bob);
    }

    // ─── Donated liquidity ───

    // TEST-016 verifies: REQ-VAULT-077, REQ-AMM-CORE-009, REQ-VAULT-095, REQ-VAULT-162, INV-002
    // Sources: 5.1 TEST-016 (a third party's increaseLiquidity raises live liquidity only and is never removed)
    function test_TEST_016_donatedLiquidityIsLiveButNeverTakenOrMoved() public {
        bytes32 key = _pledge1(alice, 1e12);
        vm.prank(attacker);
        nfpm.increaseLiquidity(uint256(key), 3e11);
        assertEq(vault.unitsOf(key), 1.3e12, "live units rise");
        assertEq(vault.depositorOf(key), alice, "the depositor of record does not change");
        assertEq(vault.marketOfPosition(key), M1);
        // Removal takes only the units Collateralization asks for; the rest stays with the NFT.
        _asColl(abi.encodeCall(vault.unwind, (key, 1e12, _zeros(), lpVaultSwap)));
        assertEq(vault.unitsOf(key), 3e11);
        // The donor gains no control: no custody call accepts it.
        _lock();
        vm.prank(coll);
        vm.expectRevert(NotDepositor.selector);
        vault.collectFees(key, attacker);
        _unlock();
        address d = abi.decode(_asColl(abi.encodeCall(vault.returnPosition, (key))), (address));
        assertEq(d, alice);
        (,,,,,,, uint128 l,,,,) = nfpm.positions(uint256(key));
        assertEq(l, 3e11, "the donated liquidity returns to the depositor with the NFT");
    }

    // ─── ERC-20 and ETH donations ───

    // TEST-080 verifies: REQ-VAULT-085, REQ-VAULT-154, REQ-VAULT-164, REQ-VAULT-175, INV-021, Q-124
    // Sources: 5.1 TEST-080; BRIEF 2026-11-10 (ERC-20 or ETH sent to the LPVault changes no record, cap, credit or mint)
    function testFuzz_TEST_080_tokenAndEthDonationsChangeNothing(
        uint256 dust,
        uint8 which
    ) public {
        dust = bound(dust, 1, 1e24);
        bytes32 key = _pledge1(alice, 1e12);
        bytes32 twin = _pledge1(bob, 1e12);
        nfpm.accrue(uint256(key), 5, 6);
        nfpm.accrue(uint256(twin), 5, 6);
        MintableToken lp = new MintableToken("LP", 18);
        MintableToken[3] memory tokens = [_token0(), _token1(), lp];
        MintableToken donated = tokens[which % 3];
        (uint256[] memory compBefore,) = vault.composition(M1, 1e12, _vec(1e8, 1e8));
        // Unwind the twin before the donation, the position after it: equal amounts.
        uint256[] memory a =
            abi.decode(_asColl(abi.encodeCall(vault.unwind, (twin, 4e11, _zeros(), lpVaultSwap))), (uint256[]));
        donated.mint(address(vault), dust);
        vm.deal(address(vault), dust);
        (bool sent,) = address(vault).call{value: 1}("");
        assertFalse(sent, "the LPVault accepts no ETH");
        uint256 r0 = _token0().balanceOf(lpVaultSwap);
        uint256[] memory b =
            abi.decode(_asColl(abi.encodeCall(vault.unwind, (key, 4e11, _zeros(), lpVaultSwap))), (uint256[]));
        assertEq(b[0], a[0], "reported amount independent of the donation");
        assertEq(b[1], a[1]);
        assertEq(_token0().balanceOf(lpVaultSwap) - r0, b[0], "the recipient receives exactly the principal");
        uint256[] memory f = abi.decode(_asColl(abi.encodeCall(vault.collectFees, (key, alice))), (uint256[]));
        assertEq(f[0], 5, "fees paid are the NFT's own, not the donation");
        assertEq(f[1], 6);
        (uint256[] memory compAfter,) = vault.composition(M1, 1e12, _vec(1e8, 1e8));
        assertEq(compAfter[0], compBefore[0]);
        assertEq(vault.unitsOf(key), 6e11);
        assertEq(vault.depositorOf(key), alice);
        assertEq(donated.balanceOf(address(vault)), dust, "the donation stays: no sweep, no rescue");
        assertEq(address(vault).balance, dust);
    }

    // TEST-080 verifies: REQ-VAULT-085, REQ-VAULT-154
    // Sources: no LPVault code path reads a balance of its own (balanceOf(address(this)))
    function test_TEST_080_noCodePathReadsTheLPVaultBalance() public {
        bytes32 key = _mint1(alice, 1e12);
        bytes memory probe = abi.encodeWithSelector(IERC20.balanceOf.selector, address(vault));
        vm.expectCall(address(usdc), probe, 0);
        vm.expectCall(address(usdt), probe, 0);
        _receive(M1, alice, key);
        nfpm.accrue(uint256(key), 1, 1);
        _asColl(abi.encodeCall(vault.unwind, (key, 1e11, _zeros(), lpVaultSwap)));
        _asColl(abi.encodeCall(vault.releaseToDepositor, (key, 1e11, _zeros())));
        _asColl(abi.encodeCall(vault.collectFees, (key, alice)));
        vault.composition(M1, 1e12, _vec(1e8, 1e8));
        vault.riskMetadata(M1, key);
        _asColl(abi.encodeCall(vault.returnPosition, (key)));
    }

    // ─── Approvals ───

    // TEST-021 verifies: REQ-AMM-V3-004, REQ-VAULT-097, REQ-VAULT-004, ATTACK-008, INV-021
    // Sources: 5.1 TEST-021 (no approve or setApprovalForAll; previous operators lose all rights; no ERC-1271)
    function test_TEST_021_noApprovalsAndNoOperatorRights() public {
        bytes32 key = _mint1(alice, 1e12);
        vm.prank(alice);
        nfpm.setApprovalForAll(bob, true);
        vm.expectCall(address(nfpm), abi.encodeWithSelector(IERC721.approve.selector), 0);
        vm.expectCall(address(nfpm), abi.encodeWithSelector(IERC721.setApprovalForAll.selector), 0);
        _receive(M1, alice, key);
        assertEq(nfpm.getApproved(uint256(key)), address(0));
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721InsufficientApproval.selector, bob, uint256(key)));
        nfpm.transferFrom(address(vault), bob, uint256(key));
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721InsufficientApproval.selector, alice, uint256(key)));
        nfpm.transferFrom(address(vault), alice, uint256(key));
        _asColl(abi.encodeCall(vault.unwind, (key, 1e11, _zeros(), lpVaultSwap)));
        _asColl(abi.encodeCall(vault.returnPosition, (key)));
        (bool ok,) = address(vault).call(abi.encodeWithSignature("isValidSignature(bytes32,bytes)", bytes32(0), ""));
        assertFalse(ok, "no ERC-1271");
    }

    // TEST-015 verifies: REQ-VAULT-094, REQ-VAULT-093
    function test_TEST_015_safeTransferHolderAndPush() public {
        NftHolder holder = new NftHolder();
        bytes32 key = _mint1(address(holder), 1e9);
        vm.prank(address(holder));
        nfpm.safeTransferFrom(address(holder), address(vault), uint256(key), "data");
        assertEq(vault.depositorOf(key), address(0));
    }
}
