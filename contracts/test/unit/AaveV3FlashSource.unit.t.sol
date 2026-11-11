// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {AaveV3FlashSource} from "../../src/flash/AaveV3FlashSource.sol";
import {IFlashSource} from "../../src/flash/IFlashSource.sol";
import {IAaveV3FlashLoanReceiver} from "../../src/interfaces/external/aave/IAaveV3FlashLoanReceiver.sol";
import {FlashSourceFixture} from "../utils/fixtures/FlashSourceFixture.sol";
import {MockAaveV3ACLManager} from "../utils/mocks/AaveV3PoolMocks.sol";
import {MockFlashReceiver} from "../utils/mocks/MockFlashReceiver.sol";
import {PayoutToken} from "../utils/mocks/PayoutToken.sol";

/// @notice AaveV3FlashSource (2.11 Flash source) against a mocked Aave V3.4 Pool and the real ParameterStore: the
/// pre-loan checks in their order, the exact premium cap and the cap above the Pool rate, the callback checks, the
/// repayment and the end state (no balance, no allowance, empty context).
/// @dev Calls of one test share a transaction (`isolate = false`), so the transient context carries between them and
/// the tests show it is cleared.
/// forge-config: default.isolate = false
contract AaveV3FlashSourceUnitTest is FlashSourceFixture {
    bytes internal constant CTX = abi.encode(uint256(7), bytes32("liquidation"));

    function setUp() public {
        _deployFlashSource();
    }

    function _borrow(
        uint256 amount
    ) internal returns (uint256) {
        return swap.borrow(address(usdcToken), amount, address(hub), CTX);
    }

    function _assertClean(
        PayoutToken token
    ) internal view {
        assertEq(token.balanceOf(address(source)), 0, "source holds a balance");
        assertEq(token.allowance(address(source), address(aavePool)), 0, "source left an allowance");
    }

    function _one(
        uint256 x
    ) internal pure returns (uint256[] memory list) {
        list = new uint256[](1);
        list[0] = x;
    }

    function _oneAsset(
        address x
    ) internal pure returns (address[] memory list) {
        list = new address[](1);
        list[0] = x;
    }

    // ─── Deployment and surface ───

    // TEST-108 verifies: REQ-FLASH-001
    function test_TEST_108_constructorFixesImmutablesAndRefusesZero() public {
        assertEq(source.LENDER(), address(aavePool));
        assertEq(source.LP_VAULT_SWAP(), address(swap));
        assertEq(source.PARAMETER_STORE(), address(store));
        assertEq(source.ON_FLASH_LOAN_MAGIC(), keccak256("IFlashReceiver.onFlashLoan"));
        vm.expectRevert(IFlashSource.ZeroAddress.selector);
        new AaveV3FlashSource(address(0), address(swap), address(store));
        vm.expectRevert(IFlashSource.ZeroAddress.selector);
        new AaveV3FlashSource(address(aavePool), address(0), address(store));
        vm.expectRevert(IFlashSource.ZeroAddress.selector);
        new AaveV3FlashSource(address(aavePool), address(swap), address(0));
    }

    /// @notice No delegatecall, callcode, selfdestruct or create in the runtime code.
    // TEST-032 verifies: REQ-FLASH-001, INV-053
    function test_TEST_032_noDelegatecallSelfdestructOrCreate() public view {
        bytes memory code = address(source).code;
        uint256 i = 0;
        while (i < code.length) {
            uint8 op = uint8(code[i]);
            assertTrue(op != 0xf4 && op != 0xf2 && op != 0xff && op != 0xf0 && op != 0xf5, "forbidden opcode");
            i += (op >= 0x60 && op <= 0x7f) ? uint256(op) - 0x5e : 1;
        }
    }

    /// @notice The source answers only its eight selectors: no owner, setter, sweep, fallback or `receive`.
    // TEST-032 verifies: REQ-FLASH-001, INV-053
    function testFuzz_TEST_032_onlyInterfaceSelectors(
        bytes4 selector,
        bytes calldata tail
    ) public {
        vm.assume(
            selector != IFlashSource.flashLoan.selector && selector != IFlashSource.maxFlashLoan.selector
                && selector != IFlashSource.flashPremium.selector && selector != IFlashSource.LENDER.selector
                && selector != IFlashSource.LP_VAULT_SWAP.selector && selector != IFlashSource.PARAMETER_STORE.selector
                && selector != IAaveV3FlashLoanReceiver.executeOperation.selector
                && selector != bytes4(keccak256("ON_FLASH_LOAN_MAGIC()"))
        );
        (bool ok,) = address(source).call(abi.encodePacked(selector, tail));
        assertFalse(ok, "unknown selector accepted");
        vm.deal(address(this), 1 ether);
        (ok,) = address(source).call{value: 1}("");
        assertFalse(ok, "ETH accepted");
    }

    // ─── Happy path ───

    // TEST-052 verifies: REQ-FLASH-001, REQ-FLASH-003, SPEC-LIQ-015, SPEC-LIQ-007, INV-040, INV-095, Q-135, Q-334
    // TEST-061 verifies: REQ-FLASH-001
    // Sources: 5.1 TEST-052 (1,000 USDC at 5 bps costs 0.5 USDC)
    function test_TEST_052_premiumWithinCapIsRepaid() public {
        assertEq(source.maxFlashLoan(address(usdcToken)), IDLE_USDC);
        assertEq(source.flashPremium(address(usdcToken), 1000e6), 500_000);
        vm.expectEmit(true, false, false, true, address(source));
        emit IFlashSource.FlashLoanServed(address(usdcToken), 1000e6, 500_000);
        uint256 premium = _borrow(1000e6);
        assertEq(premium, 500_000);
        assertEq(swap.lastAmount(), 1000e6);
        assertEq(swap.lastPremium(), 500_000);
        assertEq(swap.lastReceived(), 1000e6, "LPVaultSwap received the principal");
        assertEq(swap.lastAsset(), address(usdcToken));
        assertEq(keccak256(swap.lastContext()), keccak256(CTX));
        assertEq(usdcToken.balanceOf(aUsdc), IDLE_USDC + 500_000, "Pool repaid principal plus premium");
        assertEq(usdcToken.balanceOf(address(swap)), RECEIVER_FUNDS - 500_000);
        assertEq(aavePool.flashLoanCalls(), 1);
        _assertClean(usdcToken);
    }

    /// @notice The context is transient and cleared: a second loan in the same transaction runs normally.
    // TEST-046 verifies: REQ-FLASH-001, REQ-FLASH-003, INV-040
    function test_TEST_046_contextClearedBetweenLoans() public {
        _borrow(1000e6);
        _borrow(2000e6);
        assertEq(swap.calls(), 2);
        _assertClean(usdcToken);
    }

    // ─── Pre-loan checks and their order ───

    // TEST-046 verifies: REQ-FLASH-001, REQ-FLASH-009, INV-040, INV-095
    function testFuzz_TEST_046_onlyLPVaultSwapBorrows(
        address caller
    ) public {
        vm.assume(caller != address(swap));
        vm.prank(caller);
        vm.expectRevert(IFlashSource.NotLPVaultSwap.selector);
        source.flashLoan(address(usdcToken), 1000e6, address(hub), CTX);
    }

    /// @notice The caller check comes first: an outsider naming the Pool as the Hub still gets `NotLPVaultSwap`.
    // TEST-046 verifies: REQ-FLASH-001
    function test_TEST_046_callerCheckedBeforeEverythingElse() public {
        vm.expectRevert(IFlashSource.NotLPVaultSwap.selector);
        source.flashLoan(address(usdcToken), IDLE_USDC + 1, address(aavePool), CTX);
    }

    // TEST-285 verifies: REQ-FLASH-001, REQ-FLASH-005, INV-095, ATTACK-195, Q-386
    function test_TEST_285_lenderIsTheAaveV3PoolAndNeverTheLiquidatedHub() public {
        assertEq(source.LENDER(), address(aavePool), "LENDER reports the pool the loan draws from");
        // The Hub check comes before the liquidity and premium checks.
        aavePool.setPremiumTotal(100);
        vm.expectRevert(IFlashSource.FlashSourceIsHub.selector);
        swap.borrow(address(usdcToken), IDLE_USDC + 1, address(aavePool), CTX);
        aavePool.setPremiumTotal(POOL_PREMIUM_BPS);
        swap.borrow(address(usdcToken), 1000e6, address(hub), CTX);
        assertEq(aavePool.flashLoanCalls(), 1);
    }

    // TEST-052 verifies: REQ-FLASH-001, REQ-FLASH-002, SPEC-LIQ-015, INV-095, Q-335
    function test_TEST_052_liquidityBelowAmountRefusedBeforeLoan() public {
        // The liquidity check comes before the premium check.
        aavePool.setPremiumTotal(100);
        vm.expectRevert(abi.encodeWithSelector(IFlashSource.InsufficientFlashLiquidity.selector, IDLE_USDC));
        _borrow(IDLE_USDC + 1);
        aavePool.setPremiumTotal(POOL_PREMIUM_BPS);
        _borrow(IDLE_USDC);
        assertEq(aavePool.flashLoanCalls(), 1);
        _assertClean(usdcToken);
    }

    /// @notice A paused, inactive or flash-disabled reserve lends nothing; a frozen one still lends.
    // TEST-052 verifies: REQ-FLASH-001, REQ-FLASH-002, Q-334, Q-336
    function test_TEST_052_reserveFlagsBoundAvailableLiquidity() public {
        address a = address(usdcToken);
        aavePool.setFlags(a, true, false, true, true);
        assertEq(source.maxFlashLoan(a), 0, "paused");
        vm.expectRevert(abi.encodeWithSelector(IFlashSource.InsufficientFlashLiquidity.selector, 0));
        _borrow(1);
        aavePool.setFlags(a, false, false, false, true);
        assertEq(source.maxFlashLoan(a), 0, "inactive");
        aavePool.setFlags(a, true, false, false, false);
        assertEq(source.maxFlashLoan(a), 0, "flash disabled");
        aavePool.setFlags(a, true, true, false, true);
        assertEq(source.maxFlashLoan(a), IDLE_USDC, "frozen still lends");
        _borrow(1000e6);
        _assertClean(usdcToken);
    }

    /// @notice An unlisted asset, or a listed reserve whose aToken reads as zero, lends nothing.
    // TEST-052 verifies: REQ-FLASH-001, REQ-FLASH-002
    function test_TEST_052_unlistedReserveLendsNothing() public {
        assertEq(source.maxFlashLoan(makeAddr("unlisted")), 0);
        assertEq(source.maxFlashLoan(address(0)), 0);
        aavePool.setReserveAToken(address(usdcToken), address(0));
        assertEq(source.maxFlashLoan(address(usdcToken)), 0);
    }

    // TEST-052 verifies: REQ-FLASH-001, REQ-FLASH-002, REQ-PSTORE-024, SPEC-LIQ-015, INV-095, Q-135, Q-335
    function test_TEST_052_premiumAboveCapRefusedBeforeLoan() public {
        aavePool.setPremiumTotal(20);
        // 1,950 USDC at 20 bps: φ = 3,900,000 and maxPremium = ⌊10 × 1,950e6 / 10⁴⌋ = 1,950,000.
        vm.expectRevert(abi.encodeWithSelector(IFlashSource.FlashFeeTooHigh.selector, 3_900_000, 1_950_000));
        _borrow(1950e6);
        assertEq(aavePool.flashLoanCalls(), 0, "the Pool was never called");
    }

    /// @notice 5.1 example: `F = 1,950,000,500`, `φ = 1,950,001`: 19,500,010,000 > 19,500,005,000 is refused, the
    /// case a rounded-up bound would admit.
    // TEST-052 verifies: REQ-FLASH-001, SPEC-LIQ-015, Q-135
    function test_TEST_052_exactBoundNoRounding() public {
        aavePool.setPremiumTotal(10);
        assertEq(source.flashPremium(address(usdcToken), 1_950_000_500), 1_950_001);
        vm.expectRevert(abi.encodeWithSelector(IFlashSource.FlashFeeTooHigh.selector, 1_950_001, 1_950_000));
        _borrow(1_950_000_500);
    }

    // ─── Cap strictly above the Pool rate (SettlementMath review S3, MATH-ST-115) ───

    /// @notice With the cap equal to the 5 bps rate, a loan passes only when 10⁴ divides `5F`.
    // TEST-052 verifies: SPEC-LIQ-015, REQ-FLASH-001, REQ-PSTORE-024
    // Sources: MATH-ST-115
    function test_TEST_052_capEqualToRateRefusesMostSizes() public {
        _setCap(5);
        assertEq(_borrow(1_950_000_000), 975_000);
        vm.expectRevert(abi.encodeWithSelector(IFlashSource.FlashFeeTooHigh.selector, 975_001, 975_000));
        _borrow(1_950_000_001);
        vm.expectRevert(abi.encodeWithSelector(IFlashSource.FlashFeeTooHigh.selector, 1, 0));
        _borrow(1999);
    }

    /// @notice Launch values: cap 10 above the 5 bps rate; every loan of at least 1,000 base units passes and 999 fails
    /// closed.
    // TEST-052 verifies: SPEC-LIQ-015, REQ-FLASH-001, REQ-FLASH-007
    // Sources: MATH-ST-115
    function test_TEST_052_capAboveRateLaunchThreshold() public {
        assertEq(_borrow(1000), 1);
        assertEq(_borrow(2000), 1);
        // The source quotes ⌈2,001 × 5 / 10⁴⌉ = 2 for its gate; the V3.4 Pool charges half-up, 1.
        assertEq(source.flashPremium(address(usdcToken), 2001), 2);
        assertEq(_borrow(2001), 1);
        vm.expectRevert(abi.encodeWithSelector(IFlashSource.FlashFeeTooHigh.selector, 1, 0));
        _borrow(999);
        _assertClean(usdcToken);
    }

    /// @notice 5.1 TEST-267 example: with `maxFlashFeeBps = 4` below the 5 bps rate the flash path refuses before the
    /// loan; at the launch cap 1,000,000 USDC repays 1,000,500 USDC.
    // TEST-267 verifies: SPEC-LIQ-015, REQ-FLASH-001, INV-095
    // Sources: MATH-ST-115
    function test_TEST_267_capBelowRateRefusedAndPremiumExample() public {
        assertEq(_borrow(1_000_000e6), 500e6);
        assertEq(usdcToken.balanceOf(aUsdc), IDLE_USDC + 500e6);
        _setCap(4);
        vm.expectRevert(abi.encodeWithSelector(IFlashSource.FlashFeeTooHigh.selector, 500e6, 400e6));
        _borrow(1_000_000e6);
    }

    /// @notice With `FLASH_BORROWER` the premium is 0 and a cap of 0 still passes; the role is read from the ACLManager
    /// the PoolAddressesProvider names now.
    // TEST-052 verifies: REQ-FLASH-001, REQ-FLASH-007, SPEC-LIQ-015, Q-334, Q-373
    function test_TEST_052_flashBorrowerPaysNoPremium() public {
        acl.addFlashBorrower(address(source));
        assertEq(source.flashPremium(address(usdcToken), 2_000_000e6), 0);
        _tl();
        store.tightenMaxFlashFeeBps(0);
        assertEq(_borrow(2_000_000e6), 0);
        assertEq(usdcToken.balanceOf(aUsdc), IDLE_USDC);
        provider.setACLManager(address(new MockAaveV3ACLManager()));
        assertEq(source.flashPremium(address(usdcToken), 2_000_000e6), 1000e6);
        vm.expectRevert(abi.encodeWithSelector(IFlashSource.FlashFeeTooHigh.selector, 1000e6, 0));
        _borrow(2_000_000e6);
    }

    /// @notice `flashPremium` forms no overflowing product: the full-width quotient is rounded up.
    // TEST-052 verifies: REQ-FLASH-001, SPEC-LIQ-007
    function test_TEST_052_premiumOfHugeAmountDoesNotOverflow() public view {
        assertEq(source.flashPremium(address(usdcToken), type(uint256).max), type(uint256).max / 2000 + 1);
    }

    // ─── Callback checks ───

    // TEST-046 verifies: REQ-FLASH-003, INV-040, INV-095, Q-045
    function testFuzz_TEST_046_directCallbackRefused(
        address caller,
        address initiator,
        uint256 amount,
        uint256 premium
    ) public {
        vm.prank(caller);
        vm.expectRevert(IFlashSource.InvalidFlashCallback.selector);
        source.executeOperation(_oneAsset(address(usdcToken)), _one(amount), _one(premium), initiator, CTX);
    }

    /// @notice A Pool call that replays a finished loan's arguments finds no context.
    // TEST-046 verifies: REQ-FLASH-003, INV-040
    function test_TEST_046_callbackAfterLoanClosedRefused() public {
        _borrow(1000e6);
        usdcToken.mint(address(source), 1000e6);
        vm.prank(address(aavePool));
        vm.expectRevert(IFlashSource.InvalidFlashCallback.selector);
        source.executeOperation(_oneAsset(address(usdcToken)), _one(1000e6), _one(500_000), address(source), CTX);
    }

    // TEST-046 verifies: REQ-FLASH-003, INV-040, Q-045
    function test_TEST_046_foreignInitiatorRefused() public {
        aavePool.setInitiatorOverride(address(swap));
        vm.expectRevert(IFlashSource.InvalidFlashCallback.selector);
        _borrow(1000e6);
    }

    /// @notice Inside an open context the Pool's callback is refused for two assets, two amounts, two premiums,
    /// another asset, another amount or other params.
    // TEST-046 verifies: REQ-FLASH-003, INV-040
    function test_TEST_046_reshapedCallbackRefused() public {
        for (uint8 shape = 1; shape <= 6; ++shape) {
            aavePool.setCallbackShape(shape);
            vm.expectRevert(IFlashSource.InvalidFlashCallback.selector);
            _borrow(1000e6);
        }
        aavePool.setCallbackShape(0);
        _borrow(1000e6);
        _assertClean(usdcToken);
    }

    // TEST-046 verifies: REQ-FLASH-003, INV-040
    function test_TEST_046_secondCallbackInOneLoanRefused() public {
        aavePool.setCallbackTwice(true);
        vm.expectRevert(IFlashSource.InvalidFlashCallback.selector);
        _borrow(1000e6);
    }

    /// @notice A lender that never calls back (and pulls nothing) leaves the loan unserved: `flashLoan` reverts.
    // TEST-046 verifies: REQ-FLASH-001, INV-040
    function test_TEST_046_missingCallbackRefused() public {
        aavePool.setSkipCallback(true);
        aavePool.setPullShortBy(1000e6 + 500_000);
        vm.expectRevert(IFlashSource.InvalidFlashCallback.selector);
        _borrow(1000e6);
    }

    // TEST-046 verifies: REQ-FLASH-003, REQ-FLASH-004, INV-040
    function test_TEST_046_wrongMagicRefused() public {
        swap.setMode(MockFlashReceiver.Mode.WrongMagic);
        vm.expectRevert(IFlashSource.InvalidFlashCallback.selector);
        _borrow(1000e6);
    }

    // TEST-046 verifies: REQ-FLASH-001, INV-040
    function test_TEST_046_reentrantLoanRefused() public {
        swap.setMode(MockFlashReceiver.Mode.ReenterLoan);
        vm.expectRevert(IFlashSource.FlashLoanActive.selector);
        _borrow(1000e6);
    }

    // TEST-046 verifies: REQ-FLASH-003, INV-040
    function test_TEST_046_reentrantCallbackRefused() public {
        swap.setMode(MockFlashReceiver.Mode.ReenterCallback);
        vm.expectRevert(IFlashSource.InvalidFlashCallback.selector);
        _borrow(1000e6);
    }

    /// @notice The premium the Pool charges in the callback is re-checked against the cap.
    // TEST-052 verifies: REQ-FLASH-003, REQ-FLASH-004, SPEC-LIQ-015, INV-040
    function test_TEST_052_chargedPremiumRecheckedInCallback() public {
        aavePool.setPremiumOverride(1_000_001);
        vm.expectRevert(abi.encodeWithSelector(IFlashSource.FlashFeeTooHigh.selector, 1_000_001, 1_000_000));
        _borrow(1000e6);
        aavePool.setPremiumOverride(1_000_000);
        assertEq(_borrow(1000e6), 1_000_000, "the premium returned is the one charged");
    }

    // ─── Repayment ───

    // TEST-052 verifies: REQ-FLASH-003, REQ-SWAP-122, INV-095
    function test_TEST_052_shortRepaymentRefused() public {
        swap.setMode(MockFlashReceiver.Mode.RepayShort);
        vm.expectRevert(abi.encodeWithSelector(IFlashSource.FlashRepayShort.selector, 1_000_499_999, 1_000_500_000));
        _borrow(1000e6);
        swap.setMode(MockFlashReceiver.Mode.NoRepay);
        vm.expectRevert(abi.encodeWithSelector(IFlashSource.FlashRepayShort.selector, 0, 1_000_500_000));
        _borrow(1000e6);
    }

    /// @notice A Pool that pulls less than approved leaves no allowance behind.
    // TEST-267 verifies: REQ-FLASH-001
    function test_TEST_267_allowanceLeftByShortPullWithdrawn() public {
        aavePool.setPullShortBy(1);
        _borrow(1000e6);
        assertEq(usdcToken.allowance(address(source), address(aavePool)), 0);
        assertEq(usdcToken.balanceOf(address(source)), 1, "the unit the Pool did not pull");
    }

    /// @notice A transfer fee on the debt asset: the source forwards what it measured and is repaid by balance delta.
    /// 5,000 USDT at 10 bps arrives at the source as 4,995 and at LPVaultSwap as 4,990.005.
    // TEST-287 verifies: REQ-FLASH-003, REQ-SWAP-122, INV-095, ATTACK-197, Q-390
    function test_TEST_287_flashReceiptMeasuredByDelta() public {
        (PayoutToken usdt, address aUsdt) = _listToken("USDT", 1_000_000e6);
        usdt.mint(address(swap), 100e6);
        usdt.setFeeBps(10);
        uint256 premium = swap.borrow(address(usdt), 5000e6, address(hub), CTX);
        assertEq(premium, 2_500_000);
        assertEq(swap.lastReceived(), 4_990_005_000, "LPVaultSwap books what arrived");
        // The Pool pulled 5,002.5 USDT from the source; its own transfer pays the fee into the aToken.
        assertEq(usdt.balanceOf(aUsdt), 1_000_000e6 - 5000e6 + 5_002_500_000 - 5_002_500);
        _assertClean(usdt);
    }

    /// @notice A zero-amount loan: the source makes no transfer of its own (it skips the zero forward); the Aave Pool
    /// itself transfers zero, so with a token that reverts on zero transfers the loan reverts inside the Pool.
    /// LPVaultSwap never requests `F = 0` (REQ-SWAP-012).
    // TEST-177 verifies: REQ-FLASH-001, REQ-FLASH-003, INV-021
    function test_TEST_177_zeroAmountLoanSourceSkipsZeroTransfer() public {
        swap.setLenient(true);
        vm.expectCall(address(usdcToken), abi.encodeCall(usdcToken.transfer, (address(swap), 0)), 0);
        assertEq(_borrow(0), 0);
        _assertClean(usdcToken);
        usdcToken.setRevertOnZero(true);
        vm.expectRevert(PayoutToken.ZeroTransfer.selector);
        _borrow(0);
    }

    // ─── Review regressions (H-1 donation, M-1 virtual accounting) ───

    /// @notice A donation to the source never reaches LPVaultSwap: the source forwards only what the Pool delivered in
    /// this loan, so LPVaultSwap's `0 < Fr ≤ amount` check (REQ-SWAP-013) keeps passing; the donation counts toward the
    /// next repayment because LPVaultSwap tops the source up to `owed` by balance delta.
    // TEST-080 verifies: REQ-FLASH-001, REQ-FLASH-003, REQ-SWAP-122, INV-021, Q-390
    function test_TEST_080_donationDoesNotBlockFlashPath() public {
        _borrow(1000e6);
        usdcToken.mint(address(source), 1);
        for (uint256 i = 0; i < 3; ++i) {
            uint256 swapBefore = usdcToken.balanceOf(address(swap));
            uint256 premium = _borrow(1000e6 + i);
            assertEq(swap.lastReceived(), 1000e6 + i, "only the Pool's delivery is forwarded");
            // The first repayment after the donation is one unit smaller.
            assertEq(swapBefore - usdcToken.balanceOf(address(swap)), premium - (i == 0 ? 1 : 0));
        }
        _assertClean(usdcToken);
    }

    /// @notice A donation larger than a loan's `owed` stays in the source; the loan still forwards only `amount`.
    // TEST-080 verifies: REQ-FLASH-001, REQ-FLASH-003, INV-021
    function test_TEST_080_largeDonationStaysAndIsNeverForwarded() public {
        usdcToken.mint(address(source), 5000e6);
        uint256 premium = _borrow(1000e6);
        assertEq(swap.lastReceived(), 1000e6);
        assertEq(usdcToken.balanceOf(address(source)), 5000e6 - 1000e6 - premium);
        assertEq(usdcToken.allowance(address(source), address(aavePool)), 0);
    }

    /// @notice V3.1+ virtual accounting: underlying sent straight to the aToken is not lendable, so `maxFlashLoan` is
    /// `min(aToken balance, virtual balance)` and a loan above it is refused by the source, not by a Pool panic.
    // TEST-052 verifies: REQ-FLASH-001, REQ-FLASH-002, Q-334, Q-336
    function test_TEST_052_aTokenDonationIsNotLendable() public {
        usdcToken.mint(aUsdc, 50_000e6);
        assertEq(source.maxFlashLoan(address(usdcToken)), IDLE_USDC, "the donation is not lendable");
        vm.expectRevert(abi.encodeWithSelector(IFlashSource.InsufficientFlashLiquidity.selector, IDLE_USDC));
        _borrow(IDLE_USDC + 1);
        _borrow(IDLE_USDC);
        aavePool.setVirtualBalance(address(usdcToken), type(uint128).max);
        assertEq(source.maxFlashLoan(address(usdcToken)), usdcToken.balanceOf(aUsdc), "the aToken balance binds");
    }
}
