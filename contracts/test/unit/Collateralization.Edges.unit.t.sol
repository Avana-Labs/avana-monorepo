// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAmmIntegration} from "../../src/amm/IAmmIntegration.sol";
import {ICollateralizationErrors} from "../../src/custody/collateralization/ICollateralizationErrors.sol";
import {Pending} from "../../src/custody/collateralization/types/Pending.sol";
import {IAaveV4Spoke} from "../../src/interfaces/external/aave/IAaveV4Spoke.sol";
import {CollateralizationFixture} from "../utils/fixtures/CollateralizationFixture.sol";
import {CollPoolToken} from "../utils/mocks/CollateralizationMocks.sol";

/// @title CollateralizationEdgesUnitTest
/// @notice Edge outcomes of the ledger checks: a reconcile whose unwind delivers more than the LPVault removed books
/// only the removed amount, a seizure settlement after the vault token's supply rose reports a supply drop of 0, and a
/// pledge the LPVault credits with 0 units is refused.
/// forge-config: default.isolate = false
contract CollateralizationEdgesUnitTest is CollateralizationFixture {
    bytes32 internal constant KEY42 = bytes32(uint256(42));
    bytes32 internal constant KEY7 = bytes32(uint256(7));

    function setUp() public {
        _deployCollateralization();
    }

    // TEST-151 verifies: REQ-VAULT-135, SPEC-BACK-015
    /// @notice Alice's 9,000,000,000 credited units lose `c` to a kept seizure. On her withdrawal the reconcile unwinds
    /// `c` units of NFT 42 to Collateralization: the LPVault removes `0.8 * c` raw USDC, and the USDC transfer also
    /// lands 777 extra raw USDC (a token that pays a bonus on receipt). The pending balance books
    /// `min(received, removed) = 0.8 * c`, not the `0.8 * c + 777` received; the extra 777 stays unbooked.
    function test_TEST_151_reconcileBooksAtMostTheRemovedAmount() public {
        _underwater();
        uint256 c = _seizeAndKeep(aliceProxy, 2400e18);
        assertGt(c, 0, "a seizure was kept");
        usdc.armHook(address(usdc), abi.encodeCall(CollPoolToken.mint, (address(coll), 777)));
        _withdrawAfterRepay(c);
        assertTrue(usdc.hookFired() && usdc.hookSucceeded(), "the bonus landed during the unwind");
        uint256 removedUsdc = c * 800_000 / 1e6;
        uint256 removedUsdt = c * 1_250_000 / 1e6;
        Pending memory p = coll.getPending(vt);
        assertEq(p.units, c, "the shortfall moved into pending units");
        assertEq(p.amounts[0], removedUsdc, "booked at the removed amount, not the received one");
        assertEq(p.amounts[1], removedUsdt, "received equals removed for USDT");
        assertEq(usdc.balanceOf(address(coll)), removedUsdc + 777, "the bonus is held but not booked");
        assertEq(usdt.balanceOf(address(coll)), removedUsdt);
    }

    // TEST-208 verifies: REQ-VAULT-050, REQ-VAULT-051, SPEC-BACK-007
    /// @notice After a liquidation seized `s` units from alice and before any burn, the AaveAdapter mints 1 vault-token
    /// unit, so the supply is 1 above the snapshot's. The settlement of `s` units reverts `SupplyDropMismatch(s, 0)`:
    /// a supply that rose counts as a drop of 0, never as an underflow; the record keeps its credit.
    function test_TEST_208_supplyAboveTheSnapshotIsADropOfZero() public {
        _underwater();
        vm.prank(lpVaultSwap);
        lock.acquire();
        vm.prank(lpVaultSwap);
        coll.beginSeizure(aliceProxy, vt);
        uint256 supply0 = token.totalSupply();
        uint256 seized = _seizeAndKeep(aliceProxy, 2400e18);
        assertGt(seized, 0, "the liquidation seized units");
        vm.prank(adapter);
        token.mint(aliceProxy, 1);
        assertEq(token.totalSupply(), supply0 + 1, "supply above the snapshot");
        vm.expectRevert(abi.encodeWithSelector(ICollateralizationErrors.SupplyDropMismatch.selector, seized, 0));
        vm.prank(lpVaultSwap);
        coll.settleSeizure(aliceProxy, vt, seized, new uint256[](2));
        vm.prank(lpVaultSwap);
        lock.release();
        assertEq(coll.getAccountCredited(aliceProxy, vt), 9_000_000_000, "nothing debited");
        assertEq(_record(KEY42).credited, 5_000_000_000);
    }

    // TEST-011 verifies: REQ-VAULT-012, REQ-VAULT-107, SPEC-BACK-002
    /// @notice An LPVault that takes NFT 42 into custody but reports 0 credited units for it: the pledge reverts
    /// `ZeroUnits` from Collateralization's own check, so no record, credit or record ID is written.
    function test_TEST_011_zeroCreditedUnitsRefused() public {
        lpVault.mintPosition(KEY42, alice, MARKET_ID, 5_000_000_000);
        vm.startPrank(adapter);
        lock.acquire();
        token.addValidProxy(aliceProxy);
        vm.mockCall(
            address(lpVault),
            abi.encodeWithSelector(IAmmIntegration.receivePosition.selector, MARKET_ID, alice, KEY42),
            abi.encode(uint128(0))
        );
        vm.expectRevert(ICollateralizationErrors.ZeroUnits.selector);
        coll.pledge(alice, aliceProxy, vt, KEY42, false);
        lock.release();
        vm.stopPrank();
        vm.clearMockedCalls();
        assertEq(coll.recordIdOf(INTEGRATION, KEY42), 0, "no record");
        assertEq(coll.nextRecordId(), 1, "no record ID used");
        assertEq(coll.getAccountCredited(aliceProxy, vt), 0, "no credit");
    }

    // ─── Helpers ───

    /// @notice Alice pledges NFT 42 (5,000,000,000 units) and NFT 7 (4,000,000,000), borrows 13,000 and the vault
    /// token falls to $1.60.
    function _underwater() internal {
        _pledge(alice, aliceProxy, KEY42, 5_000_000_000);
        _pledge(alice, aliceProxy, KEY7, 4_000_000_000);
        _borrow(aliceProxy, 13_000e18);
        vtPrice.set(1.6e8);
    }

    /// @notice Alice repays, then withdraws NFT 42 at its post-reconcile units, which moves the kept seizure `c` into
    /// the pending balance.
    function _withdrawAfterRepay(
        uint256 c
    ) internal {
        vtPrice.set(2e8);
        debt.mint(aliceProxy, 13_000e18);
        vm.startPrank(aliceProxy);
        debt.approve(aave.cdpSpoke, type(uint256).max);
        IAaveV4Spoke(aave.cdpSpoke).repay(debtReserveId, type(uint256).max, aliceProxy);
        vm.stopPrank();
        _withdraw(aliceProxy, KEY42, 5_000_000_000 - c);
    }
}
