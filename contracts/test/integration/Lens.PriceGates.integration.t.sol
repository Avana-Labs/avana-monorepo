// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {DebtPriceView} from "../../src/lens/lens/types/DebtPriceView.sol";
import {LiquidationPreview} from "../../src/lens/lens/types/LiquidationPreview.sol";
import {ILPVaultSwapErrors} from "../../src/liquidation/lp-vault-swap/ILPVaultSwapErrors.sol";
import {IRiskModuleErrors} from "../../src/policy/risk-module/IRiskModuleErrors.sol";
import {DriftReason} from "../../src/types/DriftReason.sol";
import {RealStackVolatile} from "../utils/fixtures/RealStackVolatile.sol";
import {OracleFeedMock} from "../utils/mocks/LPOracleMocks.sol";

/// @title LensPriceGatesIntegrationTest
/// @notice The Lens's debt-price gates on the real stack (`RealStackVolatile`): the real RiskModule, AaveAdapter,
/// LPVaultSwap and USDC DebtOracle. `previewBorrowMax` applies the RiskModule's debt-price rule to the reserve being
/// borrowed, not only to the reserves the account already owes on; and the Lens measures a debt price's age as execution
/// does: the borrow side on the served route's timestamp against the DebtOracle's `borrowPriceMaxAge()`, the liquidation
/// side on each leg's timestamp against the ParameterStore's `liquidationPriceMaxAge(feed)`, both bounds inclusive (age
/// == max passes, max + 1 fails). The rest of the RiskModule's gates of a reserve not yet owed (its routes, its record)
/// follow the borrow as well.
/// @dev Alice holds two accounts with no debt. The debt-price cases use her WBTC/WETH account on the Volatile Hub
/// (`_wbtcWethMarket`, about $20,000 of liquidity, USDC reserve `usdcReserveIdV`): that market's LPOracle reads no USDC
/// feed, so a USDC round moves the debt rule alone, as the stand-in's DebtOracle did. A served route's age is set by the
/// timestamp of the USDC primary feed's round, a closed oracle borrow gate by a USDC second source 3 % away, and a
/// state that is not Live by a USDC alternate 3 % away from the primary (a disagreement: Drifting). The route and record
/// cases use her USDC/USDT account on the Stable Hub (10,000 vault tokens at $2.00), routes disabled and restored by the
/// timelock and the record drifted by an Aave DAO reinvestment controller on the USDC Hub asset.
/// forge-config: default.isolate = false
contract LensPriceGatesIntegrationTest is RealStackVolatile {
    /// @dev The USDC primary feed's `borrowPriceMaxAge` in the borrow-age cases, below its `feedMaxAge` (FEED_AGE).
    uint32 internal constant BORROW_AGE = 3600;
    /// @dev The liquidation age limit of the served USDC leg in the liquidation case: the USDC alternate feed's
    /// `borrowPriceMaxAge`, lowered to it (an alternate leg's liquidation limit is the lower of its two ages).
    uint32 internal constant LIQ_AGE = 4200;

    uint256 internal mA;
    uint256 internal mV;
    /// @dev Alice's USDC/USDT account (Stable Spoke).
    address internal proxy;
    /// @dev Alice's WBTC/WETH account (Volatile Spoke).
    address internal proxyV;
    OracleFeedMock internal usdcPrimary;

    function setUp() public {
        _setUpFullStack();
        mA = _addMarket(poolA);
        mV = _wbtcWethMarket();
        (, proxy) = _pledgeAs(alice, mA, UNITS);
        (, proxyV) = _pledgeUsd(alice, mV, 20_000);
        usdcPrimary = feedsOf[address(usdc)][0];
    }

    // ─── Debt-price cases: Alice's WBTC/WETH account ───

    function _previewUsdc() internal view returns (uint256) {
        return lens.previewBorrowMax(alice, mV, usdcReserveIdV, _deadline());
    }

    /// @dev Alice borrows `amount` USDC in the WBTC/WETH market, expecting `err` when it is not empty.
    function _borrowUsdc(
        uint256 amount,
        bytes memory err
    ) internal {
        uint256 nonce = adapterC.borrowNonce(proxyV);
        uint256 deadline = _deadline();
        if (err.length != 0) vm.expectRevert(err);
        vm.prank(alice);
        adapterC.borrow(mV, usdcReserveIdV, amount, alice, deadline, 0, nonce);
    }

    function _tooOld(
        uint256 age
    ) internal view returns (bytes memory) {
        return
            abi.encodeWithSelector(IRiskModuleErrors.DebtPriceTooOld.selector, usdcReserveIdV, address(usdcOracle), age);
    }

    function _debtView() internal view returns (DebtPriceView memory) {
        return lens.getDebtPriceState(spokeV, usdcReserveIdV);
    }

    /// @dev A new round of `f` at `price` dated `at`.
    function _round(
        OracleFeedMock f,
        uint256 price,
        uint256 at
    ) internal {
        f.push(int256(price), at);
    }

    /// @dev The USDC primary feed's `borrowPriceMaxAge` lowered to `BORROW_AGE` by the timelock.
    function _tightenUsdcBorrowAge() internal {
        vm.prank(address(timelock));
        store.tightenBorrowPriceMaxAge(address(usdcPrimary), BORROW_AGE);
    }

    // TEST-247 verifies: REQ-LENS-035, REQ-LENS-044, REQ-RISK-061, REQ-ADAPTER-038
    /// @notice A stale, borrow-closed or not-Live USDC price: `previewBorrowMax` and `previewBorrowRecommended` return
    /// 0 exactly when the borrow reverts `DebtPriceTooOld`, and the previewed maximum executes once the price is fresh.
    function test_TEST_247_borrowMaxAppliesTheBorrowedReservesDebtPrice() public {
        assertGt(_previewUsdc(), 0, "open with a fresh USDC price");
        _tightenUsdcBorrowAge();
        _round(usdcPrimary, 1e8, block.timestamp - BORROW_AGE - 1);
        assertEq(_previewUsdc(), 0, "stale: the preview refuses");
        (uint256 rec, uint256 max) = lens.previewBorrowRecommended(alice, mV, usdcReserveIdV, _deadline());
        assertEq(rec + max, 0, "the recommended borrow too");
        _borrowUsdc(1e6, _tooOld(BORROW_AGE + 1));
        _round(usdcPrimary, 1e8, block.timestamp);
        _round(feedsOf[address(usdc)][3], 97_000_000, block.timestamp);
        assertEq(_previewUsdc(), 0, "the oracle's own borrow gate closed: the preview refuses");
        _borrowUsdc(1e6, _tooOld(0));
        _round(feedsOf[address(usdc)][3], 1e8, block.timestamp);
        _round(feedsOf[address(usdc)][1], 97_000_000, block.timestamp);
        assertEq(_previewUsdc(), 0, "not Live: the preview refuses");
        _borrowUsdc(1e6, _tooOld(0));
        _round(feedsOf[address(usdc)][1], 1e8, block.timestamp);
        uint256 amount = _previewUsdc();
        assertGt(amount, 0, "fresh again");
        _borrowUsdc(amount, "");
        assertEq(_debtOn(spokeV, proxyV, usdcReserveIdV), amount, "the previewed maximum executes");
    }

    // TEST-247 verifies: REQ-LENS-030, REQ-LENS-035, REQ-RISK-061
    /// @notice Borrow side at the boundary: a served route aged exactly `borrowPriceMaxAge()` is fresh for the Lens and
    /// borrows; one second older is stale for both.
    function test_TEST_247_debtBorrowAgeBoundaryMatchesExecution() public {
        _tightenUsdcBorrowAge();
        uint32 maxAge = usdcOracle.borrowPriceMaxAge();
        _round(usdcPrimary, 1e8, block.timestamp - maxAge - 1);
        DebtPriceView memory v = _debtView();
        assertEq(v.age, uint256(maxAge) + 1, "the served route's age");
        assertFalse(v.borrowFresh, "max + 1: stale");
        assertEq(_previewUsdc(), 0, "max + 1: no borrow");
        _borrowUsdc(1e6, _tooOld(uint256(maxAge) + 1));
        _round(usdcPrimary, 1e8, block.timestamp - maxAge);
        v = _debtView();
        assertEq(v.age, maxAge, "aged exactly the maximum");
        assertTrue(v.borrowFresh, "max: fresh");
        assertGt(_previewUsdc(), 0, "max: borrowable");
        _borrowUsdc(1e6, "");
    }

    // TEST-247 verifies: REQ-LENS-030, REQ-RISK-061
    /// @notice The accepted price's stored timestamp only moves on a poke; execution reads the served route's live
    /// timestamp. A fresh route behind an accepted timestamp older than `FEED_AGE` is fresh for both. Rounds dated in the
    /// future on both USDC routes are unreadable to the real DebtOracle (`updatedAt > now`): it serves its accepted
    /// price, which the RiskModule refuses and the Lens reports closed to borrowing and to liquidation.
    function test_TEST_247_debtAgeIsTheServedRoutesNotTheAcceptedPrices() public {
        // Nothing pokes the DebtOracle for FEED_AGE + 560 seconds while every feed keeps publishing.
        _warpBlocks(FEED_AGE / 2 + 280);
        _refreshFeeds();
        _pokeAll();
        _warpBlocks(FEED_AGE / 2 + 280);
        _refreshFeeds();
        _pokeAll();
        _round(usdcPrimary, 1e8, block.timestamp - 60);
        (, uint64 acceptedAt) = usdcOracle.lastAcceptedPrice();
        assertGt(block.timestamp - acceptedAt, uint256(FEED_AGE) + 500, "the accepted timestamp is old");
        DebtPriceView memory v = _debtView();
        assertEq(v.age, 60, "the served route's age");
        assertTrue(v.borrowFresh && v.liquidationFresh, "fresh, as execution sees it");
        assertGt(_previewUsdc(), 0, "borrowable");
        _borrowUsdc(1e6, "");
        _round(usdcPrimary, 1e8, block.timestamp + 5);
        _round(feedsOf[address(usdc)][1], 1e8, block.timestamp + 5);
        v = _debtView();
        assertFalse(v.borrowFresh, "a timestamp in the future: the RiskModule refuses");
        assertFalse(v.liquidationFresh, "no readable route: the accepted price is closed to liquidation too");
        assertEq(_previewUsdc(), 0, "no borrow");
        _borrowUsdc(1e6, _tooOld(60));
    }

    // TEST-247 verifies: REQ-LENS-030, REQ-LENS-016, REQ-SWAP-091
    /// @notice Liquidation side at the boundary: a leg aged exactly its liquidation age limit is fresh for the Lens and
    /// `liquidate` runs; one second older is stale for both (`DebtPriceStale`). The ParameterStore keeps a feed's
    /// `liquidationPriceMaxAge` equal to its `feedMaxAge`, so a primary leg past it is no longer served; the served leg
    /// here is the USDC alternate (the primary quiet past its `feedMaxAge`), whose liquidation limit is its
    /// `borrowPriceMaxAge`, lowered to `LIQ_AGE` by the timelock.
    function test_TEST_247_debtLiquidationAgeBoundaryMatchesExecution() public {
        (address bobProxy,) = _usdcAccountBelowOne(bob, mV);
        OracleFeedMock usdcAlternate = feedsOf[address(usdc)][1];
        vm.prank(address(timelock));
        store.tightenBorrowPriceMaxAge(address(usdcAlternate), LIQ_AGE);
        _round(usdcPrimary, 1e8, block.timestamp - FEED_AGE - 1);
        _round(usdcAlternate, 1e8, block.timestamp - LIQ_AGE - 1);
        LiquidationPreview memory p = lens.previewLiquidation(bobProxy, usdcReserveIdV, block.timestamp + 120);
        assertFalse(p.debtPriceFresh, "max + 1: stale");
        usdc.mint(keeper, p.params.debtToCover);
        vm.startPrank(keeper);
        usdc.approve(lpVaultSwap, p.params.debtToCover);
        vm.expectRevert(abi.encodeWithSelector(ILPVaultSwapErrors.DebtPriceStale.selector, usdcReserveIdV));
        lvs.liquidate(p.params);
        usdc.approve(lpVaultSwap, 0);
        vm.stopPrank();
        _round(usdcAlternate, 1e8, block.timestamp - LIQ_AGE);
        p = lens.previewLiquidation(bobProxy, usdcReserveIdV, block.timestamp + 120);
        assertTrue(p.debtPriceFresh, "max: fresh");
        assertTrue(p.pricesUsable, "max: usable");
        uint256 debtBefore = _debtOn(spokeV, bobProxy, usdcReserveIdV);
        _liquidateOn(spokeV, keeper, p.params);
        assertLt(_debtOn(spokeV, bobProxy, usdcReserveIdV), debtBefore, "liquidated at the boundary");
    }

    // ─── Route and record cases: Alice's USDC/USDT account ───

    function _previewUsdcA() internal view returns (uint256) {
        return lens.previewBorrowMax(alice, mA, usdcReserveId, _deadline());
    }

    /// @dev Alice borrows `amount` of `reserveId` in the USDC/USDT market, expecting `err` when it is not empty.
    function _borrowA(
        uint256 reserveId,
        uint256 amount,
        bytes memory err
    ) internal {
        uint256 nonce = adapterC.borrowNonce(proxy);
        uint256 deadline = _deadline();
        if (err.length != 0) vm.expectRevert(err);
        vm.prank(alice);
        adapterC.borrow(mA, reserveId, amount, alice, deadline, 0, nonce);
    }

    /// @dev Both swap routes of `token` into `asset` disabled by the timelock.
    function _disableRoutes(
        address token,
        address asset
    ) internal {
        vm.startPrank(address(timelock));
        registry.disableRoute(mA, token, asset, 0);
        registry.disableRoute(mA, token, asset, 1);
        vm.stopPrank();
    }

    function _borrowAllowed() internal view returns (bool) {
        return riskModule.getAccountGateStatus(proxy).borrowAllowed;
    }

    /// @dev The Aave DAO sets `controller` as the USDC Hub asset's reinvestment controller.
    function _setUsdcReinvestment(
        address controller
    ) internal {
        vm.prank(aaveDao);
        (bool ok,) = aave.hubConfigurator
            .call(
                abi.encodeWithSignature(
                    "updateReinvestmentController(address,uint256,address)", aave.hub, usdcAssetId, controller
                )
            );
        require(ok, "reinvestment controller");
    }

    // TEST-247 verifies: REQ-LENS-035, REQ-RISK-060, REQ-RISK-062, REQ-ADAPTER-010
    /// @notice No usable route from USDT into USDC. Alice owes nothing on USDC, so the account-wide status leaves USDC
    /// out of scope and reports borrowing open; the borrow puts USDC in scope and reverts `DebtLiquidationHalted`, and
    /// the preview is 0. The backup route reopens both.
    function test_TEST_247_borrowMaxRefusesAHaltedRouteOfTheBorrowedReserve() public {
        _disableRoutes(address(usdt), address(usdc));
        assertTrue(_borrowAllowed(), "the account-wide status does not see the USDC routes");
        assertEq(_previewUsdcA(), 0, "halted: the preview refuses");
        _borrowA(
            usdcReserveId, 1e6, abi.encodeWithSelector(IRiskModuleErrors.DebtLiquidationHalted.selector, usdcReserveId)
        );
        vm.prank(address(timelock));
        registry.restoreRoute(mA, address(usdt), address(usdc), 1, routeOf[address(usdt)][address(usdc)][1]);
        uint256 amount = _previewUsdcA();
        assertGt(amount, 0, "the backup route reopens it");
        _borrowA(usdcReserveId, amount, "");
        assertEq(_debtOf(proxy, usdcReserveId), amount, "the previewed maximum executes");
    }

    // TEST-247 verifies: REQ-LENS-035, REQ-RISK-060, REQ-RISK-062, REQ-ADAPTER-010
    /// @notice The borrowed reserve's asset counts as a debt asset of the account. Alice owes GHO and USDC has no route
    /// into GHO: the account-wide status and a GHO borrow refuse, but a USDC borrow makes USDC a debt asset, which needs
    /// no route of its own, and executes. The preview follows the borrow, not the status.
    function test_TEST_247_borrowMaxCountsTheBorrowedAssetAsADebtAsset() public {
        _borrowA(ghoReserveId, 1000e18, "");
        _disableRoutes(address(usdc), address(gho));
        assertFalse(_borrowAllowed(), "the account-wide status refuses");
        assertEq(lens.previewBorrowMax(alice, mA, ghoReserveId, _deadline()), 0, "a GHO borrow: 0");
        _borrowA(
            ghoReserveId, 1e18, abi.encodeWithSelector(IRiskModuleErrors.DebtLiquidationHalted.selector, ghoReserveId)
        );
        uint256 amount = _previewUsdcA();
        assertGt(amount, 0, "a USDC borrow: open");
        _borrowA(usdcReserveId, amount, "");
        assertEq(_debtOf(proxy, usdcReserveId), amount, "the previewed maximum executes");
    }

    // TEST-247 verifies: REQ-LENS-035, REQ-RISK-060, REQ-RISK-061
    /// @notice The USDC reserve's record no longer matches the chain (a reinvestment controller on its funding-Hub
    /// asset). Alice owes nothing on it, yet the account-wide status already refuses: the drift step checks every
    /// enabled debt reserve's record. The borrow reverts `ConfigDrift(ReinvestmentController)` and the preview is 0. The
    /// controller removed reopens both.
    function test_TEST_247_borrowMaxRefusesADriftedRecordOfTheBorrowedReserve() public {
        _setUsdcReinvestment(makeAddr("reinvestmentController"));
        assertFalse(_borrowAllowed(), "the drift step sees the USDC record");
        assertEq(_previewUsdcA(), 0, "drifted: the preview refuses");
        _borrowA(
            usdcReserveId,
            1e6,
            abi.encodeWithSelector(IRiskModuleErrors.ConfigDrift.selector, 0, DriftReason.ReinvestmentController)
        );
        _setUsdcReinvestment(address(0));
        uint256 amount = _previewUsdcA();
        assertGt(amount, 0, "restored: open");
        _borrowA(usdcReserveId, amount, "");
    }
}
