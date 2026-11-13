// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ICollateralizationErrors} from "../../src/custody/collateralization/ICollateralizationErrors.sol";
import {ILPVaultErrors} from "../../src/custody/lp-vault/ILPVaultErrors.sol";
import {PledgeCharge} from "../../src/policy/risk-module/types/PledgeCharge.sol";
import {PledgeCounters} from "../../src/types/PledgeCounters.sol";
import {CollateralizationFixture} from "../utils/fixtures/CollateralizationFixture.sol";
import {CollOracleMock, CollRiskModuleMock} from "../utils/mocks/CollateralizationMocks.sol";
import {Vm} from "forge-std/Vm.sol";

/// @title CollateralizationPledgeChargeUnitTest
/// @notice The pledge's calls out of the real Collateralization on the local Aave V4: the market's LPOracle is poked
/// before the RiskModule's `checkPledge` (5.1 TEST-163), the RiskModule gets the ledger's counters as arguments and its
/// returned split is booked as returned, never read back from the ledger while the Lock is held (5.1 TEST-164), the
/// liquidity boundary vectors of a record and a market (5.1 TEST-072), and the pool-lock refusal of the calls that
/// change a position's liquidity (5.1 TEST-116, Collateralization part).
/// forge-config: default.isolate = false
contract CollateralizationPledgeChargeUnitTest is CollateralizationFixture {
    bytes32 internal constant KEY42 = bytes32(uint256(42));
    bytes32 internal constant KEY7 = bytes32(uint256(7));

    function setUp() public {
        _deployCollateralization();
    }

    /// @notice In `pledge` and in `recredit` the call to the LPOracle's `poke()` comes before the call to the
    /// RiskModule's `checkPledge`, so a first observation stored by the poke is in place before the check reads the
    /// state; a poke that reverts reverts the whole pledge and nothing is recorded.
    // TEST-163 verifies: REQ-VAULT-014, REQ-COLL-026, Q-199, Q-240
    function test_TEST_163_pokeBeforeCheckPledge() public {
        lpVault.mintPosition(KEY42, alice, MARKET_ID, 5_000_000_000);
        vm.startPrank(adapter);
        lock.acquire();
        token.addValidProxy(aliceProxy);
        vm.startStateDiffRecording();
        coll.pledge(alice, aliceProxy, vt, KEY42, false);
        _assertPokeFirst(vm.stopAndReturnStateDiff());
        vm.stopPrank();
        _supplyAndRelease(aliceProxy, 5_000_000_000);

        lpVault.addUnits(KEY42, 1_000_000);
        vm.startPrank(adapter);
        lock.acquire();
        vm.startStateDiffRecording();
        coll.recredit(alice, aliceProxy, vt, KEY42, "", false);
        _assertPokeFirst(vm.stopAndReturnStateDiff());
        lock.release();
        vm.stopPrank();

        lpVault.mintPosition(KEY7, alice, MARKET_ID, 1_000_000_000);
        oracle.setFail(true);
        vm.startPrank(adapter);
        lock.acquire();
        vm.expectRevert(CollOracleMock.PokeFailed.selector);
        coll.pledge(alice, aliceProxy, vt, KEY7, false);
        lock.release();
        vm.stopPrank();
        assertEq(coll.recordIdOf(INTEGRATION, KEY7), 0, "nothing recorded");
        assertEq(lpVault.ownerOf(KEY7), alice, "custody undone with the revert");
    }

    /// @notice A second pledge: `checkPledge` receives the depositor, proxy, market, integration, key and units with
    /// the ledger's current counters (the account's one open record counted); the returned split of 7 USD into 4
    /// regular and 3 slice is booked as returned on the market and depositor counters. The RiskModule reading the
    /// ledger while the Lock is held reverts `Locked`. A returned charge the bounds forbid (slice above the charge, a
    /// charge of `2^64`) reverts the pledge with no counter change.
    // TEST-164 verifies: REQ-COLL-026, REQ-VAULT-015, REQ-VAULT-091, SPEC-BACK-004, Q-240
    function test_TEST_164_countersPassedAndReturnedSplitBooked() public {
        _pledge(alice, aliceProxy, KEY7, 1_000_000_000);
        PledgeCounters memory k = coll.getCounters(vt, alice);
        k.accountRecords = 1;
        lpVault.mintPosition(KEY42, alice, MARKET_ID, 5_000_000_000);
        riskModule.setOverride(
            PledgeCharge({usdCharge: 700_000_000, sliceUsd: 300_000_000, rescue: false, rescueUnits: 0})
        );

        vm.startPrank(adapter);
        lock.acquire();
        vm.stopPrank();
        vm.prank(address(riskModule));
        vm.expectRevert(ICollateralizationErrors.Locked.selector);
        coll.getCounters(vt, alice);

        vm.expectCall(
            address(riskModule),
            abi.encodeCall(
                CollRiskModuleMock.checkPledge,
                (alice, aliceProxy, MARKET_ID, INTEGRATION, KEY42, 5_000_000_000, k, false)
            ),
            1
        );
        vm.prank(adapter);
        coll.pledge(alice, aliceProxy, vt, KEY42, false);
        vm.prank(adapter);
        lock.release();
        PledgeCounters memory a = coll.getCounters(vt, alice);
        assertEq(a.regularUsed, k.regularUsed + 400_000_000, "regular part booked");
        assertEq(a.sliceUsed, k.sliceUsed + 300_000_000, "slice part booked");
        assertEq(a.depositorUsed, k.depositorUsed + 700_000_000, "depositor counter");

        PledgeCharge[2] memory bad = [
            PledgeCharge({usdCharge: 1, sliceUsd: 2, rescue: false, rescueUnits: 0}),
            PledgeCharge({usdCharge: 2 ** 64, sliceUsd: 0, rescue: false, rescueUnits: 0})
        ];
        for (uint256 i = 0; i < bad.length; ++i) {
            bytes32 key = bytes32(uint256(100 + i));
            lpVault.mintPosition(key, alice, MARKET_ID, 1_000_000);
            riskModule.setOverride(bad[i]);
            vm.startPrank(adapter);
            lock.acquire();
            vm.expectRevert(ICollateralizationErrors.InvalidCharge.selector);
            coll.pledge(alice, aliceProxy, vt, key, false);
            lock.release();
            vm.stopPrank();
            PledgeCounters memory c = coll.getCounters(vt, alice);
            assertEq(c.regularUsed, a.regularUsed, "regular unchanged");
            assertEq(c.sliceUsed, a.sliceUsed, "slice unchanged");
            assertEq(c.depositorUsed, a.depositorUsed, "depositor unchanged");
        }
    }

    /// @notice Liquidity 0 is refused and 1 unit is credited; the largest credit `2^120 − 1` is booked and `2^120` is
    /// refused `LiquidityAboveBound`; the market's first pledge and last withdrawal take its totals and supply from 0
    /// to the credit and back to 0, after which a new pledge opens it again.
    // TEST-072 verifies: REQ-VAULT-110, SPEC-BACK-002, REQ-COLL-016
    function test_TEST_072_liquidityBoundaryVectors() public {
        assertEq(coll.getTotalCredited(vt), 0, "empty market");
        assertEq(token.totalSupply(), 0, "no supply");
        _pledge(bob, bobProxy, KEY7, 1);
        assertEq(coll.getAccountCredited(bobProxy, vt), 1, "one unit credited");
        assertEq(coll.getTotalCredited(vt), 1, "the market's first pledge");
        assertEq(_shares(bobProxy), 1, "one share supplied");
        _withdraw(bobProxy, KEY7, 1);
        assertEq(coll.getTotalCredited(vt), 0, "the market's last withdrawal");
        assertEq(token.totalSupply(), 0, "supply back to 0");
        assertEq(coll.recordIdOf(INTEGRATION, KEY7), 0, "record closed");
        assertEq(lpVault.ownerOf(KEY7), bob, "position returned");
        bytes32 again = bytes32(uint256(8));
        _pledge(bob, bobProxy, again, 2_000_000);
        assertEq(coll.getTotalCredited(vt), 2_000_000, "a new pledge after the last withdrawal");

        lpVault.mintPosition(KEY42, alice, MARKET_ID, 0);
        vm.startPrank(adapter);
        lock.acquire();
        token.addValidProxy(aliceProxy);
        vm.expectRevert();
        coll.pledge(alice, aliceProxy, vt, KEY42, false);
        assertEq(coll.recordIdOf(INTEGRATION, KEY42), 0, "liquidity 0 refused");
        lpVault.mintPosition(KEY42, alice, MARKET_ID, uint128(type(uint120).max) + 1);
        vm.expectRevert(ICollateralizationErrors.LiquidityAboveBound.selector);
        coll.pledge(alice, aliceProxy, vt, KEY42, false);
        riskModule.setOverride(PledgeCharge({usdCharge: type(uint64).max, sliceUsd: 0, rescue: false, rescueUnits: 0}));
        lpVault.mintPosition(KEY42, alice, MARKET_ID, type(uint120).max);
        (, uint128 credited) = coll.pledge(alice, aliceProxy, vt, KEY42, false);
        assertEq(credited, type(uint120).max, "largest credit booked");
        lock.release();
        vm.stopPrank();
    }

    /// @notice While the pool's reentrancy flag is set, a pledge and a partial removal revert `PoolLocked` and change
    /// nothing; once it clears, the same partial removal settles.
    // TEST-116 verifies: REQ-COLL-024, REQ-VAULT-012
    function test_TEST_116_poolLockRefusesPledgeAndRemoval() public {
        _pledge(alice, aliceProxy, KEY7, 5_000_000_000);
        lpVault.mintPosition(KEY42, alice, MARKET_ID, 1_000_000_000);
        lpVault.setPoolLocked(true);
        vm.startPrank(adapter);
        lock.acquire();
        vm.expectRevert(ILPVaultErrors.PoolLocked.selector);
        coll.pledge(alice, aliceProxy, vt, KEY42, false);
        vm.stopPrank();
        _withdrawAndBurn(aliceProxy, 1_000_000_000);
        vm.prank(adapter);
        vm.expectRevert(ILPVaultErrors.PoolLocked.selector);
        coll.releasePartial(aliceProxy, vt, KEY7, 1_000_000_000, new uint256[](2));
        lpVault.setPoolLocked(false);
        vm.prank(adapter);
        (uint128 remaining,) = coll.releasePartial(aliceProxy, vt, KEY7, 1_000_000_000, new uint256[](2));
        assertEq(remaining, 4_000_000_000, "removed once the flag clears");
        vm.prank(adapter);
        lock.release();
        assertEq(coll.getRecord(1).credited, 4_000_000_000, "only the unlocked removal debited the record");
        assertEq(coll.recordIdOf(INTEGRATION, KEY42), 0, "the locked pledge left no record");
    }

    function _supplyAndRelease(
        address proxy,
        uint256 units
    ) internal {
        vm.prank(adapter);
        token.mint(proxy, units);
        _supply(proxy, units);
        vm.prank(adapter);
        lock.release();
    }

    /// @dev The first `poke()` on the LPOracle comes before the first `checkPledge` on the RiskModule.
    function _assertPokeFirst(
        Vm.AccountAccess[] memory accesses
    ) internal view {
        uint256 poke = type(uint256).max;
        uint256 check = type(uint256).max;
        for (uint256 i = 0; i < accesses.length; ++i) {
            if (accesses[i].data.length < 4) continue;
            bytes4 sel = bytes4(accesses[i].data);
            if (
                poke == type(uint256).max && accesses[i].account == address(oracle)
                    && sel == CollOracleMock.poke.selector
            ) poke = i;
            if (
                check == type(uint256).max && accesses[i].account == address(riskModule)
                    && sel == CollRiskModuleMock.checkPledge.selector
            ) check = i;
        }
        assertLt(poke, type(uint256).max, "poke called");
        assertLt(check, type(uint256).max, "checkPledge called");
        assertLt(poke, check, "poke before checkPledge");
    }
}
