// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAmmIntegration} from "../../amm/IAmmIntegration.sol";
import {PledgeCounters} from "../../types/PledgeCounters.sol";
import {IVaultTokenFactory} from "../../vault-token/vault-token-factory/IVaultTokenFactory.sol";
import {CollateralizationLedger} from "./CollateralizationLedger.sol";
import {ICollateralizationViews} from "./ICollateralizationViews.sol";
import {BackingRecord} from "./types/BackingRecord.sol";
import {Pending} from "./types/Pending.sol";

/// @title CollateralizationViews
/// @notice Read-only views of the backing ledger and the constructor immutables.
/// @dev Every ledger view reverts with `Locked` while the Lock is held by another address than the caller
/// (REQ-VAULT-091); `getAccountRescueUnits` and `poolUnits` answer while the Lock is free or held by the AaveAdapter,
/// the RiskModule's reads inside the Adapter's borrow and withdrawal checks (REQ-COLL-018). The immutable getters and
/// `lpVaultOf` never revert.
/// @custom:spec REQ-VAULT-091, REQ-VAULT-128, REQ-VAULT-145, REQ-COLL-002, REQ-COLL-018, REQ-COLL-040, REQ-LOCK-016
abstract contract CollateralizationViews is CollateralizationLedger, ICollateralizationViews {
    /// @inheritdoc ICollateralizationViews
    function getRecord(
        uint256 recordId
    ) external view override returns (BackingRecord memory record) {
        _checkView();
        record = records[recordId];
    }

    /// @inheritdoc ICollateralizationViews
    function recordIdOf(
        uint32 integrationId,
        bytes32 positionKey
    ) external view override returns (uint256 recordId) {
        _checkView();
        recordId = _recordIdOf[integrationId][positionKey];
    }

    /// @inheritdoc ICollateralizationViews
    function nextRecordId() external view override returns (uint256 nextId) {
        _checkView();
        nextId = _nextRecordId;
    }

    /// @inheritdoc ICollateralizationViews
    /// @dev The seizure list in list order, followed by the records at 0 credited units.
    function getAccountRecords(
        address proxy,
        address vaultToken,
        uint256 offset,
        uint256 limit
    ) external view override returns (uint256[] memory recordIds, BackingRecord[] memory page) {
        _checkView();
        (recordIds, page) = _page(seizureList[proxy][vaultToken], zeroCreditList[proxy][vaultToken], offset, limit);
    }

    /// @inheritdoc ICollateralizationViews
    function getOpenRecordCount(
        address proxy,
        address vaultToken
    ) external view override returns (uint256 count) {
        _checkView();
        count = seizureList[proxy][vaultToken].length + zeroCreditList[proxy][vaultToken].length;
    }

    /// @inheritdoc ICollateralizationViews
    function getAccountCredited(
        address proxy,
        address vaultToken
    ) external view override returns (uint256 credited) {
        _checkView();
        credited = accountCredited[proxy][vaultToken];
    }

    /// @inheritdoc ICollateralizationViews
    function getTotalCredited(
        address vaultToken
    ) external view override returns (uint256 credited) {
        _checkView();
        credited = totalCredited[vaultToken];
    }

    /// @inheritdoc ICollateralizationViews
    function poolUnits(
        bytes32 poolKey
    ) external view override returns (uint256 units) {
        _checkAdapterView();
        units = _poolUnits[poolKey];
    }

    /// @inheritdoc ICollateralizationViews
    function getPending(
        address vaultToken
    ) external view override returns (Pending memory balance) {
        _checkView();
        balance = pending[vaultToken];
    }

    /// @inheritdoc ICollateralizationViews
    function getMarketRecords(
        address vaultToken,
        uint256 offset,
        uint256 limit
    ) external view override returns (uint256[] memory recordIds, BackingRecord[] memory page) {
        _checkView();
        // No record is ever written for address(0), so its list is the empty second half.
        (recordIds, page) = _page(marketRecords[vaultToken], marketRecords[address(0)], offset, limit);
    }

    /// @inheritdoc ICollateralizationViews
    function getMarketRecordCount(
        address vaultToken
    ) external view override returns (uint256 count) {
        _checkView();
        count = marketRecords[vaultToken].length;
    }

    /// @inheritdoc ICollateralizationViews
    function getMarketDebtFree(
        address vaultToken
    ) external view override returns (bool debtFree) {
        _checkView();
        debtFree = indebtedCount[vaultToken] == 0;
    }

    /// @inheritdoc ICollateralizationViews
    function getCounters(
        address vaultToken,
        address depositor
    ) external view override returns (PledgeCounters memory counters) {
        _checkView();
        counters = _counters(_load(vaultToken), depositor);
    }

    /// @inheritdoc ICollateralizationViews
    function previewRelease(
        uint32 integrationId,
        bytes32 positionKey
    ) external view override returns (uint256 units) {
        _checkView();
        (uint256 id, BackingRecord storage r, Ctx memory c) = _previewRecord(integrationId, positionKey);
        units = _creditedAfterReconcile(c, id, r);
    }

    /// @inheritdoc ICollateralizationViews
    function previewRecredit(
        uint32 integrationId,
        bytes32 positionKey
    ) external view override returns (uint128 added) {
        _checkView();
        (uint256 id, BackingRecord storage r, Ctx memory c) = _previewRecord(integrationId, positionKey);
        uint256 credited = _creditedAfterReconcile(c, id, r);
        if (credited == 0) return 0;
        // A reconciliation removes from the position exactly the units it debits, so the uncredited live units are
        // `live - credited` before and after it.
        uint256 live = IAmmIntegration(c.lpVault).unitsOf(positionKey);
        uint256 before = r.credited;
        // Live units cover credit (SPEC-BACK-010) and are below 2^128.
        // forge-lint: disable-next-line(unsafe-typecast)
        added = live > before ? uint128(live - before) : 0;
    }

    /// @inheritdoc ICollateralizationViews
    function getAccountRescueUnits(
        address proxy,
        address vaultToken
    ) external view override returns (uint256 rescueUnits) {
        _checkAdapterView();
        rescueUnits = accountRescueUnits[proxy][vaultToken];
    }

    /// @inheritdoc ICollateralizationViews
    function lpVaultOf(
        uint32 integrationId
    ) external view override returns (address lpVault) {
        lpVault = IVaultTokenFactory(_VAULT_TOKEN_FACTORY).lpVaultOf(integrationId);
    }

    /// @inheritdoc ICollateralizationViews
    function ADAPTER() external view override returns (address adapter) {
        adapter = _ADAPTER;
    }

    /// @inheritdoc ICollateralizationViews
    function LP_VAULT_SWAP() external view override returns (address lpVaultSwap) {
        lpVaultSwap = _LP_VAULT_SWAP;
    }

    /// @inheritdoc ICollateralizationViews
    function RISK_MODULE() external view override returns (address riskModule) {
        riskModule = _RISK_MODULE;
    }

    /// @inheritdoc ICollateralizationViews
    function LOCK() external view override returns (address lock) {
        lock = _LOCK;
    }

    /// @inheritdoc ICollateralizationViews
    function VAULT_TOKEN_FACTORY() external view override returns (address vaultTokenFactory) {
        vaultTokenFactory = _VAULT_TOKEN_FACTORY;
    }

    /// @notice The two views the RiskModule reads inside the AaveAdapter's call tree (`getAccountRescueUnits` for the
    /// health check, `poolUnits` for the borrow-side market breaker) answer while the Lock is free or held by the
    /// AaveAdapter, and revert with `Locked` while LPVaultSwap holds it.
    /// @custom:spec REQ-COLL-018, REQ-VAULT-091, REQ-LOCK-016
    function _checkAdapterView() private view {
        address holder = _holder();
        if (holder != address(0) && holder != _ADAPTER) revert Locked();
    }

    /// @notice The open record of a position and its market context, for the previews.
    function _previewRecord(
        uint32 integrationId,
        bytes32 positionKey
    ) private view returns (uint256 id, BackingRecord storage r, Ctx memory c) {
        id = _recordIdOf[integrationId][positionKey];
        if (id == 0) revert RecordNotFound();
        r = records[id];
        c = _load(proxyMarket[r.proxy]);
        _withReserve(c);
    }

    /// @notice One page of the concatenation of two record lists: at most `limit` entries from position `offset`.
    function _page(
        uint256[] storage first,
        uint256[] storage second,
        uint256 offset,
        uint256 limit
    ) private view returns (uint256[] memory recordIds, BackingRecord[] memory page) {
        uint256 head = first.length;
        uint256 total = head + second.length;
        uint256 count = 0;
        if (offset < total) {
            uint256 left = total - offset;
            count = left < limit ? left : limit;
        }
        recordIds = new uint256[](count);
        page = new BackingRecord[](count);
        for (uint256 i = 0; i < count; ++i) {
            uint256 at = offset + i;
            uint256 id = at < head ? first[at] : second[at - head];
            recordIds[i] = id;
            page[i] = records[id];
        }
    }
}
