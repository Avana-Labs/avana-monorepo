// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IPayoutEscrow} from "../../src/liquidation/payout-escrow/IPayoutEscrow.sol";
import {PayoutEscrow} from "../../src/liquidation/payout-escrow/PayoutEscrow.sol";
import {Lock} from "../../src/lock/lock/Lock.sol";
import {LockMember} from "../utils/mocks/LockMember.sol";
import {PayoutActor, PayoutDepositor} from "../utils/mocks/PayoutEscrowActors.sol";
import {PayoutToken} from "../utils/mocks/PayoutToken.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Test} from "forge-std/Test.sol";

/// Token whose outgoing transfer debits the sender amount + fee (fee charged on top).
contract SenderFeeToken is ERC20 {
    uint256 public feeBps;
    constructor() ERC20("SF", "SF") {}
    function mint(address to, uint256 a) external { _mint(to, a); }
    function setFeeBps(uint256 b) external { feeBps = b; }
    function transfer(address to, uint256 a) public override returns (bool) {
        uint256 fee = a * feeBps / 10_000;
        if (fee != 0) _transfer(msg.sender, address(0xFEE5), fee);
        _transfer(msg.sender, to, a);
        return true;
    }
}

/// Issuer that can burn any holder's balance (USDT destroyBlackFunds-style, or a negative rebase).
contract BurnableToken is ERC20 {
    constructor() ERC20("BT", "BT") {}
    function mint(address to, uint256 a) external { _mint(to, a); }
    function issuerBurn(address from, uint256 a) external { _burn(from, a); }
}

/// forge-config: default.isolate = false
contract PayoutEscrowReviewTest is Test {
    Lock lock;
    PayoutEscrow escrow;
    LockMember adapter;
    PayoutDepositor swap;
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");
    address dave = makeAddr("dave");

    function setUp() public {
        adapter = new LockMember();
        swap = new PayoutDepositor();
        lock = new Lock(address(adapter), address(swap));
        escrow = new PayoutEscrow(address(swap), address(lock));
        adapter.setLock(lock);
        swap.setUp(lock, escrow);
    }

    /// Escrow deployed with an lpVaultSwap the Lock does not know: constructor accepts it, every deposit reverts
    /// NotLocked, so every liquidation with a failed payout reverts for the escrow's (immutable) life.
    function test_PoC_constructorMismatchBricksDeposits() public {
        PayoutDepositor other = new PayoutDepositor();
        PayoutEscrow bad = new PayoutEscrow(address(other), address(lock)); // no cross-check
        other.setUp(lock, bad);
        PayoutToken t = new PayoutToken("USDC", 6);
        t.mint(address(other), 100);
        vm.expectRevert(); // Lock.acquire: NotMember -- and holder() can never equal `other`
        other.depositUnderLock(address(t), bob, 100);
        // Even inside a real LPVaultSwap lock, holder() == swap != bad.LP_VAULT_SWAP().
        assertTrue(lock.LP_VAULT_SWAP() != bad.LP_VAULT_SWAP());
    }

    /// Escrow deployed with the AaveAdapter's address as lpVaultSwap: the Adapter, while holding its own Lock,
    /// passes both deposit checks.
    function test_PoC_constructorAdapterAsDepositor() public {
        PayoutEscrow bad = new PayoutEscrow(address(adapter), address(lock));
        PayoutToken t = new PayoutToken("USDC", 6);
        t.mint(address(adapter), 100);
        vm.prank(address(adapter));
        lock.acquire();
        vm.startPrank(address(adapter));
        t.approve(address(bad), 100);
        bad.deposit(address(t), bob, 100);
        vm.stopPrank();
        assertEq(bad.claimable(address(t), bob), 100);
    }

    /// A token that charges the sender on top: bob's claim drains more than his credit; carol's credit is no longer
    /// backed and her claim reverts. INV-061 (balance >= totalClaimable) breaks.
    function test_PoC_senderFeeClaimDrainsOtherCredits() public {
        SenderFeeToken t = new SenderFeeToken();
        t.mint(address(swap), 2000);
        swap.depositUnderLock(address(t), bob, 1000);
        swap.depositUnderLock(address(t), carol, 1000);
        t.setFeeBps(100); // 1% on top, switched on after listing
        vm.prank(bob);
        escrow.claim(address(t), dave);
        assertLt(t.balanceOf(address(escrow)), escrow.totalClaimable(address(t)), "INV-061 broken");
        vm.prank(carol);
        vm.expectRevert();
        escrow.claim(address(t), dave);
    }

    /// Escrow balance falls (issuer burn / negative rebase): first claimer is paid in full, the last cannot claim.
    function test_PoC_balanceFallFirstComeFirstServed() public {
        BurnableToken t = new BurnableToken();
        t.mint(address(swap), 2000);
        swap.depositUnderLock(address(t), bob, 1000);
        swap.depositUnderLock(address(t), carol, 1000);
        t.issuerBurn(address(escrow), 500);
        vm.prank(bob);
        escrow.claim(address(t), dave);
        vm.prank(carol);
        vm.expectRevert();
        escrow.claim(address(t), dave);
        assertEq(escrow.claimable(address(t), carol), 1000);
    }

    /// Rounding-up rebasing token (balance rises by amount+1): deposit reverts TransferMismatch, which reverts the
    /// whole liquidation instead of crediting `amount`.
    function test_PoC_roundUpTokenRevertsLiquidation() public {
        PayoutToken t = new PayoutToken("aT", 6);
        t.setBonus(1);
        t.mint(address(swap), 100);
        vm.expectRevert(IPayoutEscrow.TransferMismatch.selector);
        swap.depositUnderLock(address(t), bob, 100);
    }

    /// A blocklisted credited account can still claim: the token checks the escrow (sender) and the recipient only.
    function test_PoC_blockedClaimantClaimsElsewhere() public {
        PayoutToken t = new PayoutToken("USDC", 6);
        t.mint(address(swap), 100);
        swap.depositUnderLock(address(t), bob, 100);
        t.setBlocked(bob, true);
        vm.prank(bob);
        escrow.claim(address(t), dave);
        assertEq(t.balanceOf(dave), 100);
    }

    /// Hook during a claim that liquidates through LPVaultSwap (deposit under Lock): Reentrancy, own tx only.
    function test_PoC_claimHookCannotDepositThroughLock() public {
        PayoutToken t = new PayoutToken("USDC", 6);
        PayoutActor a = new PayoutActor();
        t.mint(address(swap), 150);
        swap.depositUnderLock(address(t), address(a), 100);
        t.setHook(address(swap), abi.encodeCall(PayoutDepositor.depositUnderLock, (address(t), bob, 50)));
        vm.expectRevert(IPayoutEscrow.Reentrancy.selector);
        a.claim(escrow, address(t), dave);
    }
}
