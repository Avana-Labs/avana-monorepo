// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ILock} from "../../src/lock/lock/ILock.sol";
import {IAaveAdapterCollateral} from "../../src/policy/aave-adapter/IAaveAdapterCollateral.sol";
import {IAaveAdapterErrors} from "../../src/policy/aave-adapter/IAaveAdapterErrors.sol";
import {IAaveAdapterSettlement} from "../../src/policy/aave-adapter/IAaveAdapterSettlement.sol";
import {IAaveAdapterUser} from "../../src/policy/aave-adapter/IAaveAdapterUser.sol";
import {RepayWithCollateralParams} from "../../src/policy/aave-adapter/types/RepayWithCollateralParams.sol";
import {AaveAdapterFixture} from "../utils/fixtures/AaveAdapterFixture.sol";
import {LPVaultSwapMock} from "../utils/mocks/LPVaultSwapMock.sol";

/// @title AaveAdapterCallbacksFuzzTest
/// @notice The steps LPVaultSwap asks the Adapter to run, over random arguments: `deleverageRelease` runs only with
/// exactly the session's proxy, position, units and per-token minimums; `burnSeized` only for LPVaultSwap holding the
/// Lock, a factory token of the named market and a non-zero amount. Also pins the selectors LPVaultSwap and the app
/// call (REQ-ADAPTER-002).
/// forge-config: default.isolate = false
contract AaveAdapterCallbacksFuzzTest is AaveAdapterFixture {
    bytes32 internal k1;
    address internal p;
    uint128 internal constant RELEASE = 1_500_000_000;

    function setUp() public override {
        super.setUp();
        (k1, p) = _pledgeAs(alice, MARKET_ID, UNITS);
        _borrowAs(alice, MARKET_ID, debtReserveId, 5000e18);
        swap.setDeleverage(3000e18, 2e12, 0);
    }

    // TEST-239 verifies: REQ-ADAPTER-081, REQ-ADAPTER-092, PROP-072
    /// @notice A `deleverageRelease` whose proxy, integration, position key, units or minimums differ from the
    /// session reverts `NoDeleverageSession`, and the whole repay with collateral with it; the exact arguments pass.
    function testFuzz_TEST_239_releaseArgumentsMustMatch(
        uint8 which,
        address otherProxy,
        bytes32 otherKey,
        uint128 otherUnits,
        uint256 otherMin
    ) public {
        which = uint8(bound(which, 0, 5));
        address proxy = p;
        uint32 integrationId = INTEGRATION;
        bytes32 key = k1;
        uint128 units = RELEASE;
        uint256[] memory mins = _mins();
        if (which == 1) proxy = otherProxy == p ? address(1) : otherProxy;
        if (which == 2) integrationId = INTEGRATION + 1;
        if (which == 3) key = otherKey == k1 ? bytes32(uint256(1)) : otherKey;
        if (which == 4) units = otherUnits == RELEASE ? RELEASE + 1 : otherUnits;
        if (which == 5) mins[1] = otherMin == 0 ? 1 : otherMin;
        swap.setMode(LPVaultSwapMock.Mode.CustomRelease);
        swap.setCustomRelease(proxy, integrationId, key, units, mins);
        RepayWithCollateralParams memory params = _rwc(MARKET_ID, k1, RELEASE, debtReserveId);
        if (which != 0) vm.expectRevert(IAaveAdapterErrors.NoDeleverageSession.selector);
        vm.prank(alice);
        adapterC.repayWithCollateral(params);
        assertEq(_sharesOf(p, vtReserveId), which == 0 ? UNITS - RELEASE : UNITS, "units released only on a match");
    }

    // TEST-239 verifies: REQ-ADAPTER-080, REQ-ADAPTER-081
    /// @notice The borrower's own minimums travel through the session: any non-zero minimums the borrower sets are
    /// the ones the release is held to, so a release above what the unwind returns reverts in the LPVault.
    function testFuzz_TEST_239_borrowerMinimumsEnforced(
        uint256 minUsdc
    ) public {
        uint256 unwound = uint256(RELEASE) * 800_000 / 1e6;
        minUsdc = bound(minUsdc, 1, 2 * unwound);
        RepayWithCollateralParams memory params = _rwc(MARKET_ID, k1, RELEASE, debtReserveId);
        params.minAmounts[0] = minUsdc;
        if (minUsdc > unwound) vm.expectRevert();
        vm.prank(alice);
        adapterC.repayWithCollateral(params);
        assertEq(_sharesOf(p, vtReserveId), minUsdc > unwound ? UNITS : UNITS - RELEASE, "outcome");
    }

    // TEST-208 verifies: REQ-ADAPTER-070, REQ-PROXY-075, REQ-LOCK-023
    /// @notice `burnSeized` from any caller other than LPVaultSwap, or by LPVaultSwap without the Lock, reverts
    /// `NotLPVaultSwap`, whatever the market, token and amount.
    function testFuzz_TEST_208_burnSeizedCaller(
        address caller,
        uint256 marketId,
        uint256 units
    ) public {
        vm.assume(caller != address(swap));
        vm.expectRevert(IAaveAdapterErrors.NotLPVaultSwap.selector);
        vm.prank(caller);
        IAaveAdapterSettlement(adapter).burnSeized(marketId, vt, units);
        vm.expectRevert(IAaveAdapterErrors.NotLPVaultSwap.selector);
        swap.burnWithoutLock(marketId, vt, units);
    }

    // TEST-208 verifies: REQ-ADAPTER-070, REQ-PROXY-062
    /// @notice Under LPVaultSwap's Lock, `burnSeized` burns only a factory token named for its own market: any other
    /// market id reverts `UnknownMarket(marketId)`, and 0 units `ZeroAmount`.
    function testFuzz_TEST_208_burnSeizedMarketAndAmount(
        uint256 marketId,
        uint256 units
    ) public {
        _borrowAs(alice, MARKET_ID, debtReserveId, 10_000e18);
        vtPrice.set(1.5e8);
        uint256 seized = swap.seizeAndKeep(aave.cdpSpoke, vt, vtReserveId, debtReserveId, p, 1000e18);
        units = bound(units, 0, seized);
        if (marketId != MARKET_ID) {
            vm.expectRevert(abi.encodeWithSelector(IAaveAdapterErrors.UnknownMarket.selector, marketId));
        } else if (units == 0) {
            vm.expectRevert(IAaveAdapterErrors.ZeroAmount.selector);
        }
        swap.burnUnderLock(marketId, vt, units);
        bool burned = marketId == MARKET_ID && units != 0;
        assertEq(token.balanceOf(address(swap)), burned ? seized - units : seized, "LPVaultSwap balance");
    }

    // TEST-060 verifies: REQ-ADAPTER-081, REQ-LOCK-023
    /// @notice The callbacks refuse every caller but LPVaultSwap while the Adapter holds the Lock, whatever the
    /// arguments.
    function testFuzz_TEST_060_callbacksRefuseOutsiders(
        address caller,
        address proxy,
        uint256 reserveId,
        uint256 amount
    ) public {
        vm.assume(caller != address(swap));
        vm.mockCall(address(lock), abi.encodeCall(ILock.holder, ()), abi.encode(adapter));
        vm.expectRevert(IAaveAdapterErrors.NotLPVaultSwap.selector);
        vm.prank(caller);
        IAaveAdapterSettlement(adapter).deleverageRepay(proxy, reserveId, amount);
        vm.expectRevert(IAaveAdapterErrors.NotLPVaultSwap.selector);
        vm.prank(caller);
        IAaveAdapterSettlement(adapter).deleverageRelease(proxy, _ref(k1), RELEASE, _mins());
        // LPVaultSwap itself, with no session open, is refused by the session check.
        vm.expectRevert(IAaveAdapterErrors.NoDeleverageSession.selector);
        vm.prank(address(swap));
        IAaveAdapterSettlement(adapter).deleverageRepay(proxy, reserveId, amount);
    }

    // TEST-031 verifies: REQ-ADAPTER-002, REQ-PROXY-025
    // Sources: 2.6 REQ-ADAPTER-002 (selectors, argument order and meaning kept across upgrades)
    /// @notice The selectors the app and LPVaultSwap call are those of their written signatures: a change of any
    /// signature changes the selector this test pins.
    function test_TEST_031_entryPointSelectorsPinned() public pure {
        assertEq(
            IAaveAdapterUser.pledge.selector, bytes4(keccak256("pledge(uint256,(uint32,bytes32),uint256)")), "pledge"
        );
        assertEq(
            IAaveAdapterUser.borrow.selector,
            bytes4(keccak256("borrow(uint256,uint256,uint256,address,uint256,uint256,uint256)")),
            "borrow"
        );
        assertEq(
            IAaveAdapterUser.repay.selector,
            bytes4(keccak256("repay(address,uint256,uint256,uint256,bool,uint256)")),
            "repay"
        );
        assertEq(
            IAaveAdapterUser.withdraw.selector,
            bytes4(keccak256("withdraw(uint256,(uint32,bytes32),uint256,uint256,uint256)")),
            "withdraw"
        );
        assertEq(
            IAaveAdapterUser.repayAllAndWithdraw.selector,
            bytes4(keccak256("repayAllAndWithdraw(uint256,(uint32,bytes32),uint256,uint256[],uint256[],uint256)")),
            "repayAllAndWithdraw"
        );
        assertEq(
            IAaveAdapterUser.collectFees.selector,
            bytes4(keccak256("collectFees(uint256,(uint32,bytes32),uint256)")),
            "collectFees"
        );
        assertEq(
            IAaveAdapterUser.releaseZeroCredit.selector,
            bytes4(keccak256("releaseZeroCredit(uint256,(uint32,bytes32),uint256)")),
            "releaseZeroCredit"
        );
        assertEq(
            IAaveAdapterCollateral.removeLiquidity.selector,
            bytes4(keccak256("removeLiquidity(uint256,(uint32,bytes32),uint128,uint256[],uint256,uint256)")),
            "removeLiquidity"
        );
        assertEq(
            IAaveAdapterCollateral.recredit.selector,
            bytes4(keccak256("recredit(uint256,(uint32,bytes32),bytes,uint256)")),
            "recredit"
        );
        assertEq(
            IAaveAdapterCollateral.repayWithCollateral.selector,
            bytes4(
                keccak256(
                    "repayWithCollateral((uint256,(uint32,bytes32),uint128,uint256,uint256[],uint256,uint256,uint256))"
                )
            ),
            "repayWithCollateral"
        );
        assertEq(
            IAaveAdapterSettlement.burnSeized.selector,
            bytes4(keccak256("burnSeized(uint256,address,uint256)")),
            "burnSeized"
        );
        assertEq(
            IAaveAdapterSettlement.deleverageRepay.selector,
            bytes4(keccak256("deleverageRepay(address,uint256,uint256)")),
            "deleverageRepay"
        );
        assertEq(
            IAaveAdapterSettlement.deleverageRelease.selector,
            bytes4(keccak256("deleverageRelease(address,(uint32,bytes32),uint128,uint256[])")),
            "deleverageRelease"
        );
    }
}
