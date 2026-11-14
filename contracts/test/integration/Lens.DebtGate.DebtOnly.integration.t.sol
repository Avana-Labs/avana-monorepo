// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {LiquidationPreview} from "../../src/lens/lens/types/LiquidationPreview.sol";
import {ILPVaultSwapErrors} from "../../src/liquidation/lp-vault-swap/ILPVaultSwapErrors.sol";
import {IntegrationFlows} from "../utils/fixtures/IntegrationFlows.sol";

/// @title LensDebtGateDebtOnlyIntegrationTest
/// @notice `previewLiquidation`'s debt-price gate on its own (TEST-205): a DebtOracle that is Live with a fresh
/// accepted price but reports `liquidationPaused` while the collateral price stays usable makes LPVaultSwap revert
/// `DebtPriceStale`, and the Lens reports `debtPriceFresh = false` and `pricesUsable = false`; once the pause lifts,
/// both views reopen.
/// @dev Kept on the stand-in fixture (`usdcOracle.setLiquidationPaused`): on the real stack the USDC DebtOracle and the
/// USDC/USDT market's LPOracle read the same USDC feeds and apply the same alternate borrow-age rule, so the DebtOracle's
/// pause always pauses the collateral price too and `liquidate` refuses at its collateral rule first (`StalePrice`).
/// `Lens.DebtGate` drives the real DebtOracle's pause through feeds and time.
/// forge-config: default.isolate = false
contract LensDebtGateDebtOnlyIntegrationTest is IntegrationFlows {
    function setUp() public {
        _deployIntegration();
    }

    // TEST-205 verifies: REQ-LENS-016, REQ-LENS-030, REQ-SWAP-008
    function test_TEST_205_previewReportsTheDebtLiquidationPause() public {
        (address proxy,) = _bobAccount();
        usdcOracle.setLiquidationPaused(true);
        LiquidationPreview memory p = lens.previewLiquidation(proxy, usdcReserveId, block.timestamp + 120);
        assertFalse(p.debtPriceFresh, "the debt price is closed to liquidation");
        assertFalse(p.pricesUsable, "the preview reports the gate liquidate enforces");
        _fundCaller(keeper, p.params);
        vm.expectRevert(abi.encodeWithSelector(ILPVaultSwapErrors.DebtPriceStale.selector, usdcReserveId));
        vm.prank(keeper);
        lvs.liquidate(p.params);
        usdcOracle.setLiquidationPaused(false);
        p = lens.previewLiquidation(proxy, usdcReserveId, block.timestamp + 120);
        assertTrue(p.debtPriceFresh, "open again");
        assertTrue(p.pricesUsable, "usable again");
    }
}
