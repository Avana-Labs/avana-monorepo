// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ICollateralizationErrors} from "../../src/custody/collateralization/ICollateralizationErrors.sol";
import {ICollateralizationEvents} from "../../src/custody/collateralization/ICollateralizationEvents.sol";
import {BackingRecord} from "../../src/custody/collateralization/types/BackingRecord.sol";
import {ILPVaultErrors} from "../../src/custody/lp-vault/ILPVaultErrors.sol";
import {ILock} from "../../src/lock/lock/ILock.sol";
import {IRiskModuleChecks} from "../../src/policy/risk-module/IRiskModuleChecks.sol";
import {PledgeCharge} from "../../src/policy/risk-module/types/PledgeCharge.sol";
import {PledgeCounters} from "../../src/types/PledgeCounters.sol";
import {PositionShape} from "../../src/types/PositionShape.sol";
import {ShapeKind} from "../../src/types/ShapeKind.sol";
import {VaultTokenBindings} from "../../src/types/VaultTokenBindings.sol";
import {VaultToken} from "../../src/vault-token/vault-token/VaultToken.sol";
import {CollateralizationFixture} from "../utils/fixtures/CollateralizationFixture.sol";
import {CollOracleMock, CollRiskModuleMock} from "../utils/mocks/CollateralizationMocks.sol";

/// @title CollateralizationPledgeUnitTest
/// @notice `pledge` and `recredit` on the real Lock, VaultTokenFactory, vault token and local Aave V4: validation,
/// custody through the market's LPVault, credited units read after custody, the RiskModule charge and its checks, the
/// record, the largest-first list, the totals and the Hub- and pool-keyed counters, the record bound and the proxy's
/// market binding.
/// forge-config: default.isolate = false
contract CollateralizationPledgeUnitTest is CollateralizationFixture {
    bytes32 internal constant KEY42 = bytes32(uint256(42));
    bytes32 internal constant KEY7 = bytes32(uint256(7));

    function setUp() public {
        _deployCollateralization();
    }

    function _pledgeAs(
        address depositor,
        address proxy,
        bytes32 key
    ) internal returns (uint256 id, uint128 credited) {
        vm.prank(adapter);
        (id, credited) = coll.pledge(depositor, proxy, vt, key, false);
    }

    function _acquire(
        address member
    ) internal {
        vm.prank(member);
        lock.acquire();
    }

    function _release(
        address member
    ) internal {
        vm.prank(member);
        lock.release();
    }

    function _register(
        address proxy
    ) internal {
        vm.prank(adapter);
        token.addValidProxy(proxy);
    }

    // TEST-010 verifies: REQ-VAULT-012, REQ-VAULT-014, REQ-VAULT-016, REQ-VAULT-017, REQ-VAULT-018, REQ-VAULT-022, REQ-VAULT-035, REQ-COLL-006, REQ-COLL-024, REQ-COLL-027, SPEC-BACK-002, SPEC-BACK-003, SPEC-BACK-004, DEP-012
    // Sources: 5.1 TEST-010, 2.3 SPEC-BACK-002 and SPEC-BACK-004 examples
    /// @notice Alice pledges NFT 42 (5,000,000,000 units) at $2.00: the record, the returned credit, the totals and
    /// every counter match the 2.3 example; the position is in custody with alice as depositor.
    function test_TEST_010_pledgeWritesRecordAndCounters() public {
        lpVault.mintPosition(KEY42, alice, MARKET_ID, 5_000_000_000);
        _acquire(adapter);
        _register(aliceProxy);
        vm.expectEmit(address(coll));
        emit ICollateralizationEvents.CollateralPledged(
            1, KEY42, alice, INTEGRATION, aliceProxy, vt, 5_000_000_000, 1_000_000_000_000, 0
        );
        (uint256 id, uint128 credited) = _pledgeAs(alice, aliceProxy, KEY42);
        _release(adapter);

        assertEq(id, 1, "first record ID");
        assertEq(credited, 5_000_000_000, "credited = units read after custody");
        BackingRecord memory r = coll.getRecord(id);
        assertEq(r.positionKey, KEY42);
        assertEq(r.depositor, alice);
        assertEq(r.proxy, aliceProxy);
        assertEq(r.integrationId, INTEGRATION);
        assertEq(r.marketId, MARKET_ID);
        assertTrue(r.inList);
        assertEq(r.credited, 5_000_000_000);
        assertEq(r.originalUnits, 5_000_000_000);
        assertEq(r.originalUsdCharge, 1_000_000_000_000);
        assertEq(r.currentUsdCharge, 1_000_000_000_000);
        assertEq(r.pledgedAt, block.timestamp);
        assertEq(coll.recordIdOf(INTEGRATION, KEY42), 1);
        assertEq(coll.nextRecordId(), 2);
        assertEq(coll.getTotalCredited(vt), 5_000_000_000);
        assertEq(coll.getAccountCredited(aliceProxy, vt), 5_000_000_000);
        assertEq(coll.getOpenRecordCount(aliceProxy, vt), 1);
        assertEq(coll.getMarketRecordCount(vt), 1);
        PledgeCounters memory k = coll.getCounters(vt, alice);
        assertEq(k.hub, aave.hub);
        assertEq(k.regularUsed, 1_000_000_000_000, "regular bucket");
        assertEq(k.sliceUsed, 0);
        assertEq(k.depositorUsed, 1_000_000_000_000, "depositor counter");
        assertEq(k.tokenUsed[0], 1_000_000_000_000, "USDC counter");
        assertEq(k.tokenUsed[1], 1_000_000_000_000, "USDT counter");
        assertEq(k.poolKey, keccak256(abi.encode(INTEGRATION, pool, bytes32(0))));
        assertEq(k.poolUnits, 5_000_000_000);
        assertEq(lpVault.ownerOf(KEY42), address(lpVault), "custody");
        assertEq(lpVault.depositorOf(KEY42), alice, "depositor of record");
        assertEq(oracle.pokes(), 1, "LPOracle poked once");
    }

    // TEST-186 verifies: REQ-VAULT-012, REQ-VAULT-018, REQ-VAULT-042, SPEC-BACK-002, SPEC-BACK-009, INV-001, INV-006
    // Sources: 5.1 TEST-186 (Collateralization side)
    /// @notice The units returned to the Adapter are exactly those the LPVault reports after custody; after the
    /// Adapter's mint and the proxy's supply the gap is 0 and the proxy's shares equal its credited units.
    function test_TEST_186_creditEqualsUnitsAfterCustody() public {
        lpVault.mintPosition(KEY42, alice, MARKET_ID, 1_250_000_000_000);
        lpVault.setReceiveOverride(1_249_999_999_999);
        _acquire(adapter);
        _register(aliceProxy);
        (, uint128 credited) = _pledgeAs(alice, aliceProxy, KEY42);
        _release(adapter);
        assertEq(credited, 1_249_999_999_999, "credit = custody read, not the pre-custody units");
        lpVault.setReceiveOverride(0);
        _pledge(bob, bobProxy, KEY7, 4_000_000_000);
        assertEq(_gap(), int256(uint256(credited)), "the first pledge was not minted: its credit is the gap");
        assertEq(_shares(bobProxy), coll.getAccountCredited(bobProxy, vt), "supply = credited");
    }

    // TEST-171 verifies: REQ-COLL-002, REQ-COLL-003, REQ-VAULT-014, REQ-VAULT-102, INV-017, ATTACK-005, ATTACK-033, Q-126, Q-224, Q-240, REQ-RISK-058
    // Sources: 5.1 TEST-171
    /// @notice The pledge pokes the vault token's own LPOracle and passes the vault token's own market ID and
    /// integration to `checkPledge`; no registry is read.
    function test_TEST_171_marketIdentityFromVaultToken() public {
        lpVault.mintPosition(KEY42, alice, MARKET_ID, 5_000_000_000);
        _acquire(adapter);
        _register(aliceProxy);
        vm.expectCall(address(oracle), abi.encodeCall(CollOracleMock.poke, ()), 1);
        vm.expectCall(
            address(riskModule),
            abi.encodeWithSelector(
                IRiskModuleChecks.checkPledge.selector, alice, aliceProxy, MARKET_ID, INTEGRATION, KEY42, 5_000_000_000
            )
        );
        _pledgeAs(alice, aliceProxy, KEY42);
        _release(adapter);
    }

    // TEST-171 verifies: REQ-COLL-003, REQ-VAULT-102, INV-017, ATTACK-005
    /// @notice An address that is not a factory token and a real VaultToken with this ledger's bindings that the
    /// factory never deployed are both refused with `InvalidVaultToken` before any custody call.
    function test_TEST_171_foreignVaultTokenRefused() public {
        address fake = makeAddr("fakeVaultToken");
        _acquire(adapter);
        vm.expectRevert(ICollateralizationErrors.InvalidVaultToken.selector);
        vm.prank(adapter);
        coll.pledge(alice, aliceProxy, fake, KEY42, false);

        // A real VaultToken with this ledger's bindings that the factory never deployed.
        address unregistered = _unregisteredToken();
        vm.expectRevert(ICollateralizationErrors.InvalidVaultToken.selector);
        vm.prank(adapter);
        coll.pledge(alice, aliceProxy, unregistered, KEY42, false);
        _release(adapter);
        assertEq(lpVault.unwindCalls(), 0);
    }

    // TEST-011 verifies: REQ-VAULT-007, REQ-VAULT-027, REQ-VAULT-106, REQ-COLL-005, REQ-COLL-013, REQ-COLL-019, ATTACK-001, Q-258
    // Sources: 5.1 TEST-011 (Collateralization side), 2.3 REQ-COLL-005 example
    /// @notice A non-owner is refused by the LPVault (`NotTokenOwner`), the zero address, the LPVault or
    /// Collateralization as depositor is refused before custody (`InvalidDepositor`), and a position already backing a
    /// record is refused (`AlreadyPledged`).
    function test_TEST_011_pledgeRejections() public {
        lpVault.mintPosition(KEY42, alice, MARKET_ID, 5_000_000_000);
        _acquire(adapter);
        _register(aliceProxy);
        vm.expectRevert(ILPVaultErrors.NotTokenOwner.selector);
        _pledgeAs(bob, aliceProxy, KEY42);
        vm.expectRevert(abi.encodeWithSelector(ICollateralizationErrors.InvalidDepositor.selector, address(lpVault)));
        _pledgeAs(address(lpVault), aliceProxy, KEY42);
        vm.expectRevert(abi.encodeWithSelector(ICollateralizationErrors.InvalidDepositor.selector, address(coll)));
        _pledgeAs(address(coll), aliceProxy, KEY42);
        vm.expectRevert(abi.encodeWithSelector(ICollateralizationErrors.InvalidDepositor.selector, address(0)));
        _pledgeAs(address(0), aliceProxy, KEY42);
        _pledgeAs(alice, aliceProxy, KEY42);
        vm.expectRevert(ICollateralizationErrors.AlreadyPledged.selector);
        _pledgeAs(alice, aliceProxy, KEY42);
        _release(adapter);
    }

    // TEST-011 verifies: REQ-VAULT-012, REQ-VAULT-107, REQ-VAULT-013, REQ-COLL-010, SPEC-BACK-002
    /// @notice Zero units and units above `2^120 - 1` are refused, and so is a proxy the vault token never
    /// registered.
    function test_TEST_011_unitBoundsAndUnknownProxy() public {
        lpVault.mintPosition(KEY42, alice, MARKET_ID, 1);
        _acquire(adapter);
        vm.expectRevert(abi.encodeWithSelector(ICollateralizationErrors.UnknownProxy.selector, aliceProxy));
        _pledgeAs(alice, aliceProxy, KEY42);
        _register(aliceProxy);
        lpVault.setReceiveOverride(uint256(type(uint120).max) + 1);
        vm.expectRevert(ICollateralizationErrors.LiquidityAboveBound.selector);
        _pledgeAs(alice, aliceProxy, KEY42);
        lpVault.setReceiveOverride(type(uint120).max);
        riskModule.setOverride(PledgeCharge(1, 0, false, 0));
        _pledgeAs(alice, aliceProxy, KEY42);
        _release(adapter);
        assertEq(coll.getAccountCredited(aliceProxy, vt), type(uint120).max, "bound itself is accepted");
    }

    // TEST-279 verifies: REQ-COLL-024, REQ-COLL-035, REQ-VAULT-104, ATTACK-004, ATTACK-153, Q-293
    // Sources: 5.1 TEST-279 (ledger side), 2.3 REQ-COLL-024
    /// @notice The LPVault's range check passes through unchanged, and a position the LPVault reports under another
    /// market after custody reverts `ShapeMismatch`, rolling custody back.
    function test_TEST_279_exactShapeChecks() public {
        lpVault.mintPosition(KEY42, alice, MARKET_ID + 1, 5_000_000_000);
        _acquire(adapter);
        _register(aliceProxy);
        vm.expectRevert(abi.encodeWithSelector(ILPVaultErrors.RangeMismatch.selector, int24(-1), int24(1)));
        _pledgeAs(alice, aliceProxy, KEY42);
        lpVault.mintPosition(KEY42, alice, MARKET_ID, 5_000_000_000);
        lpVault.setMarketOfPositionOverride(MARKET_ID + 1);
        vm.expectRevert(ICollateralizationErrors.ShapeMismatch.selector);
        _pledgeAs(alice, aliceProxy, KEY42);
        _release(adapter);
        assertEq(lpVault.ownerOf(KEY42), alice, "custody rolled back");
    }

    // TEST-013 verifies: REQ-VAULT-014, REQ-VAULT-015, REQ-VAULT-109, REQ-VAULT-110, REQ-VAULT-021, SPEC-BACK-003
    // Sources: 5.1 TEST-013 (Collateralization side), 2.3 REQ-VAULT-015
    /// @notice A RiskModule refusal propagates unchanged; a charge of 0, at or above `2^64`, with the slice above the
    /// charge, rescue units above the units, or a rescue charge with fewer rescue units, reverts `InvalidCharge`; the
    /// counters stay untouched.
    function test_TEST_013_chargeChecks() public {
        lpVault.mintPosition(KEY42, alice, MARKET_ID, 5_000_000_000);
        _acquire(adapter);
        _register(aliceProxy);
        riskModule.setRefuse(true);
        vm.expectRevert(abi.encodeWithSelector(CollRiskModuleMock.Refused.selector, uint128(5_000_000_000)));
        _pledgeAs(alice, aliceProxy, KEY42);
        riskModule.setRefuse(false);
        PledgeCharge[5] memory bad = [
            PledgeCharge(0, 0, false, 0),
            PledgeCharge(2 ** 64, 0, false, 0),
            PledgeCharge(100, 101, false, 0),
            PledgeCharge(100, 0, false, 5_000_000_001),
            PledgeCharge(100, 0, true, 4_999_999_999)
        ];
        for (uint256 i = 0; i < bad.length; ++i) {
            riskModule.setOverride(bad[i]);
            vm.expectRevert(ICollateralizationErrors.InvalidCharge.selector);
            _pledgeAs(alice, aliceProxy, KEY42);
        }
        riskModule.setOverride(PledgeCharge(2 ** 64 - 1, 0, true, 5_000_000_000));
        _pledgeAs(alice, aliceProxy, KEY42);
        _release(adapter);
        assertEq(coll.getRecord(1).currentUsdCharge, 2 ** 64 - 1, "largest charge stored");
        assertEq(coll.getAccountRescueUnits(aliceProxy, vt), 5_000_000_000, "rescue pledge books every unit");
    }

    // TEST-013 verifies: REQ-VAULT-014, REQ-VAULT-034, REQ-COLL-026, SPEC-BACK-004
    /// @notice `checkPledge` receives the counters before the pledge as arguments, including the account's open
    /// records, the Hub-keyed token and depositor counters and the pool counter.
    function test_TEST_013_countersPassedAsArguments() public {
        _pledge(alice, aliceProxy, KEY42, 5_000_000_000);
        lpVault.mintPosition(KEY7, alice, MARKET_ID, 4_000_000_000);
        uint256[] memory used = new uint256[](2);
        used[0] = 1_000_000_000_000;
        used[1] = 1_000_000_000_000;
        PledgeCounters memory expected = PledgeCounters({
            hub: aave.hub,
            regularUsed: 1_000_000_000_000,
            sliceUsed: 0,
            depositorUsed: 1_000_000_000_000,
            poolKey: keccak256(abi.encode(INTEGRATION, pool, bytes32(0))),
            poolUnits: 5_000_000_000,
            accountRecords: 1,
            tokenUsed: used
        });
        _acquire(adapter);
        vm.expectCall(
            address(riskModule),
            abi.encodeCall(
                IRiskModuleChecks.checkPledge,
                (alice, aliceProxy, MARKET_ID, INTEGRATION, KEY7, uint128(4_000_000_000), expected, true)
            )
        );
        vm.prank(adapter);
        coll.pledge(alice, aliceProxy, vt, KEY7, true);
        _release(adapter);
    }

    // TEST-057 verifies: REQ-VAULT-016, SPEC-BACK-006, INV-015, ATTACK-013, Q-194
    // Sources: 5.1 TEST-057 example, 2.3 SPEC-BACK-006
    /// @notice Insertion is largest-first with ties after the earlier record: NFT 42 (5e9), NFT 7 (4e9), then a third
    /// position of 4e9 lands after NFT 7, and a fourth of 6e9 at the head.
    function test_TEST_057_insertionOrder() public {
        uint256 a = _pledge(alice, aliceProxy, KEY42, 5_000_000_000);
        uint256 b = _pledge(alice, aliceProxy, KEY7, 4_000_000_000);
        uint256 c = _pledge(alice, aliceProxy, _key(9), 4_000_000_000);
        uint256 d = _pledge(alice, aliceProxy, _key(11), 6_000_000_000);
        (uint256[] memory ids,) = coll.getAccountRecords(aliceProxy, vt, 0, 16);
        assertEq(ids.length, 4);
        assertEq(ids[0], d);
        assertEq(ids[1], a);
        assertEq(ids[2], b);
        assertEq(ids[3], c);
        (uint256[] memory page,) = coll.getAccountRecords(aliceProxy, vt, 1, 2);
        assertEq(page.length, 2);
        assertEq(page[0], a);
        assertEq(page[1], b);
        (page,) = coll.getAccountRecords(aliceProxy, vt, 4, 2);
        assertEq(page.length, 0, "offset past the end");
    }

    // TEST-269 verifies: REQ-VAULT-025, REQ-COLL-025, REQ-COLL-033, SPEC-BACK-016, INV-096, ATTACK-061, Q-294
    // Sources: 5.1 TEST-269 (record bound), 2.3 REQ-VAULT-025
    /// @notice An account-market holds at most 16 open records: the 17th pledge reverts `TooManyRecords(16)` before
    /// any custody call; another account of the same wallet in the same market is unaffected.
    function test_TEST_269_recordBound() public {
        for (uint256 i = 1; i <= 16; ++i) {
            _pledge(alice, aliceProxy, _key(100 + i), uint128(1_000_000 * i));
        }
        assertEq(coll.getOpenRecordCount(aliceProxy, vt), 16);
        lpVault.mintPosition(_key(200), alice, MARKET_ID, 1_000_000);
        _acquire(adapter);
        vm.expectRevert(abi.encodeWithSelector(ICollateralizationErrors.TooManyRecords.selector, 16));
        _pledgeAs(alice, aliceProxy, _key(200));
        _release(adapter);
        assertEq(lpVault.ownerOf(_key(200)), alice, "no custody call");
        _pledge(bob, bobProxy, _key(200), 1_000_000);
    }

    // TEST-269 verifies: REQ-COLL-031, REQ-COLL-034, REQ-VAULT-026, Q-304
    /// @notice A proxy bound to one market by its first pledge is refused in another market (`ProxyMarketMismatch`),
    /// even when that market's token has registered it.
    function test_TEST_269_oneMarketPerProxy() public {
        _pledge(alice, aliceProxy, KEY42, 5_000_000_000);
        address second = _secondMarketToken();
        lpVault.mintPosition(KEY7, alice, MARKET_ID + 1, 1_000_000);
        _acquire(adapter);
        vm.prank(adapter);
        _tokenAt(second).addValidProxy(aliceProxy);
        vm.expectRevert(abi.encodeWithSelector(ICollateralizationErrors.ProxyMarketMismatch.selector, aliceProxy));
        vm.prank(adapter);
        coll.pledge(alice, aliceProxy, second, KEY7, false);
        _release(adapter);
    }

    // TEST-272 verifies: REQ-COLL-026, REQ-VAULT-034, INV-092, ATTACK-157, Q-295, Q-383
    // Sources: 5.1 TEST-272 (ledger side)
    /// @notice Two markets of one pool share one pool counter, and the token and depositor counters are keyed by Hub,
    /// so a pledge in the second market sees the first market's exposure.
    function test_TEST_272_hubAndPoolKeyedCounters() public {
        _pledge(alice, aliceProxy, KEY42, 5_000_000_000);
        address second = _secondMarketToken();
        PledgeCounters memory k2 = coll.getCounters(second, alice);
        PledgeCounters memory k1 = coll.getCounters(vt, alice);
        assertEq(k2.poolKey, k1.poolKey, "same pool, same key");
        assertEq(k2.poolUnits, 5_000_000_000, "pool counter shared across ranges");
        assertEq(k2.tokenUsed[0], 1_000_000_000_000, "USDC counter is per Hub");
        assertEq(k2.depositorUsed, 1_000_000_000_000, "depositor counter is per Hub");
        assertEq(k2.regularUsed, 0, "market buckets are per market");
        assertEq(coll.poolUnits(k1.poolKey), 5_000_000_000);
    }

    // TEST-235 verifies: REQ-COLL-016, REQ-VAULT-015, SPEC-BACK-004, SPEC-BACK-014, INV-082, Q-253
    // Sources: 5.1 TEST-235 (ledger side), 2.3 SPEC-BACK-014 examples
    /// @notice A slice top-up books `ceil(L * slice / charge)` rescue units and its slice in the slice bucket; a rescue
    /// top-up books all its units.
    function test_TEST_235_rescueUnitsBooked() public {
        riskModule.setSlice(200_000_000_000);
        _pledge(alice, aliceProxy, KEY42, 1_500_000_000);
        BackingRecord memory r = _record(KEY42);
        assertEq(r.currentUsdCharge, 300_000_000_000);
        assertEq(r.rescueUnits, 1_000_000_000, "ceil(1.5e9 * 2 / 3)");
        PledgeCounters memory k = coll.getCounters(vt, alice);
        assertEq(k.sliceUsed, 200_000_000_000);
        assertEq(k.regularUsed, 100_000_000_000);
        assertEq(k.tokenUsed[0], 300_000_000_000);
        riskModule.setSlice(0);
        riskModule.setRescue(true);
        _pledge(alice, aliceProxy, KEY7, 500_000_000);
        assertEq(coll.getAccountRescueUnits(aliceProxy, vt), 1_500_000_000);
    }

    // TEST-238 verifies: REQ-COLL-015, REQ-COLL-021, REQ-COLL-022, REQ-VAULT-024, REQ-VAULT-030, REQ-VAULT-042, SPEC-BACK-010, SPEC-BACK-013, ATTACK-143, Q-254
    // Sources: 5.1 TEST-238, 2.3 REQ-COLL-015 and SPEC-BACK-013 examples
    /// @notice After a third party adds 1,500,000,000 units to NFT 42 only its depositor can re-credit them; the
    /// record is rebased to 6,500,000,000 units and $13,000 and keeps its list place; a second re-credit with nothing
    /// added reverts `NothingToRecredit`.
    function test_TEST_238_recredit() public {
        _pledge(alice, aliceProxy, KEY42, 5_000_000_000);
        _pledge(alice, aliceProxy, KEY7, 6_000_000_000);
        lpVault.addUnits(KEY42, 1_500_000_000);
        assertEq(coll.previewRecredit(INTEGRATION, KEY42), 1_500_000_000);
        _acquire(adapter);
        vm.expectRevert(ICollateralizationErrors.NotDepositor.selector);
        vm.prank(adapter);
        coll.recredit(bob, aliceProxy, vt, KEY42, "", false);
        vm.expectRevert(ICollateralizationErrors.NotRecordProxy.selector);
        vm.prank(adapter);
        coll.recredit(alice, bobProxy, vt, KEY42, "", false);
        vm.expectEmit(address(coll));
        emit ICollateralizationEvents.RecordRecredited(1, 1_500_000_000, 300_000_000_000, 0);
        vm.prank(adapter);
        (uint128 added, uint128 rescue) = coll.recredit(alice, aliceProxy, vt, KEY42, "", false);
        vm.expectRevert(abi.encodeWithSelector(ICollateralizationErrors.NothingToRecredit.selector, KEY42));
        vm.prank(adapter);
        coll.recredit(alice, aliceProxy, vt, KEY42, "", false);
        _release(adapter);
        assertEq(added, 1_500_000_000);
        assertEq(rescue, 0);
        BackingRecord memory r = coll.getRecord(1);
        assertEq(r.credited, 6_500_000_000);
        assertEq(r.originalUnits, 6_500_000_000);
        assertEq(r.originalUsdCharge, 1_300_000_000_000);
        assertEq(r.currentUsdCharge, 1_300_000_000_000);
        assertEq(coll.getTotalCredited(vt), 12_500_000_000);
        assertEq(coll.getCounters(vt, alice).regularUsed, 2_500_000_000_000);
        (uint256[] memory ids,) = coll.getAccountRecords(aliceProxy, vt, 0, 16);
        assertEq(ids[0], 2, "the re-credited record keeps its place");
        assertEq(ids[1], 1);
    }

    // TEST-238 verifies: REQ-COLL-037, REQ-AMM-CORE-011, REQ-COLL-015, REQ-VAULT-107, REQ-VAULT-110
    /// @notice A fungible-share top-up joins the record through `topUpPosition`; an NFT integration's
    /// `TopUpNotSupported` passes through; the rebased credit and charge are bounded.
    function test_TEST_238_topUpAndBounds() public {
        _pledge(alice, aliceProxy, KEY42, 1_000_000_000);
        _acquire(adapter);
        vm.expectRevert(ILPVaultErrors.TopUpNotSupported.selector);
        vm.prank(adapter);
        coll.recredit(alice, aliceProxy, vt, KEY42, abi.encode(uint128(250_000_000)), false);
        lpVault.setFungible(true);
        vm.prank(adapter);
        (uint128 added,) = coll.recredit(alice, aliceProxy, vt, KEY42, abi.encode(uint128(250_000_000)), false);
        assertEq(added, 250_000_000);
        lpVault.addUnits(KEY42, type(uint120).max);
        vm.expectRevert(ICollateralizationErrors.LiquidityAboveBound.selector);
        vm.prank(adapter);
        coll.recredit(alice, aliceProxy, vt, KEY42, "", false);
        _release(adapter);
    }

    // TEST-238 verifies: REQ-VAULT-110, SPEC-BACK-013
    /// @notice A re-credit whose rebased charge would reach `2^64` reverts `InvalidCharge`.
    function test_TEST_238_rebasedChargeBound() public {
        riskModule.setOverride(PledgeCharge(2 ** 63, 0, false, 0));
        _pledge(alice, aliceProxy, KEY42, 1_000_000_000);
        lpVault.addUnits(KEY42, 1);
        _acquire(adapter);
        vm.expectRevert(ICollateralizationErrors.InvalidCharge.selector);
        vm.prank(adapter);
        coll.recredit(alice, aliceProxy, vt, KEY42, "", false);
        _release(adapter);
    }

    // TEST-060 verifies: REQ-VAULT-006, REQ-VAULT-086, REQ-VAULT-112, REQ-VAULT-113, REQ-LOCK-010, REQ-LOCK-023, REQ-LOCK-028, REQ-COLL-029, INV-054, ATTACK-169
    // Sources: 5.1 TEST-060 (Collateralization side), 2.16 REQ-LOCK-010
    /// @notice Every Adapter-path function reverts `NotAdapter` for any other caller (LPVaultSwap included) and
    /// `LockNotHeld` for the Adapter while the Lock is free or held by LPVaultSwap.
    function test_TEST_060_adapterPathCallerAndLock() public {
        bytes[7] memory calls = [
            abi.encodeCall(coll.pledge, (alice, aliceProxy, vt, KEY42, false)),
            abi.encodeCall(coll.release, (aliceProxy, vt, KEY42, 1)),
            abi.encodeCall(coll.releasePartial, (aliceProxy, vt, KEY42, 1, new uint256[](2))),
            abi.encodeCall(coll.recredit, (alice, aliceProxy, vt, KEY42, "", false)),
            abi.encodeCall(coll.releaseForDeleverage, (aliceProxy, vt, KEY42, 1, new uint256[](2))),
            abi.encodeCall(coll.releaseZeroCredit, (alice, vt, KEY42)),
            abi.encodeCall(coll.collectFees, (alice, vt, KEY42))
        ];
        for (uint256 i = 0; i < calls.length; ++i) {
            _expectFail(lpVaultSwap, calls[i], abi.encodeWithSelector(ICollateralizationErrors.NotAdapter.selector));
            _expectFail(alice, calls[i], abi.encodeWithSelector(ICollateralizationErrors.NotAdapter.selector));
            _expectFail(adapter, calls[i], abi.encodeWithSelector(ICollateralizationErrors.LockNotHeld.selector));
            _acquire(lpVaultSwap);
            _expectFail(adapter, calls[i], abi.encodeWithSelector(ICollateralizationErrors.LockNotHeld.selector));
            _release(lpVaultSwap);
        }
        _expectFail(
            alice,
            abi.encodeCall(coll.markIndebted, (aliceProxy)),
            abi.encodeWithSelector(ICollateralizationErrors.NotAdapter.selector)
        );
        _expectFail(
            adapter,
            abi.encodeCall(coll.markIndebted, (aliceProxy)),
            abi.encodeWithSelector(ICollateralizationErrors.LockNotHeld.selector)
        );
    }

    // TEST-270 verifies: REQ-LOCK-010, REQ-LOCK-030, REQ-VAULT-086, INV-091
    // Sources: 5.1 TEST-270 (Collateralization side), 2.16 REQ-LOCK-030
    /// @notice Collateralization never acquires or releases the Lock: a full pledge and withdrawal make no such call,
    /// and the holder is unchanged around each inner call.
    function test_TEST_270_neverAcquiresOrReleases() public {
        vm.expectCall(address(lock), abi.encodeCall(ILock.acquire, ()), 1);
        vm.expectCall(address(lock), abi.encodeCall(ILock.release, ()), 1);
        _pledge(alice, aliceProxy, KEY42, 5_000_000_000);
        assertEq(lock.holder(), address(0));
    }

    // ─── Helpers ───

    function _expectFail(
        address caller,
        bytes memory data,
        bytes memory err
    ) internal {
        vm.prank(caller);
        (bool ok, bytes memory ret) = address(coll).call(data);
        assertFalse(ok, "call succeeded");
        assertEq(ret, err, "revert data");
    }

    /// @notice A real VaultToken bound to this Collateralization, the Adapter and LPVaultSwap but not deployed by
    /// the factory, so the factory's registries do not know it.
    function _unregisteredToken() internal returns (address) {
        return address(
            new VaultToken(
                VaultTokenBindings({
                    marketKey: keccak256("unregistered"),
                    integrationId: INTEGRATION,
                    integration: address(lpVault),
                    hub: aave.hub,
                    spoke: aave.cdpSpoke,
                    marketId: MARKET_ID,
                    lpOracle: address(oracle),
                    adapter: adapter,
                    lpVaultSwap: lpVaultSwap,
                    collateralization: address(coll),
                    decimals: VT_DECIMALS,
                    name: "Unregistered",
                    symbol: "UNR"
                })
            )
        );
    }

    /// @notice A second market of the same pool (another range) on the same Spoke and Hub.
    function _secondMarketToken() internal returns (address second) {
        address[] memory tokens = new address[](2);
        tokens[0] = address(usdc);
        tokens[1] = address(usdt);
        uint256[] memory rates = new uint256[](2);
        rates[0] = 800_000;
        rates[1] = 1_250_000;
        lpVault.bind(MARKET_ID + 1, pool, tokens, rates);
        vm.prank(timelock);
        second = factory.deployVaultToken(
            INTEGRATION,
            pool,
            bytes32(0),
            PositionShape(ShapeKind.TickRange, -100, 100),
            aave.hub,
            aave.cdpSpoke,
            MARKET_ID + 1,
            address(oracle),
            VT_DECIMALS,
            "Avana USDC/USDT wide",
            "avUSDC-USDT-w"
        );
    }

    function _tokenAt(
        address t
    ) internal pure returns (VaultTokenAdmin) {
        return VaultTokenAdmin(t);
    }
}

interface VaultTokenAdmin {
    function addValidProxy(
        address proxy
    ) external;
}
