// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ClPriceMath} from "../../src/amm/concentrated-liquidity/ClPriceMath.sol";
import {RiskModuleMath} from "../../src/policy/risk-module/RiskModuleMath.sol";
import {PriceState} from "../../src/types/PriceState.sol";
import {PriceStateView} from "../../src/types/PriceStateView.sol";
import {LPOracleCLFixture} from "../utils/fixtures/LPOracleCLFixture.sol";
import {DifferentialTest} from "./utils/DifferentialTest.sol";

/// @title LPOracleCLDifferentialTest
/// @notice FFI differential fuzzing of the deployed concentrated-liquidity LPOracle on real Uniswap v3 pools against
/// the exact Python reference: the vault-token decimals chosen at listing (`SPEC-ORC-005`), the fresh price of one
/// whole vault token at any price vector within the listing bounds (`SPEC-ORC-006`, `SPEC-ORC-008`, the stable
/// ceiling of `SPEC-ORC-004`), the served price by state (`SPEC-ORC-017`) and the borrow-side health bound.
/// @dev Run with `FOUNDRY_PROFILE=differential forge test` after `FOUNDRY_PROFILE=univ3 forge build`. Ticks cross FFI
/// offset by `MAX_TICK`.
contract LPOracleCLDifferentialTest is DifferentialTest, LPOracleCLFixture {
    uint256 internal constant OFFSET = 887_272;

    function _d() internal returns (uint256 d) {
        uint256[] memory args = _clArgs(price0, price1);
        (d,) = abi.decode(_reference("clPrice8", args), (uint256, uint256));
    }

    function _clArgs(
        uint256 p0,
        uint256 p1
    ) internal view returns (uint256[] memory args) {
        args = new uint256[](8);
        (args[0], args[1], args[2], args[3]) = (p0, p1, token0.decimals(), token1.decimals());
        args[4] = uint256(int256(tickLower) + int256(OFFSET));
        args[5] = uint256(int256(tickUpper) + int256(OFFSET));
        (args[6], args[7]) = (stable[0] ? 1 : 0, stable[1] ? 1 : 0);
    }

    function _checkFresh(
        uint256 d,
        uint256 p0,
        uint256 p1
    ) internal {
        vm.warp(block.timestamp + 1);
        _setPrices(p0, p1);
        PriceStateView memory v = _state();
        uint256[] memory base = _clArgs(p0, p1);
        uint256[] memory args = new uint256[](9);
        for (uint256 i = 0; i < 8; ++i) {
            args[i] = base[i];
        }
        args[8] = d;
        uint256 expected = abi.decode(_reference("clPrice8At", args), (uint256));
        assertEq(uint256(v.freshAnswer), expected, "fresh price8");
        if (v.state == PriceState.Live || v.state == PriceState.Drifting) {
            assertEq(uint256(v.answer), expected, "Live or Drifting serves fresh");
        }
    }

    // TEST-037 verifies: SPEC-ORC-005, SPEC-ORC-006, SPEC-ORC-008, SPEC-ORC-004, SPEC-ORC-017
    /// forge-config: differential.fuzz.runs = 256
    function testFuzz_TEST_037_stableNarrowRangeMatchesReference(
        uint256 p0,
        uint256 p1
    ) public {
        _deployClMarket(_usdcUsdt());
        uint256 d = _d();
        p0 = bound(p0, 0.5e8, 1.5e8);
        p1 = bound(p1, 0.5e8, 1.5e8);
        _checkFresh(d, p0, p1);
    }

    // TEST-037 verifies: SPEC-ORC-005, SPEC-ORC-006, SPEC-ORC-008, SPEC-ORC-009, SPEC-ORC-017
    /// forge-config: differential.fuzz.runs = 256
    function testFuzz_TEST_037_ethUsdcFullRangeMatchesReference(
        uint256 eth,
        uint256 usd
    ) public {
        _deployClMarket(_ethUsdc());
        uint256 d = _d();
        bool wethFirst = token0.decimals() == 18;
        eth = bound(eth, 30e8, 300_000e8);
        usd = bound(usd, 0.9e8, 1.1e8);
        _checkFresh(d, wethFirst ? eth : usd, wethFirst ? usd : eth);
    }

    // TEST-037 verifies: REQ-RISK-059, SPEC-CF-005
    /// forge-config: differential.fuzz.runs = 512
    function testFuzz_TEST_037_boundedHealthFactorMatchesReference(
        uint256 hf,
        uint256 served,
        uint256 accepted
    ) public {
        hf = bound(hf, 0, 1e30);
        served = bound(served, 0, 1e30);
        accepted = bound(accepted, 1, 1e30);
        uint256[] memory args = new uint256[](3);
        (args[0], args[1], args[2]) = (hf, served, accepted);
        uint256 expected = abi.decode(_reference("boundedHealthFactor", args), (uint256));
        assertEq(RiskModuleMath.boundedHealthFactor(hf, served, accepted), expected);
    }

    // TEST-037 verifies: SPEC-ORC-009
    function test_TEST_037_listingDecimalsMatchReference() public {
        _deployClMarket(_wbtcEth());
        uint256 d = _d();
        assertGe(d, 6);
        _checkFresh(d, price0, price1);
        assertLt(ClPriceMath.MIN_SQRT_RATIO, _oracleSqrt(price0, price1));
    }
}
