// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {AvanaFirstLossReserve} from "../../src/coverage/first-loss-reserve/AvanaFirstLossReserve.sol";
import {IAaveV4Hub} from "../../src/interfaces/external/aave/IAaveV4Hub.sol";
import {INonfungiblePositionManager} from "../../src/interfaces/external/uniswap/INonfungiblePositionManager.sol";
import {LiquidationPreview} from "../../src/lens/lens/types/LiquidationPreview.sol";
import {TailCoverageView} from "../../src/lens/lens/types/TailCoverageView.sol";
import {LiquidationResult} from "../../src/liquidation/lp-vault-swap/types/LiquidationResult.sol";
import {IFlashLiquidator} from "../../src/periphery/flash-liquidator/IFlashLiquidator.sol";
import {FlashLiquidationRequest} from "../../src/periphery/flash-liquidator/types/FlashLiquidationRequest.sol";
import {IParameterStoreTighten} from "../../src/policy/parameter-store/IParameterStoreTighten.sol";
import {IRiskModuleErrors} from "../../src/policy/risk-module/IRiskModuleErrors.sol";
import {PauseReason} from "../../src/types/PauseReason.sol";
import {PauseState} from "../../src/types/PauseState.sol";
import {ClTestToken, IClPool} from "../utils/fixtures/ClPoolFixture.sol";
import {RealStackFlows} from "../utils/fixtures/RealStackFlows.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
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
/// @notice Aave-side reserve states, a debt-price rise and the Lens's tail coverage on the real stack
/// (`RealStackFlows`: the real AaveAdapter, RiskModule, Collateralization, Uniswap v3 LPVault, LPVaultSwap,
/// FlashLiquidator, Lens, DebtOracles and `DexPathRoute`s on the local Aave V4 Hub and Spoke): an Aave freeze or pause
/// of one reserve, set by the Aave DAO through the real Spoke configurator, stops only what Aave or the RiskModule's own
/// read of it stops, and no Avana timer applies.
/// @dev Accounts: 10,000 vault tokens ($20,000 at $2.00, CF 30 %); bob's against 5,880 USDC is liquidatable once USDT
/// falls to $0.93 (`_depegUsdt`, HF 0.984), and a fixed 800 USDC repayment stays within Aave's close amount. A gap in
/// feed rounds longer than their maximum age opens each LPOracle's grace window on the next poke, so after the three-day
/// waits the test lets the window pass (`_waitOutGrace`) before a liquidation. TEST-202's WETH is a real
/// DebtOracle-priced debt reserve (`_addWethDebtReserve`) with routes from USDC and USDT into WETH at the feed rate.
/// TEST-247's chain has one CDP Spoke drawing GHO (the stand-in fixture had a second, Slipstream one), so the draw-cap
/// sum is that Spoke's cap.
/// forge-config: default.isolate = false
contract AaveAdapterAaveStatesIntegrationTest is RealStackFlows {
    bytes4 internal constant AAVE_RESERVE_PAUSED = bytes4(keccak256("ReservePaused()"));
    uint256 internal constant X = 800e6;

    uint256 internal mA;
    address internal vt;
    address internal stranger2 = makeAddr("flash caller");

    function setUp() public {
        _setUpFullStack();
        mA = _addMarket(poolA);
        vt = mkt[mA].vaultToken;
    }

    function _cfg() internal view returns (IStatesSpokeConfigurator) {
        return IStatesSpokeConfigurator(aave.spokeConfigurator);
    }

    function _account(
        address wallet,
        uint128 units,
        uint256 usdcDebt
    ) internal returns (address proxy, bytes32 key) {
        (key, proxy) = _pledgeAs(wallet, mA, units);
        if (usdcDebt != 0) _borrowAs(wallet, mA, usdcReserveId, usdcDebt);
    }

    function _credited(
        bytes32 key
    ) internal view returns (uint256) {
        return coll.getRecord(coll.recordIdOf(V3, key)).credited;
    }

    function _ownerOf(
        bytes32 key
    ) internal view returns (address) {
        return IERC721(address(nfpm)).ownerOf(uint256(key));
    }

    /// @dev Feeds republished, every LPOracle and the USDC DebtOracle poked, as a keeper does.
    function _refreshPrices() internal {
        _refreshFeeds();
        _pokeAll();
        usdcOracle.poke();
    }

    /// @dev The LPOracles' grace window (`graceDuration`, 1,800 s) passes with fresh rounds.
    function _waitOutGrace() internal {
        vm.warp(block.timestamp + 1801);
        vm.roll(block.number + 1801 / BLOCK_TIME);
        _refreshPrices();
    }

    function _expectBorrow(
        address wallet,
        uint256 reserveId,
        uint256 amount,
        bytes memory err
    ) internal {
        address proxy = adapterC.proxyOf(wallet, mA);
        uint256 nonce = adapterC.borrowNonce(proxy);
        uint256 d = _deadline();
        vm.expectRevert(err);
        vm.prank(wallet);
        adapterC.borrow(mA, reserveId, amount, wallet, d, 0, nonce);
    }

    /// @dev Token0 sold into the market's pool, then the pool swapped back to its price in one block: real fees.
    function _tradeThroughPool() internal {
        IClPool p = mkt[mA].pool;
        (uint160 start,,,,,,) = p.slot0();
        actor.swap(p, true, int256(1e14), 4_295_128_740);
        _swapTo(p, start);
    }

    /// @dev What the position manager owes the NFT, from a reverted `collect` by its owner, the LPVault.
    function _owed(
        bytes32 key
    ) internal returns (uint256 owed0, uint256 owed1) {
        uint256 snap = vm.snapshotState();
        vm.prank(integration);
        (owed0, owed1) = nfpm.collect(
            INonfungiblePositionManager.CollectParams(
                uint256(key), makeAddr("dryRun"), type(uint128).max, type(uint128).max
            )
        );
        vm.revertToState(snap);
    }

    /// @dev Real fees accrue to `key`, then the wallet collects exactly what the position manager owed.
    function _collectRealFees(
        address wallet,
        bytes32 key
    ) internal {
        _tradeThroughPool();
        (uint256 owed0, uint256 owed1) = _owed(key);
        IClPool p = mkt[mA].pool;
        (ClTestToken t0, ClTestToken t1) = (ClTestToken(p.token0()), ClTestToken(p.token1()));
        (uint256 b0, uint256 b1) = (t0.balanceOf(wallet), t1.balanceOf(wallet));
        vm.prank(wallet);
        adapterC.collectFees(mA, _ref(key), _deadline());
        assertGt(owed0 + owed1, 0, "fees accrued");
        assertEq(t0.balanceOf(wallet) - b0, owed0, "token0 fees collected");
        assertEq(t1.balanceOf(wallet) - b1, owed1, "token1 fees collected");
    }

    /// @dev A caller-funded liquidation of a WETH-debt account sized by the preview, USDT swapped into WETH.
    function _liquidateFunded(
        address proxy
    ) internal {
        address usdtWethPool = address(routePoolOf[address(usdt)][address(weth)][0]);
        uint256 poolUsdt = usdt.balanceOf(usdtWethPool);
        LiquidationPreview memory pv = lens.previewLiquidation(proxy, wethReserveId, block.timestamp + 60);
        assertTrue(pv.aaveLiquidatable, "liquidatable");
        pv.params.maxShortfall = pv.params.debtToCover / 20;
        LiquidationResult memory r = _liquidateAs(keeper, pv.params);
        assertEq(r.debtAsset, address(weth), "settled in WETH");
        assertEq(r.debtRepaid, pv.expectedDebtRepaid, "sized by the preview");
        assertGt(usdt.balanceOf(usdtWethPool), poolUsdt, "USDT swapped into WETH");
        assertGt(r.keeperOut, 0, "keeperOut paid in WETH");
        assertEq(weth.balanceOf(lpVaultSwap), 0, "everything paid out in WETH");
        assertGt(_hf(proxy), 0.92e18, "health rose");
    }

    /// @dev A liquidation through the real FlashLiquidator, which borrows the WETH from the Aave V3 Pool stand-in.
    function _liquidateByHelper(
        address proxy
    ) internal {
        LiquidationPreview memory pv2 = lens.previewLiquidation(proxy, wethReserveId, block.timestamp + 60);
        FlashLiquidationRequest memory q;
        q.params = pv2.params;
        q.flashAmount = pv2.params.debtToCover;
        q.maxPremium = type(uint128).max;
        q.maxTopUp = pv2.params.debtToCover / 20;
        q.params.maxShortfall = q.maxTopUp;
        weth.mint(stranger2, q.maxTopUp);
        vm.startPrank(stranger2);
        weth.approve(flashLiquidator, q.maxTopUp);
        IFlashLiquidator(flashLiquidator).flashLiquidate(q);
        vm.stopPrank();
        assertGt(_hf(proxy), 0.92e18, "the helper's liquidation raised health");
        assertEq(weth.balanceOf(flashLiquidator), 0, "the helper keeps no WETH");
        assertEq(weth.balanceOf(lpVaultSwap), 0, "LPVaultSwap keeps no WETH");
    }

    // TEST-169 verifies: REQ-ADAPTER-061, REQ-ADAPTER-062, REQ-RISK-061, Q-192, Q-202
    // Sources: 5.1 TEST-169 (Aave-side reserve pause on the real local Aave V4 Spoke)
    /// @notice The Aave Protocol Guardian pauses the vault-token reserve: borrow and a withdrawal that leaves debt
    /// revert in the RiskModule with `AaveReservePaused(reserveId)` and a liquidation in the market is blocked, still so
    /// three days later (no Avana timer or expiry). Then the USDC debt reserve is paused instead: a borrow reverts
    /// `DebtReservePaused(reserveId)` and a USDC repay is refused by Aave's own `ReservePaused()`, never by Avana. After
    /// the unpause every flow works again with no Avana action.
    function test_TEST_169_aaveReservePauseStopsOnlyWhatAaveStops() public {
        (address pA,) = _account(alice, UNITS, 2000e6);
        (bytes32 kA2,) = _pledgeAs(alice, mA, 2000e6);
        (address pB,) = _account(bob, UNITS, 5880e6);
        _depegUsdt(93_000_000);
        uint256 vtReserve = mkt[mA].reserveId;
        uint256 unitsA2 = _credited(kA2);

        vm.prank(aaveDao);
        _cfg().updatePaused(aave.cdpSpoke, vtReserve, true);
        for (uint256 i = 0; i < 2; ++i) {
            bytes memory err = abi.encodeWithSelector(IRiskModuleErrors.AaveReservePaused.selector, vtReserve);
            _expectBorrow(alice, ghoReserveId, 1e18, err);
            uint256 d = _deadline();
            vm.expectRevert(err);
            vm.prank(alice);
            adapterC.withdraw(mA, _ref(kA2), unitsA2, d, 0);
            _fundCaller(keeper, _liqParams(pB, mA, usdcReserveId, X));
            vm.expectRevert();
            vm.prank(keeper);
            lvs.liquidate(_liqParams(pB, mA, usdcReserveId, X));
            // Three days on, with fresh feed rounds: still refused for the same Aave reason, no Avana expiry.
            vm.warp(block.timestamp + 3 days);
            vm.roll(block.number + 3 days / BLOCK_TIME);
            _refreshPrices();
            _waitOutGrace();
        }

        vm.startPrank(aaveDao);
        _cfg().updatePaused(aave.cdpSpoke, vtReserve, false);
        _cfg().updatePaused(aave.cdpSpoke, usdcReserveId, true);
        vm.stopPrank();
        _refreshPrices();
        _expectBorrow(
            alice,
            ghoReserveId,
            1e18,
            abi.encodeWithSelector(IRiskModuleErrors.DebtReservePaused.selector, usdcReserveId)
        );
        usdc.mint(carol, 100e6);
        vm.startPrank(carol);
        usdc.approve(adapter, 100e6);
        vm.expectRevert(AAVE_RESERVE_PAUSED);
        adapterC.repay(alice, mA, usdcReserveId, 100e6, false, _deadline());
        vm.stopPrank();

        vm.prank(aaveDao);
        _cfg().updatePaused(aave.cdpSpoke, usdcReserveId, false);
        _repayVia(carol, alice, mA, usdcReserveId, 100e6, false);
        _borrowAs(alice, mA, ghoReserveId, 1e18);
        assertEq(_debtOf(pA, ghoReserveId), 1e18, "borrowing reopened by the DAO unpause alone");
        LiquidationResult memory r = _liquidateAs(keeper, _liqParams(pB, mA, usdcReserveId, X));
        assertEq(r.debtRepaid, X, "liquidation reopened");
    }

    // TEST-035 verifies: Q-051, Q-118, Q-203
    // Sources: 5.1 TEST-035 (the Adapter has no pause selector; an Aave freeze contains one market)
    /// @notice The Adapter holds no pause, freeze or per-market switch. Containing one market is the Aave freeze of its
    /// vault-token reserve: a borrow against it reverts `ReserveFrozen`, while a liquidation in that market, a
    /// third-party repay, fee collection (real Uniswap fees) and a debt-free withdrawal all succeed.
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
            (bool ok,) = adapter.call(abi.encodeWithSignature(absent[i], mA));
            assertFalse(ok, absent[i]);
        }
        (address pA, bytes32 kA) = _account(alice, UNITS, 2000e6);
        (bytes32 kC,) = _pledgeAs(carol, mA, 1000e6);
        (address pB,) = _account(bob, UNITS, 5880e6);
        _depegUsdt(93_000_000);
        uint256 vtReserve = mkt[mA].reserveId;
        vm.prank(aaveDao);
        _cfg().updateFrozen(aave.cdpSpoke, vtReserve, true);

        _expectBorrow(
            alice, usdcReserveId, 1e6, abi.encodeWithSelector(IRiskModuleErrors.ReserveFrozen.selector, vtReserve)
        );
        LiquidationResult memory r = _liquidateAs(keeper, _liqParams(pB, mA, usdcReserveId, X));
        assertEq(r.debtRepaid, X, "liquidation of the frozen market");
        uint256 owedBefore = _debtOf(pA, usdcReserveId);
        _repayVia(carol, alice, mA, usdcReserveId, 500e6, false);
        assertApproxEqAbs(_debtOf(pA, usdcReserveId), owedBefore - 500e6, 1, "third-party repay");
        _collectRealFees(alice, kA);
        _withdrawVia(carol, mA, kC, _credited(kC));
        assertEq(_ownerOf(kC), carol, "debt-free withdrawal");
    }

    // TEST-235 verifies: REQ-RISK-047
    // Sources: 2.7 REQ-RISK-047 (a failed pledge check reverts the whole pledge, custody included)
    /// @notice Under Paused(General), an account at HF 1.05 tops up: a charge within the restore amount (about $950)
    /// passes as a rescue; one above it reverts `NotRescueTopUp` inside Collateralization's `checkPledge` call, and the
    /// whole pledge unwinds: the NFT stays with the wallet, no record opens, nothing is credited and no vault token is
    /// minted or supplied.
    function test_TEST_235_refusedTopUpMovesNothing() public {
        (address pA,) = _account(alice, UNITS, 5714e6);
        _setPause(PauseState.Paused, PauseReason.General);
        _pledgeAs(alice, mA, 400e6);
        uint256 records = lens.getRecords(pA, 0, 16).length;
        uint256 credited = coll.getAccountCredited(pA, vt);
        uint256 supply = IERC20(vt).totalSupply();
        uint256 supplied = _sharesOf(pA, mkt[mA].reserveId);
        bytes32 k = _mintPosition(alice, mA, 2000e6);
        uint256 d = _deadline();
        vm.expectPartialRevert(IRiskModuleErrors.NotRescueTopUp.selector);
        vm.prank(alice);
        adapterC.pledge(mA, _ref(k), d);
        assertEq(_ownerOf(k), alice, "the NFT never left the wallet");
        assertEq(lens.getRecords(pA, 0, 16).length, records, "no record opened");
        assertEq(coll.getAccountCredited(pA, vt), credited, "nothing credited");
        assertEq(IERC20(vt).totalSupply(), supply, "no vault token minted");
        assertEq(_sharesOf(pA, mkt[mA].reserveId), supplied, "nothing supplied to Aave");
        assertFalse(lock.isLocked(), "Lock free");
    }

    // TEST-247 verifies: SPEC-CAP-008
    // Sources: 2.7 SPEC-CAP-008 (tail coverage ratio)
    /// @notice The Lens's tail coverage of GHO on the Stable LP Hub against the formula: per pool token other than GHO,
    /// `tail = min(⌈(tokenUsdCap + Σ topUpSliceUsd) × CF / 10^4⌉, drawCapUsd)`, and the ratio
    /// `⌊fundedUsd × 10^4 / max tail⌋`; the tail rounds up and the ratio down. The caps are tightened through the real
    /// timelock and ParameterStore; the two markets are the full ranges of `poolA` and `poolB` (CF 30 %).
    function test_TEST_247_tailCoverageMatchesTheSizingFormula() public {
        uint256 mB = _addMarket(poolB);
        _govern(
            address(store),
            abi.encodeCall(IParameterStoreTighten.tightenTokenUsdCap, (aave.hub, address(usdc), 300_000e8 + 1))
        );
        _govern(
            address(store),
            abi.encodeCall(IParameterStoreTighten.tightenTokenUsdCap, (aave.hub, address(usdt), 250_000e8))
        );
        _govern(address(store), abi.encodeCall(IParameterStoreTighten.tightenTopUpSliceUsd, (mA, 20_000e8)));
        _govern(address(store), abi.encodeCall(IParameterStoreTighten.tightenTopUpSliceUsd, (mB, 10_000e8)));
        AvanaFirstLossReserve ghoReserve = AvanaFirstLossReserve(firstLossReserveOf[address(gho)]);
        gho.mint(address(this), 70_000e18);
        gho.approve(address(ghoReserve), 70_000e18);
        ghoReserve.fund(70_000e18);

        TailCoverageView memory t = lens.getTailCoverage(aave.hub, address(gho));
        uint256 capSum = uint256(IAaveV4Hub(aave.hub).getSpokeConfig(ghoAssetId, aave.cdpSpoke).drawCap);
        assertEq(t.drawCapUsd, capSum * 1e8, "the draw cap at GHO's $1.00");
        assertEq(t.fundedUsd, ghoReserve.fundedBalance() * 1e8 / 1e18, "funded at $1.00");
        // USDC: ⌈(300,000.00000001 + 20,000 + 10,000) × 0.3⌉ = 99,000.00000001; USDT: (250,000 + 30,000) × 0.3.
        uint256 usdcTail = Math.mulDiv(330_000e8 + 1, VT_CF, 1e4, Math.Rounding.Ceil);
        assertEq(usdcTail, 99_000e8 + 1, "the tail rounds up");
        assertLt(usdcTail, t.drawCapUsd, "below the draw cap");
        assertEq(t.worstToken, address(usdc), "USDC has the largest tail");
        assertEq(t.tailUsd, usdcTail, "tail");
        assertEq(t.ratioBps, t.fundedUsd * 1e4 / usdcTail, "ratio rounds down");
        assertLt(t.ratioBps * usdcTail, t.fundedUsd * 1e4, "strictly down here: never overstates coverage");
    }

    // TEST-202 verifies: Q-238, Q-233, Q-234, Q-235
    // Sources: 5.1 TEST-202 (debt-asset price rally, WETH debt)
    /// @notice Two accounts with stable-LP collateral and WETH debt opened at HF about 1.15 see every WETH feed rise
    /// 25 % with every collateral price unchanged: each HF falls to about 0.92 (1.15 / 1.25), the RiskModule refuses a
    /// new borrow, and LPVaultSwap liquidates one with WETH the caller funds and the other with WETH the real
    /// FlashLiquidator borrows, each sized by the keeper preview, swapping the unwound USDC and USDT into WETH over the
    /// real routes and paying out in WETH; no WETH deficit is left, so summed losses stay within the WETH First-Loss
    /// Reserve's funded balance.
    function test_TEST_202_wethPriceRallyBlocksBorrowAndLiquidates() public {
        _addWethDebtReserve();
        address[2] memory wallets = [carol, alice];
        address[2] memory proxies;
        // 10,000 units at $2.00 with CF 30 % carry $6,000; HF 1.15 is $5,217.39 of WETH at $3,000.
        for (uint256 i = 0; i < 2; ++i) {
            (, proxies[i]) = _pledgeAs(wallets[i], mA, UNITS);
            _borrowAs(wallets[i], mA, wethReserveId, 1.7391e18);
            assertApproxEqRel(_hf(proxies[i]), 1.15e18, 0.002e18, "opened at HF 1.15");
        }

        _moveToken(address(weth), 3750e8);
        for (uint256 i = 0; i < 2; ++i) {
            assertApproxEqRel(_hf(proxies[i]), 0.92e18, 0.002e18, "HF 1.15 / 1.25");
        }
        uint256 nonce = adapterC.borrowNonce(proxies[0]);
        uint256 d = _deadline();
        vm.expectRevert();
        vm.prank(carol);
        adapterC.borrow(mA, usdcReserveId, 1e6, carol, d, 0, nonce);

        _liquidateFunded(proxies[0]);
        _liquidateByHelper(proxies[1]);

        uint256 deficit = IWethDeficitView(aave.hub).getSpokeDeficitRay(wethAssetId, aave.cdpSpoke) / 1e27;
        assertLe(
            deficit,
            AvanaFirstLossReserve(firstLossReserveOf[address(weth)]).fundedBalance(),
            "losses within the WETH First-Loss Reserve"
        );
    }
}

interface IWethDeficitView {
    function getSpokeDeficitRay(
        uint256 assetId,
        address spoke
    ) external view returns (uint256);
}
