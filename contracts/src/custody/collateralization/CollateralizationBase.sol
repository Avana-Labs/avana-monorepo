// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAmmIntegration} from "../../amm/IAmmIntegration.sol";
import {IAmmIntegrationHooks} from "../../amm/IAmmIntegrationHooks.sol";
import {IAaveV4Hub} from "../../interfaces/external/aave/IAaveV4Hub.sol";
import {IAaveV4Spoke} from "../../interfaces/external/aave/IAaveV4Spoke.sol";
import {ILock} from "../../lock/lock/ILock.sol";
import {PledgeCharge} from "../../policy/risk-module/types/RiskModuleTypes.sol";
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

// External calls go only to known protocol contracts while a Lock member holds the Lock, so nothing can re-enter.
// forge-lint: disable-start(reentrancy-events)
// forge-lint: disable-start(reentrancy-no-eth)
// Ledger writes happen only inside entry points that emit their own event.
// forge-lint: disable-start(missing-events-access-control)
// The storage is used by the inheriting facets, which a single-file lint does not see.
// forge-lint: disable-start(unused-state-variables)
/// @title CollateralizationBase
/// @notice Storage, caller and lock checks and exposure counters shared by the Collateralization facets.
abstract contract CollateralizationBase is ICollateralizationEvents, ICollateralizationErrors {
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

    struct Debit {
        uint256 recordId;
        bytes32 positionKey;
        uint128 take;
        uint256 creditedAfter;
        uint256 capReleased;
    }

    /// @notice Global cap on open records per account and market; an integration may set fewer.
    uint256 internal constant MAX_RECORDS_PER_ACCOUNT_MARKET = AmmConstants.MAX_RECORDS_PER_ACCOUNT_MARKET;

    function _recordCap(
        address lpVault
    ) internal view returns (uint256) {
        return Math.min(IAmmIntegration(lpVault).maxRecordsPerAccountMarket(), MAX_RECORDS_PER_ACCOUNT_MARKET);
    }

    /// @notice Bound of a record's credited units, the Hub's share type (`2^120 - 1`).
    uint256 internal constant MAX_CREDITED_UNITS = type(uint120).max;

    uint256 internal constant CHARGE_BOUND = 2 ** 64;

    /// @dev `BackingRecord.windowedBps` of a charge the pledge window took in full.
    uint16 internal constant WINDOW_BPS = 10_000;

    /// @notice Gas that must be left after a failed `markDebtFree` read for the failure to count as the read's own.
    uint256 internal constant DEBT_MARK_GAS_FLOOR = 50_000;

    uint256 internal constant SPEED_CREDIT_GAS = 100_000;

    /// @notice Gas an exit must hold before the credit call, so the credit always receives its full stipend.
    uint256 internal constant SPEED_CREDIT_FLOOR = SPEED_CREDIT_GAS + SPEED_CREDIT_GAS / 63 + 10_000;

    /// @dev First of five transient slots of the seizure snapshot; slot +0 (`proxy`) is non-zero while active.
    uint256 internal constant SEIZURE_SLOT = uint256(keccak256("avana.collateralization.seizure"));

    address internal immutable _ADAPTER;
    address internal immutable _LP_VAULT_SWAP;
    address internal immutable _RISK_MODULE;
    address internal immutable _LOCK;
    address internal immutable _VAULT_TOKEN_FACTORY;

    /// @notice Next record ID; starts at 1 and is never reused.
    uint256 internal _nextRecordId;
    mapping(uint256 recordId => BackingRecord) internal records;
    /// @notice Open record of a position; 0 = none.
    mapping(uint32 integrationId => mapping(bytes32 positionKey => uint256)) internal _recordIdOf;
    /// @notice Records with credited units of an account-market, largest-first at insertion.
    mapping(address proxy => mapping(address vaultToken => uint256[])) internal seizureList;
    mapping(address proxy => mapping(address vaultToken => uint256[])) internal zeroCreditList;
    /// @notice The one market a proxy's records belong to, written at its first pledge.
    mapping(address proxy => address vaultToken) internal proxyMarket;
    mapping(address proxy => mapping(address vaultToken => uint256)) internal accountCredited;
    mapping(address vaultToken => uint256) internal totalCredited;
    mapping(address proxy => mapping(address vaultToken => uint256)) internal accountRescueUnits;
    mapping(address vaultToken => Pending) internal pending;
    /// @notice Market exposure counter per budget part, USD 8 decimals.
    mapping(address vaultToken => mapping(Bucket => uint256)) internal marketUsd;
    mapping(bytes32 poolKey => uint256) internal _poolUnits;
    /// @notice Exposure per (Hub, market token), USD 8 decimals.
    mapping(address hub => mapping(address token => uint256)) internal tokenUsd;
    /// @notice Whether an account has had debt since its last `markDebtFree`.
    mapping(address proxy => bool) internal indebted;
    mapping(address vaultToken => uint256) internal indebtedCount;
    /// @notice Open record IDs of a market, for paging; swap-and-pop on close.
    mapping(address vaultToken => uint256[]) internal marketRecords;
    /// @notice Position + 1 of an open record in its market's `marketRecords`.
    mapping(uint256 recordId => uint256) internal marketRecordIndex;

    error InvalidImmutable();

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

    function _onlyAdapter() internal view {
        if (msg.sender != _ADAPTER) revert NotAdapter();
        if (_holder() != _ADAPTER) revert LockNotHeld();
    }

    function _onlyLPVaultSwap() internal view {
        if (msg.sender != _LP_VAULT_SWAP) revert NotLPVaultSwap();
        if (_holder() != _LP_VAULT_SWAP) revert LockNotHeld();
    }

    function _checkView() internal view {
        address holder = _holder();
        if (holder != address(0) && holder != msg.sender) revert Locked();
    }

    function _holder() internal view returns (address) {
        return ILock(_LOCK).holder();
    }

    /// @dev Checks `isVaultToken` before calling the token, so an arbitrary address is never called.
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

    function _withReserve(
        Ctx memory c
    ) internal view {
        c.assetId = IAaveV4Hub(c.hub).getAssetId(c.vaultToken);
        c.reserveId = IAaveV4Spoke(c.spoke).getReserveId(c.hub, c.assetId);
    }

    function _sharesEqualAssets(
        Ctx memory c
    ) internal view returns (bool) {
        return IAaveV4Hub(c.hub).getAddedAssets(c.assetId) == IAaveV4Hub(c.hub).getAddedShares(c.assetId);
    }

    function _supplied(
        Ctx memory c,
        address proxy
    ) internal view returns (uint256) {
        return IAaveV4Spoke(c.spoke).getUserSuppliedShares(c.reserveId, proxy);
    }

    function _checkReadSafe(
        Ctx memory c
    ) internal view {
        IAmmIntegrationHooks(c.lpVault).checkReadSafe(c.marketId);
    }

    function _returnPosition(
        Ctx memory c,
        bytes32 positionKey
    ) internal {
        // The LPVault returns the position to its own depositor of record; the address it reports is not needed.
        // forge-lint: disable-next-line(unused-return)
        IAmmIntegration(c.lpVault).returnPosition(positionKey);
    }

    function _unwind(
        Ctx memory c,
        bytes32 positionKey,
        uint128 units,
        uint256[] memory minAmounts,
        address recipient
    ) internal returns (uint256[] memory) {
        // Called once per debited record; bounded by the open-record cap.
        // forge-lint: disable-next-line(calls-loop)
        return IAmmIntegration(c.lpVault).unwind(positionKey, units, minAmounts, recipient);
    }

    function _balances(
        Ctx memory c,
        address account
    ) internal view returns (uint256[] memory balances) {
        uint256 n = c.tokens.length;
        balances = new uint256[](n);
        for (uint256 i = 0; i < n; ++i) {
            // One read per market token, at most 8.
            // forge-lint: disable-next-line(calls-loop)
            balances[i] = IERC20(c.tokens[i]).balanceOf(account);
        }
    }

    /// @notice Per-token increase of `account`'s balances since `before`, 0 where a balance did not rise.
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

    function _checkProxy(
        address vaultToken,
        address proxy
    ) internal view {
        if (proxy == address(0) || !IVaultToken(vaultToken).isValidProxy(proxy)) revert UnknownProxy(proxy);
    }

    function _supply(
        address vaultToken
    ) internal view returns (uint256) {
        return IVaultToken(vaultToken).totalSupply();
    }

    function _checkLength(
        Ctx memory c,
        uint256 actual
    ) internal pure {
        if (actual != c.tokens.length) revert LengthMismatch(c.tokens.length, actual);
    }

    function _checkCharge(
        PledgeCharge memory charge,
        uint256 units
    ) internal pure {
        if (
            charge.usdCharge == 0 || charge.usdCharge >= CHARGE_BOUND || charge.sliceUsd > charge.usdCharge
                || charge.rescueUnits > units || (charge.rescue && charge.rescueUnits != units)
        ) revert InvalidCharge();
    }

    function _book(
        Ctx memory c,
        PledgeCharge memory charge
    ) internal {
        marketUsd[c.vaultToken][Bucket.Regular] += charge.usdCharge - charge.sliceUsd;
        if (charge.sliceUsd != 0) marketUsd[c.vaultToken][Bucket.Slice] += charge.sliceUsd;
        uint256 n = c.tokens.length;
        for (uint256 i = 0; i < n; ++i) {
            // One counter per market token, at most 8.
            // forge-lint: disable-next-line(costly-loop)
            tokenUsd[c.hub][c.tokens[i]] += charge.usdCharge;
        }
    }

    /// @notice Charge carried by `remaining` units on a record's basis, rounded up.
    function _remainingCharge(
        uint256 basisCharge,
        uint256 remaining,
        uint256 basisUnits
    ) internal pure returns (uint256) {
        return Math.mulDiv(basisCharge, remaining, basisUnits, Math.Rounding.Ceil);
    }

    /// @notice Lowers a record's charge to that of its remaining units, and the counters by the difference.
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
            // One counter per market token, at most 8.
            // forge-lint: disable-next-line(costly-loop)
            tokenUsd[c.hub][token] = _satSub(tokenUsd[c.hub][token], released, CounterKind.Token, c.hub, token);
        }
    }

    /// @notice `max(value - amount, 0)`, emitting `CounterSaturated` when it clamps.
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

    function _storeSnapshot(
        address proxy,
        address vaultToken,
        uint256 reserveId,
        uint256 sharesBefore,
        uint256 supplyBefore
    ) internal {
        uint256 slot = SEIZURE_SLOT;
        // Raw tstore, not the `transient` keyword, which the SMTChecker profile cannot compile.
        // solhint-disable-next-line no-inline-assembly
        assembly ("memory-safe") {
            tstore(slot, proxy)
            tstore(add(slot, 1), vaultToken)
            tstore(add(slot, 2), reserveId)
            tstore(add(slot, 3), sharesBefore)
            tstore(add(slot, 4), supplyBefore)
        }
    }

    function _loadSnapshot()
        internal
        view
        returns (address proxy, address vaultToken, uint256 reserveId, uint256 sharesBefore, uint256 supplyBefore)
    {
        uint256 slot = SEIZURE_SLOT;
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
