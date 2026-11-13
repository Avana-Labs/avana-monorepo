// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ICollateralizationViews} from "../../src/custody/collateralization/ICollateralizationViews.sol";
import {CapView} from "../../src/types/CapView.sol";
import {PledgeCounters} from "../../src/types/PledgeCounters.sol";
import {LensFixture} from "../utils/fixtures/LensFixture.sol";

/// @title LensCapHeadroomCountersUnitTest
/// @notice `getCapHeadroom`'s per-token headroom on the real Collateralization: each token's Hub cap minus its counter,
/// and the full cap for a token the Collateralization's counters do not list.
/// forge-config: default.isolate = false
contract LensCapHeadroomCountersUnitTest is LensFixture {
    function setUp() public {
        _deployLens();
        _open(alice, aliceProxy, 1, 10_000e6);
    }

    /// @notice USDC cap $300,000 and USDT cap $250,000 on the Hub. With Alice's pledge counted, each token's headroom
    /// is its cap minus its counter. When the Collateralization's counters list only the first token, USDC keeps the
    /// same headroom and USDT is reported at its full $250,000 cap, never a revert on the shorter list.
    // TEST-247 verifies: REQ-LENS-018
    function test_TEST_247_capHeadroomTokenMissingFromCounters() public {
        PledgeCounters memory k = ICollateralizationViews(address(coll)).getCounters(vt, alice);
        assertEq(k.tokenUsed.length, 2, "one counter per pool token");
        assertGt(k.tokenUsed[0] + k.tokenUsed[1], 0, "the pledge is counted");
        CapView memory full = lens.getCapHeadroom(vt, alice);
        assertEq(full.tokenHeadroomUsd.length, 2, "one headroom per token");
        assertEq(full.tokenHeadroomUsd[0], 300_000e8 - k.tokenUsed[0], "USDC cap minus its counter");
        assertEq(full.tokenHeadroomUsd[1], 250_000e8 - k.tokenUsed[1], "USDT cap minus its counter");

        uint256 usdcUsed = k.tokenUsed[0];
        k.tokenUsed = new uint256[](1);
        k.tokenUsed[0] = usdcUsed;
        vm.mockCall(address(coll), abi.encodeCall(ICollateralizationViews.getCounters, (vt, alice)), abi.encode(k));
        CapView memory short_ = lens.getCapHeadroom(vt, alice);
        assertEq(short_.tokenHeadroomUsd.length, 2, "still one headroom per market token");
        assertEq(short_.tokenHeadroomUsd[0], full.tokenHeadroomUsd[0], "the listed token is unchanged");
        assertEq(short_.tokenHeadroomUsd[1], 250_000e8, "an unlisted token counts nothing: the full cap");
        assertEq(short_.marketHeadroomUsd, full.marketHeadroomUsd, "the market headroom is unchanged");
        vm.clearMockedCalls();
    }
}
