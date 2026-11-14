// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAaveV4Hub} from "../../src/interfaces/external/aave/IAaveV4Hub.sol";
import {IAaveV4Spoke} from "../../src/interfaces/external/aave/IAaveV4Spoke.sol";
import {
    GvDynamicReserveConfig,
    GvHubSpokeConfig,
    GvInterestRateData,
    GvPrice,
    GvReserveConfig,
    GvToken,
    IGvHubConfigurator,
    IGvSpokeConfigurator
} from "../integration/GoldenVectors.integration.t.sol";
import {Deployments} from "../utils/Deployments.sol";
import {Test} from "forge-std/Test.sol";

/// @dev Hub views of aave-v4 a3ef63e this suite reads beyond `IAaveV4Hub`.
interface IBalancesHubViews {
    function getAssetDrawnIndex(
        uint256 assetId
    ) external view returns (uint256);
    function getAssetPremiumData(
        uint256 assetId
    ) external view returns (uint256 premiumShares, int256 premiumOffsetRay);
    function getSpokeDrawnShares(
        uint256 assetId,
        address spoke
    ) external view returns (uint256);
    function getSpokePremiumData(
        uint256 assetId,
        address spoke
    ) external view returns (uint256 premiumShares, int256 premiumOffsetRay);
    function getSpokeOwed(
        uint256 assetId,
        address spoke
    ) external view returns (uint256 drawn, uint256 premium);
}

/// @notice Borrowers on the CDP Spoke (collateral, borrow and repay of each debt reserve), a lender on the Lend Spoke
/// (supply and withdraw of each asset, which moves the Hub's liquidity) and time (interest and premium accrual).
contract BalancesHandler is Test {
    /// @notice A call that found nothing to act on, or that the contract refused: reverting keeps it out of the
    /// campaign's success count, so the metrics show the calls that did real work.
    error Skipped();

    uint256 internal constant N_BORROWERS = 3;

    address public immutable hub;
    IAaveV4Spoke public immutable cdp;
    IAaveV4Spoke public immutable lend;
    GvToken public immutable coll;
    uint256 public immutable collReserve;
    address public immutable lender;

    GvToken[2] public debts;
    uint256[2] public assetIds;
    uint256[2] public debtReserves;
    uint256[2] public lendReserves;
    uint256[2] public drawCaps;
    address[N_BORROWERS] public borrowers;

    /// @notice Borrows that completed with the CDP Spoke's owed amount (plus deficit) above its draw cap.
    uint256 public drawCapViolations;
    /// @notice Borrows that completed for more than the Hub's liquidity of the asset before the call.
    uint256 public liquidityViolations;
    /// @notice Completed actions, so a campaign that only reverts is visible.
    uint256 public borrowsDone;
    uint256 public repaysDone;
    uint256 public lenderWithdrawalsDone;

    constructor(
        address hub_,
        IAaveV4Spoke cdp_,
        IAaveV4Spoke lend_,
        GvToken coll_,
        uint256 collReserve_,
        GvToken[2] memory debts_,
        uint256[2] memory assetIds_,
        uint256[2] memory debtReserves_,
        uint256[2] memory lendReserves_,
        uint256[2] memory drawCaps_,
        address lender_
    ) {
        hub = hub_;
        cdp = cdp_;
        lend = lend_;
        coll = coll_;
        collReserve = collReserve_;
        debts = debts_;
        assetIds = assetIds_;
        debtReserves = debtReserves_;
        lendReserves = lendReserves_;
        drawCaps = drawCaps_;
        lender = lender_;
        for (uint256 i; i < N_BORROWERS; ++i) {
            borrowers[i] = makeAddr(string.concat("balancesBorrower", vm.toString(i)));
        }
    }

    function borrowerCount() external pure returns (uint256) {
        return N_BORROWERS;
    }

    function supplyCollateral(
        uint256 actor,
        uint256 amount
    ) public {
        address user = borrowers[actor % N_BORROWERS];
        amount = bound(amount, 1e18, 1_000_000e18);
        coll.mint(user, amount);
        vm.startPrank(user);
        coll.approve(address(cdp), amount);
        cdp.supply(collReserve, amount, user);
        cdp.setUsingAsCollateral(collReserve, true, user);
        vm.stopPrank();
    }

    function borrow(
        uint256 actor,
        uint256 reserve,
        uint256 amount
    ) public {
        address user = borrowers[actor % N_BORROWERS];
        uint256 r = reserve % 2;
        uint256 unit = 10 ** debts[r].decimals();
        amount = bound(amount, 1, 400_000 * unit);
        uint256 liquidityBefore = IAaveV4Hub(hub).getAssetLiquidity(assetIds[r]);
        (uint256 drawn, uint256 premium) = IBalancesHubViews(hub).getSpokeOwed(assetIds[r], address(cdp));
        uint256 deficit = IAaveV4Hub(hub).getSpokeDeficitRay(assetIds[r], address(cdp));
        uint256 owedBefore = drawn + premium + (deficit + 1e27 - 1) / 1e27;
        vm.prank(user);
        try cdp.borrow(debtReserves[r], amount, user) {
            ++borrowsDone;
            if (amount > liquidityBefore) ++liquidityViolations;
            if (owedBefore + amount > drawCaps[r] * unit) ++drawCapViolations;
        } catch {
            revert Skipped();
        }
    }

    function repay(
        uint256 actor,
        uint256 reserve,
        uint256 amount
    ) public {
        address user = borrowers[actor % N_BORROWERS];
        uint256 r = reserve % 2;
        uint256 owed = cdp.getUserTotalDebt(debtReserves[r], user);
        if (owed == 0) revert Skipped();
        amount = bound(amount, 1, owed);
        debts[r].mint(user, amount);
        vm.startPrank(user);
        debts[r].approve(address(cdp), amount);
        try cdp.repay(debtReserves[r], amount, user) {
            ++repaysDone;
        } catch {
            revert Skipped();
        }
        vm.stopPrank();
    }

    function lenderSupply(
        uint256 reserve,
        uint256 amount
    ) public {
        uint256 r = reserve % 2;
        amount = bound(amount, 1, 500_000 * 10 ** debts[r].decimals());
        debts[r].mint(lender, amount);
        vm.startPrank(lender);
        debts[r].approve(address(lend), amount);
        lend.supply(lendReserves[r], amount, lender);
        vm.stopPrank();
    }

    function lenderWithdraw(
        uint256 reserve,
        uint256 amount
    ) public {
        uint256 r = reserve % 2;
        amount = bound(amount, 1, 2_000_000 * 10 ** debts[r].decimals());
        vm.prank(lender);
        try lend.withdraw(lendReserves[r], amount, lender) {
            ++lenderWithdrawalsDone;
        } catch {
            revert Skipped();
        }
    }

    function warp(
        uint256 secondsAhead
    ) public {
        vm.warp(block.timestamp + bound(secondsAhead, 1, 30 days));
    }
}

/// @title BalancesInvariantTest
/// @notice Debt accounting per debt reserve on the pinned Aave V4 Hub and the standard CDP Spoke Avana deploys, with two
/// debt reserves (GHO-like, 18 decimals; USDC-like, 6 decimals), a collateral reserve with collateral risk so premium
/// shares accrue, finite draw caps and a lender who supplies and withdraws on the Lend Spoke.
contract BalancesInvariantTest is Deployments {
    BalancesHandler internal handler;
    GvToken internal coll;
    GvToken[2] internal debts;
    uint256[2] internal assetIds;
    uint256[2] internal debtReserves;
    address internal lender = makeAddr("balancesLender");
    bytes internal irData;
    GvPrice internal one;

    function setUp() public {
        _deployAaveV4();
        irData = abi.encode(GvInterestRateData(9000, 200, 400, 6000));
        debts[0] = new GvToken("GHO", 18);
        debts[1] = new GvToken("USDC", 6);
        coll = new GvToken("COLL", 18);
        one = new GvPrice(1e8);
        uint256[2] memory drawCaps = [uint256(1_000_000), uint256(600_000)];
        uint256[2] memory lendReserves;
        for (uint256 r; r < 2; ++r) {
            lendReserves[r] = _listDebt(r, uint40(drawCaps[r]));
        }
        uint256 collReserve = _listCollateral();

        handler = new BalancesHandler(
            aave.hub,
            IAaveV4Spoke(aave.cdpSpoke),
            IAaveV4Spoke(aave.lendSpoke),
            coll,
            collReserve,
            debts,
            assetIds,
            debtReserves,
            lendReserves,
            drawCaps,
            lender
        );
        // Opening liquidity, so borrows can complete from the first call.
        handler.lenderSupply(0, 500_000e18);
        handler.lenderSupply(1, 300_000e6);
        targetContract(address(handler));
    }

    function _hubCfg(
        uint40 addCap,
        uint40 drawCap
    ) internal view returns (GvHubSpokeConfig memory) {
        return GvHubSpokeConfig(addCap, drawCap, IAaveV4Hub(aave.hub).MAX_RISK_PREMIUM_THRESHOLD(), true, false);
    }

    function _listDebt(
        uint256 r,
        uint40 drawCap
    ) internal returns (uint256 lendReserve) {
        uint40 maxCap = IAaveV4Hub(aave.hub).MAX_ALLOWED_SPOKE_CAP();
        vm.startPrank(aaveDao);
        assetIds[r] = IGvHubConfigurator(aave.hubConfigurator)
            .addAssetWithDecimals(
                aave.hub, address(debts[r]), debts[r].decimals(), aave.treasurySpoke, 1000, aave.irStrategy, irData
            );
        IGvHubConfigurator(aave.hubConfigurator).addSpoke(aave.hub, aave.lendSpoke, assetIds[r], _hubCfg(maxCap, 0));
        IGvHubConfigurator(aave.hubConfigurator).addSpoke(aave.hub, aave.cdpSpoke, assetIds[r], _hubCfg(0, drawCap));
        lendReserve = _addReserve(aave.lendSpoke, assetIds[r], address(one), 0, true, 0);
        debtReserves[r] = _addReserve(aave.cdpSpoke, assetIds[r], address(one), 0, true, 0);
        vm.stopPrank();
    }

    function _listCollateral() internal returns (uint256 collReserve) {
        GvPrice ten = new GvPrice(10e8);
        vm.startPrank(aaveDao);
        uint256 collAsset = IGvHubConfigurator(aave.hubConfigurator)
            .addAssetWithDecimals(aave.hub, address(coll), 18, aave.treasurySpoke, 0, aave.irStrategy, irData);
        IGvHubConfigurator(aave.hubConfigurator)
            .addSpoke(aave.hub, aave.cdpSpoke, collAsset, _hubCfg(IAaveV4Hub(aave.hub).MAX_ALLOWED_SPOKE_CAP(), 0));
        // Collateral risk 20 %, so every borrower carries premium shares.
        collReserve = _addReserve(aave.cdpSpoke, collAsset, address(ten), 2000, false, 8000);
        vm.stopPrank();
    }

    function _addReserve(
        address spoke,
        uint256 assetId,
        address price,
        uint24 collateralRisk,
        bool borrowable,
        uint16 collateralFactor
    ) internal returns (uint256) {
        return IGvSpokeConfigurator(aave.spokeConfigurator)
            .addReserve(
                spoke,
                aave.hub,
                assetId,
                price,
                GvReserveConfig(collateralRisk, false, false, borrowable, false),
                GvDynamicReserveConfig(collateralFactor, borrowable ? 10_000 : 10_500, 0)
            );
    }

    // TEST-103 verifies: INV-057
    // Sources: 5.1 TEST-103, QNT-31, HYP-07
    /// @notice For each debt asset, the Hub's drawn shares equal the CDP Spoke's and the sum over its borrowers.
    function invariant_TEST_103_drawnSharesAgree() public view {
        for (uint256 r; r < 2; ++r) {
            uint256 sum;
            for (uint256 i; i < handler.borrowerCount(); ++i) {
                sum += IAaveV4Spoke(aave.cdpSpoke).getUserPosition(debtReserves[r], handler.borrowers(i)).drawnShares;
            }
            uint256 spokeShares = IBalancesHubViews(aave.hub).getSpokeDrawnShares(assetIds[r], aave.cdpSpoke);
            assertEq(IAaveV4Hub(aave.hub).getAssetDrawnShares(assetIds[r]), spokeShares, "hub vs spoke drawn shares");
            assertEq(spokeShares, sum, "spoke drawn shares vs sum over users");
        }
    }

    // TEST-103 verifies: INV-057
    // Sources: 5.1 TEST-103, QNT-31, HYP-07
    /// @notice For each debt asset, the Hub's premium shares and premium offset equal the CDP Spoke's and the sums over
    /// its borrowers.
    function invariant_TEST_103_premiumSharesAgree() public view {
        for (uint256 r; r < 2; ++r) {
            uint256 sumShares;
            int256 sumOffset;
            for (uint256 i; i < handler.borrowerCount(); ++i) {
                IAaveV4Spoke.UserPosition memory p =
                    IAaveV4Spoke(aave.cdpSpoke).getUserPosition(debtReserves[r], handler.borrowers(i));
                sumShares += p.premiumShares;
                sumOffset += p.premiumOffsetRay;
            }
            (uint256 hubShares, int256 hubOffset) = IBalancesHubViews(aave.hub).getAssetPremiumData(assetIds[r]);
            (uint256 spokeShares, int256 spokeOffset) =
                IBalancesHubViews(aave.hub).getSpokePremiumData(assetIds[r], aave.cdpSpoke);
            assertEq(hubShares, spokeShares, "hub vs spoke premium shares");
            assertEq(hubOffset, spokeOffset, "hub vs spoke premium offset");
            assertEq(spokeShares, sumShares, "spoke premium shares vs sum over users");
            assertEq(spokeOffset, sumOffset, "spoke premium offset vs sum over users");
        }
    }

    // TEST-103 verifies: INV-057
    // Sources: 5.1 TEST-103
    /// @notice No borrower's debt in any reserve is negative: the premium part `premiumShares × index − offset` is at
    /// least 0, and the total debt is at least the drawn part.
    function invariant_TEST_103_userDebtNeverNegative() public view {
        for (uint256 r; r < 2; ++r) {
            uint256 index = IBalancesHubViews(aave.hub).getAssetDrawnIndex(assetIds[r]);
            for (uint256 i; i < handler.borrowerCount(); ++i) {
                address user = handler.borrowers(i);
                IAaveV4Spoke.UserPosition memory p = IAaveV4Spoke(aave.cdpSpoke).getUserPosition(debtReserves[r], user);
                assertGe(int256(uint256(p.premiumShares) * index), int256(p.premiumOffsetRay), "premium debt >= 0");
                assertGe(
                    IAaveV4Spoke(aave.cdpSpoke).getUserTotalDebt(debtReserves[r], user),
                    uint256(p.drawnShares) * index / 1e27,
                    "total debt >= drawn part"
                );
            }
        }
    }

    // TEST-103 verifies: INV-057
    // Sources: 5.1 TEST-103, MATH-AR-20
    /// @notice Every completed borrow stayed within the CDP Spoke's draw cap and the Hub's liquidity, the Hub holds the
    /// liquidity it records.
    function invariant_TEST_103_drawWithinCapAndLiquidity() public view {
        assertEq(handler.drawCapViolations(), 0, "borrow above draw cap");
        assertEq(handler.liquidityViolations(), 0, "borrow above Hub liquidity");
        for (uint256 r; r < 2; ++r) {
            uint256 liquidity = IAaveV4Hub(aave.hub).getAssetLiquidity(assetIds[r]);
            assertGe(debts[r].balanceOf(aave.hub), liquidity, "Hub holds its recorded liquidity");
        }
    }

    // TEST-103 verifies: INV-057
    // Sources: 5.1 TEST-103
    /// @notice The handler's actions reach the Hub in a plain sequence (so the campaign is not vacuous): borrows of both
    /// reserves accrue premium shares, a borrow above the draw cap and one above the Hub's liquidity are refused, the
    /// lender's withdrawal moves the liquidity, and repay reduces the drawn shares; the invariants hold after each step.
    function test_TEST_103_handlerActionsReachTheHub() public {
        handler.supplyCollateral(0, 1_000_000e18);
        handler.borrow(0, 0, 100_000e18);
        handler.borrow(0, 1, 50_000e6);
        assertEq(handler.borrowsDone(), 2, "both borrows complete");
        (uint256 premiumShares,) = IBalancesHubViews(aave.hub).getAssetPremiumData(assetIds[0]);
        assertGt(premiumShares, 0, "collateral risk gives premium shares");

        // Above the Hub's liquidity: refused (USDC liquidity is 250,000 after the borrow).
        uint256 before = handler.borrowsDone();
        vm.expectRevert(BalancesHandler.Skipped.selector);
        handler.borrow(0, 1, 260_000e6);
        assertEq(handler.borrowsDone(), before, "borrow above liquidity refused");

        handler.warp(30 days);
        handler.lenderWithdraw(0, 100_000e18);
        assertEq(handler.lenderWithdrawalsDone(), 1, "lender withdrawal moves the liquidity");
        uint256 sharesBefore = IAaveV4Hub(aave.hub).getAssetDrawnShares(assetIds[0]);
        handler.repay(0, 0, 50_000e18);
        assertEq(handler.repaysDone(), 1, "repay completes");
        assertLt(IAaveV4Hub(aave.hub).getAssetDrawnShares(assetIds[0]), sharesBefore, "repay lowers drawn shares");

        // Above the draw cap: with the cap at 1,000,000 GHO and liquidity added, a borrow past the cap is refused.
        handler.lenderSupply(0, 500_000e18);
        handler.lenderSupply(0, 500_000e18);
        handler.supplyCollateral(1, 1_000_000e18);
        handler.supplyCollateral(1, 1_000_000e18);
        before = handler.borrowsDone();
        handler.borrow(1, 0, 400_000e18);
        handler.borrow(1, 0, 400_000e18);
        vm.expectRevert(BalancesHandler.Skipped.selector);
        handler.borrow(1, 0, 400_000e18);
        assertEq(handler.borrowsDone(), before + 2, "the third borrow would pass the draw cap and is refused");

        invariant_TEST_103_drawnSharesAgree();
        invariant_TEST_103_premiumSharesAgree();
        invariant_TEST_103_userDebtNeverNegative();
        invariant_TEST_103_drawWithinCapAndLiquidity();
    }
}
