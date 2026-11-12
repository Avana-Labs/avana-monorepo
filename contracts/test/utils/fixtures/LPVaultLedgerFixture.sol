// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAmmIntegration} from "../../../src/amm/IAmmIntegration.sol";
import {ICollateralization} from "../../../src/custody/collateralization/ICollateralization.sol";
import {BackingRecord} from "../../../src/custody/collateralization/types/BackingRecord.sol";
import {IAaveV4Hub} from "../../../src/interfaces/external/aave/IAaveV4Hub.sol";
import {IAaveV4Spoke} from "../../../src/interfaces/external/aave/IAaveV4Spoke.sol";
import {Lock} from "../../../src/lock/lock/Lock.sol";
import {PledgeCounters} from "../../../src/types/PledgeCounters.sol";
import {PositionShape} from "../../../src/types/PositionShape.sol";
import {VaultTokenFactory} from "../../../src/vault-token/vault-token-factory/VaultTokenFactory.sol";
import {VaultToken} from "../../../src/vault-token/vault-token/VaultToken.sol";
import {CollOracleMock, CollRiskModuleMock} from "../mocks/CollateralizationMocks.sol";
import {AaveV4Fixture} from "./AaveV4Fixture.sol";
import {
    CollHubSpokeConfig,
    CollInterestRateData,
    CollPriceSource,
    CollSpokeDynamicReserveConfig,
    CollSpokeReserveConfig,
    ICollHubConfigurator,
    ICollSpokeConfigurator
} from "./CollateralizationFixture.sol";

/// @title LPVaultLedgerFixture
/// @notice The ledger behind an LPVault unit suite: the real Collateralization placed at the suite's named
/// Collateralization address (so the LPVault's immutable binding holds), the real VaultTokenFactory and the vault token
/// of one bound market, listed on the real local Aave V4. The RiskModule and LPOracle are the Collateralization suite's
/// stand-ins. A position pledged through it has a backing record, cap counters, a credited total and minted vault
/// tokens, which `_ledgerState` reads so a donation test can show that none of them moves.
/// @dev Suites set `isolate = false`. The Collateralization views revert while the Lock is held by another caller, so
/// `_ledgerState` is read with the Lock free.
abstract contract LPVaultLedgerFixture is AaveV4Fixture {
    /// @notice The chain addresses the LPVault under test was deployed with.
    struct LedgerCore {
        address adapter;
        address lpVaultSwap;
        address collateralization;
        address lock;
        address timelock;
        address marketRegistry;
    }

    /// @notice Everything a donation could move: the record, the cap counters the RiskModule is given, the market's
    /// credited total, the record count, and the vault token's supply and balances.
    struct LedgerState {
        uint256 recordId;
        uint128 credited;
        uint128 originalUnits;
        uint128 rescueUnits;
        uint64 usdCharge;
        uint256 accountCredited;
        uint256 totalCredited;
        uint256 nextRecordId;
        uint128 regularUsed;
        uint128 sliceUsed;
        uint256 depositorUsed;
        uint256 poolUnits;
        uint256 token0Used;
        uint256 token1Used;
        uint256 supply;
        uint256 proxyBalance;
        uint256 hubBalance;
        uint256 lpVaultBalance;
        uint256 donorBalance;
    }

    address internal aliceProxy = makeAddr("aliceProxy");
    address internal bobProxy = makeAddr("bobProxy");

    LedgerCore internal ledgerCore;
    ICollateralization internal ledger;
    VaultTokenFactory internal ledgerFactory;
    CollRiskModuleMock internal ledgerRisk;
    CollOracleMock internal ledgerOracle;
    VaultToken internal ledgerToken;
    uint32 internal ledgerIntegration;
    address internal ledgerLpVault;
    uint256 internal ledgerReserve;

    /// @notice Deploys the ledger for market `marketId` of `lpVault` (integration `integrationId`, vault-token decimals
    /// `d`), with the real Collateralization at `core.collateralization`.
    function _deployLedger(
        LedgerCore memory core,
        uint32 integrationId,
        address lpVault,
        uint256 marketId,
        uint8 d
    ) internal {
        _deployAaveV4();
        ledgerCore = core;
        ledgerIntegration = integrationId;
        ledgerLpVault = lpVault;
        ledgerRisk = new CollRiskModuleMock();
        ledgerOracle = new CollOracleMock();
        ledgerFactory = new VaultTokenFactory(
            core.adapter, core.lpVaultSwap, core.collateralization, core.timelock, core.marketRegistry
        );
        deployCodeTo(
            "Collateralization.sol:Collateralization",
            abi.encode(core.adapter, core.lpVaultSwap, address(ledgerRisk), core.lock, address(ledgerFactory)),
            core.collateralization
        );
        ledger = ICollateralization(core.collateralization);
        vm.prank(core.timelock);
        ledgerFactory.registerIntegration(integrationId, lpVault);
        (address pool, bytes32 poolId, PositionShape memory shape,) = IAmmIntegration(lpVault).marketOf(marketId);
        vm.prank(core.timelock);
        address vt = ledgerFactory.deployVaultToken(
            integrationId,
            pool,
            poolId,
            shape,
            aave.hub,
            aave.cdpSpoke,
            marketId,
            address(ledgerOracle),
            d,
            "Avana ledger market",
            "avLEDGER"
        );
        ledgerToken = VaultToken(vt);
        _listLedgerToken(d);
    }

    function _listLedgerToken(
        uint8 d
    ) private {
        IAaveV4Hub hubView = IAaveV4Hub(aave.hub);
        bytes memory irData = abi.encode(CollInterestRateData(9000, 0, 400, 6000));
        CollPriceSource price = new CollPriceSource(2e8);
        vm.startPrank(aaveDao);
        uint256 assetId = ICollHubConfigurator(aave.hubConfigurator)
            .addAssetWithDecimals(aave.hub, address(ledgerToken), d, aave.treasurySpoke, 0, aave.irStrategy, irData);
        ICollHubConfigurator(aave.hubConfigurator)
            .addSpoke(
                aave.hub,
                aave.cdpSpoke,
                assetId,
                CollHubSpokeConfig(5_500_000, 0, hubView.MAX_RISK_PREMIUM_THRESHOLD(), true, false)
            );
        ledgerReserve = ICollSpokeConfigurator(aave.spokeConfigurator)
            .addReserve(
                aave.cdpSpoke,
                aave.hub,
                assetId,
                address(price),
                CollSpokeReserveConfig(0, false, false, false, false),
                CollSpokeDynamicReserveConfig(8000, 10_500, 0)
            );
        vm.stopPrank();
    }

    /// @notice The AaveAdapter's pledge of `key` (approved to the LPVault by `owner`): Collateralization takes custody
    /// and records the credit, the Adapter mints that many vault tokens to `proxy` and supplies them to the CDP Spoke.
    function _pledgeThroughLedger(
        address owner,
        address proxy,
        bytes32 key
    ) internal returns (uint128 credited) {
        Lock lock_ = Lock(ledgerCore.lock);
        vm.startPrank(ledgerCore.adapter);
        lock_.acquire();
        if (!ledgerToken.isValidProxy(proxy)) ledgerToken.addValidProxy(proxy);
        (, credited) = ledger.pledge(owner, proxy, address(ledgerToken), key, false);
        ledgerToken.mint(proxy, credited);
        vm.stopPrank();
        vm.startPrank(proxy);
        ledgerToken.approve(aave.cdpSpoke, credited);
        IAaveV4Spoke(aave.cdpSpoke).supply(ledgerReserve, credited, proxy);
        IAaveV4Spoke(aave.cdpSpoke).setUsingAsCollateral(ledgerReserve, true, proxy);
        vm.stopPrank();
        vm.prank(ledgerCore.adapter);
        lock_.release();
    }

    /// @notice The ledger state of `key` (pledged by `depositor` for `proxy`), with `donor`'s vault-token balance.
    function _ledgerState(
        bytes32 key,
        address depositor,
        address proxy,
        address donor
    ) internal view returns (LedgerState memory s) {
        address vt = address(ledgerToken);
        s.recordId = ledger.recordIdOf(ledgerIntegration, key);
        BackingRecord memory r = ledger.getRecord(s.recordId);
        PledgeCounters memory c = ledger.getCounters(vt, depositor);
        s.credited = r.credited;
        s.originalUnits = r.originalUnits;
        s.rescueUnits = r.rescueUnits;
        s.usdCharge = r.currentUsdCharge;
        s.accountCredited = ledger.getAccountCredited(proxy, vt);
        s.totalCredited = ledger.getTotalCredited(vt);
        s.nextRecordId = ledger.nextRecordId();
        s.regularUsed = c.regularUsed;
        s.sliceUsed = c.sliceUsed;
        s.depositorUsed = c.depositorUsed;
        s.poolUnits = c.poolUnits;
        s.token0Used = c.tokenUsed[0];
        s.token1Used = c.tokenUsed[1];
        s.supply = ledgerToken.totalSupply();
        s.proxyBalance = ledgerToken.balanceOf(proxy);
        s.hubBalance = ledgerToken.balanceOf(aave.hub);
        s.lpVaultBalance = ledgerToken.balanceOf(ledgerLpVault);
        s.donorBalance = ledgerToken.balanceOf(donor);
    }

    /// @notice Every field of `b` equals `a`: no record, cap counter, credit, supply or balance moved.
    function _assertLedgerUnchanged(
        LedgerState memory a,
        LedgerState memory b
    ) internal pure {
        assertEq(b.recordId, a.recordId, "record id");
        assertEq(b.credited, a.credited, "credited units");
        assertEq(b.originalUnits, a.originalUnits, "original units");
        assertEq(b.rescueUnits, a.rescueUnits, "rescue units");
        assertEq(b.usdCharge, a.usdCharge, "USD charge");
        assertEq(b.accountCredited, a.accountCredited, "account credited");
        assertEq(b.totalCredited, a.totalCredited, "market credited total");
        assertEq(b.nextRecordId, a.nextRecordId, "no new record");
        assertEq(b.regularUsed, a.regularUsed, "regular cap use");
        assertEq(b.sliceUsed, a.sliceUsed, "slice cap use");
        assertEq(b.depositorUsed, a.depositorUsed, "depositor cap use");
        assertEq(b.poolUnits, a.poolUnits, "pool-share cap use");
        assertEq(b.token0Used, a.token0Used, "token0 cap use");
        assertEq(b.token1Used, a.token1Used, "token1 cap use");
        assertEq(b.supply, a.supply, "vault-token supply: no mint");
        assertEq(b.proxyBalance, a.proxyBalance, "proxy vault-token balance");
        assertEq(b.hubBalance, a.hubBalance, "Hub vault-token balance");
        assertEq(b.lpVaultBalance, a.lpVaultBalance, "LPVault vault-token balance");
        assertEq(b.donorBalance, a.donorBalance, "donor vault-token balance");
    }
}
