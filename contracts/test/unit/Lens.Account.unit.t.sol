// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAaveV4Spoke} from "../../src/interfaces/external/aave/IAaveV4Spoke.sol";
import {ILensErrors} from "../../src/lens/lens/ILensErrors.sol";
import {AccountView} from "../../src/lens/lens/types/AccountView.sol";
import {RecordView} from "../../src/lens/lens/types/RecordView.sol";
import {IMarketRegistryErrors} from "../../src/policy/market-registry/IMarketRegistryErrors.sol";
import {PriceState} from "../../src/types/PriceState.sol";
import {LensFixture} from "../utils/fixtures/LensFixture.sol";
import {CollPoolToken} from "../utils/mocks/CollateralizationMocks.sol";

/// @title LensAccountUnitTest
/// @notice `predictProxy`, `getAccount`, `getAccounts`, `getRecords` and `getEscrowClaimable` against the real
/// Collateralization, vault token, ProxyManager, PayoutEscrow and Aave V4 Spoke.
/// forge-config: default.isolate = false
contract LensAccountUnitTest is LensFixture {
    uint128 internal constant UNITS = 10_000e6;

    function setUp() public {
        _deployLens();
        _open(alice, aliceProxy, 1, UNITS);
    }

    // ─── predictProxy ───

    // TEST-247 verifies: REQ-LENS-008, REQ-LENS-005
    // TEST-190 verifies: REQ-LENS-008
    function test_TEST_247_predictProxyReturnsStoredProxy() public view {
        (address proxy, bool deployed) = lens.predictProxy(alice, MARKET_ID);
        assertEq(proxy, aliceProxy, "the stored binding wins");
        assertTrue(deployed, "deployed");
    }

    // TEST-190 verifies: REQ-LENS-008
    function test_TEST_190_predictProxyUndeployedIsProxyManagerAddress() public view {
        (address proxy, bool deployed) = lens.predictProxy(bob, MARKET_ID);
        assertEq(proxy, proxyManager.predictProxy(bob, aave.cdpSpoke, MARKET_ID), "CREATE2 prediction");
        assertEq(proxy, adapterMock.predictProxy(bob, MARKET_ID), "the Adapter's prediction");
        assertFalse(deployed, "not deployed");
        assertTrue(proxy != aliceProxy, "one proxy per wallet and market");
    }

    // TEST-190 verifies: REQ-LENS-008
    function test_TEST_190_predictProxyDiffersPerWallet() public view {
        (address a,) = lens.predictProxy(alice, MARKET_ID);
        (address b,) = lens.predictProxy(bob, MARKET_ID);
        (address c,) = lens.predictProxy(keeper, MARKET_ID);
        assertTrue(a != b && b != c && a != c, "distinct accounts");
    }

    // TEST-247 verifies: REQ-LENS-022
    function test_TEST_247_predictProxyUnknownMarketReverts() public {
        vm.expectRevert(abi.encodeWithSelector(IMarketRegistryErrors.UnknownMarket.selector, 99));
        lens.predictProxy(alice, 99);
    }

    // ─── getAccount ───

    // TEST-247 verifies: REQ-LENS-009, REQ-LENS-005, REQ-LENS-010
    function test_TEST_247_getAccountIdentityAndAaveData() public {
        adapterMock.setNonce(aliceProxy, 3);
        _borrow(aliceProxy, 4000e18);
        AccountView memory a = lens.getAccount(alice, MARKET_ID);
        assertEq(a.blockNumber, block.number, "block");
        assertEq(a.timestamp, block.timestamp, "timestamp");
        assertEq(a.wallet, alice, "wallet");
        assertEq(a.spoke, aave.cdpSpoke, "spoke");
        assertEq(a.marketId, MARKET_ID, "market");
        assertEq(a.proxy, aliceProxy, "proxy");
        assertTrue(a.deployed, "deployed");
        assertEq(a.borrowNonce, 3, "nonce");
        IAaveV4Spoke.UserAccountData memory d = IAaveV4Spoke(aave.cdpSpoke).getUserAccountData(aliceProxy);
        assertEq(a.healthFactor, d.healthFactor, "health factor");
        assertEq(a.totalCollateralValue, d.totalCollateralValue, "collateral value");
        assertEq(a.totalDebtValueRay, d.totalDebtValueRay, "debt value");
        assertEq(a.avgCollateralFactor, d.avgCollateralFactor, "avg CF");
        assertEq(a.riskPremium, d.riskPremium, "risk premium");
        assertEq(a.activeCollateralCount, 1, "one collateral");
        assertEq(a.borrowCount, 1, "one borrow");
        assertEq(a.healthFactor, 4e18, "20,000 x 0.8 / 4,000");
    }

    // TEST-247 verifies: REQ-LENS-009, REQ-LENS-010
    function test_TEST_247_getAccountOneDebtPositionPerEnabledReserve() public {
        _borrow(aliceProxy, 1000e18);
        _borrowUsdc(aliceProxy, 500e6);
        vm.warp(block.timestamp + 30 days);
        AccountView memory a = lens.getAccount(alice, MARKET_ID);
        assertEq(a.debts.length, 2, "two enabled reserves");
        assertEq(a.debts[0].reserveId, debtReserveId, "GHO first");
        assertEq(a.debts[0].asset, address(debt), "GHO asset");
        assertEq(a.debts[1].reserveId, usdcReserveId, "USDC second");
        assertEq(a.debts[1].asset, address(usdc), "USDC asset");
        for (uint256 i = 0; i < 2; ++i) {
            uint256 id = a.debts[i].reserveId;
            assertEq(a.debts[i].total, _debtOf(aliceProxy, id), "total = getUserTotalDebt");
            (uint256 drawn, uint256 premium) = _userDebt(aliceProxy, id);
            assertEq(a.debts[i].drawn, drawn, "drawn");
            assertEq(a.debts[i].premium, premium, "premium");
            assertEq(a.debts[i].drawn + a.debts[i].premium, a.debts[i].total, "drawn + premium = total");
        }
        assertGe(a.debts[0].total, 1000e18, "interest accrued");
    }

    // TEST-247 verifies: REQ-LENS-009
    function test_TEST_247_getAccountZeroDebtReservesIncluded() public view {
        AccountView memory a = lens.getAccount(alice, MARKET_ID);
        assertEq(a.debts.length, 2, "both reserves listed");
        assertEq(a.debts[0].total + a.debts[1].total, 0, "no debt");
        assertEq(a.healthFactor, type(uint256).max, "no debt: Aave's max");
        assertEq(a.borrowCount, 0, "no borrow");
    }

    // TEST-247 verifies: REQ-LENS-009
    function test_TEST_247_getAccountMarketPosition() public view {
        AccountView memory a = lens.getAccount(alice, MARKET_ID);
        assertEq(a.markets.length, 1, "one collateral market");
        assertEq(a.markets[0].vaultToken, vt, "vault token");
        assertEq(a.markets[0].reserveId, vtReserveId, "reserve");
        assertEq(a.markets[0].suppliedShares, UNITS, "supplied shares");
        assertEq(a.markets[0].suppliedAssets, UNITS, "shares = assets");
        assertTrue(a.markets[0].collateralEnabled, "collateral on");
        assertEq(a.markets[0].credited, UNITS, "credited");
        assertEq(a.markets[0].recordCount, 1, "one record");
        assertEq(a.markets[0].shortfall, 0, "no shortfall");
        assertEq(uint8(a.markets[0].priceState), uint8(PriceState.Live), "Live");
        assertEq(a.markets[0].rescueUnits, 0, "no rescue units");
    }

    // TEST-247 verifies: REQ-LENS-009, REQ-LENS-011
    function test_TEST_247_getAccountShortfallAfterUnreconciledSeizure() public {
        _borrow(aliceProxy, 15_000e18);
        _setVtPrice(1.8e8);
        uint256 seized = _seizeAndKeep(aliceProxy, 3000e18);
        assertGt(seized, 0, "seized");
        AccountView memory a = lens.getAccount(alice, MARKET_ID);
        assertEq(a.markets[0].suppliedShares, UNITS - seized, "supplied fell");
        assertEq(a.markets[0].credited, UNITS, "credit not yet reconciled");
        assertEq(a.markets[0].shortfall, seized, "shortfall = credited - supplied");
    }

    // TEST-247 verifies: REQ-LENS-009, SPEC-CF-005, Q-253
    function test_TEST_247_getAccountRescueUnits() public {
        riskModule.setRescue(true);
        _open(alice, aliceProxy, 2, 500e6);
        AccountView memory a = lens.getAccount(alice, MARKET_ID);
        assertEq(a.markets[0].rescueUnits, 500e6, "rescue top-up units");
        assertEq(a.markets[0].credited, UNITS + 500e6, "both records credited");
        assertEq(a.markets[0].recordCount, 2, "two records");
    }

    // TEST-228 verifies: REQ-LENS-009, REQ-LENS-037, Q-241
    function test_TEST_228_getAccountBreakersOrMarketAndIndebtedReserves() public {
        _borrow(aliceProxy, 1000e18);
        rm.setMarketBreaker(MARKET_ID, 4, uint64(block.timestamp + 1800));
        rm.setDebtBreaker(aave.cdpSpoke, debtReserveId, 32, type(uint64).max);
        rm.setDebtBreaker(aave.cdpSpoke, usdcReserveId, 8, type(uint64).max);
        AccountView memory a = lens.getAccount(alice, MARKET_ID);
        assertEq(a.breakerReasons, 4 | 32, "market and the GHO reserve with debt; USDC has no debt");
        assertEq(a.markets[0].breakerReasons, 4, "market reasons");
        assertEq(a.debts[0].breakerReasons, 32, "GHO reasons");
        assertEq(a.debts[1].breakerReasons, 8, "USDC reasons reported per reserve");
        _borrowUsdc(aliceProxy, 10e6);
        assertEq(lens.getAccount(alice, MARKET_ID).breakerReasons, 4 | 32 | 8, "USDC now indebted");
    }

    // TEST-229 verifies: REQ-LENS-009, REQ-LENS-037, Q-242
    function test_TEST_229_getAccountWalletFrozen() public {
        assertFalse(lens.getAccount(alice, MARKET_ID).walletFrozen, "not frozen");
        reg.setFrozen(alice, true);
        AccountView memory a = lens.getAccount(alice, MARKET_ID);
        assertTrue(a.walletFrozen, "frozen");
        assertEq(a.markets[0].credited, UNITS, "the account still reports");
    }

    // TEST-247 verifies: REQ-LENS-009
    function test_TEST_247_getAccountGateStatusPassedThrough() public {
        AccountView memory a = lens.getAccount(alice, MARKET_ID);
        assertTrue(a.gateStatus.borrowAllowed, "borrow allowed");
        assertFalse(a.gateStatus.statusUnavailable, "available");
        rm.setGate(aliceProxy, false, true, a.gateStatus.pauseState);
        a = lens.getAccount(alice, MARKET_ID);
        assertTrue(a.gateStatus.statusUnavailable, "fallback reported");
        assertFalse(a.gateStatus.borrowAllowed, "nothing allowed");
        assertEq(a.gateStatus.staleDebtReserveId, type(uint256).max, "no-reserve sentinel");
    }

    // TEST-247 verifies: REQ-LENS-009, REQ-LENS-030
    function test_TEST_247_getAccountDebtPriceFreshness() public {
        AccountView memory a = lens.getAccount(alice, MARKET_ID);
        assertTrue(a.debts[0].priceFresh, "GHO fixed price is always fresh");
        assertTrue(a.debts[1].priceFresh, "USDC accepted now");
        vm.warp(block.timestamp + 4201);
        a = lens.getAccount(alice, MARKET_ID);
        assertTrue(a.debts[0].priceFresh, "GHO still fresh");
        assertFalse(a.debts[1].priceFresh, "USDC older than borrowPriceMaxAge");
    }

    // TEST-247 verifies: REQ-LENS-009
    function test_TEST_247_getAccountDebtReservePausedFlag() public {
        vm.prank(aaveDao);
        _updatePaused(usdcReserveId, true);
        AccountView memory a = lens.getAccount(alice, MARKET_ID);
        assertFalse(a.debts[0].paused, "GHO live");
        assertTrue(a.debts[1].paused, "USDC paused on Aave");
    }

    // TEST-247 verifies: REQ-LENS-009, REQ-LENS-008
    function test_TEST_247_getAccountUndeployedProxy() public {
        rm.setMarketBreaker(MARKET_ID, 1, uint64(block.timestamp + 60));
        AccountView memory a = lens.getAccount(bob, MARKET_ID);
        assertFalse(a.deployed, "not deployed");
        assertEq(a.proxy, proxyManager.predictProxy(bob, aave.cdpSpoke, MARKET_ID), "predicted address");
        assertEq(a.markets.length, 0, "no positions");
        assertEq(a.debts.length, 2, "every enabled reserve");
        assertEq(a.debts[0].total + a.debts[1].total + a.debts[0].drawn + a.debts[1].premium, 0, "zero debt");
        assertEq(a.borrowNonce, 0, "no nonce");
        assertEq(a.healthFactor, 0, "no Aave data read");
        assertTrue(a.gateStatus.statusUnavailable, "no gate status for an undeployed proxy");
        assertEq(a.breakerReasons, 1, "the market's breakers still apply");
    }

    // TEST-247 verifies: REQ-LENS-009, REQ-LENS-007
    function test_TEST_247_getAccountReportsEveryPriceState() public {
        _borrow(aliceProxy, 1000e18);
        for (uint8 s = 0; s < 4; ++s) {
            lpo.setState(PriceState(s), 0, s >= 2);
            AccountView memory a = lens.getAccount(alice, MARKET_ID);
            assertEq(uint8(a.markets[0].priceState), s, "state reported, never a revert");
        }
        _setVtPrice(1);
        AccountView memory e = lens.getAccount(alice, MARKET_ID);
        assertEq(e.healthFactor, _hf(aliceProxy), "the served price drives the health factor");
        assertLt(e.healthFactor, 1e18, "Expired counts the collateral as worthless");
    }

    // TEST-247 verifies: REQ-LENS-022
    function test_TEST_247_getAccountUnknownMarketReverts() public {
        vm.expectRevert(abi.encodeWithSelector(IMarketRegistryErrors.UnknownMarket.selector, 7));
        lens.getAccount(alice, 7);
    }

    // ─── getAccounts ───

    // TEST-247 verifies: REQ-LENS-040
    function test_TEST_247_getAccountsEqualsGetAccountPerMarket() public {
        _borrow(aliceProxy, 2000e18);
        uint256[] memory ids = new uint256[](2);
        (ids[0], ids[1]) = (MARKET_ID, MARKET_ID);
        AccountView[] memory all = lens.getAccounts(alice, ids);
        AccountView memory one = lens.getAccount(alice, MARKET_ID);
        assertEq(all.length, 2, "one view per market");
        for (uint256 i = 0; i < 2; ++i) {
            assertEq(keccak256(abi.encode(all[i])), keccak256(abi.encode(one)), "identical to getAccount");
        }
    }

    // TEST-247 verifies: REQ-LENS-040
    function test_TEST_247_getAccountsEmptyList() public view {
        assertEq(lens.getAccounts(alice, new uint256[](0)).length, 0, "bounded by the caller's array");
    }

    // TEST-247 verifies: REQ-LENS-040, REQ-LENS-022
    function test_TEST_247_getAccountsUnknownMarketReverts() public {
        uint256[] memory ids = new uint256[](2);
        (ids[0], ids[1]) = (MARKET_ID, 5);
        vm.expectRevert(abi.encodeWithSelector(IMarketRegistryErrors.UnknownMarket.selector, 5));
        lens.getAccounts(alice, ids);
    }

    // ─── getRecords ───

    // TEST-247 verifies: REQ-LENS-011, REQ-LENS-005
    function test_TEST_247_getRecordsSeizureListOrder() public {
        _open(alice, aliceProxy, 2, 30_000e6);
        _open(alice, aliceProxy, 3, 5000e6);
        RecordView[] memory r = lens.getRecords(aliceProxy, 0, 16);
        assertEq(r.length, 3, "three records");
        assertEq(r[0].credited, 30_000e6, "largest first");
        assertEq(r[1].credited, UNITS, "then 10,000");
        assertEq(r[2].credited, 5000e6, "then 5,000");
        assertEq(r[0].positionKey, _key(2), "key");
        assertEq(r[0].integrationId, INTEGRATION, "integration");
        assertEq(r[0].depositor, alice, "depositor");
        assertEq(r[0].recordId, coll.recordIdOf(INTEGRATION, _key(2)), "record ID");
        assertEq(r[0].liveUnits, 30_000e6, "live units");
        assertEq(r[0].creditedAfterReconcile, 30_000e6, "nothing to reconcile");
        assertEq(r[0].blockNumber, block.number, "block");
        assertEq(r[0].timestamp, block.timestamp, "timestamp");
    }

    // TEST-247 verifies: REQ-LENS-011, REQ-LENS-023, REQ-LENS-024
    function test_TEST_247_getRecordsPaging() public {
        _open(alice, aliceProxy, 2, 30_000e6);
        _open(alice, aliceProxy, 3, 5000e6);
        RecordView[] memory p = lens.getRecords(aliceProxy, 1, 1);
        assertEq(p.length, 1, "one record");
        assertEq(p[0].credited, UNITS, "position 1");
        p = lens.getRecords(aliceProxy, 2, 200);
        assertEq(p.length, 1, "tail page");
        assertEq(p[0].credited, 5000e6, "position 2");
        assertEq(lens.getRecords(aliceProxy, 3, 200).length, 0, "offset at the end");
        assertEq(lens.getRecords(aliceProxy, type(uint256).max, 200).length, 0, "offset at max");
        assertEq(lens.getRecords(aliceProxy, 0, 0).length, 0, "limit 0");
    }

    // TEST-247 verifies: REQ-LENS-023, REQ-LENS-020
    function test_TEST_247_getRecordsLimitTooHigh() public {
        vm.expectRevert(abi.encodeWithSelector(ILensErrors.LimitTooHigh.selector, 201));
        lens.getRecords(aliceProxy, 0, 201);
        vm.expectRevert(abi.encodeWithSelector(ILensErrors.LimitTooHigh.selector, type(uint256).max));
        lens.getRecords(aliceProxy, type(uint256).max, type(uint256).max);
    }

    // TEST-247 verifies: REQ-LENS-011
    function test_TEST_247_getRecordsUnknownProxyReverts() public {
        vm.expectRevert(abi.encodeWithSelector(ILensErrors.UnknownProxy.selector, bobProxy));
        lens.getRecords(bobProxy, 0, 16);
    }

    // TEST-247 verifies: REQ-LENS-011, SPEC-BACK-011
    function test_TEST_247_getRecordsCreditedAfterReconcileMatchesCollateralization() public {
        _open(alice, aliceProxy, 2, 3000e6);
        _open(alice, aliceProxy, 3, 2000e6);
        _borrow(aliceProxy, 11_000e18);
        _setVtPrice(0.9e8);
        uint256 seized = _seizeAndKeep(aliceProxy, 4000e18);
        RecordView[] memory r = lens.getRecords(aliceProxy, 0, 16);
        uint256 debited = 0;
        for (uint256 i = 0; i < r.length; ++i) {
            assertEq(
                r[i].creditedAfterReconcile, coll.previewRelease(INTEGRATION, r[i].positionKey), "= previewRelease"
            );
            debited += r[i].credited - r[i].creditedAfterReconcile;
        }
        assertEq(debited, seized, "the shortfall is debited exactly once");
        assertEq(r[0].creditedAfterReconcile, UNITS - seized, "debited from the head of the list");
        assertEq(r[1].creditedAfterReconcile, 3000e6, "the rest untouched");
    }

    // TEST-247 verifies: REQ-LENS-011, SPEC-BACK-011
    function test_TEST_247_getRecordsShortfallSpansSeveralRecords() public {
        _open(alice, aliceProxy, 2, 3000e6);
        _open(alice, aliceProxy, 3, 2000e6);
        _borrow(aliceProxy, 11_000e18);
        _setVtPrice(0.75e8);
        uint256 seized = _seizeAndKeep(aliceProxy, 8000e18);
        assertGt(seized, UNITS, "the seizure exceeds the head record");
        RecordView[] memory r = lens.getRecords(aliceProxy, 0, 16);
        assertEq(r[0].creditedAfterReconcile, 0, "head fully debited");
        assertEq(r[1].creditedAfterReconcile, 3000e6 - (seized - UNITS), "next record takes the rest");
        for (uint256 i = 0; i < r.length; ++i) {
            assertEq(r[i].creditedAfterReconcile, coll.previewRelease(INTEGRATION, r[i].positionKey), "matches");
        }
        RecordView[] memory tail = lens.getRecords(aliceProxy, 1, 1);
        assertEq(tail[0].creditedAfterReconcile, r[1].creditedAfterReconcile, "a later page walks from the head");
    }

    // TEST-247 verifies: REQ-LENS-011
    function test_TEST_247_getRecordsSkipsReconciliationWhileSharesDifferFromAssets() public {
        _borrow(aliceProxy, 15_000e18);
        _setVtPrice(1.8e8);
        _seizeAndKeep(aliceProxy, 3000e18);
        // A donation to the Hub's vault-token asset makes its added assets exceed its added shares.
        vm.mockCall(aave.hub, abi.encodeWithSignature("getAddedAssets(uint256)", vtAssetId), abi.encode(1));
        RecordView[] memory r = lens.getRecords(aliceProxy, 0, 16);
        assertEq(r[0].creditedAfterReconcile, r[0].credited, "no reconciliation: credited unchanged");
        vm.clearMockedCalls();
    }

    // TEST-247 verifies: REQ-LENS-011
    function test_TEST_247_getRecordsReportsLiveUnitsWithDonation() public {
        vault.addUnits(_key(1), 750e6);
        RecordView[] memory r = lens.getRecords(aliceProxy, 0, 16);
        assertEq(r[0].liveUnits, UNITS + 750e6, "donated liquidity stays with the position");
        assertEq(r[0].credited, UNITS, "and is never credited");
    }

    // TEST-247 verifies: REQ-LENS-011, REQ-LENS-020
    function test_TEST_247_getRecordsSixteenRecordsInOnePage() public {
        for (uint256 i = 2; i <= 16; ++i) {
            _open(alice, aliceProxy, i, uint128(100e6 * i));
        }
        RecordView[] memory r = lens.getRecords(aliceProxy, 0, 16);
        assertEq(r.length, 16, "an account-market holds at most 16 records");
        for (uint256 i = 1; i < r.length; ++i) {
            assertLe(r[i].credited, r[i - 1].credited, "non-increasing");
        }
    }

    // ─── getEscrowClaimable ───

    // TEST-247 verifies: REQ-LENS-027, Q-401
    function test_TEST_247_getEscrowClaimablePerToken() public {
        _escrow(address(usdc), alice, 1_627_460);
        address[] memory tokens = new address[](2);
        (tokens[0], tokens[1]) = (address(usdc), address(debt));
        uint256[] memory a = lens.getEscrowClaimable(alice, tokens);
        assertEq(a.length, 2, "one per token");
        assertEq(a[0], 1_627_460, "USDC surplus held");
        assertEq(a[1], 0, "no GHO");
        assertEq(lens.getEscrowClaimable(bob, tokens)[0], 0, "another account");
    }

    // TEST-247 verifies: REQ-LENS-027
    function test_TEST_247_getEscrowClaimableAccumulatesAndOrders() public {
        for (uint256 i = 0; i < 40; ++i) {
            _escrow(address(usdc), keeper, 8e6);
        }
        _escrow(address(debt), keeper, 3e18);
        address[] memory tokens = new address[](3);
        (tokens[0], tokens[1], tokens[2]) = (address(debt), address(usdt), address(usdc));
        uint256[] memory a = lens.getEscrowClaimable(keeper, tokens);
        assertEq(a[0], 3e18, "order of the caller's tokens");
        assertEq(a[1], 0, "USDT none");
        assertEq(a[2], 320e6, "40 fees of 8 USDC");
        assertEq(lens.getEscrowClaimable(keeper, new address[](0)).length, 0, "empty request");
    }

    // ─── helpers ───

    function _escrow(
        address token,
        address account,
        uint256 amount
    ) internal {
        CollPoolToken(token).mint(lpVaultSwap, amount);
        vm.prank(lpVaultSwap);
        lock.acquire();
        vm.startPrank(lpVaultSwap);
        CollPoolToken(token).approve(address(escrow), amount);
        escrow.deposit(token, account, amount);
        lock.release();
        vm.stopPrank();
    }

    function _userDebt(
        address proxy,
        uint256 id
    ) internal view returns (uint256 drawn, uint256 premium) {
        (bool ok, bytes memory data) =
            aave.cdpSpoke.staticcall(abi.encodeWithSignature("getUserDebt(uint256,address)", id, proxy));
        require(ok, "getUserDebt");
        (drawn, premium) = abi.decode(data, (uint256, uint256));
    }

    function _updatePaused(
        uint256 reserveId,
        bool paused
    ) internal {
        (bool ok,) = aave.spokeConfigurator
            .call(abi.encodeWithSignature("updatePaused(address,uint256,bool)", aave.cdpSpoke, reserveId, paused));
        require(ok, "updatePaused");
    }
}
