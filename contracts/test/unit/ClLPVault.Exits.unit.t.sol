// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAmmIntegration} from "../../src/amm/IAmmIntegration.sol";
import {IClIntegration} from "../../src/amm/IClIntegration.sol";
import {IClPositionManager} from "../../src/amm/concentrated-liquidity/IClPositionManager.sol";
import {IMarketRegistryPause} from "../../src/policy/market-registry/IMarketRegistryPause.sol";
import {ClLPVaultBase, ClLPVaultSlipstreamHooks, ClLPVaultUniswapHooks, IClTestManager} from "./ClLPVault.Base.sol";
import {IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

/// @title ClLPVaultExitsTests
/// @notice The LPVault's part of the exit, settlement and liquidation flows of 5.1, on the production contract: what it
/// removes, pays and returns when Collateralization instructs it inside an AaveAdapter or LPVaultSwap Lock session, and
/// that no Avana state (pause state and reason, a broken or hostile MarketRegistry, the spot price, outside liquidity)
/// changes any of it. The AaveAdapter, Collateralization and LPVaultSwap steps of the same flows are checked in their own
/// suites; here they are the named addresses that hold the Lock and call. Each body runs on the Uniswap v3 and the
/// Slipstream LPVault.
abstract contract ClLPVaultExitsTests is ClLPVaultBase {
    // ─── Debt-free withdrawal and zero-credit release ───

    // TEST-018 verifies: REQ-VAULT-152, REQ-VAULT-005, INV-007, INV-045
    // Sources: 5.1 TEST-018 (the LPVault returns the whole NFT to the depositor of record with transferFrom; it succeeds
    // in None, Frozen and Paused with either reason)
    /// @notice In each pause state, a pledged NFT carrying donated liquidity and owed fees is returned whole to its
    /// depositor by one `transferFrom`, with `PositionReturned`, and its custody entry is gone; the LPVault never reads
    /// the MarketRegistry.
    /// @dev Kills: a return that keeps liquidity or fees, a hook-running transfer, a custody entry left behind, a pause
    /// read on the withdrawal path.
    function test_TEST_018_returnSendsTheWholeNftToItsDepositorInEveryState() public {
        Core memory c = _cCore();
        IClIntegration v = _cVault();
        vm.expectCall(c.registry, "", 0);
        for (uint8 state = 0; state < 4; ++state) {
            _mockPause(state < 3 ? state : 2, state < 2 ? 0 : state - 1);
            (bytes32 key,) = _cPledge(MKT_A, alice, 1e12);
            uint256 id = _cTokenId(key);
            IClTestManager manager = _cManager(key);
            manager.accrue(id, 7, 8);
            vm.prank(bob);
            manager.increaseLiquidity(id, 3e11);
            uint128 liquidity = _cLiquidity(key);
            vm.expectCall(
                address(manager), abi.encodeWithSelector(IERC721.transferFrom.selector, address(v), alice, id), 1
            );
            _returnExpectingEvent(c.adapter, key, alice);
            assertEq(manager.ownerOf(id), alice, "the NFT is back with its depositor");
            assertEq(_cLiquidity(key), liquidity, "with all its liquidity, donated included");
            assertFalse(v.isInCustody(key));
            assertEq(v.depositorOf(key), address(0));
            _assertOwedFees(key, alice, 7, 8);
        }
    }

    // TEST-020 verifies: REQ-VAULT-079, REQ-VAULT-152, REQ-AMM-CORE-010
    // Sources: 5.1 TEST-020 (after a full seizure the record stays open with 0 units; the depositor can still collect
    // fees; zero-credit release has the LPVault return the NFT)
    /// @notice A position seized down to zero units stays in custody with its depositor, is not a stray, still pays its
    /// fees to the depositor, and is returned to the depositor on release.
    /// @dev Kills: a custody entry dropped when units reach 0, fees lost with the last unit, a zero-unit NFT stranded.
    function test_TEST_020_zeroUnitPositionStaysInCustodyAndReturns() public {
        Core memory c = _cCore();
        IClIntegration v = _cVault();
        (bytes32 key, uint128 units) = _cPledge(MKT_A, alice, 1e12);
        _cAs(c.lpVaultSwap, abi.encodeCall(IAmmIntegration.unwind, (key, units, _cZeros(), c.lpVaultSwap)));
        assertEq(v.unitsOf(key), 0, "fully seized");
        assertTrue(v.isInCustody(key), "the zero-unit position stays in custody");
        assertEq(v.depositorOf(key), alice);
        vm.prank(c.timelock);
        vm.expectRevert(NotStray.selector);
        v.returnStray(key, bob);
        _cManager(key).accrue(_cTokenId(key), 11, 12);
        uint256 before0 = _cToken(MKT_A, 0).balanceOf(alice);
        uint256[] memory fees =
            abi.decode(_cAs(c.adapter, abi.encodeCall(IAmmIntegration.collectFees, (key, alice))), (uint256[]));
        assertEq(fees[0], 11);
        assertEq(fees[1], 12);
        assertEq(_cToken(MKT_A, 0).balanceOf(alice) - before0, 11, "the depositor collects its fees");
        _cAs(c.adapter, abi.encodeCall(IAmmIntegration.returnPosition, (key)));
        assertEq(_cManager(key).ownerOf(_cTokenId(key)), alice, "released to the depositor");
        assertFalse(v.isInCustody(key));
    }

    // TEST-209 verifies: INV-007, REQ-VAULT-152
    // Sources: 5.1 TEST-209 (an LPVault that sends the NFT elsewhere cannot exist: returnPosition reads depositorOf
    // itself)
    /// @notice `returnPosition` takes only the position key and sends the NFT to the depositor of record, by
    /// `transferFrom`, under either Lock member's session; it has no recipient overload, and a second return reverts.
    /// @dev Kills: a recipient parameter or any destination other than `depositorOf(positionKey)`.
    function test_TEST_209_returnPositionPaysOnlyTheDepositorOfRecord() public {
        Core memory c = _cCore();
        IClIntegration v = _cVault();
        (bytes32 k1,) = _cPledge(MKT_A, alice, 1e12);
        (bytes32 k2,) = _cPledge(MKT_B, bob, 1e12);
        (bool overload,) =
            address(v).call(abi.encodeWithSignature("returnPosition(bytes32,address)", k1, address(attacker)));
        assertFalse(overload, "no recipient can be named");
        vm.expectCall(
            address(_cManager(k1)),
            abi.encodeWithSelector(IERC721.transferFrom.selector, address(v), alice, _cTokenId(k1)),
            1
        );
        _returnExpectingEvent(c.adapter, k1, alice);
        _returnExpectingEvent(c.lpVaultSwap, k2, bob);
        assertEq(_cManager(k1).ownerOf(_cTokenId(k1)), alice);
        assertEq(_cManager(k2).ownerOf(_cTokenId(k2)), bob);
        (bool again, bytes memory err) = _cTry(c.adapter, c.coll, abi.encodeCall(IAmmIntegration.returnPosition, (k1)));
        assertFalse(again);
        assertEq(bytes4(err), NotInCustody.selector, "returned once");
    }

    // ─── Seizure and reconcile ───

    // TEST-047 verifies: REQ-VAULT-149, REQ-VAULT-058, SPEC-BACK-008, REQ-AMM-CORE-008
    // Sources: 5.1 TEST-047 (Collateralization has the LPVault remove the liquidity with zero per-token minimums and a
    // principal-capped collect to LPVaultSwap)
    /// @notice A seizure inside LPVaultSwap's Lock session removes exactly the liquidity of the seized units with zero
    /// minimums, pays exactly the removed principal to LPVaultSwap, and leaves every owed fee with the NFT.
    /// @dev Kills: a removal of other than `units * 10^k`, a non-zero minimum, an uncapped collect that sweeps fees, a
    /// recipient other than LPVaultSwap.
    function test_TEST_047_seizureRemovesExactUnitsToLPVaultSwap() public {
        Core memory c = _cCore();
        uint128 scale = _cScale(MKT_A);
        (bytes32 key, uint128 units) = _cPledge(MKT_A, alice, 1e12);
        uint256 id = _cTokenId(key);
        _cManager(key).accrue(id, 5, 6);
        uint128 seized = units / 3;
        uint128 before = _cLiquidity(key);
        vm.expectCall(
            address(_cManager(key)),
            abi.encodeCall(
                IClPositionManager.decreaseLiquidity,
                (IClPositionManager.DecreaseLiquidityParams(id, seized * scale, 0, 0, block.timestamp))
            ),
            1
        );
        uint256 b0 = _cToken(MKT_A, 0).balanceOf(c.lpVaultSwap);
        uint256 b1 = _cToken(MKT_A, 1).balanceOf(c.lpVaultSwap);
        uint256[] memory got = abi.decode(
            _cAs(c.lpVaultSwap, abi.encodeCall(IAmmIntegration.unwind, (key, seized, _cZeros(), c.lpVaultSwap))),
            (uint256[])
        );
        assertEq(_cLiquidity(key), before - seized * scale, "exactly the seized units' liquidity");
        assertEq(_cToken(MKT_A, 0).balanceOf(c.lpVaultSwap) - b0, got[0], "exactly the principal to LPVaultSwap");
        assertEq(_cToken(MKT_A, 1).balanceOf(c.lpVaultSwap) - b1, got[1]);
        assertEq(_cToken(MKT_A, 0).balanceOf(address(_cVault())), 0, "nothing rests at the LPVault");
        uint256[] memory fees =
            abi.decode(_cAs(c.adapter, abi.encodeCall(IAmmIntegration.collectFees, (key, alice))), (uint256[]));
        assertEq(fees[0], 5, "the seizure left every owed fee");
        assertEq(fees[1], 6);
    }

    // TEST-150 verifies: REQ-VAULT-149, SPEC-BACK-008, REQ-VAULT-152
    // Sources: 5.1 TEST-150 example (records of 1,000 (NFT 42) and 800 (NFT 7) units; 315 kept by the mock; withdrawing
    // NFT 42 debits 315 from it and returns it with 685 units of liquidity; owed fees unchanged)
    /// @notice The worked example on the LPVault: the reconcile inside the withdrawal removes exactly 315 units with zero
    /// minimums to Collateralization, NFT 42 returns with 685 units of liquidity and its owed fees, NFT 7 keeps 800.
    /// @dev Kills: a reconcile that removes other than the shortfall, pays elsewhere or takes fees.
    function test_TEST_150_reconcileRemovesTheShortfallAndReturnsTheRest() public {
        Core memory c = _cCore();
        (bytes32 nft42, bytes32 nft7, uint128 scale) = _example();
        _cManager(nft42).accrue(_cTokenId(nft42), 9, 9);
        uint256 coll0 = _cToken(MKT_A, 0).balanceOf(c.coll);
        uint256[] memory removed = abi.decode(
            _cAs(c.adapter, abi.encodeCall(IAmmIntegration.unwind, (nft42, 315, _cZeros(), c.coll))), (uint256[])
        );
        assertEq(_cToken(MKT_A, 0).balanceOf(c.coll) - coll0, removed[0], "the pending tokens go to Collateralization");
        assertEq(_cVault().unitsOf(nft42), 685);
        _cAs(c.adapter, abi.encodeCall(IAmmIntegration.returnPosition, (nft42)));
        assertEq(_cManager(nft42).ownerOf(_cTokenId(nft42)), alice);
        assertEq(_cLiquidity(nft42), 685 * scale, "NFT 42 returns with 685 units of liquidity");
        _assertOwedFees(nft42, alice, 9, 9);
        assertEq(_cVault().unitsOf(nft7), 800, "NFT 7 untouched");
        assertEq(_cVault().depositorOf(nft7), alice);
    }

    // TEST-154 verifies: REQ-VAULT-098, REQ-VAULT-149, INV-007
    // Sources: 5.1 TEST-154 (a hostile LPVaultSwap keeps 315 seized units; the withdrawals reconcile and return NFT 42
    // with 685 units and NFT 7 with 800; no NFT is stranded)
    /// @notice A hostile LPVaultSwap holding the Lock can call no custody function itself and cannot collect fees even
    /// through Collateralization; the withdrawals then reconcile 315 units of NFT 42 to Collateralization and return both
    /// NFTs whole to their depositor, so the LPVault holds neither.
    /// @dev Kills: a custody function open to LPVaultSwap, fee collection under LPVaultSwap's Lock, a stranded NFT.
    function test_TEST_154_hostileLPVaultSwapCannotStrandAnNft() public {
        Core memory c = _cCore();
        (bytes32 nft42, bytes32 nft7, uint128 scale) = _example();
        bytes[3] memory calls = [
            abi.encodeCall(IAmmIntegration.unwind, (nft42, 315, _cZeros(), c.lpVaultSwap)),
            abi.encodeCall(IAmmIntegration.returnPosition, (nft7)),
            abi.encodeCall(IAmmIntegration.collectFees, (nft42, alice))
        ];
        for (uint256 i = 0; i < 3; ++i) {
            (bool ok, bytes memory err) = _cTry(c.lpVaultSwap, c.lpVaultSwap, calls[i]);
            assertFalse(ok);
            assertEq(bytes4(err), NotCollateralization.selector, "LPVaultSwap cannot instruct the LPVault");
        }
        (bool fees, bytes memory why) =
            _cTry(c.lpVaultSwap, c.coll, abi.encodeCall(IAmmIntegration.collectFees, (nft42, alice)));
        assertFalse(fees);
        assertEq(bytes4(why), LockNotHeld.selector, "no fee collection under LPVaultSwap's session");
        _cAs(c.adapter, abi.encodeCall(IAmmIntegration.unwind, (nft42, 315, _cZeros(), c.coll)));
        _cAs(c.adapter, abi.encodeCall(IAmmIntegration.returnPosition, (nft42)));
        _cAs(c.adapter, abi.encodeCall(IAmmIntegration.returnPosition, (nft7)));
        assertEq(_cLiquidity(nft42), 685 * scale);
        assertEq(_cLiquidity(nft7), 800 * scale);
        assertEq(_cManager(nft42).ownerOf(_cTokenId(nft42)), alice, "no NFT stranded");
        assertEq(_cManager(nft7).ownerOf(_cTokenId(nft7)), alice);
        assertEq(_cToken(MKT_A, 0).balanceOf(address(_cVault())), 0, "the LPVault holds no pool token");
    }

    // TEST-130 verifies: REQ-VAULT-098, REQ-VAULT-064, INV-007, INV-033
    // Sources: 5.1 TEST-130 (a hostile Adapter cannot send an NFT to anyone but its depositor of record, nor collect any
    // depositor's fees)
    /// @notice With a hostile AaveAdapter holding the Lock, it can call no custody function itself; through
    /// Collateralization a fee collection naming anyone but the depositor reverts, a partial removal pays only the
    /// depositor, a return sends the NFT only to the depositor; the Adapter can never move the NFT from the LPVault.
    /// @dev Kills: a recipient the Adapter's call tree could choose for a position, its principal or its fees.
    function test_TEST_130_hostileAdapterCannotMovePositionsOrFeesElsewhere() public {
        Core memory c = _cCore();
        IClIntegration v = _cVault();
        (bytes32 key, uint128 units) = _cPledge(MKT_A, alice, 1e12);
        _cManager(key).accrue(_cTokenId(key), 5, 5);
        bytes[3] memory direct = [
            abi.encodeCall(IAmmIntegration.returnPosition, (key)),
            abi.encodeCall(IAmmIntegration.releaseToDepositor, (key, 1, _cZeros())),
            abi.encodeCall(IAmmIntegration.collectFees, (key, c.adapter))
        ];
        for (uint256 i = 0; i < 3; ++i) {
            (bool ok, bytes memory err) = _cTry(c.adapter, c.adapter, direct[i]);
            assertFalse(ok);
            assertEq(bytes4(err), NotCollateralization.selector);
        }
        address[2] memory takers = [c.adapter, attacker];
        for (uint256 i = 0; i < 2; ++i) {
            (bool ok, bytes memory err) =
                _cTry(c.adapter, c.coll, abi.encodeCall(IAmmIntegration.collectFees, (key, takers[i])));
            assertFalse(ok);
            assertEq(bytes4(err), NotDepositor.selector, "fees only to the depositor of record");
        }
        vm.prank(c.adapter);
        vm.expectRevert(
            abi.encodeWithSelector(IERC721Errors.ERC721InsufficientApproval.selector, c.adapter, _cTokenId(key))
        );
        _cManager(key).transferFrom(address(v), c.adapter, _cTokenId(key));
        uint256 adapter0 = _cToken(MKT_A, 0).balanceOf(c.adapter);
        _cAs(c.adapter, abi.encodeCall(IAmmIntegration.releaseToDepositor, (key, units / 2, _cZeros())));
        _cAs(c.adapter, abi.encodeCall(IAmmIntegration.returnPosition, (key)));
        assertEq(_cToken(MKT_A, 0).balanceOf(c.adapter), adapter0, "the Adapter received nothing");
        assertEq(_cManager(key).ownerOf(_cTokenId(key)), alice, "the NFT went only to its depositor");
        _assertOwedFees(key, alice, 5, 5);
    }

    // ─── Exits under every state ───

    // TEST-099 verifies: REQ-VAULT-005, REQ-VAULT-098, INV-044, INV-045
    // Sources: 5.1 TEST-099 (fee collection, debt-free withdrawal and zero-credit release succeed in every price state
    // and with any MarketRegistry implementation)
    /// @notice With the MarketRegistry address reverting, answering garbage or holding no code, the spot price anywhere
    /// in the tick range and any outside liquidity, fee collection, a partial removal, a reconcile removal, a seizure
    /// and the return all succeed and pay the depositor or the named recipient.
    /// @dev Kills: a registry, price or pool-liquidity read on an exit path of the LPVault.
    function testFuzz_TEST_099_exitsSucceedWithAnyRegistryAndSpot(
        uint8 mode,
        int24 tick,
        uint128 outside
    ) public {
        Core memory c = _cCore();
        if (mode % 3 == 0) _cBreakRegistry();
        else if (mode % 3 == 1) vm.etch(c.registry, hex"60206000f3");
        vm.expectCall(c.registry, "", 0);
        (bytes32 key, uint128 units) = _cPledge(MKT_A, alice, 1e12);
        _cPool(MKT_A).setPrice(int24(bound(tick, -880_000, 880_000)));
        _cPool(MKT_A).setLiquidity(outside);
        _cManager(key).accrue(_cTokenId(key), 3, 4);
        _exitAll(key, units, alice);
    }

    // TEST-193 verifies: REQ-VAULT-005, INV-043, INV-044, INV-045
    // Sources: 5.1 TEST-193 (liquidation, fee collection, debt-free withdrawal and partial removal and zero-credit
    // release succeed in every pause state and reason)
    /// @notice In None, Frozen, Paused(General) and Paused(MintPathSuspect), a seizure, a fee collection, a partial
    /// removal, a removal down to zero units and the return of the position all succeed, and none reads the state.
    /// @dev Kills: a pause-state read on any LPVault path that a liquidation or an exit takes.
    function testFuzz_TEST_193_exitsAndSeizurePassInEveryPauseState(
        uint8 state,
        uint8 reason
    ) public {
        Core memory c = _cCore();
        state = uint8(bound(state, 0, 2));
        reason = state == 2 ? uint8(bound(reason, 1, 2)) : 0;
        _mockPause(state, reason);
        vm.expectCall(c.registry, "", 0);
        (bytes32 key, uint128 units) = _cPledge(MKT_A, alice, 1e12);
        _cAs(c.lpVaultSwap, abi.encodeCall(IAmmIntegration.unwind, (key, units / 3, _cZeros(), c.lpVaultSwap)));
        _cManager(key).accrue(_cTokenId(key), 2, 2);
        _cAs(c.adapter, abi.encodeCall(IAmmIntegration.collectFees, (key, alice)));
        _cAs(c.adapter, abi.encodeCall(IAmmIntegration.releaseToDepositor, (key, units / 3, _cZeros())));
        uint128 rest = _cVault().unitsOf(key);
        _cAs(c.lpVaultSwap, abi.encodeCall(IAmmIntegration.unwind, (key, rest, _cZeros(), c.lpVaultSwap)));
        _cAs(c.adapter, abi.encodeCall(IAmmIntegration.returnPosition, (key)));
        assertEq(_cManager(key).ownerOf(_cTokenId(key)), alice, "the zero-unit position is released to its depositor");
    }

    // TEST-195 verifies: INV-045, REQ-VAULT-152
    // Sources: 5.1 TEST-195 (inside the delay, while Paused, the borrower withdraws three NFTs in two markets; the
    // queued hostile Adapter then finds no position to touch)
    /// @notice While Paused(General), three NFTs in two markets return whole to their depositor; afterwards no custody
    /// call through any Lock session can reach them, so a later Adapter finds nothing.
    /// @dev Kills: a withdrawal path the pause stops, a custody entry that outlives the return.
    function test_TEST_195_threeNftsLeaveWhilePausedAndNothingRemains() public {
        Core memory c = _cCore();
        _mockPause(2, 1);
        vm.expectCall(c.registry, "", 0);
        bytes32[3] memory keys;
        uint128[3] memory liq;
        (keys[0],) = _cPledge(MKT_A, alice, 1e12);
        (keys[1],) = _cPledge(MKT_A, alice, 2e12);
        (keys[2],) = _cPledge(MKT_B, alice, 3e12);
        for (uint256 i = 0; i < 3; ++i) {
            liq[i] = _cLiquidity(keys[i]);
            _cAs(c.adapter, abi.encodeCall(IAmmIntegration.returnPosition, (keys[i])));
        }
        for (uint256 i = 0; i < 3; ++i) {
            assertEq(_cManager(keys[i]).ownerOf(_cTokenId(keys[i])), alice);
            assertEq(_cLiquidity(keys[i]), liq[i], "returned whole");
            bytes[3] memory calls = [
                abi.encodeCall(IAmmIntegration.unwind, (keys[i], 1, _cZeros(), c.lpVaultSwap)),
                abi.encodeCall(IAmmIntegration.returnPosition, (keys[i])),
                abi.encodeCall(IAmmIntegration.releaseToDepositor, (keys[i], 1, _cZeros()))
            ];
            for (uint256 j = 0; j < 3; ++j) {
                (bool ok, bytes memory err) = _cTry(c.adapter, c.coll, calls[j]);
                assertFalse(ok);
                assertEq(bytes4(err), NotInCustody.selector, "nothing left for a later Adapter to touch");
            }
        }
    }

    // TEST-218 verifies: INV-045, REQ-VAULT-149, SPEC-BACK-008
    // Sources: 5.1 TEST-218 (outside LPs remove 0-90 % of each pool and the price moves 5-40 %; liquidations interleave
    // with debt-free withdrawals and partial removals; debt-free exits never revert for a stop)
    /// @notice Six positions in two markets; outside liquidity cut by up to 90 % and the spot moved by 5 % to 49 % of the
    /// price; then, in a random order, each is either seized in part to LPVaultSwap or partly removed for its
    /// depositor, and returned. Every step succeeds and pays exactly what it reports to its recipient.
    /// @dev Kills: an exit or seizure that depends on pool depth or the spot price.
    function testFuzz_TEST_218_exitsAndSeizuresSurviveACascade(
        uint256 seed,
        uint16 removedBps,
        uint16 moveBps
    ) public {
        Core memory c = _cCore();
        removedBps = uint16(bound(removedBps, 0, 9000));
        moveBps = uint16(bound(moveBps, 500, 4000));
        address[3] memory owners = [alice, bob, carol];
        bytes32[6] memory keys;
        uint128[6] memory units;
        for (uint256 i = 0; i < 6; ++i) {
            (keys[i], units[i]) = _cPledge(i % 2 == 0 ? MKT_A : MKT_B, owners[i % 3], uint128(1e12 * (i + 1)));
        }
        // moveBps ticks of 1.0001: a move of 5 % (500 ticks) to 49 % (4,000 ticks) of the price, down or up by seed.
        int24 ticks = int24(int256(uint256(moveBps))) * (seed % 2 == 0 ? int24(1) : int24(-1));
        for (uint256 m = MKT_A; m <= MKT_B; ++m) {
            _cPool(m).setLiquidity(uint128(1e24 * (10_000 - uint256(removedBps)) / 10_000));
            _cPool(m).setPrice(ticks);
        }
        for (uint256 n = 0; n < 6; ++n) {
            uint256 i = (n + seed % 6) % 6;
            if ((seed >> (n + 1)) & 1 == 1) {
                _seizeAndCheck(keys[i], units[i] / 2, c.lpVaultSwap);
            } else {
                _cAs(c.adapter, abi.encodeCall(IAmmIntegration.releaseToDepositor, (keys[i], units[i] / 4, _cZeros())));
            }
            _cAs(c.adapter, abi.encodeCall(IAmmIntegration.returnPosition, (keys[i])));
            assertEq(_cManager(keys[i]).ownerOf(_cTokenId(keys[i])), owners[i % 3], "back with its depositor");
        }
    }

    // TEST-223 verifies: REQ-VAULT-152, REQ-AMM-CORE-009, REQ-AMM-CORE-010, INV-033, INV-045
    // Sources: 5.1 TEST-223 (deposit, collect fees, partial removal, re-credit after a third party's increaseLiquidity,
    // partial liquidation, reconcile, withdrawal: the NFT returned with its fees)
    /// @notice One position's journey through the LPVault: pledge, fee collection, partial removal, a third party's
    /// liquidity increase (live units rise, as a re-credit reads them), a partial seizure, a reconcile removal and the
    /// withdrawal; at each step the units the LPVault reports match the liquidity left, and the NFT returns with every
    /// fee it still owes.
    /// @dev Kills: a step that loses liquidity or fees, units out of line with the position's liquidity.
    function test_TEST_223_lpJourneyThroughTheLPVault() public {
        Core memory c = _cCore();
        IClIntegration v = _cVault();
        uint128 scale = _cScale(MKT_A);
        (bytes32 key, uint128 units) = _cPledge(MKT_A, alice, 1000 * scale);
        assertEq(units, 1000);
        _cManager(key).accrue(_cTokenId(key), 20, 30);
        uint256 a0 = _cToken(MKT_A, 0).balanceOf(alice);
        _cAs(c.adapter, abi.encodeCall(IAmmIntegration.collectFees, (key, alice)));
        assertEq(_cToken(MKT_A, 0).balanceOf(alice) - a0, 20, "fees collected to the depositor");
        _cAs(c.adapter, abi.encodeCall(IAmmIntegration.releaseToDepositor, (key, 200, _cZeros())));
        assertEq(v.unitsOf(key), 800, "partial removal");
        vm.prank(bob);
        _cManager(key).increaseLiquidity(_cTokenId(key), 100 * scale);
        assertEq(v.unitsOf(key), 900, "a third party's liquidity raises live units, which a re-credit reads");
        _cAs(c.lpVaultSwap, abi.encodeCall(IAmmIntegration.unwind, (key, 150, _cZeros(), c.lpVaultSwap)));
        assertEq(v.unitsOf(key), 750, "partial liquidation");
        _cAs(c.adapter, abi.encodeCall(IAmmIntegration.unwind, (key, 50, _cZeros(), c.coll)));
        assertEq(v.unitsOf(key), 700, "reconcile");
        _cManager(key).accrue(_cTokenId(key), 2, 3);
        _cAs(c.adapter, abi.encodeCall(IAmmIntegration.returnPosition, (key)));
        assertEq(_cManager(key).ownerOf(_cTokenId(key)), alice);
        assertEq(_cLiquidity(key), 700 * scale, "returned with the liquidity left");
        _assertOwedFees(key, alice, 2, 3);
    }

    // ─── Helpers ───

    /// @dev `returnPosition(key)` by Collateralization inside `holder`'s Lock session, expecting `PositionReturned` and
    /// `depositor` as the address it reports.
    function _returnExpectingEvent(
        address holder,
        bytes32 key,
        address depositor
    ) internal {
        Core memory c = _cCore();
        IClIntegration v = _cVault();
        vm.prank(holder);
        c.lock.acquire();
        vm.expectEmit(address(v));
        emit PositionReturned(key, depositor);
        vm.prank(c.coll);
        assertEq(v.returnPosition(key), depositor);
        vm.prank(holder);
        c.lock.release();
    }

    /// @dev Answers the MarketRegistry's pause views (state, reason) for any Hub.
    function _mockPause(
        uint8 state,
        uint8 reason
    ) internal {
        address r = _cCore().registry;
        vm.mockCall(r, abi.encodeWithSelector(IMarketRegistryPause.pauseState.selector), abi.encode(state));
        vm.mockCall(r, abi.encodeWithSelector(IMarketRegistryPause.pauseReason.selector), abi.encode(reason));
    }

    /// @dev The 5.1 example: NFT 42 with 1,000 units and NFT 7 with 800 units, both alice's.
    function _example() internal returns (bytes32 nft42, bytes32 nft7, uint128 scale) {
        scale = _cScale(MKT_A);
        uint128 u42;
        uint128 u7;
        (nft42, u42) = _cPledge(MKT_A, alice, 1000 * scale);
        (nft7, u7) = _cPledge(MKT_A, alice, 800 * scale);
        assertEq(u42, 1000);
        assertEq(u7, 800);
    }

    /// @dev The owner of a returned NFT collects exactly the fees it still owed.
    function _assertOwedFees(
        bytes32 key,
        address owner,
        uint256 f0,
        uint256 f1
    ) internal {
        vm.prank(owner);
        (uint256 c0, uint256 c1) = IClPositionManager(address(_cManager(key)))
            .collect(IClPositionManager.CollectParams(_cTokenId(key), owner, type(uint128).max, type(uint128).max));
        assertEq(c0, f0, "token0 fees kept with the NFT");
        assertEq(c1, f1, "token1 fees kept with the NFT");
    }

    /// @dev Every exit of the LPVault for `key`, each paying its recipient: fees, a partial removal, a reconcile
    /// removal, a seizure and the return.
    function _exitAll(
        bytes32 key,
        uint128 units,
        address owner
    ) internal {
        Core memory c = _cCore();
        _cAs(c.adapter, abi.encodeCall(IAmmIntegration.collectFees, (key, owner)));
        _cAs(c.adapter, abi.encodeCall(IAmmIntegration.releaseToDepositor, (key, units / 4, _cZeros())));
        _cAs(c.adapter, abi.encodeCall(IAmmIntegration.unwind, (key, units / 4, _cZeros(), c.coll)));
        _seizeAndCheck(key, units / 4, c.lpVaultSwap);
        _cAs(c.adapter, abi.encodeCall(IAmmIntegration.returnPosition, (key)));
        assertEq(_cManager(key).ownerOf(_cTokenId(key)), owner, "returned to the depositor");
    }

    /// @dev A seizure of `units` to `recipient` that pays it exactly the reported amounts.
    function _seizeAndCheck(
        bytes32 key,
        uint128 units,
        address recipient
    ) internal {
        uint256 m = _cVault().marketOfPosition(key);
        uint256 b0 = _cToken(m, 0).balanceOf(recipient);
        uint256 b1 = _cToken(m, 1).balanceOf(recipient);
        uint256[] memory got = abi.decode(
            _cAs(_cCore().lpVaultSwap, abi.encodeCall(IAmmIntegration.unwind, (key, units, _cZeros(), recipient))),
            (uint256[])
        );
        assertEq(_cToken(m, 0).balanceOf(recipient) - b0, got[0], "paid exactly the reported token0");
        assertEq(_cToken(m, 1).balanceOf(recipient) - b1, got[1], "paid exactly the reported token1");
    }
}

/// @notice `ClLPVaultExitsTests` on the Uniswap v3 LPVault.
/// forge-config: default.isolate = false
contract UniswapV3IntegrationExitsUnitTest is ClLPVaultUniswapHooks, ClLPVaultExitsTests {}

/// @notice `ClLPVaultExitsTests` on the Slipstream LPVault.
/// forge-config: default.isolate = false
contract SlipstreamIntegrationExitsUnitTest is ClLPVaultSlipstreamHooks, ClLPVaultExitsTests {}
