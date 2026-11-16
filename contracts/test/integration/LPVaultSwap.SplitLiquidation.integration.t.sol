// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAaveV4Hub} from "../../src/interfaces/external/aave/IAaveV4Hub.sol";
import {LiquidationParams} from "../../src/liquidation/lp-vault-swap/types/LiquidationParams.sol";
import {LiquidationResult} from "../../src/liquidation/lp-vault-swap/types/LiquidationResult.sol";
import {LPVaultSwapUnitBase} from "../unit/LPVaultSwap.Base.sol";
import {CollSpokeDynamicReserveConfig} from "../utils/fixtures/CollateralizationFixture.sol";
import {console2} from "forge-std/console2.sol";

/// @dev The Aave V4 SpokeConfigurator setter this suite uses to apply a tier's collateral factor and bonus.
interface ISplitSpokeConfigurator {
    function updateDynamicReserveConfig(
        address spoke,
        uint256 reserveId,
        uint32 dynamicConfigKey,
        CollSpokeDynamicReserveConfig calldata dynamicConfig
    ) external;
}

/// @title LPVaultSwapSplitLiquidationIntegrationTest
/// @notice Measures audit finding L-01's split variant (fresh audit 2026-11-15) on the local Aave V4: the same insolvent
/// account is liquidated in one call and in 2, 4 and 8 partial calls, and in the two-call split that leaves just over
/// Aave's $1,000 dust threshold for the last call. Only the call that seizes the last collateral books the Hub deficit,
/// so only its borrower surplus `B` funds the First-Loss Reserve; the earlier calls pay `B` to the borrower. Each case
/// records the total `B`, its part paid to the borrower and to the reserve, the final deficit and the keeper reward,
/// across the three tiers' collateral factor, bonus and slippage allowance and four oracle spreads. The spread is how
/// far the swap proceeds `R` sit above the conservative oracle value `V`: the fixture's unwind and routes recover
/// $2.092097 a unit, and the vault-token price is set that spread below it.
/// @dev Measurement only: it asserts the settlement conservation of every call, that partial calls of an insolvent
/// account are accepted, that the deficit does not depend on the split, and that every call started with the account
/// insolvent. The table rows are printed with `-vv`.
/// forge-config: default.isolate = false
contract LPVaultSwapSplitLiquidationIntegrationTest is LPVaultSwapUnitBase {
    /// @dev Realized USDC per 1e6 vault units: the USDC leg plus the USDT leg at the routes' 0.9995.
    uint256 internal constant REALIZED_PER_UNIT = 2_092_097;
    /// @dev Aave V4's `DUST_LIQUIDATION_THRESHOLD`, $1,000, in USDC base units at $1.
    uint256 internal constant DUST_USD = 1000e6;
    /// @dev The max-leak split leaves this much collateral for the last call (just above the dust threshold).
    uint256 internal constant LAST_SLICE_USD = 1010e6;

    /// @dev One risk tier's Aave collateral factor and maximum bonus and Avana's slippage allowance, from the anvil
    /// listing config (`script/deploy/config/anvil.json`).
    struct Tier {
        string name;
        uint16 cf;
        uint32 bonus;
        uint16 slippageBps;
    }

    /// @dev Totals over the calls of one case, in USDC base units.
    struct Outcome {
        uint256 calls;
        uint256 seizedValue;
        uint256 repaid;
        uint256 surplusB;
        uint256 toBorrower;
        uint256 toReserve;
        uint256 deficit;
        uint256 keeperReward;
        uint256 avanaFee;
        uint256 bInsolventBefore;
    }

    // ─── Tiers and cases ───

    function _stable() internal pure returns (Tier memory) {
        return Tier("Stable", 3500, 10_500, 195);
    }

    function _correlated() internal pure returns (Tier memory) {
        return Tier("Correlated", 3400, 10_600, 230);
    }

    function _volatile() internal pure returns (Tier memory) {
        return Tier("Volatile", 3000, 10_800, 300);
    }

    function _applyTier(
        Tier memory t
    ) internal {
        vm.prank(aaveDao);
        ISplitSpokeConfigurator(aave.spokeConfigurator)
            .updateDynamicReserveConfig(aave.cdpSpoke, vtReserveId, 0, CollSpokeDynamicReserveConfig(t.cf, t.bonus, 0));
        store.setSlippage(MARKET_ID, t.slippageBps);
    }

    /// @dev The vault-token price that puts `R` `spreadBps` above `V`.
    function _priceFor(
        uint256 spreadBps
    ) internal pure returns (uint256) {
        return REALIZED_PER_UNIT * 100 * BPS / (BPS + spreadBps);
    }

    /// @dev Bob's account: `debt` USDC against vault units worth `collateralUsd` at `price8`, opened at five times that
    /// price so the borrow passes at every tier's collateral factor, then priced at `price8`.
    function _openInsolvent(
        uint256 debt,
        uint256 collateralUsd,
        uint256 price8
    ) internal returns (address proxy) {
        uint256 units = collateralUsd * PRICE_UNIT / price8;
        (proxy,) = _openAccount(bob, uint128(units), debt, price8 * 5);
        lpOracle.setAnswer(int256(price8));
        assertLt(_hf(proxy), 1e18, "liquidatable");
    }

    function _deficit() internal view returns (uint256) {
        return IAaveV4Hub(aave.hub).getSpokeDeficitRay(usdcAssetId, aave.cdpSpoke);
    }

    /// @dev The account's collateral at the oracle price is below its debt (`V < debt` before the call).
    function _insolvent(
        address proxy,
        uint256 price8
    ) internal view returns (bool) {
        return _suppliedUnits(proxy) * price8 / PRICE_UNIT < _debtOf(proxy, usdcReserveId);
    }

    /// @dev One liquidation by the borrower itself (its own keeper) for `debtToCover`; adds it to `o`.
    function _call(
        Outcome memory o,
        address proxy,
        uint256 price8,
        uint256 debtToCover
    ) internal {
        bool insolvent = _insolvent(proxy, price8);
        uint256 deficitBefore = _deficit();
        uint256 reserveBefore = usdcCoverage.fundedBalance();
        LiquidationParams memory p = _params(proxy, debtToCover);
        p.maxShortfall = debtToCover / 5;
        LiquidationResult memory r = _liquidateAs(bob, p);
        assertEq(
            r.callerFunds + r.recovered + r.shortfall,
            r.debtRepaid + r.avanaFee + r.borrowerSurplus + r.keeperOut,
            "conservation"
        );
        uint256 funded = usdcCoverage.fundedBalance() - reserveBefore;
        if (_deficit() > deficitBefore) {
            assertEq(_suppliedUnits(proxy), 0, "deficit only once the collateral is gone");
            assertEq(funded, r.borrowerSurplus, "deficit call funds the reserve with B");
        } else {
            assertEq(funded, 0, "no deficit, reserve untouched");
        }
        ++o.calls;
        o.seizedValue += _valueOf(r.unitsSeized, price8, PRICE_UNIT, 6);
        o.repaid += r.debtRepaid;
        o.surplusB += r.borrowerSurplus;
        o.toReserve += funded;
        o.toBorrower += r.borrowerSurplus - funded;
        o.keeperReward += r.keeperReward;
        o.avanaFee += r.avanaFee;
        if (insolvent) o.bInsolventBefore += r.borrowerSurplus;
    }

    /// @dev Liquidates a fresh insolvent account: `parts - 1` equal partial calls of the debt the collateral can repay
    /// at the bonus, then one call for the rest of the debt (`parts == 0`: the max-leak two-call split, the first call
    /// leaving `LAST_SLICE_USD` of collateral).
    function _case(
        Tier memory t,
        uint256 spreadBps,
        uint256 debt,
        uint256 collateralUsd,
        uint256 parts
    ) internal returns (Outcome memory o) {
        uint256 price8 = _priceFor(spreadBps);
        address proxy = _openInsolvent(debt, collateralUsd, price8);
        uint256 deficit0 = _deficit();
        uint256 repayable = collateralUsd * BPS / t.bonus;
        if (parts == 0) {
            _call(o, proxy, price8, (collateralUsd - LAST_SLICE_USD) * BPS / t.bonus);
        } else {
            for (uint256 i = 1; i < parts; ++i) {
                _call(o, proxy, price8, repayable / parts);
            }
        }
        assertGt(
            _suppliedUnits(proxy) * price8 / PRICE_UNIT, DUST_USD, "partial calls leave at least the dust threshold"
        );
        _call(o, proxy, price8, _debtOf(proxy, usdcReserveId));
        assertEq(_suppliedUnits(proxy), 0, "every unit seized");
        assertEq(o.calls, parts == 0 ? 2 : parts, "call count");
        o.deficit = (_deficit() - deficit0) / 1e27;
        assertEq(o.bInsolventBefore, o.surplusB, "every call started insolvent");
        assertEq(usdc.balanceOf(address(lvs)), 0, "LPVaultSwap holds no USDC");
    }

    /// @dev Runs one, 2, 4 and 8 calls and the max-leak split at each spread, prints a row per case and checks that
    /// splitting moves `B` from the reserve to the borrower while the deficit stays the same.
    function _matrix(
        Tier memory t,
        uint256 debt,
        uint256 collateralUsd,
        uint256[] memory spreads
    ) internal {
        _applyTier(t);
        uint256 snap = vm.snapshotState();
        uint8[5] memory splits = [1, 2, 4, 8, 0];
        for (uint256 s = 0; s < spreads.length; ++s) {
            Outcome memory one;
            for (uint256 k = 0; k < splits.length; ++k) {
                vm.revertToState(snap);
                Outcome memory o = _case(t, spreads[s], debt, collateralUsd, splits[k]);
                _row(t, spreads[s], splits[k], o);
                if (splits[k] == 1) {
                    one = o;
                    assertEq(o.toBorrower, 0, "one call: B funds the reserve");
                    assertGt(o.toReserve, 0, "one call: the reserve receives B");
                } else {
                    assertGt(o.toBorrower, 0, "split: the borrower keeps B of the earlier calls");
                    assertApproxEqAbs(o.deficit, one.deficit, 2e6, "deficit independent of the split");
                    assertApproxEqAbs(o.surplusB, one.surplusB, 2e6, "total B independent of the split");
                }
            }
        }
    }

    function _spreads() internal pure returns (uint256[] memory s) {
        s = new uint256[](4);
        (s[0], s[1], s[2], s[3]) = (10, 40, 100, 200);
    }

    // ─── Is partial liquidation of an insolvent account allowed? ───

    /// @notice Aave V4 has no close factor: a call repays `min(debtToCover, debt to the target health factor)`, and for
    /// an insolvent account the target-HF debt exceeds the whole debt, so the caller's `debtToCover` sets the size. A
    /// 1,000 USDC call on the report's account (10,000 USDC debt, 9,000 of collateral, Stable tier, 0.40% spread)
    /// settles, leaves collateral, books no deficit and pays `B` to the borrower.
    function test_partialLiquidationOfAnInsolventAccountIsAllowed() public {
        _applyTier(_stable());
        uint256 price8 = _priceFor(40);
        address proxy = _openInsolvent(10_000e6, 9000e6, price8);
        uint256 deficitBefore = _deficit();
        uint256 reserveBefore = usdcCoverage.fundedBalance();
        Outcome memory o;
        _call(o, proxy, price8, 1000e6);
        assertEq(o.repaid, 1000e6, "the caller's debtToCover was repaid in full");
        assertGt(_suppliedUnits(proxy), 0, "collateral left");
        assertEq(_deficit(), deficitBefore, "no deficit booked");
        assertEq(usdcCoverage.fundedBalance(), reserveBefore, "reserve untouched");
        assertGt(o.toBorrower, 0, "B paid to the defaulted borrower");
    }

    /// @notice Aave V4's dust rule is the only limit: a partial call that would leave less than $1,000 of collateral
    /// (and not all of the debt repaid) must seize all of it, so with a `debtToCover` below what that takes Aave reverts
    /// `MustNotLeaveDust`. The borrower can therefore keep `B` on all but the last $1,000 of collateral.
    function test_dustRuleKeepsOnlyTheLastThousandDollarsForTheDeficitCall() public {
        _applyTier(_stable());
        uint256 price8 = _priceFor(40);
        address proxy = _openInsolvent(10_000e6, 9000e6, price8);
        LiquidationParams memory p = _params(proxy, (9000e6 - 500e6) * BPS / 10_500);
        p.maxShortfall = p.debtToCover / 5;
        _expectLiquidateRevert(bob, p, abi.encodeWithSelector(bytes4(keccak256("MustNotLeaveDust()"))));
    }

    // ─── Measurement matrix ───

    /// @notice The report's example (10,000 USDC debt, 9,000 of collateral) on the Stable tier at 0.10%, 0.40%, 1% and
    /// 2% spread.
    function test_splitMeasurement_stable() public {
        _matrix(_stable(), 10_000e6, 9000e6, _spreads());
    }

    /// @notice The same on the Correlated tier.
    function test_splitMeasurement_correlated() public {
        _matrix(_correlated(), 10_000e6, 9000e6, _spreads());
    }

    /// @notice The same on the Volatile tier.
    function test_splitMeasurement_volatile() public {
        _matrix(_volatile(), 10_000e6, 9000e6, _spreads());
    }

    /// @notice A large account (1,000,000 USDC debt, 900,000 of collateral) on the Stable tier at 0.40%: the dust
    /// threshold is a fixed $1,000, so the max-leak split leaves the reserve the `B` of $1,010 of collateral.
    function test_splitMeasurement_largeAccount() public {
        uint256[] memory s = new uint256[](1);
        s[0] = 40;
        _matrix(_stable(), 1_000_000e6, 900_000e6, s);
    }

    // ─── Output ───

    function _row(
        Tier memory t,
        uint256 spreadBps,
        uint256 parts,
        Outcome memory o
    ) internal pure {
        string memory split = parts == 0 ? "2 (max)" : _uint(parts);
        console2.log(
            string.concat(
                "| ",
                t.name,
                " | ",
                _pct(spreadBps, BPS),
                " | ",
                split,
                " | ",
                _usd(o.seizedValue),
                " | ",
                _usd(o.surplusB),
                " | ",
                _usd(o.toBorrower),
                " | ",
                _usd(o.toReserve),
                " | ",
                _pct(o.toBorrower, o.seizedValue),
                " | ",
                _usd(o.deficit),
                " | ",
                _usd(o.keeperReward),
                " |"
            )
        );
    }

    function _uint(
        uint256 v
    ) internal pure returns (string memory) {
        if (v == 0) return "0";
        uint256 len;
        for (uint256 x = v; x != 0; x /= 10) {
            ++len;
        }
        bytes memory b = new bytes(len);
        for (; v != 0; v /= 10) {
            b[--len] = bytes1(uint8(48 + v % 10));
        }
        return string(b);
    }

    /// @dev `x` USDC base units as dollars with two decimals.
    function _usd(
        uint256 x
    ) internal pure returns (string memory) {
        uint256 cents = (x + 5000) / 10_000;
        return string.concat(_uint(cents / 100), ".", cents % 100 < 10 ? "0" : "", _uint(cents % 100));
    }

    /// @dev `num / den` as a percentage with three decimals.
    function _pct(
        uint256 num,
        uint256 den
    ) internal pure returns (string memory) {
        if (den == 0) return "n/a";
        uint256 v = num * 100_000 / den;
        uint256 f = v % 1000;
        return string.concat(_uint(v / 1000), ".", f < 100 ? "0" : "", f < 10 ? "0" : "", _uint(f), "%");
    }
}
