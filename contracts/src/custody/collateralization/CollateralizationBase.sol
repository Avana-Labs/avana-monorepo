// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAmmIntegration} from "../../amm/IAmmIntegration.sol";
import {IAmmIntegrationHooks} from "../../amm/IAmmIntegrationHooks.sol";
import {IAaveV4Hub} from "../../interfaces/external/aave/IAaveV4Hub.sol";
import {IAaveV4Spoke} from "../../interfaces/external/aave/IAaveV4Spoke.sol";
import {ILock} from "../../lock/lock/ILock.sol";
import {PledgeCharge} from "../../policy/risk-module/types/PledgeCharge.sol";
import {AmmConstants} from "../../types/AmmConstants.sol";
import {IVaultTokenFactory} from "../../vault-token/vault-token-factory/IVaultTokenFactory.sol";
import {IVaultToken} from "../../vault-token/vault-token/IVaultToken.sol";
import {ICollateralizationErrors} from "./ICollateralizationErrors.sol";
import {ICollateralizationEvents} from "./ICollateralizationEvents.sol";
import {BackingRecord} from "./types/BackingRecord.sol";
import {CounterKind} from "./types/CounterKind.sol";
import {Pending} from "./types/Pending.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

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
// The storage is declared here and read and written by the facets that inherit it (Pledge, Release, Seizure, Pending,
// DebtMark, Views), which a single-file lint does not see.
// forge-lint: disable-start(unused-state-variables)
/// @title CollateralizationBase
/// @notice Immutables, plain storage, caller and lock checks, vault-token validation, market context, the exposure
/// counters and the transient seizure snapshot of Collateralization (2.3).
/// @dev Collateralization is immutable, so its state is plain storage in declaration order, read directly by the
/// Certora spec. Names follow the 2.3 Storage table; the record index, the next record ID and the pool counter carry a
/// leading underscore because the views `recordIdOf`, `nextRecordId` and `poolUnits` share their names. Every amount
/// is a return value, a stored amount or a balance delta measured around the call that delivered it (REQ-VAULT-088).
/// @custom:spec REQ-COLL-001, REQ-COLL-002, REQ-COLL-003, REQ-COLL-030, REQ-VAULT-028, REQ-VAULT-034, REQ-VAULT-037, REQ-VAULT-086, REQ-VAULT-091, REQ-LOCK-010, SPEC-BACK-004, SPEC-BACK-005, SPEC-BACK-016
abstract contract CollateralizationBase is ICollateralizationEvents, ICollateralizationErrors {
    /// @notice Budget part of the market exposure counter (Q-396: no idle part).
    enum Bucket {
        Regular,
        Slice
    }

    /// @notice Market context of one call, read from a validated vault token and its LPVault's market table.
    struct Ctx {
        address vaultToken;
        address lpVault;
        uint32 integrationId;
        uint256 marketId;
        address hub;
        address spoke;
        bytes32 poolKey;
        address[] tokens;
        uint256 assetId;
        uint256 reserveId;
    }

    /// @notice One record debit of a seizure or a reconciliation.
    struct Debit {
        uint256 recordId;
        bytes32 positionKey;
        uint128 take;
        uint256 creditedAfter;
        uint256 capReleased;
    }

    /// @notice At most 16 open records per account and market (SPEC-BACK-016).
    uint256 internal constant MAX_RECORDS_PER_ACCOUNT_MARKET = AmmConstants.MAX_RECORDS_PER_ACCOUNT_MARKET;

    /// @notice Bound of a record's credited units, the Hub's share type (`2^120 - 1`).
    uint256 internal constant MAX_CREDITED_UNITS = type(uint120).max;

    /// @dev Charges are stored as `uint64`; a charge must be below `2^64` (REQ-VAULT-015).
    uint256 internal constant CHARGE_BOUND = 2 ** 64;

    /// @notice Gas that must be left after a failed `markDebtFree` read for the failure to count as the read's own
    /// (REQ-COLL-040): a call that ran out of gas leaves at most 1/64 of what it was given, so 50,000 left means the read
    /// had at least 63 × 50,000 = 3,150,000 gas, above the worst-case `getUserAccountData` of a CDP account.
    uint256 internal constant DEBT_MARK_GAS_FLOOR = 50_000;

    /// @dev First of five transient slots of the seizure snapshot: `keccak256("avana.collateralization.seizure")`.
    /// Slot +0 `proxy` (non-zero while active), +1 `vaultToken`, +2 `reserveId`, +3 `sharesBefore`, +4 `supplyBefore`.
    uint256 internal constant SEIZURE_SLOT = uint256(keccak256("avana.collateralization.seizure"));

    address internal immutable _ADAPTER;
    address internal immutable _LP_VAULT_SWAP;
    address internal immutable _RISK_MODULE;
    address internal immutable _LOCK;
    address internal immutable _VAULT_TOKEN_FACTORY;

    /// @notice Next record ID; starts at 1 and is never reused.
    uint256 internal _nextRecordId;
    /// @notice Open records by ID; deleted on close.
    mapping(uint256 recordId => BackingRecord) internal records;
    /// @notice Open record of a position; 0 = none.
    mapping(uint32 integrationId => mapping(bytes32 positionKey => uint256)) internal _recordIdOf;
    /// @notice Records with credited units of an account-market, largest-first at insertion (SPEC-BACK-006).
    mapping(address proxy => mapping(address vaultToken => uint256[])) internal seizureList;
    /// @notice Open records at 0 credited units of an account-market (REQ-VAULT-074).
    mapping(address proxy => mapping(address vaultToken => uint256[])) internal zeroCreditList;
    /// @notice The one market a proxy's records belong to, written at its first pledge (REQ-COLL-031).
    mapping(address proxy => address vaultToken) internal proxyMarket;
    /// @notice Sum of credited units of an account-market's open records.
    mapping(address proxy => mapping(address vaultToken => uint256)) internal accountCredited;
    /// @notice Sum of credited units of a market's open records.
    mapping(address vaultToken => uint256) internal totalCredited;
    /// @notice Sum of rescue units of an account-market's open records (SPEC-BACK-014).
    mapping(address proxy => mapping(address vaultToken => uint256)) internal accountRescueUnits;
    /// @notice Pending-settlement balance of a market (Q-201).
    mapping(address vaultToken => Pending) internal pending;
    /// @notice Market exposure counter per budget part, USD 8 decimals.
    mapping(address vaultToken => mapping(Bucket => uint256)) internal marketUsd;
    /// @notice Credited units over every market of one pool (Q-383).
    mapping(bytes32 poolKey => uint256) internal _poolUnits;
    /// @notice Exposure per (Hub, market token), USD 8 decimals.
    mapping(address hub => mapping(address token => uint256)) internal tokenUsd;
    /// @notice Exposure per (Hub, depositor), USD 8 decimals.
    mapping(address hub => mapping(address depositor => uint256)) internal depositorUsd;
    /// @notice Whether an account has had debt since its last `markDebtFree` (Q-355).
    mapping(address proxy => bool) internal indebted;
    /// @notice Accounts of a market carrying the indebted mark.
    mapping(address vaultToken => uint256) internal indebtedCount;
    /// @notice Open record IDs of a market, for paging; swap-and-pop on close.
    mapping(address vaultToken => uint256[]) internal marketRecords;
    /// @notice Position + 1 of an open record in its market's `marketRecords`.
    mapping(uint256 recordId => uint256) internal marketRecordIndex;

    /// @notice Error of a constructor argument that is zero or repeats another one.
    error InvalidImmutable();

    /// @custom:spec REQ-COLL-001, REQ-COLL-002
    constructor(
        address adapter,
        address lpVaultSwap,
        address riskModule,
        address lock,
        address vaultTokenFactory
    ) {
        if (
            adapter == address(0) || lpVaultSwap == address(0) || riskModule == address(0) || lock == address(0)
                || vaultTokenFactory == address(0)
        ) revert InvalidImmutable();
        if (
            adapter == lpVaultSwap || adapter == riskModule || adapter == lock || adapter == vaultTokenFactory
                || lpVaultSwap == riskModule || lpVaultSwap == lock || lpVaultSwap == vaultTokenFactory
                || riskModule == lock || riskModule == vaultTokenFactory || lock == vaultTokenFactory
        ) revert InvalidImmutable();
        _ADAPTER = adapter;
        _LP_VAULT_SWAP = lpVaultSwap;
        _RISK_MODULE = riskModule;
        _LOCK = lock;
        _VAULT_TOKEN_FACTORY = vaultTokenFactory;
        _nextRecordId = 1;
    }

    // ─── Caller and lock ───

    /// @custom:spec REQ-VAULT-006, REQ-VAULT-086, REQ-VAULT-112, REQ-VAULT-113, REQ-LOCK-010, REQ-LOCK-023
    function _onlyAdapter() internal view {
        if (msg.sender != _ADAPTER) revert NotAdapter();
        if (_holder() != _ADAPTER) revert LockNotHeld();
    }

    /// @custom:spec REQ-VAULT-046, REQ-VAULT-050, REQ-VAULT-086, REQ-VAULT-138, REQ-LOCK-010, REQ-LOCK-023
    function _onlyLPVaultSwap() internal view {
        if (msg.sender != _LP_VAULT_SWAP) revert NotLPVaultSwap();
        if (_holder() != _LP_VAULT_SWAP) revert LockNotHeld();
    }

    /// @notice Ledger views revert while the lock is held, unless the caller is the holder.
    /// @custom:spec REQ-VAULT-091, REQ-VAULT-125, REQ-LOCK-016
    function _checkView() internal view {
        address holder = _holder();
        if (holder != address(0) && holder != msg.sender) revert Locked();
    }

    /// @notice The current Lock holder (address(0) while free).
    /// @custom:spec REQ-LOCK-010
    function _holder() internal view returns (address) {
        return ILock(_LOCK).holder();
    }

    // ─── Market context ───

    /// @notice Validates a vault token (REQ-COLL-003) and reads its market context.
    /// @dev The factory's `isVaultToken` is checked before any call to the token, so an arbitrary address reverts
    /// `InvalidVaultToken` without being called. Tokens, pool and pool identifier come from the LPVault's write-once
    /// market table; `poolKey = keccak256(abi.encode(integrationId, pool, poolId))`.
    /// @custom:spec REQ-COLL-002, REQ-COLL-003, REQ-COLL-027, REQ-VAULT-102, INV-017
    function _load(
        address vaultToken
    ) internal view returns (Ctx memory c) {
        IVaultTokenFactory factory = IVaultTokenFactory(_VAULT_TOKEN_FACTORY);
        if (!factory.isVaultToken(vaultToken)) revert InvalidVaultToken();
        IVaultToken token = IVaultToken(vaultToken);
        c.vaultToken = vaultToken;
        c.integrationId = token.integrationId();
        c.lpVault = token.integration();
        c.spoke = token.spoke();
        if (
            factory.tokenOf(c.spoke, token.marketKey()) != vaultToken || factory.lpVaultOf(c.integrationId) != c.lpVault
                || token.collateralization() != address(this) || token.adapter() != _ADAPTER
                || token.lpVaultSwap() != _LP_VAULT_SWAP
        ) revert InvalidVaultToken();
        c.marketId = token.marketId();
        c.hub = token.hub();
        // The shape is the LPVault's to enforce; the ledger needs the pool keys and tokens only.
        // forge-lint: disable-next-line(unused-return)
        (address pool, bytes32 poolId,, address[] memory tokens) = IAmmIntegration(c.lpVault).marketOf(c.marketId);
        c.tokens = tokens;
        c.poolKey = keccak256(abi.encode(c.integrationId, pool, poolId));
    }

    /// @notice Adds the vault-token Hub asset and CDP Spoke reserve to a context.
    /// @custom:spec REQ-COLL-002
    function _withReserve(
        Ctx memory c
    ) internal view {
        c.assetId = IAaveV4Hub(c.hub).getAssetId(c.vaultToken);
        c.reserveId = IAaveV4Spoke(c.spoke).getReserveId(c.hub, c.assetId);
    }

    /// @custom:spec REQ-VAULT-047, REQ-VAULT-130
    function _sharesEqualAssets(
        Ctx memory c
    ) internal view returns (bool) {
        return IAaveV4Hub(c.hub).getAddedAssets(c.assetId) == IAaveV4Hub(c.hub).getAddedShares(c.assetId);
    }

    /// @custom:spec REQ-VAULT-131, REQ-VAULT-132
    function _supplied(
        Ctx memory c,
        address proxy
    ) internal view returns (uint256) {
        return IAaveV4Spoke(c.spoke).getUserSuppliedShares(c.reserveId, proxy);
    }

    /// @notice Reverts with `PoolLocked` while the market's pool is mid-operation (REQ-VAULT-010).
    /// @custom:spec REQ-VAULT-010, REQ-VAULT-105
    function _checkReadSafe(
        Ctx memory c
    ) internal view {
        IAmmIntegrationHooks(c.lpVault).checkReadSafe(c.marketId);
    }

    /// @notice Has the market's LPVault return a position to its depositor of record.
    /// @custom:spec REQ-VAULT-033, REQ-VAULT-072
    function _returnPosition(
        Ctx memory c,
        bytes32 positionKey
    ) internal {
        // The LPVault returns the position to its own depositor of record; the address it reports is not needed.
        // forge-lint: disable-next-line(unused-return)
        IAmmIntegration(c.lpVault).returnPosition(positionKey);
    }

    /// @notice Has the market's LPVault remove exactly `units` from a position and pay the principal to `recipient`.
    /// @custom:spec REQ-VAULT-032, REQ-AMM-CORE-007
    function _unwind(
        Ctx memory c,
        bytes32 positionKey,
        uint128 units,
        uint256[] memory minAmounts,
        address recipient
    ) internal returns (uint256[] memory) {
        // Called once per debited record, at most 16 (SPEC-BACK-016).
        // forge-lint: disable-next-line(calls-loop)
        return IAmmIntegration(c.lpVault).unwind(positionKey, units, minAmounts, recipient);
    }

    /// @notice Balances of `account` in each market token, pool order.
    /// @custom:spec REQ-VAULT-088
    function _balances(
        Ctx memory c,
        address account
    ) internal view returns (uint256[] memory balances) {
        uint256 n = c.tokens.length;
        balances = new uint256[](n);
        for (uint256 i = 0; i < n; ++i) {
            // One read per market token, at most 8 (REQ-COLL-028).
            // forge-lint: disable-next-line(calls-loop)
            balances[i] = IERC20(c.tokens[i]).balanceOf(account);
        }
    }

    /// @notice Per-token increase of `account`'s balances since `before`, 0 where a balance did not rise.
    /// @custom:spec REQ-VAULT-088, SPEC-BACK-015
    function _received(
        Ctx memory c,
        address account,
        uint256[] memory before
    ) internal view returns (uint256[] memory received) {
        received = _balances(c, account);
        uint256 n = received.length;
        for (uint256 i = 0; i < n; ++i) {
            received[i] = received[i] > before[i] ? received[i] - before[i] : 0;
        }
    }

    /// @notice A registered proxy of the vault token, else `UnknownProxy`.
    /// @custom:spec REQ-VAULT-013, REQ-VAULT-048, REQ-COLL-010
    function _checkProxy(
        address vaultToken,
        address proxy
    ) internal view {
        if (proxy == address(0) || !IVaultToken(vaultToken).isValidProxy(proxy)) revert UnknownProxy(proxy);
    }

    /// @notice The vault token's total supply.
    /// @custom:spec SPEC-BACK-007, SPEC-BACK-012
    function _supply(
        address vaultToken
    ) internal view returns (uint256) {
        return IVaultToken(vaultToken).totalSupply();
    }

    /// @notice Requires an n-token array of the market's length.
    /// @custom:spec REQ-COLL-028, REQ-COLL-036
    function _checkLength(
        Ctx memory c,
        uint256 actual
    ) internal pure {
        if (actual != c.tokens.length) revert LengthMismatch(c.tokens.length, actual);
    }

    // ─── Charges and counters ───

    /// @notice Checks a RiskModule charge for `units` credited units (REQ-VAULT-015).
    /// @custom:spec REQ-VAULT-015, REQ-VAULT-110, SPEC-BACK-003, SPEC-BACK-014
    function _checkCharge(
        PledgeCharge memory charge,
        uint256 units
    ) internal pure {
        if (
            charge.usdCharge == 0 || charge.usdCharge >= CHARGE_BOUND || charge.sliceUsd > charge.usdCharge
                || charge.rescueUnits > units || (charge.rescue && charge.rescueUnits != units)
        ) revert InvalidCharge();
    }

    /// @notice Books a charge on the market, token and depositor counters (SPEC-BACK-004).
    /// @custom:spec REQ-COLL-026, REQ-VAULT-017, REQ-VAULT-034, SPEC-BACK-004
    function _book(
        Ctx memory c,
        address depositor,
        PledgeCharge memory charge
    ) internal {
        marketUsd[c.vaultToken][Bucket.Regular] += charge.usdCharge - charge.sliceUsd;
        if (charge.sliceUsd != 0) marketUsd[c.vaultToken][Bucket.Slice] += charge.sliceUsd;
        uint256 n = c.tokens.length;
        for (uint256 i = 0; i < n; ++i) {
            // Inherent: one counter per market token, at most 8 (REQ-COLL-028).
            // forge-lint: disable-next-line(costly-loop)
            tokenUsd[c.hub][c.tokens[i]] += charge.usdCharge;
        }
        depositorUsd[c.hub][depositor] += charge.usdCharge;
    }

    /// @notice Charge carried by `remaining` units on a record's basis: `ceil(V0 * remaining / U0)` (SPEC-BACK-005).
    /// @custom:spec SPEC-BACK-005, SPEC-BACK-013
    function _remainingCharge(
        uint256 basisCharge,
        uint256 remaining,
        uint256 basisUnits
    ) internal pure returns (uint256) {
        return Math.mulDiv(basisCharge, remaining, basisUnits, Math.Rounding.Ceil);
    }

    /// @notice Releases the exposure of a record whose `credited` already holds its remaining units: sets its charge to
    /// the charge of the remaining units and lowers the counters by the difference, slice first, saturating at 0.
    /// @custom:spec REQ-VAULT-036, REQ-VAULT-037, REQ-VAULT-038, REQ-VAULT-127, SPEC-BACK-005
    function _releaseExposure(
        Ctx memory c,
        BackingRecord storage r
    ) internal returns (uint256 released) {
        uint256 remaining = _remainingCharge(r.originalUsdCharge, r.credited, r.originalUnits);
        uint256 before = r.currentUsdCharge;
        if (remaining >= before) return 0;
        released = before - remaining;
        // remaining < before <= type(uint64).max, checked just above.
        // forge-lint: disable-next-line(unsafe-typecast)
        r.currentUsdCharge = uint64(remaining);
        address vt = c.vaultToken;
        uint256 slice = marketUsd[vt][Bucket.Slice];
        uint256 fromSlice = released < slice ? released : slice;
        if (fromSlice != 0) marketUsd[vt][Bucket.Slice] = slice - fromSlice;
        marketUsd[vt][Bucket.Regular] =
            _satSub(marketUsd[vt][Bucket.Regular], released - fromSlice, CounterKind.MarketRegular, c.hub, vt);
        uint256 n = c.tokens.length;
        for (uint256 i = 0; i < n; ++i) {
            address token = c.tokens[i];
            // Inherent: one counter per market token, at most 8 (REQ-COLL-028).
            // forge-lint: disable-next-line(costly-loop)
            tokenUsd[c.hub][token] = _satSub(tokenUsd[c.hub][token], released, CounterKind.Token, c.hub, token);
        }
        address depositor = r.depositor;
        depositorUsd[c.hub][depositor] =
            _satSub(depositorUsd[c.hub][depositor], released, CounterKind.Depositor, c.hub, depositor);
    }

    /// @notice `max(value - amount, 0)`, emitting `CounterSaturated` when it clamps.
    /// @custom:spec REQ-VAULT-037, REQ-VAULT-127
    function _satSub(
        uint256 value,
        uint256 amount,
        CounterKind kind,
        address hub,
        address key
    ) internal returns (uint256) {
        if (amount <= value) return value - amount;
        emit CounterSaturated(kind, hub, key, value, amount);
        return 0;
    }

    // ─── Seizure snapshot (EIP-1153) ───

    /// @custom:spec REQ-VAULT-048, REQ-VAULT-049
    function _storeSnapshot(
        address proxy,
        address vaultToken,
        uint256 reserveId,
        uint256 sharesBefore,
        uint256 supplyBefore
    ) internal {
        uint256 slot = SEIZURE_SLOT;
        // Transient storage keeps the snapshot inside one transaction; the `transient` keyword is not used because
        // the SMTChecker profile cannot compile it.
        // solhint-disable-next-line no-inline-assembly
        assembly ("memory-safe") {
            tstore(slot, proxy)
            tstore(add(slot, 1), vaultToken)
            tstore(add(slot, 2), reserveId)
            tstore(add(slot, 3), sharesBefore)
            tstore(add(slot, 4), supplyBefore)
        }
    }

    /// @custom:spec REQ-VAULT-048, REQ-VAULT-050
    function _loadSnapshot()
        internal
        view
        returns (address proxy, address vaultToken, uint256 reserveId, uint256 sharesBefore, uint256 supplyBefore)
    {
        uint256 slot = SEIZURE_SLOT;
        // Reads the transient snapshot written by `_storeSnapshot`.
        // solhint-disable-next-line no-inline-assembly
        assembly ("memory-safe") {
            proxy := tload(slot)
            vaultToken := tload(add(slot, 1))
            reserveId := tload(add(slot, 2))
            sharesBefore := tload(add(slot, 3))
            supplyBefore := tload(add(slot, 4))
        }
    }
}
// forge-lint: disable-end(unused-state-variables)
// forge-lint: disable-end(missing-events-access-control)
// forge-lint: disable-end(reentrancy-no-eth)
// forge-lint: disable-end(reentrancy-events)
