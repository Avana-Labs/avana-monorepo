// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ClTestToken} from "../utils/fixtures/ClPoolFixture.sol";
import {UniswapV4IntegrationFixture} from "../utils/fixtures/UniswapV4IntegrationFixture.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

/// @title UniswapV4IntegrationDonationsUnitTest
/// @notice The Uniswap v4 LPVault and value it never asked for: pushed and stray PositionManager NFTs, a PoolManager
/// `donate` to the pool, and ERC-20 and ETH sent to the LPVault. A pushed NFT is only a stray, returned only through
/// the timelock; a pool donation is fee growth, paid to the depositor as fees and never units; a token or ETH balance
/// of the LPVault changes no unit read, reported amount or composition, and no code path reads one. The same suite as
/// the Uniswap v3 and Slipstream LPVaults' (a third party's added liquidity is impossible on v4: `TEST-342`).
/// forge-config: default.isolate = false
contract UniswapV4IntegrationDonationsUnitTest is UniswapV4IntegrationFixture {
    function _mint1(
        address owner
    ) internal returns (bytes32) {
        return _mintFor(owner, stableKey, M1_LOWER, M1_UPPER, 1e15);
    }

    // ─── Stray NFTs ───

    // TEST-015 verifies: REQ-VAULT-078, REQ-VAULT-093, REQ-VAULT-003, REQ-VAULT-152, ATTACK-006
    /// @notice An NFT pushed with `safeTransferFrom` is recorded as a stray only: no depositor, no market, no units,
    /// and no custody call accepts it.
    function test_TEST_015_pushedNftIsOnlyAStray() public {
        bytes32 key = _mint1(alice);
        vm.expectEmit(address(vault));
        emit StrayReceived(key, alice, alice);
        vm.prank(alice);
        IERC721(address(posm)).safeTransferFrom(alice, address(vault), uint256(key));
        assertEq(posm.ownerOf(uint256(key)), address(vault));
        assertEq(vault.depositorOf(key), address(0));
        assertEq(vault.marketOfPosition(key), 0);
        assertFalse(vault.isInCustody(key));
        vm.expectRevert(NotInCustody.selector);
        vault.unitsOf(key);
        _lock();
        vm.startPrank(coll);
        vm.expectRevert(NotTokenOwner.selector);
        vault.receivePosition(M1, alice, key);
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
    /// @notice Only the PositionManager may call the receiver hook.
    function test_TEST_015_onlyThePositionManagerMayPush() public {
        vm.prank(alice);
        vm.expectRevert(UnsupportedNft.selector);
        vault.onERC721Received(alice, alice, 1, "");
    }

    // TEST-015 verifies: REQ-VAULT-165, REQ-VAULT-079, REQ-VAULT-080, REQ-VAULT-083, REQ-VAULT-122, REQ-VAULT-123, ATTACK-006
    // TEST-166 verifies: REQ-VAULT-082, REQ-VAULT-084, REQ-ACCESS-060, REQ-VAULT-081; shared: TEST-166 returns a stray only through the timelock, which this test checks on the Uniswap v4 LPVault
    /// @notice `returnStray` runs only from the timelock, only for an NFT the LPVault holds without a custody entry,
    /// never to the zero address or itself and never under the Lock.
    function test_TEST_015_returnStrayOnlyThroughTheTimelockForAStray() public {
        bytes32 stray = _mint1(alice);
        bytes32 pledged = _mint1(bob);
        _receive(M1, bob, pledged);
        vm.prank(alice);
        posm.transferFrom(alice, address(vault), uint256(stray)); // pushed without a hook: still stray
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
        vm.stopPrank();
        bytes32 elsewhere = _mint1(carol);
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
        assertEq(posm.ownerOf(uint256(stray)), carol);
        assertEq(vault.unitsOf(pledged), uint128(1e15 / 10 ** vault.unitExponent(M1)), "the pledged position untouched");
    }

    // TEST-015 verifies: REQ-VAULT-083, REQ-VAULT-079, ATTACK-006
    /// @notice A returned position's NFT sent back later is a stray again; pledged again before a scheduled return
    /// executes, the return is refused.
    function test_TEST_015_strayConditionIsEvaluatedAtExecution() public {
        bytes32 key = _mint1(alice);
        _receive(M1, alice, key);
        _asColl(abi.encodeCall(vault.returnPosition, (key)));
        vm.prank(alice);
        posm.transferFrom(alice, address(vault), uint256(key));
        vm.prank(timelock);
        vault.returnStray(key, alice);
        vm.prank(alice);
        posm.approve(address(vault), uint256(key));
        _receive(M1, alice, key);
        vm.prank(timelock);
        vm.expectRevert(NotStray.selector);
        vault.returnStray(key, bob);
    }

    // ─── Pool donations ───

    // TEST-342 verifies: REQ-AMM-V4-004, REQ-AMM-V4-010, REQ-VAULT-077, REQ-VAULT-162
    /// @notice A PoolManager `donate` to the market's pool is fee growth: the depositor's units do not move, and the
    /// next fee collection pays the donation to the depositor (the only liquidity in range), to the rounding of the
    /// fee-growth division.
    function test_TEST_342_poolDonationIsFeesNotUnits() public {
        bytes32 key = _mint1(alice);
        uint128 units = _receive(M1, alice, key);
        v4Actor.donate(stableKey, 1e9, 2e9);
        assertEq(vault.unitsOf(key), units, "units unchanged");
        (uint256 a0, uint256 a1) = _balances(M1, alice);
        uint256[] memory fees = _collect(key, alice);
        (uint256 b0, uint256 b1) = _balances(M1, alice);
        assertEq(b0 - a0, fees[0], "fee0 delivered as returned");
        assertEq(b1 - a1, fees[1], "fee1 delivered as returned");
        assertApproxEqAbs(fees[0], 1e9, 1, "the donated token0");
        assertApproxEqAbs(fees[1], 2e9, 1, "the donated token1");
        assertEq(vault.unitsOf(key), units, "still unchanged");
    }

    // ─── ERC-20 and ETH donations ───

    // TEST-080 verifies: REQ-VAULT-085, REQ-VAULT-154, REQ-VAULT-164, REQ-VAULT-175, INV-021, Q-124
    /// @notice Tokens and ETH sent to the LPVault change no reported amount, fee, unit read or composition, and stay
    /// where they are: the same unwind and collection run with and without the donation return the same amounts.
    function testFuzz_TEST_080_tokenAndEthDonationsChangeNothing(
        uint256 dust,
        uint8 which
    ) public {
        dust = bound(dust, 1, 1e24);
        bytes32 key = _mint1(alice);
        _receive(M1, alice, key);
        _washV4(stableKey, 1e12);
        ClTestToken other = new ClTestToken("LP", 18);
        ClTestToken[3] memory tokens = [usdc, usdt, other];
        ClTestToken donated = tokens[which % 3];
        (uint256[] memory compBefore,) = vault.composition(M1, 1e9, _vec(ONE, ONE));
        uint256 snap = vm.snapshotState();
        uint256[] memory a = _unwind(key, 4e11, _zeros(), lpVaultSwap);
        uint256[] memory fa = _collect(key, alice);
        vm.revertToState(snap);
        donated.mint(address(vault), dust);
        vm.deal(address(vault), dust);
        (bool sent,) = address(vault).call{value: 1}("");
        assertFalse(sent, "the LPVault accepts no ETH");
        uint256[] memory b = _unwind(key, 4e11, _zeros(), lpVaultSwap);
        uint256[] memory fb = _collect(key, alice);
        assertEq(b[0], a[0], "principal token0 independent of the donation");
        assertEq(b[1], a[1], "principal token1");
        assertEq(fb[0], fa[0], "fees are the position's own, not the donation");
        assertEq(fb[1], fa[1]);
        (uint256[] memory compAfter,) = vault.composition(M1, 1e9, _vec(ONE, ONE));
        assertEq(compAfter[0], compBefore[0]);
        assertEq(compAfter[1], compBefore[1]);
        assertEq(donated.balanceOf(address(vault)), dust, "the donation stays: no sweep, no rescue");
        assertEq(address(vault).balance, dust);
    }

    // TEST-080 verifies: REQ-VAULT-085, REQ-VAULT-154
    /// @notice No LPVault code path reads a balance of its own: pledge, unwind, release, fee collection, composition,
    /// risk metadata and return run without a `balanceOf(LPVault)` call on either token or WETH.
    function test_TEST_080_noCodePathReadsTheLPVaultBalance() public {
        bytes32 key = _mint1(alice);
        bytes memory probe = abi.encodeWithSelector(IERC20.balanceOf.selector, address(vault));
        vm.expectCall(address(usdc), probe, 0);
        vm.expectCall(address(usdt), probe, 0);
        vm.expectCall(address(weth), probe, 0);
        _receive(M1, alice, key);
        _washV4(stableKey, 1e12);
        _unwind(key, 1e11, _zeros(), lpVaultSwap);
        _asColl(abi.encodeCall(vault.releaseToDepositor, (key, 1e11, _zeros())));
        _collect(key, alice);
        vault.composition(M1, 1e12, _vec(ONE, ONE));
        vault.riskMetadata(M1, key);
        _asColl(abi.encodeCall(vault.returnPosition, (key)));
    }
}
