// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {LiquidationPreview} from "../../src/lens/lens/types/LiquidationPreview.sol";
import {ILPVaultSwapErrors} from "../../src/liquidation/lp-vault-swap/ILPVaultSwapErrors.sol";
import {LiquidationParams} from "../../src/liquidation/lp-vault-swap/types/LiquidationParams.sol";
import {LiquidationResult} from "../../src/liquidation/lp-vault-swap/types/LiquidationResult.sol";
import {IAaveAdapterEvents} from "../../src/policy/aave-adapter/IAaveAdapterEvents.sol";
import {PauseReason} from "../../src/types/PauseReason.sol";
import {PauseState} from "../../src/types/PauseState.sol";
import {ClTestToken} from "../utils/fixtures/ClPoolFixture.sol";
import {RealStackUniswapV4Journeys} from "../utils/fixtures/RealStackUniswapV4Journeys.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Vm} from "forge-std/Vm.sol";

/// @title LiquidationUniswapV4IntegrationTest
/// @notice Caller-funded liquidation of accounts on a Uniswap v4 market, opened through the real AaveAdapter and
/// settled by the real LPVaultSwap on the real stack: the Lens's `previewLiquidation` parameters executed unchanged for
/// a USDC and a GHO debt (`TEST-205`) with every settlement identity of `TEST-047`, the Adapter's seized-unit burn and
/// its event (`TEST-208`), a caller's raised `minPayout`, settlement under every pause state and the borrower's own
/// freeze (`TEST-047`), and the borrower's exits after a liquidation while Paused (`TEST-193`). The seized units are
/// removed through the real Uniswap v4 LPVault: the principal to LPVaultSwap and the fees to the depositor.
/// @dev Each account: a $20,000 USDC/USDT v4 position against 5,880 of debt (HF 1.020); USDT then falls to $0.93.
/// forge-config: default.isolate = false
contract LiquidationUniswapV4IntegrationTest is RealStackUniswapV4Journeys {
    function setUp() public {
        _setUpV4Journeys();
    }

    function _params(
        address proxy,
        uint256 reserveId,
        uint256 debtToCover
    ) internal view returns (LiquidationParams memory p) {
        p = _liqParams(proxy, mS, reserveId, debtToCover);
    }

    // TEST-205 verifies: REQ-LENS-016, REQ-LENS-017, REQ-LENS-028, REQ-LENS-029, SPEC-LIQ-004, SPEC-LIQ-005
    // TEST-047 verifies: REQ-SWAP-011, REQ-SWAP-020, REQ-ADAPTER-070, SPEC-LIQ-006, SPEC-LIQ-010, REQ-AMM-V4-004; shared: the executed preview is checked against every settlement identity
    // TEST-208 verifies: REQ-ADAPTER-070, REQ-SWAP-092; shared: each executed preview checks the seized-unit burn and its event
    function test_TEST_205_v4ParamsExecuteUnchangedForGhoAndUsdc() public {
        (address ghoProxy, bytes32 ghoKey) = _stableAccount(alice, v4GhoReserveS, DEBT_GHO);
        (address usdcProxy,) = _stableAccount(bob, v4UsdcReserveS, DEBT_USDC);
        _depegUsdt4(93_000_000);
        uint256[2] memory reserves = [v4GhoReserveS, v4UsdcReserveS];
        address[2] memory proxies = [ghoProxy, usdcProxy];
        ClTestToken[2] memory assets = [gho, usdc];
        _washV4Market(mS, 1e12);
        (uint256 f0, uint256 f1) = _feesOwed4(mS, ghoKey);
        _executeAsPreviewed(proxies[0], reserves[0], assets[0], f0, f1);
        _executeAsPreviewed(proxies[1], reserves[1], assets[1], 0, 0);
    }

    /// @dev The preview's parameters executed unchanged; the depositor alice receives `f0`, `f1` of fees when it is
    /// her account (both zero otherwise).
    function _executeAsPreviewed(
        address proxy,
        uint256 reserveId,
        ClTestToken asset,
        uint256 f0,
        uint256 f1
    ) internal {
        LiquidationPreview memory p = lens.previewLiquidation(proxy, reserveId, block.timestamp + 120);
        assertTrue(p.aaveLiquidatable && p.pricesUsable, "liquidatable with usable gates");
        assertEq(p.params.marketId, mS, "the v4 market");
        uint256[3] memory b = [
            IERC20(vtS).totalSupply(),
            _sharesOn(v4SpokeS, proxy, mkt[mS].reserveId),
            _debtOn(v4SpokeS, proxy, reserveId)
        ];
        (uint256 a0, uint256 a1) = _pair4(mS, alice);
        vm.recordLogs();
        LiquidationResult memory r = _liquidateOn(v4SpokeS, keeper, p.params);
        assertEq(_burnEvents(r.unitsSeized), 1, "one SeizedUnitsBurned of c");
        assertEq(r.debtRepaid, p.expectedDebtRepaid, "D as previewed");
        assertEq(r.unitsSeized, p.expectedUnitsSeized, "c as previewed");
        assertEq(r.minOut, p.recoveryFloor, "recovery floor as previewed");
        assertEq(r.avanaFee, p.expectedAvanaFee, "Avana fee as previewed");
        _checkSettlement4(r, p.params.debtToCover, asset, vtS);
        assertGt(r.amountsOut[0] + r.amountsOut[1], 0, "the real v4 unwind paid the principal");
        assertEq(b[0] - IERC20(vtS).totalSupply(), r.unitsSeized, "supply drop = c");
        assertEq(b[1] - _sharesOn(v4SpokeS, proxy, mkt[mS].reserveId), r.unitsSeized, "share drop = c");
        assertApproxEqAbs(b[2] - _debtOn(v4SpokeS, proxy, reserveId), r.debtRepaid, 1, "debt fell by D");
        if (f0 + f1 != 0) {
            (uint256 c0, uint256 c1) = _pair4(mS, alice);
            assertEq(c0 - a0, f0, "the seizure paid the depositor's token0 fees to the depositor");
            assertEq(c1 - a1, f1, "and its token1 fees");
        }
        _assertBacked(vtS);
    }

    function _burnEvents(
        uint256 c
    ) internal view returns (uint256 burns) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 k = 0; k < logs.length; ++k) {
            if (logs[k].emitter != adapter || logs[k].topics[0] != IAaveAdapterEvents.SeizedUnitsBurned.selector) {
                continue;
            }
            ++burns;
            assertEq(uint256(logs[k].topics[1]), mS, "event market");
            assertEq(address(uint160(uint256(logs[k].topics[2]))), vtS, "event vault token");
            assertEq(abi.decode(logs[k].data, (uint256)), c, "event units = c");
        }
    }

    // TEST-205 verifies: REQ-LENS-029, REQ-SWAP-026
    function test_TEST_205_v4RaisedMinPayoutIsEnforced() public {
        (address proxy,) = _stableAccount(bob, v4UsdcReserveS, DEBT_USDC);
        _depegUsdt4(93_000_000);
        LiquidationPreview memory p = lens.previewLiquidation(proxy, v4UsdcReserveS, block.timestamp + 120);
        LiquidationParams memory raised = p.params;
        raised.minPayout = p.expectedPayout;
        uint256 debtBefore = _debtOn(v4SpokeS, proxy, v4UsdcReserveS);
        usdc.mint(keeper, raised.debtToCover);
        vm.startPrank(keeper);
        usdc.approve(lpVaultSwap, raised.debtToCover);
        vm.expectPartialRevert(ILPVaultSwapErrors.PayoutTooLow.selector);
        lvs.liquidate(raised);
        vm.stopPrank();
        assertEq(_debtOn(v4SpokeS, proxy, v4UsdcReserveS), debtBefore, "nothing repaid");
        raised.minPayout = p.expectedPayout - p.expectedAvanaFee;
        LiquidationResult memory r = _liquidateOn(v4SpokeS, keeper, raised);
        assertEq(r.unitsSeized, p.expectedUnitsSeized, "c as previewed");
        assertGe(r.keeperOut, raised.minPayout, "the raised minimum held");
    }

    // TEST-047 verifies: REQ-SWAP-003, REQ-ADAPTER-070, REQ-ADAPTER-086, INV-045, INV-046
    function test_TEST_047_v4SucceedsInEveryPauseState() public {
        address[3] memory wallets = [bob, alice, carol];
        address[3] memory proxies;
        for (uint256 i = 0; i < 3; ++i) {
            (proxies[i],) = _stableAccount(wallets[i], v4UsdcReserveS, DEBT_USDC);
        }
        _depegUsdt4(93_000_000);
        PauseState[3] memory states = [PauseState.Frozen, PauseState.Paused, PauseState.Paused];
        PauseReason[3] memory reasons = [PauseReason.None, PauseReason.General, PauseReason.MintPathSuspect];
        for (uint256 i = 0; i < 3; ++i) {
            _setPause(states[i], reasons[i]);
            _freezeWallet(wallets[i]);
            LiquidationResult memory r = _liquidateOn(v4SpokeS, keeper, _params(proxies[i], v4UsdcReserveS, 800e6));
            assertGt(r.unitsSeized, 0, "settles under the pause and the borrower's freeze");
            _checkSettlement4(r, 800e6, usdc, vtS);
            _setPause(PauseState.None, PauseReason.None);
        }
        _assertBacked(vtS);
    }

    // TEST-193 verifies: REQ-ADAPTER-047, REQ-ADAPTER-071, REQ-PROXY-032, REQ-PROXY-035, INV-045, INV-067
    function test_TEST_193_v4ExitsAfterLiquidationWhilePaused() public {
        (address proxy, bytes32 key) = _stableAccount(bob, v4UsdcReserveS, DEBT_USDC);
        _depegUsdt4(93_000_000);
        _setPause(PauseState.Paused, PauseReason.General);
        _liquidateOn(v4SpokeS, keeper, _params(proxy, v4UsdcReserveS, 800e6));
        uint256 owed = _debtOn(v4SpokeS, proxy, v4UsdcReserveS);
        _repayOn(bob, bob, mS, v4UsdcReserveS, owed + 1e6, true);
        assertEq(_debtOn(v4SpokeS, proxy, v4UsdcReserveS), 0, "repaid while Paused");
        uint256 left = _credited4(key);
        vm.prank(bob);
        adapterC.withdraw(mS, _ref4(key), left, _deadline(), 0);
        assertEq(v4posm.ownerOf(uint256(key)), bob, "the NFT returned to its depositor");
        assertEq(_sharesOn(v4SpokeS, proxy, mkt[mS].reserveId), 0, "nothing left supplied");
        _assertBacked(vtS);
    }
}
