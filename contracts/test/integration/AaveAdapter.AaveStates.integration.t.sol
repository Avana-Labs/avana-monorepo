// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAaveV4Hub} from "../../src/interfaces/external/aave/IAaveV4Hub.sol";
import {LiquidationPreview} from "../../src/lens/lens/types/LiquidationPreview.sol";
import {TailCoverageView} from "../../src/lens/lens/types/TailCoverageView.sol";
import {LiquidationResult} from "../../src/liquidation/lp-vault-swap/types/LiquidationResult.sol";
import {FlashLiquidationRequest} from "../../src/periphery/flash-liquidator/types/FlashLiquidationRequest.sol";
import {IRiskModuleErrors} from "../../src/policy/risk-module/IRiskModuleErrors.sol";
import {PauseReason} from "../../src/types/PauseReason.sol";
import {PauseState} from "../../src/types/PauseState.sol";
import {IntegrationFlows} from "../utils/fixtures/IntegrationFlows.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

interface IStatesSpokeConfigurator {
    function updateFrozen(
        address spoke,
        uint256 reserveId,
        bool frozen
    ) external;
    function updatePaused(
        address spoke,
        uint256 reserveId,
        bool paused
    ) external;
}

/// @title AaveAdapterAaveStatesIntegrationTest
/// @notice Aave-side reserve states, a debt-price rise and the Lens's tail coverage with the real AaveAdapter,
/// RiskModule, Collateralization, LPVaultSwap and Lens on the local Aave V4 Hub and Spokes: an Aave freeze or pause of
/// one reserve stops only what Aave or the RiskModule's own read of it stops, and no Avana timer applies.
/// forge-config: default.isolate = false
contract AaveAdapterAaveStatesIntegrationTest is IntegrationFlows {
    bytes4 internal constant AAVE_RESERVE_PAUSED = bytes4(keccak256("ReservePaused()"));

    function setUp() public {
        _deployIntegration();
    }

    function _cfg() internal view returns (IStatesSpokeConfigurator) {
        return IStatesSpokeConfigurator(aave.spokeConfigurator);
    }

    function _expectBorrow(
        address wallet,
        uint256 reserveId,
        uint256 amount,
        bytes memory err
    ) internal {
        address proxy = adapterC.proxyOf(wallet, MARKET_ID);
        uint256 nonce = adapterC.borrowNonce(proxy);
        uint256 d = _deadline();
        vm.expectRevert(err);
        vm.prank(wallet);
        adapterC.borrow(MARKET_ID, reserveId, amount, wallet, d, 0, nonce);
    }

    // TEST-169 verifies: REQ-ADAPTER-061, REQ-ADAPTER-062, REQ-RISK-061, Q-192, Q-202
    // Sources: 5.1 TEST-169 (Aave-side reserve pause on the real local Aave V4 Spoke)
    /// @notice The Aave Protocol Guardian pauses the vault-token reserve: borrow and a withdrawal that leaves debt
    /// revert in the RiskModule with `AaveReservePaused(reserveId)` and a liquidation in the market is blocked, still so
    /// three days later (no Avana timer or expiry). Then the USDC debt reserve is paused instead: a borrow reverts
    /// `DebtReservePaused(reserveId)` and a USDC repay is refused by Aave's own `ReservePaused()`, never by Avana. After
    /// the unpause every flow works again with no Avana action.
    function test_TEST_169_aaveReservePauseStopsOnlyWhatAaveStops() public {
        (address pA,) = _openAccount(alice, MARKET_ID, 10_000e6, 4000e6, P_VAULT);
        (bytes32 kA2,) = _pledgeVia(alice, MARKET_ID, 2000e6);
        (address pB,) = _bobAccount();
        uint256 vtReserve = _vtReserve(MARKET_ID);

        vm.prank(aaveDao);
        _cfg().updatePaused(aave.cdpSpoke, vtReserve, true);
        for (uint256 i = 0; i < 2; ++i) {
            bytes memory err = abi.encodeWithSelector(IRiskModuleErrors.AaveReservePaused.selector, vtReserve);
            _expectBorrow(alice, debtReserveId, 1e18, err);
            uint256 d = _deadline();
            vm.expectRevert(err);
            vm.prank(alice);
            adapterC.withdraw(MARKET_ID, _ref(kA2), 2000e6, d, 0);
            LiquidationResult memory none;
            _fundCaller(keeper, _liqParams(pB, MARKET_ID, usdcReserveId, 1950e6));
            vm.expectRevert();
            vm.prank(keeper);
            none = lvs.liquidate(_liqParams(pB, MARKET_ID, usdcReserveId, 1950e6));
            // Three days on, with fresh feed rounds: still refused for the same Aave reason, no Avana expiry.
            vm.warp(block.timestamp + 3 days);
            _refreshPrices();
        }

        vm.startPrank(aaveDao);
        _cfg().updatePaused(aave.cdpSpoke, vtReserve, false);
        _cfg().updatePaused(aave.cdpSpoke, usdcReserveId, true);
        vm.stopPrank();
        _refreshPrices();
        _expectBorrow(
            alice,
            debtReserveId,
            1e18,
            abi.encodeWithSelector(IRiskModuleErrors.DebtReservePaused.selector, usdcReserveId)
        );
        usdc.mint(carol, 100e6);
        vm.startPrank(carol);
        usdc.approve(adapter, 100e6);
        vm.expectRevert(AAVE_RESERVE_PAUSED);
        adapterC.repay(alice, MARKET_ID, usdcReserveId, 100e6, false, _deadline());
        vm.stopPrank();

        vm.prank(aaveDao);
        _cfg().updatePaused(aave.cdpSpoke, usdcReserveId, false);
        _repayVia(carol, alice, MARKET_ID, usdcReserveId, 100e6, false);
        _borrowVia(alice, MARKET_ID, debtReserveId, 1e18);
        assertEq(_debtOf(pA, debtReserveId), 1e18, "borrowing reopened by the DAO unpause alone");
        LiquidationResult memory r = _liquidateAs(keeper, _liqParams(pB, MARKET_ID, usdcReserveId, 1950e6));
        assertEq(r.debtRepaid, 1950e6, "liquidation reopened");
    }

    // TEST-035 verifies: Q-051, Q-118, Q-203
    // Sources: 5.1 TEST-035 (the Adapter has no pause selector; an Aave freeze contains one market)
    /// @notice The Adapter holds no pause, freeze or per-market switch. Containing one market is the Aave freeze of its
    /// vault-token reserve: a borrow against it reverts `ReserveFrozen`, while a liquidation in that market, a
    /// third-party repay, fee collection and a debt-free withdrawal all succeed.
    function test_TEST_035_aaveFreezeContainsOneMarketAndLeavesItsExitsOpen() public {
        string[8] memory absent = [
            "pause()",
            "unpause()",
            "freeze(address)",
            "pauseMarket(uint256)",
            "freezeMarket(uint256)",
            "pauseFunction(bytes4)",
            "setMarketOffboarding(uint256)",
            "setPaused(bool)"
        ];
        for (uint256 i = 0; i < absent.length; ++i) {
            (bool ok,) = adapter.call(abi.encodeWithSignature(absent[i], uint256(MARKET_ID)));
            assertFalse(ok, absent[i]);
        }
        (address pA, bytes32 kA) = _openAccount(alice, MARKET_ID, 10_000e6, 4000e6, P_VAULT);
        (bytes32 kC,) = _pledgeVia(carol, MARKET_ID, 1000e6);
        (address pB,) = _bobAccount();
        uint256 vtReserve = _vtReserve(MARKET_ID);
        vm.prank(aaveDao);
        _cfg().updateFrozen(aave.cdpSpoke, vtReserve, true);

        _expectBorrow(
            alice, usdcReserveId, 1e6, abi.encodeWithSelector(IRiskModuleErrors.ReserveFrozen.selector, vtReserve)
        );
        LiquidationResult memory r = _liquidateAs(keeper, _liqParams(pB, MARKET_ID, usdcReserveId, 1950e6));
        assertEq(r.debtRepaid, 1950e6, "liquidation of the frozen market");
        _repayVia(carol, alice, MARKET_ID, usdcReserveId, 500e6, false);
        assertEq(_debtOf(pA, usdcReserveId), 3500e6, "third-party repay");
        vault.accrueFees(kA, 7e6);
        vm.prank(alice);
        adapterC.collectFees(MARKET_ID, _ref(kA), _deadline());
        assertEq(usdt.balanceOf(alice), 7e6, "fees collected");
        _withdrawVia(carol, MARKET_ID, kC, 1000e6);
        assertEq(vault.ownerOf(kC), carol, "debt-free withdrawal");
    }

    // TEST-235 verifies: REQ-RISK-047
    // Sources: 2.7 REQ-RISK-047 (a failed pledge check reverts the whole pledge, custody included)
    /// @notice Under Paused(General), an account at HF 1.05 tops up: a charge within the restore amount passes as a
    /// rescue; one above it reverts `NotRescueTopUp` inside Collateralization's `checkPledge` call, and the whole
    /// pledge unwinds: the NFT stays with the wallet, no record opens, nothing is credited and no vault token is
    /// minted or supplied.
    function test_TEST_235_refusedTopUpMovesNothing() public {
        (address pA,) = _openAccount(alice, MARKET_ID, 10_000e6, 16_000e6, P_VAULT);
        reg.setPause(aave.hub, PauseState.Paused, PauseReason.General);
        _pledgeVia(alice, MARKET_ID, 400e6);
        uint256 records = lens.getRecords(pA, 0, 16).length;
        uint256 credited = coll.getAccountCredited(pA, vt);
        uint256 supply = token.totalSupply();
        uint256 supplied = _suppliedOf(pA, MARKET_ID);
        bytes32 k = _newKey();
        vault.mintPosition(k, alice, MARKET_ID, 2000e6);
        uint256 d = _deadline();
        vm.expectPartialRevert(IRiskModuleErrors.NotRescueTopUp.selector);
        vm.prank(alice);
        adapterC.pledge(MARKET_ID, _ref(k), d);
        assertEq(vault.ownerOf(k), alice, "the NFT never left the wallet");
        assertEq(lens.getRecords(pA, 0, 16).length, records, "no record opened");
        assertEq(coll.getAccountCredited(pA, vt), credited, "nothing credited");
        assertEq(token.totalSupply(), supply, "no vault token minted");
        assertEq(_suppliedOf(pA, MARKET_ID), supplied, "nothing supplied to Aave");
        assertFalse(lock.isLocked(), "Lock free");
    }

    // TEST-247 verifies: SPEC-CAP-008
    // Sources: 2.7 SPEC-CAP-008 (tail coverage ratio)
    /// @notice The Lens's tail coverage of GHO on the Stable LP Hub against the formula: per pool token other than GHO,
    /// `tail = min(⌈(tokenUsdCap + Σ topUpSliceUsd) × CF / 10^4⌉, drawCapUsd)`, and the ratio
    /// `⌊fundedUsd × 10^4 / max tail⌋`; the tail rounds up and the ratio down.
    function test_TEST_247_tailCoverageMatchesTheSizingFormula() public {
        store.setTokenCap(aave.hub, address(usdc), 300_000e8 + 1);
        store.setTokenCap(aave.hub, address(usdt), 250_000e8);
        store.setCaps(MARKET_ID, 1e30, 20_000e8, 0);
        store.setCaps(MARKET_B, 1e30, 10_000e8, 0);
        debt.mint(address(this), 70_000e18);
        debt.approve(address(ghoCoverage), 70_000e18);
        ghoCoverage.fund(70_000e18);

        TailCoverageView memory t = lens.getTailCoverage(aave.hub, address(debt));
        uint256 capSum = uint256(IAaveV4Hub(aave.hub).getSpokeConfig(ghoAssetId, aave.cdpSpoke).drawCap)
            + uint256(IAaveV4Hub(aave.hub).getSpokeConfig(ghoAssetId, cdp[SLIPSTREAM].spoke).drawCap);
        assertEq(t.drawCapUsd, capSum * 1e8, "draw caps at GHO's $1.00");
        assertEq(t.fundedUsd, ghoCoverage.fundedBalance() * 1e8 / 1e18, "funded at $1.00");
        // USDC: ⌈(300,000.00000001 + 20,000 + 10,000) × 0.8⌉ = 264,000.00000001; USDT: (250,000 + 30,000) × 0.8.
        uint256 usdcTail = Math.mulDiv(330_000e8 + 1, 8000, 1e4, Math.Rounding.Ceil);
        assertEq(usdcTail, 264_000e8 + 1, "the tail rounds up");
        assertLt(usdcTail, t.drawCapUsd, "below the draw caps");
        assertEq(t.worstToken, address(usdc), "USDC has the largest tail");
        assertEq(t.tailUsd, usdcTail, "tail");
        assertEq(t.ratioBps, t.fundedUsd * 1e4 / usdcTail, "ratio rounds down");
        assertLt(t.ratioBps * usdcTail, t.fundedUsd * 1e4, "strictly down here: never overstates coverage");
    }

    // TEST-202 verifies: Q-238, Q-233, Q-234, Q-235
    // Sources: 5.1 TEST-202 (debt-asset price rally, WETH debt)
    /// @notice Two accounts with stable-LP collateral and WETH debt opened at HF about 1.15 see the WETH feed rise 25 %
    /// with every collateral price unchanged: each HF falls to about 0.92 (1.15 / 1.25), the RiskModule refuses a new
    /// borrow, and LPVaultSwap liquidates one with WETH the caller funds and the other with WETH the public flash
    /// liquidation helper borrows, each sized by the keeper preview, swapping the unwound USDC and USDT into WETH over
    /// the routes and paying out in WETH; no WETH deficit is left, so summed losses stay within the WETH Coverage
    /// Spoke's funded reserve.
    function test_TEST_202_wethPriceRallyBlocksBorrowAndLiquidates() public {
        _addWethDebtReserve();
        address[2] memory wallets = [carol, alice];
        address[2] memory proxies;
        // 10,000 units at $2.10 with CF 80 % carry $16,800; HF 1.15 is $14,608.70 of WETH at $3,000.
        for (uint256 i = 0; i < 2; ++i) {
            (, proxies[i]) = _pledgeVia(wallets[i], MARKET_ID, 10_000e6);
            _borrowVia(wallets[i], MARKET_ID, wethReserveId, 4.8696e18);
            assertApproxEqRel(_hf(proxies[i]), 1.15e18, 0.002e18, "opened at HF 1.15");
        }
        weth.mint(address(this), 10e18);
        weth.approve(address(wethCoverage), 10e18);
        wethCoverage.fund(10e18);

        wethOracle.setAnswer(3750e8);
        _moveTokenPrice(address(weth), 3750e8);
        for (uint256 i = 0; i < 2; ++i) {
            assertApproxEqRel(_hf(proxies[i]), 0.92e18, 0.002e18, "HF 1.15 / 1.25");
        }
        uint256 nonce = adapterC.borrowNonce(proxies[0]);
        uint256 d = _deadline();
        vm.expectRevert();
        vm.prank(carol);
        adapterC.borrow(MARKET_ID, usdcReserveId, 1e6, carol, d, 0, nonce);

        uint256 swaps = routePools[address(usdt)][address(weth)][0].swaps();
        LiquidationPreview memory pv = lens.previewLiquidation(proxies[0], wethReserveId, block.timestamp + 60);
        assertTrue(pv.aaveLiquidatable, "liquidatable");
        pv.params.maxShortfall = pv.params.debtToCover / 20;
        LiquidationResult memory r = _liquidateAs(keeper, pv.params);
        assertEq(r.debtAsset, address(weth), "settled in WETH");
        assertEq(r.debtRepaid, pv.expectedDebtRepaid, "sized by the preview");
        assertGt(routePools[address(usdt)][address(weth)][0].swaps(), swaps, "USDT swapped into WETH");
        assertGt(r.keeperOut, 0, "keeperOut paid in WETH");
        assertEq(weth.balanceOf(lpVaultSwap), 0, "everything paid out in WETH");
        assertGt(_hf(proxies[0]), 0.92e18, "health rose");

        LiquidationPreview memory pv2 = lens.previewLiquidation(proxies[1], wethReserveId, block.timestamp + 60);
        FlashLiquidationRequest memory q;
        q.params = pv2.params;
        q.flashAmount = pv2.params.debtToCover;
        q.maxPremium = type(uint128).max;
        q.maxTopUp = pv2.params.debtToCover / 20;
        q.params.maxShortfall = q.maxTopUp;
        weth.mint(stranger2, q.maxTopUp);
        vm.startPrank(stranger2);
        weth.approve(address(helper), q.maxTopUp);
        helper.flashLiquidate(q);
        vm.stopPrank();
        assertGt(_hf(proxies[1]), 0.92e18, "the helper's liquidation raised health");
        assertEq(weth.balanceOf(address(helper)), 0, "the helper keeps no WETH");
        assertEq(weth.balanceOf(lpVaultSwap), 0, "LPVaultSwap keeps no WETH");

        uint256 deficit = IWethDeficitView(aave.hub).getSpokeDeficitRay(wethAssetId, aave.cdpSpoke) / 1e27;
        assertLe(deficit, wethCoverage.fundedBalance(), "losses within the WETH Coverage Spoke");
    }

    address internal stranger2 = makeAddr("flash caller");
}

interface IWethDeficitView {
    function getSpokeDeficitRay(
        uint256 assetId,
        address spoke
    ) external view returns (uint256);
}

