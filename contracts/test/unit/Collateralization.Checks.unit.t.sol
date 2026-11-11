// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ICollateralizationErrors} from "../../src/custody/collateralization/ICollateralizationErrors.sol";
import {ICollateralizationEvents} from "../../src/custody/collateralization/ICollateralizationEvents.sol";
import {BackingRecord} from "../../src/custody/collateralization/types/BackingRecord.sol";
import {ILPVaultErrors} from "../../src/custody/lp-vault/ILPVaultErrors.sol";
import {IAaveV4Spoke} from "../../src/interfaces/external/aave/IAaveV4Spoke.sol";
import {PledgeCharge} from "../../src/policy/risk-module/types/PledgeCharge.sol";
import {PositionShape} from "../../src/types/PositionShape.sol";
import {ShapeKind} from "../../src/types/ShapeKind.sol";
import {CollateralizationFixture} from "../utils/fixtures/CollateralizationFixture.sol";
import {CollOracleMock, CollRiskModuleMock} from "../utils/mocks/CollateralizationMocks.sol";

/// @title CollateralizationChecksUnitTest
/// @notice Which check refuses a call when several apply, and that a refused call writes nothing: the pledge's
/// validation before custody, the charge checks after it, a refusal by the RiskModule or the LPOracle, the exits on a
/// record of another market, the deleverage and partial-removal unit bounds, and the pool lock on exits that remove
/// liquidity.
/// forge-config: default.isolate = false
contract CollateralizationChecksUnitTest is CollateralizationFixture {
    bytes32 internal constant KEY42 = bytes32(uint256(42));
    bytes32 internal constant KEY7 = bytes32(uint256(7));

    function setUp() public {
        _deployCollateralization();
    }

    // TEST-011 verifies: REQ-COLL-003, REQ-COLL-005, REQ-COLL-010, REQ-VAULT-007, REQ-VAULT-013, REQ-VAULT-102, ATTACK-005
    // Sources: 2.3 REQ-COLL-003 (the vault token first), REQ-COLL-005, REQ-VAULT-013
    /// @notice The vault token is checked before the depositor, the depositor before the proxy, and a zero proxy is an
    /// unknown proxy; no custody call happens for any of them.
    function test_TEST_011_validationOrderBeforeCustody() public {
        lpVault.mintPosition(KEY42, alice, MARKET_ID, 5_000_000_000);
        _acquire(adapter);
        _expectPledgeFail(
            address(0),
            aliceProxy,
            makeAddr("notAToken"),
            KEY42,
            abi.encodeWithSelector(ICollateralizationErrors.InvalidVaultToken.selector)
        );
        _expectPledgeFail(
            address(0),
            makeAddr("unregistered"),
            vt,
            KEY42,
            abi.encodeWithSelector(ICollateralizationErrors.InvalidDepositor.selector, address(0))
        );
        _expectPledgeFail(
            alice,
            address(0),
            vt,
            KEY42,
            abi.encodeWithSelector(ICollateralizationErrors.UnknownProxy.selector, address(0))
        );
        _release(adapter);
        assertEq(lpVault.ownerOf(KEY42), alice, "no custody call");
        assertEq(coll.nextRecordId(), 1, "no record ID used");
    }

    // TEST-269 verifies: REQ-COLL-025, REQ-COLL-031, REQ-VAULT-025, REQ-VAULT-027, REQ-VAULT-106, Q-294, Q-304
    // Sources: 2.3 REQ-COLL-025 (record bound before custody), REQ-COLL-031
    /// @notice With sixteen records open, re-pledging one of them reverts `AlreadyPledged` (checked before the bound),
    /// a new position reverts `TooManyRecords(16)` even while the pool is locked (no read-safety call before the bound),
    /// and a proxy bound to another market reverts `ProxyMarketMismatch` before the record checks.
    function test_TEST_269_boundChecksBeforeCustody() public {
        for (uint256 i = 0; i < 16; ++i) {
            _pledge(alice, aliceProxy, _key(100 + i), 1_000_000);
        }
        lpVault.mintPosition(KEY42, alice, MARKET_ID, 1_000_000);
        lpVault.setPoolLocked(true);
        _acquire(adapter);
        _expectPledgeFail(
            alice, aliceProxy, vt, _key(100), abi.encodeWithSelector(ICollateralizationErrors.AlreadyPledged.selector)
        );
        _expectPledgeFail(
            alice, aliceProxy, vt, KEY42, abi.encodeWithSelector(ICollateralizationErrors.TooManyRecords.selector, 16)
        );
        address second = _secondMarketToken();
        _addValidProxy(second, aliceProxy);
        _expectPledgeFail(
            alice,
            aliceProxy,
            second,
            _key(100),
            abi.encodeWithSelector(ICollateralizationErrors.ProxyMarketMismatch.selector, aliceProxy)
        );
        _release(adapter);
        lpVault.setPoolLocked(false);
        assertEq(lpVault.ownerOf(KEY42), alice, "no custody call");
    }

    // TEST-011 verifies: REQ-COLL-024, REQ-VAULT-012, REQ-VAULT-107, SPEC-BACK-002
    // Sources: 2.3 REQ-COLL-024 (read safety, then custody), REQ-VAULT-012
    /// @notice With fifteen records the pool lock refuses the pledge in `checkReadSafe` before custody; units above
    /// `2^120 - 1` are refused before the shape check; a wrong shape is refused before the charge.
    function test_TEST_011_postCustodyCheckOrder() public {
        lpVault.mintPosition(KEY42, alice, MARKET_ID, 5_000_000_000);
        lpVault.setPoolLocked(true);
        _acquire(adapter);
        _register(aliceProxy);
        _expectPledgeFail(alice, aliceProxy, vt, KEY42, abi.encodeWithSelector(ILPVaultErrors.PoolLocked.selector));
        lpVault.setPoolLocked(false);
        lpVault.setReceiveOverride(uint256(type(uint120).max) + 1);
        lpVault.setMarketOfPositionOverride(MARKET_ID + 9);
        riskModule.setRefuse(true);
        _expectPledgeFail(
            alice, aliceProxy, vt, KEY42, abi.encodeWithSelector(ICollateralizationErrors.LiquidityAboveBound.selector)
        );
        lpVault.setReceiveOverride(type(uint120).max);
        _expectPledgeFail(
            alice, aliceProxy, vt, KEY42, abi.encodeWithSelector(ICollateralizationErrors.ShapeMismatch.selector)
        );
        lpVault.setMarketOfPositionOverride(0);
        _expectPledgeFail(
            alice,
            aliceProxy,
            vt,
            KEY42,
            abi.encodeWithSelector(CollRiskModuleMock.Refused.selector, uint128(type(uint120).max))
        );
        _release(adapter);
        assertEq(coll.recordIdOf(INTEGRATION, KEY42), 0, "no record");
        assertEq(lpVault.ownerOf(KEY42), alice, "custody undone with the revert");
    }

    // TEST-013 verifies: REQ-VAULT-015, REQ-VAULT-110, SPEC-BACK-002, SPEC-BACK-003
    // Sources: 2.3 REQ-VAULT-015 (0 < usdCharge < 2^64), SPEC-BACK-016 (uint120 credited bound)
    /// @notice The largest credit (`2^120 - 1` units) with the largest charge (`2^64 - 1`) is booked exactly; a charge
    /// of `2^64` is refused.
    function test_TEST_013_extremeCreditAndCharge() public {
        uint128 maxUnits = type(uint120).max;
        lpVault.mintPosition(KEY42, alice, MARKET_ID, maxUnits);
        riskModule.setOverride(PledgeCharge({usdCharge: 2 ** 64, sliceUsd: 0, rescue: false, rescueUnits: 0}));
        _acquire(adapter);
        _register(aliceProxy);
        _expectPledgeFail(
            alice, aliceProxy, vt, KEY42, abi.encodeWithSelector(ICollateralizationErrors.InvalidCharge.selector)
        );
        riskModule.setOverride(
            PledgeCharge({usdCharge: type(uint64).max, sliceUsd: type(uint64).max, rescue: true, rescueUnits: maxUnits})
        );
        vm.prank(adapter);
        (uint256 id, uint128 credited) = coll.pledge(alice, aliceProxy, vt, KEY42, true);
        _release(adapter);
        assertEq(credited, maxUnits);
        BackingRecord memory r = coll.getRecord(id);
        assertEq(r.credited, maxUnits);
        assertEq(r.originalUsdCharge, type(uint64).max);
        assertEq(r.rescueUnits, maxUnits);
        assertEq(coll.getCounters(vt, alice).sliceUsed, type(uint64).max, "all of it in the slice");
        assertEq(coll.getCounters(vt, alice).regularUsed, 0);
        assertEq(coll.getAccountRescueUnits(aliceProxy, vt), maxUnits);
    }

    // TEST-171 verifies: REQ-COLL-002, REQ-VAULT-014, Q-199
    // Sources: 2.3 REQ-VAULT-014 (the pledge pokes the market's LPOracle)
    /// @notice A pledge whose LPOracle poke reverts reverts whole, with the oracle's error, and writes nothing; a
    /// re-credit pokes too.
    function test_TEST_171_failingPokeRevertsThePledge() public {
        lpVault.mintPosition(KEY42, alice, MARKET_ID, 5_000_000_000);
        oracle.setFail(true);
        _acquire(adapter);
        _register(aliceProxy);
        _expectPledgeFail(alice, aliceProxy, vt, KEY42, abi.encodeWithSelector(CollOracleMock.PokeFailed.selector));
        _release(adapter);
        assertEq(coll.getTotalCredited(vt), 0);
        oracle.setFail(false);
        _pledge(alice, aliceProxy, KEY42, 5_000_000_000);
        lpVault.addUnits(KEY42, 1_000_000);
        oracle.setFail(true);
        _acquire(adapter);
        vm.expectRevert(CollOracleMock.PokeFailed.selector);
        vm.prank(adapter);
        coll.recredit(alice, aliceProxy, vt, KEY42, "", false);
        _release(adapter);
        assertEq(coll.getRecord(1).credited, 5_000_000_000, "no re-credit");
    }

    // TEST-018 verifies: REQ-VAULT-068, REQ-VAULT-102, REQ-VAULT-113, REQ-COLL-003, REQ-COLL-031
    // Sources: 2.3 REQ-VAULT-068 (the record's market), REQ-COLL-003
    /// @notice Every exit and the re-credit name the record's own market: called with another registered market's
    /// vault token on a record of the first market, each reverts `InvalidVaultToken` and the record is unchanged.
    function test_TEST_018_exitsOnAnotherMarketRefused() public {
        _pledge(alice, aliceProxy, KEY42, 5_000_000_000);
        address second = _secondMarketToken();
        uint256[] memory mins = new uint256[](2);
        bytes[6] memory calls = [
            abi.encodeCall(coll.release, (aliceProxy, second, KEY42, 5_000_000_000)),
            abi.encodeCall(coll.releasePartial, (aliceProxy, second, KEY42, 1, mins)),
            abi.encodeCall(coll.recredit, (alice, aliceProxy, second, KEY42, "", false)),
            abi.encodeCall(coll.releaseForDeleverage, (aliceProxy, second, KEY42, 1, mins)),
            abi.encodeCall(coll.releaseZeroCredit, (alice, second, KEY42)),
            abi.encodeCall(coll.collectFees, (alice, second, KEY42))
        ];
        _acquire(adapter);
        for (uint256 i = 0; i < calls.length; ++i) {
            vm.prank(adapter);
            (bool ok, bytes memory ret) = address(coll).call(calls[i]);
            assertFalse(ok, "exit on another market");
            assertEq(ret, abi.encodeWithSelector(ICollateralizationErrors.InvalidVaultToken.selector));
        }
        _release(adapter);
        assertEq(coll.getRecord(1).credited, 5_000_000_000);
        assertEq(lpVault.ownerOf(KEY42), address(lpVault));
    }

    // TEST-239 verifies: REQ-COLL-017, REQ-VAULT-069, REQ-VAULT-143, REQ-COLL-028
    // Sources: 2.3 REQ-COLL-017 (0 < units <= credited), REQ-COLL-028
    /// @notice `releaseForDeleverage` refuses 0 units and one unit above the credit, refuses a minimums array of the
    /// wrong length and a locked pool, and accepts exactly the credit (closing the record and emitting both events).
    function test_TEST_239_deleverageUnitBounds() public {
        _pledge(alice, aliceProxy, KEY42, 5_000_000_000);
        _acquire(adapter);
        _withdrawAndBurn(aliceProxy, 5_000_000_000);
        uint256[] memory two = new uint256[](2);
        vm.startPrank(adapter);
        vm.expectRevert(ICollateralizationErrors.UnitsMismatch.selector);
        coll.releaseForDeleverage(aliceProxy, vt, KEY42, 0, two);
        vm.expectRevert(abi.encodeWithSelector(ICollateralizationErrors.LengthMismatch.selector, 2, 1));
        coll.releaseForDeleverage(aliceProxy, vt, KEY42, 5_000_000_000, new uint256[](1));
        lpVault.setPoolLocked(true);
        vm.expectRevert(ILPVaultErrors.PoolLocked.selector);
        coll.releaseForDeleverage(aliceProxy, vt, KEY42, 5_000_000_000, two);
        lpVault.setPoolLocked(false);
        vm.stopPrank();
        // The proxy withdrew 5e9 earlier in this Adapter call, so a claim of 5e9 + 1 units reads a supply of 5e9 + 1 and
        // no shortfall; the unit check refuses it.
        vm.prank(adapter);
        vm.expectRevert(ICollateralizationErrors.UnitsMismatch.selector);
        coll.releaseForDeleverage(aliceProxy, vt, KEY42, 5_000_000_001, two);
        vm.expectEmit(address(coll));
        emit ICollateralizationEvents.RecordReduced(1, 5_000_000_000, 1_000_000_000_000);
        vm.expectEmit(address(coll));
        emit ICollateralizationEvents.CollateralReleased(1, KEY42, alice, aliceProxy, vt, 5_000_000_000);
        vm.prank(adapter);
        (uint256[] memory amounts, bool closed) = coll.releaseForDeleverage(aliceProxy, vt, KEY42, 5_000_000_000, two);
        _release(adapter);
        assertTrue(closed);
        assertEq(amounts[0], 4_000_000_000, "USDC principal to LPVaultSwap");
        assertEq(amounts[1], 6_250_000_000);
        assertEq(usdc.balanceOf(lpVaultSwap), 4_000_000_000);
        assertEq(lpVault.ownerOf(KEY42), alice, "the emptied position returns to its depositor");
        assertEq(coll.getTotalCredited(vt), 0);
        assertEq(coll.getMarketRecordCount(vt), 0);
    }

    // TEST-237 verifies: REQ-COLL-014, REQ-COLL-020, REQ-COLL-028, REQ-VAULT-088, Q-254
    // Sources: 2.3 REQ-COLL-014 (units < credited), REQ-COLL-020
    /// @notice A partial removal of `credited - 1` units keeps one unit and its charge rounded up; the depositor's
    /// minimums are enforced by the LPVault with its exact arguments; a locked pool refuses the removal.
    function test_TEST_237_partialRemovalBoundaries() public {
        _pledge(alice, aliceProxy, KEY42, 5_000_000_000);
        _acquire(adapter);
        _withdrawAndBurn(aliceProxy, 4_999_999_999);
        uint256[] memory mins = new uint256[](2);
        mins[1] = 6_249_999_999;
        vm.prank(adapter);
        vm.expectRevert(abi.encodeWithSelector(ILPVaultErrors.BelowMinimum.selector, 1, 6_249_999_998, 6_249_999_999));
        coll.releasePartial(aliceProxy, vt, KEY42, 4_999_999_999, mins);
        lpVault.setPoolLocked(true);
        vm.prank(adapter);
        vm.expectRevert(ILPVaultErrors.PoolLocked.selector);
        coll.releasePartial(aliceProxy, vt, KEY42, 4_999_999_999, new uint256[](2));
        lpVault.setPoolLocked(false);
        mins[1] = 6_249_999_998;
        vm.expectEmit(address(coll));
        emit ICollateralizationEvents.RecordReduced(1, 4_999_999_999, 999_999_999_800);
        vm.prank(adapter);
        (uint128 remaining, uint256[] memory amounts) = coll.releasePartial(aliceProxy, vt, KEY42, 4_999_999_999, mins);
        _release(adapter);
        assertEq(remaining, 1);
        assertEq(amounts[0], 3_999_999_999, "floor(4,999,999,999 x 0.8)");
        assertEq(amounts[1], 6_249_999_998, "floor(4,999,999,999 x 1.25)");
        BackingRecord memory r = coll.getRecord(1);
        assertEq(r.credited, 1);
        assertEq(r.currentUsdCharge, 200, "ceil(1e12 x 1 / 5e9) = 200");
        assertEq(coll.getCounters(vt, alice).regularUsed, 200);
        assertEq(_gap(), 0);
    }

    // TEST-018 verifies: REQ-VAULT-033, REQ-VAULT-037, REQ-COLL-008
    // Sources: 2.3 REQ-VAULT-037 (exits read no policy), REQ-COLL-008
    /// @notice A withdrawal release is not gated by the pool lock, the RiskModule or the LPOracle: with the pool
    /// locked, the RiskModule refusing and the oracle reverting, the record still closes and the position returns.
    function test_TEST_018_withdrawalIgnoresPoolLockAndPolicy() public {
        _pledge(alice, aliceProxy, KEY42, 5_000_000_000);
        lpVault.setPoolLocked(true);
        riskModule.setRefuse(true);
        oracle.setFail(true);
        _withdraw(aliceProxy, KEY42, 5_000_000_000);
        assertEq(lpVault.ownerOf(KEY42), alice);
        assertEq(coll.recordIdOf(INTEGRATION, KEY42), 0);
    }

    // TEST-020 verifies: REQ-VAULT-059, REQ-VAULT-075, REQ-COLL-022, SPEC-BACK-015
    // Sources: 2.3 REQ-COLL-022 (fees to the depositor of record only)
    /// @notice `collectFees` pays every accrued fee to the depositor of record only, leaves the record and the credit
    /// unchanged, refuses another depositor and a position with no record, and returns zeros once collected.
    function test_TEST_020_collectFeesOnlyToTheDepositor() public {
        _pledge(alice, aliceProxy, KEY42, 5_000_000_000);
        lpVault.accrueFees(KEY42, 7777);
        _acquire(adapter);
        vm.startPrank(adapter);
        vm.expectRevert(ICollateralizationErrors.NotDepositor.selector);
        coll.collectFees(bob, vt, KEY42);
        vm.expectRevert(ICollateralizationErrors.RecordNotFound.selector);
        coll.collectFees(alice, vt, KEY7);
        uint256[] memory amounts = coll.collectFees(alice, vt, KEY42);
        uint256[] memory again = coll.collectFees(alice, vt, KEY42);
        vm.stopPrank();
        _release(adapter);
        assertEq(amounts[0], 7777);
        assertEq(amounts[1], 7777);
        assertEq(again[0] + again[1], 0, "nothing accrued since");
        assertEq(usdc.balanceOf(alice), 7777);
        assertEq(usdt.balanceOf(alice), 7777);
        assertEq(coll.getRecord(1).credited, 5_000_000_000);
        assertEq(_gap(), 0);
    }

    // TEST-238 verifies: REQ-COLL-015, REQ-COLL-021, REQ-COLL-037, REQ-VAULT-074, SPEC-BACK-013
    // Sources: 2.3 REQ-COLL-015, REQ-COLL-037 (the credit is the live units, not the LPVault's report)
    /// @notice A re-credit refuses another proxy and another depositor, credits the live units above the credit (not
    /// the top-up's report), and a second re-credit with nothing new reverts `NothingToRecredit`.
    function test_TEST_238_recreditChecks() public {
        _pledge(alice, aliceProxy, KEY42, 5_000_000_000);
        _pledge(bob, bobProxy, KEY7, 1_000_000_000);
        lpVault.addUnits(KEY42, 1_000_000_000);
        _acquire(adapter);
        vm.startPrank(adapter);
        vm.expectRevert(ICollateralizationErrors.NotRecordProxy.selector);
        coll.recredit(alice, bobProxy, vt, KEY42, "", false);
        vm.expectRevert(ICollateralizationErrors.NotDepositor.selector);
        coll.recredit(bob, aliceProxy, vt, KEY42, "", false);
        lpVault.setFungible(true);
        vm.expectEmit(address(coll));
        emit ICollateralizationEvents.RecordRecredited(1, 1_500_000_000, 300_000_000_000, 0);
        (uint128 added,) = coll.recredit(alice, aliceProxy, vt, KEY42, abi.encode(uint128(500_000_000)), false);
        token.mint(aliceProxy, added);
        vm.stopPrank();
        _supply(aliceProxy, added);
        vm.prank(adapter);
        vm.expectRevert(abi.encodeWithSelector(ICollateralizationErrors.NothingToRecredit.selector, KEY42));
        coll.recredit(alice, aliceProxy, vt, KEY42, "", false);
        _release(adapter);
        assertEq(added, 1_500_000_000, "live units above credit: donation plus top-up");
        assertEq(_gap(), 0);
        assertEq(_shares(aliceProxy), 6_500_000_000);
        BackingRecord memory r = coll.getRecord(1);
        assertEq(r.credited, 6_500_000_000);
        assertEq(r.originalUnits, 6_500_000_000, "basis rebased");
        assertEq(r.originalUsdCharge, 1_300_000_000_000);
    }

    // ─── Helpers ───

    function _expectPledgeFail(
        address depositor,
        address proxy,
        address vaultToken,
        bytes32 key,
        bytes memory err
    ) internal {
        vm.prank(adapter);
        (bool ok, bytes memory ret) =
            address(coll).call(abi.encodeCall(coll.pledge, (depositor, proxy, vaultToken, key, false)));
        assertFalse(ok, "pledge succeeded");
        assertEq(ret, err, "revert data");
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

    function _addValidProxy(
        address vaultToken,
        address proxy
    ) internal {
        vm.prank(adapter);
        IValidProxyRegistry(vaultToken).addValidProxy(proxy);
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
}

interface IValidProxyRegistry {
    function addValidProxy(
        address proxy
    ) external;
}
