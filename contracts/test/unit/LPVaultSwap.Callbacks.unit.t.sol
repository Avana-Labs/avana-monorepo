// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ILPVaultSwapErrors} from "../../src/liquidation/lp-vault-swap/ILPVaultSwapErrors.sol";
import {LiquidationResult} from "../../src/liquidation/lp-vault-swap/types/LiquidationResult.sol";
import {LVSFlashSourceMock, LVSLyingRoute} from "../utils/mocks/LPVaultSwapMocks.sol";
import {LPVaultSwapUnitBase} from "./LPVaultSwap.Base.sol";

/// @title LPVaultSwapCallbacksUnitTest
/// @notice The flash callback `onFlashLoan` (2.11 REQ-SWAP-013, REQ-FLASH-004, REQ-SWAP-054): it runs only inside
/// `deleverage`, only from the registry's current flash source, only while the AaveAdapter holds the Lock, only once,
/// only for the asset, amount and context hash `deleverage` opened, and only with a measured principal `0 < Fr ≤ F`; a
/// premium above `maxFlashFeeBps` is refused; a source that never calls back leaves `deleverage` reverting; on success
/// it returns `keccak256("IFlashReceiver.onFlashLoan")`. Every refusal is `InvalidFlashCallback` (or
/// `FlashFeeTooHigh`).
/// forge-config: default.isolate = false
contract LPVaultSwapCallbacksUnitTest is LPVaultSwapUnitBase {
    address internal proxy;
    bytes32 internal key;
    LVSFlashSourceMock internal source;
    uint256 internal constant X = 2_075_924_073;

    function setUp() public override {
        super.setUp();
        (proxy, key) = _openAccount(alice, 10_000e6, 15_000e6, 250_000_000);
        source = new LVSFlashSourceMock(address(lvs), makeAddr("v3Pool"));
        // Exactly the loan: a source holding more would count the excess toward its own repayment (REQ-SWAP-122).
        usdc.mint(address(source), X);
        registry.setFlashSource(address(source));
    }

    function _repayExpect(
        bytes memory err
    ) internal {
        vm.prank(alice);
        vm.expectRevert(err);
        adapter.repayWithCollateral(proxy, _position(key), 1000e6, usdcReserveId, new uint256[](0), 0);
    }

    function _invalid() internal pure returns (bytes memory) {
        return abi.encodeWithSelector(ILPVaultSwapErrors.InvalidFlashCallback.selector);
    }

    /// @notice A correct source: the callback returns the magic value, the source is repaid `F + φ` and the wallet paid.
    // TEST-046 verifies: REQ-SWAP-013, REQ-FLASH-004, REQ-SWAP-106
    function test_TEST_046_validCallbackReturnsMagic() public {
        source.setQuote(1000, 1000);
        uint256 sourceBefore = usdc.balanceOf(address(source));
        vm.prank(alice);
        (uint256 repaid,) =
            adapter.repayWithCollateral(proxy, _position(key), 1000e6, usdcReserveId, new uint256[](0), 0);
        assertEq(repaid, X, "x");
        assertEq(source.lastMagic(), keccak256("IFlashReceiver.onFlashLoan"), "magic");
        assertEq(usdc.balanceOf(address(source)), sourceBefore + 1000, "topped up to F + premium by balance");
    }

    /// @notice `onFlashLoan` from any address outside `deleverage` (no context), including the flash source itself.
    // TEST-046 verifies: REQ-SWAP-013, REQ-SWAP-054, INV-040, PROP-036
    function test_TEST_046_onFlashLoanOnlyInsideDeleverage() public {
        vm.prank(attacker);
        vm.expectRevert(_invalid());
        lvs.onFlashLoan(address(usdc), X, 0, "");
        vm.prank(address(source));
        vm.expectRevert(_invalid());
        lvs.onFlashLoan(address(usdc), X, 0, "");
    }

    /// @notice A route re-entering `onFlashLoan` from inside `liquidate` (LPVaultSwap holding the Lock) is refused.
    // TEST-046 verifies: REQ-SWAP-013, REQ-SWAP-054, PROP-036, PROP-037
    function test_TEST_046_onFlashLoanRefusedWhileLiquidating() public {
        (address bobProxy,) = _bobAccount();
        LVSLyingRoute reentrant = new LVSLyingRoute(address(usdt), address(usdc));
        usdc.mint(address(reentrant), 2000e6);
        reentrant.setOut(1_009_594_950);
        reentrant.setReenter(
            address(lvs), abi.encodeCall(lvs.onFlashLoan, (address(usdc), uint256(1), uint256(0), bytes("")))
        );
        registry.setRoute(MARKET_ID, address(usdt), address(usdc), 0, address(reentrant), true);
        LiquidationResult memory r = _liquidateAs(keeper, _params(bobProxy, 1950e6));
        assertFalse(reentrant.lastReenterOk(), "re-entry refused");
        assertEq(bytes4(reentrant.lastReenterData()), ILPVaultSwapErrors.InvalidFlashCallback.selector, "error");
        assertGt(r.recovered, 0, "the liquidation itself settles");
    }

    /// @notice The callback must come from the registry's current flash source: a source the registry replaced while
    /// its loan was open is refused (`msg.sender == MarketRegistry.flashSource()` is checked in the callback).
    // TEST-046 verifies: REQ-SWAP-013, REQ-FLASH-006, REQ-FLASH-009
    function test_TEST_046_callerMustBeRegistrySource() public {
        source.setRegistrySwitch(address(registry), makeAddr("replacementSource"));
        _repayExpect(_invalid());
        source.setRegistrySwitch(address(registry), address(source));
        vm.prank(alice);
        adapter.repayWithCollateral(proxy, _position(key), 1000e6, usdcReserveId, new uint256[](0), 0);
    }

    /// @notice Asset, amount and context mismatches are refused.
    // TEST-046 verifies: REQ-SWAP-013, REQ-SWAP-054
    function test_TEST_046_assetAmountContextBound() public {
        source.setAssetOverride(address(usdt));
        _repayExpect(_invalid());
        source.setAssetOverride(address(usdc));
        source.setAmountOverride(X + 1);
        _repayExpect(_invalid());
        source.setAmountOverride(X);
        source.setTamper(true);
        _repayExpect(_invalid());
    }

    /// @notice The measured principal: nothing forwarded (`Fr = 0`) or more than `F` forwarded is refused; less than
    /// `F` (a transfer fee) is accepted and used as the repayment.
    // TEST-046 verifies: REQ-SWAP-013, REQ-SWAP-108, REQ-FLASH-003
    function test_TEST_046_measuredPrincipalBounds() public {
        source.setForward(0);
        _repayExpect(_invalid());
        usdc.mint(address(source), 1);
        source.setForward(X + 1);
        _repayExpect(_invalid());
        source.setForward(X - 10);
        uint256 debt = _debtOf(proxy, usdcReserveId);
        vm.prank(alice);
        (uint256 repaid,) =
            adapter.repayWithCollateral(proxy, _position(key), 1000e6, usdcReserveId, new uint256[](0), 0);
        assertEq(repaid, X - 10, "Fr repaid, never F");
        assertEq(_debtOf(proxy, usdcReserveId), debt - (X - 10), "debt falls by Fr");
    }

    /// @notice A second callback in the same loan is refused (single use).
    // TEST-046 verifies: REQ-SWAP-013, REQ-SWAP-054
    function test_TEST_046_secondCallbackRefused() public {
        source.setTwice(true);
        _repayExpect(_invalid());
    }

    /// @notice A source that never calls back leaves `deleverage` reverting `InvalidFlashCallback`.
    // TEST-046 verifies: REQ-SWAP-013, REQ-SWAP-106
    function test_TEST_046_noCallbackRefused() public {
        source.setSkip(true);
        _repayExpect(_invalid());
    }

    /// @notice A charged premium above `maxFlashFeeBps × F / 10⁴` is refused in the callback even when the quote
    /// passed: `FlashFeeTooHigh`.
    // TEST-046 verifies: REQ-SWAP-013, REQ-FLASH-004, SPEC-LIQ-015
    // TEST-052 verifies: REQ-FLASH-004, SPEC-LIQ-015
    function test_TEST_052_chargedPremiumAboveCapRefused() public {
        uint256 cap = X * 10 / 10_000;
        source.setQuote(0, cap + 1);
        _repayExpect(abi.encodeWithSelector(ILPVaultSwapErrors.FlashFeeTooHigh.selector));
        source.setQuote(0, cap);
        vm.prank(alice);
        adapter.repayWithCollateral(proxy, _position(key), 1000e6, usdcReserveId, new uint256[](0), 0);
    }

    /// @notice The pre-loan quote bound and the liquidity bound use the registry's source on every call.
    // TEST-052 verifies: REQ-FLASH-002, SPEC-LIQ-015, REQ-FLASH-009
    function test_TEST_052_preLoanQuoteAndLiquidity() public {
        uint256 cap = X * 10 / 10_000;
        source.setQuote(cap + 1, 0);
        _repayExpect(abi.encodeWithSelector(ILPVaultSwapErrors.FlashFeeTooHigh.selector));
        source.setQuote(cap, 0);
        source.setAvailable(X - 1);
        _repayExpect(abi.encodeWithSelector(ILPVaultSwapErrors.FlashLiquidityShort.selector, X - 1, X));
        source.setAvailable(X);
        vm.prank(alice);
        adapter.repayWithCollateral(proxy, _position(key), 1000e6, usdcReserveId, new uint256[](0), 0);
    }
}
