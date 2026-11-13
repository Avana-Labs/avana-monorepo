// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ICollateralizationDebtMark} from "../../src/custody/collateralization/ICollateralizationDebtMark.sol";
import {IAaveV4Spoke} from "../../src/interfaces/external/aave/IAaveV4Spoke.sol";
import {IAaveAdapterErrors} from "../../src/policy/aave-adapter/IAaveAdapterErrors.sol";
import {IAaveAdapterEvents} from "../../src/policy/aave-adapter/IAaveAdapterEvents.sol";
import {DebtReserveDef} from "../../src/policy/market-registry/types/DebtReserveDef.sol";
import {IRiskModuleChecks} from "../../src/policy/risk-module/IRiskModuleChecks.sol";
import {IRiskModuleErrors} from "../../src/policy/risk-module/IRiskModuleErrors.sol";
import {PauseReason} from "../../src/types/PauseReason.sol";
import {PauseState} from "../../src/types/PauseState.sol";
import {AaveAdapterFixture} from "../utils/fixtures/AaveAdapterFixture.sol";

/// @title AaveAdapterBorrowUnitTest
/// @notice `borrow` on the real Aave V4 Spoke: the order of its call bounds (deadline, amount, pause state of the
/// market's and the funding Hub, proxy, debt-reserve enablement, receiver rule, freeze, nonce), the RiskModule calls
/// around the proxy's Spoke call, the exact forwarding of the drawn asset and the single-use nonce.
/// forge-config: default.isolate = false
contract AaveAdapterBorrowUnitTest is AaveAdapterFixture {
    bytes32 internal aliceKey;

    function setUp() public override {
        super.setUp();
        (aliceKey, aliceProxy) = _pledgeAs(alice, MARKET_ID, UNITS);
    }

    function _borrow(
        uint256 reserveId,
        uint256 amount,
        address receiver,
        uint256 minHf,
        uint256 nonce
    ) internal returns (uint256) {
        uint256 d = _deadline();
        vm.prank(alice);
        return adapterC.borrow(MARKET_ID, reserveId, amount, receiver, d, minHf, nonce);
    }

    function _expectBorrowRevert(
        bytes memory err,
        uint256 reserveId,
        uint256 amount,
        address receiver,
        uint256 nonce
    ) internal {
        uint256 d = _deadline();
        vm.expectRevert(err);
        vm.prank(alice);
        adapterC.borrow(MARKET_ID, reserveId, amount, receiver, d, 0, nonce);
    }

    // ─── Happy paths ───

    // TEST-027 verifies: REQ-PROXY-015, REQ-PROXY-019, REQ-PROXY-021, REQ-PROXY-022, REQ-PROXY-023, REQ-PROXY-024, REQ-ADAPTER-008, SPEC-PROXY-004, INV-019, INV-020, INV-023
    // Sources: 5.1 TEST-027, FLOW-002
    /// @notice A GHO borrow consumes nonce 0, calls `preBorrowCheck` and `markIndebted` before the proxy's Spoke call
    /// and `postHealthCheck` after it, sends exactly the drawn amount to the receiver and emits `Borrowed` with the
    /// consumed nonce and the health factor the RiskModule returned.
    function test_TEST_027_borrowGho() public {
        uint256 amount = 5000e18;
        vm.expectCall(
            address(risk), abi.encodeCall(IRiskModuleChecks.preBorrowCheck, (aliceProxy, debtReserveId, amount))
        );
        vm.expectCall(address(coll), abi.encodeCall(ICollateralizationDebtMark.markIndebted, (aliceProxy)));
        vm.expectCall(address(risk), abi.encodeCall(IRiskModuleChecks.postHealthCheck, (aliceProxy, 1.5e18)));
        // $20,000 of collateral at CF 80% over $5,000 of GHO debt.
        uint256 hfExpected = uint256(16_000e18) * 1e18 / amount;
        vm.expectEmit(adapter);
        emit IAaveAdapterEvents.Borrowed(alice, MARKET_ID, debtReserveId, bob, amount, 0, hfExpected);
        uint256 drawn = _borrow(debtReserveId, amount, bob, 1.5e18, 0);
        assertEq(drawn, amount, "drawn");
        assertEq(debt.balanceOf(bob), amount, "receiver paid");
        assertEq(debt.balanceOf(aliceProxy), 0, "proxy keeps nothing");
        assertEq(debt.balanceOf(adapter), 0, "adapter keeps nothing");
        assertEq(adapterC.borrowNonce(aliceProxy), 1, "nonce consumed");
        assertEq(_debtOf(aliceProxy, debtReserveId), amount, "debt");
        assertEq(risk.preBorrowCalls(), 1, "one pre-check");
        assertEq(debt.allowance(aliceProxy, aave.cdpSpoke), 0, "no allowance");
    }

    // TEST-027 verifies: REQ-PROXY-015, REQ-PROXY-021, REQ-ADAPTER-067, SPEC-PROXY-004
    /// @notice The same path borrows USDC (6 decimals): 500 USDC land at the receiver and the proxy ends with none.
    function test_TEST_027_borrowUsdc() public {
        _borrow(usdcReserveId, 500e6, alice, 0, 0);
        assertEq(usdcDebt.balanceOf(alice), 500e6, "USDC at receiver");
        assertEq(usdcDebt.balanceOf(aliceProxy), 0, "proxy USDC");
        assertEq(_debtOf(aliceProxy, usdcReserveId), 500e6, "USDC debt");
    }

    // TEST-027 verifies: SPEC-PROXY-004, REQ-PROXY-013, ATTACK-076
    // Sources: 2.6 SPEC-PROXY-004 example
    /// @notice A proxy holding 0.37 USDC of donated dust borrows 5,000 USDC: the drawn amount is the balance delta,
    /// the receiver gets exactly 5,000 USDC and the proxy ends at its start value, 370,000 base units.
    function test_TEST_027_donatedDustIgnored() public {
        usdcDebt.mint(aliceProxy, 370_000);
        _borrow(usdcReserveId, 5_000_000_000, bob, 0, 0);
        assertEq(usdcDebt.balanceOf(bob), 5_000_000_000, "receiver");
        assertEq(usdcDebt.balanceOf(aliceProxy), 370_000, "dust kept, not forwarded");
    }

    // TEST-203 verifies: REQ-PROXY-018, SPEC-PROXY-006, REQ-ADAPTER-067
    /// @notice One account borrows GHO and USDC on one health factor; each borrow consumes the next nonce whatever
    /// the asset.
    function test_TEST_203_twoReservesOneAccount() public {
        _borrow(debtReserveId, 4000e18, alice, 0, 0);
        _borrow(usdcReserveId, 2000e6, alice, 0, 1);
        assertEq(adapterC.borrowNonce(aliceProxy), 2, "two nonces");
        assertEq(_borrowCountOf(aliceProxy), 2, "two borrowed reserves");
        // $16,000 CF-weighted collateral over 4,000 + 2,000 × 0.9999 of debt.
        uint256 debtValue = 4000e18 + 2000e18 * 99_990_000 / 1e8;
        assertApproxEqRel(_hf(aliceProxy), uint256(16_000e18) * 1e18 / debtValue, 1e12, "hf");
    }

    // TEST-278 verifies: REQ-PROXY-016, Q-381
    /// @notice There is no minimum borrow: one base unit of USDC borrows.
    function test_TEST_278_oneBaseUnitBorrow() public {
        _borrow(usdcReserveId, 1, alice, 0, 0);
        assertEq(usdcDebt.balanceOf(alice), 1, "1 base unit");
        assertGe(_debtOf(aliceProxy, usdcReserveId), 1, "debt at least the amount");
    }

    // ─── Order of call bounds ───

    // TEST-027 verifies: REQ-PROXY-015, REQ-PROXY-058, REQ-PROXY-060, REQ-PROXY-093, REQ-ADAPTER-052, REQ-ADAPTER-072, REQ-ADAPTER-073, REQ-PROXY-057, REQ-PROXY-062, REQ-PROXY-061, REQ-ADAPTER-087, REQ-PROXY-059
    /// @notice With every bound failing at once, the errors come one by one in the order of REQ-PROXY-015.
    function test_TEST_027_checkOrder() public {
        registry.setFrozen(alice, true);
        _pause(PauseState.Frozen, PauseReason.None);
        uint256 past = block.timestamp - 1;
        vm.expectRevert(abi.encodeWithSelector(IAaveAdapterErrors.DeadlineExpired.selector, past));
        vm.prank(alice);
        adapterC.borrow(MARKET_B, 99, 0, address(0), past, 0, 7);
        uint256 d = _deadline();
        vm.expectRevert(IAaveAdapterErrors.ZeroAmount.selector);
        vm.prank(alice);
        adapterC.borrow(MARKET_B, 99, 0, address(0), d, 0, 7);
        vm.expectRevert(IAaveAdapterErrors.ApplicationFrozen.selector);
        vm.prank(alice);
        adapterC.borrow(MARKET_B, 99, 1, address(0), d, 0, 7);
        _pause(PauseState.None, PauseReason.None);
        vm.expectRevert(abi.encodeWithSelector(IAaveAdapterErrors.NoProxy.selector, alice, MARKET_B));
        vm.prank(alice);
        adapterC.borrow(MARKET_B, 99, 1, address(0), d, 0, 7);
        vm.expectRevert(abi.encodeWithSelector(IAaveAdapterErrors.UnknownDebtReserve.selector, aave.cdpSpoke, 99));
        vm.prank(alice);
        adapterC.borrow(MARKET_ID, 99, 1, address(0), d, 0, 7);
        vm.expectRevert(abi.encodeWithSelector(IAaveAdapterErrors.InvalidReceiver.selector, address(0)));
        vm.prank(alice);
        adapterC.borrow(MARKET_ID, debtReserveId, 1, address(0), d, 0, 7);
        vm.expectRevert(abi.encodeWithSelector(IAaveAdapterErrors.AddressIsFrozen.selector, alice));
        vm.prank(alice);
        adapterC.borrow(MARKET_ID, debtReserveId, 1, bob, d, 0, 7);
        registry.setFrozen(alice, false);
        registry.setFrozen(bob, true);
        vm.expectRevert(abi.encodeWithSelector(IAaveAdapterErrors.AddressIsFrozen.selector, bob));
        vm.prank(alice);
        adapterC.borrow(MARKET_ID, debtReserveId, 1, bob, d, 0, 7);
        vm.expectRevert(abi.encodeWithSelector(IAaveAdapterErrors.BadNonce.selector, 0, 7));
        vm.prank(alice);
        adapterC.borrow(MARKET_ID, debtReserveId, 1, carol, d, 0, 7);
        assertEq(risk.preBorrowCalls(), 0, "no RiskModule call before the bounds pass");
    }

    // TEST-027 verifies: REQ-PROXY-058
    function test_TEST_027_deadlineInclusive() public {
        vm.prank(alice);
        adapterC.borrow(MARKET_ID, debtReserveId, 1e18, alice, block.timestamp, 0, 0);
        assertEq(debt.balanceOf(alice), 1e18, "borrowed at the deadline");
    }

    // ─── Pause state ───

    // TEST-192 verifies: REQ-ADAPTER-045, REQ-ADAPTER-046, REQ-ADAPTER-072, REQ-ADAPTER-073, REQ-ACCESS-080
    /// @notice Every borrow reverts under Frozen and under Paused with either reason.
    function test_TEST_192_borrowRefusedUnlessNone() public {
        _pause(PauseState.Frozen, PauseReason.None);
        _expectBorrowRevert(
            abi.encodeWithSelector(IAaveAdapterErrors.ApplicationFrozen.selector), debtReserveId, 1, alice, 0
        );
        _pause(PauseState.Paused, PauseReason.General);
        _expectBorrowRevert(
            abi.encodeWithSelector(IAaveAdapterErrors.ApplicationPaused.selector), debtReserveId, 1, alice, 0
        );
        _pause(PauseState.Paused, PauseReason.MintPathSuspect);
        _expectBorrowRevert(
            abi.encodeWithSelector(IAaveAdapterErrors.ApplicationPaused.selector), debtReserveId, 1, alice, 0
        );
        _pause(PauseState.None, PauseReason.None);
        _borrow(debtReserveId, 1, alice, 0, 0);
        assertEq(adapterC.borrowNonce(aliceProxy), 1, "None borrows");
    }

    // TEST-273 verifies: REQ-PROXY-015, REQ-ADAPTER-044, Q-378
    /// @notice A cross-Hub reserve also needs its funding Hub at None: a pause of the funding Hub alone refuses the
    /// borrow, and a pause of an unrelated Hub does not.
    function test_TEST_273_fundingHubPauseRefuses() public {
        address funding = makeAddr("fundingHub");
        DebtReserveDef memory def = _debtDef(debtReserveId, address(debt), 18, ghoAssetId);
        def.fundingHub = funding;
        def.crossHub = true;
        registry.setDebtReserve(aave.cdpSpoke, debtReserveId, def);
        registry.setPause(makeAddr("unrelated"), PauseState.Paused, PauseReason.General);
        registry.setPause(funding, PauseState.Frozen, PauseReason.None);
        _expectBorrowRevert(
            abi.encodeWithSelector(IAaveAdapterErrors.ApplicationFrozen.selector), debtReserveId, 1, alice, 0
        );
        registry.setPause(funding, PauseState.Paused, PauseReason.General);
        _expectBorrowRevert(
            abi.encodeWithSelector(IAaveAdapterErrors.ApplicationPaused.selector), debtReserveId, 1, alice, 0
        );
    }

    // ─── Debt reserve, receiver and freeze ───

    // TEST-030 verifies: REQ-ADAPTER-067, REQ-PROXY-009, REQ-PROXY-062, INV-073
    /// @notice A reserve the registry has not enabled for the Spoke (the vault-token reserve itself, a disabled GHO
    /// reserve) reverts `UnknownDebtReserve` before any RiskModule or proxy call.
    function test_TEST_030_unknownDebtReserve() public {
        _expectBorrowRevert(
            abi.encodeWithSelector(IAaveAdapterErrors.UnknownDebtReserve.selector, aave.cdpSpoke, vtReserveId),
            vtReserveId,
            1,
            alice,
            0
        );
        DebtReserveDef memory def = _debtDef(debtReserveId, address(debt), 18, ghoAssetId);
        def.approved = false;
        registry.setDebtReserve(aave.cdpSpoke, debtReserveId, def);
        _expectBorrowRevert(
            abi.encodeWithSelector(IAaveAdapterErrors.UnknownDebtReserve.selector, aave.cdpSpoke, debtReserveId),
            debtReserveId,
            1,
            alice,
            0
        );
        assertEq(risk.preBorrowCalls(), 0, "no pre-check");
    }

    // TEST-027 verifies: REQ-PROXY-017, REQ-PROXY-061, INV-020, ATTACK-106, Q-105, Q-312
    // Sources: 2.6 REQ-PROXY-017 list
    /// @notice Every receiver class of REQ-PROXY-017 reverts `InvalidReceiver` before any RiskModule or proxy call
    /// and leaves the nonce unchanged.
    function test_TEST_027_receiverRuleRefusesEveryClass() public {
        (, address bobProxy) = _pledgeAs(bob, MARKET_ID, UNITS);
        address[] memory refused = new address[](20);
        refused[0] = address(0);
        refused[1] = bobProxy;
        refused[2] = aliceProxy;
        refused[3] = adapter;
        refused[4] = address(coll);
        refused[5] = address(swap);
        refused[6] = timelock;
        refused[7] = address(registry);
        refused[8] = address(pstore);
        refused[9] = address(risk);
        refused[10] = address(proxyManager);
        refused[11] = address(lpVault);
        refused[12] = registry.payoutEscrow();
        refused[13] = registry.flashSourceAddr();
        refused[14] = aave.hub;
        refused[15] = aave.cdpSpoke;
        refused[16] = aave.lendSpoke;
        refused[17] = address(debt);
        refused[18] = vt;
        refused[19] = address(usdcDebt);
        for (uint256 i = 0; i < refused.length; ++i) {
            _expectBorrowRevert(
                abi.encodeWithSelector(IAaveAdapterErrors.InvalidReceiver.selector, refused[i]),
                debtReserveId,
                1e18,
                refused[i],
                0
            );
        }
        assertEq(risk.preBorrowCalls(), 0, "no pre-check");
        assertEq(adapterC.borrowNonce(aliceProxy), 0, "nonce unchanged");
        // The borrower's own wallet and an unrelated Safe are valid receivers.
        _borrow(debtReserveId, 1e18, alice, 0, 0);
        _borrow(debtReserveId, 1e18, makeAddr("safe"), 0, 1);
        assertEq(debt.balanceOf(makeAddr("safe")), 1e18, "safe paid");
    }

    // TEST-027 verifies: REQ-PROXY-017
    /// @notice A Spoke listed on the funding Hub for the borrowed asset (the Lend Spoke, a Coverage Spoke) is refused
    /// even when the registry does not know it as a CDP Spoke, and a token listed on that Hub likewise.
    function test_TEST_027_receiverListedOnFundingHub() public {
        _expectBorrowRevert(
            abi.encodeWithSelector(IAaveAdapterErrors.InvalidReceiver.selector, aave.lendSpoke),
            usdcReserveId,
            1e6,
            aave.lendSpoke,
            0
        );
        _expectBorrowRevert(
            abi.encodeWithSelector(IAaveAdapterErrors.InvalidReceiver.selector, vt), usdcReserveId, 1e6, vt, 0
        );
        _expectBorrowRevert(
            abi.encodeWithSelector(IAaveAdapterErrors.InvalidReceiver.selector, vtB), usdcReserveId, 1e6, vtB, 0
        );
    }

    // TEST-229 verifies: REQ-ADAPTER-082, REQ-ADAPTER-087, INV-024
    /// @notice A frozen caller cannot borrow and nobody can borrow to a frozen receiver.
    function test_TEST_229_frozenCallerOrReceiver() public {
        registry.setFrozen(alice, true);
        _expectBorrowRevert(
            abi.encodeWithSelector(IAaveAdapterErrors.AddressIsFrozen.selector, alice), debtReserveId, 1, bob, 0
        );
        registry.setFrozen(alice, false);
        registry.setFrozen(bob, true);
        _expectBorrowRevert(
            abi.encodeWithSelector(IAaveAdapterErrors.AddressIsFrozen.selector, bob), debtReserveId, 1, bob, 0
        );
    }

    // ─── Nonce ───

    // TEST-096 verifies: REQ-PROXY-015, REQ-PROXY-059, INV-019, ATTACK-036
    /// @notice Each nonce value admits one borrow: a replayed nonce reverts `BadNonce(current, expected)`, a skipped
    /// nonce too, and the stored nonce moves only on success.
    function test_TEST_096_nonceSingleUse() public {
        _borrow(debtReserveId, 1e18, alice, 0, 0);
        _expectBorrowRevert(
            abi.encodeWithSelector(IAaveAdapterErrors.BadNonce.selector, 1, 0), debtReserveId, 1e18, alice, 0
        );
        _expectBorrowRevert(
            abi.encodeWithSelector(IAaveAdapterErrors.BadNonce.selector, 1, 2), debtReserveId, 1e18, alice, 2
        );
        _borrow(usdcReserveId, 1e6, alice, 0, 1);
        assertEq(adapterC.borrowNonce(aliceProxy), 2, "nonce 2");
    }

    // TEST-027 verifies: REQ-PROXY-015, REQ-PROXY-022, REQ-PROXY-067, SPEC-PROXY-001, INV-019, INV-025
    /// @notice A borrow refused by the health check after the Spoke call undoes everything, the nonce, the debt and
    /// the transfer included.
    function test_TEST_027_lateRevertKeepsNonce() public {
        uint256 amount = 15_000e18; // hf = 16,000 / 15,000 = 1.0667 < 1.10
        uint256 d = _deadline();
        uint256 hf = uint256(16_000e18) * 1e18 / amount;
        vm.expectRevert(abi.encodeWithSelector(IRiskModuleErrors.HealthFactorTooLow.selector, hf, 1.1e18));
        vm.prank(alice);
        adapterC.borrow(MARKET_ID, debtReserveId, amount, alice, d, 1.1e18, 0);
        assertEq(adapterC.borrowNonce(aliceProxy), 0, "nonce unchanged");
        assertEq(_debtOf(aliceProxy, debtReserveId), 0, "no debt");
        assertEq(debt.balanceOf(alice), 0, "no transfer");
        // Without the caller's minimum the same borrow passes at Aave's 1.00.
        _borrow(debtReserveId, amount, alice, 0, 0);
        assertEq(adapterC.borrowNonce(aliceProxy), 1, "consumed");
    }

    // TEST-027 verifies: REQ-PROXY-077, REQ-PROXY-096
    /// @notice A borrow above Aave's own health-factor limit reverts in the Spoke and changes nothing.
    function test_TEST_027_aaveRefusesBelowOne() public {
        uint256 d = _deadline();
        vm.expectRevert();
        vm.prank(alice);
        adapterC.borrow(MARKET_ID, debtReserveId, 16_001e18, alice, d, 0, 0);
        assertEq(adapterC.borrowNonce(aliceProxy), 0, "nonce unchanged");
    }

    // TEST-028 verifies: REQ-PROXY-020, REQ-PROXY-066, REQ-ADAPTER-008
    /// @notice A RiskModule pre-check error propagates unchanged and the nonce increment is undone.
    function test_TEST_028_riskModuleErrorPropagates() public {
        risk.setRefuse(true);
        _expectBorrowRevert(
            abi.encodeWithSelector(IRiskModuleErrors.SequencerDown.selector), debtReserveId, 1, alice, 0
        );
        assertEq(adapterC.borrowNonce(aliceProxy), 0, "nonce unchanged");
    }

    // TEST-027 verifies: REQ-PROXY-021, REQ-PROXY-072, SPEC-PROXY-004
    /// @notice A Hub that delivers less than the debt it records (a transfer fee switched on for the asset) fails the
    /// balance-delta check: `UnitsMismatch(amount, drawn)`.
    function test_TEST_027_shortDeliveryReverts() public {
        debt.setFeeBps(100);
        _expectBorrowRevert(
            abi.encodeWithSelector(IAaveAdapterErrors.UnitsMismatch.selector, 1000e18, 990e18),
            debtReserveId,
            1000e18,
            alice,
            0
        );
    }

    // TEST-026 verifies: REQ-ADAPTER-066, REQ-PROXY-057, INV-063, ATTACK-010
    /// @notice A wallet borrows only on its own account: another wallet naming the market has no proxy there.
    function test_TEST_026_borrowOnlyOwnAccount() public {
        uint256 d = _deadline();
        vm.expectRevert(abi.encodeWithSelector(IAaveAdapterErrors.NoProxy.selector, attacker, MARKET_ID));
        vm.prank(attacker);
        adapterC.borrow(MARKET_ID, debtReserveId, 1e18, attacker, d, 0, 0);
        assertEq(_debtOf(aliceProxy, debtReserveId), 0, "alice untouched");
    }

    // TEST-027 verifies: REQ-PROXY-019, REQ-COLL-039
    /// @notice The borrow marks the account indebted in Collateralization for the market-closing count.
    function test_TEST_027_marksIndebted() public {
        assertTrue(coll.getMarketDebtFree(vt), "debt-free before");
        _borrow(debtReserveId, 1e18, alice, 0, 0);
        assertFalse(coll.getMarketDebtFree(vt), "market not debt-free");
    }

    // TEST-027 verifies: REQ-PROXY-023, REQ-ADAPTER-007
    /// @notice Nothing stays in the Adapter or the proxy after a borrow, and the proxy has no allowance.
    function test_TEST_027_nothingStays() public {
        _borrow(usdcReserveId, 1234e6, bob, 0, 0);
        assertEq(usdcDebt.balanceOf(adapter), 0, "adapter");
        assertEq(usdcDebt.balanceOf(aliceProxy), 0, "proxy");
        assertEq(usdcDebt.allowance(aliceProxy, aave.cdpSpoke), 0, "allowance");
        assertEq(IAaveV4Spoke(aave.cdpSpoke).getUserSuppliedShares(vtReserveId, aliceProxy), UNITS, "collateral");
    }
}
