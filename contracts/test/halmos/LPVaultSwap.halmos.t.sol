// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {SettlementMath} from "../../src/liquidation/lp-vault-swap/SettlementMath.sol";
import {LPVaultSwapImmutables} from "../../src/liquidation/lp-vault-swap/types/LPVaultSwapImmutables.sol";
import {
    LPVaultSwapSettlementHarness,
    LVSHarnessRegistry,
    LVSHarnessRoute,
    LVSHarnessToken
} from "../utils/harness/LPVaultSwapSettlementHarness.sol";
import {Test} from "forge-std/Test.sol";

/// @title LPVaultSwapHalmosTest
/// @notice PROP-059, no buy leg, for every input in range: (1) LPVaultSwap's swap-leg step routes every released token
/// other than the debt asset into the debt asset only, never routes the debt asset itself, and passes each route its
/// SPEC-LIQ-018 minimum; (2) the caller-funded settlement has no buy or sell-back term: `Kf + R + shortfall = D + A +
/// B + keeperOut` and the unused funding `Kf − D` returns inside `keeperOut`.
/// @dev Amounts are bounded to the listing ranges; the leg step runs on the real `LPVaultSwapSettlement` code through
/// a harness with two pool tokens and minting routes. Fuzz twins: `testFuzz_TEST_078_*` and `testFuzz_TEST_081_*` on
/// the full liquidation; the two floor checks time out on their division chain and have 10,000-run fuzz twins
/// `testFuzz_TEST_198_floorCoversDebt*` (PROP-017 and PROP-048 prove their parts).
contract LPVaultSwapHalmosTest is Test {
    LPVaultSwapSettlementHarness internal harness;
    LVSHarnessRegistry internal registry;
    LVSHarnessToken internal usdc;
    LVSHarnessToken internal usdt;
    LVSHarnessRoute internal usdtRoute;
    LVSHarnessRoute internal usdcRoute;

    function setUp() public {
        registry = new LVSHarnessRegistry();
        usdc = new LVSHarnessToken("USDC", 6);
        usdt = new LVSHarnessToken("USDT", 6);
        harness = new LPVaultSwapSettlementHarness(
            LPVaultSwapImmutables({
                lock: address(0x1001),
                aaveAdapter: address(0x1002),
                collateralization: address(0x1003),
                marketRegistry: address(registry),
                parameterStore: address(0x1005),
                payoutEscrow: address(0x1006),
                keeperFloor: 1
            })
        );
        usdtRoute = new LVSHarnessRoute(usdt, usdc, 1, 1);
        usdcRoute = new LVSHarnessRoute(usdc, usdt, 1, 1);
        registry.setRoute(address(usdt), address(usdc), address(usdtRoute));
        registry.setRoute(address(usdc), address(usdt), address(usdcRoute));
    }

    // PROP-059 verifies: REQ-SWAP-021, REQ-SWAP-022, REQ-SWAP-088, REQ-SWAP-089, SPEC-LIQ-018, INV-070, Q-333, Q-404
    /// @notice With USDC the debt asset and both tokens released in any amounts below 2^64: the USDC leg is never
    /// routed (its route to USDT, which would buy USDT with USDC, is never called), the USDT leg is routed into USDC
    /// only when it is not a dust leg, at a minimum of at least 1, and `R` is the USDC released plus the route's output.
    function check_PROP_059_noBuyLeg(
        uint64 a0,
        uint64 a1
    ) public {
        address[] memory tokens = new address[](2);
        (tokens[0], tokens[1]) = (address(usdc), address(usdt));
        uint8[] memory decimals = new uint8[](2);
        (decimals[0], decimals[1]) = (6, 6);
        uint256[] memory prices = new uint256[](2);
        (prices[0], prices[1]) = (1e8, 1e8);
        uint256[] memory amounts = new uint256[](2);
        (amounts[0], amounts[1]) = (a0, a1);
        usdc.mint(address(harness), a0);
        usdt.mint(address(harness), a1);
        (uint8[] memory used, uint256 recovered,) =
            harness.swapLegs(address(usdc), 6, tokens, decimals, prices, amounts, 100, 1e6);
        assert(usdcRoute.calls() == 0);
        assert(used[0] == 0);
        if (a1 > 1) {
            assert(usdtRoute.calls() == 1 && used[1] == 1);
            assert(usdtRoute.lastMinOut() >= 1);
            assert(recovered == uint256(a0) + a1);
        } else {
            assert(usdtRoute.calls() == 0);
            assert(recovered == a0);
        }
    }

    // PROP-059 verifies: SPEC-LIQ-010, SPEC-LIQ-017, REQ-SWAP-089, REQ-SWAP-111, INV-035, Q-333, Q-404
    /// @notice The unused funding returns: for `Kf ≥ D`, a recovery and floor in range and the launch fee share, the
    /// payout is `keeperOut = (Kf − D) + (R' − A − B) ≥ Kf − D`, and `keeperOut = Kf + kr` whenever `R' ≥ D`.
    function check_PROP_059_unusedPrincipalRepaid(
        uint256 debt,
        uint256 extra,
        uint256 value,
        uint256 minRec,
        uint256 recovered
    ) public pure {
        vm.assume(debt < 2 ** 120 && extra < 2 ** 120 && value < 2 ** 120 && recovered < 2 ** 120);
        vm.assume(minRec <= value);
        uint256 kf = debt + extra;
        SettlementMath.Payouts memory p =
            SettlementMath.payouts(value, debt, SettlementMath.recoveryWithFloor(minRec, recovered), 2000);
        uint256 shortfall = minRec > recovered ? minRec - recovered : 0;
        uint256 out = SettlementMath.keeperPayout(kf, recovered + shortfall, debt, p.avanaFee, p.borrowerSurplus);
        assert(out >= extra);
        assert(kf + recovered + shortfall == debt + p.avanaFee + p.borrowerSurplus + out);
        if (recovered + shortfall >= debt) assert(out == kf + p.keeperReward);
    }

    // PROP-059 verifies: SPEC-LIQ-003, SPEC-LIQ-005, SPEC-LIQ-007, REQ-SWAP-012, INV-034, Q-235, Q-404
    /// @notice USDC debt, vault token of 6 decimals at $2.10, bonus 10,500, no flash term: for every repayment
    /// `D < 2^64` Aave's seizure `c = ⌊D × 10,500 × 10⁸ / (10⁴ × 2.1·10⁸)⌋` values to a floor that, with one vault unit,
    /// one debt unit, `U` and `ε`, covers `D`. TIMEOUT at the 60 s assertion budget (the division chain); its 10,000-run
    /// fuzz twin is `testFuzz_TEST_198_floorCoversDebtUsdc`.
    function check_PROP_059_floorCoversDebtUsdc(
        uint64 debt
    ) public pure {
        _floorCovers(debt, 10_500, 6, 6, 210_000_000);
    }

    // PROP-059 verifies: SPEC-LIQ-003, SPEC-LIQ-005, SPEC-LIQ-007, REQ-SWAP-012, INV-034, Q-235, Q-404
    /// @notice GHO debt (18 decimals, Aave's fixed $1.00 source), vault token of 6 decimals at $2.00, bonus 10,200.
    /// TIMEOUT as above; fuzz twin `testFuzz_TEST_198_floorCoversDebtGho`.
    function check_PROP_059_floorCoversDebtGho(
        uint64 debt
    ) public pure {
        _floorCovers(debt, 10_200, 18, 6, 200_000_000);
    }

    function _floorCovers(
        uint256 debt,
        uint256 bonus,
        uint8 dd,
        uint8 dv,
        uint256 pc
    ) internal pure {
        vm.assume(debt >= 1);
        uint256 s = SettlementMath.effectiveSlippage(bonus, 100);
        uint256 c = debt * 1e8 * 10 ** dv * bonus / (10 ** dd * pc * 10_000);
        uint256 v = SettlementMath.seizedValue(c, pc, dv, dd, 1e8);
        uint256 vaultUnit = SettlementMath.unitValue(pc, dv, dd, 1e8);
        uint256 eps = 10 ** dd;
        uint256 u = 2 * 10 ** (dd - 6);
        uint256 minRec = SettlementMath.recoveryFloor(v, s, u, eps);
        assert(debt <= minRec + vaultUnit + 1 + u + eps);
    }
}

