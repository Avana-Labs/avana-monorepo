// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ICollateralization} from "../../src/custody/collateralization/ICollateralization.sol";
import {CollateralizationFixture} from "../utils/fixtures/CollateralizationFixture.sol";

/// @notice Reads Collateralization's record, totals and counters for one account and position; the LPVault mock calls
/// it at the moment it moves the position or its units. Its parameters are immutables, so its runtime code can be placed
/// at another address.
contract CollateralizationCeiProbe {
    ICollateralization internal immutable COLL;
    address internal immutable VT;
    address internal immutable PROXY;
    address internal immutable DEPOSITOR;
    uint32 internal immutable INTEGRATION;
    bytes32 internal immutable KEY;
    uint256 internal immutable RECORD;

    constructor(
        ICollateralization coll,
        address vt,
        address proxy,
        address depositor,
        uint32 integration,
        bytes32 key,
        uint256 record
    ) {
        (COLL, VT, PROXY, DEPOSITOR, INTEGRATION, KEY, RECORD) = (coll, vt, proxy, depositor, integration, key, record);
    }

    function snapshot()
        external
        view
        returns (uint256 recordId, uint256 credited, uint256 total, uint256 account, uint256 regularUsed)
    {
        recordId = COLL.recordIdOf(INTEGRATION, KEY);
        credited = COLL.getRecord(RECORD).credited;
        total = COLL.getTotalCredited(VT);
        account = COLL.getAccountCredited(PROXY, VT);
        regularUsed = COLL.getCounters(VT, DEPOSITOR).regularUsed;
    }
}

/// @title CollateralizationCeiUnitTest
/// @notice Checks-effects-interactions per step (2.16 `REQ-LOCK-017`, 2.3 `REQ-VAULT-089`): when Collateralization asks
/// the LPVault to return a position or release units, the record, the totals and the counters of that debit are already
/// final, so the external call sees the step's settled state.
/// forge-config: default.isolate = false
contract CollateralizationCeiUnitTest is CollateralizationFixture {
    bytes32 internal constant KEY42 = bytes32(uint256(42));
    bytes32 internal constant KEY7 = bytes32(uint256(7));

    function setUp() public {
        _deployCollateralization();
    }

    function _observeAt(
        bytes32 key,
        uint256 record
    ) internal returns (CollateralizationCeiProbe probe) {
        // Collateralization's ledger views answer only the Lock holder while it is held (REQ-LOCK-016), so the probe
        // runs at the AaveAdapter's address, the holder of these debits; the fixture's AaveAdapter is an address the
        // test pranks, never a contract Collateralization calls.
        CollateralizationCeiProbe deployed =
            new CollateralizationCeiProbe(coll, vt, aliceProxy, alice, INTEGRATION, key, record);
        vm.etch(adapter, address(deployed).code);
        probe = CollateralizationCeiProbe(adapter);
        lpVault.setObserver(address(probe), abi.encodeCall(CollateralizationCeiProbe.snapshot, ()));
    }

    function _now(
        CollateralizationCeiProbe probe
    ) internal view returns (bytes memory ret) {
        (, ret) = address(probe).staticcall(abi.encodeCall(CollateralizationCeiProbe.snapshot, ()));
    }

    function _seen() internal view returns (uint256, uint256, uint256, uint256, uint256) {
        return abi.decode(lpVault.observed(), (uint256, uint256, uint256, uint256, uint256));
    }

    /// @notice A debt-free release of NFT 42 (5,000,000,000 of 9,000,000,000 credited units): inside the LPVault's
    /// `returnPosition` the record is already closed, the totals already lowered to 4,000,000,000 and the regular
    /// counter already $8,000, the same values as after the call.
    // TEST-018 verifies: REQ-LOCK-017, REQ-VAULT-089
    function test_TEST_018_releaseEffectsBeforePositionReturn() public {
        _pledge(alice, aliceProxy, KEY42, 5_000_000_000);
        _pledge(alice, aliceProxy, KEY7, 4_000_000_000);
        CollateralizationCeiProbe probe = _observeAt(KEY42, 1);
        vm.prank(adapter);
        lock.acquire();
        _withdrawAndBurn(aliceProxy, 5_000_000_000);
        vm.prank(adapter);
        coll.release(aliceProxy, vt, KEY42, 5_000_000_000);
        vm.prank(adapter);
        lock.release();
        assertEq(lpVault.observations(), 1, "one position move");
        (uint256 recordId, uint256 credited, uint256 total, uint256 account, uint256 regular) = _seen();
        assertEq(recordId, 0, "record closed before the position moved");
        assertEq(credited, 0, "record deleted before the position moved");
        assertEq(total, 4_000_000_000);
        assertEq(account, 4_000_000_000);
        assertEq(regular, 800_000_000_000);
        assertEq(_now(probe), lpVault.observed(), "the call saw the final state");
    }

    /// @notice A partial removal of 1,000,000,000 of NFT 42's 5,000,000,000 units: inside `releaseToDepositor` the
    /// record already holds 4,000,000,000 units, the total 4,000,000,000 and the regular counter $8,000.
    // TEST-237 verifies: REQ-LOCK-017, REQ-VAULT-089
    function test_TEST_237_partialRemovalEffectsBeforeUnitRelease() public {
        _pledge(alice, aliceProxy, KEY42, 5_000_000_000);
        CollateralizationCeiProbe probe = _observeAt(KEY42, 1);
        vm.prank(adapter);
        lock.acquire();
        _withdrawAndBurn(aliceProxy, 1_000_000_000);
        vm.prank(adapter);
        coll.releasePartial(aliceProxy, vt, KEY42, 1_000_000_000, new uint256[](2));
        vm.prank(adapter);
        lock.release();
        assertEq(lpVault.observations(), 1, "one unit release");
        (uint256 recordId, uint256 credited, uint256 total, uint256 account, uint256 regular) = _seen();
        assertEq(recordId, 1, "the record stays open");
        assertEq(credited, 4_000_000_000, "units debited before they left");
        assertEq(total, 4_000_000_000);
        assertEq(account, 4_000_000_000);
        assertEq(regular, 800_000_000_000);
        assertEq(_now(probe), lpVault.observed(), "the call saw the final state");
    }
}
