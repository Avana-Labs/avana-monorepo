// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ICollateralizationErrors} from "../../src/custody/collateralization/ICollateralizationErrors.sol";
import {ILock} from "../../src/lock/lock/ILock.sol";
import {RepayWithCollateralParams} from "../../src/policy/aave-adapter/types/RepayWithCollateralParams.sol";
import {PositionRef} from "../../src/types/PositionRef.sol";
import {AaveAdapterFixture} from "../utils/fixtures/AaveAdapterFixture.sol";

/// @title AaveAdapterReentryRowsUnitTest
/// @notice Re-entry through a pool token's transfer hook (TEST-222, the AaveAdapter's share) on the real AaveAdapter,
/// Lock, Collateralization, vault tokens, ProxyManager and PositionProxies on the real local Aave V4. USDC, a pool token
/// of the market, calls back (ERC-777 style, `CollPoolToken.armHook`) while the LPVault pays it out during a partial
/// removal and during a fee collection; the callback re-enters every state-changing Adapter entry point as the
/// borrower and reads the Adapter's and Collateralization's views.
/// forge-config: default.isolate = false
contract AaveAdapterReentryRowsUnitTest is AaveAdapterFixture {
    uint256 internal constant ENTRY_POINTS = 10;

    bytes32 internal k1;
    bytes32 internal k2;
    address internal p;

    uint256 internal reentries;
    uint256 internal lockHeldReverts;
    uint256 internal otherOutcomes;
    bool internal viewsAsBefore;
    bool internal collViewsRefused;

    address internal proxyBefore;
    uint256 internal nonceBefore;

    function setUp() public override {
        super.setUp();
        (k1, p) = _pledgeAs(alice, MARKET_ID, UNITS);
        (k2,) = _pledgeAs(alice, MARKET_ID, UNITS);
        _borrowAs(alice, MARKET_ID, debtReserveId, 1000e18);
        _fund(alice, debtReserveId, 10e18);
    }

    function _entryPoints() internal view returns (bytes[] memory c) {
        uint256 d = block.timestamp + 600;
        uint256[] memory ids = new uint256[](1);
        ids[0] = debtReserveId;
        uint256[] memory caps = new uint256[](1);
        caps[0] = 10e18;
        PositionRef memory r2 = PositionRef(INTEGRATION, k2);
        RepayWithCollateralParams memory rwc = _rwc(MARKET_ID, k2, 1_000_000, debtReserveId);
        c = new bytes[](ENTRY_POINTS);
        c[0] = abi.encodeCall(adapterC.pledge, (MARKET_ID, PositionRef(INTEGRATION, keccak256("fresh")), d));
        c[1] = abi.encodeCall(adapterC.borrow, (MARKET_ID, debtReserveId, 1e18, alice, d, 0, nonceBefore));
        c[2] = abi.encodeCall(adapterC.repay, (alice, MARKET_ID, debtReserveId, 1e18, false, d));
        c[3] = abi.encodeCall(adapterC.withdraw, (MARKET_ID, r2, 1_000_000, d, 0));
        c[4] = abi.encodeCall(adapterC.removeLiquidity, (MARKET_ID, r2, 1_000_000, _mins(), d, 0));
        c[5] = abi.encodeCall(adapterC.collectFees, (MARKET_ID, r2, d));
        c[6] = abi.encodeCall(adapterC.recredit, (MARKET_ID, r2, abi.encode(uint128(1)), d));
        c[7] = abi.encodeCall(adapterC.repayWithCollateral, (rwc));
        c[8] = abi.encodeCall(adapterC.repayAllAndWithdraw, (MARKET_ID, r2, UNITS, ids, caps, d));
        c[9] = abi.encodeCall(adapterC.releaseZeroCredit, (MARKET_ID, r2, d));
    }

    /// @notice The token callback: re-enters each entry point as the borrower, then reads the views.
    function reenterEverything() external {
        bytes[] memory calls = _entryPoints();
        bytes memory held = abi.encodeWithSelector(ILock.LockHeld.selector, adapter);
        for (uint256 i = 0; i < calls.length; ++i) {
            ++reentries;
            vm.prank(alice);
            (bool ok, bytes memory ret) = adapter.call(calls[i]);
            if (!ok && keccak256(ret) == keccak256(held)) ++lockHeldReverts;
            else ++otherOutcomes;
        }
        viewsAsBefore = adapterC.proxyOf(alice, MARKET_ID) == proxyBefore && adapterC.borrowNonce(p) == nonceBefore
            && adapterC.walletOf(p) == alice;
        (bool okRecord, bytes memory r1) =
            address(coll).staticcall(abi.encodeWithSignature("recordIdOf(uint32,bytes32)", INTEGRATION, k2));
        (bool okCredit, bytes memory r2) =
            address(coll).staticcall(abi.encodeWithSignature("getAccountCredited(address,address)", p, vt));
        collViewsRefused = !okRecord && !okCredit && bytes4(r1) == ICollateralizationErrors.Locked.selector
            && bytes4(r2) == ICollateralizationErrors.Locked.selector;
    }

    function _arm() internal {
        proxyBefore = adapterC.proxyOf(alice, MARKET_ID);
        nonceBefore = adapterC.borrowNonce(p);
        (reentries, lockHeldReverts, otherOutcomes) = (0, 0, 0);
        (viewsAsBefore, collViewsRefused) = (false, false);
        usdc.armHook(address(this), abi.encodeCall(this.reenterEverything, ()));
    }

    function _assertNoReentry(
        string memory during
    ) internal view {
        assertTrue(usdc.hookFired() && usdc.hookSucceeded(), string.concat("the callback ran during ", during));
        assertEq(reentries, ENTRY_POINTS, "every entry point re-entered");
        assertEq(lockHeldReverts, ENTRY_POINTS, string.concat("every re-entry reverts LockHeld(adapter): ", during));
        assertEq(otherOutcomes, 0, "no re-entry passed or failed otherwise");
        assertTrue(viewsAsBefore, "the Adapter's views answer pre-call values");
        assertTrue(collViewsRefused, "Collateralization's views refuse mid-call");
    }

    // TEST-222 verifies: REQ-LOCK-007, REQ-PROXY-048, REQ-PROXY-076, ATTACK-092, ATTACK-093
    // Sources: 5.1 TEST-222 (Adapter side), Q-254, Q-255
    /// @notice During a partial removal the USDC payout calls back: every Adapter entry point re-entered as the
    /// borrower reverts `LockHeld(adapter)`, the Adapter's views answer pre-call values and Collateralization's views
    /// refuse; the outer removal completes exactly as without the callback.
    function test_TEST_222_reentryDuringPartialRemovalChangesNothing() public {
        uint256 supply0 = token.totalSupply();
        uint256 credited0 = coll.getAccountCredited(p, vt);
        uint256 debt0 = _debtOf(p, debtReserveId);
        _arm();
        vm.prank(alice);
        adapterC.removeLiquidity(MARKET_ID, _ref(k1), 1_000_000_000, _mins(), _deadline(), 0);
        _assertNoReentry("a partial removal");
        assertEq(supply0 - token.totalSupply(), 1_000_000_000, "only the outer removal burned");
        assertEq(credited0 - coll.getAccountCredited(p, vt), 1_000_000_000, "only the outer removal debited");
        assertEq(_debtOf(p, debtReserveId), debt0, "no re-entered borrow or repay");
        assertEq(adapterC.borrowNonce(p), nonceBefore, "nonce unchanged");
        assertFalse(lock.isLocked(), "lock free after the call");
    }

    // TEST-222 verifies: REQ-LOCK-007, REQ-PROXY-048, ATTACK-092, ATTACK-093
    /// @notice The same during a fee collection: every re-entry reverts `LockHeld(adapter)`, and the collection pays
    /// exactly the accrued fees and moves no units.
    function test_TEST_222_reentryDuringFeeCollectionChangesNothing() public {
        lpVault.accrueFees(k1, 5e6);
        uint256 supply0 = token.totalSupply();
        uint256 usdc0 = usdc.balanceOf(alice);
        _arm();
        vm.prank(alice);
        adapterC.collectFees(MARKET_ID, _ref(k1), _deadline());
        _assertNoReentry("a fee collection");
        assertEq(usdc.balanceOf(alice) - usdc0, 5e6, "the accrued fees only");
        assertEq(token.totalSupply(), supply0, "no unit moved");
        assertFalse(lock.isLocked(), "lock free after the call");
    }
}
