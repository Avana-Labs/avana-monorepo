// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IVaultToken} from "../../src/vault-token/vault-token/IVaultToken.sol";
import {VaultTokenFixture} from "../utils/fixtures/VaultTokenFixture.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title VaultTokenTransfersUnitTest
/// @notice The transfer rule of 2.4 on the token alone: exactly supply (proxy to Hub), withdrawal (Hub to proxy) and
/// seizure (Hub to LPVaultSwap) succeed; every other `transfer` and `transferFrom` reverts `UnauthorizedTransfer`,
/// zero amounts and spender transfers included, before any allowance is read or spent.
/// @dev Token-side parts of TEST-022 (movements) and TEST-189 (negative cases). The Hub, Spoke and LPVaultSwap are
/// pranked addresses; `VaultToken.AaveV4.integration.t.sol` runs supply and withdrawal through the real Aave V4 Spoke
/// and Hub. The PositionProxy and LPVaultSwap selector inventories of TEST-189 join the row with those contracts.
contract VaultTokenTransfersUnitTest is VaultTokenFixture {
    function setUp() public {
        _deployToken();
    }

    // ─── Allowed paths (TEST-022) ───

    // TEST-022 verifies: REQ-VTOKEN-006, REQ-VTOKEN-009, REQ-VTOKEN-010, REQ-VTOKEN-011, INV-011, Q-119, Q-224
    // Sources: 5.1 TEST-022, 2.4 REQ-VTOKEN-010
    /// @notice Supply: the Spoke moves the proxy's units to the Hub on the proxy's exact allowance, which ends at 0;
    /// `Approval(proxy, spoke, amount)` precedes `Transfer(proxy, hub, amount)`.
    function test_TEST_022_supplyProxyToHubBySpoke() public {
        _register(proxyA);
        _mint(proxyA, 5_000_000_000);
        vm.expectEmit(address(token));
        emit IERC20.Approval(proxyA, spoke, 5_000_000_000);
        vm.prank(proxyA);
        token.approve(spoke, 5_000_000_000);
        vm.expectEmit(address(token));
        emit IERC20.Transfer(proxyA, hub, 5_000_000_000);
        vm.prank(spoke);
        assertTrue(token.transferFrom(proxyA, hub, 5_000_000_000), "transferFrom");
        assertEq(token.balanceOf(hub), 5_000_000_000, "hub");
        assertEq(token.balanceOf(proxyA), 0, "proxy");
        assertEq(token.allowance(proxyA, spoke), 0, "allowance left");
    }

    // TEST-022 verifies: REQ-VTOKEN-006, REQ-VTOKEN-017, INV-011, Q-224
    /// @notice Withdrawal: the Hub pays a registered proxy, then the Adapter burns the units from it.
    function test_TEST_022_withdrawHubToProxyThenBurn() public {
        _pledge(proxyA, 5_000_000_000);
        vm.prank(hub);
        assertTrue(token.transfer(proxyA, 2_500_000_000), "transfer");
        vm.prank(adapter);
        token.burn(proxyA, 2_500_000_000);
        assertEq(token.balanceOf(proxyA), 0, "proxy holds units after the call");
        assertEq(token.balanceOf(hub), 2_500_000_000, "hub");
        assertEq(token.totalSupply(), 2_500_000_000, "supply");
    }

    // TEST-022 verifies: REQ-VTOKEN-006, REQ-VTOKEN-026, INV-011, Q-116, Q-300
    /// @notice Seizure: the Hub pays LPVaultSwap, the only liquidator the token admits.
    function test_TEST_022_seizureHubToLpVaultSwap() public {
        _pledge(proxyA, 5_000_000_000);
        vm.prank(hub);
        token.transfer(lpVaultSwap, 1_020_000_000);
        assertEq(token.balanceOf(lpVaultSwap), 1_020_000_000, "lpVaultSwap");
    }

    // TEST-022 verifies: REQ-VTOKEN-006, REQ-VTOKEN-031, INV-011
    /// @notice A registered proxy can also push its own units to the Hub with `transfer` (the units sit there
    /// unrecorded, which the Lens reports as stranded).
    function test_TEST_022_proxyDirectTransferToHubIsAllowed() public {
        _register(proxyA);
        _mint(proxyA, 7);
        vm.prank(proxyA);
        token.transfer(hub, 7);
        assertEq(token.balanceOf(hub), 7, "hub");
    }

    // ─── Refused paths (TEST-189) ───

    // TEST-189 verifies: REQ-VTOKEN-006, REQ-VTOKEN-008, REQ-VTOKEN-026, REQ-VTOKEN-030, INV-011, ATTACK-002, ATTACK-018, ATTACK-181, Q-116, Q-224, Q-300
    // Sources: 5.1 TEST-189, 2.4 REQ-VTOKEN-006
    /// @notice The Hub pays nobody but registered proxies and LPVaultSwap: not a third-party liquidator, the Adapter,
    /// the Spoke, the LPVault, Collateralization, the LPOracle, the Hub itself or an unregistered contract.
    function test_TEST_189_hubPaysOnlyProxiesAndLpVaultSwap() public {
        _pledge(proxyA, 1000);
        address[9] memory refused =
            [wallet, adapter, spoke, lpVault, collateralization, lpOracle, hub, proxyB, address(token)];
        for (uint256 i = 0; i < refused.length; ++i) {
            vm.prank(hub);
            vm.expectRevert(abi.encodeWithSelector(IVaultToken.UnauthorizedTransfer.selector, hub, refused[i]));
            token.transfer(refused[i], 1);
        }
        assertEq(token.balanceOf(hub), 1000, "hub balance moved");
    }

    // TEST-189 verifies: REQ-VTOKEN-041, INV-011, ATTACK-019, Q-224, Q-304
    /// @notice No proxy-to-proxy, proxy-to-LPVaultSwap or proxy-to-anyone transfer: a proxy sends only to the Hub.
    function test_TEST_189_proxySendsOnlyToHub() public {
        _register(proxyA);
        _register(proxyB);
        _mint(proxyA, 100);
        address[6] memory refused = [proxyB, lpVaultSwap, adapter, spoke, wallet, proxyA];
        for (uint256 i = 0; i < refused.length; ++i) {
            vm.prank(proxyA);
            vm.expectRevert(abi.encodeWithSelector(IVaultToken.UnauthorizedTransfer.selector, proxyA, refused[i]));
            token.transfer(refused[i], 1);
        }
        assertEq(token.balanceOf(proxyA), 100, "proxy balance moved");
    }

    // TEST-189 verifies: REQ-VTOKEN-041, INV-011, ATTACK-023, Q-224, Q-300
    /// @notice Seized units never re-enter the Hub from LPVaultSwap and never leave it except by burn.
    function test_TEST_189_lpVaultSwapCannotSendSeizedUnits() public {
        _pledge(proxyA, 1000);
        vm.prank(hub);
        token.transfer(lpVaultSwap, 400);
        address[5] memory refused = [hub, proxyA, adapter, wallet, lpVaultSwap];
        for (uint256 i = 0; i < refused.length; ++i) {
            vm.prank(lpVaultSwap);
            vm.expectRevert(abi.encodeWithSelector(IVaultToken.UnauthorizedTransfer.selector, lpVaultSwap, refused[i]));
            token.transfer(refused[i], 1);
        }
        assertEq(token.balanceOf(lpVaultSwap), 400, "seized units moved");
    }

    // TEST-189 verifies: REQ-VTOKEN-008, REQ-VTOKEN-030, INV-011, ATTACK-181, Q-224
    /// @notice Zero-amount transfers off the paths revert too, from holders and non-holders alike, including a
    /// transfer to the zero address (the path check runs before OpenZeppelin's receiver check).
    function test_TEST_189_zeroAmountAndZeroAddressOffPathRevert() public {
        vm.prank(hub);
        vm.expectRevert(abi.encodeWithSelector(IVaultToken.UnauthorizedTransfer.selector, hub, wallet));
        token.transfer(wallet, 0);
        vm.prank(wallet);
        vm.expectRevert(abi.encodeWithSelector(IVaultToken.UnauthorizedTransfer.selector, wallet, hub));
        token.transfer(hub, 0);
        vm.prank(hub);
        vm.expectRevert(abi.encodeWithSelector(IVaultToken.UnauthorizedTransfer.selector, hub, address(0)));
        token.transfer(address(0), 0);
        vm.prank(spoke);
        vm.expectRevert(abi.encodeWithSelector(IVaultToken.UnauthorizedTransfer.selector, address(0), hub));
        token.transferFrom(address(0), hub, 0);
    }

    // TEST-189 verifies: REQ-VTOKEN-008, REQ-VTOKEN-030, REQ-VTOKEN-048, INV-011
    /// @notice Zero-amount transfers revert on the allowed paths too: supply, withdrawal and seizure with 0 units, and
    /// a zero `transferFrom(proxy, hub, 0)` by anyone, which would otherwise need no allowance and emit a zero
    /// `Transfer` from a registered proxy.
    function test_TEST_189_zeroAmountOnAllowedPathsReverts() public {
        _pledge(proxyA, 1000);
        vm.prank(proxyA);
        vm.expectRevert(abi.encodeWithSelector(IVaultToken.UnauthorizedTransfer.selector, proxyA, hub));
        token.transfer(hub, 0);
        vm.prank(wallet);
        vm.expectRevert(abi.encodeWithSelector(IVaultToken.UnauthorizedTransfer.selector, proxyA, hub));
        token.transferFrom(proxyA, hub, 0);
        vm.prank(spoke);
        vm.expectRevert(abi.encodeWithSelector(IVaultToken.UnauthorizedTransfer.selector, proxyA, hub));
        token.transferFrom(proxyA, hub, 0);
        vm.prank(hub);
        vm.expectRevert(abi.encodeWithSelector(IVaultToken.UnauthorizedTransfer.selector, hub, proxyA));
        token.transfer(proxyA, 0);
        vm.prank(hub);
        vm.expectRevert(abi.encodeWithSelector(IVaultToken.UnauthorizedTransfer.selector, hub, lpVaultSwap));
        token.transfer(lpVaultSwap, 0);
        assertEq(token.balanceOf(hub), 1000, "hub");
    }

    // TEST-189 verifies: REQ-VTOKEN-008, REQ-VTOKEN-011, REQ-VTOKEN-030, INV-011, ATTACK-018, Q-224
    /// @notice An allowance never moves a unit off the paths: an off-path `transferFrom` reverts `UnauthorizedTransfer`
    /// whatever the allowance (unlimited included) and spends none of it.
    function test_TEST_189_allowanceNeverBypassesThePath() public {
        _pledge(proxyA, 1000);
        vm.prank(proxyA);
        token.approve(wallet, type(uint256).max);
        vm.prank(hub);
        token.transfer(proxyA, 10);
        vm.prank(wallet);
        vm.expectRevert(abi.encodeWithSelector(IVaultToken.UnauthorizedTransfer.selector, proxyA, wallet));
        token.transferFrom(proxyA, wallet, 10);
        vm.prank(hub);
        token.approve(wallet, 100);
        vm.prank(wallet);
        vm.expectRevert(abi.encodeWithSelector(IVaultToken.UnauthorizedTransfer.selector, hub, wallet));
        token.transferFrom(hub, wallet, 10);
        assertEq(token.allowance(hub, wallet), 100, "allowance spent");
        assertEq(token.allowance(proxyA, wallet), type(uint256).max, "unlimited allowance changed");
    }

    // TEST-189 verifies: REQ-VTOKEN-034, REQ-VTOKEN-011
    /// @notice On an allowed path the standard OpenZeppelin allowance and balance errors apply.
    function test_TEST_189_allowedPathKeepsErc20Errors() public {
        _register(proxyA);
        _mint(proxyA, 10);
        vm.prank(spoke);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spoke, 0, 10));
        token.transferFrom(proxyA, hub, 10);
        vm.prank(proxyA);
        token.approve(spoke, 20);
        vm.prank(spoke);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, proxyA, 10, 20));
        token.transferFrom(proxyA, hub, 20);
    }

    // ─── Views (TEST-189) ───

    // TEST-189 verifies: REQ-VTOKEN-040, REQ-VTOKEN-006, INV-011
    function test_TEST_189_recipientViewIsHubLpVaultSwapAndProxies() public {
        _register(proxyA);
        assertTrue(token.isAllowedRecipient(hub), "hub");
        assertTrue(token.isAllowedRecipient(lpVaultSwap), "lpVaultSwap");
        assertTrue(token.isAllowedRecipient(proxyA), "proxy");
        address[7] memory refused = [adapter, spoke, lpVault, collateralization, lpOracle, wallet, proxyB];
        for (uint256 i = 0; i < refused.length; ++i) {
            assertFalse(token.isAllowedRecipient(refused[i]), "refused recipient allowed");
        }
    }

    // TEST-189 verifies: REQ-VTOKEN-006, REQ-VTOKEN-008, REQ-VTOKEN-040, REQ-VTOKEN-041, REQ-VTOKEN-048, INV-011, Q-224, Q-300
    /// @notice For any pair of addresses and any registration state, `isAllowedTransfer` equals the formula of
    /// `REQ-VTOKEN-040`; a `transfer` of a non-zero amount the sender holds succeeds exactly when it is true, and a
    /// zero-amount `transfer` never succeeds.
    function testFuzz_TEST_189_transferSucceedsExactlyOnAllowedPath(
        address from,
        address to,
        bool registerFrom,
        bool registerTo,
        uint256 amount
    ) public {
        vm.assume(from != address(0));
        amount = bound(amount, 1, type(uint128).max);
        if (registerFrom) _tryRegister(from);
        if (registerTo) _tryRegister(to);
        bool expected =
            (to == hub && token.isValidProxy(from)) || (from == hub && (token.isValidProxy(to) || to == lpVaultSwap));
        assertEq(token.isAllowedTransfer(from, to), expected, "formula");
        deal(address(token), from, amount);
        vm.prank(from);
        (bool ok,) = address(token).call(abi.encodeCall(IERC20.transfer, (to, 0)));
        assertFalse(ok, "zero transfer succeeded");
        vm.prank(from);
        (ok,) = address(token).call(abi.encodeCall(IERC20.transfer, (to, amount)));
        assertEq(ok, expected, "transfer outcome");
    }

    // TEST-189 verifies: REQ-VTOKEN-008, REQ-VTOKEN-010, REQ-VTOKEN-011, REQ-VTOKEN-030, REQ-VTOKEN-048, INV-011
    /// @notice For any spender, holder, recipient, allowance and amount, `transferFrom` succeeds exactly when the path
    /// is allowed, the amount is non-zero and within the allowance and balance; an off-path or zero-amount call spends
    /// no allowance.
    function testFuzz_TEST_189_transferFromNeedsPathAmountAndAllowance(
        address spender,
        address from,
        address to,
        bool registerFrom,
        uint256 allowance_,
        uint256 amount
    ) public {
        vm.assume(from != address(0) && spender != address(0));
        allowance_ = bound(allowance_, 0, type(uint128).max);
        amount = bound(amount, 0, type(uint128).max);
        if (registerFrom) _tryRegister(from);
        deal(address(token), from, type(uint128).max);
        vm.prank(from);
        token.approve(spender, allowance_);
        bool expected = token.isAllowedTransfer(from, to) && amount > 0 && amount <= allowance_;
        vm.prank(spender);
        (bool ok,) = address(token).call(abi.encodeCall(IERC20.transferFrom, (from, to, amount)));
        assertEq(ok, expected, "transferFrom outcome");
        assertEq(token.allowance(from, spender), ok ? allowance_ - amount : allowance_, "allowance");
    }

    // TEST-022 verifies: REQ-VTOKEN-005, REQ-VTOKEN-015, SPEC-UNIT-002, INV-009, INV-010, Q-066, Q-224
    /// @notice A full cycle conserves units one-for-one: pledge n, withdraw w, burn w, seize s, burn s; the supply is
    /// always the sum of the holders' balances and ends at n − w − s, all in the Hub.
    function testFuzz_TEST_022_unitsMoveOneForOne(
        uint120 n,
        uint120 w,
        uint120 s
    ) public {
        n = uint120(bound(n, 1, type(uint120).max));
        w = uint120(bound(w, 0, n));
        s = uint120(bound(s, 0, n - w));
        _pledge(proxyA, n);
        // A zero withdrawal or seizure is no movement at all: zero-amount transfers revert (REQ-VTOKEN-048).
        if (w > 0) {
            vm.prank(hub);
            token.transfer(proxyA, w);
            vm.prank(adapter);
            token.burn(proxyA, w);
        }
        if (s > 0) {
            vm.prank(hub);
            token.transfer(lpVaultSwap, s);
            vm.prank(adapter);
            token.burn(lpVaultSwap, s);
        }
        uint256 rest = uint256(n) - w - s;
        assertEq(token.totalSupply(), rest, "supply");
        assertEq(token.balanceOf(hub), rest, "hub");
        assertEq(token.balanceOf(proxyA) + token.balanceOf(lpVaultSwap), 0, "units outside the Hub");
    }

    function _tryRegister(
        address account
    ) private {
        vm.prank(adapter);
        (bool ok,) = address(token).call(abi.encodeCall(IVaultToken.addValidProxy, (account)));
        ok;
    }
}
