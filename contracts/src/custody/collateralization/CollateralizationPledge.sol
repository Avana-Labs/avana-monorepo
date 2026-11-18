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
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

// External calls go only to known protocol contracts while a Lock member holds the Lock, so nothing can re-enter.
// forge-lint: disable-start(reentrancy-events)
// forge-lint: disable-start(reentrancy-no-eth)
// Ledger writes happen only inside entry points that emit their own event.
// forge-lint: disable-start(missing-events-access-control)
/// @title CollateralizationPledge
/// @notice Adapter path, credit side: `pledge` records a custodied position and `recredit` credits units added to it.
/// @dev Trusts the Adapter for `depositor`, `proxy` and `requireRescue`, but still enforces the custody limits.
abstract contract CollateralizationPledge is CollateralizationLedger, ICollateralizationAdapter {
    /// @inheritdoc ICollateralizationAdapter
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
        if (open >= _recordCap(c.lpVault)) revert TooManyRecords(open);

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
            windowedBps: charge.rescue ? 0 : WINDOW_BPS,
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
        _book(c, charge);
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
        r.windowedBps = _windowedBps(r.currentUsdCharge, r.windowedBps, charge, rebased);
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
        _book(c, charge);
    }

    /// @dev The record's `windowedBps` after a re-credit, rounded down so an exit never credits more than was charged.
    function _windowedBps(
        uint256 current,
        uint16 bps,
        PledgeCharge memory charge,
        uint256 rebased
    ) private pure returns (uint16) {
        if (rebased == 0) return WINDOW_BPS;
        uint256 windowed = current * bps / WINDOW_BPS + (charge.rescue ? 0 : charge.usdCharge);
        // windowed <= rebased, so the share is at most WINDOW_BPS and fits uint16; `rebased` is non-zero here.
        return SafeCast.toUint16(Math.mulDiv(windowed, WINDOW_BPS, rebased));
    }

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
        // The credit is the live units read next, not the LPVault's report of the top-up.
        // forge-lint: disable-next-line(unused-return)
        if (topUp.length != 0) IAmmIntegration(c.lpVault).topUpPosition(positionKey, depositor, topUp);
    }

    /// @dev Counters are passed in because the ledger's views revert while the Lock is held.
    function _charge(
        Ctx memory c,
        address depositor,
        address proxy,
        bytes32 positionKey,
        uint128 units,
        bool requireRescue
    ) private returns (PledgeCharge memory) {
        // The poke only stores the first observation; the RiskModule reads the price state itself.
        // forge-lint: disable-next-line(unused-return)
        ILPOracle(IVaultToken(c.vaultToken).lpOracle()).poke();
        PledgeCounters memory counters = _counters(c);
        counters.accountRecords = seizureList[proxy][c.vaultToken].length + zeroCreditList[proxy][c.vaultToken].length;
        return IRiskModuleChecks(_RISK_MODULE)
            .checkPledge(depositor, proxy, c.marketId, c.integrationId, positionKey, units, counters, requireRescue);
    }

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
