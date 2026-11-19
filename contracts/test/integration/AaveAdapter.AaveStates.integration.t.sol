// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {RiskStatus} from "../../src/amm/types/AmmTypes.sol";
import {AvanaFirstLossReserve} from "../../src/coverage/first-loss-reserve/AvanaFirstLossReserve.sol";
import {ILPVault} from "../../src/custody/lp-vault/ILPVault.sol";
import {IAaveV4Hub} from "../../src/interfaces/external/aave/IAaveV4Hub.sol";
import {INonfungiblePositionManager} from "../../src/interfaces/external/uniswap/INonfungiblePositionManager.sol";
import {LiquidationResult} from "../../src/liquidation/lp-vault-swap/types/LPVaultSwapTypes.sol";
import {BreakerReasons} from "../../src/policy/market-registry/types/Breaker.sol";
import {IParameterStoreTighten} from "../../src/policy/parameter-store/IParameterStoreTighten.sol";
import {IRiskModuleErrors} from "../../src/policy/risk-module/IRiskModuleErrors.sol";
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
/// TEST-247's chain has one CDP Spoke drawing GHO (no Slipstream Spoke is built here), so the draw-cap sum is that
/// Spoke's cap.
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
    }

    /// @dev 1,801 s pass with fresh rounds.
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

    // TEST-169 verifies: REQ-ADAPTER-061, REQ-ADAPTER-062, REQ-RISK-061, Q-192, Q-202
    // Sources: 5.1 TEST-169 (Aave-side reserve pause on the real local Aave V4 Spoke)
    /// @notice The Aave Protocol Guardian pauses the vault-token reserve: a withdrawal and a liquidation in the market
    /// are refused by Aave's own `ReservePaused()`, still so three days later (no Avana timer or expiry). Then the USDC
    /// debt reserve is paused instead: a USDC borrow and a USDC repay are refused by Aave's own `ReservePaused()`, never
    /// by Avana. After the pause lifts every flow works again with no Avana action.
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
            uint256 d = _deadline();
            vm.expectRevert(AAVE_RESERVE_PAUSED);
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
        _expectBorrow(alice, usdcReserveId, 1e6, abi.encodePacked(AAVE_RESERVE_PAUSED));
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
        assertEq(_debtOf(pA, ghoReserveId), 1e18, "borrowing reopened by the DAO lifting the pause alone");
        LiquidationResult memory r = _liquidateAs(keeper, _liqParams(pB, mA, usdcReserveId, X));
        assertEq(r.debtRepaid, X, "liquidation reopened");
    }

    // TEST-035 verifies: Q-051, Q-118, Q-203
    // Sources: 5.1 TEST-035 (the Adapter has no pause selector; an Aave freeze contains one market)
    /// @notice The Adapter holds no pause, freeze or per-market switch. Containing one market is the Aave freeze of its
    /// vault-token reserve; a liquidation in that market, a third-party repay, fee collection (real Uniswap fees) and a
    /// debt-free withdrawal all succeed under it.
    function test_TEST_035_aaveFreezeContainsOneMarketAndLeavesItsExitsOpen() public {
        string[7] memory absent = [
            "pause()",
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

        LiquidationResult memory r = _liquidateAs(keeper, _liqParams(pB, mA, usdcReserveId, X));
        assertEq(r.debtRepaid, X, "liquidation of the frozen market");
        uint256 owedBefore = _debtOf(pA, usdcReserveId);
        _repayVia(carol, alice, mA, usdcReserveId, 500e6, false);
        assertApproxEqAbs(_debtOf(pA, usdcReserveId), owedBefore - 500e6, 1, "third-party repay");
        _collectRealFees(alice, kA);
        _withdrawVia(carol, mA, kC, _credited(kC));
        assertEq(_ownerOf(kC), carol, "debt-free withdrawal");
    }
}

interface IWethDeficitView {
    function getSpokeDeficitRay(
        uint256 assetId,
        address spoke
    ) external view returns (uint256);
}
