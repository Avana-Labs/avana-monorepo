// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {Pending} from "../../../src/custody/collateralization/types/Pending.sol";
import {AaveAdapterSteps} from "../../../src/policy/aave-adapter/AaveAdapterSteps.sol";
import {AaveAdapterStorage} from "../../../src/policy/aave-adapter/AaveAdapterStorage.sol";
import {AaveAdapterImmutables} from "../../../src/policy/aave-adapter/types/AaveAdapterImmutables.sol";

/// @notice The two Collateralization views the backing gap reads, with balances the harness sets.
contract AdapterBackingLedger {
    uint256 public credited;
    uint256 public pendingUnits;

    function set(
        uint256 c,
        uint256 p
    ) external {
        credited = c;
        pendingUnits = p;
    }

    function getTotalCredited(
        address
    ) external view returns (uint256) {
        return credited;
    }

    function getPending(
        address
    ) external view returns (Pending memory pending) {
        pending.units = pendingUnits;
    }
}

/// @notice A vault token's `totalSupply`, which the harness sets.
contract AdapterBackingSupply {
    uint256 public totalSupply;

    function set(
        uint256 s
    ) external {
        totalSupply = s;
    }
}

/// @title AaveAdapterProperties
/// @notice Echidna and Medusa properties of the AaveAdapter's own internals (2.6): the backing-gap check of
/// SPEC-PROXY-008 and the transient repay-with-collateral session of REQ-ADAPTER-080/081, run on the production code of
/// `AaveAdapterSteps` and `AaveAdapterStorage` that every logic contract inherits.
/// @dev The router with its four logic contracts is about 74 KB of creation code, beyond one harness's 49,152-byte
/// initcode limit, and the real Aave V4 fixture is deployed with cheatcodes; so this harness inherits the internals and
/// models Collateralization's two backing views and the vault token's supply. The nonce, the account binding, exit
/// liveness and the supply accounting across real calls are the Foundry invariant suite's (`AaveAdapter.invariant.t.sol`,
/// TEST-088, TEST-096, TEST-099, TEST-211). Between transactions: the session is empty, the ERC-7201 slot is the
/// namespace formula and the last gap check matched its model. Assertion entry points `gapCall` and `session` have
/// finite branching.
contract AaveAdapterProperties is AaveAdapterSteps {
    /// @dev The vault-token stand-in, created with the ledger while the base constructor's arguments are built.
    address internal supplyToken;

    uint256 public calls;
    /// @notice Set when a gap check disagreed with the model; never reset.
    bool public mismatch;

    constructor() AaveAdapterStorage(_immutables()) {}

    /// @dev Deploys the Collateralization and vault-token stand-ins; every other dependency is a fixed non-zero address
    /// the internals exercised here never call.
    function _immutables() private returns (AaveAdapterImmutables memory im) {
        AdapterBackingLedger ledger = new AdapterBackingLedger();
        supplyToken = address(new AdapterBackingSupply());
        im = AaveAdapterImmutables({
            proxyManager: address(0x1001),
            collateralization: address(ledger),
            riskModule: address(0x1003),
            marketRegistry: address(0x1004),
            parameterStore: address(0x1005),
            lpVaultSwap: address(0x1006),
            lock: address(0x1007),
            vaultTokenFactory: address(0x1008),
            timelock: address(0x1009)
        });
    }

    function _ledger() internal view returns (AdapterBackingLedger) {
        return AdapterBackingLedger(_COLLATERALIZATION);
    }

    function _token() internal view returns (address) {
        return supplyToken;
    }

    /// @notice External entry for `_checkGap`, so a revert can be observed with try/catch.
    function checkGapExternal(
        int256 gapBefore
    ) external view {
        _checkGap(_token(), gapBefore);
    }

    // ─── Assertion entry points ───

    /// @notice One Adapter call's effect on a market's backing, by kind: 0 a conforming pledge or re-credit (supply
    /// and credited rise by `a`), 1 a conforming withdrawal or removal (both fall by `a`), 2 a conforming deleverage
    /// release that reconciles `b` units into pending, 3 an unbacked mint (supply rises one unit more than credited),
    /// 4 an unmatched burn (supply falls, credited does not), 5 an orphan seizure burn earlier (a gap) followed by a
    /// conforming pledge. The check passes exactly for the conforming kinds.
    function gapCall(
        uint8 kind,
        uint64 a,
        uint64 b,
        uint64 base
    ) external {
        ++calls;
        AdapterBackingSupply token = AdapterBackingSupply(_token());
        uint256 start = uint256(base) + uint256(a) + uint256(b) + 2;
        uint256 orphan = kind % 6 == 5 ? uint256(b) + 1 : 0;
        token.set(start - orphan);
        _ledger().set(start, 0);
        int256 g0 = _gap(_token());
        uint256 k = kind % 6;
        if (k == 0 || k == 5) {
            token.set(start - orphan + a);
            _ledger().set(start + a, 0);
        } else if (k == 1) {
            token.set(start - a);
            _ledger().set(start - a, 0);
        } else if (k == 2) {
            // Withdraw and burn `a`; `b` units of an earlier shortfall move from credited to pending.
            token.set(start - a);
            _ledger().set(start - a - b, b);
        } else if (k == 3) {
            token.set(start + a + 1);
            _ledger().set(start + a, 0);
        } else {
            token.set(start - a - 1);
            _ledger().set(start, 0);
        }
        bool conforming = k == 0 || k == 1 || k == 2 || k == 5;
        bool passed;
        try this.checkGapExternal(g0) {
            passed = true;
        } catch {
            passed = false;
        }
        if (passed != conforming) mismatch = true;
        assert(passed == conforming);
        assert(k != 5 || g0 == int256(orphan));
    }

    /// @notice Opens a session, runs the steps `steps` names (bit 0 repay, bit 1 release), reads every field back and
    /// closes it: the fields are the ones written, the flags only accumulate, and a closed session reads empty.
    function session(
        address proxy,
        uint256 marketId,
        bytes32 key,
        uint256 units,
        uint256 reserveId,
        bytes32 minHash,
        uint8 steps
    ) external {
        ++calls;
        _openSession(proxy, marketId, key, units, reserveId, minHash);
        (address p, uint256 m, bytes32 k, uint256 u, uint256 r, bytes32 h, uint256 s) = _session();
        assert(p == proxy && m == marketId && k == key && u == units && r == reserveId && h == minHash && s == 0);
        if (steps & 1 != 0) _markStep(STEP_REPAID);
        if (steps & 2 != 0) _markStep(STEP_RELEASED);
        (,,,,,, s) = _session();
        assert(s == (steps & 3));
        _markStep(STEP_REPAID);
        (,,,,,, uint256 s2) = _session();
        assert(s2 == (s | STEP_REPAID));
        _clearSession();
        (p, m, k, u, r, h, s) = _session();
        assert(p == address(0) && m == 0 && k == bytes32(0) && u == 0 && r == 0 && h == bytes32(0) && s == 0);
    }

    // ─── Properties ───

    /// @notice No session survives a transaction.
    function property_sessionEmptyBetweenTransactions() external view returns (bool) {
        (address p,,,,,, uint256 s) = _session();
        return p == address(0) && s == 0;
    }

    /// @notice The storage slot is the ERC-7201 location of `avana.storage.AaveAdapter`.
    function property_storageSlotIsNamespace() external pure returns (bool) {
        return STORAGE_SLOT
            == keccak256(abi.encode(uint256(keccak256("avana.storage.AaveAdapter")) - 1)) & ~bytes32(uint256(0xff));
    }

    /// @notice Every gap check agreed with the backing model.
    function property_gapCheckMatchesModel() external view returns (bool) {
        return !mismatch;
    }

    /// @notice The implementation immutables never change and none is zero.
    function property_immutablesFixed() external view returns (bool) {
        return _PROXY_MANAGER == address(0x1001) && _RISK_MODULE == address(0x1003) && _LOCK == address(0x1007)
            && _TIMELOCK == address(0x1009) && _COLLATERALIZATION != address(0) && _SELF == address(this);
    }
}
