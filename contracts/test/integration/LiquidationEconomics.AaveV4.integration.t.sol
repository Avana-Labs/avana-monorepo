// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {FirstLossReserve} from "../../src/FirstLossReserve.sol";
import {IAaveV4Hub} from "../../src/dependencies/aave/IAaveV4Hub.sol";
import {IAaveV4Oracle} from "../../src/dependencies/aave/IAaveV4Oracle.sol";
import {IAaveV4Spoke} from "../../src/dependencies/aave/IAaveV4Spoke.sol";
import {IFirstLossReserve} from "../../src/interfaces/IFirstLossReserve.sol";
import {ILPVault} from "../../src/interfaces/ILPVault.sol";
import {ILiquidationModule} from "../../src/interfaces/ILiquidationModule.sol";
import {INfpmPositions} from "../../src/interfaces/INfpmPositions.sol";
import {ClTickMath} from "../../src/libraries/ClTickMath.sol";
import {LiquidationMath} from "../../src/libraries/LiquidationMath.sol";
import {AaveV4MarketTestBase} from "../utils/AaveV4MarketTestBase.sol";
import {HubSpokeConfig, IHubConfiguratorCalls} from "./VaultToken.AaveV4.integration.t.sol";
import {IAccessManager} from "@openzeppelin/contracts/access/manager/IAccessManager.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @dev Errors of aave-v4 a3ef63e `ISpoke` this suite expects.
interface IAaveV4LiquidationErrors {
    error HealthFactorNotBelowThreshold();
    error MustNotLeaveDust();
}

/// @title LiquidationEconomicsAaveV4IntegrationTest
/// @notice Attacks on the economics of a liquidation in kind, on the pinned real Aave V4 Hub and CDP Spoke with the
/// real LiquidationModule, LPOracle, VaultToken and Uniswap v3 LPVault (`AaveV4MarketTestBase`): competing and
/// front-running liquidators, a pool moved between quote and execution, dust debts and positions, and the loss
/// waterfall of an account Aave empties with debt left.
/// @dev The RiskModule is the market-lookup stand-in: the cases here read only `getMarket`, the fee and the
/// LiquidationModule from it, which the stand-in answers as the real one does. The two loss layers are real
/// FirstLossReserves listed on the real Hub. Aave's dust rule (`DUST_LIQUIDATION_THRESHOLD`, $1,000) decides whether a
/// liquidation may be partial, so the partial cases use a $20,000 position.
contract LiquidationEconomicsAaveV4IntegrationTest is AaveV4MarketTestBase {
    uint64 internal constant COVERAGE_ROLE = 500;
    /// @dev A $20,000 position: 10,000 of each token at $1.
    uint256 internal constant BIG = 10_000e18;

    address internal liquidator2 = makeAddr("liquidator2");

    /// @dev What one liquidation must have done, read before it.
    struct Before {
        uint256 hf;
        uint256 bonus;
        uint256 supply;
        uint256 debt;
        uint256 vtSupply;
        uint256 totalCredit;
        uint256 payer;
        uint256 deficit;
    }

    function setUp() public override {
        super.setUp();
        debt.mint(liquidator2, 1e24);
        vm.prank(liquidator2);
        debt.approve(address(module), type(uint256).max);
    }

    // ─── Case 4: competing liquidators ───

    /// @notice Bug hunted: two liquidators in one block, the first partial and the second to the target, get other than
    /// Aave V4's dynamic bonus for their own share (the second priced at the first's health factor), or the same
    /// collateral is seized or unwound twice. Each liquidation must seize exactly `repaid · bonus` at Aave's prices, at
    /// the bonus of the health factor it found, burn exactly what it seized, and pay out exactly the liquidity worth it.
    function test_twoLiquidatorsInOneBlock_eachGetsTheBonusAtItsOwnHealthFactor() public {
        (bytes32 key, address account) = _unhealthyBig(0.909375e8);
        uint256 supply0 = spoke.getUserSuppliedAssets(vtReserveId, account);
        uint128 credit0 = vault.getPosition(key).credit;
        uint256 hf0 = _hf(account);
        assertGt(hf0, 0.95e18, "between the max-bonus health factor and 1: the bonus is dynamic");
        assertLt(hf0, 1e18);

        (ILiquidationModule.LiquidationResult memory r1, uint256 bonus1) =
            _checkedLiquidation(liquidator, account, 500e18);
        (ILiquidationModule.LiquidationResult memory r2, uint256 bonus2) =
            _checkedLiquidation(liquidator2, account, 1e23);

        assertLt(bonus2, bonus1, "the second liquidator is paid at the higher health factor the first left");
        assertGe(bonus2, 10_250, "never below Aave's minimum bonus");
        assertApproxEqAbs(_hf(account), 1.1e18, 1e15, "the second restores the target");
        // No double seizure: the account lost the sum of both seizures, and the record what both unwound.
        assertEq(spoke.getUserSuppliedAssets(vtReserveId, account), supply0 - r1.seized - r2.seized);
        assertEq(vault.getPosition(key).credit, credit0 - r1.creditUnwound - r2.creditUnwound);
        assertLe(spoke.getUserSuppliedAssets(vtReserveId, account), vault.getPosition(key).credit);
    }

    /// @notice Bug hunted: a liquidator front-run by another who restores the target loses its funds, or still seizes
    /// from the now healthy account. Its call reverts with Aave's health check, its debt tokens never leave it, and
    /// the account is not touched twice.
    function test_frontRunLiquidator_revertsWhole_keepsItsFunds() public {
        (, address account) = _unhealthyBig(0.909375e8);
        _checkedLiquidation(liquidator2, account, 1e23);
        assertGe(_hf(account), 1e18);
        uint256 supply = spoke.getUserSuppliedAssets(vtReserveId, account);
        uint256 balance = debt.balanceOf(liquidator);

        vm.prank(liquidator);
        vm.expectRevert(IAaveV4LiquidationErrors.HealthFactorNotBelowThreshold.selector);
        module.liquidate(_params(account, 500e18));
        assertEq(debt.balanceOf(liquidator), balance);
        assertEq(spoke.getUserSuppliedAssets(vtReserveId, account), supply);
        _assertModuleEmpty();
    }

    /// @notice Bug hunted: anyone (here a stranger repaying part of the borrower's debt through the adapter's open
    /// `repay`) front-runs a liquidation so that the liquidator's exact cover would leave less than Aave's dust
    /// threshold of debt, and every such liquidation reverts. Aave then requires the whole debt, so a liquidator that
    /// over-covers still liquidates: the module takes only what Aave used and refunds the rest.
    function test_griefByPartialRepay_cannotBlockAnOverCoveringLiquidator() public {
        // $1,100 of collateral against $1,500: after the stranger's repayment, $900 of debt at health factor 0.98.
        (, address account) = _unhealthy(SIZE, 1500e18, 0.55e8);
        uint256 owed = spoke.getUserTotalDebt(debtReserveId, account);
        // A stranger repays enough to put the account under the dust threshold of debt.
        debt.mint(attacker, owed);
        vm.startPrank(attacker);
        debt.approve(address(adapter), owed);
        adapter.repay(MARKET, debtReserveId, owed - 900e18, carol);
        vm.stopPrank();
        assertLt(_hf(account), 1e18, "still liquidatable");

        vm.prank(liquidator);
        vm.expectRevert(IAaveV4LiquidationErrors.MustNotLeaveDust.selector);
        module.liquidate(_params(account, 100e18));

        uint256 balance = debt.balanceOf(liquidator);
        (ILiquidationModule.LiquidationResult memory r,) = _checkedLiquidation(liquidator, account, 1e23);
        assertEq(spoke.getUserTotalDebt(debtReserveId, account), 0, "the whole debt");
        assertEq(balance - debt.balanceOf(liquidator), r.debtRepaid, "the rest of the cover is refunded");
    }

    /// @notice Bug hunted: a borrower fills the account up to `MAX_POSITIONS` with dust positions so the unwind plan
    /// runs out of gas or skips the real collateral. The liquidation still unwinds the real position, pays exactly the
    /// seized value, and stays well under a block's gas.
    function test_maxDustPositions_cannotBlockLiquidation() public {
        (bytes32 key,) = _mintFull(carol, BIG);
        _pledge(carol, key);
        uint256 n = vault.MAX_POSITIONS() - 1;
        for (uint256 i; i < n; ++i) {
            (bytes32 dust,) = _mintFull(carol, 1e9);
            _pledge(carol, dust);
        }
        _borrow(carol, 15_000e18);
        _setPrices(0.909375e8);
        address account = adapter.accountOf(carol, MARKET);
        assertEq(vault.positionsOf(account).length, n + 1);

        uint256 gasBefore = gasleft();
        (ILiquidationModule.LiquidationResult memory r,) = _checkedLiquidation(liquidator, account, 1e23);
        uint256 used = gasBefore - gasleft();
        assertGt(r.creditUnwound, 0);
        assertLt(used, 10_000_000, "a liquidation through 16 positions fits in a block");
        emit log_named_uint("gas: liquidation through 16 positions (with checks)", used);
    }

    // ─── Case 3: the pool moves between quote and execution ───

    /// @notice Bug hunted: a liquidator moves the pool before liquidating, to make a healthy account liquidatable, to
    /// seize more units, or to take more of the borrower's liquidity, then moves it back for a profit (a sandwich).
    /// Prices come from Aave's oracle, so the health factor, the units seized and the credit unwound do not move with
    /// the pool; the borrower ends exactly as after an honest liquidation; and the round trip leaves the attacker no
    /// better off than liquidating honestly.
    function test_sandwichedLiquidation_takesNoMoreAndDoesNotPay() public {
        (bytes32 key, address account) = _unhealthyBig(0.909375e8);
        uint256 hf = _hf(account);
        uint256 snap = vm.snapshotState();
        ILiquidationModule.LiquidationResult memory honest = _liquidateAs(liquidator, account, 1e23);
        uint256 honestValue = _usd(honest.amount0, honest.amount1);
        uint128 honestLiquidity = vault.getPosition(key).liquidity;
        uint256 honestDebt = spoke.getUserTotalDebt(debtReserveId, account);
        vm.revertToState(snap);

        // Front-run: push the pool 20 % up, liquidate, push it back.
        (uint256 a0, uint256 a1) = (t0.balanceOf(address(actor)), t1.balanceOf(address(actor)));
        _swapTo(pool, ClTickMath.getSqrtPriceAtTick(1823));
        assertEq(_hf(account), hf, "the health factor ignores the pool");
        ILiquidationModule.LiquidationResult memory r = _liquidateAs(liquidator, account, 1e23);
        _swapTo(pool, ClTickMath.getSqrtPriceAtTick(0));

        assertEq(r.seized, honest.seized, "seized");
        assertEq(r.debtRepaid, honest.debtRepaid, "repaid");
        assertEq(r.creditUnwound, honest.creditUnwound, "credit unwound");
        assertEq(vault.getPosition(key).liquidity, honestLiquidity, "the borrower keeps the same liquidity");
        assertEq(spoke.getUserTotalDebt(debtReserveId, account), honestDebt, "and owes the same");
        // The attacker's swaps cost it the pool fee both ways; the extra token value it unwound is its own swap's.
        int256 swapPnl = int256(_usd(t0.balanceOf(address(actor)), t1.balanceOf(address(actor)))) - int256(_usd(a0, a1));
        int256 sandwich = int256(_usd(r.amount0, r.amount1)) + swapPnl;
        assertLt(sandwich, int256(honestValue), "a sandwich pays less than an honest liquidation");
    }

    /// @notice Bug hunted: a liquidator quotes a liquidation, the pool moves before it lands, and the call pays less
    /// than quoted, or fails half way leaving debt repaid but collateral not paid out. The quote's minimums make the
    /// whole call revert, and nothing moved: debt, supply, credit, the NFT's liquidity and the liquidator's funds.
    function test_quotedMinimums_revertWholeWhenThePoolMoves() public {
        (bytes32 key, address account) = _unhealthyBig(0.909375e8);
        uint256 snap = vm.snapshotState();
        ILiquidationModule.LiquidationResult memory quote = _liquidateAs(liquidator, account, 1e23);
        vm.revertToState(snap);

        _swapTo(pool, ClTickMath.getSqrtPriceAtTick(500));
        uint256 debtBefore = spoke.getUserTotalDebt(debtReserveId, account);
        uint256 supplyBefore = spoke.getUserSuppliedAssets(vtReserveId, account);
        ILPVault.Position memory p = vault.getPosition(key);
        uint256 balance = debt.balanceOf(liquidator);
        ILiquidationModule.LiquidationParams memory params = _params(account, 1e23);
        (params.minAmount0, params.minAmount1) = (quote.amount0, quote.amount1);
        vm.prank(liquidator);
        vm.expectPartialRevert(ILiquidationModule.BelowMinimum.selector);
        module.liquidate(params);

        assertEq(spoke.getUserTotalDebt(debtReserveId, account), debtBefore);
        assertEq(spoke.getUserSuppliedAssets(vtReserveId, account), supplyBefore);
        assertEq(vault.getPosition(key).credit, p.credit);
        assertEq(INfpmPositions(address(nfpm)).positions(uint256(key)).liquidity, p.liquidity);
        assertEq(debt.balanceOf(liquidator), balance);
        _assertModuleEmpty();
    }

    // ─── Case 5: dust ───

    /// @notice Bug hunted: a position too small for Aave's dust rule (here $20 of collateral against $15 of debt)
    /// cannot be liquidated or closed: a partial cover is refused, and what the full cover leaves cannot be taken out.
    /// The over-covering liquidator repays the whole debt, and the borrower then withdraws the rest of the NFT whole.
    function test_tinyPosition_isLiquidatedThenClosed() public {
        (bytes32 key, address account) = _unhealthy(10e18, 15e18, 0.8e8);
        vm.prank(liquidator);
        vm.expectRevert(IAaveV4LiquidationErrors.MustNotLeaveDust.selector);
        module.liquidate(_params(account, 1e18));

        (ILiquidationModule.LiquidationResult memory r,) = _checkedLiquidation(liquidator, account, 1e21);
        assertEq(spoke.getUserTotalDebt(debtReserveId, account), 0, "the whole tiny debt");
        assertGt(r.amount0 + r.amount1, 0);
        vm.prank(carol);
        adapter.withdraw(key, 0, 0, 0, carol);
        assertEq(nfpm.ownerOf(uint256(key)), carol);
        assertEq(spoke.getUserSuppliedAssets(vtReserveId, account), 0);
        assertEq(vt.totalSupply(), 0);
    }

    /// @notice Bug hunted: a debt of a few wei cannot be liquidated (the seizure rounds to nothing and the module
    /// reverts), or can be farmed. Aave takes the whole tiny debt with all collateral of a tiny position, and the
    /// module pays out what it unwound.
    function test_weiDebt_canStillBeLiquidated() public {
        (bytes32 key, address account) = _unhealthy(1e6, 1e5, 0.01e8);
        uint256 owed = spoke.getUserTotalDebt(debtReserveId, account);
        assertLt(owed, 1e6);
        _checkedLiquidation(liquidator, account, 1e18);
        assertEq(spoke.getUserSuppliedAssets(vtReserveId, account), 0);
        assertEq(vault.getPosition(key).credit, 0);
    }

    /// @notice Bug hunted: the module's rounding farmed by many small liquidations of one account (a borrower
    /// liquidating itself from a second wallet, or a liquidator splitting its cover): each round pays out more than the
    /// value Aave seized, or leaves supply above the credit behind it. Every round pays at most the seized value, and the
    /// many small rounds together pay no more than one round of the same total cover.
    function test_splitLiquidations_cannotFarmRounding() public {
        (, address account) = _unhealthyBig(0.909375e8);
        uint256 snap = vm.snapshotState();
        ILiquidationModule.LiquidationResult memory once = _liquidateAs(liquidator, account, 2000e18);
        uint256 onceValue = _usd(once.amount0 + once.fee0, once.amount1 + once.fee1);
        vm.revertToState(snap);

        uint256 total;
        uint256 repaid;
        for (uint256 i; i < 20; ++i) {
            (ILiquidationModule.LiquidationResult memory r,) = _checkedLiquidation(liquidator, account, 100e18);
            total += _usd(r.amount0 + r.fee0, r.amount1 + r.fee1);
            repaid += r.debtRepaid;
        }
        assertEq(repaid, 2000e18);
        // Split rounds are priced at the higher health factor each leaves, so the bonus only falls.
        assertLe(total, onceValue, "twenty small liquidations pay no more than one");
    }

    /// @notice Bug hunted: once a liquidation leaves rounding dust of credit in a position, the borrower cannot close
    /// it: the debt-free withdrawal must release the whole NFT and burn every vault token left.
    function test_dustAfterLiquidation_closesWhole() public {
        (bytes32 key, address account) = _unhealthyBig(0.909375e8);
        _checkedLiquidation(liquidator, account, 777e18 + 13);
        _repayAll(carol);
        vm.prank(carol);
        adapter.withdraw(key, 0, 0, 0, carol);
        assertEq(nfpm.ownerOf(uint256(key)), carol);
        assertEq(spoke.getUserSuppliedAssets(vtReserveId, account), 0);
        assertEq(vault.getMarket(MARKET).totalCredit, 0);
        assertEq(vt.totalSupply(), 0);
    }

    // ─── Case 6: deficit and the loss waterfall ───

    /// @notice Bug hunted: when a liquidation empties an account whose collateral is worth less than its debt, the loss
    /// is covered out of order (the DAO offset before Avana's reserve), in the wrong amounts, or twice. Aave records
    /// exactly the debt the seizure could not repay; Avana's First-Loss Reserve pays first and exactly its balance; the
    /// DAO Deficit Offset pays only beyond Avana's balance, exactly the rest it can; the residual stays recorded on the
    /// Hub; and no layer can pay again for what is covered.
    function test_underwaterAccount_lossWaterfallInOrderAndExact() public {
        (FirstLossReserve avana, FirstLossReserve offset) = _deployLayers(100e18, 150e18);
        (bytes32 key, address account) = _unhealthy(SIZE, 1500e18, 0.5e8);
        uint256 owed = spoke.getUserTotalDebt(debtReserveId, account);

        (ILiquidationModule.LiquidationResult memory r,) = _checkedLiquidation(liquidator, account, 1e23);
        assertEq(spoke.getUserSuppliedAssets(vtReserveId, account), 0, "all collateral seized");
        assertEq(spoke.getUserTotalDebt(debtReserveId, account), 0, "Aave moves the rest to the deficit");
        assertEq(vault.getPosition(key).credit, 0);
        uint256 deficit = _deficit();
        assertApproxEqAbs(deficit, owed - r.debtRepaid, 1, "the deficit is exactly the unpaid debt");
        assertGt(deficit, 250e18, "larger than both layers together");

        assertEq(_cover(avana), 100e18, "Avana pays its whole balance first");
        assertEq(avana.fundedBalance(), 0);
        assertEq(_deficit(), deficit - 100e18);
        vm.prank(coverageCaller);
        vm.expectRevert(abi.encodeWithSelector(IFirstLossReserve.NothingToCover.selector, aave.cdpSpoke));
        avana.coverDeficit(aave.cdpSpoke, type(uint256).max);

        assertEq(_cover(offset), 150e18, "then the DAO offset");
        assertEq(offset.fundedBalance(), 0);
        assertEq(_deficit(), deficit - 250e18, "the residual stays on the Hub");
        vm.prank(coverageCaller);
        vm.expectRevert(abi.encodeWithSelector(IFirstLossReserve.NothingToCover.selector, aave.cdpSpoke));
        offset.coverDeficit(aave.cdpSpoke, type(uint256).max);
        _assertModuleEmpty();
    }

    /// @notice Bug hunted: a First-Loss Reserve large enough for the whole deficit pays more than it, or the offset
    /// behind it pays as well. Avana's layer pays exactly the deficit and keeps the rest; the offset then has nothing
    /// to cover and its balance does not move.
    function test_reserveCoversTheWholeDeficit_offsetPaysNothing() public {
        (FirstLossReserve avana, FirstLossReserve offset) = _deployLayers(10_000e18, 150e18);
        (, address account) = _unhealthy(SIZE, 1500e18, 0.5e8);
        _checkedLiquidation(liquidator, account, 1e23);
        uint256 deficit = _deficit();
        assertGt(deficit, 0);

        assertEq(_cover(avana), deficit, "exactly the deficit");
        assertEq(avana.fundedBalance(), 10_000e18 - deficit);
        assertEq(IAaveV4Hub(aave.hub).getSpokeDeficitRay(_debtAssetId(), aave.cdpSpoke), 0);
        vm.prank(coverageCaller);
        vm.expectRevert(
            abi.encodeWithSelector(
                IFirstLossReserve.FirstLossLayerNotExhausted.selector, address(avana), 10_000e18 - deficit
            )
        );
        offset.coverDeficit(aave.cdpSpoke, type(uint256).max);
        assertEq(offset.fundedBalance(), 150e18);
    }

    // ─── Helpers ───

    /// @dev Carol pledges `size` of each token, borrows `owed`, and both token prices fall to `price`.
    function _unhealthy(
        uint256 size,
        uint256 owed,
        uint256 price
    ) internal returns (bytes32 key, address account) {
        (key,) = _mintFull(carol, size);
        _pledge(carol, key);
        _borrow(carol, owed);
        _setPrices(price);
        account = adapter.accountOf(carol, MARKET);
        assertLt(_hf(account), 1e18, "liquidatable");
    }

    /// @dev Carol's $20,000 position with $15,000 of debt, at `price`.
    function _unhealthyBig(
        uint256 price
    ) internal returns (bytes32 key, address account) {
        return _unhealthy(BIG, 15_000e18, price);
    }

    function _setPrices(
        uint256 price
    ) internal {
        feed0.set(int256(price));
        feed1.set(int256(price));
    }

    function _hf(
        address account
    ) internal view returns (uint256) {
        return spoke.getUserAccountData(account).healthFactor;
    }

    function _liquidateAs(
        address who,
        address account,
        uint256 cover
    ) internal returns (ILiquidationModule.LiquidationResult memory r) {
        ILiquidationModule.LiquidationParams memory p = _params(account, cover);
        p.receiver = who;
        vm.prank(who);
        r = module.liquidate(p);
    }

    /// @dev Liquidates and checks every amount against Aave's state and prices: the debt and supply moved by exactly
    /// what the result says, the seizure is `repaid · bonus` at the bonus of the health factor before the call, the
    /// vault tokens seized were burned, the credit unwound left the market, the fee is Avana's share of that bonus, the
    /// payout is worth the seized units at the oracle, and nothing stays in the module.
    function _checkedLiquidation(
        address who,
        address account,
        uint256 cover
    ) internal returns (ILiquidationModule.LiquidationResult memory r, uint256 bonus) {
        Before memory b = _before(who, account);
        bonus = b.bonus;
        (uint256 r0, uint256 r1) = (t0.balanceOf(who), t1.balanceOf(who));
        r = _liquidateAs(who, account, cover);

        // The debt fell by the repayment plus whatever Aave moved to the deficit (only when it emptied the account).
        uint256 toDeficit = IAaveV4Hub(aave.hub).getSpokeDeficitRay(_debtAssetId(), aave.cdpSpoke) - b.deficit;
        assertApproxEqAbs(
            b.debt - spoke.getUserTotalDebt(debtReserveId, account), r.debtRepaid + toDeficit / 1e27, 1, "debt moved"
        );
        if (spoke.getUserSuppliedAssets(vtReserveId, account) != 0) {
            assertEq(toDeficit, 0, "no deficit while collateral is left");
        }
        assertEq(b.payer - debt.balanceOf(who), r.debtRepaid, "the liquidator paid only what Aave took");
        assertEq(b.supply - spoke.getUserSuppliedAssets(vtReserveId, account), r.seized, "supply moved by the seizure");
        assertEq(b.vtSupply - vt.totalSupply(), r.seized, "every seized unit burned");
        assertEq(b.totalCredit - vault.getMarket(MARKET).totalCredit, r.creditUnwound, "credit unwound");
        IAaveV4Oracle o = IAaveV4Oracle(spoke.ORACLE());
        uint256 pVt = o.getReservePrice(vtReserveId);
        uint256 pDebt = o.getReservePrice(debtReserveId);
        if (spoke.getUserSuppliedAssets(vtReserveId, account) != 0) {
            // Not capped by the collateral: Aave's bonus on the debt repaid, rounded down.
            assertApproxEqAbs(
                r.seized, Math.mulDiv(r.debtRepaid, pDebt * bonus, pVt * 10_000), 2, "seized = repaid x bonus"
            );
        } else {
            // Capped: all collateral, for no more debt than it is worth at the bonus.
            assertLe(r.debtRepaid, Math.mulDiv(r.seized, pVt * 10_000, pDebt * bonus, Math.Rounding.Ceil) + 1);
        }
        assertEq(r.feeUnits, LiquidationMath.feeUnits(r.seized, bonus, 2000), "Avana's share of Aave's bonus");
        assertEq(t0.balanceOf(who) - r0, r.amount0);
        assertEq(t1.balanceOf(who) - r1, r.amount1);
        if (spoke.getUserSuppliedAssets(vtReserveId, account) != 0) {
            // Worth at the module's own unit value: Aave's vault-token price is that value cut to 8 decimals, so Aave
            // seizes up to 1e-8 more units than the debt's worth, and those units are the borrower's to give.
            uint256 paid = _usd(r.amount0 + r.fee0, r.amount1 + r.fee1);
            uint256 worth = Math.mulDiv(r.seized, _unitValue(), 1e18);
            assertLe(paid, worth + 1e6, "never more than the seized units are worth");
            assertApproxEqRel(paid, worth, 1e9, "the liquidity worth the seized units");
        }
        _assertModuleEmpty();
        _assertCustody(account);
    }

    function _before(
        address who,
        address account
    ) internal view returns (Before memory b) {
        b.hf = _hf(account);
        b.bonus = spoke.getLiquidationBonus(vtReserveId, account, b.hf);
        b.supply = spoke.getUserSuppliedAssets(vtReserveId, account);
        b.debt = spoke.getUserTotalDebt(debtReserveId, account);
        b.vtSupply = vt.totalSupply();
        b.totalCredit = vault.getMarket(MARKET).totalCredit;
        b.payer = debt.balanceOf(who);
        b.deficit = IAaveV4Hub(aave.hub).getSpokeDeficitRay(_debtAssetId(), aave.cdpSpoke);
    }

    /// @dev Every record of the account matches its NFT, and its supply is backed by its credit.
    function _assertCustody(
        address account
    ) internal view {
        bytes32[] memory keys = vault.positionsOf(account);
        for (uint256 i; i < keys.length; ++i) {
            assertEq(
                INfpmPositions(address(nfpm)).positions(uint256(keys[i])).liquidity,
                vault.getPosition(keys[i]).liquidity,
                "NFT liquidity = record"
            );
        }
        assertLe(spoke.getUserSuppliedAssets(vtReserveId, account), vault.accountCredit(account, MARKET));
    }

    function _assertModuleEmpty() internal view {
        assertEq(t0.balanceOf(address(module)), 0, "module token0");
        assertEq(t1.balanceOf(address(module)), 0, "module token1");
        assertEq(debt.balanceOf(address(module)), 0, "module debt");
        assertEq(vt.balanceOf(address(module)), 0, "module vault token");
        assertEq(debt.allowance(address(module), aave.cdpSpoke), 0, "module allowance");
    }

    /// @dev 18-decimal USD value of pool-token amounts at Aave's prices.
    function _usd(
        uint256 a0,
        uint256 a1
    ) internal view returns (uint256) {
        IAaveV4Oracle o = IAaveV4Oracle(IAaveV4Spoke(aave.lendSpoke).ORACLE());
        return LiquidationMath.value(a0, a1, o.getReservePrice(priceReserve0), o.getReservePrice(priceReserve1), 18, 18);
    }

    /// @dev 18-decimal USD value of one whole vault token at Aave's token prices, as the module computes it.
    function _unitValue() internal view returns (uint256) {
        (uint256 u0, uint256 u1) = oracle.getUnitAmounts();
        return _usd(u0, u1);
    }

    function _debtAssetId() internal view returns (uint256) {
        return spoke.getReserve(debtReserveId).assetId;
    }

    /// @dev `ceil(deficitRay / RAY)` of the CDP Spoke in the debt asset.
    function _deficit() internal view returns (uint256) {
        return Math.ceilDiv(IAaveV4Hub(aave.hub).getSpokeDeficitRay(_debtAssetId(), aave.cdpSpoke), RAY);
    }

    function _cover(
        FirstLossReserve layer
    ) internal returns (uint256 covered) {
        vm.prank(coverageCaller);
        (, covered) = layer.coverDeficit(aave.cdpSpoke, type(uint256).max);
    }

    /// @dev Avana's First-Loss Reserve and the DAO Deficit Offset behind it for the debt asset, listed on the Hub with
    /// no draw cap, holding the deficit-eliminator role, allowing the CDP Spoke, and funded with the given amounts.
    function _deployLayers(
        uint256 avanaFunds,
        uint256 offsetFunds
    ) internal returns (FirstLossReserve avana, FirstLossReserve offset) {
        avana = _deployLayer(address(0), avanaFunds);
        offset = _deployLayer(address(avana), offsetFunds);
    }

    function _deployLayer(
        address inFront,
        uint256 funds
    ) internal returns (FirstLossReserve layer) {
        uint256 assetId = _debtAssetId();
        layer = new FirstLossReserve(aave.hub, address(debt), assetId, aave.accessManager, inFront);
        IAaveV4Hub hubView = IAaveV4Hub(aave.hub);
        HubSpokeConfig memory config =
            HubSpokeConfig(hubView.MAX_ALLOWED_SPOKE_CAP(), 0, hubView.MAX_RISK_PREMIUM_THRESHOLD(), true, false);
        vm.prank(aaveDao);
        IHubConfiguratorCalls(aave.hubConfigurator).addSpoke(aave.hub, address(layer), assetId, config);
        _grantDeficitEliminator(address(layer));
        bytes4[] memory coverage = new bytes4[](1);
        coverage[0] = IFirstLossReserve.coverDeficit.selector;
        bytes4[] memory admin = new bytes4[](1);
        admin[0] = IFirstLossReserve.setAllowedSpoke.selector;
        IAccessManager manager = IAccessManager(aave.accessManager);
        vm.startPrank(aaveDao);
        manager.setTargetFunctionRole(address(layer), coverage, COVERAGE_ROLE);
        manager.setTargetFunctionRole(address(layer), admin, COVERAGE_ROLE + 1);
        manager.grantRole(COVERAGE_ROLE, coverageCaller, 0);
        manager.grantRole(COVERAGE_ROLE + 1, aaveGovernanceExecutor, 0);
        vm.stopPrank();
        vm.prank(aaveGovernanceExecutor);
        layer.setAllowedSpoke(aave.cdpSpoke, true);
        debt.mint(avanaLabs, funds);
        vm.startPrank(avanaLabs);
        debt.approve(address(layer), funds);
        layer.fund(funds);
        vm.stopPrank();
    }
}
