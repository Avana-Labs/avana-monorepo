// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAmmIntegration} from "../../amm/IAmmIntegration.sol";
import {ICollateralizationViews} from "../../custody/collateralization/ICollateralizationViews.sol";
import {BackingRecord} from "../../custody/collateralization/types/BackingRecord.sol";
import {IAaveV4Hub} from "../../interfaces/external/aave/IAaveV4Hub.sol";
import {IAaveV4Spoke} from "../../interfaces/external/aave/IAaveV4Spoke.sol";
import {IPayoutEscrow} from "../../liquidation/payout-escrow/IPayoutEscrow.sol";
import {ILPOracle} from "../../oracle/lp-oracle/ILPOracle.sol";
import {IAaveAdapter} from "../../policy/aave-adapter/IAaveAdapter.sol";
import {DebtReserveDef} from "../../policy/market-registry/types/MarketRegistryTypes.sol";
import {IRiskModule} from "../../policy/risk-module/IRiskModule.sol";
import {AmmConstants} from "../../types/AmmConstants.sol";
import {Market} from "../../types/Market.sol";
import {ILensAccount} from "./ILensAccount.sol";
import {ILensHubReads} from "./ILensHubReads.sol";
import {ILensSpokeReads} from "./ILensSpokeReads.sol";
import {LensBase} from "./LensBase.sol";
import {AccountView} from "./types/AccountView.sol";
import {DebtPosition} from "./types/DebtPosition.sol";
import {MarketPosition} from "./types/MarketPosition.sol";
import {RecordView} from "./types/RecordView.sol";

/// @title LensAccount
/// @notice Account views of the Lens: proxy address, account state, records and escrowed payouts.
// Loops are bounded by governance listings, one page of at most LENS_MAX_PAGE records, or the caller's arrays.
// forge-lint: disable-start(calls-loop)
abstract contract LensAccount is LensBase, ILensAccount {
    /// @inheritdoc ILensAccount
    function predictProxy(
        address wallet,
        uint256 marketId
    ) external view override returns (address proxy, bool deployed) {
        _unlocked();
        (proxy, deployed) = _proxy(wallet, marketId, _market(marketId).spoke);
    }

    /// @inheritdoc ILensAccount
    function getAccount(
        address wallet,
        uint256 marketId
    ) external view override returns (AccountView memory account) {
        _unlocked();
        account = _account(wallet, marketId);
    }

    /// @inheritdoc ILensAccount
    function getAccounts(
        address wallet,
        uint256[] calldata marketIds
    ) external view override returns (AccountView[] memory accounts) {
        _unlocked();
        accounts = new AccountView[](marketIds.length);
        for (uint256 i = 0; i < marketIds.length; ++i) {
            accounts[i] = _account(wallet, marketIds[i]);
        }
    }

    /// @inheritdoc ILensAccount
    function getRecords(
        address proxy,
        uint256 offset,
        uint256 limit
    ) external view override returns (RecordView[] memory records) {
        _unlocked();
        if (_emptyPage(limit)) return records;
        // forge-lint: disable-next-line(unused-return)
        (address spoke,, address vaultToken, uint256 reserveId) = IAaveAdapter(_ADAPTER).accountOf(proxy);
        if (spoke == address(0)) revert UnknownProxy(proxy);
        (uint256[] memory ids, BackingRecord[] memory all) = ICollateralizationViews(_COLLATERALIZATION)
            .getAccountRecords(proxy, vaultToken, 0, AmmConstants.MAX_RECORDS_PER_ACCOUNT_MARKET);
        uint256[] memory after_ = _creditedAfterReconcile(proxy, vaultToken, spoke, reserveId, all);
        if (offset >= after_.length) return records;
        uint256 n = after_.length - offset;
        records = new RecordView[](n < limit ? n : limit);
        for (uint256 i = 0; i < records.length; ++i) {
            records[i] = _recordView(ids[offset + i], all[offset + i], after_[offset + i]);
        }
    }

    /// @inheritdoc ILensAccount
    function getEscrowClaimable(
        address account,
        address[] calldata tokens
    ) external view override returns (uint256[] memory amounts) {
        _unlocked();
        amounts = new uint256[](tokens.length);
        for (uint256 i = 0; i < tokens.length; ++i) {
            amounts[i] = IPayoutEscrow(_PAYOUT_ESCROW).claimable(tokens[i], account);
        }
    }

    function _account(
        address wallet,
        uint256 marketId
    ) internal view returns (AccountView memory a) {
        Market memory m = _market(marketId);
        (a.blockNumber, a.timestamp, a.wallet, a.spoke, a.marketId) =
        (block.number, block.timestamp, wallet, m.spoke, marketId);
        (a.proxy, a.deployed) = _proxy(wallet, marketId, m.spoke);
        a.walletFrozen = _registry().isFrozenAddress(wallet);
        a.gateStatus = IRiskModule(_RISK_MODULE).getAccountGateStatus(a.proxy);
        // forge-lint: disable-next-line(unused-return)
        (uint32 reasons,) = IRiskModule(_RISK_MODULE).getBreakerStatus(marketId);
        if (a.deployed) {
            a.borrowNonce = IAaveAdapter(_ADAPTER).borrowNonce(a.proxy);
            IAaveV4Spoke.UserAccountData memory d = IAaveV4Spoke(m.spoke).getUserAccountData(a.proxy);
            (a.healthFactor, a.totalCollateralValue, a.totalDebtValueRay) =
            (d.healthFactor, d.totalCollateralValue, d.totalDebtValueRay);
            (a.avgCollateralFactor, a.riskPremium, a.activeCollateralCount, a.borrowCount) =
            (d.avgCollateralFactor, d.riskPremium, d.activeCollateralCount, d.borrowCount);
            a.markets = new MarketPosition[](1);
            a.markets[0] = _marketPosition(a.proxy, m, reasons);
        }
        uint256[] memory ids = _registry().getDebtReserveIds(m.spoke);
        a.debts = new DebtPosition[](ids.length);
        for (uint256 i = 0; i < ids.length; ++i) {
            a.debts[i] = _debtPosition(m.spoke, ids[i], a.proxy, a.deployed);
            if (a.debts[i].total > 0) reasons |= a.debts[i].breakerReasons;
        }
        a.breakerReasons = reasons;
    }

    /// @dev One debt reserve of the account; amounts stay 0 for an undeployed proxy.
    function _debtPosition(
        address spoke,
        uint256 reserveId,
        address proxy,
        bool deployed
    ) internal view returns (DebtPosition memory p) {
        DebtReserveDef memory def = _registry().getDebtReserve(spoke, reserveId);
        (p.reserveId, p.asset) = (reserveId, def.asset);
        if (deployed) {
            (p.drawn, p.premium) = ILensSpokeReads(spoke).getUserDebt(reserveId, proxy);
            p.total = IAaveV4Spoke(spoke).getUserTotalDebt(reserveId, proxy);
        }
        p.paused = IAaveV4Spoke(spoke).getReserveConfig(reserveId).paused;
        p.priceFresh = _debtView(spoke, def).borrowFresh;
        // forge-lint: disable-next-line(unused-return)
        (p.breakerReasons,) = IRiskModule(_RISK_MODULE).getDebtBreakerStatus(spoke, reserveId);
    }

    function _marketPosition(
        address proxy,
        Market memory m,
        uint32 reasons
    ) internal view returns (MarketPosition memory p) {
        ICollateralizationViews coll = ICollateralizationViews(_COLLATERALIZATION);
        (p.vaultToken, p.reserveId, p.breakerReasons) = (m.vaultToken, m.reserveId, reasons);
        p.suppliedShares = IAaveV4Spoke(m.spoke).getUserSuppliedShares(m.reserveId, proxy);
        p.suppliedAssets = ILensHubReads(m.hub).previewRemoveByShares(m.hubAssetId, p.suppliedShares);
        // forge-lint: disable-next-line(unused-return)
        (p.collateralEnabled,) = IAaveV4Spoke(m.spoke).getUserReserveStatus(m.reserveId, proxy);
        p.credited = coll.getAccountCredited(proxy, m.vaultToken);
        p.recordCount = coll.getOpenRecordCount(proxy, m.vaultToken);
        p.shortfall = p.credited > p.suppliedShares ? p.credited - p.suppliedShares : 0;
        // forge-lint: disable-next-line(unused-return)
        (,, p.priceState) = ILPOracle(m.lpOracle).getTokenPrices();
        p.rescueUnits = coll.getAccountRescueUnits(proxy, m.vaultToken);
    }

    /// @dev Credited units after the shortfall is debited from the head of the seizure list.
    function _creditedAfterReconcile(
        address proxy,
        address vaultToken,
        address spoke,
        uint256 reserveId,
        BackingRecord[] memory all
    ) internal view returns (uint256[] memory out) {
        uint256 listed = 0;
        while (listed < all.length && all[listed].inList) ++listed;
        out = new uint256[](listed);
        uint256 credited = ICollateralizationViews(_COLLATERALIZATION).getAccountCredited(proxy, vaultToken);
        uint256 supplied = IAaveV4Spoke(spoke).getUserSuppliedShares(reserveId, proxy);
        uint256 rem = credited > supplied && _sharesEqualAssetsOf(spoke, reserveId) ? credited - supplied : 0;
        for (uint256 i = 0; i < listed; ++i) {
            uint256 cr = all[i].credited;
            uint256 take = rem < cr ? rem : cr;
            out[i] = cr - take;
            rem -= take;
        }
    }

    function _recordView(
        uint256 recordId,
        BackingRecord memory r,
        uint256 creditedAfter
    ) internal view returns (RecordView memory v) {
        (v.blockNumber, v.timestamp, v.recordId) = (block.number, block.timestamp, recordId);
        (v.integrationId, v.positionKey, v.depositor) = (r.integrationId, r.positionKey, r.depositor);
        (v.credited, v.creditedAfterReconcile) = (r.credited, creditedAfter);
        v.liveUnits = _liveUnits(r.integrationId, r.positionKey);
    }

    function _sharesEqualAssetsOf(
        address spoke,
        uint256 reserveId
    ) internal view returns (bool) {
        IAaveV4Spoke.Reserve memory r = IAaveV4Spoke(spoke).getReserve(reserveId);
        return IAaveV4Hub(r.hub).getAddedShares(r.assetId) == IAaveV4Hub(r.hub).getAddedAssets(r.assetId);
    }

    /// @dev Live units of a position per its AMM integration; 0 when not in custody, where `unitsOf` would revert.
    function _liveUnits(
        uint32 integrationId,
        bytes32 positionKey
    ) internal view returns (uint256 units) {
        address lpVault = ICollateralizationViews(_COLLATERALIZATION).lpVaultOf(integrationId);
        if (IAmmIntegration(lpVault).depositorOf(positionKey) != address(0)) {
            units = IAmmIntegration(lpVault).unitsOf(positionKey);
        }
    }
}
// forge-lint: disable-end(calls-loop)
