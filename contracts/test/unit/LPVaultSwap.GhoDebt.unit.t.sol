// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ILPVaultSwapErrors} from "../../src/liquidation/lp-vault-swap/ILPVaultSwapErrors.sol";
import {LiquidationParams} from "../../src/liquidation/lp-vault-swap/types/LiquidationParams.sol";
import {LiquidationResult} from "../../src/liquidation/lp-vault-swap/types/LiquidationResult.sol";
import {MockCLPool} from "../utils/mocks/SwapRouteMocks.sol";
import {LPVaultSwapUnitBase} from "./LPVaultSwap.Base.sol";

/// @title LPVaultSwapGhoDebtUnitTest
/// @notice Liquidations repaying GHO (2.11 SPEC-LIQ-004 to SPEC-LIQ-022 at 18 decimals, Aave's fixed $1.00 GHO
/// source, REQ-SWAP-088): both pool tokens are swapped into GHO, every figure is in 18-decimal GHO units, the caller
/// funds and is paid in GHO, the fee goes to `feeRecipient` and any borrower surplus to the wallet in GHO; a top-up
/// closes a floor the routes miss; a pending balance of a market whose settlement reserve is GHO funds the GHO
/// Coverage Spoke. Each figure is checked against the independent model of the base suite.
/// forge-config: default.isolate = false
contract LPVaultSwapGhoDebtUnitTest is LPVaultSwapUnitBase {
    address internal proxy;
    MockCLPool internal usdcGhoPool;
    MockCLPool internal usdtGhoPool;

    function setUp() public override {
        super.setUp();
        proxy = _ghoAccount(alice);
        // Fresh GHO pools with settable rates (1 base unit of a 6-decimal token = 1e12 GHO units at par).
        usdcGhoPool = _clPool(usdc, gho, 1e12, 1);
        usdtGhoPool = _clPool(usdt, gho, 1e12, 1);
        registry.setRoute(
            MARKET_ID, address(usdc), address(gho), 0, address(_route(address(usdc), address(gho), usdcGhoPool)), true
        );
        registry.setRoute(
            MARKET_ID, address(usdt), address(gho), 0, address(_route(address(usdt), address(gho), usdtGhoPool)), true
        );
    }

    function _ghoAccount(
        address wallet
    ) internal returns (address ghoProxy) {
        (ghoProxy,) = _openAccount(wallet, 10_000e6, 0, 250_000_000);
        lpOracle.setAnswer(250_000_000);
        adapter.borrow(ghoProxy, ghoReserveId, address(gho), 18_000e18, wallet);
        lpOracle.setAnswer(int256(P_VAULT));
    }

    function _ghoParams(
        uint256 debtToCover
    ) internal view returns (LiquidationParams memory p) {
        p = _params(proxy, debtToCover);
        p.debtReserveId = ghoReserveId;
    }

    /// @dev The model of a GHO-debt liquidation of `c` units for `d` repaid, funding `kf`, recovery `r`, at `pc`.
    function _expectGho(
        uint256 c,
        uint256 d,
        uint256 kf,
        uint256 r,
        uint256 pc,
        uint256 maxShortfall
    ) internal pure returns (Expect memory e) {
        e.value = _valueOf(c, pc, PRICE_UNIT, 18);
        e.units = _unitsOf(false, 18, PRICE_UNIT);
        e.slippage = _slippageOf(10_500, SLIPPAGE_BPS);
        e.minRec = _floorOf(e.value, e.slippage, e.units, FLOOR_ROUNDING_ALLOWANCE_GHO);
        e.recovered = r;
        uint256 rf = r > e.minRec ? r : e.minRec;
        e.surplus = rf > d ? rf - d : 0;
        e.gain = e.value > d ? e.value - d : 0;
        uint256 share = e.gain * AVANA_FEE_SHARE_BPS / BPS;
        e.fee = share < e.surplus ? share : e.surplus;
        e.reward = (e.surplus < e.gain ? e.surplus : e.gain) - e.fee;
        e.borrower = e.surplus - e.fee - e.reward;
        uint256 floorGap = e.minRec > r ? e.minRec - r : 0;
        require(floorGap <= maxShortfall, "model: below floor");
        e.shortfall = floorGap;
        e.keeperOut = kf + r + e.shortfall - d - e.fee - e.borrower;
    }

    /// @notice 1,950 GHO at par routes: `R = (a₀ + a₁) × 10¹²`, every figure equal to the model, the caller paid in
    /// GHO, the fee in GHO, LPVaultSwap neutral in every token.
    // TEST-048 verifies: REQ-SWAP-088, REQ-SWAP-089, SPEC-LIQ-004, SPEC-LIQ-005, SPEC-LIQ-010, SPEC-LIQ-022
    function test_ghoWaterfallMatchesModel() public {
        uint256 feeBefore = gho.balanceOf(feeRecipient);
        LiquidationResult memory r = _liquidateAs(keeper, _ghoParams(1950e18));
        (uint256 a0, uint256 a1) = _released(r.unitsSeized);
        assertEq(r.recovered, (a0 + a1) * 1e12, "both legs at par into GHO");
        Expect memory e = _expectGho(r.unitsSeized, r.debtRepaid, r.callerFunds, r.recovered, P_VAULT, 0);
        _assertResult(r, e);
        assertEq(r.debtAsset, address(gho), "GHO");
        assertEq(gho.balanceOf(feeRecipient), feeBefore + r.avanaFee, "fee in GHO");
        assertEq(gho.balanceOf(keeper), r.keeperOut, "caller paid in GHO");
        assertEq(gho.balanceOf(address(lvs)), 0, "no GHO kept");
        assertEq(usdc.balanceOf(address(lvs)), 0, "no USDC kept");
        assertEq(usdt.balanceOf(address(lvs)), 0, "no USDT kept");
        _assertNoAllowances();
    }

    /// @notice Any repayment, vault price and route rates within ±3 %: the model's figures with GHO conserved, or a
    /// named refusal.
    // TEST-078 verifies: SPEC-LIQ-004, SPEC-LIQ-005, SPEC-LIQ-010, SPEC-LIQ-019, REQ-SWAP-088
    function testFuzz_ghoSettlementMatchesModel(
        uint256 debtToCover,
        uint256 price8,
        uint256 usdcRate,
        uint256 usdtRate,
        uint256 maxShortfall
    ) public {
        debtToCover = bound(debtToCover, 5e18, 8000e18);
        price8 = bound(price8, 160_000_000, 225_000_000);
        usdcRate = bound(usdcRate, 9700, 10_300);
        usdtRate = bound(usdtRate, 9700, 10_300);
        maxShortfall = bound(maxShortfall, 0, 500e18);
        lpOracle.setAnswer(int256(price8));
        usdcGhoPool.setRate(1e12 * usdcRate, 10_000);
        usdtGhoPool.setRate(1e12 * usdtRate, 10_000);
        if (_hf(proxy) >= 0.95e18) return; // keeps Aave's maximum bonus, the one the model uses
        LiquidationParams memory p = _ghoParams(debtToCover);
        p.maxShortfall = maxShortfall;
        gho.mint(keeper, debtToCover + maxShortfall);
        vm.prank(keeper);
        gho.approve(address(lvs), debtToCover + maxShortfall);
        uint256 callerBefore = gho.balanceOf(keeper);
        vm.prank(keeper);
        try lvs.liquidate(p) returns (LiquidationResult memory r) {
            _checkGho(r, [usdcRate, usdtRate, price8, maxShortfall, callerBefore]);
        } catch (bytes memory reason) {
            bytes4 s = bytes4(reason);
            assertTrue(
                s == ILPVaultSwapErrors.RecoveryBelowFloor.selector || s == ILPVaultSwapErrors.NoRouteAvailable.selector
                    || s == bytes4(keccak256("MustNotLeaveDust()")),
                "unexpected refusal"
            );
        }
    }

    /// @dev `k = [usdcRate, usdtRate, price8, maxShortfall, callerBefore]`.
    function _checkGho(
        LiquidationResult memory r,
        uint256[5] memory k
    ) internal view {
        (uint256 a0, uint256 a1) = _released(r.unitsSeized);
        assertEq(r.recovered, a0 * 1e12 * k[0] / 10_000 + a1 * 1e12 * k[1] / 10_000, "R from the two GHO legs");
        _assertResult(r, _expectGho(r.unitsSeized, r.debtRepaid, r.callerFunds, r.recovered, k[2], k[3]));
        assertEq(gho.balanceOf(keeper), k[4] - r.callerFunds - r.shortfall + r.keeperOut, "caller flow");
        assertEq(gho.balanceOf(address(lvs)), 0, "GHO conserved through LPVaultSwap");
    }

    /// @notice The vault priced at $2.15 while its released tokens are worth $2.09 a unit at the legs' prices: every
    /// leg meets its minimum at par, yet `R` stays below the floor. Without a budget the call reverts
    /// `RecoveryBelowFloor` and nothing moves; with one the caller tops up exactly `minRec − R` in GHO.
    // TEST-233 verifies: SPEC-LIQ-019, REQ-SWAP-025, REQ-SWAP-026, REQ-SWAP-111
    function test_ghoShortfallTopUp() public {
        lpOracle.setAnswer(215_000_000);
        uint256 debt = _debtOf(proxy, ghoReserveId);
        _expectLiquidateRevert(keeper, _ghoParams(1950e18), _err(ILPVaultSwapErrors.RecoveryBelowFloor.selector));
        assertEq(_debtOf(proxy, ghoReserveId), debt, "nothing repaid");
        LiquidationParams memory p = _ghoParams(1950e18);
        p.maxShortfall = 200e18;
        gho.mint(keeper, 1950e18 + 200e18);
        vm.prank(keeper);
        gho.approve(address(lvs), 1950e18 + 200e18);
        uint256 before = gho.balanceOf(keeper);
        vm.prank(keeper);
        LiquidationResult memory r = lvs.liquidate(p);
        assertGt(r.shortfall, 0, "a top-up was needed");
        assertEq(r.recovered + r.shortfall, r.minOut, "R + shortfall = minRec");
        assertEq(r.borrowerSurplus, 0, "the top-up never reaches the borrower");
        assertEq(gho.balanceOf(keeper), before - r.callerFunds - r.shortfall + r.keeperOut, "pulled exactly");
    }

    /// @notice Routes paying 3 % above the oracle make `R > V`: the borrower surplus `B = S − G > 0` is paid to Alice's
    /// wallet in GHO with `BorrowerSurplusPaid`.
    // TEST-048 verifies: SPEC-LIQ-022, REQ-SWAP-089, INV-086
    function test_ghoBorrowerSurplusToWallet() public {
        usdcGhoPool.setRate(1e12 * 10_300, 10_000);
        usdtGhoPool.setRate(1e12 * 10_300, 10_000);
        uint256 walletBefore = gho.balanceOf(alice);
        LiquidationResult memory r = _liquidateAs(keeper, _ghoParams(1950e18));
        Expect memory e = _expectGho(r.unitsSeized, r.debtRepaid, r.callerFunds, r.recovered, P_VAULT, 0);
        _assertResult(r, e);
        assertGt(r.borrowerSurplus, 0, "B > 0 when R exceeds V");
        assertEq(gho.balanceOf(alice), walletBefore + r.borrowerSurplus, "surplus to the wallet");
    }

    /// @notice The fee recipient's share is computed on the oracle gain in GHO, at every fee share up to 50 %.
    // TEST-240 verifies: SPEC-LIQ-009, SPEC-LIQ-022, INV-036
    function testFuzz_ghoFeeShare(
        uint16 share
    ) public {
        share = uint16(bound(share, 0, 5000));
        store.setAvanaFeeShareBps(share);
        LiquidationResult memory r = _liquidateAs(keeper, _ghoParams(1950e18));
        uint256 v = _valueOf(r.unitsSeized, P_VAULT, PRICE_UNIT, 18);
        uint256 gain = v > r.debtRepaid ? v - r.debtRepaid : 0;
        uint256 surplus = r.recovered > r.debtRepaid ? r.recovered - r.debtRepaid : 0;
        uint256 fee = gain * share / BPS;
        assertEq(r.avanaFee, fee < surplus ? fee : surplus, "A = min(G x share, S)");
        assertEq(r.avanaFee + r.keeperReward + r.borrowerSurplus, surplus, "A + kr + B = S");
    }

    /// @notice A market whose settlement reserve is GHO: the pending balance left by an earlier seizure is released,
    /// both tokens are swapped into GHO and `R` funds the GHO Coverage Spoke; the caller receives nothing.
    // TEST-280 verifies: REQ-SWAP-066, REQ-SWAP-070, Q-338
    function test_pendingIntoGhoCoverage() public {
        (address bobProxy,) = _bobAccount();
        _seizeAndKeep(bobProxy, 1000e6);
        _liquidateAs(keeper, _params(bobProxy, 500e6));
        registry.setSettlementReserve(MARKET_ID, ghoReserveId);
        uint256 coverageBefore = gho.balanceOf(aave.hub);
        address anyone = makeAddr("anyone");
        vm.prank(anyone);
        (uint256 units,, uint256 recovered) = lvs.settlePending(MARKET_ID, ghoReserveId);
        assertGt(units, 0, "units settled");
        assertGt(recovered, 0, "GHO recovered");
        assertEq(gho.balanceOf(aave.hub), coverageBefore + recovered, "R added to the GHO Hub through fund");
        assertEq(gho.balanceOf(anyone), 0, "the caller receives nothing");
        assertEq(gho.balanceOf(address(lvs)), 0, "no GHO kept");
        assertEq(coll.getPending(address(vt)).units, 0, "pending settled");
    }

    /// @notice `settlePending` names the market's settlement reserve: the USDC reserve for a GHO-settling market is
    /// refused `UnknownDebtReserve`.
    // TEST-170 verifies: REQ-SWAP-066, REQ-SWAP-068
    function test_pendingWrongReserveRefused() public {
        (address bobProxy,) = _bobAccount();
        _seizeAndKeep(bobProxy, 1000e6);
        _liquidateAs(keeper, _params(bobProxy, 500e6));
        registry.setSettlementReserve(MARKET_ID, ghoReserveId);
        vm.expectRevert(abi.encodeWithSelector(ILPVaultSwapErrors.UnknownDebtReserve.selector, usdcReserveId));
        lvs.settlePending(MARKET_ID, usdcReserveId);
    }
}
