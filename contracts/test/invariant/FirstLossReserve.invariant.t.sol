// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {FirstLossReserve} from "../../src/reserve/FirstLossReserve.sol";
import {FirstLossReserveFixture} from "../utils/fixtures/FirstLossReserveFixture.sol";
import {Test} from "forge-std/Test.sol";

/// @notice Records deficits, funds both layers and covers in any order on the local Aave V4 Hub, tracking what each
/// layer paid. It deploys its own stack so the fixture's helpers run as its own calls.
contract FirstLossReserveHandler is FirstLossReserveFixture {
    uint256 public reported;
    uint256 public covered;
    uint256 public funded;
    /// @notice Covers that paid while no deficit was recorded, or paid past it.
    uint256 public overPaid;
    /// @notice Offset covers that paid while the Avana layer was active on the Hub and held funds.
    uint256 public outOfOrder;

    constructor() {
        _deployLayers();
        funded = avanaLayer.fundedBalance() + daoOffset.fundedBalance();
    }

    function report(
        uint256 amount
    ) external {
        amount = bound(amount, 1e18, 50_000e18);
        if (hub.getAssetLiquidity(ghoAssetId) < amount) return;
        _reportDeficit(ghoAssetId, aave.cdpSpoke, amount);
        reported += amount;
    }

    function fund(
        bool offset,
        uint256 amount
    ) external {
        amount = bound(amount, 1e18, 100_000e18);
        _fundLayer(offset ? daoOffset : avanaLayer, offset ? daoTreasury : avanaLabs, amount);
        funded += amount;
    }

    function cover(
        bool offset,
        bool otherCdp,
        uint256 maxAmount
    ) external {
        FirstLossReserve layer = offset ? daoOffset : avanaLayer;
        address spoke = otherCdp ? otherSpoke : aave.cdpSpoke;
        maxAmount = bound(maxAmount, 1, 400_000e18);
        uint256 deficit = _deficit(spoke);
        bool avanaFirst = avanaLayer.fundedBalance() != 0 && hub.getSpokeConfig(ghoAssetId, address(avanaLayer)).active;
        vm.prank(coverageCaller);
        try layer.coverDeficit(spoke, maxAmount) returns (uint256, uint256 paid) {
            covered += paid;
            if (paid > deficit || spoke != aave.cdpSpoke) ++overPaid;
            if (offset && avanaFirst) ++outOfOrder;
        } catch {}
    }

    function setAvanaActive(
        bool active
    ) external {
        _setActive(ghoAssetId, address(avanaLayer), active);
    }

    function cdpDeficit() external view returns (uint256) {
        return _deficit(aave.cdpSpoke);
    }

    function balances() external view returns (uint256) {
        return avanaLayer.fundedBalance() + daoOffset.fundedBalance();
    }
}

/// @notice The reserve pays only real deficits, never past them, never another Spoke's, and in the loss order.
contract FirstLossReserveInvariantTest is Test {
    FirstLossReserveHandler internal handler;

    function setUp() public {
        handler = new FirstLossReserveHandler();
        bytes4[] memory selectors = new bytes4[](4);
        selectors[0] = FirstLossReserveHandler.report.selector;
        selectors[1] = FirstLossReserveHandler.fund.selector;
        selectors[2] = FirstLossReserveHandler.cover.selector;
        selectors[3] = FirstLossReserveHandler.setAvanaActive.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
        targetContract(address(handler));
    }

    function invariant_paysOnlyRealDeficits() public view {
        assertEq(handler.overPaid(), 0);
        assertLe(handler.covered(), handler.reported());
    }

    function invariant_deficitIsReportedLessCovered() public view {
        assertEq(handler.cdpDeficit(), handler.reported() - handler.covered());
    }

    function invariant_lossOrder() public view {
        assertEq(handler.outOfOrder(), 0);
    }

    /// @notice What both layers hold is what was funded less what was covered, give or take share rounding.
    function invariant_balancesAccountForCovers() public view {
        uint256 expected = handler.funded() - handler.covered();
        assertApproxEqAbs(handler.balances(), expected, 1e6);
    }
}
