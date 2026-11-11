// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {CollateralizationBase} from "../../../src/custody/collateralization/CollateralizationBase.sol";
import {CollateralizationLedger} from "../../../src/custody/collateralization/CollateralizationLedger.sol";
import {BackingRecord} from "../../../src/custody/collateralization/types/BackingRecord.sol";

/// @notice Lock stand-in with a settable holder, for the gate checks of the harness.
contract HarnessLock {
    address public holder;

    function setHolder(
        address h
    ) external {
        holder = h;
    }
}

/// @title CollateralizationLedgerHarness
/// @notice Exposes Collateralization's record internals (list insertion, the head-first debit, closing, the exposure
/// release and the caller gates) over one account-market, without the vault token, LPVault or Aave calls, for fuzz,
/// Halmos and Echidna/Medusa.
/// @dev `seed` writes a record exactly as `pledge` does after its external checks; the market context carries two
/// tokens and one Hub.
contract CollateralizationLedgerHarness is CollateralizationLedger {
    address public constant HUB = address(0x4B0B);
    address public constant VT = address(0x7777);
    address public constant TOKEN0 = address(0x7070);
    address public constant TOKEN1 = address(0x7171);
    bytes32 public constant POOL_KEY = keccak256("pool");

    constructor(
        address adapter,
        address lpVaultSwap,
        address lock
    ) CollateralizationBase(adapter, lpVaultSwap, address(0x5155), lock, address(0xFAC7)) {}

    function ctx() public pure returns (Ctx memory c) {
        c.vaultToken = VT;
        c.hub = HUB;
        c.poolKey = POOL_KEY;
        c.tokens = new address[](2);
        c.tokens[0] = TOKEN0;
        c.tokens[1] = TOKEN1;
    }

    /// @notice Writes a record of `credited` units charged `charge` (with `slice` of it in the slice bucket and
    /// `rescue` rescue units) for `proxy`, as `pledge` does after custody.
    function seed(
        address proxy,
        uint128 credited,
        uint64 charge,
        uint64 slice,
        uint128 rescue
    ) external returns (uint256 id) {
        id = _nextRecordId++;
        records[id] = BackingRecord({
            positionKey: bytes32(id),
            depositor: address(uint160(0xD0D0)),
            integrationId: 1,
            marketId: 4,
            inList: true,
            proxy: proxy,
            pledgedAt: uint40(block.timestamp),
            lastDebitedAt: 0,
            credited: credited,
            originalUnits: credited,
            rescueUnits: rescue,
            originalUsdCharge: charge,
            currentUsdCharge: charge
        });
        _recordIdOf[1][bytes32(id)] = id;
        proxyMarket[proxy] = VT;
        _insert(seizureList[proxy][VT], id, credited);
        marketRecords[VT].push(id);
        marketRecordIndex[id] = marketRecords[VT].length;
        accountCredited[proxy][VT] += credited;
        totalCredited[VT] += credited;
        _poolUnits[POOL_KEY] += credited;
        accountRescueUnits[proxy][VT] += rescue;
        marketUsd[VT][Bucket.Regular] += charge - slice;
        marketUsd[VT][Bucket.Slice] += slice;
        tokenUsd[HUB][TOKEN0] += charge;
        tokenUsd[HUB][TOKEN1] += charge;
        depositorUsd[HUB][address(uint160(0xD0D0))] += charge;
    }

    function debit(
        address proxy,
        uint256 units
    ) external returns (uint256 touched) {
        (, touched) = _debit(ctx(), proxy, units);
    }

    function debitRecord(
        uint256 id,
        uint256 units
    ) external returns (uint256) {
        return _debitRecord(ctx(), records[id], units);
    }

    function close(
        uint256 id
    ) external {
        BackingRecord storage r = records[id];
        _debitRecord(ctx(), r, r.credited);
        _close(ctx(), id, r);
    }

    function remainingCharge(
        uint256 basisCharge,
        uint256 remaining,
        uint256 basisUnits
    ) external pure returns (uint256) {
        return _remainingCharge(basisCharge, remaining, basisUnits);
    }

    function gateAdapter() external view {
        _onlyAdapter();
    }

    function gateLPVaultSwap() external view {
        _onlyLPVaultSwap();
    }

    function gateView() external view {
        _checkView();
    }

    // ─── Reads ───

    function list(
        address proxy
    ) external view returns (uint256[] memory) {
        return seizureList[proxy][VT];
    }

    function zeros(
        address proxy
    ) external view returns (uint256[] memory) {
        return zeroCreditList[proxy][VT];
    }

    function record(
        uint256 id
    ) external view returns (BackingRecord memory) {
        return records[id];
    }

    function credit(
        address proxy
    ) external view returns (uint256) {
        return accountCredited[proxy][VT];
    }

    function total() external view returns (uint256) {
        return totalCredited[VT];
    }

    function pool() external view returns (uint256) {
        return _poolUnits[POOL_KEY];
    }

    function rescueSum(
        address proxy
    ) external view returns (uint256) {
        return accountRescueUnits[proxy][VT];
    }

    function market() external view returns (uint256 regular, uint256 slice) {
        return (marketUsd[VT][Bucket.Regular], marketUsd[VT][Bucket.Slice]);
    }

    function tokenCounter() external view returns (uint256) {
        return tokenUsd[HUB][TOKEN0];
    }

    function nextId() external view returns (uint256) {
        return _nextRecordId;
    }
}
