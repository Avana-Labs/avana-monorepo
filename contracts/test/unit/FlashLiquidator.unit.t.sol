// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ILPVaultSwapErrors} from "../../src/liquidation/lp-vault-swap/ILPVaultSwapErrors.sol";
import {LiquidationParams} from "../../src/liquidation/lp-vault-swap/types/LiquidationParams.sol";
import {FlashLiquidator} from "../../src/periphery/flash-liquidator/FlashLiquidator.sol";
import {IFlashLiquidator} from "../../src/periphery/flash-liquidator/IFlashLiquidator.sol";
import {IFlashLiquidatorErrors} from "../../src/periphery/flash-liquidator/IFlashLiquidatorErrors.sol";
import {IFlashLiquidatorEvents} from "../../src/periphery/flash-liquidator/IFlashLiquidatorEvents.sol";
import {IOperatorFlashLiquidator} from "../../src/periphery/flash-liquidator/IOperatorFlashLiquidator.sol";
import {OperatorFlashLiquidator} from "../../src/periphery/flash-liquidator/OperatorFlashLiquidator.sol";
import {FlashLiquidationRequest} from "../../src/periphery/flash-liquidator/types/FlashLiquidationRequest.sol";
import {FlashLiquidatorFixture} from "../utils/fixtures/FlashLiquidatorFixture.sol";
import {PayoutToken} from "../utils/mocks/PayoutToken.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {Vm, VmSafe} from "forge-std/Vm.sol";

/// @notice The public flash liquidation helper (2.11 Flash liquidation helper) against a mocked Aave V3.4 Pool, the
/// real ParameterStore, Lock and PayoutEscrow, and a mocked LPVaultSwap: the 2.11 example, the request checks and
/// their order, the pre-loan and in-callback premium bounds, the quotes, the measured `keeperOut`, the bounded top-up,
/// the net payout and residues, the end state, the caller binding, the Hub rule, transfer fees and blocklists.
/// @dev Calls of one test share a transaction (`isolate = false`), so the transient context carries between them and
/// the tests show it is cleared.
/// forge-config: default.isolate = false
contract FlashLiquidatorUnitTest is FlashLiquidatorFixture {
    uint256 internal constant EXAMPLE_PREMIUM = 975_000;
    uint256 internal constant EXAMPLE_KEEPER_OUT = 2020.8e6;
    uint256 internal constant EXAMPLE_PAYOUT = 69.825e6;

    function setUp() public {
        _deployHelpers();
    }

    function _liquidate(
        FlashLiquidationRequest memory request
    ) internal returns (uint256) {
        vm.prank(caller);
        return helper.flashLiquidate(request);
    }

    function _assertClean(
        address who
    ) internal view {
        assertEq(usdcToken.balanceOf(who), 0, "helper holds USDC");
        assertEq(usdtToken.balanceOf(who), 0, "helper holds USDT");
        assertEq(usdcToken.allowance(who, address(aavePool)), 0, "Pool allowance left");
        assertEq(usdcToken.allowance(who, address(lvs)), 0, "LPVaultSwap allowance left");
    }

    // ─── Deployment and surface (REQ-HELPER-001, REQ-HELPER-002) ───

    // TEST-288 verifies: REQ-HELPER-001, REQ-HELPER-002, REQ-HELPER-011, Q-358, Q-404
    // Sources: 5.1 TEST-288
    function test_TEST_288_constructorFixesImmutablesAndRefusesZero() public {
        assertEq(helper.POOL(), address(aavePool));
        assertEq(helper.LP_VAULT_SWAP(), address(lvs));
        assertEq(helper.MARKET_REGISTRY(), address(registry));
        assertEq(helper.PARAMETER_STORE(), address(store));
        assertEq(opHelper.SIGNER(), signer);
        assertEq(opHelper.FUNDING_SAFE(), safe);
        assertEq(opHelper.MAX_TOP_UP_BPS(), OPERATOR_TOP_UP_BPS);
        address[4] memory core = [address(aavePool), address(lvs), address(registry), address(store)];
        for (uint256 i = 0; i < 4; ++i) {
            // A fresh copy: `address[4] memory args = core` would alias `core` and zero it for the checks below.
            address[4] memory args = [core[0], core[1], core[2], core[3]];
            args[i] = address(0);
            vm.expectRevert(IFlashLiquidatorErrors.ZeroAddress.selector);
            this.deployHelper(args[0], args[1], args[2], args[3]);
            vm.expectRevert(IFlashLiquidatorErrors.ZeroAddress.selector);
            this.deployOperatorHelper(args, signer, safe, 100);
        }
        vm.expectRevert(IFlashLiquidatorErrors.ZeroAddress.selector);
        this.deployOperatorHelper(core, address(0), safe, 100);
        vm.expectRevert(IFlashLiquidatorErrors.ZeroAddress.selector);
        this.deployOperatorHelper(core, signer, address(0), 100);
        vm.expectRevert(abi.encodeWithSelector(IFlashLiquidatorErrors.InvalidTopUpBps.selector, 10_001));
        this.deployOperatorHelper(core, signer, safe, 10_001);
        OperatorFlashLiquidator full = this.deployOperatorHelper(core, signer, safe, 10_000);
        assertEq(full.MAX_TOP_UP_BPS(), 10_000);
    }

    /// @notice A zero LPVaultSwap or ParameterStore is refused once the Pool and the MarketRegistry pass.
    // TEST-288 verifies: REQ-HELPER-001
    function test_TEST_288_constructorRefusesZeroLpVaultSwap() public {
        vm.expectRevert(IFlashLiquidatorErrors.ZeroAddress.selector);
        this.deployHelper(address(aavePool), address(0), address(registry), address(store));
    }

    // TEST-288 verifies: REQ-HELPER-001
    function test_TEST_288_constructorRefusesZeroParameterStore() public {
        vm.expectRevert(IFlashLiquidatorErrors.ZeroAddress.selector);
        this.deployHelper(address(aavePool), address(lvs), address(registry), address(0));
    }

    /// @notice No delegatecall, callcode, selfdestruct or create in either variant's runtime code.
    // TEST-288 verifies: REQ-HELPER-001, REQ-HELPER-012
    function test_TEST_288_noDelegatecallSelfdestructOrCreate() public view {
        _assertNoForbiddenOpcode(address(helper).code);
        _assertNoForbiddenOpcode(address(opHelper).code);
    }

    /// @notice The public helper answers only its nine selectors: no owner, role, setter, sweep, rescue, arbitrary
    /// call, fallback or `receive`.
    // TEST-288 verifies: REQ-HELPER-001, REQ-HELPER-010
    function testFuzz_TEST_288_publicHelperOnlyInterfaceSelectors(
        bytes4 selector,
        bytes calldata tail
    ) public {
        vm.assume(!_isPublicSelector(selector));
        (bool ok,) = address(helper).call(abi.encodePacked(selector, tail));
        assertFalse(ok, "unknown selector accepted");
        vm.deal(address(this), 1 ether);
        (ok,) = address(helper).call{value: 1}("");
        assertFalse(ok, "ETH accepted");
    }

    /// @notice The operator variant adds only `SIGNER`, `FUNDING_SAFE` and `MAX_TOP_UP_BPS`.
    // TEST-288 verifies: REQ-HELPER-001, REQ-HELPER-011
    function testFuzz_TEST_288_operatorHelperOnlyInterfaceSelectors(
        bytes4 selector,
        bytes calldata tail
    ) public {
        vm.assume(
            !_isPublicSelector(selector) && selector != IOperatorFlashLiquidator.SIGNER.selector
                && selector != IOperatorFlashLiquidator.FUNDING_SAFE.selector
                && selector != IOperatorFlashLiquidator.MAX_TOP_UP_BPS.selector
        );
        (bool ok,) = address(opHelper).call(abi.encodePacked(selector, tail));
        assertFalse(ok, "unknown selector accepted");
    }

    // ─── The 2.11 example (3.5 LIQ-069) ───

    // TEST-174 verifies: REQ-HELPER-004, REQ-HELPER-006, REQ-HELPER-007, REQ-HELPER-008, REQ-HELPER-010, REQ-SWAP-012, LIQ-069, Q-404
    // TEST-288 verifies: REQ-HELPER-001
    // Sources: 2.11 REQ-HELPER-008 example, 3.5 LIQ-069, FLOW-005
    function test_TEST_174_helperExampleLiq069() public {
        assertEq(helper.maxFlashLoan(address(usdcToken)), IDLE_USDC);
        assertEq(helper.flashPremium(address(usdcToken), 1950e6), EXAMPLE_PREMIUM);
        vm.expectEmit(true, true, true, true, address(helper));
        emit IFlashLiquidatorEvents.FlashLiquidated(
            caller, caller, address(usdcToken), 1950e6, EXAMPLE_PREMIUM, EXAMPLE_KEEPER_OUT, 0, EXAMPLE_PAYOUT
        );
        uint256 payout = _liquidate(_exampleRequest());
        assertEq(payout, EXAMPLE_PAYOUT, "69.825 USDC");
        assertEq(usdcToken.balanceOf(caller), EXAMPLE_PAYOUT);
        assertEq(usdcToken.balanceOf(aUsdc), IDLE_USDC + EXAMPLE_PREMIUM, "Pool repaid 1,950.975 USDC");
        assertEq(usdcToken.balanceOf(treasury), A_EXAMPLE, "Avana fee 19.5 USDC");
        assertEq(lvs.lastCaller(), address(helper), "LPVaultSwap sees the helper");
        assertEq(lvs.lastKf(), 1950e6);
        assertEq(lvs.lastKeeperOut(), EXAMPLE_KEEPER_OUT);
        assertEq(aavePool.flashLoanCalls(), 1);
        _assertClean(address(helper));
    }

    /// @notice With `FLASH_BORROWER` the premium is 0, quoted and charged, and the payout keeps it.
    // TEST-052 verifies: REQ-HELPER-005, REQ-HELPER-009, SPEC-LIQ-015
    function test_TEST_052_helperFlashBorrowerPaysNoPremium() public {
        acl.addFlashBorrower(address(helper));
        assertEq(helper.flashPremium(address(usdcToken), 1950e6), 0);
        uint256 payout = _liquidate(_request(1950e6, 1950e6, 0, 0, 70.8e6));
        assertEq(payout, 70.8e6);
        _setCap(0);
        _liquidate(_request(1950e6, 1950e6, 0, 0, 70.8e6));
        assertEq(usdcToken.balanceOf(caller), 141.6e6, "zero premium passes a zero cap");
    }

    // ─── Request checks (REQ-HELPER-003, REQ-HELPER-013) ───

    // TEST-174 verifies: REQ-HELPER-003, REQ-HELPER-013
    function test_TEST_174_helperRequestChecksFlashAmount() public {
        vm.expectRevert(IFlashLiquidatorErrors.InvalidFlashAmount.selector);
        _liquidate(_request(1950e6, 0, EXAMPLE_PREMIUM, 0, 0));
        vm.expectRevert(IFlashLiquidatorErrors.InvalidFlashAmount.selector);
        _liquidate(_request(1950e6, 1950e6 + 1, EXAMPLE_PREMIUM, 0, 0));
        assertEq(aavePool.flashLoanCalls(), 0);
        assertEq(lvs.calls(), 0);
    }

    // TEST-052 verifies: REQ-HELPER-003, REQ-HELPER-009, INV-095
    function test_TEST_052_helperLiquidityBelowAmountRefused() public {
        aavePool.setVirtualBalance(address(usdcToken), 1000e6);
        vm.expectRevert(abi.encodeWithSelector(IFlashLiquidatorErrors.InsufficientFlashLiquidity.selector, 1000e6));
        _liquidate(_exampleRequest());
        aavePool.setFlags(address(usdcToken), true, false, true, true);
        vm.expectRevert(abi.encodeWithSelector(IFlashLiquidatorErrors.InsufficientFlashLiquidity.selector, 0));
        _liquidate(_exampleRequest());
        assertEq(aavePool.flashLoanCalls(), 0);
        assertEq(lvs.calls(), 0);
    }

    /// @notice An unknown debt reserve reads asset 0, which the Pool lends nothing of: the call fails closed.
    // TEST-174 verifies: REQ-HELPER-003, REQ-HELPER-013
    function test_TEST_174_helperUnknownDebtReserveFailsClosed() public {
        FlashLiquidationRequest memory request = _exampleRequest();
        request.params.debtReserveId = 99;
        vm.expectRevert(abi.encodeWithSelector(IFlashLiquidatorErrors.InsufficientFlashLiquidity.selector, 0));
        _liquidate(request);
    }

    /// @notice Order: the flash amount before the Hub check, the Hub check before liquidity, liquidity before the
    /// premium quote.
    // TEST-174 verifies: REQ-HELPER-002, REQ-HELPER-003, REQ-HELPER-013
    function test_TEST_174_helperRequestCheckOrder() public {
        registry.setHub(address(aavePool), true);
        aavePool.setVirtualBalance(address(usdcToken), 0);
        _setCap(0);
        vm.expectRevert(IFlashLiquidatorErrors.InvalidFlashAmount.selector);
        _liquidate(_request(1950e6, 0, 0, 0, 0));
        vm.expectRevert(IFlashLiquidatorErrors.FlashSourceIsHub.selector);
        _liquidate(_exampleRequest());
        registry.setHub(address(aavePool), false);
        vm.expectRevert(abi.encodeWithSelector(IFlashLiquidatorErrors.InsufficientFlashLiquidity.selector, 0));
        _liquidate(_exampleRequest());
        aavePool.setVirtualBalance(address(usdcToken), uint128(IDLE_USDC));
        vm.expectRevert(abi.encodeWithSelector(IFlashLiquidatorErrors.FlashFeeTooHigh.selector, EXAMPLE_PREMIUM, 0));
        _liquidate(_exampleRequest());
    }

    // ─── Premium bounds (REQ-HELPER-005, SPEC-LIQ-015) ───

    /// @notice `maxFlashFeeBps = 4` below the Pool's 5 bps: the ceiling quote fails before `flashLoan` is called.
    // TEST-052 verifies: REQ-HELPER-005, SPEC-LIQ-015, INV-095
    // Sources: 5.1 TEST-267 (cap 4 reverts before flashLoan), MATH-ST-23
    function test_TEST_052_helperQuoteAboveCapRefusedBeforeLoan() public {
        _setCap(4);
        vm.expectRevert(
            abi.encodeWithSelector(IFlashLiquidatorErrors.FlashFeeTooHigh.selector, EXAMPLE_PREMIUM, 780_000)
        );
        _liquidate(_exampleRequest());
        assertEq(aavePool.flashLoanCalls(), 0, "no loan");
        assertEq(lvs.calls(), 0);
    }

    // TEST-052 verifies: REQ-HELPER-005, Q-135
    function test_TEST_052_helperPremiumAboveMaxPremiumRefused() public {
        vm.expectRevert(
            abi.encodeWithSelector(IFlashLiquidatorErrors.PremiumTooHigh.selector, EXAMPLE_PREMIUM, EXAMPLE_PREMIUM - 1)
        );
        _liquidate(_request(1950e6, 1950e6, EXAMPLE_PREMIUM - 1, 0, 0));
        assertEq(lvs.calls(), 0, "refused before liquidate");
    }

    /// @notice A Pool that raises its premium after the quote: the charged premium is re-checked against the cap.
    // TEST-052 verifies: REQ-HELPER-005, SPEC-LIQ-015, Q-135
    function test_TEST_052_helperChargedPremiumAboveCapRefused() public {
        aavePool.setPremiumOverride(1_950_001);
        vm.expectRevert(abi.encodeWithSelector(IFlashLiquidatorErrors.FlashFeeTooHigh.selector, 1_950_001, 1_950_000));
        _liquidate(_request(1950e6, 1950e6, type(uint256).max, 0, 0));
        aavePool.setPremiumOverride(1_950_000);
        _liquidate(_request(1950e6, 1950e6, type(uint256).max, 0, 0));
        assertEq(usdcToken.balanceOf(caller), EXAMPLE_KEEPER_OUT - 1950e6 - 1_950_000, "cap is inclusive");
    }

    /// @notice The exact bound of 5.1 TEST-052: `F = 1,950,000,500`, `φ = 1,950,001` is refused at the 10 bps cap.
    // TEST-052 verifies: REQ-HELPER-005, SPEC-LIQ-015
    // Sources: 5.1 TEST-052 example
    function test_TEST_052_helperExactBoundNoRounding() public {
        aavePool.setPremiumOverride(1_950_001);
        uint256 f = 1_950_000_500;
        vm.expectRevert(abi.encodeWithSelector(IFlashLiquidatorErrors.FlashFeeTooHigh.selector, 1_950_001, 1_950_000));
        _liquidate(_request(f, f, type(uint256).max, 0, 0));
    }

    /// @notice Quotes: 0 for an inactive, paused or flash-disabled reserve or one with no aToken; `min(aToken
    /// balance, virtual balance)` otherwise; the ceiling premium without `FLASH_BORROWER`.
    // TEST-052 verifies: REQ-HELPER-009
    function test_TEST_052_helperQuotes() public {
        address u = address(usdcToken);
        assertEq(helper.maxFlashLoan(u), IDLE_USDC);
        aavePool.setVirtualBalance(u, 5e6);
        assertEq(helper.maxFlashLoan(u), 5e6, "virtual balance binds");
        usdcToken.mint(aUsdc, 1);
        aavePool.setVirtualBalance(u, uint128(IDLE_USDC + 10));
        assertEq(helper.maxFlashLoan(u), IDLE_USDC + 1, "aToken balance binds");
        aavePool.setFlags(u, false, false, false, true);
        assertEq(helper.maxFlashLoan(u), 0, "inactive");
        aavePool.setFlags(u, true, false, true, true);
        assertEq(helper.maxFlashLoan(u), 0, "paused");
        aavePool.setFlags(u, true, false, false, false);
        assertEq(helper.maxFlashLoan(u), 0, "flash disabled");
        aavePool.setFlags(u, true, true, false, true);
        assertEq(helper.maxFlashLoan(u), IDLE_USDC + 1, "frozen still lends");
        aavePool.setReserveAToken(u, address(0));
        assertEq(helper.maxFlashLoan(u), 0, "no aToken");
        assertEq(helper.flashPremium(u, 1), 1, "ceiling of 0.0005");
        assertEq(helper.flashPremium(u, 1999), 1);
        assertEq(helper.flashPremium(u, 2001), 2);
        assertEq(helper.flashPremium(u, 1950e6), EXAMPLE_PREMIUM);
    }

    // ─── Liquidation, repayment and payout (REQ-HELPER-006 … REQ-HELPER-008) ───

    /// @notice `F < X`: the helper pulls `X − F` from its caller, approves exactly `X`, and `keeperOut` returns the
    /// inventory inside the payout. Example (ATTACK row on oversizing): `X = 2,047.5`, `F = 1,950`.
    // TEST-174 verifies: REQ-HELPER-004, REQ-HELPER-006, REQ-HELPER-008, REQ-SWAP-011, SPEC-LIQ-017
    function test_TEST_174_helperApprovesExactlyXAndMeasuresKeeperOut() public {
        _fund(caller, address(helper), 97.5e6);
        vm.expectEmit(true, true, true, true, address(helper));
        emit IFlashLiquidatorEvents.FlashLiquidated(
            caller, caller, address(usdcToken), 1950e6, EXAMPLE_PREMIUM, 2118.3e6, 0, 167.325e6
        );
        uint256 payout = _liquidate(_request(2047.5e6, 1950e6, EXAMPLE_PREMIUM, 0, 167.325e6));
        assertEq(payout, 167.325e6, "inventory 97.5 + net 69.825");
        assertEq(lvs.lastKf(), 2047.5e6, "LPVaultSwap pulled exactly X");
        assertEq(usdcToken.balanceOf(caller), 167.325e6);
        _assertClean(address(helper));
    }

    /// @notice Oversized loan: `X = F = 10,000` USDC repays 10,005 and pays 65.8 USDC (ATTACK oversizing example).
    // TEST-174 verifies: REQ-HELPER-007, REQ-HELPER-008, SPEC-LIQ-017
    function test_TEST_174_helperOversizedLoanPremiumFromPayout() public {
        uint256 payout = _liquidate(_request(10_000e6, 10_000e6, 5e6, 0, 65.8e6));
        assertEq(payout, 65.8e6);
        assertEq(usdcToken.balanceOf(treasury), A_EXAMPLE, "Avana's fee does not pay the premium");
    }

    /// @notice The dust example of 2.11 `REQ-HELPER-007`: `X = F = 3` USDC, `owed = 3.0015`, `keeperOut = 2.95`,
    /// `topUp = 0.0515` USDC pulled from the caller; with `maxTopUp = 0` the whole liquidation reverts.
    // TEST-174 verifies: REQ-HELPER-007, REQ-SWAP-081
    // Sources: 2.11 REQ-HELPER-007 example
    function test_TEST_174_helperTopUpWithinBound() public {
        lvs.setOutcome(3e6, 2.95e6, 0);
        vm.expectRevert(abi.encodeWithSelector(IFlashLiquidatorErrors.TopUpExceeded.selector, 51_500, 0));
        _liquidate(_request(3e6, 3e6, 1500, 0, 0));
        assertEq(lvs.calls(), 0, "the whole liquidation reverted");
        vm.expectRevert(abi.encodeWithSelector(IFlashLiquidatorErrors.TopUpExceeded.selector, 51_500, 51_499));
        _liquidate(_request(3e6, 3e6, 1500, 51_499, 0));

        _fund(caller, address(helper), 51_500);
        vm.expectEmit(true, true, true, true, address(helper));
        emit IFlashLiquidatorEvents.FlashLiquidated(caller, caller, address(usdcToken), 3e6, 1500, 2.95e6, 51_500, 0);
        uint256 payout = _liquidate(_request(3e6, 3e6, 1500, 51_500, 0));
        assertEq(payout, 0);
        assertEq(usdcToken.balanceOf(caller), 0, "the caller paid the top-up");
        _assertClean(address(helper));
    }

    // TEST-174 verifies: REQ-HELPER-008, REQ-HELPER-014, Q-345
    // TEST-176 verifies: REQ-HELPER-008, REQ-HELPER-014, Q-345
    function test_TEST_176_helperPayoutTooLow() public {
        vm.expectRevert(
            abi.encodeWithSelector(IFlashLiquidatorErrors.PayoutTooLow.selector, EXAMPLE_PAYOUT, EXAMPLE_PAYOUT + 1)
        );
        _liquidate(_request(1950e6, 1950e6, EXAMPLE_PREMIUM, 0, EXAMPLE_PAYOUT + 1));
        assertEq(lvs.calls(), 0, "the whole liquidation reverted");
        assertEq(usdcToken.balanceOf(aUsdc), IDLE_USDC);
        _liquidate(_request(1950e6, 1950e6, EXAMPLE_PREMIUM, 0, EXAMPLE_PAYOUT));
    }

    /// @notice `params.minPayout` stays LPVaultSwap's bound on `keeperOut`; the helper's caller may leave it 0.
    // TEST-176 verifies: REQ-HELPER-008, Q-345
    function test_TEST_176_paramsMinPayoutBindsKeeperOut() public {
        FlashLiquidationRequest memory request = _exampleRequest();
        request.params.minPayout = EXAMPLE_KEEPER_OUT + 1;
        vm.expectRevert(
            abi.encodeWithSelector(ILPVaultSwapErrors.PayoutTooLow.selector, EXAMPLE_KEEPER_OUT, EXAMPLE_KEEPER_OUT + 1)
        );
        _liquidate(request);
    }

    /// @notice A route residue and a dust leg in USDT reach the caller; the helper keeps nothing.
    // TEST-174 verifies: REQ-HELPER-001, REQ-HELPER-008, REQ-SWAP-026
    // TEST-288 verifies: REQ-HELPER-001
    function test_TEST_174_helperPayoutAndResidueToRecipient() public {
        lvs.addResidue(usdtToken, 0.4e6);
        lvs.addResidue(usdtToken, 0.000003e6);
        usdtToken.mint(address(helper), 5e6);
        _liquidate(_exampleRequest());
        assertEq(usdtToken.balanceOf(caller), 0.400003e6, "residue and dust leg forwarded");
        assertEq(usdtToken.balanceOf(address(helper)), 5e6, "a balance held before the call stays");
        assertEq(usdcToken.balanceOf(caller), EXAMPLE_PAYOUT);
    }

    // TEST-288 verifies: REQ-HELPER-001, Q-358
    function test_TEST_288_revertedCallLeavesNothing() public {
        lvs.addResidue(usdtToken, 1e6);
        _fund(caller, address(helper), 1000e6);
        lvs.setOutcome(3e6, 2.95e6, 0);
        vm.expectRevert(abi.encodeWithSelector(IFlashLiquidatorErrors.TopUpExceeded.selector, 51_500, 0));
        _liquidate(_request(3e6, 3e6, 1500, 0, 0));
        _assertClean(address(helper));
        assertEq(usdcToken.balanceOf(caller), 1000e6);
        assertEq(usdcToken.allowance(caller, address(helper)), 1000e6);
    }

    // ─── Public instance (REQ-HELPER-010) ───

    /// @notice The caller pays and is paid; a third party that approved the helper is never touched.
    // TEST-289 verifies: REQ-HELPER-004, REQ-HELPER-010, REQ-HELPER-012, Q-404
    // Sources: 5.1 TEST-289
    function test_TEST_289_publicHelperPullsFromAndPaysOnlyCaller() public {
        address victim = makeAddr("victim");
        _fund(victim, address(helper), 10_000e6);
        _fund(caller, address(helper), 97.5e6);
        lvs.setOutcome(3e6, 2.95e6, 0);
        // Inventory and the dust case's top-up come from the caller, never from the victim's allowance.
        _liquidate(_request(3e6, 2.9e6, 1450, 1e6, 0));
        assertEq(usdcToken.balanceOf(caller), 97.5e6 - 0.1e6 + 48_550, "inventory returned inside the payout");
        _liquidate(_request(3e6, 3e6, 1500, 1e6, 0));
        assertEq(usdcToken.balanceOf(caller), 97.5e6 - 0.1e6 + 48_550 - 51_500, "top-up paid by the caller");
        assertEq(usdcToken.balanceOf(victim), 10_000e6, "victim untouched");
        assertEq(usdcToken.allowance(victim, address(helper)), 10_000e6);
        lvs.setOutcome(D_EXAMPLE, R_EXAMPLE, A_EXAMPLE);
        vm.prank(victim);
        uint256 payout = helper.flashLiquidate(_exampleRequest());
        assertEq(usdcToken.balanceOf(victim), 10_000e6 + payout, "a caller is paid only itself");
    }

    /// @notice LPVaultSwap checks the freeze on the helper, not on its caller: a frozen Z liquidates through the
    /// public helper and is paid, while its direct call reverts.
    // TEST-289 verifies: REQ-HELPER-006, REQ-HELPER-010, REQ-SWAP-105, Q-242
    // Sources: 2.11 REQ-SWAP-105 example
    function test_TEST_289_frozenAddressSettlesThroughPublicHelper() public {
        address z = makeAddr("Z");
        lvs.setFrozen(z, true);
        LiquidationParams memory p = _params(1950e6);
        vm.prank(z);
        vm.expectRevert(abi.encodeWithSelector(ILPVaultSwapErrors.AddressIsFrozen.selector, z));
        lvs.liquidate(p);
        vm.prank(z);
        uint256 payout = helper.flashLiquidate(_exampleRequest());
        assertEq(payout, EXAMPLE_PAYOUT);
        assertEq(usdcToken.balanceOf(z), EXAMPLE_PAYOUT);
        lvs.setFrozen(address(helper), true);
        vm.expectRevert(abi.encodeWithSelector(ILPVaultSwapErrors.AddressIsFrozen.selector, address(helper)));
        _liquidate(_exampleRequest());
    }

    /// @notice A market token that refuses the helper: LPVaultSwap escrows the residue credited to the helper and the
    /// liquidation completes; the credit is claimable only to `feeRecipient`, never to the caller.
    // TEST-289 verifies: REQ-HELPER-010, REQ-SWAP-076, Q-389
    function test_TEST_289_residueRefusedByHelperEscrowedToHelper() public {
        lvs.addResidue(usdtToken, 0.4e6);
        usdtToken.setBlocked(address(helper), true);
        uint256 payout = _liquidate(_exampleRequest());
        assertEq(payout, EXAMPLE_PAYOUT);
        assertEq(escrow.claimable(address(usdtToken), address(helper)), 0.4e6, "credited to the helper");
        assertEq(usdtToken.balanceOf(caller), 0);
        vm.prank(caller);
        helper.claimEscrowed(address(usdtToken));
        assertEq(usdtToken.balanceOf(caller), 0, "never to the caller");
        assertEq(usdtToken.balanceOf(feeRecipient), 0.4e6, "to feeRecipient");
    }

    // ─── Blocklists and transfer fees ───

    /// @notice A caller the debt asset blocks cannot be paid: the payout is never escrowed and the whole liquidation
    /// reverts.
    // TEST-174 verifies: REQ-HELPER-008, REQ-SWAP-026, Q-389
    function test_TEST_174_blocklistedCallerRevertsWholeLiquidation() public {
        usdcToken.setBlocked(caller, true);
        vm.expectRevert(abi.encodeWithSelector(PayoutToken.Blocked.selector, caller));
        _liquidate(_exampleRequest());
        assertEq(lvs.calls(), 0);
        assertEq(escrow.totalClaimable(address(usdcToken)), 0, "never escrowed");
    }

    /// @notice A caller a market token blocks cannot receive its residue: the forward reverts the whole call.
    // TEST-174 verifies: REQ-HELPER-008
    function test_TEST_174_residueRefusedByRecipientRevertsWholeLiquidation() public {
        lvs.addResidue(usdtToken, 0.4e6);
        usdtToken.setBlocked(caller, true);
        vm.expectRevert(abi.encodeWithSelector(PayoutToken.Blocked.selector, caller));
        _liquidate(_exampleRequest());
        assertEq(lvs.calls(), 0);
    }

    /// @notice A transfer fee on the debt asset: the helper receives less than `X` from the caller and the Pool, so
    /// LPVaultSwap's pull of `X` fails and the call reverts; the caller then funds `liquidate` itself.
    // TEST-174 verifies: REQ-HELPER-007, REQ-SWAP-108, REQ-SWAP-123
    function test_TEST_174_transferFeeOnDebtAssetReverts() public {
        usdcToken.setFeeBps(10);
        vm.expectPartialRevert(IERC20Errors.ERC20InsufficientBalance.selector);
        _liquidate(_exampleRequest());
        _fund(caller, address(lvs), 1950e6);
        vm.prank(caller);
        lvs.liquidate(_params(1950e6));
        assertEq(lvs.lastKf(), 1948.05e6, "LPVaultSwap measures Kf when the caller funds directly");
    }

    /// @notice A balance the helper held before the call never pays for it: a fee that would leave the helper below
    /// its start reverts `PayoutTooLow(0, minPayout)`; a fee the payout covers is paid from the payout.
    // TEST-174 verifies: REQ-HELPER-001, REQ-HELPER-007, REQ-HELPER-008, REQ-SWAP-108
    function test_TEST_174_transferFeePaidFromPayoutNeverFromHelperBalance() public {
        usdcToken.mint(address(helper), 1e6);
        usdcToken.setFeeBps(10);
        lvs.setOutcome(3e6, 2.95e6, 0);
        _fund(caller, address(helper), 1e6);
        vm.expectRevert(abi.encodeWithSelector(IFlashLiquidatorErrors.PayoutTooLow.selector, 0, 0));
        _liquidate(_request(3e6, 3e6, 1500, 1e6, 0));

        lvs.setOutcome(D_EXAMPLE, R_EXAMPLE, A_EXAMPLE);
        usdcToken.mint(address(helper), 9e6);
        uint256 payout = _liquidate(_request(1950e6, 1950e6, EXAMPLE_PREMIUM, 0, 65e6));
        // Kf = 1,948.05; keeperOut 2,020.8 arrives as 2,018.7792; less 1,950.975 owed, less the 1.95 inbound fee.
        assertEq(payout, 65.8542e6, "the fee is paid from the payout");
        assertEq(usdcToken.balanceOf(address(helper)), 10e6, "the helper's own balance is where it started");
    }

    // ─── Source rule (REQ-HELPER-002) ───

    // TEST-285 verifies: REQ-HELPER-002, REQ-HELPER-013, Q-386, INV-095
    // Sources: 5.1 TEST-285, ATTACK-195
    function test_TEST_285_hubPoolRefusedAtDeploymentAndEveryCall() public {
        registry.setHub(address(aavePool), true);
        vm.expectRevert(IFlashLiquidatorErrors.FlashSourceIsHub.selector);
        this.deployHelper(address(aavePool), address(lvs), address(registry), address(store));
        vm.expectRevert(IFlashLiquidatorErrors.FlashSourceIsHub.selector);
        this.deployOperatorHelper([address(aavePool), address(lvs), address(registry), address(store)], signer, safe, 1);
        vm.expectRevert(IFlashLiquidatorErrors.FlashSourceIsHub.selector);
        _liquidate(_exampleRequest());
        vm.prank(signer);
        vm.expectRevert(IFlashLiquidatorErrors.FlashSourceIsHub.selector);
        opHelper.flashLiquidate(_exampleRequest());
        assertEq(aavePool.flashLoanCalls(), 0);
        // Another recorded Hub does not stop the helper; the Aave V3 Pool passes.
        registry.setHub(address(aavePool), false);
        registry.setHub(makeAddr("otherHub"), true);
        _liquidate(_exampleRequest());
    }

    // ─── No route, recipient or call data from the request (REQ-HELPER-012) ───

    /// @notice LPVaultSwap receives the request's `params` unchanged; two requests that differ only in the helper's
    /// `minPayout` reach `liquidate` with identical `params`.
    // TEST-290 verifies: REQ-HELPER-012, REQ-HELPER-004, Q-062, Q-335
    // Sources: 5.1 TEST-290 example
    function test_TEST_290_paramsPassedUnchanged() public {
        FlashLiquidationRequest memory a = _exampleRequest();
        _liquidate(a);
        bytes32 first = lvs.lastParamsHash();
        assertEq(first, keccak256(abi.encode(a.params)), "byte-equal params");
        FlashLiquidationRequest memory b = _exampleRequest();
        b.minPayout = 0;
        _liquidate(b);
        assertEq(lvs.lastParamsHash(), first, "the helper's minPayout is not forwarded");
    }

    /// @notice Every external call the helper makes goes to the Pool (and its address provider and ACLManager for the
    /// premium quote), LPVaultSwap, the MarketRegistry, the ParameterStore, the debt asset or the market's tokens.
    // TEST-290 verifies: REQ-HELPER-012, REQ-HELPER-001
    function test_TEST_290_callsOnlyFixedTargets() public {
        lvs.addResidue(usdtToken, 1e6);
        vm.startStateDiffRecording();
        _liquidate(_exampleRequest());
        Vm.AccountAccess[] memory accesses = vm.stopAndReturnStateDiff();
        uint256 seen = 0;
        for (uint256 i = 0; i < accesses.length; ++i) {
            if (accesses[i].accessor != address(helper)) continue;
            address target = accesses[i].account;
            ++seen;
            // The ParameterStore proxy's delegatecall to its implementation is recorded with the helper as accessor.
            if (accesses[i].kind == VmSafe.AccountAccessKind.DelegateCall && target == address(implementation)) {
                continue;
            }
            assertTrue(
                target == address(helper) || target == address(aavePool) || target == address(provider)
                    || target == address(acl) || target == address(lvs) || target == address(registry)
                    || target == address(store) || target == address(usdcToken) || target == address(usdtToken),
                "call to an unlisted target"
            );
        }
        assertGt(seen, 10);
    }

    // ─── helpers ───

    function _isPublicSelector(
        bytes4 selector
    ) internal pure returns (bool) {
        return selector == IFlashLiquidator.flashLiquidate.selector
            || selector == IFlashLiquidator.executeOperation.selector
            || selector == IFlashLiquidator.maxFlashLoan.selector || selector == IFlashLiquidator.flashPremium.selector
            || selector == IFlashLiquidator.POOL.selector || selector == IFlashLiquidator.LP_VAULT_SWAP.selector
            || selector == IFlashLiquidator.MARKET_REGISTRY.selector
            || selector == IFlashLiquidator.PARAMETER_STORE.selector
            || selector == IFlashLiquidator.claimEscrowed.selector;
    }

    function _assertNoForbiddenOpcode(
        bytes memory code
    ) internal pure {
        uint256 i = 0;
        while (i < code.length) {
            uint8 op = uint8(code[i]);
            assertTrue(op != 0xf4 && op != 0xf2 && op != 0xff && op != 0xf0 && op != 0xf5, "forbidden opcode");
            i += (op >= 0x60 && op <= 0x7f) ? uint256(op) - 0x5e : 1;
        }
    }
}
