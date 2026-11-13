// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAaveV4Spoke} from "../../src/interfaces/external/aave/IAaveV4Spoke.sol";
import {ActionPreview} from "../../src/lens/lens/types/ActionPreview.sol";
import {HubAssetView} from "../../src/lens/lens/types/HubAssetView.sol";
import {RemovalSizing} from "../../src/lens/lens/types/RemovalSizing.sol";
import {LensFixture} from "../utils/fixtures/LensFixture.sol";
import {CollPoolToken} from "../utils/mocks/CollateralizationMocks.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";

/// @title LensActionsInvariantTest
/// @notice Random pledges, borrows, repays, withdrawals, price moves and time on the real Aave V4 Spoke and
/// Collateralization, every action taken through its after-action preview: after every step every preview matched the
/// account Aave reported once the action ran, every removal the Lens sized kept its target, and the Spoke slices of
/// every Hub asset add up to the Hub.
/// forge-config: default.isolate = false
contract LensActionsInvariantTest is StdInvariant, LensFixture {
    uint256 internal constant VIRTUAL = 1e6;

    address[2] internal wallets;
    address[2] internal proxies;
    uint256[2] internal nextKey;
    uint256 internal mismatches;
    uint256 internal steps;

    function setUp() public {
        _deployLens();
        (wallets[0], wallets[1]) = (alice, bob);
        (proxies[0], proxies[1]) = (aliceProxy, bobProxy);
        (nextKey[0], nextKey[1]) = (1, 101);
        _open(alice, aliceProxy, nextKey[0]++, 20_000e6);
        _open(bob, bobProxy, nextKey[1]++, 8000e6);
        bytes4[] memory selectors = new bytes4[](6);
        selectors[0] = this.actPledge.selector;
        selectors[1] = this.actBorrow.selector;
        selectors[2] = this.actRepay.selector;
        selectors[3] = this.actWithdraw.selector;
        selectors[4] = this.actPrice.selector;
        selectors[5] = this.actWarp.selector;
        targetSelector(FuzzSelector({addr: address(this), selectors: selectors}));
        targetContract(address(this));
    }

    // ─── actions ───

    function _check(
        ActionPreview memory v,
        uint256 i
    ) internal {
        IAaveV4Spoke.UserAccountData memory a = IAaveV4Spoke(aave.cdpSpoke).getUserAccountData(proxies[i]);
        if (v.healthFactorAfter != a.healthFactor || v.debtValueAfterRay != a.totalDebtValueRay) ++mismatches;
        if (v.collateralValueAfter != a.totalCollateralValue) ++mismatches;
        ++steps;
    }

    function actPledge(
        uint256 who,
        uint256 units
    ) external {
        uint256 i = who % 2;
        if (coll.getOpenRecordCount(proxies[i], vt) >= 16) return;
        bytes32 key = _key(nextKey[i]++);
        uint128 u = uint128(bound(units, 10e6, 30_000e6));
        vault.mintPosition(key, wallets[i], MARKET_ID, u);
        ActionPreview memory v = lens.previewPledgeAfter(wallets[i], MARKET_ID, key);
        _pledge(wallets[i], proxies[i], key, u);
        _check(v, i);
    }

    function actBorrow(
        uint256 who,
        uint256 bps,
        bool usdcDebt
    ) external {
        uint256 i = who % 2;
        uint256 reserve = usdcDebt ? usdcReserveId : debtReserveId;
        uint256 amount = lens.previewBorrowMax(wallets[i], MARKET_ID, reserve, block.timestamp);
        amount = amount * bound(bps, 1, 10_000) / 10_000;
        if (amount == 0) return;
        ActionPreview memory v = lens.previewBorrowAfter(wallets[i], MARKET_ID, reserve, amount);
        if (usdcDebt) _borrowUsdc(proxies[i], amount);
        else _borrow(proxies[i], amount);
        _check(v, i);
    }

    function actRepay(
        uint256 who,
        uint256 bps,
        bool usdcDebt
    ) external {
        uint256 i = who % 2;
        uint256 reserve = usdcDebt ? usdcReserveId : debtReserveId;
        uint256 owed = _debtOf(proxies[i], reserve);
        uint256 amount = owed * bound(bps, 1, 10_000) / 10_000;
        if (amount == 0) return;
        ActionPreview memory v = lens.previewRepayAfter(wallets[i], MARKET_ID, reserve, amount);
        CollPoolToken asset = usdcDebt ? CollPoolToken(address(usdc)) : debt;
        asset.mint(proxies[i], amount);
        vm.startPrank(proxies[i]);
        asset.approve(aave.cdpSpoke, amount);
        IAaveV4Spoke(aave.cdpSpoke).repay(reserve, amount, proxies[i]);
        vm.stopPrank();
        _check(v, i);
    }

    function actWithdraw(
        uint256 who,
        uint256 target
    ) external {
        uint256 i = who % 2;
        RemovalSizing memory s = lens.previewMaxWithdraw(wallets[i], MARKET_ID, bound(target, 1e18, 3e18));
        if (s.bestIndex == type(uint256).max || s.records.length < 2) return;
        bytes32 key = s.records[s.bestIndex].positionKey;
        ActionPreview memory v = lens.previewWithdrawAfter(wallets[i], MARKET_ID, key);
        if (v.healthFactorAfter < s.target) ++mismatches;
        _withdraw(proxies[i], key, s.records[s.bestIndex].units);
        _check(v, i);
    }

    function actPrice(
        uint256 price
    ) external {
        _setVtPrice(int256(bound(price, 1.2e8, 2.5e8)));
    }

    function actWarp(
        uint256 dt
    ) external {
        vm.warp(block.timestamp + bound(dt, 1, 30 days));
    }

    // ─── invariants ───

    // TEST-247 verifies: REQ-LENS-052, REQ-LENS-053, REQ-LENS-054
    function invariant_TEST_247_previewsMatchedEveryAction() public view {
        assertEq(mismatches, 0, "every preview matched Aave after its action");
    }

    // TEST-247 verifies: REQ-LENS-059
    function invariant_TEST_247_slicesAddUpToTheHub() public view {
        uint256[3] memory ids = [ghoAssetId, usdcAssetId, vtAssetId];
        for (uint256 k = 0; k < 3; ++k) {
            HubAssetView memory v = lens.getHubAsset(aave.hub, ids[k]);
            uint256 shares = 0;
            uint256 drawnShares = 0;
            uint256 owed = 0;
            uint256 added = 0;
            for (uint256 j = 0; j < v.spokes.length; ++j) {
                shares += v.spokes[j].addedShares;
                drawnShares += v.spokes[j].drawnShares;
                owed += v.spokes[j].drawn;
                added += v.spokes[j].added;
            }
            assertEq(shares, v.addedShares, "added shares");
            assertEq(drawnShares, v.drawnShares, "drawn shares");
            assertGe(owed, v.owed, "owed rounds up per Spoke");
            assertLe(owed, v.owed + 2 * v.spokes.length, "within two units per Spoke");
            assertLe(added, v.added, "added rounds down per Spoke");
            uint256 virtualPart = VIRTUAL * (v.added - v.addedShares) / (v.addedShares + VIRTUAL) + 1;
            assertGe(added + v.spokes.length + virtualPart, v.added, "within a unit per Spoke and the virtual share");
        }
    }
}
