// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ILPVaultSwapErrors} from "../../src/liquidation/lp-vault-swap/ILPVaultSwapErrors.sol";
import {LiquidationParams} from "../../src/liquidation/lp-vault-swap/types/LiquidationParams.sol";
import {LiquidationResult} from "../../src/liquidation/lp-vault-swap/types/LiquidationResult.sol";
import {RouteMode} from "../../src/liquidation/lp-vault-swap/types/RouteMode.sol";
import {LPVaultSwapUnitBase} from "../unit/LPVaultSwap.Base.sol";

/// @title LPVaultSwapCascadeFuzzTest
/// @notice TEST-218, LPVaultSwap's part: liquidation cascades across two markets. Twelve accounts (six per market) are
/// opened at HF 1.10; both vault prices fall by 5–40 %; the pools' route rates move within ±2 %; then rounds of
/// liquidation (until no account is eligible, at most 40) in a fuzzed order, each call sized at a fuzzed share of the
/// account's debt with a shortfall budget (resized to the whole debt when Aave's dust rule refuses the part), by
/// rotating callers in both route modes. Asserted: every account below HF 1 is liquidated within the run (it ends at
/// HF ≥ 1 or with no collateral left), or its refusal is one the 3.6 halt matrix names; every settlement conserves the
/// debt asset, meets its floor on `R + shortfall` and keeps `D ≤ Kf`; `INV-076` per liquidation (an account solvent at
/// the bonus never loses health); LPVaultSwap ends neutral. The LP-removal and concentration-gate halves of the row are
/// the RiskModule's and the LPVault's suites.
/// forge-config: default.isolate = false
/// forge-config: default.fuzz.runs = 24
contract LPVaultSwapCascadeFuzzTest is LPVaultSwapUnitBase {
    uint256 internal constant PER_MARKET = 6;
    uint256 internal constant MAX_ROUNDS = 40;

    address[] internal proxies;
    bool[] internal inB;
    address[3] internal callers;

    function setUp() public override {
        super.setUp();
        _deploySecondMarket();
        callers = [keeper, makeAddr("anyEoa"), makeAddr("otherKeeper")];
        for (uint256 i = 0; i < PER_MARKET; ++i) {
            uint128 units = uint128(1000e6 + i * 700e6);
            // HF 1.10 at $2.10: debt = units x 2.10 x 0.80 / 1.10
            uint256 debt = uint256(units) * 168 / 110;
            (address a,) = _openAccount(makeAddr(string(abi.encode("a", i))), units, debt, 250_000_000);
            (address b,) = _openAccountB(makeAddr(string(abi.encode("b", i))), units, debt, 250_000_000);
            proxies.push(a);
            inB.push(false);
            proxies.push(b);
            inB.push(true);
        }
    }

    function _named(
        bytes memory reason
    ) internal pure returns (bool) {
        bytes4 s = bytes4(reason);
        return s == ILPVaultSwapErrors.NotLiquidatable.selector || s == ILPVaultSwapErrors.NoRouteAvailable.selector
            || s == ILPVaultSwapErrors.RecoveryBelowFloor.selector || s == ILPVaultSwapErrors.NothingSeized.selector
            || s == bytes4(keccak256("MustNotLeaveDust()"));
    }

    function _liquidateOnce(
        uint256 i,
        uint256 shareBps,
        uint256 callerIndex,
        bool backupOnly
    ) internal returns (bool settled) {
        address proxy = proxies[i];
        uint256 debt = _debtOf(proxy, usdcReserveId);
        if (debt == 0) return false;
        uint256 size = debt * shareBps / 10_000;
        if (size < 10e6) size = debt;
        return _liquidateSized(i, size, size / 20, callerIndex, backupOnly);
    }

    function _liquidateSized(
        uint256 i,
        uint256 size,
        uint256 maxShortfall,
        uint256 callerIndex,
        bool backupOnly
    ) internal returns (bool settled) {
        address proxy = proxies[i];
        uint256 debt = _debtOf(proxy, usdcReserveId);
        LiquidationParams memory p = _params(proxy, size);
        p.marketId = inB[i] ? MARKET_B : MARKET_ID;
        p.routeMode = backupOnly ? RouteMode.BackupOnly : RouteMode.PrimaryThenBackup;
        p.maxShortfall = maxShortfall;
        address caller = callers[callerIndex % 3];
        uint256 hfBefore = _hf(proxy);
        _fund(usdc, caller, size + p.maxShortfall);
        vm.prank(caller);
        try lvs.liquidate(p) returns (LiquidationResult memory r) {
            settled = true;
            assertEq(
                r.callerFunds + r.recovered + r.shortfall, r.debtRepaid + r.avanaFee + r.borrowerSurplus + r.keeperOut
            );
            assertGe(r.recovered + r.shortfall, r.minOut, "floor on R + shortfall");
            assertLe(r.debtRepaid, r.callerFunds, "D <= Kf");
            if (hfBefore >= 0.84e18 && _debtOf(proxy, usdcReserveId) != 0) {
                assertGe(_hf(proxy), hfBefore, "INV-076: an account solvent at the bonus never loses health");
            }
        } catch (bytes memory reason) {
            assertTrue(_named(reason), "a refusal outside the halt matrix");
            // Aave's dust rule refuses a partial call that would leave a sliver: the keeper resizes to the whole debt,
            // as the preview tells it to.
            if (bytes4(reason) == bytes4(keccak256("MustNotLeaveDust()")) && size < debt) {
                vm.prank(caller);
                usdc.approve(address(lvs), 0);
                return _liquidateSized(i, debt, debt / 20, callerIndex, backupOnly);
            }
        }
        vm.prank(caller);
        usdc.approve(address(lvs), 0);
    }

    /// @notice The cascade: fuzzed price fall, route rates, order, call sizes, callers and route modes.
    // TEST-218 verifies: INV-045, INV-046, INV-074, INV-076, INV-081, SPEC-LIQ-021, REQ-SWAP-118, Q-241, Q-249, Q-251
    function testFuzz_TEST_218_cascadeLiquidatesEveryEligibleAccount(
        uint256 dropBps,
        uint256 rateBps,
        uint256 orderSeed,
        uint256 shareBps,
        uint256 callerSeed
    ) public {
        dropBps = bound(dropBps, 500, 4000);
        rateBps = bound(rateBps, 9800, 10_200);
        shareBps = bound(shareBps, 2000, 10_000);
        int256 price = int256(P_VAULT * (10_000 - dropBps) / 10_000);
        lpOracle.setAnswer(price);
        lpOracleB.setAnswer(price);
        usdtUsdcPool.setRate(rateBps, 10_000);
        usdtUsdcPool2.setRate(rateBps, 10_000);
        uint256 n = proxies.length;
        uint256 settledCount = 0;
        for (uint256 round = 0; round < MAX_ROUNDS && _anyEligible(); ++round) {
            uint256 start = uint256(keccak256(abi.encode(orderSeed, round))) % n;
            for (uint256 k = 0; k < n; ++k) {
                uint256 i = (start + k * 5) % n; // 5 is coprime with 12: a full permutation per round
                if (_hf(proxies[i]) >= 1e18 || _suppliedOf(i) == 0) continue;
                bool backupOnly = uint256(keccak256(abi.encode(callerSeed, round, k))) % 2 == 1;
                if (_liquidateOnce(i, shareBps, callerSeed + k, backupOnly)) ++settledCount;
            }
        }
        for (uint256 i = 0; i < n; ++i) {
            assertTrue(_hf(proxies[i]) >= 1e18 || _suppliedOf(i) == 0, "an eligible account was left unliquidated");
        }
        if (dropBps > 1000) assertGt(settledCount, 0, "the fall made accounts liquidatable");
        assertEq(usdc.balanceOf(address(lvs)), 0, "LPVaultSwap keeps no USDC");
        assertEq(usdt.balanceOf(address(lvs)), 0, "LPVaultSwap keeps no USDT");
        assertEq(vt.balanceOf(address(lvs)), 0, "no vault tokens of market 4");
        assertEq(vtB.balanceOf(address(lvs)), 0, "no vault tokens of market 5");
        assertFalse(lock.isLocked(), "Lock free");
    }

    function _anyEligible() internal view returns (bool) {
        for (uint256 i = 0; i < proxies.length; ++i) {
            if (_hf(proxies[i]) < 1e18 && _suppliedOf(i) != 0) return true;
        }
        return false;
    }

    function _suppliedOf(
        uint256 i
    ) internal view returns (uint256) {
        return _suppliedUnitsIn(proxies[i], inB[i] ? vtReserveIdB : vtReserveId);
    }

    function _suppliedUnitsIn(
        address proxy,
        uint256 reserveId
    ) internal view returns (uint256) {
        (bool ok, bytes memory ret) = aave.cdpSpoke
        .staticcall(abi.encodeWithSignature("getUserSuppliedShares(uint256,address)", reserveId, proxy));
        require(ok, "shares");
        return abi.decode(ret, (uint256));
    }
}
