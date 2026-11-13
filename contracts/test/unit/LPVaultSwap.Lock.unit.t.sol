// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ILPVaultSwapErrors} from "../../src/liquidation/lp-vault-swap/ILPVaultSwapErrors.sol";
import {ILPVaultSwapLiquidation} from "../../src/liquidation/lp-vault-swap/ILPVaultSwapLiquidation.sol";
import {DeleverageRequest} from "../../src/liquidation/lp-vault-swap/types/DeleverageRequest.sol";
import {LiquidationResult} from "../../src/liquidation/lp-vault-swap/types/LiquidationResult.sol";
import {ILock} from "../../src/lock/lock/ILock.sol";
import {IAaveAdapterErrors} from "../../src/policy/aave-adapter/IAaveAdapterErrors.sol";
import {LVSLyingRoute} from "../utils/mocks/LPVaultSwapMocks.sol";
import {LPVaultSwapUnitBase} from "./LPVaultSwap.Base.sol";

/// @notice Hook target of a payout token: records the Lock holder every time a transfer of the token runs.
contract LVSLockProbe {
    ILock public immutable lock;
    address[] public holders;

    constructor(
        ILock lock_
    ) {
        lock = lock_;
    }

    fallback() external {
        holders.push(lock.holder());
    }

    function count() external view returns (uint256) {
        return holders.length;
    }
}

/// @title LPVaultSwapLockUnitTest
/// @notice LPVaultSwap as a member of the chain's Lock (2.11 REQ-SWAP-002; 2.16 REQ-LOCK-005, REQ-LOCK-007,
/// REQ-LOCK-023, REQ-LOCK-030): `liquidate` and `settlePending` acquire the Lock before any state-changing external
/// call and release it as their last step, so every route call, payout transfer and escrow deposit runs with
/// LPVaultSwap as holder and no Avana entry point can be re-entered; a reverted call leaves the Lock free; `deleverage`
/// and its callback run only under the AaveAdapter's Lock and call its two steps in order; the Lock's members are
/// exactly the AaveAdapter and LPVaultSwap.
/// forge-config: default.isolate = false
contract LPVaultSwapLockUnitTest is LPVaultSwapUnitBase {
    address internal proxy;

    function setUp() public override {
        super.setUp();
        (proxy,) = _bobAccount();
    }

    /// @notice TEST-270: the Lock's members are the AaveAdapter and LPVaultSwap, fixed at construction; LPVaultSwap names
    /// that Lock; any other address's `acquire` reverts `NotMember`.
    // TEST-270 verifies: REQ-LOCK-001, REQ-SWAP-002, INV-091, PROP-075
    function test_TEST_270_lockMembership() public {
        assertEq(lock.AAVE_ADAPTER(), address(adapter), "AaveAdapter member");
        assertEq(lock.LP_VAULT_SWAP(), address(lvs), "LPVaultSwap member");
        assertEq(lvs.LOCK(), address(lock), "LPVaultSwap's Lock");
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(ILock.NotMember.selector, attacker));
        lock.acquire();
        vm.prank(address(implementation));
        vm.expectRevert(abi.encodeWithSelector(ILock.NotMember.selector, address(implementation)));
        lock.acquire();
    }

    /// @notice Every debt-asset transfer of a liquidation (caller pull, Aave's repayment, payouts) runs while
    /// LPVaultSwap holds the Lock, the caller's payout included, and the Lock is free after the call.
    // TEST-060 verifies: REQ-SWAP-002, REQ-LOCK-007, REQ-LOCK-030, INV-054
    function test_TEST_060_heldForEveryTransferReleasedLast() public {
        LVSLockProbe probe = new LVSLockProbe(ILock(address(lock)));
        _fund(usdc, keeper, 1950e6);
        usdc.setHook(address(probe), "");
        vm.prank(keeper);
        lvs.liquidate(_params(proxy, 1950e6));
        usdc.setHook(address(0), "");
        assertGt(probe.count(), 3, "transfers observed");
        for (uint256 i = 0; i < probe.count(); ++i) {
            assertEq(probe.holders(i), address(lvs), "LPVaultSwap holds the Lock at every transfer");
        }
        assertFalse(lock.isLocked(), "released");
    }

    /// @notice A route re-entering `liquidate` or `settlePending` reverts `LockHeld(LPVaultSwap)`; one re-entering
    /// `deleverage` reverts `NotAdapter`; the outer liquidation itself settles.
    // TEST-060 verifies: REQ-SWAP-002, REQ-LOCK-005, REQ-SWAP-106, INV-054, PROP-037
    function test_TEST_060_noReentryFromRoute() public {
        bytes[3] memory calls = [
            abi.encodeCall(ILPVaultSwapLiquidation.liquidate, (_params(proxy, 1950e6))),
            abi.encodeCall(ILPVaultSwapLiquidation.settlePending, (MARKET_ID, usdcReserveId)),
            abi.encodeCall(lvs.deleverage, (_emptyRequest()))
        ];
        bytes[3] memory errors = [
            abi.encodeWithSelector(ILPVaultSwapErrors.LockHeld.selector, address(lvs)),
            abi.encodeWithSelector(ILPVaultSwapErrors.LockHeld.selector, address(lvs)),
            abi.encodeWithSelector(ILPVaultSwapErrors.NotAdapter.selector)
        ];
        for (uint256 i = 0; i < calls.length; ++i) {
            LVSLyingRoute reentrant = new LVSLyingRoute(address(usdt), address(usdc));
            usdc.mint(address(reentrant), 1_009_594_950);
            reentrant.setOut(1_009_594_950);
            reentrant.setReenter(address(lvs), calls[i]);
            registry.setRoute(MARKET_ID, address(usdt), address(usdc), 0, address(reentrant), true);
            LiquidationResult memory r = _liquidateAs(keeper, _params(proxy, 1950e6));
            assertFalse(reentrant.lastReenterOk(), "re-entry refused");
            assertEq(keccak256(reentrant.lastReenterData()), keccak256(errors[i]), "error");
            assertGt(r.debtRepaid, 0, "outer call settles");
        }
    }

    function _emptyRequest() internal pure returns (DeleverageRequest memory r) {
        r.minAmounts = new uint256[](0);
    }

    /// @notice A reverted liquidation leaves the Lock free (transient storage rolls back with the revert): the next
    /// call by any member acquires it.
    // TEST-060 verifies: REQ-SWAP-002, REQ-LOCK-007
    function test_TEST_060_revertLeavesLockFree() public {
        lpOracle.setAnswer(250_000_000); // healthy: NotLiquidatable inside the Lock
        _expectLiquidateRevert(keeper, _params(proxy, 1950e6), _err(ILPVaultSwapErrors.NotLiquidatable.selector));
        assertFalse(lock.isLocked(), "free after a revert");
        vm.prank(address(adapter));
        lock.acquire();
        vm.prank(address(adapter));
        lock.release();
    }

    /// @notice REQ-LOCK-023 from LPVaultSwap's side: the AaveAdapter's deleverage steps run only for LPVaultSwap under
    /// the AaveAdapter's Lock and only in their session order; LPVaultSwap calls them once each, repay before release.
    // TEST-060 verifies: REQ-LOCK-023, REQ-SWAP-106
    function test_TEST_060_deleverageStepsOnlyInOrderUnderAdapterLock() public {
        (address aliceProxy, bytes32 key) = _openAccount(alice, 10_000e6, 15_000e6, 250_000_000);
        vm.prank(attacker);
        vm.expectRevert(IAaveAdapterErrors.NotLPVaultSwap.selector);
        adapter.deleverageRepay(aliceProxy, usdcReserveId, 1);
        vm.prank(address(lvs));
        vm.expectRevert(IAaveAdapterErrors.NotLPVaultSwap.selector);
        adapter.deleverageRelease(aliceProxy, _position(key), 1, new uint256[](0));
        uint256 repays = adapter.repayCalls();
        uint256 releases = adapter.releaseCalls();
        vm.prank(alice);
        adapter.repayWithCollateral(aliceProxy, _position(key), 1000e6, usdcReserveId, new uint256[](2), 0);
        assertEq(adapter.repayCalls(), repays + 1, "repay once");
        assertEq(adapter.releaseCalls(), releases + 1, "release once");
        assertFalse(lock.isLocked(), "released by the AaveAdapter");
    }

    /// @notice A payout recipient's token hook re-entering `liquidate` during the fee transfer is refused (the transfer
    /// fails inside its gas, and the fee is escrowed): no Avana entry runs mid-settlement.
    // TEST-060 verifies: REQ-SWAP-002, REQ-SWAP-076, INV-054
    function test_TEST_060_payoutHookCannotReenter() public {
        _fund(usdc, keeper, 2 * 1950e6);
        usdc.setHook(address(lvs), abi.encodeCall(ILPVaultSwapLiquidation.liquidate, (_params(proxy, 1950e6))));
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(ILPVaultSwapErrors.LockHeld.selector, address(lvs)));
        lvs.liquidate(_params(proxy, 1950e6));
        assertFalse(lock.isLocked(), "free");
    }
}
