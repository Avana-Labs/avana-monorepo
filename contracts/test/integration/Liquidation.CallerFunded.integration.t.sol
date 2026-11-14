// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ClPriceMath} from "../../src/amm/concentrated-liquidity/ClPriceMath.sol";
import {LiquidationPreview} from "../../src/lens/lens/types/LiquidationPreview.sol";
import {ILPVaultSwapErrors} from "../../src/liquidation/lp-vault-swap/ILPVaultSwapErrors.sol";
import {ILPVaultSwapEvents} from "../../src/liquidation/lp-vault-swap/ILPVaultSwapEvents.sol";
import {LiquidationParams} from "../../src/liquidation/lp-vault-swap/types/LiquidationParams.sol";
import {LiquidationResult} from "../../src/liquidation/lp-vault-swap/types/LiquidationResult.sol";
import {RouteMode} from "../../src/liquidation/lp-vault-swap/types/RouteMode.sol";
import {ISettlementRoute} from "../../src/liquidation/settlement-routes/ISettlementRoute.sol";
import {IAaveAdapterEvents} from "../../src/policy/aave-adapter/IAaveAdapterEvents.sol";
import {PauseReason} from "../../src/types/PauseReason.sol";
import {PauseState} from "../../src/types/PauseState.sol";
import {ClTestToken, IClPool} from "../utils/fixtures/ClPoolFixture.sol";
import {RealStackFlows} from "../utils/fixtures/RealStackFlows.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title LiquidationCallerFundedIntegrationTest
/// @notice Caller-funded liquidation of an account the borrower opened through the real AaveAdapter, settled by the
/// real LPVaultSwap on the real stack (`RealStackFlows`): the Adapter's `burnSeized`, Collateralization's seizure, the
/// real Uniswap v3 LPVault's unwind through the NonfungiblePositionManager, the real `DexPathRoute`s into the debt
/// asset and the waterfall, for each debt reserve, in both route modes and in every pause state.
/// @dev Bob's account: 10,000 vault tokens ($20,000 at $2.00, CF 30 %) against 5,880 of debt, HF 1.020; USDT then
/// falls to $0.93 (`_depegUsdt`), the vault token to $1.9287 and HF to 0.984. Aave closes at most the debt that
/// restores its 1.10 target (about 862, the Lens's `params.debtToCover`); a repayment of `D` within it is pulled whole
/// and seizes `D × (1 + bonus) / 1.9287` vault tokens (the Lens's `expectedUnitsSeized`) worth `V = c × 1.9287`. The
/// other cases repay a fixed 800. The settlement identities of `TEST-047` hold on the real routes' recovery.
/// forge-config: default.isolate = false
contract LiquidationCallerFundedIntegrationTest is RealStackFlows {
    uint256 internal constant X = 800e6;
    uint256 internal mA;
    address internal vt;

    function setUp() public {
        _setUpFullStack();
        mA = _addMarket(poolA);
        vt = mkt[mA].vaultToken;
    }

    /// @dev Bob's account in `reserveId` (USDC or GHO), then the USDT depeg.
    function _account(
        address wallet,
        uint256 reserveId
    ) internal returns (address proxy, bytes32 key) {
        (key, proxy) = _pledgeAs(wallet, mA, UNITS);
        _borrowAs(wallet, mA, reserveId, reserveId == usdcReserveId ? 5880e6 : 5880e18);
    }

    function _bobAccount() internal returns (address proxy, bytes32 key) {
        (proxy, key) = _account(bob, usdcReserveId);
        _depegUsdt(93_000_000);
    }

    /// @dev The oracle value of `c` vault-token units in the debt asset's base units (USDC: 6 decimals, GHO: 18).
    function _value(
        uint256 c,
        uint256 reserveId
    ) internal view returns (uint256) {
        uint256 price8 = uint256(mkt[mA].oracle.latestAnswer());
        uint256 scale = reserveId == usdcReserveId ? 1 : 1e12;
        return c * price8 * scale / 1e8;
    }

    /// @dev Every settlement identity of `TEST-047` and `TEST-104` on one result.
    function _checkSettlement(
        LiquidationResult memory r,
        uint256 x,
        uint256 v,
        ClTestToken asset
    ) internal view {
        assertEq(r.debtAsset, address(asset), "settled in the repaid debt asset");
        assertEq(r.callerFunds, x, "Kf = the pulled funding");
        assertLe(r.debtRepaid, r.callerFunds, "D <= Kf");
        assertEq(
            r.callerFunds + r.recovered + r.shortfall,
            r.debtRepaid + r.avanaFee + r.borrowerSurplus + r.keeperOut,
            "Kf + R + shortfall = D + A + B + keeperOut"
        );
        assertGe(r.recovered + r.shortfall, r.minOut, "R + shortfall >= minRec");
        uint256 rf = r.recovered + r.shortfall;
        uint256 s = rf > r.debtRepaid ? rf - r.debtRepaid : 0;
        uint256 g = v > r.debtRepaid ? v - r.debtRepaid : 0;
        uint256 a = g * 2000 / 10_000;
        assertEq(r.avanaFee, a < s ? a : s, "A = min(floor(G x 20 %), S)");
        assertEq(r.avanaFee + r.keeperReward + r.borrowerSurplus, s, "A + kr + B = S");
        assertEq(asset.balanceOf(lpVaultSwap), 0, "LPVaultSwap keeps no debt asset");
        assertEq(usdt.balanceOf(lpVaultSwap) + usdc.balanceOf(lpVaultSwap), 0, "LPVaultSwap keeps no pool token");
        assertEq(IERC20(vt).balanceOf(lpVaultSwap), 0, "LPVaultSwap keeps no vault token");
        assertFalse(lock.isLocked(), "Lock released");
        assertEq(v3Pool.flashLoanCalls(), 0, "no flash source or lender called");
    }

    /// @dev The USDT → USDC route pool of `slot` (0 primary, 1 backup) swapped so USDT sells `bps` below its feed.
    function _skewRoute(
        uint256 slot,
        uint256 bps
    ) internal {
        IClPool p = routePoolOf[address(usdt)][address(usdc)][slot];
        uint256 pUsdt = _usdPrice(address(usdt)) * (10_000 - bps) / 10_000;
        (uint256 p0, uint256 p1) =
            p.token0() == address(usdt) ? (pUsdt, _usdPrice(address(usdc))) : (_usdPrice(address(usdc)), pUsdt);
        _swapTo(p, ClPriceMath.oracleSqrtPrice(p0, p1, 6, 6));
    }

    // TEST-047 verifies: REQ-SWAP-011, REQ-SWAP-015, REQ-SWAP-016, REQ-SWAP-020, REQ-SWAP-045, REQ-ADAPTER-070, REQ-SWAP-028, SPEC-LIQ-006, SPEC-LIQ-009, SPEC-LIQ-010, SPEC-LIQ-022, Q-060, Q-061, Q-404
    // TEST-104 verifies: SPEC-LIQ-010, REQ-SWAP-073, INV-035, INV-038
    function test_TEST_047_callerFundedSequenceThroughRealAdapter() public {
        (address proxy,) = _bobAccount();
        uint256 supplyBefore = IERC20(vt).totalSupply();
        uint256 creditedBefore = coll.getTotalCredited(vt);
        uint256 debtBefore = _debtOf(proxy, usdcReserveId);
        uint256 sharesBefore = _sharesOf(proxy, mkt[mA].reserveId);
        // The Lens sizes the repayment (Aave's close amount, about 862) and its seizure; the call repays all of it.
        LiquidationPreview memory pv = lens.previewLiquidation(proxy, usdcReserveId, block.timestamp + 120);
        (uint256 x, uint256 c) = (pv.params.debtToCover, pv.expectedUnitsSeized);
        assertGt(x, X, "a close amount above 800");
        LiquidationParams memory p = _liqParams(proxy, mA, usdcReserveId, x);
        _fundCaller(keeper, p);
        vm.expectEmit(true, true, false, true, adapter);
        emit IAaveAdapterEvents.SeizedUnitsBurned(mA, vt, c);
        vm.prank(keeper);
        LiquidationResult memory r = lvs.liquidate(p);
        assertEq(r.debtRepaid, x, "D: Aave pulled the whole repayment");
        assertEq(r.debtRepaid, pv.expectedDebtRepaid, "D as the Lens previewed");
        assertEq(r.unitsSeized, c, "c = D x (1 + bonus) / the oracle price, as the Lens sized it");
        _checkSettlement(r, x, _value(c, usdcReserveId), usdc);
        assertGt(r.amountsOut[0], 0, "the real unwind returned token0");
        assertGt(r.amountsOut[1], 0, "and token1");
        assertEq(supplyBefore - IERC20(vt).totalSupply(), c, "the Adapter burned exactly the seized units");
        assertEq(creditedBefore - coll.getTotalCredited(vt), c, "Collateralization debited them");
        assertEq(sharesBefore - _sharesOf(proxy, mkt[mA].reserveId), c, "the proxy's shares fell by c");
        assertEq(IERC20(vt).totalSupply(), coll.getTotalCredited(vt) + coll.getPending(vt).units, "supply = credited");
        assertApproxEqAbs(debtBefore - _debtOf(proxy, usdcReserveId), x, 1, "debt fell by D (Aave rounds shares)");
        assertEq(usdc.balanceOf(keeper), r.keeperOut, "keeperOut paid to the caller");
        assertEq(usdc.balanceOf(feeRecipient), r.avanaFee, "fee paid to the fee recipient");
        assertEq(usdc.balanceOf(bob), 5880e6 + r.borrowerSurplus, "surplus (if any) to the wallet");
        assertGt(_hf(proxy), 0.984e18, "the account's health rose");
    }

    // TEST-047 verifies: REQ-SWAP-020, REQ-SWAP-045, REQ-ADAPTER-070, SPEC-LIQ-004, SPEC-LIQ-006, Q-233
    function test_TEST_047_ghoDebtReserveThroughRealAdapter() public {
        (address proxy,) = _account(bob, ghoReserveId);
        _depegUsdt(93_000_000);
        uint256 supplyBefore = IERC20(vt).totalSupply();
        LiquidationPreview memory pv = lens.previewLiquidation(proxy, ghoReserveId, block.timestamp + 120);
        (uint256 x, uint256 c) = (pv.params.debtToCover, pv.expectedUnitsSeized);
        LiquidationParams memory p = _liqParams(proxy, mA, ghoReserveId, x);
        _fundCaller(keeper, p);
        vm.expectEmit(true, true, false, true, adapter);
        emit IAaveAdapterEvents.SeizedUnitsBurned(mA, vt, c);
        vm.prank(keeper);
        LiquidationResult memory r = lvs.liquidate(p);
        assertEq(r.debtRepaid, x, "D in GHO, all of the Lens's close amount");
        assertEq(r.unitsSeized, c, "seizure at GHO $1.00 as previewed");
        _checkSettlement(r, x, _value(c, ghoReserveId), gho);
        assertEq(supplyBefore - IERC20(vt).totalSupply(), c, "burned");
        assertEq(usdc.balanceOf(lpVaultSwap), 0, "both legs swapped into GHO");
        assertEq(gho.balanceOf(keeper), r.keeperOut, "keeperOut in GHO");
    }

    // TEST-047 verifies: REQ-SWAP-003, REQ-ADAPTER-070, REQ-ADAPTER-086, INV-045, INV-046, Q-404
    function test_TEST_047_succeedsInEveryPauseStateThroughRealAdapter() public {
        address[3] memory wallets = [bob, alice, carol];
        address[3] memory proxies;
        for (uint256 i = 0; i < 3; ++i) {
            (proxies[i],) = _account(wallets[i], usdcReserveId);
        }
        _depegUsdt(93_000_000);
        PauseState[3] memory states = [PauseState.Frozen, PauseState.Paused, PauseState.Paused];
        PauseReason[3] memory reasons = [PauseReason.None, PauseReason.General, PauseReason.MintPathSuspect];
        for (uint256 i = 0; i < 3; ++i) {
            _setPause(states[i], reasons[i]);
            _freezeWallet(wallets[i]);
            LiquidationResult memory r = _liquidateAs(keeper, _liqParams(proxies[i], mA, usdcReserveId, X));
            assertGt(r.unitsSeized, 0, "settles under the pause and the borrower's freeze");
            _checkSettlement(r, X, _value(r.unitsSeized, usdcReserveId), usdc);
            _setPause(PauseState.None, PauseReason.None);
        }
    }

    /// @notice A primary route that cannot meet its per-leg minimum fails over to the backup in `PrimaryThenBackup`;
    /// `BackupOnly` never calls the primary. The primary's pool is moved 10 % below the USDT feed by a real swap.
    // TEST-174 verifies: REQ-SWAP-022, REQ-SWAP-025, REQ-SWAP-001, SPEC-LIQ-018
    function test_TEST_174_routeModesThroughRealAdapter() public {
        (address bobProxy,) = _account(bob, usdcReserveId);
        (address aliceProxy,) = _account(alice, usdcReserveId);
        _depegUsdt(93_000_000);
        (address primary,) = registry.getRoute(mA, address(usdt), address(usdc), 0);
        IClPool primaryPool = routePoolOf[address(usdt)][address(usdc)][0];
        IClPool backupPool = routePoolOf[address(usdt)][address(usdc)][1];
        _skewRoute(0, 1000);
        uint256 backupUsdt = usdt.balanceOf(address(backupPool));
        LiquidationParams memory p = _liqParams(bobProxy, mA, usdcReserveId, X);
        address anyEoa = makeAddr("anyEoa");
        _fundCaller(anyEoa, p);
        vm.expectEmit(true, true, false, false, lpVaultSwap);
        emit ILPVaultSwapEvents.RouteFailed(mA, address(usdt), primary, ISettlementRoute.MinOutNotMet.selector);
        vm.prank(anyEoa);
        LiquidationResult memory r = lvs.liquidate(p);
        _checkSettlement(r, X, _value(r.unitsSeized, usdcReserveId), usdc);
        assertGt(usdt.balanceOf(address(backupPool)), backupUsdt, "the backup ran");

        _skewRoute(0, 5);
        uint256 primaryUsdt = usdt.balanceOf(address(primaryPool));
        backupUsdt = usdt.balanceOf(address(backupPool));
        p = _liqParams(aliceProxy, mA, usdcReserveId, X);
        p.routeMode = RouteMode.BackupOnly;
        r = _liquidateAs(makeAddr("otherEoa"), p);
        _checkSettlement(r, X, _value(r.unitsSeized, usdcReserveId), usdc);
        assertEq(usdt.balanceOf(address(primaryPool)), primaryUsdt, "BackupOnly never calls the primary");
        assertGt(usdt.balanceOf(address(backupPool)), backupUsdt, "the backup ran again");
    }

    /// @notice Both routes failing refuse the liquidation by name and leave the account, the Adapter's mint record
    /// and Collateralization untouched.
    // TEST-174 verifies: REQ-SWAP-025, REQ-SWAP-042
    function test_TEST_174_bothRoutesFailRevertsWithoutState() public {
        (address proxy,) = _bobAccount();
        _skewRoute(0, 1000);
        _skewRoute(1, 1000);
        uint256 supplyBefore = IERC20(vt).totalSupply();
        uint256 debtBefore = _debtOf(proxy, usdcReserveId);
        LiquidationParams memory p = _liqParams(proxy, mA, usdcReserveId, X);
        usdc.mint(keeper, X);
        vm.startPrank(keeper);
        usdc.approve(lpVaultSwap, X);
        vm.expectRevert(ILPVaultSwapErrors.NoRouteAvailable.selector);
        lvs.liquidate(p);
        vm.stopPrank();
        assertEq(IERC20(vt).totalSupply(), supplyBefore, "nothing burned");
        assertEq(_debtOf(proxy, usdcReserveId), debtBefore, "nothing repaid");
        assertEq(usdc.balanceOf(keeper), X, "the caller keeps its funding");
        assertFalse(lock.isLocked(), "Lock free");
    }

    /// @notice A liquidation while Paused, then the borrower's own exits through the real Adapter: repay of the
    /// remainder, withdrawal of the remaining units and the NFT back to the wallet.
    // TEST-193 verifies: REQ-ADAPTER-047, REQ-ADAPTER-071, REQ-PROXY-032, REQ-PROXY-035, INV-045, INV-067
    function test_TEST_193_exitsAfterLiquidationWhilePaused() public {
        (address proxy, bytes32 key) = _bobAccount();
        _setPause(PauseState.Paused, PauseReason.General);
        _liquidateAs(keeper, _liqParams(proxy, mA, usdcReserveId, X));
        uint256 owed = _debtOf(proxy, usdcReserveId);
        _repayVia(bob, bob, mA, usdcReserveId, owed, true);
        assertEq(_debtOf(proxy, usdcReserveId), 0, "repaid while Paused");
        uint256 left = coll.getRecord(coll.recordIdOf(V3, key)).credited;
        _withdrawVia(bob, mA, key, left);
        assertEq(IERC20(address(nfpm)).balanceOf(bob), 1, "the NFT returned to its depositor");
        assertEq(_sharesOf(proxy, mkt[mA].reserveId), 0, "nothing left supplied");
        assertEq(IERC20(vt).totalSupply(), coll.getTotalCredited(vt), "supply = credited");
    }
}
