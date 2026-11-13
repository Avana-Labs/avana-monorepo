// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ILPVaultSwapEvents} from "../../src/liquidation/lp-vault-swap/ILPVaultSwapEvents.sol";
import {LiquidationParams} from "../../src/liquidation/lp-vault-swap/types/LiquidationParams.sol";
import {LiquidationResult} from "../../src/liquidation/lp-vault-swap/types/LiquidationResult.sol";
import {SettlementReport} from "../../src/types/SettlementReport.sol";
import {LPVaultSwapFixture} from "../utils/fixtures/LPVaultSwapFixture.sol";
import {PayoutToken} from "../utils/mocks/PayoutToken.sol";
import {Vm} from "forge-std/Vm.sol";

/// @title LPVaultSwapUnitBase
/// @notice Shared base of the LPVaultSwap suites: the fixture, an independent transcription of the 2.11 settlement
/// formulas used as the expected values of every flow test (written from the spec text, not from SettlementMath, so a
/// fault in either shows), balance snapshots of every account a liquidation touches, and revert helpers.
/// @dev Every test contract inheriting this base runs one test as one transaction (`isolate = false`), so the Lock,
/// transient contexts and balances behave as in production within a test.
abstract contract LPVaultSwapUnitBase is LPVaultSwapFixture, ILPVaultSwapEvents {
    /// @dev Expected settlement of one routed liquidation, from 2.11 SPEC-LIQ-001 to SPEC-LIQ-022.
    struct Expect {
        uint256 value;
        uint256 units;
        uint256 slippage;
        uint256 minRec;
        uint256 recovered;
        uint256 surplus;
        uint256 gain;
        uint256 fee;
        uint256 reward;
        uint256 borrower;
        uint256 shortfall;
        uint256 keeperOut;
    }

    /// @dev LPVaultSwap's, the caller's, the fee recipient's and the escrow's balances of every token a call moves.
    struct Snap {
        uint256 lvsUsdc;
        uint256 lvsUsdt;
        uint256 lvsGho;
        uint256 lvsVt;
        uint256 callerUsdc;
        uint256 callerUsdt;
        uint256 callerGho;
        uint256 feeUsdc;
        uint256 feeGho;
        uint256 escrowUsdc;
        uint256 escrowUsdt;
        uint256 vtSupply;
    }

    function setUp() public virtual {
        _deployLPVaultSwap();
    }

    // ─── Independent model of 2.11 (USDC or GHO debt; vault token and pool tokens of 6 decimals) ───

    function _ceilDiv(
        uint256 a,
        uint256 b
    ) internal pure returns (uint256) {
        return a == 0 ? 0 : (a - 1) / b + 1;
    }

    /// @dev SPEC-LIQ-001 and SPEC-LIQ-003 with `lf = 0`: `s = min(allowance, ⌊1e4 (b − 1e4) / b⌋)`.
    function _slippageOf(
        uint256 bonus,
        uint256 allowance
    ) internal pure returns (uint256 s) {
        if (bonus <= BPS) return 0;
        s = BPS * (bonus - BPS) / bonus;
        if (allowance < s) s = allowance;
    }

    /// @dev `V = ⌊c × Pc × 10^dd / (10^dv × Pdebt)⌋` with `dv = 6`.
    function _valueOf(
        uint256 c,
        uint256 pc,
        uint256 pdebt,
        uint256 dd
    ) internal pure returns (uint256) {
        return c * pc * 10 ** dd / (1e6 * pdebt);
    }

    /// @dev `U` of the USDC/USDT market against a debt asset of `dd` decimals priced `pdebt`; USDC counts 1 when it is
    /// the debt asset.
    function _unitsOf(
        bool usdcIsDebt,
        uint256 dd,
        uint256 pdebt
    ) internal pure returns (uint256 u) {
        u = usdcIsDebt ? 1 : _ceilDiv(PRICE_UNIT * 10 ** dd, 1e6 * pdebt);
        u += _ceilDiv(P_USDT * 10 ** dd, 1e6 * pdebt);
    }

    /// @dev `minRec = max(0, ⌈V (1e4 − s) / 1e4⌉ − U − ε)`.
    function _floorOf(
        uint256 v,
        uint256 s,
        uint256 u,
        uint256 eps
    ) internal pure returns (uint256) {
        uint256 term = _ceilDiv(v * (BPS - s), BPS);
        return term > u + eps ? term - u - eps : 0;
    }

    /// @dev The unwind of `c` units at the fixture's LPVault rates: `[USDC, USDT]`.
    function _released(
        uint256 c
    ) internal pure returns (uint256 a0, uint256 a1) {
        a0 = c * USDC_RATE / 1e6;
        a1 = c * USDT_RATE / 1e6;
    }

    /// @dev The full expected settlement of a USDC-debt liquidation of `c` units for `d` repaid, caller funding `kf`,
    /// recovery `r`, Aave bonus `bonus`, prices `pc` and $1 USDC.
    function _expectUsdc(
        uint256 c,
        uint256 d,
        uint256 kf,
        uint256 r,
        uint256 bonus,
        uint256 pc,
        uint256 maxShortfall
    ) internal pure returns (Expect memory e) {
        e.value = _valueOf(c, pc, PRICE_UNIT, 6);
        e.units = _unitsOf(true, 6, PRICE_UNIT);
        e.slippage = _slippageOf(bonus, SLIPPAGE_BPS);
        e.minRec = _floorOf(e.value, e.slippage, e.units, FLOOR_ROUNDING_ALLOWANCE_USDC);
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

    /// @dev USDC recovered by the default routes from `c` units: the USDC leg plus the USDT leg at 0.9995.
    function _routedRecovery(
        uint256 c
    ) internal pure returns (uint256) {
        (uint256 a0, uint256 a1) = _released(c);
        return a0 + a1 * 9995 / 10_000;
    }

    /// @dev SPEC-LIQ-018 minimum of the USDT leg into USDC: `max(1, ⌈Vleg (1e4 − sLeg) / 1e4⌉ − Uleg − ⌊ε / n'⌋)`.
    function _usdtLegMinOut(
        uint256 a1,
        uint256 sLeg,
        uint256 swapped
    ) internal pure returns (uint256) {
        uint256 vLeg = a1 * P_USDT / PRICE_UNIT;
        uint256 term = _ceilDiv(vLeg * (BPS - sLeg), BPS);
        uint256 cut = 1 + FLOOR_ROUNDING_ALLOWANCE_USDC / swapped;
        return term > cut ? term - cut : 1;
    }

    // ─── Snapshots ───

    function _snap(
        address caller
    ) internal view returns (Snap memory s) {
        s.lvsUsdc = usdc.balanceOf(address(lvs));
        s.lvsUsdt = usdt.balanceOf(address(lvs));
        s.lvsGho = gho.balanceOf(address(lvs));
        s.lvsVt = vt.balanceOf(address(lvs));
        s.callerUsdc = usdc.balanceOf(caller);
        s.callerUsdt = usdt.balanceOf(caller);
        s.callerGho = gho.balanceOf(caller);
        s.feeUsdc = usdc.balanceOf(feeRecipient);
        s.feeGho = gho.balanceOf(feeRecipient);
        s.escrowUsdc = usdc.balanceOf(address(escrow));
        s.escrowUsdt = usdt.balanceOf(address(escrow));
        s.vtSupply = vt.totalSupply();
    }

    /// @dev REQ-SWAP-042: no change in LPVaultSwap's balance of the debt assets, the vault token or the pool tokens.
    function _assertNeutral(
        Snap memory before
    ) internal view {
        Snap memory a = _snap(address(0));
        assertEq(a.lvsUsdc, before.lvsUsdc, "LPVaultSwap USDC changed");
        assertEq(a.lvsUsdt, before.lvsUsdt, "LPVaultSwap USDT changed");
        assertEq(a.lvsGho, before.lvsGho, "LPVaultSwap GHO changed");
        assertEq(a.lvsVt, before.lvsVt, "LPVaultSwap vault tokens changed");
    }

    /// @dev REQ-SWAP-023, REQ-SWAP-042: every allowance LPVaultSwap granted is 0 again.
    function _assertNoAllowances() internal view {
        address[5] memory spenders =
            [aave.cdpSpoke, address(usdtPrimary), address(usdtBackup), address(escrow), address(adapter)];
        for (uint256 i = 0; i < spenders.length; ++i) {
            assertEq(usdc.allowance(address(lvs), spenders[i]), 0, "USDC allowance left");
            assertEq(usdt.allowance(address(lvs), spenders[i]), 0, "USDT allowance left");
            assertEq(gho.allowance(address(lvs), spenders[i]), 0, "GHO allowance left");
        }
        assertEq(usdc.allowance(address(lvs), address(usdcCoverage)), 0, "coverage allowance left");
    }

    // ─── Calls ───

    function _fund(
        PayoutToken asset,
        address caller,
        uint256 amount
    ) internal {
        asset.mint(caller, amount);
        vm.prank(caller);
        asset.approve(address(lvs), type(uint256).max);
    }

    /// @dev Funds and approves `caller`, then expects `liquidate(p)` to revert with exactly `err`.
    function _expectLiquidateRevert(
        address caller,
        LiquidationParams memory p,
        bytes memory err
    ) internal {
        PayoutToken asset = p.debtReserveId == ghoReserveId ? gho : usdc;
        _fund(asset, caller, p.debtToCover + p.maxShortfall);
        vm.prank(caller);
        vm.expectRevert(err);
        lvs.liquidate(p);
    }

    /// @dev The `LiquidationSettled` report of the last call in the recorded logs.
    function _settledReport(
        Vm.Log[] memory logs
    ) internal pure returns (SettlementReport memory report, bool found) {
        bytes32 sig = LiquidationSettled.selector;
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].topics.length > 0 && logs[i].topics[0] == sig) {
                report = abi.decode(logs[i].data, (SettlementReport));
                found = true;
            }
        }
    }

    function _count(
        Vm.Log[] memory logs,
        bytes32 sig
    ) internal pure returns (uint256 n) {
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].topics.length > 0 && logs[i].topics[0] == sig) ++n;
        }
    }

    function _err(
        bytes4 selector
    ) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(selector);
    }

    /// @notice Carol's small account: 1,500 vault tokens pledged at $2.50 against 1,950 USDC, at $1.50 HF 0.923, so
    /// Aave repays her whole debt in one call.
    function _carolAccount() internal returns (address proxy, bytes32 key) {
        (proxy, key) = _openAccount(carol, 1500e6, 1950e6, 250_000_000);
        lpOracle.setAnswer(150_000_000);
    }

    /// @dev Bob's standard liquidation with `debtToCover` from `caller`; returns the result.
    function _bobLiquidation(
        address caller,
        uint256 debtToCover
    ) internal returns (address proxy, LiquidationResult memory r) {
        (proxy,) = _bobAccount();
        r = _liquidateAs(caller, _params(proxy, debtToCover));
    }

    function _assertResult(
        LiquidationResult memory r,
        Expect memory e
    ) internal pure {
        assertEq(r.minOut, e.minRec, "minRec");
        assertEq(r.recovered, e.recovered, "R");
        assertEq(r.avanaFee, e.fee, "A");
        assertEq(r.keeperReward, e.reward, "kr");
        assertEq(r.borrowerSurplus, e.borrower, "B");
        assertEq(r.shortfall, e.shortfall, "shortfall");
        assertEq(r.keeperOut, e.keeperOut, "keeperOut");
    }

    /// @dev Reverts expected from LPVaultSwap carry these selectors.
    function _lvsError(
        bytes4 selector,
        uint256 arg
    ) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(selector, arg);
    }
}
