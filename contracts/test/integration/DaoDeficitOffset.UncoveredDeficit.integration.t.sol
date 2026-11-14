// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IDaoDeficitOffset} from "../../src/coverage/dao-deficit-offset/IDaoDeficitOffset.sol";
import {IAaveV4Hub} from "../../src/interfaces/external/aave/IAaveV4Hub.sol";
import {DaoDeficitOffsetFixture} from "../utils/fixtures/DaoDeficitOffsetFixture.sol";

interface IHubLossViews {
    function previewRemoveByShares(
        uint256 assetId,
        uint256 shares
    ) external view returns (uint256);
    function getAssetDeficitRay(
        uint256 assetId
    ) external view returns (uint256);
    function restore(
        uint256 assetId,
        uint256 drawnAmount,
        IAaveV4Hub.PremiumDelta calldata premiumDelta
    ) external returns (uint256);
}

/// @title DaoDeficitOffsetUncoveredDeficitIntegrationTest
/// @notice TEST-299 on the pinned Aave V4 Hub: the full loss order of `Q-410` for one `(Hub, GHO)` and what lies beyond
/// it. Aave V4 has no action that writes a deficit down across all suppliers: `Hub.eliminateDeficit` is restricted and
/// burns the calling Spoke's own added shares, so an uncovered deficit stays inside the asset's added assets, the
/// supply share price does not fall, and withdrawals are paid in full first-come while liquidity lasts.
contract DaoDeficitOffsetUncoveredDeficitIntegrationTest is DaoDeficitOffsetFixture {
    IHubLossViews internal h;

    function setUp() public {
        _deployLayers();
        h = IHubLossViews(aave.hub);
    }

    // TEST-299 verifies: REQ-FLR-027, REQ-FLR-048, REQ-FLR-049, SPEC-FLR-006, INV-100, DEF-014, ATTACK-198, Q-410
    // Sources: 5.1 TEST-299, MATH-AR-51h, SYM-193a, SYM-193b, SYM-193c, SYM-193d
    /// @notice Lenders 2,000,000 GHO, Avana Umbrella 100,000, DAO offset 150,000. Borrowers draw 1,500,000 of ordinary
    /// debt and a 300,000 GHO account is liquidated to zero collateral. The Avana Umbrella covers 100,000, then the DAO
    /// offset 150,000, and 50,000 stays recorded; the lenders' share price is unchanged, so after every borrower repays,
    /// liquidity is 1,950,000 against 2,000,000 of claims: the first 1,950,000 withdrawn is paid in full and the last
    /// 50,000 of claims has nothing behind it.
    function test_TEST_299_lossOrderThenFirstComeResidual() public {
        uint256 id = ghoAssetId;
        uint256 lendShares = hub.getSpokeAddedShares(id, aave.lendSpoke);
        assertEq(h.previewRemoveByShares(id, lendShares), CREDIT_LINE_GHO, "lend claim 2,000,000");
        assertEq(hub.getAssetLiquidity(id), 2_250_000e18, "liquidity: lenders + Avana layer + DAO offset");

        _draw(id, aave.cdpSpoke, 1_500_000e18);
        _reportDeficit(id, aave.cdpSpoke, 300_000e18);

        // (1) The DAO offset is refused while the Avana Umbrella holds funds; the Avana Umbrella pays first.
        vm.prank(coverageCaller);
        vm.expectRevert(
            abi.encodeWithSelector(
                IDaoDeficitOffset.FirstLossLayerNotExhausted.selector, address(ghoCoverage), 100_000e18
            )
        );
        ghoOffset.coverDeficit(aave.cdpSpoke, type(uint256).max);
        assertEq(_coverWith(ghoCoverage, aave.cdpSpoke, type(uint256).max), 100_000e18, "layer 1: 100,000");
        // (2) Then the DAO offset.
        assertEq(_coverWith(ghoOffset, aave.cdpSpoke, type(uint256).max), 150_000e18, "layer 2: 150,000");
        // (3) The residual stays recorded on the Hub and on the CDP Spoke's draw capacity.
        assertEq(_deficitUnits(id, aave.cdpSpoke), 50_000e18, "residual 50,000");
        assertEq(h.getAssetDeficitRay(id), 50_000e18 * RAY, "asset deficit 50,000");
        assertEq(ghoCoverage.fundedBalance() + ghoOffset.fundedBalance(), 0, "both layers spent");

        // (4) No write-down: the lenders' claim still reads 2,000,000.
        assertEq(h.previewRemoveByShares(id, lendShares), CREDIT_LINE_GHO, "share price unchanged by the residual");

        // (5) Every borrower repays: liquidity 1,950,000 against 2,000,000 of claims.
        gho.mint(aave.hub, 1_500_000e18);
        vm.prank(aave.cdpSpoke);
        h.restore(id, 1_500_000e18, IAaveV4Hub.PremiumDelta(0, 0, 0));
        assertEq(hub.getAssetLiquidity(id), 1_950_000e18, "liquidity after full repayment");

        // (6) First come, first served: a full exit reverts, an exit up to liquidity is paid in full.
        vm.prank(aave.lendSpoke);
        vm.expectRevert();
        hub.remove(id, CREDIT_LINE_GHO, address(0xBEEF));
        vm.prank(aave.lendSpoke);
        hub.remove(id, 1_950_000e18, address(0xBEEF));
        assertEq(gho.balanceOf(address(0xBEEF)), 1_950_000e18, "early exits paid in full");
        uint256 left = hub.getSpokeAddedShares(id, aave.lendSpoke);
        assertEq(h.previewRemoveByShares(id, left), 50_000e18, "last 50,000 of claims");
        assertEq(hub.getAssetLiquidity(id), 0, "nothing behind them");
    }

    // TEST-299 verifies: REQ-FLR-027, DEF-014, Q-410
    // Sources: 5.1 TEST-299
    /// @notice Only a Spoke burning its own added shares can lower a recorded deficit: an address without the role is
    /// refused, and the DAO executor with the role but no Spoke position on the asset reverts `SpokeNotActive`; a later
    /// top-up of either layer clears the residual through `coverDeficit`.
    function test_TEST_299_noWriteDownOnlyLayerTopUp() public {
        _draw(ghoAssetId, aave.cdpSpoke, 1_500_000e18);
        _reportDeficit(ghoAssetId, aave.cdpSpoke, 300_000e18);
        _coverWith(ghoCoverage, aave.cdpSpoke, type(uint256).max);
        _coverWith(ghoOffset, aave.cdpSpoke, type(uint256).max);

        vm.prank(aaveDao);
        vm.expectRevert();
        hub.eliminateDeficit(ghoAssetId, 50_000e18, aave.cdpSpoke);
        _grantDeficitEliminator(aaveDao);
        vm.prank(aaveDao);
        vm.expectRevert(bytes4(keccak256("SpokeNotActive()")));
        hub.eliminateDeficit(ghoAssetId, 50_000e18, aave.cdpSpoke);
        assertEq(_deficitUnits(ghoAssetId, aave.cdpSpoke), 50_000e18, "residual unchanged");

        // The DAO tops up its offset (the Avana Umbrella is empty, so the offset may pay) and the residual clears.
        _fund(ghoOffset, gho, daoTreasury, 50_000e18);
        assertEq(_coverWith(ghoOffset, aave.cdpSpoke, type(uint256).max), 50_000e18, "top-up covers the residual");
        assertEq(hub.getSpokeDeficitRay(ghoAssetId, aave.cdpSpoke), 0, "no deficit left");
    }
}
