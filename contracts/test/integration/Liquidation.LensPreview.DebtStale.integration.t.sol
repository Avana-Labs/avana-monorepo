// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {LiquidationPreview} from "../../src/lens/lens/types/LiquidationPreview.sol";
import {ILPVaultSwapErrors} from "../../src/liquidation/lp-vault-swap/ILPVaultSwapErrors.sol";
import {LiquidationResult} from "../../src/liquidation/lp-vault-swap/types/LiquidationResult.sol";
import {IntegrationFlows} from "../utils/fixtures/IntegrationFlows.sol";

/// @title LiquidationLensPreviewDebtStaleIntegrationTest
/// @notice `TEST-205`'s debt-price gate on its own: a USDC DebtOracle leg older than `liquidationPriceMaxAge` while the
/// collateral price stays usable makes the preview report `debtPriceFresh = false` and `liquidate` revert
/// `DebtPriceStale`; a fresh leg reopens both and the same preview executes.
/// @dev Kept on the stand-in fixture: on the real stack the USDC DebtOracle and the USDC/USDT market's LPOracle read
/// the same USDC feeds, so no feed state makes the debt price stale with the collateral price usable, and `liquidate`
/// refuses at its collateral rule first (`Liquidation.LensPreview` checks that case on the real stack).
/// forge-config: default.isolate = false
contract LiquidationLensPreviewDebtStaleIntegrationTest is IntegrationFlows {
    function setUp() public {
        _deployIntegration();
    }

    // TEST-205 verifies: REQ-LENS-016, REQ-SWAP-091, REQ-SWAP-096
    function test_TEST_205_debtPriceStaleGateMatchesLiquidate() public {
        _setPrice(MARKET_ID, 250_000_000);
        (, address proxy) = _pledgeVia(bob, MARKET_ID, 10_000e6);
        _borrowVia(bob, MARKET_ID, usdcReserveId, 18_000e6);
        _setPrice(MARKET_ID, P_VAULT);
        usdcOracle.setLeg(uint64(block.timestamp - FEED_AGE - 1));
        LiquidationPreview memory p = lens.previewLiquidation(proxy, usdcReserveId, block.timestamp + 120);
        assertFalse(p.debtPriceFresh, "preview: debt price stale");
        _fundCaller(keeper, p.params);
        vm.expectRevert(abi.encodeWithSelector(ILPVaultSwapErrors.DebtPriceStale.selector, usdcReserveId));
        vm.prank(keeper);
        lvs.liquidate(p.params);
        usdcOracle.setLeg(uint64(block.timestamp));
        p = lens.previewLiquidation(proxy, usdcReserveId, block.timestamp + 120);
        assertTrue(p.pricesUsable && p.debtPriceFresh, "gates clear");
        LiquidationResult memory r = _liquidateAs(keeper, p.params);
        assertEq(r.debtRepaid, p.expectedDebtRepaid, "D as previewed");
        assertEq(r.unitsSeized, p.expectedUnitsSeized, "c as previewed");
    }
}
