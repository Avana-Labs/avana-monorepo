// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAmmIntegration} from "../../amm/IAmmIntegration.sol";
import {ICoverageSpoke} from "../../coverage/coverage-spoke/ICoverageSpoke.sol";
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
/// @notice Bodies of the Hub, AMM-integration registration, Coverage Spoke, cross-Hub line, flash source, CDP Spoke and debt
/// reserve writes of the MarketRegistry. Normal delay.
/// @dev Reached only by delegatecall from the MarketRegistry, which checks `APPLICATION_ADMIN` first; see
/// `IMarketRegistryLogic`. Every external call is a view: these bodies read Aave, the integration, the factory, the
/// Coverage Spokes, the flash source, the RiskModule and the ParameterStore, and write only the registry's storage.
/// @custom:spec REQ-CONFIG-005, REQ-CONFIG-016, REQ-CONFIG-074, REQ-CONFIG-075, REQ-CONFIG-077, REQ-CONFIG-079, REQ-CONFIG-081, REQ-CONFIG-083, REQ-MREG-006, REQ-MREG-007, REQ-MREG-008, REQ-MREG-009, REQ-MREG-010, REQ-MREG-018, REQ-MREG-032, REQ-MREG-033, Q-312, Q-313, Q-378, Q-379, Q-386, Q-388
// Each function carries the body of a selector declared in an IMarketRegistry piece that the MarketRegistry itself
// implements; this contract inherits no piece, since each piece also declares functions another contract serves.
// solhint-disable comprehensive-interface
// Every external call made here is a view (STATICCALL), so none can re-enter the registry or reorder its events.
// forge-lint: disable-start(reentrancy-events)
contract MarketRegistryHubsLogic is MarketRegistryDebtChecks, IMarketRegistryLogic {
    /// @notice Fixes the implementation immutables; they must equal the MarketRegistry's.
    /// @param im The per-chain Avana addresses.
    /// @custom:spec REQ-CONFIG-005
    constructor(
        MarketRegistryImmutables memory im
    ) MarketRegistryStorage(im) {}

    /// @inheritdoc IMarketRegistryLogic
    /// @custom:spec REQ-CONFIG-005
    function logicConfig() external view override returns (bytes32 kind, bytes32 immutablesHash) {
        return (keccak256("MarketRegistryHubsLogic"), _IMMUTABLES_HASH);
    }

    /// @notice Body of `recordHub`.
    /// @custom:spec REQ-CONFIG-083, REQ-CONFIG-005, Q-378, Q-388
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

    /// @notice Body of `registerIntegration`.
    /// @custom:spec REQ-CONFIG-075, Q-376
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

    /// @notice Body of `setCoverageSpoke`.
    /// @custom:spec REQ-MREG-009, Q-379
    function setCoverageSpoke(
        address hub,
        address asset,
        address coverageSpoke
    ) external {
        _onlyDelegated();
        Layout storage l = _s();
        if (l.hubTier[hub] == RiskTier.None) revert IMarketRegistryHubs.InvalidHub(hub);
        if (
            coverageSpoke == address(0) || asset == address(0) || l.coverageSpokeOf[hub][asset] != address(0)
                || ICoverageSpoke(coverageSpoke).HUB() != hub || ICoverageSpoke(coverageSpoke).ASSET() != asset
                || ICoverageSpoke(coverageSpoke).ASSET_ID() != IAaveV4Hub(hub).getAssetId(asset)
        ) revert IMarketRegistryHubs.InvalidCoverageSpoke(coverageSpoke);
        l.coverageSpokeOf[hub][asset] = coverageSpoke;
        l.knownCoverageSpoke[coverageSpoke] = true;
        emit IMarketRegistryHubs.CoverageSpokeSet(hub, asset, coverageSpoke);
    }

    /// @notice Body of `setCrossHubLine`.
    /// @custom:spec Q-378, REQ-FLR-043
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
            address cs = l.coverageSpokeOf[fundingHub][asset];
            uint256 coverage = cs == address(0) ? 0 : ICoverageSpoke(cs).fundedBalance();
            if (total > coverage) revert IMarketRegistryHubs.CrossHubCapExceeded(total, coverage);
        }
        l.crossHubLineCap[fundingHub][asset][spoke] = cap;
        l.crossHubLineTotal[fundingHub][asset] = total;
        emit IMarketRegistryHubs.CrossHubLineSet(fundingHub, asset, spoke, cap, total);
    }

    /// @notice Body of `setCrossHubLinesEnabled`.
    /// @custom:spec REQ-CONFIG-081, Q-378
    function setCrossHubLinesEnabled(
        bool enabled
    ) external {
        _onlyDelegated();
        _s().crossHubLinesEnabled = enabled;
        emit IMarketRegistryHubs.CrossHubLinesEnabledSet(enabled);
    }

    /// @notice Body of `setFlashSource`.
    /// @custom:spec REQ-CONFIG-005, REQ-FLASH-006, INV-095, Q-386, Q-388
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

    /// @notice Body of `approveSpokeCodeHash`.
    /// @custom:spec REQ-CONFIG-074
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

    /// @notice Body of `deployCdpSpoke`: records the standard Aave V4 Spoke that the Aave payload deployed with
    /// `def.aaveOracle`, or re-approves a recorded Spoke after an Aave DAO upgrade of its implementation.
    /// @custom:spec REQ-CONFIG-077, REQ-CONFIG-074, REQ-CONFIG-016, REQ-CONFIG-076, REQ-CONFIG-083, Q-281, Q-312, Q-378
    function deployCdpSpoke(
        SpokeDef calldata def
    ) external returns (address spoke) {
        _onlyDelegated();
        Layout storage l = _s();
        spoke = _spokeOfOracle(def.aaveOracle);
        _requireStandardSpoke(spoke, def);
        SpokeDef storage rec = l.spokes[spoke];
        bytes32 triple = keccak256(abi.encode(def.hub, def.integrationId, def.riskTier));
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
                    || l.integrationLpVault[def.integrationId] == address(0) || l.spokeOfTriple[triple] != address(0)
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
            l.spokeOfTriple[triple] = spoke;
            l.spokeList.push(spoke);
        }
        // The drift check reads the record just written; a failure reverts the whole call.
        try IRiskModuleChecks(_RISK_MODULE).checkAaveConfig(spoke, new uint256[](0)) {}
        catch {
            revert InvalidSpoke(spoke);
        }
        emit SpokeApproved(spoke, def.hub, def.integrationId, def.implementation, def.aaveOracle);
    }

    /// @notice Body of `enableDebtReserve`.
    /// @custom:spec REQ-MREG-006, REQ-MREG-007, REQ-MREG-008, REQ-MREG-009, REQ-MREG-032, REQ-CONFIG-079, REQ-CONFIG-081, INV-095, Q-233, Q-386, Q-388, Q-390
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
        _checkCoverageSpoke(def);
        _checkFlashAndFee(def);
        uint256 cap = _drawCapOf(def.fundingHub, def.hubAssetId, spoke);
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
        rec.coverageSpoke = def.coverageSpoke;
        rec.crossHub = def.crossHub;
        rec.approved = true;
        l.debtReserveIds[spoke].push(def.reserveId);
        l.knownCoverageSpoke[def.coverageSpoke] = true;
        l.knownPriceSource[def.priceSource] = true;
        l.isDebtAsset[def.asset] = true;
        l.recordedDrawCap[spoke][def.reserveId] = cap;
        cl.drawCapSum = sum;
        // The liveness bound is read from the ParameterStore, which accepts only an enabled reserve, so it runs after
        // the record is written; a failure reverts the whole call.
        _checkMarketsLive(spoke, def.reserveId, def.asset);
        emit DebtReserveApproved(
            spoke, def.reserveId, def.asset, def.fundingHub, def.hubAssetId, def.priceSource, def.coverageSpoke
        );
        emit IMarketRegistryCreditLines.CreditLineRecorded(def.fundingHub, def.asset, spoke, cap, sum);
    }

    /// @notice Body of `removeDebtReserve`.
    /// @custom:spec REQ-MREG-010, REQ-MREG-033, Q-233, Q-260, Q-397
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
        delete l.lastBreachAt[key];
        delete l.debtReserves[spoke][reserveId];
        _removeId(l.debtReserveIds[spoke], reserveId);
        emit DebtReserveRemoved(spoke, reserveId);
    }

    /// @dev The Spoke an AaveOracle serves; `InvalidSpoke` when the oracle reports none or cannot be read.
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

    /// @dev REQ-CONFIG-074 and REQ-CONFIG-016: the Spoke's oracle is `def.aaveOracle` with 8 decimals, and the
    /// implementation in its proxy's EIP-1967 slot (read through `extSload` in the proxy's storage) is
    /// `def.implementation`, whose code hash is approved.
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

    /// @dev Removes `id` from `ids`, keeping the order of the others.
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
