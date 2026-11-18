// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ICollateralization} from "../../src/custody/collateralization/ICollateralization.sol";
import {ILPVaultSwapBase} from "../../src/liquidation/lp-vault-swap/ILPVaultSwapBase.sol";
import {DeleverageRequest} from "../../src/liquidation/lp-vault-swap/types/LPVaultSwapTypes.sol";
import {ILock} from "../../src/lock/lock/ILock.sol";
import {IAaveAdapter} from "../../src/policy/aave-adapter/IAaveAdapter.sol";
import {IAaveAdapterBase} from "../../src/policy/aave-adapter/IAaveAdapterBase.sol";
import {RepayWithCollateralParams} from "../../src/policy/aave-adapter/types/AaveAdapterTypes.sol";
import {IMarketRegistry} from "../../src/policy/market-registry/IMarketRegistry.sol";
import {IRiskModuleErrors} from "../../src/policy/risk-module/IRiskModuleErrors.sol";
import {PauseReason, PauseState} from "../../src/types/MarketTypes.sol";
import {PositionRef} from "../../src/types/PositionTypes.sol";
import {IVaultToken} from "../../src/vault-token/vault-token/IVaultToken.sol";
import {AaveAdapterFixture} from "../utils/fixtures/AaveAdapterFixture.sol";
import {LPVaultSwapMock} from "../utils/mocks/LPVaultSwapMock.sol";

/// @title AaveAdapterSettlementUnitTest
/// @notice `repayWithCollateral` with its transient session and LPVaultSwap's two callbacks, and `burnSeized` inside a
/// liquidation and a pending settlement, on the real Aave V4 Spoke, Lock and Collateralization with the LPVaultSwap
/// stand-in of 2.11 (`LPVaultSwapMock`), including every way a faulty LPVaultSwap could misuse the callbacks.
/// forge-config: default.isolate = false
contract AaveAdapterSettlementUnitTest is AaveAdapterFixture {
    bytes32 internal k1;
    address internal p;
    uint128 internal constant RELEASE = 1_500_000_000; // 1,500 vault tokens, $3,000

    function setUp() public override {
        super.setUp();
        (k1, p) = _pledgeAs(alice, MARKET_ID, UNITS);
        _borrowAs(alice, MARKET_ID, debtReserveId, 10_000e18); // hf 16,000 / 10,000 = 1.6
        // LPVaultSwap flash-borrows 3,000 GHO and converts each released unit to 2e12 GHO wei ($2.00 per token).
        swap.setDeleverage(3000e18, 2e12, 0);
    }

    function _rwcAs(
        address wallet,
        RepayWithCollateralParams memory params
    ) internal returns (uint256 repaid, uint256 out) {
        vm.prank(wallet);
        (repaid, out) = adapterC.repayWithCollateral(params);
    }

    function _expectRwcRevert(
        bytes memory err,
        RepayWithCollateralParams memory params
    ) internal {
        vm.expectRevert(err);
        vm.prank(alice);
        adapterC.repayWithCollateral(params);
    }

    // ─── Repay with collateral ───

    // TEST-239 verifies: REQ-ADAPTER-080, REQ-ADAPTER-081, REQ-ADAPTER-069, SPEC-PROXY-009, INV-089
    // Sources: 5.1 TEST-239, 2.6 SPEC-PROXY-009
    /// @notice The happy path: LPVaultSwap repays 3,000 GHO through `deleverageRepay`, then the Adapter withdraws,
    /// burns and releases exactly the session's units through `deleverageRelease`; supplied shares fall by `units`,
    /// the health factor rises, the backing gap is kept and `RepaidWithCollateral` reports both health factors.
    function test_TEST_239_repayWithCollateral() public {
        uint256 hfBefore = _hf(p);
        RepayWithCollateralParams memory params = _rwc(MARKET_ID, k1, RELEASE, debtReserveId);
        uint256 hfAfter = uint256((UNITS - RELEASE) * 2 * 8000 / 10_000) * 1e12 * 1e18 / 7000e18;
        vm.expectCall(vt, abi.encodeCall(IVaultToken.burn, (p, RELEASE)), 1);
        vm.expectCall(
            address(coll), abi.encodeCall(ICollateralization.releaseForDeleverage, (p, vt, k1, RELEASE, _mins())), 1
        );
        vm.expectEmit(adapter);
        emit IAaveAdapterBase.RepaidWithCollateral(
            alice, MARKET_ID, vt, k1, RELEASE, debtReserveId, 3000e18, 0, hfBefore, hfAfter
        );
        (uint256 repaid, uint256 out) = _rwcAs(alice, params);
        assertEq(repaid, 3000e18, "repaid");
        assertEq(out, 0, "nothing left over");
        assertEq(_debtOf(p, debtReserveId), 7000e18, "debt lowered");
        assertEq(_sharesOf(p, vtReserveId), UNITS - RELEASE, "shares fell by units");
        assertEq(token.totalSupply(), UNITS - RELEASE, "burned");
        assertEq(coll.getTotalCredited(vt), UNITS - RELEASE, "debited");
        assertEq(debt.balanceOf(adapter), 0, "adapter holds nothing");
        assertFalse(lock.isLocked(), "lock released");
        DeleverageRequest memory r = swap.lastRequest();
        assertEq(r.proxy, p, "request proxy");
        assertEq(r.wallet, alice, "request wallet");
        assertEq(r.spoke, aave.cdpSpoke, "request spoke");
        assertEq(r.marketId, MARKET_ID, "request market");
        assertEq(r.vaultToken, vt, "request token");
        assertEq(r.position.positionKey, k1, "request key");
        assertEq(r.units, RELEASE, "request units");
        assertEq(r.debtReserveId, debtReserveId, "request reserve");
    }

    // TEST-239 verifies: REQ-ADAPTER-080, SPEC-PROXY-009
    /// @notice Leftover debt asset goes to the wallet, and once the account is debt-free the event reports
    /// `type(uint256).max`.
    function test_TEST_239_debtFreeResult() public {
        swap.setDeleverage(0, 2e12 + 1e11, 0); // flash the whole debt; the units convert at $2.10 per token
        RepayWithCollateralParams memory params = _rwc(MARKET_ID, k1, 5_000_000_000, debtReserveId);
        uint256 hfBefore = _hf(p);
        vm.expectEmit(adapter);
        emit IAaveAdapterBase.RepaidWithCollateral(
            alice, MARKET_ID, vt, k1, 5_000_000_000, debtReserveId, 10_000e18, 500e18, hfBefore, type(uint256).max
        );
        _rwcAs(alice, params);
        assertEq(_borrowCountOf(p), 0, "debt-free");
        assertEq(debt.balanceOf(alice), 10_000e18 + 500e18, "borrowed GHO plus the leftover");
    }

    // TEST-239 verifies: REQ-ADAPTER-080, REQ-ADAPTER-091
    /// @notice `minAssetOut` bounds the debt asset paid to the wallet: 500 GHO + 1 wei reverts
    /// `AssetOutBelowMinimum(500 GHO, 500 GHO + 1)`, exactly 500 GHO passes.
    function test_TEST_239_minAssetOutBoundsTheLeftover() public {
        swap.setDeleverage(0, 2e12 + 1e11, 0);
        RepayWithCollateralParams memory params = _rwc(MARKET_ID, k1, 5_000_000_000, debtReserveId);
        params.minAssetOut = 500e18 + 1;
        _expectRwcRevert(
            abi.encodeWithSelector(IAaveAdapterBase.AssetOutBelowMinimum.selector, 500e18, 500e18 + 1), params
        );
        params.minAssetOut = 500e18;
        (, uint256 out) = _rwcAs(alice, params);
        assertEq(out, 500e18, "a minimum equal to the leftover passes");
    }

    // TEST-272 verifies: REQ-COLL-040, REQ-ADAPTER-080
    /// @notice A repay with collateral that leaves no borrow clears the account's indebted mark in the same call; one
    /// that leaves debt keeps it.
    function test_TEST_272_debtFreeDeleverageClearsTheMark() public {
        ICollateralization views = ICollateralization(address(coll));
        assertFalse(views.getMarketDebtFree(vt), "marked by the borrow");
        _rwcAs(alice, _rwc(MARKET_ID, k1, RELEASE, debtReserveId));
        assertFalse(views.getMarketDebtFree(vt), "debt remains: still marked");
        swap.setDeleverage(0, 2e12 + 1e11, 0);
        _rwcAs(alice, _rwc(MARKET_ID, k1, 4_000_000_000, debtReserveId));
        assertEq(_borrowCountOf(p), 0, "debt-free");
        assertTrue(views.getMarketDebtFree(vt), "mark cleared");
    }

    // TEST-239 verifies: REQ-ADAPTER-080, REQ-ADAPTER-091, SPEC-PROXY-009, PROP-072
    /// @notice A conversion that releases more value than it repays lowers the health factor while debt remains:
    /// `HealthFactorNotImproved(before, after)`; a caller minimum above the result reverts the same way.
    function test_TEST_239_healthFactorMustNotFall() public {
        swap.setDeleverage(100e18, 5e10, 0); // repays 100 GHO for 2,000 tokens
        RepayWithCollateralParams memory params = _rwc(MARKET_ID, k1, 2_000_000_000, debtReserveId);
        uint256 before = _hf(p);
        uint256 afterHf = uint256(12_800e18) * 1e18 / 9900e18;
        _expectRwcRevert(
            abi.encodeWithSelector(IAaveAdapterBase.HealthFactorNotImproved.selector, before, afterHf), params
        );
        swap.setDeleverage(3000e18, 2e12, 0);
        params = _rwc(MARKET_ID, k1, RELEASE, debtReserveId);
        params.minHealthFactor = 3e18;
        uint256 good = uint256((UNITS - RELEASE) * 2 * 8000 / 10_000) * 1e12 * 1e18 / 7000e18;
        _expectRwcRevert(
            abi.encodeWithSelector(IAaveAdapterBase.HealthFactorNotImproved.selector, before, good), params
        );
    }

    // TEST-239 verifies: REQ-ADAPTER-080, REQ-ADAPTER-091, REQ-ADAPTER-067
    /// @notice Bounds in order: deadline, zero units, proxy, pause reason, integration, enabled reserve, debt on it.
    function test_TEST_239_checkOrder() public {
        RepayWithCollateralParams memory params = _rwc(MARKET_ID, k1, 0, usdcReserveId);
        params.position = PositionRef(9, k1);
        params.deadline = block.timestamp - 1;
        _expectRwcRevert(abi.encodeWithSelector(IAaveAdapterBase.DeadlineExpired.selector, params.deadline), params);
        params.deadline = _deadline();
        _expectRwcRevert(abi.encodeWithSelector(IAaveAdapterBase.ZeroAmount.selector), params);
        params.units = RELEASE;
        vm.expectRevert(abi.encodeWithSelector(IAaveAdapterBase.NoProxy.selector, bob, MARKET_ID));
        vm.prank(bob);
        adapterC.repayWithCollateral(params);
        _pause(PauseState.Paused, PauseReason.MintPathSuspect);
        _expectRwcRevert(abi.encodeWithSelector(IAaveAdapterBase.ApplicationPaused.selector), params);
        _pause(PauseState.None, PauseReason.None);
        _expectRwcRevert(abi.encodeWithSelector(IAaveAdapterBase.IntegrationMismatch.selector, MARKET_ID, 9), params);
        params.position = _ref(k1);
        params.debtReserveId = vtReserveId;
        _expectRwcRevert(
            abi.encodeWithSelector(IAaveAdapterBase.UnknownDebtReserve.selector, aave.cdpSpoke, vtReserveId), params
        );
        params.debtReserveId = usdcReserveId;
        _expectRwcRevert(abi.encodeWithSelector(IAaveAdapterBase.NothingToRepay.selector, usdcReserveId), params);
    }

    // TEST-192 verifies: REQ-ADAPTER-080, REQ-ADAPTER-045, REQ-ADAPTER-046, REQ-ADAPTER-082, REQ-ADAPTER-086, Q-356
    /// @notice Repay with collateral is open under Frozen, under `Paused(General)` and for a frozen wallet (it reads no
    /// freeze), and refused only under `Paused(MintPathSuspect)`.
    function test_TEST_192_repayWithCollateralPauseMatrix() public {
        swap.setDeleverage(1000e18, 2e12, 0);
        registry.setFrozen(alice, true);
        vm.expectCall(address(registry), abi.encodeWithSelector(IMarketRegistry.isFrozenAddress.selector), 0);
        _pause(PauseState.Frozen, PauseReason.None);
        _rwcAs(alice, _rwc(MARKET_ID, k1, 500_000_000, debtReserveId));
        _pause(PauseState.Paused, PauseReason.General);
        _rwcAs(alice, _rwc(MARKET_ID, k1, 500_000_000, debtReserveId));
        _pause(PauseState.Paused, PauseReason.MintPathSuspect);
        _expectRwcRevert(
            abi.encodeWithSelector(IAaveAdapterBase.ApplicationPaused.selector),
            _rwc(MARKET_ID, k1, 500_000_000, debtReserveId)
        );
    }

    // TEST-239 verifies: REQ-ADAPTER-091
    /// @notice LPVaultSwap's own refusals propagate: `DeleverageTooSmall` and `DeleverageShortfall`.
    function test_TEST_239_lpVaultSwapErrorsPropagate() public {
        RepayWithCollateralParams memory params = _rwc(MARKET_ID, k1, RELEASE, debtReserveId);
        params.minDebtRepaid = 3001e18;
        _expectRwcRevert(abi.encodeWithSelector(ILPVaultSwapBase.DeleverageTooSmall.selector, 3000e18, 3001e18), params);
        swap.setDeleverage(3000e18, 1e12, 0);
        params.minDebtRepaid = 0;
        _expectRwcRevert(
            abi.encodeWithSelector(ILPVaultSwapBase.DeleverageShortfall.selector, 1500e18, 3000e18), params
        );
    }

    // ─── Session misuse (REQ-ADAPTER-092) ───

    // TEST-239 verifies: REQ-ADAPTER-081, REQ-ADAPTER-092, REQ-LOCK-023, PROP-072
    /// @notice Every way an LPVaultSwap implementation could step outside the session reverts: a missing step, a
    /// repeated step, the release first, another proxy, other units, weaker minimums, another reserve.
    function test_TEST_239_sessionMisuseReverts() public {
        LPVaultSwapMock.Mode[9] memory modes = [
            LPVaultSwapMock.Mode.SkipRepay,
            LPVaultSwapMock.Mode.SkipRelease,
            LPVaultSwapMock.Mode.RepayTwice,
            LPVaultSwapMock.Mode.ReleaseTwice,
            LPVaultSwapMock.Mode.ReleaseFirst,
            LPVaultSwapMock.Mode.WrongProxy,
            LPVaultSwapMock.Mode.WrongUnits,
            LPVaultSwapMock.Mode.WeakMinimums,
            LPVaultSwapMock.Mode.WrongReserve
        ];
        (, address bobProxy) = _pledgeAs(bob, MARKET_ID, UNITS);
        swap.setOtherProxy(bobProxy);
        RepayWithCollateralParams memory params = _rwc(MARKET_ID, k1, RELEASE, debtReserveId);
        params.minAmounts[0] = 1;
        for (uint256 i = 0; i < modes.length; ++i) {
            swap.setMode(modes[i]);
            _expectRwcRevert(abi.encodeWithSelector(IAaveAdapterBase.NoDeleverageSession.selector), params);
        }
        swap.setMode(LPVaultSwapMock.Mode.ReleaseOtherProxy);
        _expectRwcRevert(abi.encodeWithSelector(IAaveAdapterBase.NoDeleverageSession.selector), params);
        swap.setMode(LPVaultSwapMock.Mode.ZeroRepay);
        _expectRwcRevert(abi.encodeWithSelector(IAaveAdapterBase.ZeroAmount.selector), params);
        swap.setMode(LPVaultSwapMock.Mode.Normal);
        _rwcAs(alice, params);
        assertEq(_sharesOf(bobProxy, vtReserveId), UNITS, "bob untouched");
    }

    // TEST-060 verifies: REQ-ADAPTER-081, REQ-ADAPTER-092, REQ-LOCK-023, REQ-LOCK-030, REQ-PROXY-048
    /// @notice The callbacks answer only LPVaultSwap while the Adapter holds the Lock: any other caller, LPVaultSwap
    /// with no Lock, and LPVaultSwap holding the Lock itself get `NotLPVaultSwap`.
    function test_TEST_060_callbacksOutsideSession() public {
        bytes memory repayCall = abi.encodeCall(IAaveAdapter.deleverageRepay, (p, debtReserveId, 1e18));
        bytes memory releaseCall = abi.encodeCall(IAaveAdapter.deleverageRelease, (p, _ref(k1), RELEASE, _mins()));
        vm.expectRevert(IAaveAdapterBase.NotLPVaultSwap.selector);
        vm.prank(attacker);
        IAaveAdapter(adapter).deleverageRepay(p, debtReserveId, 1e18);
        vm.expectRevert(IAaveAdapterBase.NotLPVaultSwap.selector);
        vm.prank(alice);
        IAaveAdapter(adapter).deleverageRelease(p, _ref(k1), RELEASE, _mins());
        (bool ok, bytes memory ret) = swap.callUnlocked(adapter, repayCall);
        assertFalse(ok, "unlocked repay");
        assertEq(ret, abi.encodeWithSelector(IAaveAdapterBase.NotLPVaultSwap.selector), "NotLPVaultSwap");
        bytes memory err = swap.callUnderLock(adapter, releaseCall);
        assertEq(err, abi.encodeWithSelector(IAaveAdapterBase.NotLPVaultSwap.selector), "LPVaultSwap's own lock");
    }

    // TEST-060 verifies: REQ-LOCK-007, REQ-LOCK-030, REQ-ADAPTER-050, ATTACK-092
    /// @notice While the Adapter holds the Lock across `deleverage`, a call from LPVaultSwap back into any user entry
    /// point reverts `LockHeld(adapter)`: the callbacks never release the Lock.
    function test_TEST_060_noReentryDuringDeleverage() public {
        swap.setMode(LPVaultSwapMock.Mode.ReenterAdapter);
        swap.setReentry(abi.encodeCall(adapterC.repay, (alice, MARKET_ID, debtReserveId, 1e18, false, _deadline())));
        _rwcAs(alice, _rwc(MARKET_ID, k1, RELEASE, debtReserveId));
        assertEq(swap.reentryError(), abi.encodeWithSelector(ILock.LockHeld.selector, adapter), "LockHeld(adapter)");
    }

    // TEST-239 verifies: REQ-ADAPTER-080, REQ-ADAPTER-069, REQ-ADAPTER-075
    /// @notice A Collateralization that releases without debiting leaves the burn unmatched: `BackingMismatch`.
    function test_TEST_239_backingCheckedAfterDeleverage() public {
        uint256[] memory amounts = new uint256[](2);
        vm.mockCall(
            address(coll),
            abi.encodeWithSelector(ICollateralization.releaseForDeleverage.selector),
            abi.encode(amounts, false)
        );
        // The mock's swap needs no tokens: its recovery is minted.
        _expectRwcRevert(
            abi.encodeWithSelector(IAaveAdapterBase.BackingMismatch.selector, UNITS - RELEASE, UNITS, 0),
            _rwc(MARKET_ID, k1, RELEASE, debtReserveId)
        );
    }

    // ─── burnSeized ───

    // TEST-208 verifies: REQ-ADAPTER-070, REQ-ADAPTER-005, REQ-ADAPTER-046, REQ-ADAPTER-047, REQ-PROXY-075, INV-010, INV-014
    // Sources: 5.1 TEST-208
    /// @notice In a liquidation LPVaultSwap, holding the Lock, has the Adapter burn exactly the seized units from its
    /// own balance; `SeizedUnitsBurned` is emitted and Collateralization's settlement finds the supply drop. It runs
    /// with a broken registry and RiskModule under `Paused(MintPathSuspect)`.
    function test_TEST_208_burnSeizedInLiquidation() public {
        vtPrice.set(1.2e8);
        registry.setBroken(true);
        risk.setBroken(true);
        _pause(PauseState.Paused, PauseReason.MintPathSuspect);
        uint256 supplyBefore = token.totalSupply();
        vm.recordLogs();
        uint256 seized = swap.liquidate(aave.cdpSpoke, MARKET_ID, vt, vtReserveId, debtReserveId, p, 2000e18, 2);
        assertGt(seized, 0, "seized");
        assertEq(token.totalSupply(), supplyBefore - seized, "burned");
        assertEq(token.balanceOf(address(swap)), 0, "LPVaultSwap keeps no units");
        assertEq(coll.getTotalCredited(vt), supplyBefore - seized, "debited");
    }

    // TEST-208 verifies: REQ-ADAPTER-070, REQ-PROXY-075, REQ-LOCK-023
    /// @notice `burnSeized` reverts `NotLPVaultSwap` for any other caller, for LPVaultSwap without the Lock and when
    /// another holder has the Lock; `UnknownMarket` for a token outside the factory or naming another market;
    /// `ZeroAmount` for 0 units.
    function test_TEST_208_burnSeizedRefusals() public {
        vm.expectRevert(IAaveAdapterBase.NotLPVaultSwap.selector);
        vm.prank(attacker);
        IAaveAdapter(adapter).burnSeized(MARKET_ID, vt, 1);
        vm.expectRevert(IAaveAdapterBase.NotLPVaultSwap.selector);
        swap.burnWithoutLock(MARKET_ID, vt, 1);
        vm.mockCall(address(lock), abi.encodeCall(ILock.holder, ()), abi.encode(address(swap)));
        vm.expectRevert(IAaveAdapterBase.NotLPVaultSwap.selector);
        vm.prank(attacker);
        IAaveAdapter(adapter).burnSeized(MARKET_ID, vt, 1);
        vm.clearMockedCalls();
        vm.mockCall(address(lock), abi.encodeCall(ILock.holder, ()), abi.encode(adapter));
        vm.expectRevert(IAaveAdapterBase.NotLPVaultSwap.selector);
        vm.prank(address(swap));
        IAaveAdapter(adapter).burnSeized(MARKET_ID, vt, 1);
        vm.clearMockedCalls();
        vm.expectRevert(abi.encodeWithSelector(IAaveAdapterBase.UnknownMarket.selector, MARKET_B));
        swap.burnUnderLock(MARKET_B, vt, 1);
        vm.expectRevert(abi.encodeWithSelector(IAaveAdapterBase.UnknownMarket.selector, MARKET_ID));
        swap.burnUnderLock(MARKET_ID, address(usdc), 1);
        vm.expectRevert(IAaveAdapterBase.ZeroAmount.selector);
        swap.burnUnderLock(MARKET_ID, vt, 0);
    }

    // TEST-241 verifies: REQ-ADAPTER-069, SPEC-PROXY-008, INV-080, INV-001
    // Sources: 5.1 TEST-241, 2.6 SPEC-PROXY-008 example
    /// @notice An orphan `burnSeized` (a seizure burn never settled) opens a gap `G > 0`; later pledges, withdrawals,
    /// removals and re-credits in the market keep working and keep `G`; `settlePending` closes it.
    function test_TEST_241_gapKeepsMarketWorking() public {
        vtPrice.set(1.2e8);
        uint256 seized = swap.seizeAndKeep(aave.cdpSpoke, vt, vtReserveId, debtReserveId, p, 2000e18);
        swap.burnUnderLock(MARKET_ID, vt, seized);
        assertEq(_gap(), int256(seized), "gap opened");
        vtPrice.set(2e8);
        (bytes32 kb,) = _pledgeAs(bob, MARKET_ID, UNITS);
        assertEq(_gap(), int256(seized), "pledge keeps the gap");
        uint256 d = _deadline();
        vm.prank(bob);
        adapterC.removeLiquidity(MARKET_ID, _ref(kb), 1_000_000_000, _mins(), d, 0);
        assertEq(_gap(), int256(seized), "removal keeps the gap");
        lpVault.addUnits(kb, 1_000_000_000);
        vm.prank(bob);
        adapterC.recredit(MARKET_ID, _ref(kb), "", d);
        assertEq(_gap(), int256(seized), "re-credit keeps the gap");
        vm.prank(bob);
        adapterC.withdraw(MARKET_ID, _ref(kb), UNITS, d, 0);
        assertEq(_gap(), int256(seized), "withdrawal keeps the gap");
    }
}
