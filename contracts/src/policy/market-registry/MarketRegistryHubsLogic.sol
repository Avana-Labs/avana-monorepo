// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAmmIntegration} from "../../amm/IAmmIntegration.sol";
import {IAvanaFirstLossReserve} from "../../coverage/first-loss-reserve/IAvanaFirstLossReserve.sol";
import {ILPVault} from "../../custody/lp-vault/ILPVault.sol";
import {IFlashSource} from "../../flash/IFlashSource.sol";
import {IAaveV4ExtSload} from "../../interfaces/external/aave/IAaveV4ExtSload.sol";
import {IAaveV4Hub} from "../../interfaces/external/aave/IAaveV4Hub.sol";
import {IAaveV4Oracle} from "../../interfaces/external/aave/IAaveV4Oracle.sol";
import {IAaveV4Spoke} from "../../interfaces/external/aave/IAaveV4Spoke.sol";
import {IVaultTokenFactory} from "../../vault-token/vault-token-factory/IVaultTokenFactory.sol";
import {IRiskModuleChecks} from "../risk-module/IRiskModuleChecks.sol";
import {IMarketRegistryApprovals} from "./IMarketRegistryApprovals.sol";
import {IMarketRegistryCreditLines} from "./IMarketRegistryCreditLines.sol";
import {IMarketRegistryHubs} from "./IMarketRegistryHubs.sol";
import {IMarketRegistryLogic} from "./IMarketRegistryLogic.sol";
import {MarketRegistryDebtChecks} from "./MarketRegistryDebtChecks.sol";
import {MarketRegistryStorage} from "./MarketRegistryStorage.sol";
import {DebtReserveDef} from "./types/DebtReserveDef.sol";
import {MarketRegistryImmutables} from "./types/MarketRegistryImmutables.sol";
import {RiskTier} from "./types/RiskTier.sol";
import {SpokeDef} from "./types/SpokeDef.sol";

/// @title MarketRegistryHubsLogic
/// @notice Bodies of the MarketRegistry's Hub, integration, cross-Hub line, flash source, Spoke and debt-reserve writes.
/// @dev Runs only by delegatecall from the MarketRegistry, which checks `APPLICATION_ADMIN` first.
// Bodies of IMarketRegistry selectors; this contract inherits no interface piece.
// solhint-disable comprehensive-interface
// Every external call here is a view, so none can re-enter the registry.
// forge-lint: disable-start(reentrancy-events)
contract MarketRegistryHubsLogic is MarketRegistryDebtChecks, IMarketRegistryLogic {
    constructor(
        MarketRegistryImmutables memory im
    ) MarketRegistryStorage(im) {}

    /// @inheritdoc IMarketRegistryLogic
    function logicConfig() external view override returns (bytes32 kind, bytes32 immutablesHash) {
        return (keccak256("MarketRegistryHubsLogic"), _IMMUTABLES_HASH);
    }

    function recordHub(
        address hub,
        RiskTier tier
    ) external {
        _onlyDelegated();
        Layout storage l = _s();
        if (hub == address(0) || tier == RiskTier.None || l.hubTier[hub] != RiskTier.None) {
            revert IMarketRegistryHubs.InvalidHub(hub);
        }
        address fs = l.flashSource;
        if (fs != address(0) && IFlashSource(fs).LENDER() == hub) revert InvalidRoute();
        l.hubTier[hub] = tier;
        l.hubList.push(hub);
        emit IMarketRegistryHubs.HubRecorded(hub, tier);
    }

    function registerIntegration(
        uint32 integrationId,
        address lpVault,
        address pricing
    ) external {
        _onlyDelegated();
        Layout storage l = _s();
        if (
            integrationId == 0 || lpVault == address(0) || pricing == address(0)
                || l.integrationLpVault[integrationId] != address(0) || l.integrationIdOf[lpVault] != 0
        ) revert IMarketRegistryHubs.InvalidIntegration(integrationId);
        if (
            IAmmIntegration(lpVault).INTEGRATION_ID() != integrationId
                || IVaultTokenFactory(_VAULT_TOKEN_FACTORY).lpVaultOf(integrationId) != lpVault
                || ILPVault(lpVault).MARKET_REGISTRY() != address(this)
        ) revert IMarketRegistryHubs.InvalidIntegration(integrationId);
        l.integrationLpVault[integrationId] = lpVault;
        l.integrationPricing[integrationId] = pricing;
        l.integrationIdOf[lpVault] = integrationId;
        l.isPricing[pricing] = true;
        emit IMarketRegistryHubs.IntegrationRegistered(integrationId, lpVault, pricing);
    }

    function setAvanaFirstLossReserve(
        address hub,
        address asset,
        address firstLossReserve
    ) external {
        _onlyDelegated();
        Layout storage l = _s();
        if (l.hubTier[hub] == RiskTier.None) revert IMarketRegistryHubs.InvalidHub(hub);
        if (
            firstLossReserve == address(0) || asset == address(0) || l.firstLossReserveOf[hub][asset] != address(0)
                || IAvanaFirstLossReserve(firstLossReserve).HUB() != hub
                || IAvanaFirstLossReserve(firstLossReserve).ASSET() != asset
                || IAvanaFirstLossReserve(firstLossReserve).ASSET_ID() != IAaveV4Hub(hub).getAssetId(asset)
        ) revert IMarketRegistryHubs.InvalidAvanaFirstLossReserve(firstLossReserve);
        l.firstLossReserveOf[hub][asset] = firstLossReserve;
        l.knownAvanaFirstLossReserve[firstLossReserve] = true;
        emit IMarketRegistryHubs.AvanaFirstLossReserveSet(hub, asset, firstLossReserve);
    }

    function setCrossHubLine(
        address fundingHub,
        address asset,
        address spoke,
        uint256 cap
    ) external {
        _onlyDelegated();
        Layout storage l = _s();
        if (!l.crossHubLinesEnabled && cap > 0) revert IMarketRegistryHubs.CrossHubLinesDisabled();
        if (!l.spokes[spoke].approved) revert InvalidSpoke(spoke);
        if (l.hubTier[fundingHub] == RiskTier.None || l.spokes[spoke].hub == fundingHub) {
            revert IMarketRegistryHubs.InvalidHub(fundingHub);
        }
        uint256 old = l.crossHubLineCap[fundingHub][asset][spoke];
        uint256 total = l.crossHubLineTotal[fundingHub][asset] - old + cap;
        if (cap > old) {
            address cs = l.firstLossReserveOf[fundingHub][asset];
            uint256 coverage = cs == address(0) ? 0 : IAvanaFirstLossReserve(cs).fundedBalance();
            if (total > coverage) revert IMarketRegistryHubs.CrossHubCapExceeded(total, coverage);
        }
        l.crossHubLineCap[fundingHub][asset][spoke] = cap;
        l.crossHubLineTotal[fundingHub][asset] = total;
        emit IMarketRegistryHubs.CrossHubLineSet(fundingHub, asset, spoke, cap, total);
    }

    function setCrossHubLinesEnabled(
        bool enabled
    ) external {
        _onlyDelegated();
        _s().crossHubLinesEnabled = enabled;
        emit IMarketRegistryHubs.CrossHubLinesEnabledSet(enabled);
    }

    function setFlashSource(
        address newSource
    ) external {
        _onlyDelegated();
        if (newSource == address(0) || IFlashSource(newSource).LP_VAULT_SWAP() != _LP_VAULT_SWAP) {
            revert InvalidRoute();
        }
        if (_s().hubTier[IFlashSource(newSource).LENDER()] != RiskTier.None) revert InvalidRoute();
        address previous = _s().flashSource;
        _s().flashSource = newSource;
        emit IMarketRegistryHubs.FlashSourceSet(previous, newSource);
    }

    function approveSpokeCodeHash(
        bytes32 codeHash
    ) external {
        _onlyDelegated();
        if (codeHash == bytes32(0) || codeHash == _EMPTY_CODE_HASH || _spokeHashApproved(codeHash)) {
            revert IMarketRegistryApprovals.InvalidSpokeCodeHash(codeHash);
        }
        _s().approvedSpokeCodeHash[codeHash] = true;
        emit IMarketRegistryApprovals.SpokeCodeHashApproved(codeHash);
    }

    function deployCdpSpoke(
        SpokeDef calldata def
    ) external returns (address spoke) {
        _onlyDelegated();
        Layout storage l = _s();
        spoke = _spokeOfOracle(def.aaveOracle);
        _requireStandardSpoke(spoke, def);
        SpokeDef storage rec = l.spokes[spoke];
        if (rec.approved) {
            if (
                rec.hub != def.hub || rec.integrationId != def.integrationId || rec.riskTier != def.riskTier
                    || rec.aaveOracle != def.aaveOracle
            ) revert InvalidSpoke(spoke);
            rec.implementation = def.implementation;
            l.spokeCodeHash[spoke] = def.implementation.codehash;
        } else {
            if (
                l.hubTier[def.hub] != def.riskTier || def.riskTier == RiskTier.None
                    || l.integrationLpVault[def.integrationId] == address(0)
            ) revert InvalidSpoke(spoke);
            l.spokes[spoke] = SpokeDef({
                approved: true,
                hub: def.hub,
                integrationId: def.integrationId,
                riskTier: def.riskTier,
                implementation: def.implementation,
                aaveOracle: def.aaveOracle
            });
            l.spokeCodeHash[spoke] = def.implementation.codehash;
            l.spokeList.push(spoke);
        }
        // The drift check reads the record just written; a failure reverts the whole call.
        try IRiskModuleChecks(_RISK_MODULE).checkAaveConfig(spoke, new uint256[](0)) {}
        catch {
            revert InvalidSpoke(spoke);
        }
        emit SpokeApproved(spoke, def.hub, def.integrationId, def.implementation, def.aaveOracle);
    }

    function enableDebtReserve(
        address spoke,
        DebtReserveDef calldata def
    ) external {
        _onlyDelegated();
        Layout storage l = _s();
        SpokeDef storage sp = l.spokes[spoke];
        if (!sp.approved) revert InvalidSpoke(spoke);
        if (l.hubTier[def.fundingHub] == RiskTier.None) revert InvalidDebtReserve("fundingHub");
        if (l.debtReserves[spoke][def.reserveId].approved) revert InvalidDebtReserve("enabled");
        _checkFunding(spoke, sp.hub, def);
        _checkAaveReserve(spoke, def);
        _checkPriceSource(spoke, def);
        _checkAvanaFirstLossReserve(def);
        _checkFlashAndFee(def);
        uint256 cap = _drawCapOf(def.fundingHub, def.hubAssetId, spoke);
        // A cross-Hub draw cap (whole units) must fit its line (base units); 2^128 * 10^18 cannot overflow.
        if (def.crossHub) {
            uint256 capBase = cap * 10 ** uint256(def.decimals);
            uint256 lineCap = l.crossHubLineCap[def.fundingHub][def.asset][spoke];
            if (capBase > lineCap) revert IMarketRegistryHubs.CrossHubCapExceeded(capBase, lineCap);
        }
        CreditLine storage cl = l.creditLines[def.fundingHub][def.asset];
        uint256 sum = cl.drawCapSum + cap;
        if (sum > cl.line) {
            revert IMarketRegistryCreditLines.CreditLineExceeded(def.fundingHub, def.asset, sum, cl.line);
        }
        _requireCovered(def.fundingHub, def.asset, cl.line);
        DebtReserveDef storage rec = l.debtReserves[spoke][def.reserveId];
        rec.reserveId = def.reserveId;
        rec.asset = def.asset;
        rec.decimals = def.decimals;
        rec.fundingHub = def.fundingHub;
        rec.hubAssetId = def.hubAssetId;
        rec.priceSource = def.priceSource;
        rec.fixedPrice = def.fixedPrice;
        rec.firstLossReserve = def.firstLossReserve;
        rec.crossHub = def.crossHub;
        rec.approved = true;
        l.debtReserveIds[spoke].push(def.reserveId);
        l.knownAvanaFirstLossReserve[def.firstLossReserve] = true;
        l.knownPriceSource[def.priceSource] = true;
        l.isDebtAsset[def.asset] = true;
        l.recordedDrawCap[spoke][def.reserveId] = cap;
        cl.drawCapSum = sum;
        // Runs after the record is written: the ParameterStore accepts only an enabled reserve.
        _checkMarketsLive(spoke, def.reserveId, def.asset);
        emit DebtReserveApproved(
            spoke, def.reserveId, def.asset, def.fundingHub, def.hubAssetId, def.priceSource, def.firstLossReserve
        );
        emit IMarketRegistryCreditLines.CreditLineRecorded(def.fundingHub, def.asset, spoke, cap, sum);
    }

    function removeDebtReserve(
        address spoke,
        uint256 reserveId
    ) external {
        _onlyDelegated();
        Layout storage l = _s();
        DebtReserveDef storage rec = l.debtReserves[spoke][reserveId];
        if (!rec.approved) revert UnknownDebtReserve(spoke, reserveId);
        uint256[] storage ids = l.marketsOfSpoke[spoke];
        bool settles = false;
        for (uint256 i = 0; i < ids.length && !settles; ++i) {
            settles = l.settlementReserve[ids[i]] == reserveId && !_keyFree(ids[i]);
        }
        IAaveV4Hub hub = IAaveV4Hub(rec.fundingHub);
        if (
            settles || hub.getSpokeTotalOwed(rec.hubAssetId, spoke) != 0
                || hub.getSpokeDeficitRay(rec.hubAssetId, spoke) != 0
        ) revert DebtReserveInUse(spoke, reserveId);
        CreditLine storage cl = l.creditLines[rec.fundingHub][rec.asset];
        cl.drawCapSum -= l.recordedDrawCap[spoke][reserveId];
        delete l.recordedDrawCap[spoke][reserveId];
        bytes32 key = _debtKey(spoke, reserveId);
        delete l.latched[key];
        _clearBreachTimes(l, key);
        delete l.debtReserves[spoke][reserveId];
        _removeId(l.debtReserveIds[spoke], reserveId);
        emit DebtReserveRemoved(spoke, reserveId);
    }

    function _spokeOfOracle(
        address aaveOracle
    ) private view returns (address spoke) {
        if (aaveOracle == address(0)) revert InvalidSpoke(address(0));
        try IAaveV4Oracle(aaveOracle).spoke() returns (address s) {
            spoke = s;
        } catch {
            revert InvalidSpoke(address(0));
        }
        if (spoke == address(0)) revert InvalidSpoke(address(0));
    }

    function _requireStandardSpoke(
        address spoke,
        SpokeDef calldata def
    ) private view {
        address impl = def.implementation;
        if (
            impl == address(0) || IAaveV4Spoke(spoke).ORACLE() != def.aaveOracle
                || IAaveV4Oracle(def.aaveOracle).decimals() != _ORACLE_DECIMALS
                || address(uint160(uint256(IAaveV4ExtSload(spoke).extSload(_IMPLEMENTATION_SLOT)))) != impl
                || !_spokeHashApproved(impl.codehash)
        ) revert InvalidSpoke(spoke);
    }

    function _removeId(
        uint256[] storage ids,
        uint256 id
    ) private {
        uint256 n = ids.length;
        uint256 at = n;
        for (uint256 i = 0; i < n; ++i) {
            if (ids[i] == id) {
                at = i;
                break;
            }
        }
        if (at == n) return;
        for (uint256 i = at; i + 1 < n; ++i) {
            ids[i] = ids[i + 1];
        }
        ids.pop();
    }
}
