// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ILPVaultSwapErrors} from "../../src/liquidation/lp-vault-swap/ILPVaultSwapErrors.sol";
import {LiquidationParams} from "../../src/liquidation/lp-vault-swap/types/LiquidationParams.sol";
import {LiquidationResult} from "../../src/liquidation/lp-vault-swap/types/LiquidationResult.sol";
import {PriceState} from "../../src/types/PriceState.sol";
import {LPVaultSwapUnitBase} from "../unit/LPVaultSwap.Base.sol";

/// @title LPVaultSwapPriceGatesFuzzTest
/// @notice Every combination of the seized market's price state, its four flags, a leg's age against
/// `liquidationPriceMaxAge`, the repaid reserve's DebtOracle state, its liquidation flag and leg age (2.11 REQ-SWAP-008,
/// REQ-SWAP-050, REQ-SWAP-091, REQ-SWAP-110, SPEC-LIQ-012): `liquidate` settles exactly when the market is Live or
/// Drifting with no pause, disagreement pause or expired disagreement and every leg within its age, the grace bound (if
/// in grace) is met, and the DebtOracle is Live with no liquidation pause and fresh legs; otherwise it reverts with the
/// first failing check's error (`StalePrice` for the market, then `DebtPriceStale(r)`, then `GraceHealthFactor`) and
/// nothing moves. `settlePending` applies the same price gates but not the grace bound.
/// forge-config: default.isolate = false
/// forge-config: default.fuzz.runs = 512
contract LPVaultSwapPriceGatesFuzzTest is LPVaultSwapUnitBase {
    address internal proxy;
    address internal feed = makeAddr("usdtFeed");
    address internal usdcFeed = makeAddr("usdcFeed");

    struct Gates {
        uint8 marketState;
        bool paused;
        bool pauseActive;
        bool expired;
        bool grace;
        uint32 legAge;
        uint8 debtState;
        bool debtPaused;
        uint32 debtLegAge;
        bool graceMet;
    }

    function setUp() public override {
        super.setUp();
        (proxy,) = _bobAccount();
        store.setLiquidationPriceMaxAge(feed, 88_200);
        store.setLiquidationPriceMaxAge(usdcFeed, 88_200);
        vm.warp(1_800_000_000);
    }

    function _apply(
        Gates memory g
    ) internal {
        lpOracle.setState(PriceState(g.marketState % 4));
        lpOracle.setFlags(g.paused, g.pauseActive, g.expired, g.grace);
        lpOracle.setLeg(1, 1, feed, uint64(block.timestamp - (g.legAge % 120_000)));
        usdcOracle.setState(PriceState(g.debtState % 4), g.debtPaused);
        usdcOracle.setLeg(0, usdcFeed, uint64(block.timestamp - (g.debtLegAge % 120_000)));
        uint256 hf = _hf(proxy);
        store.setGraceHealthFactor(g.graceMet ? hf + 1 : hf);
    }

    function _marketOk(
        Gates memory g
    ) internal pure returns (bool) {
        PriceState s = PriceState(g.marketState % 4);
        bool stateOk = s == PriceState.Live || s == PriceState.Drifting;
        return stateOk && !g.paused && !g.pauseActive && !g.expired && (g.legAge % 120_000) <= 88_200;
    }

    function _debtOk(
        Gates memory g
    ) internal pure returns (bool) {
        return PriceState(g.debtState % 4) == PriceState.Live && !g.debtPaused && (g.debtLegAge % 120_000) <= 88_200;
    }

    /// @notice `liquidate` over every combination: settles exactly when every gate passes, else the first failing
    /// gate's error with the debt unchanged.
    // TEST-049 verifies: REQ-SWAP-008, REQ-SWAP-050, REQ-SWAP-091, REQ-SWAP-110, INV-030, INV-059, Q-128, Q-208
    function testFuzz_TEST_049_liquidateGates(
        Gates memory g
    ) public {
        _apply(g);
        bytes memory expected;
        if (!_marketOk(g)) {
            expected = abi.encodeWithSelector(ILPVaultSwapErrors.StalePrice.selector);
        } else if (!_debtOk(g)) {
            expected = abi.encodeWithSelector(ILPVaultSwapErrors.DebtPriceStale.selector, usdcReserveId);
        } else if (g.grace && !g.graceMet) {
            expected = abi.encodeWithSelector(ILPVaultSwapErrors.GraceHealthFactor.selector);
        }
        uint256 debt = _debtOf(proxy, usdcReserveId);
        if (expected.length != 0) {
            _fund(usdc, keeper, 1950e6);
            vm.prank(keeper);
            vm.expectRevert(expected);
            lvs.liquidate(_params(proxy, 1950e6));
            assertEq(_debtOf(proxy, usdcReserveId), debt, "a refusal repays nothing");
        } else {
            LiquidationResult memory r = _liquidateAs(keeper, _params(proxy, 1950e6));
            assertGt(r.unitsSeized, 0, "every gate passed: settles");
            assertLt(_debtOf(proxy, usdcReserveId), debt, "debt repaid");
        }
    }

    /// @notice `settlePending` over the same combinations: the price gates apply, the grace bound does not.
    // TEST-170 verifies: REQ-SWAP-066, REQ-SWAP-091, REQ-SWAP-110
    function testFuzz_TEST_170_pendingGates(
        Gates memory g
    ) public {
        _seizeAndKeep(proxy, 1000e6);
        _liquidateAs(keeper, _params(proxy, 500e6));
        uint256 pending = coll.getPending(address(vt)).units;
        _apply(g);
        if (!_marketOk(g)) {
            vm.expectRevert(abi.encodeWithSelector(ILPVaultSwapErrors.StalePrice.selector));
            lvs.settlePending(MARKET_ID, usdcReserveId);
            assertEq(coll.getPending(address(vt)).units, pending, "nothing settled");
        } else if (!_debtOk(g)) {
            vm.expectRevert(abi.encodeWithSelector(ILPVaultSwapErrors.DebtPriceStale.selector, usdcReserveId));
            lvs.settlePending(MARKET_ID, usdcReserveId);
            assertEq(coll.getPending(address(vt)).units, pending, "nothing settled");
        } else {
            (uint256 units,,) = lvs.settlePending(MARKET_ID, usdcReserveId);
            assertGt(units, 0, "settled, whatever the grace state");
        }
    }

    /// @notice The DebtOracle's legs are checked only for a reserve that is not GHO's fixed price: a GHO repayment
    /// settles with the USDC DebtOracle in any state.
    // TEST-226 verifies: REQ-SWAP-091, REQ-SWAP-110, Q-208
    function testFuzz_TEST_226_ghoIgnoresUsdcOracle(
        uint8 debtState,
        bool debtPaused
    ) public {
        (address ghoProxy,) = _openAccount(alice, 10_000e6, 0, 250_000_000);
        lpOracle.setAnswer(250_000_000);
        adapter.borrow(ghoProxy, ghoReserveId, address(gho), 18_000e18, alice);
        lpOracle.setAnswer(int256(P_VAULT));
        usdcOracle.setState(PriceState(debtState % 4), debtPaused);
        LiquidationResult memory r;
        {
            gho.mint(keeper, 1950e18);
            vm.prank(keeper);
            gho.approve(address(lvs), 1950e18);
            vm.prank(keeper);
            LiquidationParams memory p = _params(ghoProxy, 1950e18);
            p.debtReserveId = ghoReserveId;
            r = lvs.liquidate(p);
        }
        assertGt(r.unitsSeized, 0, "GHO repayment settles");
    }
}
