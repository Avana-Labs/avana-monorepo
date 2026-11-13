// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {TailCoverageView} from "../../src/lens/lens/types/TailCoverageView.sol";
import {LensFixture} from "../utils/fixtures/LensFixture.sol";

/// @title LensGovernanceDriftFuzzTest
/// @notice The Lens's share of the governance drift sequences (TEST-225): random sequences of cap tightenings and
/// loosenings, slice changes, Aave-side collateral-factor changes by the Aave executor, draw-cap changes and Coverage
/// Spoke funding, after each of which `Lens.getTailCoverage` must report the cap-sizing tail and the coverage ratio of
/// SPEC-FLR-005 exactly, read from the real Aave V4 Hub and Spoke.
/// @dev Expected values, GHO at $1.00 (8-decimal USD): `tail = min(ceil((tokenUsdCap + topUpSliceUsd) * CF / 10^4),
/// drawCap * 10^8)`, `ratio = floor(fundedUsd * 10^4 / tail)` (SPEC-CAP-008: above 10^4 when over-funded). USDC's cap
/// is 0, so USDT is the worst token.
/// forge-config: default.isolate = false
contract LensGovernanceDriftFuzzTest is LensFixture {
    function setUp() public {
        _deployLens();
        store.setTokenCap(aave.hub, address(usdc), 0);
    }

    function _setCollateralFactor(
        uint16 cf
    ) internal {
        _spokeConfig(
            abi.encodeWithSignature(
                "updateDynamicReserveConfig(address,uint256,uint32,(uint16,uint32,uint16))",
                aave.cdpSpoke,
                vtReserveId,
                uint32(0),
                cf,
                uint32(10_500),
                uint16(0)
            )
        );
    }

    // TEST-225 verifies: SPEC-FLR-005, REQ-LENS-034, SPEC-CAP-008
    // Sources: 5.1 TEST-225 (Lens side), MATH-GOV-01
    /// @notice Four governance steps, each a tighten or loosen of the USDT cap and the slice, a collateral-factor
    /// change on the Spoke, a draw-cap change and a funding change; after every step the reported tail, worst token,
    /// draw capacity and coverage ratio equal the formula on the values then in force.
    function testFuzz_TEST_225_tailCoverageFollowsEveryGovernanceStep(
        uint256[4] memory caps,
        uint256[4] memory slices,
        uint16[4] memory cfs,
        uint40[4] memory drawCaps,
        uint256[4] memory funded
    ) public {
        for (uint256 i = 0; i < 4; ++i) {
            uint256 cap = bound(caps[i], 1e8, 10_000_000e8);
            uint256 slice = bound(slices[i], 0, 500_000e8);
            uint16 cf = uint16(bound(cfs[i], 100, 9000));
            uint40 drawCap = uint40(bound(drawCaps[i], 1, 50_000_000));
            uint256 f = bound(funded[i], 1e18, 5_000_000e18);
            store.setTokenCap(aave.hub, address(usdt), cap);
            store.setCaps(MARKET_ID, 1_000_000e8, slice, 1e8);
            _setCollateralFactor(cf);
            _setDrawCap(ghoAssetId, aave.cdpSpoke, drawCap);
            ghoCov.set(f, f);

            TailCoverageView memory t = lens.getTailCoverage(aave.hub, address(debt));
            uint256 exposure = _ceilDiv((cap + slice) * cf, 1e4);
            uint256 drawUsd = uint256(drawCap) * 1e8;
            uint256 tail = exposure < drawUsd ? exposure : drawUsd;
            // A tie at the draw capacity can name either token; below it USDT's capped exposure is the largest.
            if (exposure < drawUsd) assertEq(t.worstToken, address(usdt), "worst token");
            assertEq(t.drawCapUsd, drawUsd, "draw capacity");
            assertEq(t.tailUsd, tail, "tail term");
            assertEq(t.fundedUsd, f / 1e10, "funded at $1.00");
            assertEq(t.ratioBps, t.fundedUsd * 1e4 / tail, "coverage ratio, rounded down");
        }
    }

    function _ceilDiv(
        uint256 a,
        uint256 b
    ) internal pure returns (uint256) {
        return a == 0 ? 0 : (a - 1) / b + 1;
    }
}
