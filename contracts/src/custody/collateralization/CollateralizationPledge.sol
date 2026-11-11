// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAmmIntegration} from "../../amm/IAmmIntegration.sol";
import {ILPOracle} from "../../oracle/lp-oracle/ILPOracle.sol";
import {IRiskModuleChecks} from "../../policy/risk-module/IRiskModuleChecks.sol";
import {PledgeCharge} from "../../policy/risk-module/types/PledgeCharge.sol";
import {PledgeCounters} from "../../types/PledgeCounters.sol";
import {IVaultToken} from "../../vault-token/vault-token/IVaultToken.sol";
import {CollateralizationLedger} from "./CollateralizationLedger.sol";
import {ICollateralizationAdapter} from "./ICollateralizationAdapter.sol";
import {BackingRecord} from "./types/BackingRecord.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

// Every external call in this file goes to the market's registered LPVault, the vault token, the VaultTokenFactory, the
// Aave Hub or Spoke, or (in `pledge` and `recredit`) the RiskModule's view check and the market's LPOracle, while a Lock
// member holds the Lock, so no other code can re-enter Collateralization; the order of calls, writes and events is the
// one 2.3 fixes: custody before the credit is read, balance deltas measured around the call that delivers them, and
// events that report a call's amounts after that call (REQ-VAULT-089, REQ-LOCK-017).
// forge-lint: disable-start(reentrancy-events)
// forge-lint: disable-start(reentrancy-no-eth)
// The ledger's writes happen only inside the Adapter's and LPVaultSwap's entry points, each of which emits its 2.3 event
// (`CollateralPledged`, `RecordRecredited`, `RecordReduced`, `RecordDebited`, `CollateralReleased`, `SeizureSettled`,
// `SeizureReconciled`, `PendingSettled`); the internal helpers that write counters are covered by those events.
// forge-lint: disable-start(missing-events-access-control)
/// @title CollateralizationPledge
/// @notice Adapter path, credit side: `pledge` writes a new record for a position the market's LPVault takes into
/// custody, and `recredit` credits the live units added to a pledged position. Both book the RiskModule's charge and
/// return the units the AaveAdapter mints.
/// @dev Collateralization trusts the Adapter for `depositor`, `proxy` and `requireRescue`, and still enforces the
/// custody limits of REQ-COLL-005 whatever it passes: the depositor is neither the market's LPVault nor this contract,
/// the LPVault pulls the position from its owner and matches the exact shape, `credited` is the units read after
/// custody, one record per position, at most 16 per account-market, one market per proxy.
/// @custom:spec REQ-COLL-005, REQ-COLL-015, REQ-COLL-024, REQ-COLL-025, REQ-COLL-026, REQ-COLL-027, REQ-COLL-031, REQ-COLL-037, REQ-VAULT-006, REQ-VAULT-007, REQ-VAULT-012, REQ-VAULT-013, REQ-VAULT-014, REQ-VAULT-015, REQ-VAULT-016, REQ-VAULT-017, REQ-VAULT-018, REQ-VAULT-022, REQ-VAULT-024, REQ-VAULT-025, REQ-VAULT-027, REQ-VAULT-042
abstract contract CollateralizationPledge is CollateralizationLedger, ICollateralizationAdapter {
    /// @inheritdoc ICollateralizationAdapter
    /// @custom:spec REQ-VAULT-006, REQ-VAULT-007, REQ-VAULT-010, REQ-VAULT-012, REQ-VAULT-013, REQ-VAULT-014, REQ-VAULT-015, REQ-VAULT-016, REQ-VAULT-017, REQ-VAULT-018, REQ-VAULT-019, REQ-VAULT-021, REQ-VAULT-022, REQ-VAULT-025, REQ-VAULT-027, REQ-VAULT-042, REQ-VAULT-106, REQ-VAULT-107, REQ-VAULT-109, REQ-VAULT-110, REQ-COLL-003, REQ-COLL-010, REQ-COLL-013, REQ-COLL-016, REQ-COLL-019, REQ-COLL-024, REQ-COLL-025, REQ-COLL-026, REQ-COLL-027, REQ-COLL-031, REQ-COLL-033, REQ-COLL-034, REQ-COLL-035, SPEC-BACK-002, SPEC-BACK-003, SPEC-BACK-004, SPEC-BACK-006, SPEC-BACK-014
    function pledge(
        address depositor,
        address proxy,
        address vaultToken,
        bytes32 positionKey,
        bool requireRescue
    ) external override returns (uint256 recordId, uint128 credited) {
        _onlyAdapter();
        Ctx memory c = _load(vaultToken);
        if (depositor == address(0) || depositor == address(this) || depositor == c.lpVault) {
            revert InvalidDepositor(depositor);
        }
        _checkProxy(vaultToken, proxy);
        address bound = proxyMarket[proxy];
        if (bound != address(0) && bound != vaultToken) revert ProxyMarketMismatch(proxy);
        if (_recordIdOf[c.integrationId][positionKey] != 0) revert AlreadyPledged();
        uint256 open = seizureList[proxy][vaultToken].length + zeroCreditList[proxy][vaultToken].length;
        if (open >= MAX_RECORDS_PER_ACCOUNT_MARKET) revert TooManyRecords(open);

        _checkReadSafe(c);
        credited = IAmmIntegration(c.lpVault).receivePosition(c.marketId, depositor, positionKey);
        if (credited == 0) revert ZeroUnits();
        if (credited > MAX_CREDITED_UNITS) revert LiquidityAboveBound();
        if (IAmmIntegration(c.lpVault).marketOfPosition(positionKey) != c.marketId) revert ShapeMismatch();
        PledgeCharge memory charge = _charge(c, depositor, proxy, positionKey, credited, requireRescue);
        _checkCharge(charge, credited);

        recordId = _nextRecordId++;
        _recordIdOf[c.integrationId][positionKey] = recordId;
        records[recordId] = BackingRecord({
            positionKey: positionKey,
            depositor: depositor,
            integrationId: c.integrationId,
            marketId: SafeCast.toUint32(c.marketId),
            inList: true,
            proxy: proxy,
            // uint40 seconds last until the year 36812.
            // forge-lint: disable-next-line(unsafe-typecast)
            pledgedAt: uint40(block.timestamp),
            lastDebitedAt: 0,
            credited: credited,
            originalUnits: credited,
            rescueUnits: charge.rescueUnits,
            // usdCharge < 2^64 (`_checkCharge`).
            // forge-lint: disable-next-line(unsafe-typecast)
            originalUsdCharge: uint64(charge.usdCharge),
            // usdCharge < 2^64 (`_checkCharge`).
            // forge-lint: disable-next-line(unsafe-typecast)
            currentUsdCharge: uint64(charge.usdCharge)
        });
        if (bound == address(0)) proxyMarket[proxy] = vaultToken;
        _insert(seizureList[proxy][vaultToken], recordId, credited);
        marketRecords[vaultToken].push(recordId);
        marketRecordIndex[recordId] = marketRecords[vaultToken].length;
        _credit(c, proxy, credited, charge.rescueUnits);
        _book(c, depositor, charge);
        emit CollateralPledged(
            recordId,
            positionKey,
            depositor,
            c.integrationId,
            proxy,
            vaultToken,
            credited,
            charge.usdCharge,
            charge.sliceUsd
        );
    }

    /// @inheritdoc ICollateralizationAdapter
    /// @custom:spec REQ-COLL-015, REQ-COLL-016, REQ-COLL-021, REQ-COLL-022, REQ-COLL-037, REQ-VAULT-010, REQ-VAULT-024, REQ-VAULT-030, REQ-VAULT-031, REQ-VAULT-032, REQ-VAULT-042, REQ-VAULT-074, REQ-VAULT-107, REQ-VAULT-110, REQ-VAULT-131, SPEC-BACK-004, SPEC-BACK-010, SPEC-BACK-013, SPEC-BACK-014
    function recredit(
        address depositor,
        address proxy,
        address vaultToken,
        bytes32 positionKey,
        bytes calldata topUp,
        bool requireRescue
    ) external override returns (uint128 added, uint128 rescueUnits) {
        (Ctx memory c, uint256 id, BackingRecord storage r) =
            _prepareRecredit(depositor, proxy, vaultToken, positionKey, topUp);
        added = _uncredited(c, r, positionKey);
        PledgeCharge memory charge = _charge(c, depositor, proxy, positionKey, added, requireRescue);
        rescueUnits = _rebase(c, r, added, charge);
        emit RecordRecredited(id, added, charge.usdCharge, rescueUnits);
    }

    /// @notice The live units of a record's position above its credited units (REQ-COLL-015).
    /// @custom:spec REQ-COLL-015, REQ-COLL-021, REQ-VAULT-074, REQ-VAULT-107, SPEC-BACK-010
    function _uncredited(
        Ctx memory c,
        BackingRecord storage r,
        bytes32 positionKey
    ) private view returns (uint128 added) {
        uint256 live = IAmmIntegration(c.lpVault).unitsOf(positionKey);
        uint256 credited = r.credited;
        if (credited == 0 || live <= credited) revert NothingToRecredit(positionKey);
        if (live > MAX_CREDITED_UNITS) revert LiquidityAboveBound();
        // live <= 2^120 - 1.
        // forge-lint: disable-next-line(unsafe-typecast)
        added = uint128(live - credited);
    }

    /// @notice Checks a re-credit's charge, rebases the record on `credited + added` units and its charge plus the new
    /// charge (SPEC-BACK-013), and books the totals, counters and rescue units.
    /// @custom:spec REQ-VAULT-015, REQ-VAULT-030, REQ-VAULT-110, REQ-COLL-016, SPEC-BACK-004, SPEC-BACK-013, SPEC-BACK-014
    function _rebase(
        Ctx memory c,
        BackingRecord storage r,
        uint128 added,
        PledgeCharge memory charge
    ) private returns (uint128 rescueUnits) {
        _checkCharge(charge, added);
        uint256 rebased = r.currentUsdCharge + charge.usdCharge;
        if (rebased >= CHARGE_BOUND) revert InvalidCharge();
        rescueUnits = charge.rescueUnits;
        // credited + added <= 2^120 - 1 (`_uncredited`) and rebased < 2^64.
        uint128 units = r.credited + added;
        r.credited = units;
        r.originalUnits = units;
        // rebased < 2^64, checked above.
        // forge-lint: disable-next-line(unsafe-typecast)
        r.originalUsdCharge = uint64(rebased);
        // rebased < 2^64, checked above.
        // forge-lint: disable-next-line(unsafe-typecast)
        r.currentUsdCharge = uint64(rebased);
        r.rescueUnits += rescueUnits;
        _credit(c, r.proxy, added, rescueUnits);
        _book(c, r.depositor, charge);
    }

    /// @notice Start of `recredit`: caller and lock, vault token, the open record naming `proxy` and `depositor` in
    /// `vaultToken`'s market, the pool lock, reconciliation with the proxy's supplied shares (REQ-VAULT-131) and the
    /// fungible-share top-up (REQ-COLL-037).
    /// @custom:spec REQ-COLL-015, REQ-COLL-022, REQ-COLL-037, REQ-VAULT-010, REQ-VAULT-131, REQ-LOCK-011
    function _prepareRecredit(
        address depositor,
        address proxy,
        address vaultToken,
        bytes32 positionKey,
        bytes calldata topUp
    ) private returns (Ctx memory c, uint256 id, BackingRecord storage r) {
        _onlyAdapter();
        c = _load(vaultToken);
        (id, r) = _record(c, positionKey);
        _checkMarket(c, r);
        if (r.proxy != proxy) revert NotRecordProxy();
        if (r.depositor != depositor) revert NotDepositor();
        _checkReadSafe(c);
        _withReserve(c);
        _reconcile(c, proxy, _supplied(c, proxy));
        // The credit is the live units read next (REQ-COLL-037), not the LPVault's report of the top-up.
        // forge-lint: disable-next-line(unused-return)
        if (topUp.length != 0) IAmmIntegration(c.lpVault).topUpPosition(positionKey, depositor, topUp);
    }

    /// @notice Pokes the market's LPOracle and asks the RiskModule for the charge of `units` (REQ-VAULT-014).
    /// @dev The counters are passed as arguments because the ledger's views revert while the Lock is held. The check's
    /// revert data propagates unchanged.
    /// @custom:spec REQ-VAULT-014, REQ-VAULT-109, REQ-VAULT-144, REQ-COLL-026, REQ-AMM-CORE-005
    function _charge(
        Ctx memory c,
        address depositor,
        address proxy,
        bytes32 positionKey,
        uint128 units,
        bool requireRescue
    ) private returns (PledgeCharge memory) {
        // The poke only stores the first observation (Q-199); the RiskModule reads the price state itself.
        // forge-lint: disable-next-line(unused-return)
        ILPOracle(IVaultToken(c.vaultToken).lpOracle()).poke();
        PledgeCounters memory counters = _counters(c, depositor);
        counters.accountRecords = seizureList[proxy][c.vaultToken].length + zeroCreditList[proxy][c.vaultToken].length;
        return IRiskModuleChecks(_RISK_MODULE)
            .checkPledge(depositor, proxy, c.marketId, c.integrationId, positionKey, units, counters, requireRescue);
    }

    /// @notice Adds `units` and `rescue` units to the account, market and pool totals.
    /// @custom:spec REQ-VAULT-017, REQ-VAULT-129, REQ-COLL-016, REQ-COLL-026, SPEC-BACK-009, SPEC-BACK-014
    function _credit(
        Ctx memory c,
        address proxy,
        uint256 units,
        uint256 rescue
    ) private {
        accountCredited[proxy][c.vaultToken] += units;
        totalCredited[c.vaultToken] += units;
        _poolUnits[c.poolKey] += units;
        if (rescue != 0) accountRescueUnits[proxy][c.vaultToken] += rescue;
    }
}
// forge-lint: disable-end(missing-events-access-control)
// forge-lint: disable-end(reentrancy-no-eth)
// forge-lint: disable-end(reentrancy-events)
