// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {AccountView} from "../../src/lens/lens/types/AccountView.sol";
import {LiquidationPreview} from "../../src/lens/lens/types/LiquidationPreview.sol";
import {RecordView} from "../../src/lens/lens/types/RecordView.sol";
import {LiquidationResult} from "../../src/liquidation/lp-vault-swap/types/LiquidationResult.sol";
import {IAaveAdapterErrors} from "../../src/policy/aave-adapter/IAaveAdapterErrors.sol";
import {PauseReason} from "../../src/types/PauseReason.sol";
import {PauseState} from "../../src/types/PauseState.sol";
import {IntegrationFlows} from "../utils/fixtures/IntegrationFlows.sol";

/// @title LpJourneyIntegrationTest
/// @notice `TEST-223` on the local deployment: one LP's journey from wallet to Spoke and back through the real
/// AaveAdapter, PositionProxy, Collateralization, LPVaultSwap and Lens, with the Lens asserted at every step against
/// what the chain then holds: deposit → borrow → collect fees → partial repay → top-up → price drop → partial
/// liquidation sized by the Lens → `repayAllAndWithdraw` → position returned. Variants: a frozen address, both pause
/// reasons, partial removal with and without debt, and a re-credit after a third party adds liquidity.
/// forge-config: default.isolate = false
contract LpJourneyIntegrationTest is IntegrationFlows {
    function setUp() public {
        _deployIntegration();
    }

    /// @dev The Lens's account view equals the Spoke's and Collateralization's state in the same block.
    function _lensMatchesChain(
        address wallet
    ) internal view returns (AccountView memory a) {
        a = lens.getAccount(wallet, MARKET_ID);
        address proxy = adapterC.proxyOf(wallet, MARKET_ID);
        assertEq(a.proxy, proxy, "Lens: proxy");
        assertTrue(a.deployed, "Lens: deployed");
        assertEq(a.borrowNonce, adapterC.borrowNonce(proxy), "Lens: borrow nonce");
        assertEq(a.healthFactor, _hf(proxy), "Lens: health factor = Spoke");
        assertEq(a.markets[0].suppliedShares, _suppliedOf(proxy, MARKET_ID), "Lens: supplied = Spoke");
        assertEq(a.markets[0].credited, coll.getAccountCredited(proxy, vt), "Lens: credited = Collateralization");
        assertEq(a.debts[0].total, _debtOf(proxy, debtReserveId), "Lens: GHO debt = Spoke");
        assertEq(a.debts[1].total, _debtOf(proxy, usdcReserveId), "Lens: USDC debt = Spoke");
        assertTrue(lens.checkBacking(vt).supplyEqualsCredited, "Lens: vault token backed");
    }

    // TEST-223 verifies: REQ-LENS-008, REQ-LENS-009, REQ-LENS-011, REQ-LENS-012, REQ-LENS-016, REQ-LENS-028, REQ-LENS-035, REQ-LENS-036, REQ-ADAPTER-071, REQ-ADAPTER-096, REQ-PROXY-032, Q-268, Q-278
    function test_TEST_223_fullJourney() public {
        (bytes32 key, address proxy) = _depositBorrowCollect();
        bytes32 key2 = _repayAndTopUp(proxy);
        _liquidateSized(proxy);
        _repayAllAndExit(proxy, key, key2);
    }

    /// @dev Deposit (the predicted proxy is the one deployed), borrow the Lens's recommended GHO, collect fees.
    function _depositBorrowCollect() internal returns (bytes32 key, address proxy) {
        (address predicted, bool deployed) = lens.predictProxy(alice, MARKET_ID);
        assertFalse(deployed, "no account yet");
        _setPrice(MARKET_ID, P_VAULT);
        (key, proxy) = _pledgeVia(alice, MARKET_ID, 20_000e6);
        assertEq(proxy, predicted, "CREATE2 address as predicted");
        assertEq(_lensMatchesChain(alice).markets[0].credited, 20_000e6, "credited");
        (uint256 rec, uint256 max) = lens.previewBorrowRecommended(alice, MARKET_ID, debtReserveId, _deadline());
        assertLt(rec, max, "recommended below the maximum");
        _borrowVia(alice, MARKET_ID, debtReserveId, rec);
        assertApproxEqRel(_hf(proxy), 1.1e18, 1e12, "lands at the recommended 1.10");
        _lensMatchesChain(alice);
        // Fees: units, supply and health factor unchanged.
        vault.accrueFees(key, 25e6);
        uint256 hf = _hf(proxy);
        vm.prank(alice);
        adapterC.collectFees(MARKET_ID, _ref(key), _deadline());
        assertEq(usdc.balanceOf(alice), 25e6, "USDC fees to the depositor");
        assertEq(usdt.balanceOf(alice), 25e6, "USDT fees to the depositor");
        assertEq(_hf(proxy), hf, "health factor unchanged");
    }

    /// @dev A third party repays a quarter 30 days later; the borrower tops up with a second record.
    function _repayAndTopUp(
        address proxy
    ) internal returns (bytes32 key2) {
        vm.warp(block.timestamp + 30 days);
        _refreshPrices();
        uint256 owed = _debtOf(proxy, debtReserveId);
        _repayVia(carol, alice, MARKET_ID, debtReserveId, owed / 4, false);
        assertApproxEqAbs(_debtOf(proxy, debtReserveId), owed - owed / 4, 1, "a quarter repaid");
        _lensMatchesChain(alice);
        (key2,) = _pledgeVia(alice, MARKET_ID, 2000e6);
        assertEq(lens.getRecords(proxy, 0, 16).length, 2, "Lens: two records");
        _lensMatchesChain(alice);
    }

    /// @dev A price drop and a partial liquidation sized by the Lens.
    function _liquidateSized(
        address proxy
    ) internal {
        _setPrice(MARKET_ID, 120_000_000);
        LiquidationPreview memory p = lens.previewLiquidation(proxy, debtReserveId, block.timestamp + 120);
        assertTrue(p.aaveLiquidatable && p.pricesUsable, "liquidatable with usable prices");
        LiquidationResult memory r = _liquidateAs(keeper, p.params);
        assertEq(r.debtRepaid, p.expectedDebtRepaid, "D as previewed");
        assertEq(r.unitsSeized, p.expectedUnitsSeized, "c as previewed");
        AccountView memory a = _lensMatchesChain(alice);
        assertEq(a.markets[0].credited, 22_000e6 - r.unitsSeized, "credited fell by the seizure");
        assertGt(a.healthFactor, p.healthFactor, "health restored toward the target");
    }

    /// @dev Repay everything with the Lens's quote and withdraw the first record in one call, then the second.
    function _repayAllAndExit(
        address proxy,
        bytes32 key,
        bytes32 key2
    ) internal {
        _setPrice(MARKET_ID, P_VAULT);
        uint256 quote = lens.quoteRepayAll(alice, MARKET_ID, debtReserveId, _deadline());
        RecordView[] memory recs = lens.getRecords(proxy, 0, 16);
        debt.mint(alice, quote);
        vm.prank(alice);
        debt.approve(adapter, quote);
        uint256[] memory ids = new uint256[](1);
        ids[0] = debtReserveId;
        uint256[] memory spends = new uint256[](1);
        spends[0] = quote;
        vm.prank(alice);
        adapterC.repayAllAndWithdraw(MARKET_ID, _ref(recs[0].positionKey), recs[0].credited, ids, spends, _deadline());
        assertEq(_debtOf(proxy, debtReserveId), 0, "debt-free");
        _withdrawVia(alice, MARKET_ID, recs[1].positionKey, recs[1].credited);
        assertEq(vault.ownerOf(key), alice, "first position returned");
        assertEq(vault.ownerOf(key2), alice, "second position returned");
        assertEq(lens.getRecords(proxy, 0, 16).length, 0, "Lens: no record left");
        assertEq(_lensMatchesChain(alice).markets[0].credited, 0, "nothing credited");
        assertFalse(lock.isLocked(), "Lock free");
    }

    // TEST-223 verifies: REQ-ADAPTER-082, REQ-ADAPTER-086, REQ-LENS-009, Q-242, Q-252
    function test_TEST_223_frozenAddress() public {
        // HF 1.05 < the 1.10 target: a top-up up to the restore amount is a rescue.
        (address proxy, bytes32 key) = _openAccount(alice, MARKET_ID, 10_000e6, 16_000e6, P_VAULT);
        reg.setFrozen(alice, true);
        assertTrue(lens.getAccount(alice, MARKET_ID).walletFrozen, "Lens: frozen wallet shown");
        uint256 nonce = adapterC.borrowNonce(proxy);
        vm.expectRevert(abi.encodeWithSelector(IAaveAdapterErrors.AddressIsFrozen.selector, alice));
        vm.prank(alice);
        adapterC.borrow(MARKET_ID, usdcReserveId, 1e6, alice, _deadline(), 0, nonce);
        // A rescue top-up of an indebted account stays open ($840, within the $1,000 restore amount).
        _pledgeVia(alice, MARKET_ID, 400e6);
        // Exits stay open: repay, then a debt-free withdrawal.
        _repayVia(alice, alice, MARKET_ID, usdcReserveId, _debtOf(proxy, usdcReserveId), true);
        _withdrawVia(alice, MARKET_ID, key, 10_000e6);
        assertEq(vault.ownerOf(key), alice, "position returned while frozen");
        _lensMatchesChain(alice);
    }

    // TEST-223 verifies: REQ-ADAPTER-045, REQ-ADAPTER-046, REQ-ADAPTER-083, REQ-LENS-031, Q-252
    function test_TEST_223_pausedGeneralRescueAndMintPathSuspectExits() public {
        (address proxy, bytes32 key) = _openAccount(alice, MARKET_ID, 10_000e6, 16_000e6, P_VAULT);
        reg.setPause(aave.hub, PauseState.Paused, PauseReason.General);
        assertEq(uint8(lens.getApplicationState(aave.hub)), uint8(PauseState.Paused), "Lens: Paused");
        assertEq(lens.getPauseReason(aave.hub), uint8(PauseReason.General), "Lens: General");
        uint256 nonce = adapterC.borrowNonce(proxy);
        vm.expectRevert(IAaveAdapterErrors.ApplicationPaused.selector);
        vm.prank(alice);
        adapterC.borrow(MARKET_ID, usdcReserveId, 1e6, alice, _deadline(), 0, nonce);
        _pledgeVia(alice, MARKET_ID, 400e6);
        assertEq(lens.getRecords(proxy, 0, 16).length, 2, "rescue top-up taken under General");

        reg.setPause(aave.hub, PauseState.Paused, PauseReason.MintPathSuspect);
        bytes32 k3 = _newKey();
        vault.mintPosition(k3, alice, MARKET_ID, 1000e6);
        vm.expectRevert(IAaveAdapterErrors.ApplicationPaused.selector);
        vm.prank(alice);
        adapterC.pledge(MARKET_ID, _ref(k3), _deadline());
        _repayVia(alice, alice, MARKET_ID, usdcReserveId, _debtOf(proxy, usdcReserveId), true);
        _withdrawVia(alice, MARKET_ID, key, 10_000e6);
        assertEq(vault.ownerOf(key), alice, "exit open under MintPathSuspect");
        _lensMatchesChain(alice);
    }

    // TEST-223 verifies: REQ-ADAPTER-045, REQ-ADAPTER-086, Q-254
    function test_TEST_223_partialRemovalWithAndWithoutDebt() public {
        (address proxy, bytes32 key) = _openAccount(alice, MARKET_ID, 10_000e6, 4000e6, P_VAULT);
        uint256[] memory mins = new uint256[](2);
        uint256 hfBefore = _hf(proxy);
        vm.prank(alice);
        uint256[] memory out = adapterC.removeLiquidity(MARKET_ID, _ref(key), 2000e6, mins, _deadline(), 0);
        assertEq(out[0], 2000e6 * USDC_RATE / 1e6, "USDC released to the wallet");
        assertLt(_hf(proxy), hfBefore, "with debt: health factor lower but checked");
        assertEq(coll.getAccountCredited(proxy, vt), 8000e6, "record keeps 8,000");
        _repayVia(alice, alice, MARKET_ID, usdcReserveId, _debtOf(proxy, usdcReserveId), true);
        vm.prank(alice);
        adapterC.removeLiquidity(MARKET_ID, _ref(key), 3000e6, mins, _deadline(), 0);
        assertEq(coll.getAccountCredited(proxy, vt), 5000e6, "debt-free removal");
        _lensMatchesChain(alice);
    }

    // TEST-223 verifies: REQ-LENS-038, REQ-ADAPTER-083, INV-088, Q-254
    function test_TEST_223_recreditAfterDonation() public {
        (address proxy, bytes32 key) = _openAccount(alice, MARKET_ID, 10_000e6, 4000e6, P_VAULT);
        vault.addUnits(key, 1000e6);
        (uint128 added,, bool rescueOnly) = lens.previewRecredit(MARKET_ID, key);
        assertEq(added, 1000e6, "Lens: the donated units");
        assertFalse(rescueOnly, "Lens: regular re-credit");
        vm.prank(alice);
        uint128 got = adapterC.recredit(MARKET_ID, _ref(key), "", _deadline());
        assertEq(got, added, "re-credited as previewed");
        assertEq(_suppliedOf(proxy, MARKET_ID), 11_000e6, "minted and supplied");
        _lensMatchesChain(alice);
    }
}
