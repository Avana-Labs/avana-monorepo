// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IPayoutEscrow} from "../../src/liquidation/payout-escrow/IPayoutEscrow.sol";
import {PayoutEscrow} from "../../src/liquidation/payout-escrow/PayoutEscrow.sol";
import {ILock} from "../../src/lock/lock/ILock.sol";
import {Lock} from "../../src/lock/lock/Lock.sol";
import {AvanaTest} from "../utils/AvanaTest.sol";
import {ForkConstants} from "../utils/fixtures/ForkConstants.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @notice LPVaultSwap's Lock seat for the fork: takes the Lock, approves the escrow with `forceApprove` (USDT returns
/// no value) and deposits an undelivered payout, as LPVaultSwap does.
contract ForkEscrowDepositor {
    using SafeERC20 for IERC20;

    ILock public lock;
    IPayoutEscrow public escrow;

    function bind(
        ILock lock_,
        IPayoutEscrow escrow_
    ) external {
        (lock, escrow) = (lock_, escrow_);
    }

    function depositUnderLock(
        address token,
        address account,
        uint256 amount
    ) external {
        lock.acquire();
        IERC20(token).forceApprove(address(escrow), amount);
        escrow.deposit(token, account, amount);
        lock.release();
    }
}

interface IForkUsdc {
    function blacklister() external view returns (address);
    function blacklist(
        address account
    ) external;
}

interface IForkUsdt {
    function owner() external view returns (address);
    function setParams(
        uint256 newBasisPoints,
        uint256 newMaxFee
    ) external;
}

/// @title PayoutEscrowForkTest
/// @notice TEST-221 for the PayoutEscrow on an Ethereum fork, with the live USDC and USDT: a payout to a borrower the
/// USDC issuer has blocklisted is escrowed and claimed to another recipient (a claim to the blocked address reverts and
/// the credit stays); with USDT's `basisPointsRate` switched on, a deposit credits the amount that arrived. The
/// depositor holds LPVaultSwap's Lock seat. Skipped without `RPC_MAINNET` or a pinned block.
/// @dev Run with `FOUNDRY_PROFILE=fork forge test --match-contract PayoutEscrowForkTest`.
/// forge-config: default.isolate = false
contract PayoutEscrowForkTest is AvanaTest {
    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address internal constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;

    ForkEscrowDepositor internal depositor;
    PayoutEscrow internal escrow;

    function setUp() public {
        string memory rpc = vm.envOr("RPC_MAINNET", string(""));
        uint256 blockNumber = ForkConstants.mainnetForkBlock();
        if (bytes(rpc).length == 0 || blockNumber == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpc, blockNumber);
        depositor = new ForkEscrowDepositor();
        Lock lock = new Lock(makeAddr("aaveAdapter"), address(depositor));
        escrow = new PayoutEscrow(address(depositor), address(lock));
        depositor.bind(ILock(address(lock)), IPayoutEscrow(address(escrow)));
    }

    // TEST-221 verifies: REQ-ESCROW-002, REQ-ESCROW-004, REQ-ESCROW-013, Q-214
    function test_TEST_221_blocklistedBorrowerPaidThroughTheEscrow() public {
        vm.prank(IForkUsdc(USDC).blacklister());
        IForkUsdc(USDC).blacklist(bob);
        deal(USDC, address(depositor), 1000e6);
        depositor.depositUnderLock(USDC, bob, 1000e6);
        assertEq(escrow.claimable(USDC, bob), 1000e6, "credited to the blocked borrower");
        vm.prank(bob);
        vm.expectRevert();
        escrow.claim(USDC, bob);
        assertEq(escrow.claimable(USDC, bob), 1000e6, "the credit stays after a refused claim");
        address fresh = makeAddr("fresh wallet");
        vm.prank(bob);
        assertEq(escrow.claim(USDC, fresh), 1000e6, "claimed to another recipient");
        assertEq(IERC20(USDC).balanceOf(fresh), 1000e6, "paid");
        assertEq(escrow.totalClaimable(USDC), 0, "nothing left owed");
    }

    // TEST-221 verifies: REQ-ESCROW-003, REQ-ESCROW-011, Q-271
    function test_TEST_221_usdtFeeSwitchedOnCreditsWhatArrived() public {
        vm.prank(IForkUsdt(USDT).owner());
        IForkUsdt(USDT).setParams(10, 50);
        deal(USDT, address(depositor), 1_612_848);
        uint256 before = IERC20(USDT).balanceOf(address(escrow));
        depositor.depositUnderLock(USDT, bob, 1_612_848);
        uint256 arrived = IERC20(USDT).balanceOf(address(escrow)) - before;
        assertEq(arrived, uint256(1_612_848) - uint256(1_612_848) * 10 / 10_000, "the fee-reduced amount arrived");
        assertEq(escrow.claimable(USDT, bob), arrived, "credit = what arrived");
        assertEq(escrow.totalClaimable(USDT), arrived, "total = what arrived");
    }
}
