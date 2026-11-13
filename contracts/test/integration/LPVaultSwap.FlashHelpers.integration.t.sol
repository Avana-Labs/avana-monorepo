// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {LiquidationParams} from "../../src/liquidation/lp-vault-swap/types/LiquidationParams.sol";
import {LiquidationResult} from "../../src/liquidation/lp-vault-swap/types/LiquidationResult.sol";
import {FlashLiquidator} from "../../src/periphery/flash-liquidator/FlashLiquidator.sol";
import {IFlashLiquidatorErrors} from "../../src/periphery/flash-liquidator/IFlashLiquidatorErrors.sol";
import {IFlashLiquidatorEvents} from "../../src/periphery/flash-liquidator/IFlashLiquidatorEvents.sol";
import {OperatorFlashLiquidator} from "../../src/periphery/flash-liquidator/OperatorFlashLiquidator.sol";
import {FlashLiquidationRequest} from "../../src/periphery/flash-liquidator/types/FlashLiquidationRequest.sol";
import {LPVaultSwapUnitBase} from "../unit/LPVaultSwap.Base.sol";
import {PayoutToken} from "../utils/mocks/PayoutToken.sol";
import {Vm} from "forge-std/Vm.sol";

/// @title LPVaultSwapFlashHelpersIntegrationTest
/// @notice The public and operator flash liquidation helpers (2.11 "Flash liquidation helper", REQ-HELPER-001 to
/// REQ-HELPER-015) against the real LPVaultSwap on the local Aave V4: the helper flash-borrows the debt asset from the
/// Aave V3 Pool stand-in, funds `liquidate` as an ordinary caller (LPVaultSwap sees the helper as `msg.sender`, takes
/// no loan of its own and runs every check), repays the Pool from `keeperOut`, pulls an inventory, a shortfall budget
/// or a top-up from its payer only, forwards residues and pays its caller only after the loan returns.
/// forge-config: default.isolate = false
contract LPVaultSwapFlashHelpersIntegrationTest is LPVaultSwapUnitBase, IFlashLiquidatorEvents {
    FlashLiquidator internal helper;
    OperatorFlashLiquidator internal opHelper;
    address internal signer = makeAddr("operatorSigner");
    address internal safe = makeAddr("operatorSafe");
    address internal proxy;

    function setUp() public override {
        super.setUp();
        helper = new FlashLiquidator(address(v3Pool), address(lvs), address(registry), address(store));
        opHelper = new OperatorFlashLiquidator(
            address(v3Pool), address(lvs), address(registry), address(store), signer, safe, 100
        );
        (proxy,) = _bobAccount();
    }

    function _request(
        uint256 x,
        uint256 f
    ) internal view returns (FlashLiquidationRequest memory q) {
        q.params = _params(proxy, x);
        q.flashAmount = f;
        q.maxPremium = type(uint128).max;
        q.maxTopUp = 0;
        q.minPayout = 0;
    }

    function _premium(
        uint256 f
    ) internal pure returns (uint256) {
        return (f * 5 + 5000) / 10_000;
    }

    /// @notice The public helper borrows `F = X = 1,950` USDC, LPVaultSwap settles with the helper as caller, the
    /// helper repays `F + φ` from `keeperOut` and pays its caller `keeperOut − F − φ`; neither the helper nor
    /// LPVaultSwap keeps a balance; LPVaultSwap called no flash source.
    // TEST-289 verifies: REQ-HELPER-004, REQ-HELPER-006, REQ-HELPER-007, REQ-HELPER-008, REQ-HELPER-010, REQ-SWAP-012, REQ-SWAP-014, REQ-SWAP-073, Q-404
    // TEST-267 verifies: REQ-HELPER-006, REQ-HELPER-007, REQ-HELPER-008, REQ-SWAP-012
    function test_TEST_289_publicHelperFundsLiquidate() public {
        Snap memory s0 = _snap(carol);
        uint256 phi = _premium(1950e6);
        uint256 loans = v3Pool.flashLoanCalls();
        vm.expectCall(address(flashSource), abi.encodeWithSignature("flashLoan(address,uint256,address,bytes)"), 0);
        vm.recordLogs();
        vm.prank(carol);
        uint256 payout = helper.flashLiquidate(_request(1950e6, 1950e6));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        (bool found, address settledCaller, uint256 keeperOut) = _settled(logs);
        assertTrue(found, "settled");
        assertEq(settledCaller, address(helper), "LPVaultSwap sees the helper as msg.sender");
        assertEq(payout, keeperOut - 1950e6 - phi, "payout = keeperOut - F - phi");
        assertEq(usdc.balanceOf(carol), s0.callerUsdc + payout, "caller paid");
        assertEq(usdc.balanceOf(address(helper)), 0, "helper keeps nothing");
        assertEq(v3Pool.flashLoanCalls(), loans + 1, "one Pool loan, the helper's");
        _assertNeutral(s0);
    }

    function _settled(
        Vm.Log[] memory logs
    ) internal pure returns (bool found, address caller, uint256 keeperOut) {
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].topics.length > 0 && logs[i].topics[0] == LiquidationSettled.selector) {
                found = true;
                caller = address(uint160(uint256(logs[i].topics[1])));
                bytes memory data = logs[i].data;
                // SettlementReport.keeperOut is field 14 of the tuple behind the offset word.
                assembly {
                    let base := add(add(data, 0x20), mload(add(data, 0x20)))
                    keeperOut := mload(add(base, mul(14, 0x20)))
                }
            }
        }
    }

    /// @notice A frozen address liquidates through the public helper: the freeze binds `msg.sender` only, and
    /// LPVaultSwap's caller is the helper (REQ-SWAP-105).
    // TEST-289 verifies: REQ-SWAP-105, REQ-HELPER-006, REQ-HELPER-010, Q-242, Q-404
    // TEST-229 verifies: REQ-SWAP-105, Q-404
    function test_TEST_289_frozenAddressThroughHelper() public {
        registry.setFrozen(attacker, true);
        vm.prank(attacker);
        uint256 payout = helper.flashLiquidate(_request(1950e6, 1950e6));
        assertGt(payout, 0, "settled through the helper");
        assertEq(usdc.balanceOf(attacker), payout, "paid");
    }

    /// @notice `F < X`: the helper pulls the inventory `X − F` from its caller and returns it in the payout; the Lens
    /// margin above the debt Aave pulls returns too.
    // TEST-289 verifies: REQ-HELPER-004, REQ-HELPER-008, SPEC-LIQ-017
    function test_TEST_289_inventoryReturnedInPayout() public {
        usdc.mint(carol, 97.5e6);
        vm.prank(carol);
        usdc.approve(address(helper), type(uint256).max);
        vm.prank(carol);
        uint256 payout = helper.flashLiquidate(_request(2_047_500_000, 1950e6));
        assertGt(payout, 97.5e6, "inventory and net reward returned");
        assertEq(usdc.balanceOf(address(helper)), 0, "helper keeps nothing");
    }

    /// @notice A floor shortfall through the helper: the helper prefunds `maxShortfall` from its caller, approves
    /// LPVaultSwap for `X + maxShortfall`, LPVaultSwap pulls exactly the gap, and the unused budget returns in the
    /// payout.
    // TEST-289 verifies: REQ-HELPER-004, REQ-HELPER-006, SPEC-LIQ-019
    // TEST-233 verifies: SPEC-LIQ-019, REQ-SWAP-101
    function test_TEST_233_shortfallThroughHelper() public {
        usdtUsdcPool.setRate(95, 100);
        usdtUsdcPool2.setRate(95, 100);
        FlashLiquidationRequest memory q = _request(1950e6, 1950e6);
        q.params.maxShortfall = 200e6;
        usdc.mint(carol, 200e6);
        vm.prank(carol);
        usdc.approve(address(helper), type(uint256).max);
        vm.recordLogs();
        vm.prank(carol);
        uint256 payout = helper.flashLiquidate(q);
        (,, uint256 keeperOut) = _settled(vm.getRecordedLogs());
        uint256 phi = _premium(1950e6);
        assertEq(payout, usdc.balanceOf(carol), "payout to the caller");
        assertGt(keeperOut, 1950e6 + phi, "covers the loan");
        assertEq(usdc.balanceOf(address(helper)), 0, "unused budget returned");
    }

    /// @notice A dust liquidation whose `keeperOut` is below `F + φ`: the helper pulls the top-up from its caller up to
    /// `maxTopUp`; with `maxTopUp = 0` the whole liquidation reverts `TopUpExceeded`.
    // TEST-289 verifies: REQ-HELPER-007, REQ-SWAP-081
    // TEST-267 verifies: REQ-HELPER-007
    function test_TEST_289_topUpBoundedByMaxTopUp() public {
        usdtUsdcPool.setRate(5, 10);
        FlashLiquidationRequest memory q = _request(3e6, 3e6);
        uint256 debt = _debtOf(proxy, usdcReserveId);
        vm.prank(carol);
        vm.expectRevert();
        helper.flashLiquidate(q);
        assertEq(_debtOf(proxy, usdcReserveId), debt, "nothing settled");
        q.maxTopUp = 1e6;
        usdc.mint(carol, 1e6);
        vm.prank(carol);
        usdc.approve(address(helper), type(uint256).max);
        vm.prank(carol);
        helper.flashLiquidate(q);
        assertLt(_debtOf(proxy, usdcReserveId), debt, "settled with a top-up");
        assertLt(usdc.balanceOf(carol), 1e6, "the top-up came from the caller");
    }

    /// @notice A residue LPVaultSwap pays the helper (a partial fill) is forwarded to the helper's caller after the
    /// loan returns.
    // TEST-289 verifies: REQ-HELPER-008, REQ-SWAP-024
    function test_TEST_289_residueForwardedToCaller() public {
        (, uint256 a1) = _released(975e6);
        usdtUsdcPool.setMaxIn(a1 - 11);
        vm.prank(carol);
        helper.flashLiquidate(_request(1950e6, 1950e6));
        assertEq(usdt.balanceOf(carol), 11, "residue forwarded");
        assertEq(usdt.balanceOf(address(helper)), 0, "helper keeps none");
    }

    /// @notice GHO debt through the public helper: the Pool lends GHO like any other asset.
    // TEST-289 verifies: REQ-HELPER-015, REQ-FLASH-010, REQ-SWAP-088, REQ-ACCESS-178
    function test_TEST_289_ghoDebtThroughPool() public {
        (address ghoProxy,) = _openAccount(alice, 10_000e6, 0, 250_000_000);
        lpOracle.setAnswer(250_000_000);
        adapter.borrow(ghoProxy, ghoReserveId, address(gho), 18_000e18, alice);
        lpOracle.setAnswer(int256(P_VAULT));
        FlashLiquidationRequest memory q;
        q.params = _params(ghoProxy, 1950e18);
        q.params.debtReserveId = ghoReserveId;
        q.flashAmount = 1950e18;
        q.maxPremium = type(uint128).max;
        uint256 supply = gho.totalSupply();
        vm.prank(carol);
        uint256 payout = helper.flashLiquidate(q);
        assertEq(gho.totalSupply(), supply, "no GHO minted to fund the liquidation");
        assertEq(gho.balanceOf(carol), payout, "paid in GHO");
        assertGt(payout, 0, "net reward");
    }

    /// @notice The operator variant: only its signer calls; `F = 0` takes no loan and the Safe funds `X`; the payout
    /// returns to the Safe; a loan above the need is refused after `liquidate` returns.
    // TEST-289 verifies: REQ-HELPER-011, REQ-HELPER-016
    // TEST-267 verifies: REQ-HELPER-011
    function test_TEST_289_operatorSignerSafeAndNoLoan() public {
        vm.prank(carol);
        vm.expectRevert(IFlashLiquidatorErrors.NotSigner.selector);
        opHelper.flashLiquidate(_request(1950e6, 1950e6));
        usdc.mint(safe, 1950e6);
        vm.prank(safe);
        usdc.approve(address(opHelper), type(uint256).max);
        uint256 loans = v3Pool.flashLoanCalls();
        vm.prank(signer);
        uint256 payout = opHelper.flashLiquidate(_request(1950e6, 0));
        assertEq(v3Pool.flashLoanCalls(), loans, "no loan with F = 0");
        assertEq(usdc.balanceOf(safe), payout, "payout to the Safe");
        assertGt(payout, 1950e6, "funding back plus the reward");
        // A loan far above the debt this call repays is refused (REQ-HELPER-011).
        (proxy,) = _openAccount(dave(), 10_000e6, 18_000e6, 250_000_000);
        FlashLiquidationRequest memory big = _request(1_000_000e6, 900_000e6);
        usdc.mint(safe, 100_000e6);
        vm.prank(signer);
        (bool ok, bytes memory ret) = address(opHelper).call(abi.encodeCall(opHelper.flashLiquidate, (big)));
        assertFalse(ok, "refused");
        assertEq(bytes4(ret), IFlashLiquidatorErrors.FlashAmountAboveNeed.selector, "FlashAmountAboveNeed");
    }

    function dave() internal returns (address) {
        return makeAddr("dave");
    }

    /// @notice A residue the token refuses to deliver to the public helper is credited to the helper in the escrow and
    /// claimed to its caller in the same call (REQ-HELPER-010).
    // TEST-289 verifies: REQ-HELPER-010, REQ-SWAP-076
    function test_TEST_289_helperEscrowClaimedToItsCaller() public {
        (, uint256 a1) = _released(975e6);
        usdtUsdcPool.setMaxIn(a1 - 13);
        usdt.setBlocked(address(helper), true);
        uint256 before = usdt.balanceOf(carol);
        vm.prank(carol);
        helper.flashLiquidate(_request(1950e6, 1950e6));
        assertEq(escrow.claimable(address(usdt), address(helper)), 0, "claimed in the call");
        assertEq(usdt.balanceOf(carol), before + 13, "the caller's residue");
    }

    /// @notice When the caller cannot receive it either, the credit stays with the helper and anyone then claims it to
    /// `feeRecipient` (REQ-HELPER-010).
    // TEST-289 verifies: REQ-HELPER-010, REQ-SWAP-076
    function test_TEST_289_helperEscrowClaimedToFeeRecipient() public {
        (, uint256 a1) = _released(975e6);
        usdtUsdcPool.setMaxIn(a1 - 13);
        usdt.setBlocked(address(helper), true);
        usdt.setBlocked(carol, true);
        vm.prank(carol);
        helper.flashLiquidate(_request(1950e6, 1950e6));
        assertEq(escrow.claimable(address(usdt), address(helper)), 13, "credited to the helper");
        usdt.setBlocked(address(helper), false);
        uint256 before = usdt.balanceOf(feeRecipient);
        helper.claimEscrowed(address(usdt));
        assertEq(usdt.balanceOf(feeRecipient), before + 13, "claimed to feeRecipient");
    }

    /// @notice Debt-reserve sizing against the public helper's liquidity: the largest single liquidation the account
    /// allows (its whole USDC debt) fits within half of `maxFlashLoan(USDC)` and settles through the helper; once the
    /// Pool's idle USDC falls below that size (the monitoring alert's condition is below twice it) the helper refuses
    /// before LPVaultSwap is called, and a committed operator settles the same liquidation from its own inventory.
    // TEST-289 verifies: REQ-FLASH-008, REQ-SWAP-014, REQ-HELPER-015
    function test_REQ_FLASH_008_largestLiquidationWithinHalfThePool() public {
        uint256 largest = _debtOf(proxy, usdcReserveId);
        assertLe(2 * largest, helper.maxFlashLoan(address(usdc)), "sized within half of the Pool's idle USDC");
        uint256 snapshot = vm.snapshotState();
        vm.prank(carol);
        uint256 payout = helper.flashLiquidate(_request(largest, largest));
        assertGt(payout, 0, "the largest liquidation settles through the helper");
        vm.revertToState(snapshot);
        v3Pool.setVirtualBalance(address(usdc), uint128(largest - 1));
        assertLt(helper.maxFlashLoan(address(usdc)), 2 * largest, "below twice the size: the alert condition");
        uint256 calls = adapter.burnCalls();
        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(IFlashLiquidatorErrors.InsufficientFlashLiquidity.selector, largest - 1));
        helper.flashLiquidate(_request(largest, largest));
        assertEq(adapter.burnCalls(), calls, "LPVaultSwap never called");
        LiquidationResult memory r = _liquidateAs(keeper, _params(proxy, largest));
        assertGt(r.unitsSeized, 0, "inventory covers the gap");
    }

    /// @notice The helper's quotes are the Pool's: 5 bps ceiling without `FLASH_BORROWER`, 0 with it; LPVaultSwap's
    /// `liquidate` never reads them.
    // TEST-289 verifies: REQ-HELPER-009, REQ-FLASH-007
    function test_TEST_289_helperQuotes() public {
        assertEq(helper.flashPremium(address(usdc), 1950e6), 975_000, "ceil 5 bps");
        acl.addFlashBorrower(address(helper));
        assertEq(helper.flashPremium(address(usdc), 1950e6), 0, "FLASH_BORROWER");
        vm.prank(carol);
        uint256 payout = helper.flashLiquidate(_request(1950e6, 1950e6));
        assertGt(payout, 0, "settled with no premium");
        assertEq(helper.maxFlashLoan(address(usdc)), 18_000_000e6, "idle liquidity");
        assertEq(address(helper.LP_VAULT_SWAP()), address(lvs), "binds the real LPVaultSwap");
        PayoutToken token = usdc;
        token;
    }
}
