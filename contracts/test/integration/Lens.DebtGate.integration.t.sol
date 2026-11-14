// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {LiquidationPreview} from "../../src/lens/lens/types/LiquidationPreview.sol";
import {ILPVaultSwapErrors} from "../../src/liquidation/lp-vault-swap/ILPVaultSwapErrors.sol";
import {LiquidationResult} from "../../src/liquidation/lp-vault-swap/types/LiquidationResult.sol";
import {DebtPriceView} from "../../src/oracle/debt-oracle/types/DebtPriceView.sol";
import {PriceState} from "../../src/types/PriceState.sol";
import {RouteSlot} from "../../src/types/RouteSlot.sol";
import {RealStackFlows} from "../utils/fixtures/RealStackFlows.sol";
import {OracleFeedMock} from "../utils/mocks/LPOracleMocks.sol";

/// @title LensDebtGateIntegrationTest
/// @notice `previewLiquidation`'s debt-price gate matches what `liquidate` enforces (TEST-205), on the real stack
/// (`RealStackFlows`) with the real USDC DebtOracle: a DebtOracle that is Live with a fresh accepted price but reports
/// `liquidationPaused` because the alternate route it serves is past its `borrowPriceMaxAge` makes the Lens report
/// `debtPriceFresh = false` and `pricesUsable = false`, and LPVaultSwap refuses the liquidation; once the pause lifts,
/// both views reopen and the reopened preview executes.
/// @dev Bob's account: 10,000 vault tokens against 5,880 USDC, HF 0.984 after USDT falls to $0.93 (`_depegUsdt`). The
/// timelock lowers the USDC alternate feed's `borrowPriceMaxAge` to one hour; the USDC primary feed then goes without a
/// round past its `feedMaxAge` (the DebtOracle serves the alternate) and the alternate's last round is an hour and a
/// second old, within its `liquidationPriceMaxAge`. The market's LPOracle prices USDC from the same feeds under the same
/// rule, so it is liquidation-paused too and `liquidate` refuses at its collateral rule, which runs first
/// (`StalePrice`); `Lens.DebtGate.DebtOnly` checks the debt rule alone (`DebtPriceStale`) on the stand-in fixture. The
/// L1 configuration has no sequencer feed, so the sequencer-down pause is not reachable here.
/// forge-config: default.isolate = false
contract LensDebtGateIntegrationTest is RealStackFlows {
    uint32 internal constant ALT_BORROW_AGE = 3600;
    uint256 internal mA;

    function setUp() public {
        _setUpFullStack();
        mA = _addMarket(poolA);
    }

    /// @dev New rounds now, at their current answers, on the given feeds.
    function _push(
        OracleFeedMock[] memory fs
    ) internal {
        for (uint256 i = 0; i < fs.length; ++i) {
            fs[i].push(fs[i].answer(), block.timestamp);
        }
    }

    /// @dev Every feed but the USDC primary and alternate: all four USDT feeds, the USDC second source and GHO.
    function _others() internal view returns (OracleFeedMock[] memory fs) {
        fs = new OracleFeedMock[](6);
        for (uint256 i = 0; i < 4; ++i) {
            fs[i] = feedsOf[address(usdt)][i];
        }
        (fs[4], fs[5]) = (feedsOf[address(usdc)][3], ghoFeed);
    }

    function _warp(
        uint256 s
    ) internal {
        vm.warp(block.timestamp + s);
        vm.roll(block.number + s / BLOCK_TIME);
    }

    // TEST-205 verifies: REQ-LENS-016, REQ-LENS-030, REQ-SWAP-008
    function test_TEST_205_previewReportsTheDebtLiquidationPause() public {
        (, address proxy) = _pledgeAs(bob, mA, UNITS);
        _borrowAs(bob, mA, usdcReserveId, 5880e6);
        _depegUsdt(93_000_000);
        OracleFeedMock usdcPrimary = feedsOf[address(usdc)][0];
        OracleFeedMock usdcAlternate = feedsOf[address(usdc)][1];
        vm.prank(address(timelock));
        store.tightenBorrowPriceMaxAge(address(usdcAlternate), ALT_BORROW_AGE);

        // The USDC primary goes quiet past its feedMaxAge; the alternate's last round is then an hour and a second old.
        _warp(FEED_AGE + 1);
        _push(_others());
        usdcAlternate.push(usdcAlternate.answer(), block.timestamp);
        _warp(ALT_BORROW_AGE + 1);
        _push(_others());
        usdcOracle.poke();

        DebtPriceView memory d = usdcOracle.getPriceState();
        assertEq(uint8(d.state), uint8(PriceState.Live), "the DebtOracle is Live");
        assertEq(uint8(d.routeUsed), uint8(RouteSlot.Alternate), "serving the alternate");
        (, uint64 acceptedAt) = usdcOracle.lastAcceptedPrice();
        assertEq(acceptedAt, block.timestamp - ALT_BORROW_AGE - 1, "the accepted price is the alternate's round");
        assertLe(block.timestamp - acceptedAt, FEED_AGE, "within its liquidationPriceMaxAge");
        assertTrue(d.liquidationPaused, "the alternate past its borrowPriceMaxAge pauses liquidation");

        LiquidationPreview memory p = lens.previewLiquidation(proxy, usdcReserveId, block.timestamp + 120);
        assertTrue(p.aaveLiquidatable, "liquidatable on Aave");
        assertFalse(p.debtPriceFresh, "the debt price is closed to liquidation");
        assertFalse(p.pricesUsable, "the preview reports the gate liquidate enforces");
        assertTrue(mkt[mA].oracle.getPriceState().liquidationPaused, "the LPOracle serves the same USDC alternate");
        _fundCaller(keeper, p.params);
        vm.expectRevert(ILPVaultSwapErrors.StalePrice.selector);
        vm.prank(keeper);
        lvs.liquidate(p.params);

        // A new USDC primary round lifts the pause: both views reopen and the reopened preview executes.
        usdcPrimary.push(usdcPrimary.answer(), block.timestamp);
        usdcOracle.poke();
        assertFalse(usdcOracle.getPriceState().liquidationPaused, "the DebtOracle serves the primary again");
        p = lens.previewLiquidation(proxy, usdcReserveId, block.timestamp + 120);
        assertTrue(p.debtPriceFresh, "open again");
        assertTrue(p.pricesUsable, "usable again");
        LiquidationResult memory r = _liquidateAs(keeper, p.params);
        assertEq(r.debtRepaid, p.expectedDebtRepaid, "D as previewed");
        assertEq(r.unitsSeized, p.expectedUnitsSeized, "c as previewed");
    }
}
