// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ICollateralizationErrors} from "../../src/custody/collateralization/ICollateralizationErrors.sol";
import {ICollateralizationSeizure} from "../../src/custody/collateralization/ICollateralizationSeizure.sol";
import {Pending} from "../../src/custody/collateralization/types/Pending.sol";
import {IAaveV4Spoke} from "../../src/interfaces/external/aave/IAaveV4Spoke.sol";
import {IAaveAdapterErrors} from "../../src/policy/aave-adapter/IAaveAdapterErrors.sol";
import {IPositionProxy} from "../../src/proxy/position-proxy/IPositionProxy.sol";
import {AaveAdapterFixture} from "../utils/fixtures/AaveAdapterFixture.sol";

/// @title AaveAdapterSeizureRowsUnitTest
/// @notice The AaveAdapter's share of seizure and pending settlement (TEST-056, TEST-131, TEST-152, TEST-154) on the
/// real local Aave V4, Collateralization, vault tokens, ProxyManager and PositionProxies. LPVaultSwap is the settable
/// `LPVaultSwapMock`, honest (`liquidate`, `settlePending`) or hostile (`seizeAndKeep`, a burn without a settlement):
/// these rows are about what the reviewed Adapter allows any LPVaultSwap to do. The Adapter's `burnSeized` is the only
/// burn of seized or pending units and burns only from LPVaultSwap; the borrower's own exits run through the Adapter.
/// forge-config: default.isolate = false
contract AaveAdapterSeizureRowsUnitTest is AaveAdapterFixture {
    uint128 internal constant U1000 = 1_000_000_000;
    uint128 internal constant U800 = 800_000_000;

    function _pledgeKey(
        address wallet,
        bytes32 key,
        uint128 units
    ) internal returns (address proxy) {
        lpVault.mintPosition(key, wallet, MARKET_ID, units);
        vm.prank(wallet);
        (proxy,,) = adapterC.pledge(MARKET_ID, _ref(key), _deadline());
    }

    function _repayAll(
        address wallet,
        address proxy
    ) internal {
        uint256 owed = _debtOf(proxy, debtReserveId);
        _fund(wallet, debtReserveId, owed);
        vm.prank(wallet);
        adapterC.repay(wallet, MARKET_ID, debtReserveId, owed, true, _deadline());
    }

    function _withdrawAll(
        address wallet,
        bytes32 key
    ) internal returns (uint256 units) {
        units = coll.previewRelease(INTEGRATION, key);
        vm.prank(wallet);
        adapterC.withdraw(MARKET_ID, _ref(key), units, _deadline(), 0);
    }

    function _backed() internal view {
        assertLe(token.totalSupply(), coll.getTotalCredited(vt) + coll.getPending(vt).units, "backed");
    }

    // ─── TEST-154: C-QNT-1 through the Adapter ───

    // TEST-154 verifies: INV-001, INV-008, INV-058, REQ-VAULT-129, REQ-VAULT-136, REQ-VAULT-139, SPEC-BACK-012, Q-201
    // Sources: 5.1 TEST-154 (C-QNT-1), QNT-07, QNT-T09
    /// @notice Records of 1,000 and 800 units on one proxy; a hostile LPVaultSwap seizes about 315 units and keeps
    /// them. The borrower repays through the Adapter and withdraws NFT 42: Collateralization reconciles the shortfall,
    /// the Adapter burns only the remaining 685 units from the proxy, NFT 42 returns with 685 units of liquidity and 315
    /// are pending; NFT 7 then returns with all 800. An honest LPVaultSwap settles the 315 pending units, the Adapter
    /// burning them from LPVaultSwap, after which the market's supply, credit and pending balance are 0, the proxy keeps
    /// its binding and code, and no position is left in custody.
    function test_TEST_154_cQnt1RegressionThroughTheAdapter() public {
        bytes32 k42 = keccak256("nft 42");
        bytes32 k7 = keccak256("nft 7");
        address proxy = _pledgeKey(alice, k42, U1000);
        _pledgeKey(alice, k7, U800);
        bytes32 codeHash = proxy.codehash;
        _borrowAs(alice, MARKET_ID, debtReserveId, 1600e18);
        vtPrice.set(1.05e8);
        uint256 c = swap.seizeAndKeep(aave.cdpSpoke, vt, vtReserveId, debtReserveId, proxy, 315e18);
        assertApproxEqAbs(c, 315_000_000, 1, "about 315 units seized and kept");
        assertEq(token.balanceOf(lpVaultSwap), c, "kept by the hostile LPVaultSwap");
        _backed();

        vtPrice.set(2e8);
        _repayAll(alice, proxy);
        uint256 supply0 = token.totalSupply();
        assertEq(_withdrawAll(alice, k42), U1000 - c, "NFT 42 releases 685 units");
        assertEq(supply0 - token.totalSupply(), U1000 - c, "the Adapter burned only the remaining units");
        (address owner42,,, uint128 live42,) = lpVault.positions(k42);
        assertEq(owner42, alice, "NFT 42 back with its owner");
        assertEq(live42, U1000 - c, "NFT 42 keeps its remaining liquidity");
        Pending memory p = coll.getPending(vt);
        assertEq(p.units, c, "the shortfall is pending");
        _backed();

        assertEq(_withdrawAll(alice, k7), U800, "NFT 7 releases all 800 units");
        (address owner7,,, uint128 live7,) = lpVault.positions(k7);
        assertEq(owner7, alice, "NFT 7 back with its owner");
        assertEq(live7, U800, "NFT 7 untouched by the reconcile");
        assertEq(_sharesOf(proxy, vtReserveId), 0, "proxy supply 0");

        // An honest LPVaultSwap settles the pending units; the Adapter burns them from LPVaultSwap.
        swap.settlePending(MARKET_ID, vt, c);
        assertEq(token.totalSupply(), 0, "market supply 0");
        assertEq(coll.getTotalCredited(vt), 0, "credit 0");
        assertEq(coll.getPending(vt).units, 0, "pending 0");
        assertEq(token.balanceOf(lpVaultSwap), 0, "nothing left with LPVaultSwap");
        assertEq(usdc.balanceOf(lpVaultSwap), p.amounts[0], "the reconciled principal reached LPVaultSwap");
        assertEq(proxy.codehash, codeHash, "proxy code unchanged");
        assertEq(IPositionProxy(proxy).WALLET(), alice, "proxy wallet unchanged");
        assertEq(adapterC.proxyOf(alice, MARKET_ID), proxy, "binding unchanged");
    }

    // ─── TEST-056: debit check of an honest liquidation ───

    // TEST-056 verifies: REQ-VAULT-047, REQ-VAULT-048, REQ-VAULT-114, REQ-VAULT-115, REQ-COLL-010
    /// @notice An honest liquidation through the Adapter's `burnSeized`: the proxy's share drop equals the units
    /// LPVaultSwap received, equals the supply drop from the Adapter's burn and equals the units Collateralization
    /// debited from the account; LPVaultSwap is left with no vault tokens.
    function test_TEST_056_shareDropEqualsBurnAndDebit() public {
        (, address proxy) = _pledgeAs(alice, MARKET_ID, UNITS);
        _borrowAs(alice, MARKET_ID, debtReserveId, 15_000e18);
        vtPrice.set(1.6e8);
        uint256 shares0 = _sharesOf(proxy, vtReserveId);
        uint256 supply0 = token.totalSupply();
        uint256 credited0 = coll.getAccountCredited(proxy, vt);
        uint256 seized = swap.liquidate(aave.cdpSpoke, MARKET_ID, vt, vtReserveId, debtReserveId, proxy, 2000e18, 2);
        assertGt(seized, 0, "a seizure happened");
        assertEq(shares0 - _sharesOf(proxy, vtReserveId), seized, "share drop = units received");
        assertEq(supply0 - token.totalSupply(), seized, "supply drop = Adapter burn");
        assertEq(credited0 - coll.getAccountCredited(proxy, vt), seized, "debited = seized");
        assertEq(token.balanceOf(lpVaultSwap), 0, "LPVaultSwap keeps nothing");
        _backed();
    }

    // ─── TEST-131: hostile LPVaultSwap ───

    // TEST-131 verifies: REQ-VAULT-049, REQ-VAULT-051, SPEC-BACK-007, ATTACK-025, ATTACK-079
    /// @notice A hostile LPVaultSwap cannot seize a healthy account (Aave refuses the liquidation), cannot have the
    /// Adapter burn from anyone but itself or more than it holds, cannot call `burnSeized` without holding the Lock,
    /// and cannot mint. When it seizes and keeps units, the borrower's next withdrawal through the Adapter reconciles
    /// the shortfall into the pending balance and returns the rest of the NFT.
    function test_TEST_131_hostileLPVaultSwapBoundedByTheAdapter() public {
        bytes32 key = _newKey();
        address proxy = _pledgeKey(alice, key, UNITS);
        _borrowAs(alice, MARKET_ID, debtReserveId, 15_000e18);

        // Healthy: Aave refuses to liquidate.
        vm.expectRevert();
        swap.seizeAndKeep(aave.cdpSpoke, vt, vtReserveId, debtReserveId, proxy, 2000e18);

        // The Adapter burns only from LPVaultSwap, which holds nothing yet, and only under its Lock.
        vm.expectRevert();
        swap.burnUnderLock(MARKET_ID, vt, 1);
        vm.expectRevert(IAaveAdapterErrors.NotLPVaultSwap.selector);
        swap.burnWithoutLock(MARKET_ID, vt, 1);
        vm.expectRevert(IAaveAdapterErrors.NotLPVaultSwap.selector);
        vm.prank(alice);
        adapterC.burnSeized(MARKET_ID, vt, 1);
        vm.expectRevert();
        vm.prank(lpVaultSwap);
        token.mint(lpVaultSwap, 1);

        vtPrice.set(1.6e8);
        uint256 kept = swap.seizeAndKeep(aave.cdpSpoke, vt, vtReserveId, debtReserveId, proxy, 2000e18);
        assertGt(kept, 0, "seized and kept");
        // It cannot burn more than it received.
        vm.expectRevert();
        swap.burnUnderLock(MARKET_ID, vt, kept + 1);
        _backed();

        vtPrice.set(2e8);
        _repayAll(alice, proxy);
        assertEq(_withdrawAll(alice, key), UNITS - kept, "the rest of the NFT is released");
        (address owner,,,,) = lpVault.positions(key);
        assertEq(owner, alice, "no NFT stranded");
        assertEq(coll.getPending(vt).units, kept, "the shortfall is pending");
        _backed();
    }

    // ─── TEST-152: pending settlement needs the Adapter's burn ───

    // TEST-152 verifies: REQ-VAULT-137, REQ-VAULT-138, REQ-VAULT-139, REQ-VAULT-141, REQ-COLL-012, REQ-LOCK-007
    /// @notice `settlePending` succeeds only after the Adapter burned exactly `units` from LPVaultSwap in the same
    /// call: without the burn it reverts `SupplyDropMismatch`; above the pending balance it reverts `PendingExceeded`;
    /// `burnSeized` from any caller but LPVaultSwap, or without its Lock, reverts `NotLPVaultSwap`, and for another
    /// market's token `UnknownMarket`. A matching burn and settlement drop supply and pending by `units`, pay
    /// LPVaultSwap the pool tokens, and keep the gap `totalSupply <= totalCredited + pending` unchanged.
    function test_TEST_152_settlementNeedsTheAdaptersExactBurn() public {
        bytes32 key = _newKey();
        address proxy = _pledgeKey(alice, key, UNITS);
        _borrowAs(alice, MARKET_ID, debtReserveId, 15_000e18);
        vtPrice.set(1.6e8);
        uint256 kept = swap.seizeAndKeep(aave.cdpSpoke, vt, vtReserveId, debtReserveId, proxy, 2000e18);
        vtPrice.set(2e8);
        _repayAll(alice, proxy);
        _withdrawAll(alice, key);
        assertEq(coll.getPending(vt).units, kept, "pending after the reconcile");

        // No burn: the supply check fails.
        bytes memory err =
            swap.callUnderLock(address(coll), abi.encodeCall(ICollateralizationSeizure.settlePending, (vt, kept)));
        assertEq(bytes4(err), ICollateralizationErrors.SupplyDropMismatch.selector, "settlement without the burn");
        // Burn callers and markets.
        vm.expectRevert(IAaveAdapterErrors.NotLPVaultSwap.selector);
        vm.prank(alice);
        adapterC.burnSeized(MARKET_ID, vt, kept);
        vm.expectRevert(IAaveAdapterErrors.NotLPVaultSwap.selector);
        swap.burnWithoutLock(MARKET_ID, vt, kept);
        vm.expectRevert(abi.encodeWithSelector(IAaveAdapterErrors.UnknownMarket.selector, MARKET_B));
        swap.burnUnderLock(MARKET_B, vt, kept);
        // More than pending.
        err = swap.callUnderLock(address(coll), abi.encodeCall(ICollateralizationSeizure.settlePending, (vt, kept + 1)));
        assertEq(bytes4(err), ICollateralizationErrors.PendingExceeded.selector, "above the pending balance");

        int256 gap0 = int256(coll.getTotalCredited(vt) + coll.getPending(vt).units) - int256(token.totalSupply());
        uint256 usdc0 = usdc.balanceOf(lpVaultSwap);
        swap.settlePending(MARKET_ID, vt, kept);
        assertEq(coll.getPending(vt).units, 0, "pending settled");
        assertEq(token.balanceOf(lpVaultSwap), 0, "the Adapter burned exactly the units");
        assertGt(usdc.balanceOf(lpVaultSwap), usdc0, "pool tokens paid to LPVaultSwap");
        assertEq(
            int256(coll.getTotalCredited(vt) + coll.getPending(vt).units) - int256(token.totalSupply()),
            gap0,
            "gap unchanged"
        );
        assertEq(IAaveV4Spoke(aave.cdpSpoke).getUserSuppliedShares(vtReserveId, proxy), 0, "account empty");
    }
}
