// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAaveV4Hub} from "../../src/interfaces/external/aave/IAaveV4Hub.sol";
import {IAaveV4Spoke} from "../../src/interfaces/external/aave/IAaveV4Spoke.sol";
import {LiquidationParams, LiquidationResult} from "../../src/liquidation/lp-vault-swap/types/LPVaultSwapTypes.sol";
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
/// @notice Audit finding L-01, split variant (fresh audit 2026-11-15), on the local Aave V4. An underwater account (its
/// collateral value below its debt times the liquidation bonus) can be liquidated in several partial calls, and only the
/// last books the Hub deficit. Every call on such an account pays its borrower surplus `B` into the First-Loss Reserve,
/// so splitting the liquidation leaves the borrower nothing. Each case liquidates a fresh account in one call, in 2, 4
/// and 8 calls, and in two calls that leave just over Aave's $1,000 dust threshold for the last, across the three tiers'
/// collateral factor, bonus and slippage allowance and four oracle spreads. It also covers an account between `debt` and
/// `debt × bonus` (solvent at the oracle value, still underwater) and a solvent account, whose `B` still goes to the
/// borrower. The spread is how far the swap proceeds `R` sit above the conservative oracle value `V`: the fixture's
/// unwind and routes recover $2.092097 a unit, and the vault-token price is set that spread below it.
/// @dev Each case prints a row (with `-vv`): total `B`, its parts paid to the borrower and to the reserve, the
/// borrower's part over the oracle value seized, the final deficit and the keeper reward.
/// forge-config: default.isolate = false
contract LPVaultSwapSplitLiquidationIntegrationTest is LPVaultSwapUnitBase {
    /// @dev Realized USDC per 1e6 vault units: the USDC leg plus the USDT leg at the routes' 0.9995.
    uint256 internal constant REALIZED_PER_UNIT = 2_092_097;
    /// @dev Aave V4's `DUST_LIQUIDATION_THRESHOLD`, $1,000, in USDC base units at $1.
    uint256 internal constant DUST_USD = 1000e6;
    /// @dev The max-split case leaves this much collateral for the last call (just above the dust threshold).
    uint256 internal constant LAST_SLICE_USD = 1010e6;
    /// @dev Case kinds: an underwater account seized to the end, then a solvent one.
    uint256 internal constant UNDERWATER = 0;
    uint256 internal constant SOLVENT = 1;

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
        uint256 surplusB;
        uint256 toBorrower;
        uint256 toReserve;
        uint256 deficit;
        uint256 keeperReward;
        uint256 underwaterCalls;
        bool firstCallSolventAtValue;
    }

    // ─── Tiers ───

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

    // ─── Accounts and calls ───

    /// @dev The vault-token price that puts `R` `spreadBps` above `V`.
    function _priceFor(
        uint256 spreadBps
    ) internal pure returns (uint256) {
        return REALIZED_PER_UNIT * 100 * BPS / (BPS + spreadBps);
    }

    /// @dev Bob's account: `debt` USDC against vault units worth `collateralUsd` at `price8`, opened at five times that
    /// price so the borrow passes at every tier's collateral factor, then priced at `price8`.
    function _openAccountAt(
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

    function _collateralUsd(
        address proxy,
        uint256 price8
    ) internal view returns (uint256) {
        return _suppliedUnits(proxy) * price8 / PRICE_UNIT;
    }

    /// @dev The account's collateral is below its debt times the bonus Aave applies to this call.
    function _underwater(
        address proxy,
        uint256 price8
    ) internal view returns (bool) {
        uint256 bonus = IAaveV4Spoke(aave.cdpSpoke).getLiquidationBonus(vtReserveId, proxy, _hf(proxy));
        return _collateralUsd(proxy, price8) * BPS < _debtOf(proxy, usdcReserveId) * bonus;
    }

    /// @dev One liquidation by the borrower itself (its own keeper) for `debtToCover`; checks where `B` went and adds
    /// the call to `o`.
    function _call(
        Outcome memory o,
        address proxy,
        uint256 price8,
        uint256 debtToCover
    ) internal {
        bool underwater = _underwater(proxy, price8);
        if (o.calls == 0) o.firstCallSolventAtValue = _collateralUsd(proxy, price8) >= _debtOf(proxy, usdcReserveId);
        uint256 deficitBefore = _deficit();
        uint256 reserveBefore = usdcCoverage.fundedBalance();
        uint256 walletBefore = usdc.balanceOf(bob);
        LiquidationParams memory p = _params(proxy, debtToCover);
        p.maxShortfall = debtToCover / 5;
        LiquidationResult memory r = _liquidateAs(bob, p);
        assertEq(
            r.callerFunds + r.recovered + r.shortfall,
            r.debtRepaid + r.avanaFee + r.borrowerSurplus + r.keeperOut,
            "conservation"
        );
        uint256 funded = usdcCoverage.fundedBalance() - reserveBefore;
        if (underwater || _deficit() > deficitBefore) {
            assertEq(funded, r.borrowerSurplus, "underwater: B funds the reserve");
        } else {
            assertEq(funded, 0, "solvent: reserve untouched");
        }
        // The borrower is the caller here: `_liquidateAs` minted it `debtToCover + maxShortfall`, LPVaultSwap pulled
        // `Kf` and the shortfall, and paid back keeperOut plus the part of B the reserve did not take.
        assertEq(
            usdc.balanceOf(bob) + r.callerFunds + r.shortfall,
            walletBefore + debtToCover + p.maxShortfall + r.keeperOut + r.borrowerSurplus - funded,
            "wallet"
        );
        ++o.calls;
        if (underwater) ++o.underwaterCalls;
        o.seizedValue += _valueOf(r.unitsSeized, price8, PRICE_UNIT, 6);
        o.surplusB += r.borrowerSurplus;
        o.toReserve += funded;
        o.toBorrower += r.borrowerSurplus - funded;
        o.keeperReward += r.keeperReward;
    }

    /// @dev Liquidates a fresh underwater account to the end: `parts - 1` equal partial calls of the debt the collateral
    /// can repay at the bonus, then one call for the rest of the debt (`parts == 0`: two calls, the first leaving
    /// `LAST_SLICE_USD` of collateral).
    function _underwaterCase(
        Tier memory t,
        uint256 spreadBps,
        uint256 debt,
        uint256 collateralUsd,
        uint256 parts
    ) internal returns (Outcome memory o) {
        uint256 price8 = _priceFor(spreadBps);
        address proxy = _openAccountAt(debt, collateralUsd, price8);
        uint256 deficit0 = _deficit();
        uint256 repayable = collateralUsd * BPS / t.bonus;
        if (parts == 0) {
            _call(o, proxy, price8, (collateralUsd - LAST_SLICE_USD) * BPS / t.bonus);
        } else {
            for (uint256 i = 1; i < parts; ++i) {
                _call(o, proxy, price8, repayable / parts);
            }
        }
        assertGt(_collateralUsd(proxy, price8), DUST_USD, "partial calls leave at least the dust threshold");
        _call(o, proxy, price8, _debtOf(proxy, usdcReserveId));
        assertEq(_suppliedUnits(proxy), 0, "every unit seized");
        assertEq(o.calls, parts == 0 ? 2 : parts, "call count");
        assertEq(o.underwaterCalls, o.calls, "every call started underwater");
        o.deficit = (_deficit() - deficit0) / 1e27;
        assertGt(o.deficit, 0, "the last call booked a deficit");
        assertGt(o.surplusB, 0, "the calls carried a borrower surplus");
        assertEq(o.toBorrower, 0, "the underwater borrower kept no B");
        assertEq(o.toReserve, o.surplusB, "the reserve received all of B");
        assertEq(usdc.balanceOf(address(lvs)), 0, "LPVaultSwap holds no USDC");
    }

    /// @dev A solvent account (collateral worth 11,000 against 10,000 USDC, above `debt × bonus` in every tier) repaid
    /// in `parts` equal calls: no deficit, and every call pays `B` to the borrower.
    function _solventCase(
        uint256 spreadBps,
        uint256 parts
    ) internal returns (Outcome memory o) {
        uint256 price8 = _priceFor(spreadBps);
        address proxy = _openAccountAt(10_000e6, 11_000e6, price8);
        uint256 deficit0 = _deficit();
        for (uint256 i = 1; i < parts; ++i) {
            _call(o, proxy, price8, 10_000e6 / parts);
        }
        _call(o, proxy, price8, _debtOf(proxy, usdcReserveId));
        assertEq(_debtOf(proxy, usdcReserveId), 0, "debt repaid");
        assertGt(_suppliedUnits(proxy), 0, "collateral left");
        assertEq(_deficit(), deficit0, "no deficit");
        assertEq(o.underwaterCalls, 0, "no call started underwater");
        assertGt(o.surplusB, 0, "the calls carried a borrower surplus");
        assertEq(o.toReserve, 0, "solvent: the reserve took nothing");
        assertEq(o.toBorrower, o.surplusB, "solvent: the borrower received all of B");
    }

    /// @dev Every split of each spread on tier `t`: the underwater account of `debt` against `collateralUsd` in 1, 2, 4
    /// and 8 calls and the max split; on the report's account also the account between `debt` and `debt × bonus` in two
    /// calls and the solvent account in one and two calls.
    function _matrix(
        Tier memory t,
        uint256 debt,
        uint256 collateralUsd,
        uint256[] memory spreads
    ) internal {
        _applyTier(t);
        uint256 snap = vm.snapshotState();
        uint8[5] memory splits = [1, 2, 4, 8, 0];
        bool reportAccount = debt == 10_000e6;
        for (uint256 s = 0; s < spreads.length; ++s) {
            Outcome memory one;
            for (uint256 k = 0; k < splits.length; ++k) {
                vm.revertToState(snap);
                Outcome memory o = _underwaterCase(t, spreads[s], debt, collateralUsd, splits[k]);
                _row(t, spreads[s], "underwater", splits[k], o);
                if (splits[k] == 1) {
                    one = o;
                } else {
                    assertApproxEqAbs(o.deficit, one.deficit, 2e6, "deficit independent of the split");
                    assertApproxEqAbs(o.surplusB, one.surplusB, 2e6, "total B independent of the split");
                }
            }
            if (!reportAccount) continue;
            // Between debt and debt × bonus: solvent at the oracle value before the first call, still underwater.
            vm.revertToState(snap);
            Outcome memory band = _underwaterCase(t, spreads[s], 10_000e6, 10_000e6 * (BPS + t.bonus) / (2 * BPS), 2);
            assertTrue(band.firstCallSolventAtValue, "the first call started with collateral above the debt");
            _row(t, spreads[s], "debt <= coll < debt x bonus", 2, band);
            for (uint256 parts = 1; parts <= 2; ++parts) {
                vm.revertToState(snap);
                _row(t, spreads[s], "solvent", parts, _solventCase(spreads[s], parts));
            }
        }
    }

    function _spreads() internal pure returns (uint256[] memory s) {
        s = new uint256[](4);
        (s[0], s[1], s[2], s[3]) = (10, 40, 100, 200);
    }

    // ─── Partial liquidation of an underwater account ───

    /// @notice Aave V4 has no close factor: a call repays `min(debtToCover, debt to the target health factor)`, and for
    /// an underwater account the target-HF debt exceeds the whole debt, so the caller's `debtToCover` sets the size. A
    /// 1,000 USDC call on the report's account (10,000 USDC debt, 9,000 of collateral, Stable tier, 0.40% spread)
    /// settles, leaves collateral and books no deficit, and its `B` funds the First-Loss Reserve.
    // TEST-216 verifies: SPEC-LIQ-022, REQ-SWAP-027
    function test_TEST_216_partialCallOnAnUnderwaterAccountFundsTheReserve() public {
        _applyTier(_stable());
        uint256 price8 = _priceFor(40);
        address proxy = _openAccountAt(10_000e6, 9000e6, price8);
        uint256 deficitBefore = _deficit();
        Outcome memory o;
        _call(o, proxy, price8, 1000e6);
        assertGt(_suppliedUnits(proxy), 0, "collateral left");
        assertEq(_deficit(), deficitBefore, "no deficit booked");
        assertGt(o.toReserve, 0, "B funded the reserve");
        assertEq(o.toBorrower, 0, "the borrower received no B");
    }

    /// @notice Aave V4's dust rule is the only limit on a partial call: one that would leave less than $1,000 of
    /// collateral (and not all of the debt repaid) must seize all of it, so with a `debtToCover` below what that takes
    /// Aave reverts `MustNotLeaveDust`.
    // TEST-216 verifies: SPEC-LIQ-022
    function test_TEST_216_dustRuleKeepsTheLastThousandDollarsForTheDeficitCall() public {
        _applyTier(_stable());
        uint256 price8 = _priceFor(40);
        address proxy = _openAccountAt(10_000e6, 9000e6, price8);
        LiquidationParams memory p = _params(proxy, (9000e6 - 500e6) * BPS / 10_500);
        p.maxShortfall = p.debtToCover / 5;
        _expectLiquidateRevert(bob, p, abi.encodeWithSelector(bytes4(keccak256("MustNotLeaveDust()"))));
    }

    // ─── Every split, tier and spread ───

    /// @notice The report's account (10,000 USDC debt, 9,000 of collateral) on the Stable tier at 0.10%, 0.40%, 1% and
    /// 2% spread.
    // TEST-216 verifies: SPEC-LIQ-022, REQ-SWAP-026, REQ-SWAP-027
    function test_TEST_216_splitLiquidationFundsTheReserve_stable() public {
        _matrix(_stable(), 10_000e6, 9000e6, _spreads());
    }

    /// @notice The same on the Correlated tier.
    // TEST-216 verifies: SPEC-LIQ-022, REQ-SWAP-026, REQ-SWAP-027
    function test_TEST_216_splitLiquidationFundsTheReserve_correlated() public {
        _matrix(_correlated(), 10_000e6, 9000e6, _spreads());
    }

    /// @notice The same on the Volatile tier.
    // TEST-216 verifies: SPEC-LIQ-022, REQ-SWAP-026, REQ-SWAP-027
    function test_TEST_216_splitLiquidationFundsTheReserve_volatile() public {
        _matrix(_volatile(), 10_000e6, 9000e6, _spreads());
    }

    /// @notice A large account (1,000,000 USDC debt, 900,000 of collateral) on the Stable tier at 0.40%: the dust
    /// threshold is a fixed $1,000, so a split could keep almost all of `B` were it paid to the borrower.
    // TEST-216 verifies: SPEC-LIQ-022, REQ-SWAP-027
    function test_TEST_216_splitLiquidationFundsTheReserve_largeAccount() public {
        uint256[] memory s = new uint256[](1);
        s[0] = 40;
        _matrix(_stable(), 1_000_000e6, 900_000e6, s);
    }

    // ─── Output ───

    function _row(
        Tier memory t,
        uint256 spreadBps,
        string memory kind,
        uint256 parts,
        Outcome memory o
    ) internal pure {
        string memory split = parts == 0 ? "2 (max)" : _uint(parts);
        console2.log(
            string.concat(
                string.concat("| ", t.name, " | ", _pct(spreadBps, BPS), " | ", kind, " | ", split, " | "),
                string.concat(_usd(o.surplusB), " | ", _usd(o.toBorrower), " | ", _usd(o.toReserve), " | "),
                string.concat(
                    _pct(o.toBorrower, o.seizedValue), " | ", _usd(o.deficit), " | ", _usd(o.keeperReward), " |"
                )
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
