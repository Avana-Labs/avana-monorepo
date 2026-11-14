// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {DebtPriceView} from "../../src/lens/lens/types/DebtPriceView.sol";
import {LiquidationPreview} from "../../src/lens/lens/types/LiquidationPreview.sol";
import {ILPVaultSwapErrors} from "../../src/liquidation/lp-vault-swap/ILPVaultSwapErrors.sol";
import {DebtReserveDef} from "../../src/policy/market-registry/types/DebtReserveDef.sol";
import {IRiskModuleErrors} from "../../src/policy/risk-module/IRiskModuleErrors.sol";
import {DriftReason} from "../../src/types/DriftReason.sol";
import {PriceState} from "../../src/types/PriceState.sol";
import {IntegrationFlows} from "../utils/fixtures/IntegrationFlows.sol";

/// @title LensPriceGatesIntegrationTest
/// @notice The Lens's debt-price gates against the real RiskModule, AaveAdapter and LPVaultSwap. `previewBorrowMax`
/// applies the RiskModule's debt-price rule to the reserve being borrowed, not only to the reserves the account
/// already owes on; and the Lens measures a debt price's age as execution does: the borrow side on the served route's
/// timestamp against the DebtOracle's `borrowPriceMaxAge()`, the liquidation side on each leg's timestamp against the
/// ParameterStore's `liquidationPriceMaxAge(feed)`, both bounds inclusive (age == max passes, max + 1 fails). The rest
/// of the RiskModule's gates of a reserve not yet owed (its routes, its record) follow the borrow as well.
/// @dev Alice: 10,000 vault tokens at $2.10 and no debt, so USDC is not yet in her RiskModule scope.
/// forge-config: default.isolate = false
contract LensPriceGatesIntegrationTest is IntegrationFlows {
    uint32 internal constant LIQ_AGE = 4200;

    address internal proxy;

    function setUp() public {
        _deployIntegration();
        (proxy,) = _openAccount(alice, MARKET_ID, 10_000e6, 0, P_VAULT);
    }

    function _previewUsdc() internal view returns (uint256) {
        return lens.previewBorrowMax(alice, MARKET_ID, usdcReserveId, _deadline());
    }

    /// @dev Alice borrows `amount` USDC, expecting `err` when it is not empty.
    function _borrowUsdc(
        uint256 amount,
        bytes memory err
    ) internal {
        uint256 nonce = adapterC.borrowNonce(proxy);
        uint256 deadline = _deadline();
        if (err.length != 0) vm.expectRevert(err);
        vm.prank(alice);
        adapterC.borrow(MARKET_ID, usdcReserveId, amount, alice, deadline, 0, nonce);
    }

    function _tooOld(
        uint256 age
    ) internal view returns (bytes memory) {
        return
            abi.encodeWithSelector(IRiskModuleErrors.DebtPriceTooOld.selector, usdcReserveId, address(usdcOracle), age);
    }

    /// @dev Both swap routes of `token` into `asset` usable or not.
    function _setRoutes(
        address token,
        address asset,
        bool usable
    ) internal {
        reg.setRouteUsable(MARKET_ID, token, asset, 0, usable);
        reg.setRouteUsable(MARKET_ID, token, asset, 1, usable);
    }

    function _borrowAllowed() internal view returns (bool) {
        return rm.getAccountGateStatus(proxy).borrowAllowed;
    }

    function _debtView() internal view returns (DebtPriceView memory) {
        return lens.getDebtPriceState(_spokeOf(proxy), usdcReserveId);
    }

    // TEST-247 verifies: REQ-LENS-035, REQ-LENS-044, REQ-RISK-061, REQ-ADAPTER-038
    /// @notice A stale, borrow-closed or not-Live USDC price: `previewBorrowMax` and `previewBorrowRecommended` return
    /// 0 exactly when the borrow reverts `DebtPriceTooOld`, and the previewed maximum executes once the price is fresh.
    function test_TEST_247_borrowMaxAppliesTheBorrowedReservesDebtPrice() public {
        assertGt(_previewUsdc(), 0, "open with a fresh USDC price");
        usdcOracle.setReport(PriceState.Live, uint64(block.timestamp - FEED_AGE - 1), true);
        assertEq(_previewUsdc(), 0, "stale: the preview refuses");
        (uint256 rec, uint256 max) = lens.previewBorrowRecommended(alice, MARKET_ID, usdcReserveId, _deadline());
        assertEq(rec + max, 0, "the recommended borrow too");
        _borrowUsdc(1e6, _tooOld(FEED_AGE + 1));
        usdcOracle.setReport(PriceState.Live, uint64(block.timestamp), false);
        assertEq(_previewUsdc(), 0, "the oracle's own borrow gate closed: the preview refuses");
        _borrowUsdc(1e6, _tooOld(0));
        usdcOracle.setReport(PriceState.Cached, uint64(block.timestamp), true);
        assertEq(_previewUsdc(), 0, "not Live: the preview refuses");
        _borrowUsdc(1e6, _tooOld(0));
        usdcOracle.setReport(PriceState.Live, uint64(block.timestamp), true);
        uint256 amount = _previewUsdc();
        assertGt(amount, 0, "fresh again");
        _borrowUsdc(amount, "");
        assertEq(_debtOf(proxy, usdcReserveId), amount, "the previewed maximum executes");
    }

    // TEST-247 verifies: REQ-LENS-030, REQ-LENS-035, REQ-RISK-061
    /// @notice Borrow side at the boundary: a served route aged exactly `borrowPriceMaxAge()` is fresh for the Lens and
    /// borrows; one second older is stale for both.
    function test_TEST_247_debtBorrowAgeBoundaryMatchesExecution() public {
        uint32 maxAge = usdcOracle.borrowPriceMaxAge();
        usdcOracle.setReport(PriceState.Live, uint64(block.timestamp - maxAge - 1), true);
        DebtPriceView memory v = _debtView();
        assertEq(v.age, uint256(maxAge) + 1, "the served route's age");
        assertFalse(v.borrowFresh, "max + 1: stale");
        assertEq(_previewUsdc(), 0, "max + 1: no borrow");
        _borrowUsdc(1e6, _tooOld(uint256(maxAge) + 1));
        usdcOracle.setReport(PriceState.Live, uint64(block.timestamp - maxAge), true);
        v = _debtView();
        assertEq(v.age, maxAge, "aged exactly the maximum");
        assertTrue(v.borrowFresh, "max: fresh");
        assertGt(_previewUsdc(), 0, "max: borrowable");
        _borrowUsdc(1e6, "");
    }

    // TEST-247 verifies: REQ-LENS-030, REQ-RISK-061
    /// @notice The accepted price's stored timestamp only moves on a poke; execution reads the served route's live
    /// timestamp. A fresh route behind an old accepted timestamp is fresh for both, and a route timestamp in the future
    /// is refused by the RiskModule and reported closed to borrowing (LPVaultSwap counts it age 0).
    function test_TEST_247_debtAgeIsTheServedRoutesNotTheAcceptedPrices() public {
        usdcOracle.setLeg(uint64(block.timestamp - 60));
        usdcOracle.setAcceptedAt(uint64(block.timestamp - FEED_AGE - 500));
        DebtPriceView memory v = _debtView();
        assertEq(v.age, 60, "the served route's age");
        assertTrue(v.borrowFresh && v.liquidationFresh, "fresh, as execution sees it");
        assertGt(_previewUsdc(), 0, "borrowable");
        _borrowUsdc(1e6, "");
        usdcOracle.setLeg(uint64(block.timestamp + 5));
        v = _debtView();
        assertFalse(v.borrowFresh, "a timestamp in the future: the RiskModule refuses");
        assertTrue(v.liquidationFresh, "LPVaultSwap counts it age 0");
        assertEq(_previewUsdc(), 0, "no borrow");
        _borrowUsdc(1e6, _tooOld(0));
    }

    // TEST-247 verifies: REQ-LENS-030, REQ-LENS-016, REQ-SWAP-091
    /// @notice Liquidation side at the boundary: a leg aged exactly its `liquidationPriceMaxAge` is fresh for the
    /// Lens and `liquidate` runs; one second older is stale for both (`DebtPriceStale`).
    function test_TEST_247_debtLiquidationAgeBoundaryMatchesExecution() public {
        (address bobProxy,) = _bobAccount();
        store.setLiquidationPriceMaxAge(feedUsdcDebt, LIQ_AGE);
        usdcOracle.setLeg(uint64(block.timestamp - LIQ_AGE - 1));
        LiquidationPreview memory p = lens.previewLiquidation(bobProxy, usdcReserveId, block.timestamp + 120);
        assertFalse(p.debtPriceFresh, "max + 1: stale");
        _fundCaller(keeper, p.params);
        vm.expectRevert(abi.encodeWithSelector(ILPVaultSwapErrors.DebtPriceStale.selector, usdcReserveId));
        vm.prank(keeper);
        lvs.liquidate(p.params);
        usdcOracle.setLeg(uint64(block.timestamp - LIQ_AGE));
        p = lens.previewLiquidation(bobProxy, usdcReserveId, block.timestamp + 120);
        assertTrue(p.debtPriceFresh, "max: fresh");
        assertTrue(p.pricesUsable, "max: usable");
        _liquidateAs(keeper, p.params);
        assertLt(_debtOf(bobProxy, usdcReserveId), 18_000e6, "liquidated at the boundary");
    }

    // TEST-247 verifies: REQ-LENS-035, REQ-RISK-060, REQ-RISK-062, REQ-ADAPTER-010
    /// @notice No usable route from USDT into USDC. Alice owes nothing on USDC, so the account-wide status leaves USDC
    /// out of scope and reports borrowing open; the borrow puts USDC in scope and reverts `DebtLiquidationHalted`, and
    /// the preview is 0. The backup route reopens both.
    function test_TEST_247_borrowMaxRefusesAHaltedRouteOfTheBorrowedReserve() public {
        _setRoutes(address(usdt), address(usdc), false);
        assertTrue(_borrowAllowed(), "the account-wide status does not see the USDC routes");
        assertEq(_previewUsdc(), 0, "halted: the preview refuses");
        _borrowUsdc(1e6, abi.encodeWithSelector(IRiskModuleErrors.DebtLiquidationHalted.selector, usdcReserveId));
        reg.setRouteUsable(MARKET_ID, address(usdt), address(usdc), 1, true);
        uint256 amount = _previewUsdc();
        assertGt(amount, 0, "the backup route reopens it");
        _borrowUsdc(amount, "");
        assertEq(_debtOf(proxy, usdcReserveId), amount, "the previewed maximum executes");
    }

    // TEST-247 verifies: REQ-LENS-035, REQ-RISK-060, REQ-RISK-062, REQ-ADAPTER-010
    /// @notice The borrowed reserve's asset counts as a debt asset of the account. Alice owes GHO and USDC has no route
    /// into GHO: the account-wide status and a GHO borrow refuse, but a USDC borrow makes USDC a debt asset, which needs
    /// no route of its own, and executes. The preview follows the borrow, not the status.
    function test_TEST_247_borrowMaxCountsTheBorrowedAssetAsADebtAsset() public {
        _borrowVia(alice, MARKET_ID, debtReserveId, 1000e18);
        _setRoutes(address(usdc), address(debt), false);
        assertFalse(_borrowAllowed(), "the account-wide status refuses");
        assertEq(lens.previewBorrowMax(alice, MARKET_ID, debtReserveId, _deadline()), 0, "a GHO borrow: 0");
        uint256 nonce = adapterC.borrowNonce(proxy);
        uint256 deadline = _deadline();
        vm.expectRevert(abi.encodeWithSelector(IRiskModuleErrors.DebtLiquidationHalted.selector, debtReserveId));
        vm.prank(alice);
        adapterC.borrow(MARKET_ID, debtReserveId, 1e18, alice, deadline, 0, nonce);
        uint256 amount = _previewUsdc();
        assertGt(amount, 0, "a USDC borrow: open");
        _borrowUsdc(amount, "");
        assertEq(_debtOf(proxy, usdcReserveId), amount, "the previewed maximum executes");
    }

    // TEST-247 verifies: REQ-LENS-035, REQ-RISK-060, REQ-RISK-061
    /// @notice The USDC reserve's record no longer matches the Spoke (another Hub asset id). Alice owes nothing on it,
    /// yet the account-wide status already refuses: the drift step checks every enabled debt reserve's record. The
    /// borrow reverts `ConfigDrift(DebtReserveMismatch)` from its scope step and the preview is 0. The record restored
    /// reopens both.
    function test_TEST_247_borrowMaxRefusesADriftedRecordOfTheBorrowedReserve() public {
        address spoke = _spokeOf(proxy);
        DebtReserveDef memory d = reg.getDebtReserve(spoke, usdcReserveId);
        ++d.hubAssetId;
        reg.setDebtReserve(spoke, usdcReserveId, d);
        assertFalse(_borrowAllowed(), "the drift step sees the USDC record");
        assertEq(_previewUsdc(), 0, "drifted: the preview refuses");
        _borrowUsdc(
            1e6, abi.encodeWithSelector(IRiskModuleErrors.ConfigDrift.selector, 0, DriftReason.DebtReserveMismatch)
        );
        --d.hubAssetId;
        reg.setDebtReserve(spoke, usdcReserveId, d);
        uint256 amount = _previewUsdc();
        assertGt(amount, 0, "restored: open");
        _borrowUsdc(amount, "");
    }
}
