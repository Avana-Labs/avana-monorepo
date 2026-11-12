// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {LPVaultLedgerFixture} from "../utils/fixtures/LPVaultLedgerFixture.sol";
import {SlipstreamIntegrationFixture} from "../utils/fixtures/SlipstreamIntegrationFixture.sol";
import {MintableToken, NftHolder, OtherNft} from "../utils/mocks/UniswapV3Mocks.sol";
import {IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

/// @notice Slipstream LPVault and value it never asked for: pushed and stray NFTs of every generation, liquidity a
/// third party adds to a custodied NFT, ERC-20 and ETH donations, and position-manager approvals. None of them changes
/// a custody entry, a unit read, a reported amount or a composition, and no code path reads a balance of the LPVault.
/// Market 1 is backed by the real Collateralization and vault token (`LPVaultLedgerFixture`), so every donation test
/// also shows that the backing record's credited units, the cap counters, the credited totals and the vault token's
/// supply and balances do not move.
/// forge-config: default.isolate = false
contract SlipstreamIntegrationDonationsUnitTest is SlipstreamIntegrationFixture, LPVaultLedgerFixture {
    function setUp() public override {
        super.setUp();
        _deployLedger(
            LedgerCore(adapter, lpVaultSwap, coll, address(lock), timelock, registry),
            INTEGRATION,
            address(vault),
            M1,
            9
        );
    }

    /// @notice A market-1 position of `owner` pledged through the real Collateralization for `proxy`.
    function _ledgerPledge(
        address owner,
        address proxy,
        uint128 liquidity
    ) internal returns (bytes32 key) {
        key = _mint1(owner, liquidity);
        _pledgeThroughLedger(owner, proxy, key);
    }

    // ─── Stray NFTs ───

    // TEST-015 verifies: REQ-VAULT-078, REQ-VAULT-093, REQ-VAULT-003, REQ-VAULT-152, REQ-AMM-SLIP-001, ATTACK-006, INV-006
    // Sources: 5.1 TEST-015; BRIEF 2026-11-10 (an NFT pushed with safeTransferFrom is recorded only as a stray)
    function test_TEST_015_pushedNftIsOnlyAStrayOnEveryGeneration() public {
        bytes32 backed = _ledgerPledge(bob, bobProxy, 1e12);
        LedgerState memory before = _ledgerState(backed, bob, bobProxy, alice);
        bytes32 k; // generation 2's pushed NFT
        for (uint8 g = 0; g < 4; ++g) {
            uint256 id = npms[g].mint(alice, pool1.token0(), pool1.token1(), 1, -50, 50, 1e9);
            bytes32 key = _key(g, id);
            if (g == G1) k = key;
            vm.expectEmit(address(vault));
            emit StrayReceived(key, alice, alice);
            vm.prank(alice);
            npms[g].safeTransferFrom(alice, address(vault), id);
            assertEq(npms[g].ownerOf(id), address(vault));
            assertEq(vault.depositorOf(key), address(0));
            assertEq(vault.marketOfPosition(key), 0);
            assertFalse(vault.isInCustody(key));
            vm.expectRevert(NotInCustody.selector);
            vault.unitsOf(key);
            assertEq(ledger.recordIdOf(INTEGRATION, key), 0, "a pushed NFT has no backing record");
        }
        _assertLedgerUnchanged(before, _ledgerState(backed, bob, bobProxy, alice));
        _lock();
        vm.startPrank(coll);
        vm.expectRevert(NotTokenOwner.selector);
        vault.receivePosition(M1, alice, k);
        vm.expectRevert(NotTokenOwner.selector);
        vault.receivePosition(M1, address(vault), k);
        vm.expectRevert(NotInCustody.selector);
        vault.returnPosition(k);
        vm.expectRevert(NotInCustody.selector);
        vault.unwind(k, 1, _zeros(), lpVaultSwap);
        vm.expectRevert(NotInCustody.selector);
        vault.collectFees(k, alice);
        vm.stopPrank();
        _unlock();
        _assertLedgerUnchanged(before, _ledgerState(backed, bob, bobProxy, alice));
    }

    // TEST-015 verifies: REQ-VAULT-124, REQ-VAULT-078
    function test_TEST_015_onlyAnAllowlistedManagerMayPush() public {
        bytes32 backed = _ledgerPledge(bob, bobProxy, 1e12);
        LedgerState memory before = _ledgerState(backed, bob, bobProxy, alice);
        OtherNft other = new OtherNft();
        other.mint(alice, 1);
        vm.prank(alice);
        vm.expectRevert(UnsupportedNft.selector);
        other.safeTransferFrom(alice, address(vault), 1);
        vm.expectRevert(UnsupportedNft.selector);
        vault.onERC721Received(alice, alice, 1, "");
        // A token ID that does not fit below the generation byte is not accepted either.
        vm.prank(address(npms[0]));
        vm.expectRevert(UnsupportedNft.selector);
        vault.onERC721Received(alice, alice, uint256(1) << 248, "");
        _assertLedgerUnchanged(before, _ledgerState(backed, bob, bobProxy, alice));
    }

    // TEST-015 verifies: REQ-VAULT-165, REQ-VAULT-079, REQ-VAULT-080, REQ-VAULT-083, REQ-VAULT-122, REQ-VAULT-123, INV-007, ATTACK-006
    // TEST-166 verifies: REQ-VAULT-082, REQ-VAULT-084, Q-228
    function test_TEST_015_returnStrayOnlyThroughTheTimelockForAStray() public {
        bytes32 stray = _mint1(alice, 1e9);
        bytes32 pledged = _ledgerPledge(bob, bobProxy, 1e9);
        LedgerState memory before = _ledgerState(pledged, bob, bobProxy, alice);
        vm.prank(alice);
        _npm1().transferFrom(alice, address(vault), _id(stray));
        assertEq(ledger.recordIdOf(INTEGRATION, stray), 0, "a stray has no backing record");
        _assertLedgerUnchanged(before, _ledgerState(pledged, bob, bobProxy, alice));
        vm.prank(alice);
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
        vault.returnStray(_key(G1, 9999), alice);
        vm.expectRevert(NotStray.selector);
        vault.returnStray(_key(0, _id(stray)), alice); // same token ID on another generation, not held
        vm.stopPrank();
        _lock();
        vm.prank(timelock);
        vm.expectRevert(Locked.selector);
        vault.returnStray(stray, alice);
        _unlock();
        vm.expectEmit(address(vault));
        emit StrayReturned(stray, carol);
        vm.prank(timelock);
        vault.returnStray(stray, carol);
        assertEq(_npm1().ownerOf(_id(stray)), carol);
        _assertLedgerUnchanged(before, _ledgerState(pledged, bob, bobProxy, alice));
    }

    // ─── Donated liquidity ───

    // TEST-016 verifies: REQ-VAULT-077, REQ-AMM-CORE-009, REQ-VAULT-095, REQ-VAULT-162, INV-002, INV-006
    // Sources: 5.1 TEST-016; BRIEF 2026-11-10 (liquidity a third party adds to a custodied position is not credited)
    function test_TEST_016_donatedLiquidityIsLiveButNeverTakenOrMoved() public {
        bytes32 key = _ledgerPledge(alice, aliceProxy, 1e12);
        LedgerState memory before = _ledgerState(key, alice, aliceProxy, attacker);
        assertEq(before.credited, 1e12);
        vm.prank(attacker);
        _npm1().increaseLiquidity(_id(key), 3e11);
        assertEq(vault.unitsOf(key), 1.3e12, "live units rise");
        assertEq(vault.depositorOf(key), alice);
        _assertLedgerUnchanged(before, _ledgerState(key, alice, aliceProxy, attacker));
        _asColl(abi.encodeCall(vault.unwind, (key, 1e12, _zeros(), lpVaultSwap)));
        assertEq(vault.unitsOf(key), 3e11);
        _lock();
        vm.prank(coll);
        vm.expectRevert(NotDepositor.selector);
        vault.collectFees(key, attacker);
        _unlock();
        address d = abi.decode(_asColl(abi.encodeCall(vault.returnPosition, (key))), (address));
        assertEq(d, alice);
        assertEq(_liquidity(key), 3e11, "the donated liquidity returns to the depositor with the NFT");
    }

    // ─── ERC-20 and ETH donations ───

    /// @notice Sends `dust` of `donated` and `dust` wei to the LPVault (ETH by balance; a plain transfer is refused)
    /// and checks that the ledger of `key` (alice's, pledged through Collateralization) did not move.
    function _donateTokenAndEth(
        bytes32 key,
        MintableToken donated,
        uint256 dust
    ) internal {
        LedgerState memory before = _ledgerState(key, alice, aliceProxy, attacker);
        donated.mint(address(vault), dust);
        vm.deal(address(vault), dust);
        (bool sent,) = address(vault).call{value: 1}("");
        assertFalse(sent, "the LPVault accepts no ETH");
        _assertLedgerUnchanged(before, _ledgerState(key, alice, aliceProxy, attacker));
    }

    // TEST-080 verifies: REQ-VAULT-085, REQ-VAULT-154, REQ-VAULT-164, REQ-VAULT-175, INV-021, Q-124, INV-006
    // Sources: 5.1 TEST-080; BRIEF 2026-11-10 (USDC, a market token, an LP token or ETH changes nothing)
    function testFuzz_TEST_080_tokenAndEthDonationsChangeNothing(
        uint256 dust,
        uint8 which
    ) public {
        dust = bound(dust, 1, 1e24);
        bytes32 key = _ledgerPledge(alice, aliceProxy, 1e12);
        bytes32 twin = _pledge1(bob, 1e12);
        _npm1().accrue(_id(key), 5, 6);
        _npm1().accrue(_id(twin), 5, 6);
        MintableToken lp = new MintableToken("LP", 18);
        MintableToken[4] memory tokens = [_token0(), _token1(), lp, aero];
        MintableToken donated = tokens[which % 4];
        (uint256[] memory compBefore,) = vault.composition(M1, 1e12, _vec(1e8, 1e8));
        uint256[] memory a =
            abi.decode(_asColl(abi.encodeCall(vault.unwind, (twin, 4e11, _zeros(), lpVaultSwap))), (uint256[]));
        _donateTokenAndEth(key, donated, dust);
        uint256 r0 = _token0().balanceOf(lpVaultSwap);
        uint256[] memory b =
            abi.decode(_asColl(abi.encodeCall(vault.unwind, (key, 4e11, _zeros(), lpVaultSwap))), (uint256[]));
        assertEq(b[0], a[0], "reported amount independent of the donation");
        assertEq(b[1], a[1]);
        assertEq(_token0().balanceOf(lpVaultSwap) - r0, b[0]);
        uint256[] memory f = abi.decode(_asColl(abi.encodeCall(vault.collectFees, (key, alice))), (uint256[]));
        assertEq(f[0], 5);
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
        vm.expectCall(address(aero), probe, 0);
        _receive(M1, alice, key);
        _npm1().accrue(_id(key), 1, 1);
        _asColl(abi.encodeCall(vault.unwind, (key, 1e11, _zeros(), lpVaultSwap)));
        _asColl(abi.encodeCall(vault.releaseToDepositor, (key, 1e11, _zeros())));
        _asColl(abi.encodeCall(vault.collectFees, (key, alice)));
        vault.composition(M1, 1e12, _vec(1e8, 1e8));
        vault.riskMetadata(M1, key);
        vault.isStaked(M1, _id(key));
        _asColl(abi.encodeCall(vault.returnPosition, (key)));
    }

    // ─── Approvals ───

    // TEST-021 verifies: REQ-AMM-SLIP-010, REQ-VAULT-097, REQ-VAULT-004, ATTACK-008, INV-021
    // Sources: 5.1 TEST-021 (no approve or setApprovalForAll; previous operators lose all rights; no ERC-1271)
    function test_TEST_021_noApprovalsAndNoOperatorRights() public {
        bytes32 key = _mint1(alice, 1e12);
        uint256 id = _id(key);
        vm.prank(alice);
        _npm1().setApprovalForAll(bob, true);
        vm.expectCall(address(_npm1()), abi.encodeWithSelector(IERC721.approve.selector), 0);
        vm.expectCall(address(_npm1()), abi.encodeWithSelector(IERC721.setApprovalForAll.selector), 0);
        _receive(M1, alice, key);
        assertEq(_npm1().getApproved(id), address(0));
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721InsufficientApproval.selector, bob, id));
        _npm1().transferFrom(address(vault), bob, id);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721InsufficientApproval.selector, alice, id));
        _npm1().transferFrom(address(vault), alice, id);
        _asColl(abi.encodeCall(vault.unwind, (key, 1e11, _zeros(), lpVaultSwap)));
        _asColl(abi.encodeCall(vault.returnPosition, (key)));
        (bool ok,) = address(vault).call(abi.encodeWithSignature("isValidSignature(bytes32,bytes)", bytes32(0), ""));
        assertFalse(ok, "no ERC-1271");
    }

    // TEST-015 verifies: REQ-VAULT-094, REQ-VAULT-093
    function test_TEST_015_safeTransferHolderAndPush() public {
        bytes32 backed = _ledgerPledge(bob, bobProxy, 1e12);
        NftHolder holder = new NftHolder();
        bytes32 key = _mint1(address(holder), 1e9);
        LedgerState memory before = _ledgerState(backed, bob, bobProxy, address(holder));
        vm.prank(address(holder));
        _npm1().safeTransferFrom(address(holder), address(vault), _id(key), "data");
        assertEq(vault.depositorOf(key), address(0));
        assertEq(ledger.recordIdOf(INTEGRATION, key), 0, "a pushed NFT has no backing record");
        _assertLedgerUnchanged(before, _ledgerState(backed, bob, bobProxy, address(holder)));
    }
}
