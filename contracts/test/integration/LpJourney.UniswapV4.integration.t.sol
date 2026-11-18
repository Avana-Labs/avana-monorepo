// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {AccountView, LiquidationPreview, RecordView} from "../../src/lens/lens/types/LensTypes.sol";
import {LiquidationResult} from "../../src/liquidation/lp-vault-swap/types/LPVaultSwapTypes.sol";
import {RealStackUniswapV4Journeys} from "../utils/fixtures/RealStackUniswapV4Journeys.sol";

/// @title LpJourneyUniswapV4IntegrationTest
/// @notice `TEST-223` on a Uniswap v4 market of the real stack (`RealStackUniswapV4Journeys`): one LP's journey from
/// wallet to the v4 Spoke and back through the real AaveAdapter, PositionProxy, Collateralization, Uniswap v4 LPVault on
/// the PositionManager and PoolManager, LPVaultSwap and Lens, with the Lens asserted at every step against the chain:
/// deposit → borrow the recommended GHO → collect real fees → a third party's partial repay → a second record → borrow
/// to the limit → price drop → partial liquidation sized by the Lens → `repayAllAndWithdraw` → both NFTs returned.
/// @dev Fees are real: a swap through the market's v4 pool and back to its price in one block. The price drop moves
/// both pool tokens to $0.92 on every feed (inside the USD band, the pool's 1:1 rate unchanged).
/// forge-config: default.isolate = false
contract LpJourneyUniswapV4IntegrationTest is RealStackUniswapV4Journeys {
    function setUp() public {
        _setUpV4Journeys();
    }

    /// @dev The Lens's account view equals the v4 Spoke's and Collateralization's state in the same block.
    function _lensMatchesChain(
        address wallet
    ) internal view returns (AccountView memory a) {
        a = lens.getAccount(wallet, mS);
        address proxy = adapterC.proxyOf(wallet, mS);
        assertEq(a.proxy, proxy, "Lens: proxy");
        assertTrue(a.deployed, "Lens: deployed");
        assertEq(a.healthFactor, _hfOn(v4SpokeS, proxy), "Lens: health factor = Spoke");
        assertEq(a.markets[0].suppliedShares, _sharesOn(v4SpokeS, proxy, mkt[mS].reserveId), "Lens: supplied");
        assertEq(a.markets[0].credited, coll.getAccountCredited(proxy, vtS), "Lens: credited = Collateralization");
        for (uint256 i = 0; i < a.debts.length; ++i) {
            assertEq(a.debts[i].total, _debtOn(v4SpokeS, proxy, a.debts[i].reserveId), "Lens: debt = Spoke");
        }
        assertTrue(lens.checkBacking(vtS).supplyEqualsCredited, "Lens: vault token backed");
    }

    // TEST-223 verifies: REQ-LENS-008, REQ-LENS-009, REQ-LENS-016, REQ-LENS-028, REQ-ADAPTER-071, REQ-AMM-V4-004, REQ-AMM-V4-010, REQ-PROXY-032
    function test_TEST_223_v4FullJourney() public {
        (address predicted, bool deployed) = lens.predictProxy(alice, mS);
        assertFalse(deployed, "no account yet");
        (bytes32 key, address proxy) = _v4PledgeUsd(alice, mS, USD);
        assertEq(proxy, predicted, "CREATE2 address as predicted");
        assertEq(_lensMatchesChain(alice).markets[0].credited, _credited4(key), "credited = the record");
        (uint256 rec, uint256 max) = lens.previewBorrowRecommended(alice, mS, v4GhoReserveS, _deadline());
        assertLt(rec, max, "recommended below the maximum");
        _borrowAs(alice, mS, v4GhoReserveS, rec);
        assertApproxEqRel(_hfOn(v4SpokeS, proxy), 1.1e18, 1e12, "lands at the recommended 1.10");
        _lensMatchesChain(alice);
        _collectRealFees(key, proxy);
        bytes32 key2 = _repayAndTopUp(proxy);
        _liquidateSized(proxy);
        _repayAllAndExit(proxy, key, key2);
    }

    /// @dev Fees: units, supply and health factor unchanged; the wallet receives exactly what the PoolManager owed.
    function _collectRealFees(
        bytes32 key,
        address proxy
    ) internal {
        _washV4Market(mS, 1e12);
        (uint256 owed0, uint256 owed1) = _feesOwed4(mS, key);
        assertGt(owed0, 0, "token0 fees accrued");
        assertGt(owed1, 0, "token1 fees accrued");
        uint256 hf = _hfOn(v4SpokeS, proxy);
        uint256 creditedBefore = _credited4(key);
        (uint256 a0, uint256 a1) = _pair4(mS, alice);
        vm.prank(alice);
        adapterC.collectFees(mS, _ref4(key), _deadline());
        (uint256 b0, uint256 b1) = _pair4(mS, alice);
        assertEq(b0 - a0, owed0, "token0 fees to the depositor");
        assertEq(b1 - a1, owed1, "token1 fees to the depositor");
        assertEq(_credited4(key), creditedBefore, "units unchanged");
        assertEq(_hfOn(v4SpokeS, proxy), hf, "health factor unchanged");
    }

    /// @dev A third party repays a quarter 30 days later; the borrower adds a second record, then borrows to the
    /// Lens's maximum.
    function _repayAndTopUp(
        address proxy
    ) internal returns (bytes32 key2) {
        vm.warp(block.timestamp + 30 days);
        vm.roll(block.number + 30 days / BLOCK_TIME);
        _refreshFeeds();
        _pokeAll();
        uint256 owed = _debtOn(v4SpokeS, proxy, v4GhoReserveS);
        _repayOn(carol, alice, mS, v4GhoReserveS, owed / 4, false);
        assertApproxEqAbs(_debtOn(v4SpokeS, proxy, v4GhoReserveS), owed - owed / 4, 1, "a quarter repaid");
        _lensMatchesChain(alice);
        (key2,) = _v4PledgeUsd(alice, mS, 2000);
        assertEq(lens.getRecords(proxy, 0, 16).length, 2, "Lens: two records");
        _lensMatchesChain(alice);
        uint256 max = lens.previewBorrowMax(alice, mS, v4GhoReserveS, _deadline());
        _borrowAs(alice, mS, v4GhoReserveS, max);
        assertGe(_hfOn(v4SpokeS, proxy), 1e18, "at the limit, above HF 1");
        _lensMatchesChain(alice);
    }

    /// @dev Both tokens fall to $0.92, then a partial liquidation sized by the Lens.
    function _liquidateSized(
        address proxy
    ) internal {
        _publish(address(usdc), 92_000_000);
        _depegUsdt4(92_000_000);
        uint256 creditedBefore = coll.getAccountCredited(proxy, vtS);
        LiquidationPreview memory p = lens.previewLiquidation(proxy, v4GhoReserveS, block.timestamp + 120);
        assertTrue(p.aaveLiquidatable && p.pricesUsable, "liquidatable with usable prices");
        LiquidationResult memory r = _liquidateOn(v4SpokeS, keeper, p.params);
        assertEq(r.debtRepaid, p.expectedDebtRepaid, "D as previewed");
        assertEq(r.unitsSeized, p.expectedUnitsSeized, "c as previewed");
        AccountView memory a = _lensMatchesChain(alice);
        assertEq(a.markets[0].credited, creditedBefore - r.unitsSeized, "credited fell by the seizure");
        assertGt(a.healthFactor, p.healthFactor, "health restored toward the target");
        _checkSettlement4(r, p.params.debtToCover, gho, vtS);
    }

    /// @dev Repay everything with the Lens's quote and withdraw the first record in one call, then the second.
    function _repayAllAndExit(
        address proxy,
        bytes32 key,
        bytes32 key2
    ) internal {
        _publish(address(usdc), 100_000_000);
        _depegUsdt4(100_000_000);
        uint256 quote = lens.quoteRepayAll(alice, mS, v4GhoReserveS, _deadline());
        RecordView[] memory recs = lens.getRecords(proxy, 0, 16);
        gho.mint(alice, quote);
        vm.prank(alice);
        gho.approve(adapter, quote);
        uint256[] memory ids = new uint256[](1);
        ids[0] = v4GhoReserveS;
        uint256[] memory spends = new uint256[](1);
        spends[0] = quote;
        vm.prank(alice);
        adapterC.repayAllAndWithdraw(mS, _ref4(recs[0].positionKey), recs[0].credited, ids, spends, _deadline());
        assertEq(_debtOn(v4SpokeS, proxy, v4GhoReserveS), 0, "debt-free");
        vm.prank(alice);
        adapterC.withdraw(mS, _ref4(recs[1].positionKey), recs[1].credited, _deadline(), 0);
        assertEq(v4posm.ownerOf(uint256(key)), alice, "first NFT returned");
        assertEq(v4posm.ownerOf(uint256(key2)), alice, "second NFT returned");
        assertEq(lens.getRecords(proxy, 0, 16).length, 0, "Lens: no record left");
        assertEq(coll.getAccountCredited(proxy, vtS), 0, "nothing credited");
        _assertBacked(vtS);
        assertFalse(lock.isLocked(), "Lock free");
    }
}
