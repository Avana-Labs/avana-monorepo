// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAmmIntegration} from "../../src/amm/IAmmIntegration.sol";
import {IClIntegration} from "../../src/amm/IClIntegration.sol";
import {IClPositionManager} from "../../src/amm/concentrated-liquidity/IClPositionManager.sol";
import {MintableToken} from "../utils/mocks/UniswapV3Mocks.sol";
import {ClLPVaultBase, ClLPVaultSlipstreamHooks, ClLPVaultUniswapHooks} from "./ClLPVault.Base.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

/// @notice A mock pool's reentrancy flag (`MockV3Pool`, `MockCLPool`).
interface IClLockablePool {
    function setUnlocked(
        bool on
    ) external;
}

/// @notice A contract that tries to move a custodied position through the LPVault's custody entry points.
contract CustodyIntruder {
    function attempt(
        address vault,
        bytes calldata data
    ) external returns (bool ok) {
        (ok,) = vault.call(data);
    }
}

/// @title ClLPVaultLockGateTests
/// @notice Who may move value through a concentrated-liquidity LPVault and when, on the production LPVault with the
/// real Lock: only Collateralization, only while a Lock member holds the Lock, never a Lock member, an EOA, a proxy,
/// another LPVault or a hostile contract directly; the stray return only through the timelock and never under the
/// Lock; the per-leg minimums of a deleverage removal; the removal value at any spot against the composition; the
/// custody rules of the AMM integration interface; and the exploit-shape attempts on a pledged position. Each body
/// runs on the Uniswap v3 and the Slipstream LPVault.
abstract contract ClLPVaultLockGateTests is ClLPVaultBase {
    /// @notice Mints a position of `marketId`'s pool on `[lower, upper]` to `owner` and approves the LPVault for it.
    function _cMintRange(
        uint256 marketId,
        address owner,
        int24 lower,
        int24 upper,
        uint128 liquidity
    ) internal virtual returns (bytes32 key);

    /// @dev The value-moving entry points of the LPVault for `key` (pledged by bob) and `fresh` (minted by alice).
    function _entryPoints(
        bytes32 key,
        bytes32 fresh
    ) internal view returns (bytes[5] memory calls) {
        address swap = _cCore().lpVaultSwap;
        calls[0] = abi.encodeCall(IAmmIntegration.receivePosition, (MKT_A, alice, fresh));
        calls[1] = abi.encodeCall(IAmmIntegration.returnPosition, (key));
        calls[2] = abi.encodeCall(IAmmIntegration.unwind, (key, uint128(1), _cZeros(), swap));
        calls[3] = abi.encodeCall(IAmmIntegration.releaseToDepositor, (key, uint128(1), _cZeros()));
        calls[4] = abi.encodeCall(IAmmIntegration.collectFees, (key, bob));
    }

    function _plain(
        address caller,
        bytes memory data
    ) internal returns (bool ok, bytes memory out) {
        vm.prank(caller);
        (ok, out) = address(_cVault()).call(data);
    }

    function _err(
        bytes4 selector
    ) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(selector);
    }

    /// @dev The custody facts a refused attempt must leave intact.
    function _assertBacked(
        bytes32 key,
        address depositor,
        uint128 units
    ) internal view {
        IClIntegration v = _cVault();
        assertEq(_cManager(key).ownerOf(_cTokenId(key)), address(v), "the LPVault owns the NFT");
        assertEq(v.depositorOf(key), depositor, "depositor of record");
        assertGe(v.unitsOf(key), units, "credited units still backed");
    }

    // ─── TEST-060: the Lock and Collateralization ───

    // TEST-060 verifies: REQ-LOCK-028, REQ-VAULT-165, INV-091, REQ-VAULT-147, REQ-VAULT-148, REQ-VAULT-149
    // Sources: 5.1 TEST-060 (LPVault part: every value-moving entry point succeeds only while the Lock is held and only
    // from Collateralization; returnStray reverts while the Lock is held; ledger views revert Locked under it)
    /// @notice Without the Lock, Collateralization's calls to `receivePosition`, `returnPosition`, `unwind`,
    /// `releaseToDepositor` and `collectFees` revert `LockNotHeld`; with the Lock held by the AaveAdapter or by
    /// LPVaultSwap, the same calls from any other caller revert `NotCollateralization`, and from Collateralization they
    /// succeed. While the Lock is held `returnStray` reverts `Locked` even for the timelock, and `depositorOf` reverts
    /// `Locked` for any caller, and `unitsOf` for any caller but Collateralization.
    function test_TEST_060_valueMovesOnlyUnderTheLockFromCollateralization() public {
        (bytes32 key,) = _cPledge(MKT_A, bob, 1e12);
        bytes32 fresh = _cMint(MKT_A, alice, 1e9);
        bytes[5] memory calls = _entryPoints(key, fresh);
        for (uint256 i = 0; i < calls.length; ++i) {
            _assertOnlyCollateralizationUnderTheLock(calls[i]);
        }
        // From Collateralization under the Lock, each succeeds.
        _cAs(_cCore().adapter, calls[4]);
        _cAs(_cCore().adapter, calls[3]);
        _cAs(_cCore().lpVaultSwap, calls[2]);
        _cAs(_cCore().adapter, calls[0]);
        assertEq(_cVault().depositorOf(fresh), alice, "received under the Lock");
        bytes32 stray = _cMint(MKT_A, carol, 1e9);
        vm.prank(carol);
        _cManager(stray).transferFrom(carol, address(_cVault()), _cTokenId(stray));
        _assertLockedSurface(key, stray);
        _cAs(_cCore().adapter, calls[1]);
        assertEq(_cManager(key).ownerOf(_cTokenId(key)), bob, "returned under the Lock");
        vm.prank(_cCore().timelock);
        _cVault().returnStray(stray, carol);
        assertEq(_cManager(stray).ownerOf(_cTokenId(stray)), carol, "the stray leaves once the Lock is free");
    }

    /// @dev `data` from Collateralization without the Lock reverts `LockNotHeld`; under either member's Lock, from the
    /// member itself or an outsider, `NotCollateralization`.
    function _assertOnlyCollateralizationUnderTheLock(
        bytes memory data
    ) internal {
        Core memory c = _cCore();
        (bool ok, bytes memory out) = _plain(c.coll, data);
        assertFalse(ok, "Collateralization without the Lock");
        assertEq(out, _err(LockNotHeld.selector), "LockNotHeld");
        address[2] memory holders = [c.adapter, c.lpVaultSwap];
        for (uint256 h = 0; h < 2; ++h) {
            (ok, out) = _cTry(holders[h], holders[h], data);
            assertFalse(ok, "the Lock holder itself");
            assertEq(out, _err(NotCollateralization.selector), "NotCollateralization");
            (ok, out) = _cTry(holders[h], alice, data);
            assertFalse(ok, "an outsider under the Lock");
            assertEq(out, _err(NotCollateralization.selector), "NotCollateralization");
        }
    }

    /// @dev Under the AaveAdapter's Lock: `returnStray` reverts `Locked` for the timelock, `depositorOf` and `unitsOf`
    /// revert `Locked` for an outsider, and Collateralization reads `unitsOf`.
    function _assertLockedSurface(
        bytes32 key,
        bytes32 stray
    ) internal {
        Core memory c = _cCore();
        IClIntegration v = _cVault();
        vm.prank(c.adapter);
        c.lock.acquire();
        vm.prank(c.timelock);
        vm.expectRevert(Locked.selector);
        v.returnStray(stray, carol);
        vm.prank(alice);
        vm.expectRevert(Locked.selector);
        v.depositorOf(key);
        vm.prank(alice);
        vm.expectRevert(Locked.selector);
        v.unitsOf(key);
        vm.prank(c.coll);
        assertGt(v.unitsOf(key), 0, "Collateralization reads units under the Lock");
        vm.prank(c.adapter);
        c.lock.release();
    }

    // ─── TEST-270: Lock membership ───

    // TEST-270 verifies: REQ-LOCK-028, INV-091, REQ-VAULT-165, REQ-VAULT-079
    // Sources: 5.1 TEST-270 (LPVault part)
    /// @notice An EOA, a PositionProxy address, another LPVault, a hostile contract and the two Lock members themselves
    /// can move nothing through the LPVault, with the Lock free or held; `returnStray` runs only for the timelock, only
    /// for a position with no custody entry and never under the Lock. A market bound after launch takes a pledge,
    /// a seizure removal and a return with the same Lock and the same two members.
    function test_TEST_270_noOtherCallerMovesValueAndALaterMarketUsesTheSameLock() public {
        (bytes32 key, uint128 units) = _cPledge(MKT_A, bob, 1e12);
        bytes32 fresh = _cMint(MKT_A, alice, 1e9);
        CustodyIntruder intruder = new CustodyIntruder();
        address[6] memory callers = [
            alice,
            makeAddr("positionProxy"),
            address(_cVaultWithTimelock(_cCore().timelock)),
            address(intruder),
            _cCore().adapter,
            _cCore().lpVaultSwap
        ];
        bytes[5] memory calls = _entryPoints(key, fresh);
        for (uint256 i = 0; i < calls.length; ++i) {
            assertFalse(intruder.attempt(address(_cVault()), calls[i]), "hostile contract, Lock free");
            for (uint256 k = 0; k < callers.length; ++k) {
                _assertNeverMoves(callers[k], calls[i]);
            }
        }
        _assertBacked(key, bob, units);
        vm.prank(_cCore().timelock);
        vm.expectRevert(NotStray.selector);
        _cVault().returnStray(key, alice);
        _laterMarketUsesTheSameLock();
    }

    /// @dev `data` from `caller` fails with the Lock free and under either member's Lock.
    function _assertNeverMoves(
        address caller,
        bytes memory data
    ) internal {
        (bool ok,) = _plain(caller, data);
        assertFalse(ok, "Lock free");
        (ok,) = _cTry(_cCore().adapter, caller, data);
        assertFalse(ok, "Lock held by the AaveAdapter");
        (ok,) = _cTry(_cCore().lpVaultSwap, caller, data);
        assertFalse(ok, "Lock held by LPVaultSwap");
    }

    /// @dev A market bound after launch takes a pledge, a seizure removal and a return with the same Lock and members.
    function _laterMarketUsesTheSameLock() internal {
        Core memory c = _cCore();
        (address member0, address member1) = (c.lock.AAVE_ADAPTER(), c.lock.LP_VAULT_SWAP());
        _cBindMarketC(address(new MintableToken("DAI", 18)), address(new MintableToken("USDS", 18)));
        (bytes32 later, uint128 laterUnits) = _cPledge(MKT_C, alice, 1e15);
        assertGt(laterUnits, 0, "pledged into the later market");
        _cAs(c.lpVaultSwap, abi.encodeCall(IAmmIntegration.unwind, (later, laterUnits / 2, _cZeros(), c.lpVaultSwap)));
        _cAs(c.adapter, abi.encodeCall(IAmmIntegration.returnPosition, (later)));
        assertEq(_cManager(later).ownerOf(_cTokenId(later)), alice, "returned to its depositor");
        assertEq(c.lock.AAVE_ADAPTER(), member0, "members unchanged");
        assertEq(c.lock.LP_VAULT_SWAP(), member1, "members unchanged");
        assertEq(address(_cCore().lock), address(c.lock), "no Lock redeploy");
    }

    // ─── TEST-252: a stray owned by the LPVault ───

    // TEST-252 verifies: REQ-VAULT-147, REQ-VAULT-078, Q-258
    // Sources: 5.1 TEST-252 (LPVault part: a stray NFT owned by the LPVault reverts NotTokenOwner)
    /// @notice An NFT sent to the LPVault outside a pledge is owned by it: a pledge of it naming its sender, the
    /// LPVault itself or Collateralization as owner reverts `NotTokenOwner`, and it gets no custody entry.
    function test_TEST_252_strayOwnedByTheLPVaultCannotBePledged() public {
        bytes32 stray = _cMint(MKT_A, alice, 1e9);
        vm.prank(alice);
        _cManager(stray).transferFrom(alice, address(_cVault()), _cTokenId(stray));
        _assertNotTokenOwner(stray, alice);
        _assertNotTokenOwner(stray, address(_cVault()));
        _assertNotTokenOwner(stray, _cCore().coll);
        assertEq(_cVault().depositorOf(stray), address(0), "no custody entry");
        assertEq(_cManager(stray).ownerOf(_cTokenId(stray)), address(_cVault()));
    }

    function _assertNotTokenOwner(
        bytes32 key,
        address owner
    ) internal {
        bytes memory data = abi.encodeCall(IAmmIntegration.receivePosition, (MKT_A, owner, key));
        (bool ok, bytes memory out) = _cTry(_cCore().adapter, _cCore().coll, data);
        assertFalse(ok, "a stray cannot be pledged");
        assertEq(out, _err(NotTokenOwner.selector), "NotTokenOwner");
    }

    // ─── TEST-239: deleverage removals ───

    // TEST-239 verifies: REQ-VAULT-149, REQ-VAULT-146, REQ-VAULT-148, SPEC-BACK-008
    // Sources: 5.1 TEST-239 (LPVault part: per-leg minimums apply; full units return the NFT)
    /// @notice A deleverage removal to LPVaultSwap with a per-leg minimum one unit above what the pool returns on either
    /// leg reverts and moves nothing; at exactly the returned amounts it passes and LPVaultSwap receives them. Removing
    /// the rest leaves the position at 0 units in custody, and the return then sends the whole NFT to its depositor.
    function test_TEST_239_perLegMinimumsAndFullUnitsReturnTheNft() public {
        (bytes32 key, uint128 units) = _cPledge(MKT_A, bob, 1e12);
        uint128 half = units / 2;
        uint256[] memory got = _dryUnwind(key, half);
        assertGt(got[0] + got[1], 0, "the removal returns tokens");
        _assertMinimumRefused(key, half, got, 0);
        _assertMinimumRefused(key, half, got, 1);
        assertEq(_cVault().unitsOf(key), units, "nothing removed");
        address swap = _cCore().lpVaultSwap;
        uint256 b0 = _cToken(MKT_A, 0).balanceOf(swap);
        uint256 b1 = _cToken(MKT_A, 1).balanceOf(swap);
        _cAs(swap, abi.encodeCall(IAmmIntegration.unwind, (key, half, got, swap)));
        assertEq(_cToken(MKT_A, 0).balanceOf(swap) - b0, got[0], "leg 0 to LPVaultSwap");
        assertEq(_cToken(MKT_A, 1).balanceOf(swap) - b1, got[1], "leg 1 to LPVaultSwap");
        _cAs(swap, abi.encodeCall(IAmmIntegration.unwind, (key, units - half, _cZeros(), swap)));
        assertEq(_cVault().unitsOf(key), 0, "every unit removed");
        assertEq(_cVault().depositorOf(key), bob, "still in custody at 0 units");
        _cAs(_cCore().adapter, abi.encodeCall(IAmmIntegration.returnPosition, (key)));
        assertEq(_cManager(key).ownerOf(_cTokenId(key)), bob, "full units return the NFT");
    }

    /// @dev The amounts an unwind of `units` would return now, with the state restored after.
    function _dryUnwind(
        bytes32 key,
        uint128 units
    ) internal returns (uint256[] memory got) {
        address swap = _cCore().lpVaultSwap;
        uint256 snap = vm.snapshotState();
        got = abi.decode(_cAs(swap, abi.encodeCall(IAmmIntegration.unwind, (key, units, _cZeros(), swap))), (uint256[]));
        vm.revertToState(snap);
    }

    /// @dev An unwind whose minimum on `leg` is one unit above what it returns reverts.
    function _assertMinimumRefused(
        bytes32 key,
        uint128 units,
        uint256[] memory got,
        uint256 leg
    ) internal {
        address swap = _cCore().lpVaultSwap;
        uint256[] memory mins = new uint256[](2);
        (mins[0], mins[1]) = (got[0], got[1]);
        mins[leg] += 1;
        bytes memory data = abi.encodeCall(IAmmIntegration.unwind, (key, units, mins, swap));
        (bool ok,) = _cTry(swap, _cCore().coll, data);
        assertFalse(ok, "a minimum above the leg's amount reverts");
    }

    // ─── TEST-217: removal at any spot against the composition ───

    // TEST-217 verifies: INV-078, REQ-AMM-CORE-006, REQ-AMM-CORE-007, SPEC-BACK-008
    // Sources: 5.1 TEST-217 (LPVault part: oracle prices 0.01 to 2.0 per token, spot independent of them, removal of
    // 0 to 100 % of a position; the removal is never worth less at oracle prices than the composition credits)
    /// @notice For any oracle price vector, any spot tick of the pool and any removed share of a pledged position, the
    /// tokens `unwind` returns are worth at oracle prices at least the value of the `composition` the LPVault reports
    /// for the same units at those prices (floored, then reduced by one raw unit: rounding against the borrower).
    function testFuzz_TEST_217_removalAtAnySpotCoversTheComposition(
        uint256 p0,
        uint256 p1,
        int256 spot,
        uint256 shareBps
    ) public {
        (bytes32 key, uint128 units) = _cPledge(MKT_A, bob, 1e15);
        uint256[] memory prices = new uint256[](2);
        (prices[0], prices[1]) = (bound(p0, 1e6, 2e8), bound(p1, 1e6, 2e8));
        uint128 x = uint128(uint256(units) * bound(shareBps, 1, 10_000) / 10_000);
        vm.assume(x > 0);
        (uint256[] memory comp,) = _cVault().composition(MKT_A, x, prices);
        // forge-lint: disable-next-line(unsafe-typecast)
        _cPool(MKT_A).setPrice(int24(bound(spot, -5000, 5000)));
        address swap = _cCore().lpVaultSwap;
        bytes memory data = abi.encodeCall(IAmmIntegration.unwind, (key, x, _cZeros(), swap));
        uint256[] memory got = abi.decode(_cAs(swap, data), (uint256[]));
        // Both pool tokens have 6 decimals in both fixtures.
        assertGe(got[0] * prices[0] + got[1] * prices[1], comp[0] * prices[0] + comp[1] * prices[1], "under-backed");
    }

    // ─── TEST-116: the integration interface's custody rules ───

    // TEST-116 verifies: REQ-AMM-CORE-005, REQ-AMM-CORE-007, REQ-AMM-CORE-011, REQ-VAULT-147, INV-005
    // Sources: 5.1 TEST-116 (LPVault part, on mocked pools: exact range received, other ranges refused; unwind with
    // zero minimums at a moved spot; fees without principal; the pool derived from the position's own fields; a pledge
    // refused with PoolLocked while the pool's reentrancy flag is set)
    /// @notice A position at the market's exact range is received; one tick spacing off on either side reverts
    /// `RangeMismatch`; a position of another fee tier or spacing of the same pair reverts `PoolMismatch`; while the
    /// pool's reentrancy flag is set the pledge reverts `PoolLocked`. Fee collection pays the owed fees only, leaving
    /// the units; an unwind with zero minimums at a spot moved off the oracle price removes exactly the units.
    function test_TEST_116_custodyRulesThroughTheIntegrationInterface() public {
        Core memory c = _cCore();
        int24 sp = _spacingA();
        _assertRefused(_cMintRange(MKT_A, alice, MKT_A_LOWER - sp, MKT_A_UPPER, 1e9), RangeMismatch.selector);
        _assertRefused(_cMintRange(MKT_A, alice, MKT_A_LOWER, MKT_A_UPPER - sp, 1e9), RangeMismatch.selector);
        _assertRefused(_cMint(MKT_B, alice, 1e9), PoolMismatch.selector);
        bytes32 exact = _cMint(MKT_A, alice, 1e12);
        IClLockablePool(address(_cPool(MKT_A))).setUnlocked(false);
        _assertRefused(exact, PoolLocked.selector);
        IClLockablePool(address(_cPool(MKT_A))).setUnlocked(true);
        uint128 units = abi.decode(
            _cAs(c.adapter, abi.encodeCall(IAmmIntegration.receivePosition, (MKT_A, alice, exact))), (uint128)
        );
        assertEq(_cVault().depositorOf(exact), alice, "exact range received");
        _assertFeesOnly(exact, units);
        // Zero minimums at a spot moved off the oracle price remove exactly the units.
        _cPool(MKT_A).setPrice(40);
        _cAs(c.lpVaultSwap, abi.encodeCall(IAmmIntegration.unwind, (exact, units / 4, _cZeros(), c.lpVaultSwap)));
        assertEq(_cVault().unitsOf(exact), units - units / 4, "exactly the units removed");
    }

    /// @dev A pledge of `key` into market A reverts with `selector` and leaves no custody entry.
    function _assertRefused(
        bytes32 key,
        bytes4 selector
    ) internal {
        Core memory c = _cCore();
        (bool ok, bytes memory out) =
            _cTry(c.adapter, c.coll, abi.encodeCall(IAmmIntegration.receivePosition, (MKT_A, alice, key)));
        assertFalse(ok, "refused");
        assertEq(bytes4(out), selector, "refusal error");
        assertEq(_cVault().depositorOf(key), address(0), "no custody entry");
    }

    /// @dev Fees of 7 and 3 (6-decimal) tokens accrue to `key`; collection pays exactly them and leaves the units.
    function _assertFeesOnly(
        bytes32 key,
        uint128 units
    ) internal {
        _cManager(key).accrue(_cTokenId(key), 7e6, 3e6);
        uint256 a0 = _cToken(MKT_A, 0).balanceOf(alice);
        uint256 a1 = _cToken(MKT_A, 1).balanceOf(alice);
        _cAs(_cCore().adapter, abi.encodeCall(IAmmIntegration.collectFees, (key, alice)));
        assertEq(_cToken(MKT_A, 0).balanceOf(alice) - a0, 7e6, "fee 0 only");
        assertEq(_cToken(MKT_A, 1).balanceOf(alice) - a1, 3e6, "fee 1 only");
        assertEq(_cVault().unitsOf(key), units, "no principal taken");
    }

    /// @dev Tick spacing of market A's pool in both fixtures.
    function _spacingA() internal view virtual returns (int24);

    // ─── TEST-291: exploit-shape attempts on a pledged position ───

    // TEST-291 verifies: INV-002, INV-007, REQ-VAULT-097, REQ-VAULT-004, ATTACK-003, ATTACK-008
    // Sources: 5.1 TEST-291 (the attempts that apply to both LPVaults: the position manager's decreaseLiquidity,
    // collect, transferFrom, safeTransferFrom and approve-then-transfer by the depositor and by an operator set before
    // the pledge; a re-pledge naming the depositor or the LPVault as owner; every custody entry point outside
    // Collateralization or the Lock; the stray return)
    /// @notice A position whose owner set a `setApprovalForAll` operator before pledging is pledged; then every path
    /// that could lower its liquidity or move its NFT while it backs a record is tried by the depositor and by the
    /// operator. Every attempt fails, and after each one the LPVault still owns the NFT, the depositor of record is
    /// unchanged and the position still holds at least its credited units.
    function test_TEST_291_noPathReducesAPledgedPositionOrMovesItsNft() public {
        address operator = makeAddr("prePledgeOperator");
        bytes32 key = _cMint(MKT_A, alice, 1e12);
        vm.prank(alice);
        _cManager(key).setApprovalForAll(operator, true);
        uint128 units = abi.decode(
            _cAs(_cCore().adapter, abi.encodeCall(IAmmIntegration.receivePosition, (MKT_A, alice, key))), (uint128)
        );
        address[2] memory actors = [alice, operator];
        for (uint256 i = 0; i < 2; ++i) {
            _tryManagerPaths(key, actors[i]);
            _assertBacked(key, alice, units);
        }
        _tryRepledge(key, alice);
        _tryRepledge(key, address(_cVault()));
        _assertBacked(key, alice, units);
        bytes[5] memory calls = _entryPoints(key, key);
        for (uint256 i = 0; i < calls.length; ++i) {
            for (uint256 k = 0; k < 2; ++k) {
                (bool ok,) = _plain(actors[k], calls[i]);
                assertFalse(ok, "custody entry point outside Collateralization");
            }
            (bool okColl,) = _plain(_cCore().coll, calls[i]);
            assertFalse(okColl, "custody entry point outside the Lock");
        }
        _assertBacked(key, alice, units);
        vm.prank(_cCore().timelock);
        vm.expectRevert(NotStray.selector);
        _cVault().returnStray(key, operator);
        _assertBacked(key, alice, units);
    }

    /// @dev `who` tries the position manager's decreaseLiquidity, collect, transferFrom, safeTransferFrom and approve.
    function _tryManagerPaths(
        bytes32 key,
        address who
    ) internal {
        address m = address(_cManager(key));
        uint256 id = _cTokenId(key);
        address v = address(_cVault());
        bytes[5] memory calls;
        calls[0] = abi.encodeCall(
            IClPositionManager.decreaseLiquidity,
            (IClPositionManager.DecreaseLiquidityParams(id, 1, 0, 0, block.timestamp))
        );
        calls[1] = abi.encodeCall(
            IClPositionManager.collect,
            (IClPositionManager.CollectParams(id, who, type(uint128).max, type(uint128).max))
        );
        calls[2] = abi.encodeCall(IERC721.transferFrom, (v, who, id));
        calls[3] = abi.encodeWithSignature("safeTransferFrom(address,address,uint256)", v, who, id);
        calls[4] = abi.encodeCall(IERC721.approve, (who, id));
        for (uint256 i = 0; i < 5; ++i) {
            vm.prank(who);
            (bool ok,) = m.call(calls[i]);
            assertFalse(ok, "a position-manager path succeeded");
        }
    }

    /// @dev A pledge of the custodied `key` naming `owner` is refused.
    function _tryRepledge(
        bytes32 key,
        address owner
    ) internal {
        bytes memory data = abi.encodeCall(IAmmIntegration.receivePosition, (MKT_A, owner, key));
        (bool ok,) = _cTry(_cCore().adapter, _cCore().coll, data);
        assertFalse(ok, "re-pledge");
    }
}

/// @notice The suite on the Uniswap v3 LPVault.
/// forge-config: default.isolate = false
contract UniswapV3IntegrationLockGateUnitTest is ClLPVaultUniswapHooks, ClLPVaultLockGateTests {
    function _cMintRange(
        uint256 marketId,
        address owner,
        int24 lower,
        int24 upper,
        uint128 liquidity
    ) internal override returns (bytes32) {
        return _mint(owner, marketId == M1 ? pool500 : pool3000, lower, upper, liquidity);
    }

    function _spacingA() internal pure override returns (int24) {
        return 10;
    }
}

/// @notice The suite on the Slipstream LPVault.
/// forge-config: default.isolate = false
contract SlipstreamIntegrationLockGateUnitTest is ClLPVaultSlipstreamHooks, ClLPVaultLockGateTests {
    function _cMintRange(
        uint256 marketId,
        address owner,
        int24 lower,
        int24 upper,
        uint128 liquidity
    ) internal override returns (bytes32) {
        return marketId == M1
            ? _mint(owner, G1, pool1, lower, upper, liquidity)
            : _mint(owner, G2, pool100, lower, upper, liquidity);
    }

    function _spacingA() internal pure override returns (int24) {
        return 1;
    }
}
