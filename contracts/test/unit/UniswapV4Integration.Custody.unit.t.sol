// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ClPriceMath} from "../../src/amm/concentrated-liquidity/ClPriceMath.sol";
import {IUniswapV4Integration} from "../../src/amm/uniswap-v4/IUniswapV4Integration.sol";
import {UniswapV4State} from "../../src/amm/uniswap-v4/UniswapV4State.sol";
import {IUniswapV4PoolManager} from "../../src/interfaces/external/uniswap-v4/IUniswapV4PoolManager.sol";
import {IVaultToken} from "../../src/vault-token/vault-token/IVaultToken.sol";
import {IClPool} from "../utils/fixtures/ClPoolFixture.sol";
import {UniswapV4IntegrationFixture} from "../utils/fixtures/UniswapV4IntegrationFixture.sol";
import {CollPoolToken} from "../utils/mocks/CollateralizationMocks.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// @notice The Uniswap v4 LPVault's custody rules, ported from the concentrated-liquidity suites to the real v4
/// PositionManager and PoolManager: the return of a whole position to its depositor in every state (`TEST-018`), a
/// zero-unit position (`TEST-020`), `returnPosition` naming no recipient (`TEST-209`), the reconcile removal
/// (`TEST-150`), a hostile AaveAdapter (`TEST-130`), exits whatever the MarketRegistry and the spot (`TEST-099`), three
/// positions leaving for good (`TEST-195`), fee collection (`TEST-017`), the depositor's partial removal
/// (`TEST-237`), no top-up (`TEST-238`), split removals (`TEST-074`), re-entry from a pool token (`TEST-222`), approvals
/// and operators (`TEST-021`, `TEST-291`), the Lock (`TEST-060`, `TEST-270`), isolation from vault tokens and gates
/// (`TEST-162`), a transfer fee on a payout (`TEST-221`), the exact range and the clamp (`TEST-279`), and a removal at
/// any spot against the composition (`TEST-217`).
/// @dev v4 removals pay the position's owed fees to the depositor in the same batch (`REQ-AMM-V4-013`), so where the
/// concentrated-liquidity suites check that fees stay owed, these check that the depositor received them.
/// forge-config: default.isolate = false
contract UniswapV4IntegrationCustodyUnitTest is UniswapV4IntegrationFixture {
    uint256 internal constant M3 = 3;
    uint8 internal constant A_DECREASE_LIQUIDITY = 0x01;
    uint8 internal constant A_TAKE_PAIR = 0x11;

    PoolKey internal feeKey;

    // ─── Helpers ───

    function _pledge(
        address owner,
        uint128 liquidity
    ) internal returns (bytes32 key, uint128 units) {
        key = _mintFor(owner, stableKey, M1_LOWER, M1_UPPER, liquidity);
        units = _receive(M1, owner, key);
    }

    /// @dev `data` from `caller`, with the Lock held by `holder` (free when `holder` is 0).
    function _try(
        address holder,
        address caller,
        bytes memory data
    ) internal returns (bool ok, bytes memory out) {
        if (holder != address(0)) {
            vm.prank(holder);
            lock.acquire();
        }
        vm.prank(caller);
        (ok, out) = address(vault).call(data);
        if (holder != address(0)) {
            vm.prank(holder);
            lock.release();
        }
    }

    /// @dev `data` from Collateralization under `holder`'s Lock; reverts with the call's error.
    function _as(
        address holder,
        bytes memory data
    ) internal returns (bytes memory out) {
        bool ok;
        (ok, out) = _try(holder, coll, data);
        if (!ok) {
            assembly {
                revert(add(out, 32), mload(out))
            }
        }
    }

    function _assertFails(
        address holder,
        address caller,
        bytes memory data,
        bytes4 err
    ) internal {
        (bool ok, bytes memory out) = _try(holder, caller, data);
        assertFalse(ok, "refused");
        assertEq(bytes4(out), err, "error");
    }

    function _positionId(
        PoolKey memory k,
        bytes32 key
    ) internal view returns (bytes32 id, bytes32 positionId) {
        id = _poolId(k);
        (int24 lower, int24 upper) = _range(k);
        positionId = UniswapV4State.positionId(address(posm), lower, upper, key);
    }

    function _range(
        PoolKey memory k
    ) internal view returns (int24, int24) {
        return _poolId(k) == _poolId(ethKey) ? (M2_LOWER, M2_UPPER) : (M1_LOWER, M1_UPPER);
    }

    function _liquidity(
        PoolKey memory k,
        bytes32 key
    ) internal view returns (uint128) {
        (bytes32 id, bytes32 positionId) = _positionId(k, key);
        return UniswapV4State.positionLiquidity(IUniswapV4PoolManager(address(pm)), id, positionId);
    }

    function _owed(
        PoolKey memory k,
        bytes32 key
    ) internal view returns (uint256 f0, uint256 f1) {
        IUniswapV4PoolManager m = IUniswapV4PoolManager(address(pm));
        (bytes32 id, bytes32 positionId) = _positionId(k, key);
        (int24 lower, int24 upper) = _range(k);
        (uint256 in0, uint256 in1) = UniswapV4State.feeGrowthInside(m, id, lower, upper);
        (f0, f1) = UniswapV4State.feesOwed(UniswapV4State.position(m, id, positionId), in0, in1);
    }

    function _scale() internal view returns (uint128) {
        return uint128(10 ** vault.unitExponent(M1));
    }

    /// @dev Custody, depositor of record and at least the credited units of liquidity.
    function _assertBacked(
        bytes32 key,
        address depositor,
        uint128 units
    ) internal view {
        assertEq(posm.ownerOf(uint256(key)), address(vault), "the LPVault owns the NFT");
        assertEq(vault.depositorOf(key), depositor, "depositor of record");
        assertGe(_liquidity(stableKey, key), uint256(units) * _scale(), "liquidity backs the credited units");
    }

    function _entryPoints(
        bytes32 key,
        bytes32 fresh
    ) internal view returns (bytes[5] memory calls) {
        calls = [
            abi.encodeCall(vault.receivePosition, (M1, alice, fresh)),
            abi.encodeCall(vault.returnPosition, (key)),
            abi.encodeCall(vault.unwind, (key, 1, _zeros(), lpVaultSwap)),
            abi.encodeCall(vault.releaseToDepositor, (key, 1, _zeros())),
            abi.encodeCall(vault.collectFees, (key, bob))
        ];
    }

    function _decreaseData(
        PoolKey memory k,
        uint256 tokenId,
        address to
    ) internal pure returns (bytes memory) {
        bytes memory actions = abi.encodePacked(A_DECREASE_LIQUIDITY, A_TAKE_PAIR);
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(tokenId, uint256(1), uint128(0), uint128(0), bytes(""));
        params[1] = abi.encode(k.currency0, k.currency1, to);
        return abi.encode(actions, params);
    }

    function _increaseData(
        PoolKey memory k,
        uint256 tokenId
    ) internal pure returns (bytes memory) {
        bytes memory actions = abi.encodePacked(uint8(0x00), A_SETTLE_PAIR);
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(tokenId, uint256(1e12), type(uint128).max, type(uint128).max, bytes(""));
        params[1] = abi.encode(k.currency0, k.currency1);
        return abi.encode(actions, params);
    }

    /// @dev Market `M3`: a stable pool of two `CollPoolToken`s (a transfer fee and a transfer hook each) on the M1 range,
    /// with its Uniswap v3 reference pool.
    function _bindHookMarket() internal returns (CollPoolToken t0, CollPoolToken t1) {
        CollPoolToken a = new CollPoolToken("HK0", 6);
        CollPoolToken b = new CollPoolToken("HK1", 6);
        (t0, t1) = address(a) < address(b) ? (a, b) : (b, a);
        feeKey = _key(address(t0), address(t1), 100, 1);
        _initPool(feeKey, ONE, ONE, 6, 6);
        IClPool ref = _referencePool(address(t0), address(t1), ONE, ONE, CARDINALITY, 1e18);
        _observe(ref, 3);
        _bindV4(M3, feeKey, address(ref), M1_LOWER, M1_UPPER, ONE, ONE);
    }

    /// @dev Whether `code` pushes `selector` as a 4-byte constant (PUSH4).
    function _pushes(
        bytes memory code,
        bytes4 selector
    ) internal pure returns (bool) {
        for (uint256 i = 0; i + 4 < code.length; ++i) {
            if (
                code[i] == 0x63 && code[i + 1] == selector[0] && code[i + 2] == selector[1]
                    && code[i + 3] == selector[2] && code[i + 4] == selector[3]
            ) return true;
        }
        return false;
    }

    // ─── Debt-free withdrawal and zero-credit release ───

    // TEST-018 verifies: REQ-VAULT-152, REQ-VAULT-005, INV-007, INV-045
    /// @notice Three pledged positions carrying owed fees, with the spot at three places, are each returned whole to the
    /// depositor by one `transferFrom`, with `PositionReturned`, their liquidity and owed fees unchanged and their custody
    /// entry gone; the LPVault never calls the MarketRegistry.
    function test_TEST_018_returnSendsTheWholeNftToItsDepositor() public {
        vm.expectCall(registry, "", 0);
        int24[3] memory spots = [int24(0), int24(-30), int24(200)];
        for (uint256 i = 0; i < 3; ++i) {
            (bytes32 key,) = _pledge(alice, 1e15);
            _washV4(stableKey, 1e12);
            _swapV4To(stableKey, ClPriceMath.sqrtRatioAtTick(spots[i]));
            uint128 liquidity = _liquidity(stableKey, key);
            (uint256 f0, uint256 f1) = _owed(stableKey, key);
            assertGt(f0 + f1, 0, "owed fees");
            vm.expectCall(
                address(posm),
                abi.encodeWithSelector(IERC721.transferFrom.selector, address(vault), alice, uint256(key)),
                1
            );
            _lock();
            vm.expectEmit(true, true, false, false, address(vault));
            emit PositionReturned(key, alice);
            vm.prank(coll);
            vault.returnPosition(key);
            _unlock();
            assertEq(posm.ownerOf(uint256(key)), alice, "back with its depositor");
            assertEq(_liquidity(stableKey, key), liquidity, "with all its liquidity");
            (uint256 g0, uint256 g1) = _owed(stableKey, key);
            assertEq(g0, f0, "and its owed fees");
            assertEq(g1, f1);
            assertFalse(vault.isInCustody(key));
            assertEq(vault.depositorOf(key), address(0));
        }
    }

    // TEST-020 verifies: REQ-VAULT-079, REQ-VAULT-152, REQ-AMM-CORE-010
    /// @notice A position seized down to zero units stays in custody with its depositor and is not a stray; the seizure
    /// paid its owed fees to the depositor, a later fee collection succeeds, and the release returns it.
    function test_TEST_020_zeroUnitPositionStaysInCustodyAndReturns() public {
        (bytes32 key, uint128 units) = _pledge(alice, 1e15);
        _washV4(stableKey, 1e12);
        (uint256 f0, uint256 f1) = _owed(stableKey, key);
        (uint256 a0, uint256 a1) = _balances(M1, alice);
        _as(lpVaultSwap, abi.encodeCall(vault.unwind, (key, units, _zeros(), lpVaultSwap)));
        (uint256 b0, uint256 b1) = _balances(M1, alice);
        assertEq(b0 - a0, f0, "owed fees to the depositor");
        assertEq(b1 - a1, f1);
        assertEq(vault.unitsOf(key), 0, "fully seized");
        assertTrue(vault.isInCustody(key), "the zero-unit position stays in custody");
        assertEq(vault.depositorOf(key), alice);
        vm.prank(timelock);
        vm.expectRevert(NotStray.selector);
        vault.returnStray(key, bob);
        _as(adapter, abi.encodeCall(vault.collectFees, (key, alice)));
        _as(adapter, abi.encodeCall(vault.returnPosition, (key)));
        assertEq(posm.ownerOf(uint256(key)), alice, "released to the depositor");
        assertFalse(vault.isInCustody(key));
    }

    // TEST-209 verifies: INV-007, REQ-VAULT-152
    /// @notice `returnPosition` takes only the position key and sends the NFT to the depositor of record by
    /// `transferFrom`, under either Lock member's session; it has no recipient overload, and a second return reverts.
    function test_TEST_209_returnPositionPaysOnlyTheDepositorOfRecord() public {
        (bytes32 k1,) = _pledge(alice, 1e15);
        (bytes32 k2,) = _pledge(bob, 1e15);
        (bool overload,) = address(vault).call(abi.encodeWithSignature("returnPosition(bytes32,address)", k1, carol));
        assertFalse(overload, "no recipient can be named");
        vm.expectCall(
            address(posm), abi.encodeWithSelector(IERC721.transferFrom.selector, address(vault), alice, uint256(k1)), 1
        );
        _as(adapter, abi.encodeCall(vault.returnPosition, (k1)));
        _as(lpVaultSwap, abi.encodeCall(vault.returnPosition, (k2)));
        assertEq(posm.ownerOf(uint256(k1)), alice);
        assertEq(posm.ownerOf(uint256(k2)), bob);
        _assertFails(adapter, coll, abi.encodeCall(vault.returnPosition, (k1)), NotInCustody.selector);
    }

    // ─── Seizure, reconcile and a hostile Adapter ───

    // TEST-150 verifies: REQ-VAULT-149, SPEC-BACK-008, REQ-VAULT-152
    /// @notice The worked example on the v4 LPVault: records of 1,000 (NFT 42) and 800 (NFT 7) units; the reconcile
    /// inside the withdrawal removes exactly 315 units of NFT 42 with zero minimums to Collateralization and pays its owed
    /// fees to the depositor; NFT 42 returns with 685 units of liquidity and NFT 7 keeps 800.
    function test_TEST_150_reconcileRemovesTheShortfallAndReturnsTheRest() public {
        uint128 scale = _scale();
        (bytes32 nft42, uint128 u42) = _pledge(alice, 1000 * scale);
        (bytes32 nft7, uint128 u7) = _pledge(alice, 800 * scale);
        assertEq(u42, 1000);
        assertEq(u7, 800);
        _washV4(stableKey, 1e12);
        _reconcile315(nft42);
        assertEq(vault.unitsOf(nft42), 685);
        _as(adapter, abi.encodeCall(vault.returnPosition, (nft42)));
        assertEq(posm.ownerOf(uint256(nft42)), alice);
        assertEq(_liquidity(stableKey, nft42), 685 * uint256(scale), "NFT 42 returns with 685 units of liquidity");
        assertEq(vault.unitsOf(nft7), 800, "NFT 7 untouched");
        assertEq(vault.depositorOf(nft7), alice);
    }

    /// @dev The reconcile removal of 315 units of `key`: the principal to Collateralization, the owed fees to the
    /// depositor alice.
    function _reconcile315(
        bytes32 key
    ) internal {
        (uint256 f0, uint256 f1) = _owed(stableKey, key);
        (uint256 c0, uint256 c1) = _balances(M1, coll);
        (uint256 a0, uint256 a1) = _balances(M1, alice);
        uint256[] memory removed =
            abi.decode(_as(adapter, abi.encodeCall(vault.unwind, (key, 315, _zeros(), coll))), (uint256[]));
        (uint256 d0, uint256 d1) = _balances(M1, coll);
        assertEq(d0 - c0, removed[0], "the pending tokens go to Collateralization");
        assertEq(d1 - c1, removed[1]);
        (uint256 b0, uint256 b1) = _balances(M1, alice);
        assertEq(b0 - a0, f0, "the owed fees go to the depositor");
        assertEq(b1 - a1, f1);
    }

    // TEST-130 verifies: REQ-VAULT-098, REQ-VAULT-064, INV-007, INV-033
    /// @notice A hostile AaveAdapter holding the Lock can call no custody function itself; through Collateralization a
    /// fee collection naming anyone but the depositor reverts, and a partial removal and the return pay only the
    /// depositor; the Adapter can never move the NFT out of the LPVault.
    function test_TEST_130_hostileAdapterCannotMovePositionsOrFeesElsewhere() public {
        (bytes32 key, uint128 units) = _pledge(alice, 1e15);
        _washV4(stableKey, 1e12);
        bytes[3] memory direct = [
            abi.encodeCall(vault.returnPosition, (key)),
            abi.encodeCall(vault.releaseToDepositor, (key, 1, _zeros())),
            abi.encodeCall(vault.collectFees, (key, adapter))
        ];
        for (uint256 i = 0; i < 3; ++i) {
            _assertFails(adapter, adapter, direct[i], NotCollateralization.selector);
        }
        address[2] memory takers = [adapter, carol];
        for (uint256 i = 0; i < 2; ++i) {
            _assertFails(adapter, coll, abi.encodeCall(vault.collectFees, (key, takers[i])), NotDepositor.selector);
        }
        vm.prank(adapter);
        vm.expectRevert();
        posm.transferFrom(address(vault), adapter, uint256(key));
        (uint256 a0, uint256 a1) = _balances(M1, adapter);
        _as(adapter, abi.encodeCall(vault.releaseToDepositor, (key, units / 2, _zeros())));
        _as(adapter, abi.encodeCall(vault.returnPosition, (key)));
        (uint256 b0, uint256 b1) = _balances(M1, adapter);
        assertEq(b0 + b1, a0 + a1, "the Adapter received nothing");
        assertEq(posm.ownerOf(uint256(key)), alice, "the NFT went only to its depositor");
    }

    // ─── Exits under every state ───

    // TEST-099 verifies: REQ-VAULT-005, REQ-VAULT-098, INV-044, INV-045
    /// @notice With the MarketRegistry address reverting, answering garbage or holding no code, and the spot anywhere
    /// around the range, fee collection, a partial removal, a seizure, a reconcile removal and the return all succeed.
    function testFuzz_TEST_099_exitsSucceedWithAnyRegistryAndSpot(
        uint8 mode,
        int24 tick
    ) public {
        if (mode % 3 == 0) vm.etch(registry, hex"60006000fd");
        else if (mode % 3 == 1) vm.etch(registry, hex"60206000f3");
        vm.expectCall(registry, "", 0);
        (bytes32 key, uint128 units) = _pledge(alice, 1e15);
        _washV4(stableKey, 1e12);
        _swapV4To(stableKey, ClPriceMath.sqrtRatioAtTick(int24(bound(tick, -500, 500))));
        _as(adapter, abi.encodeCall(vault.collectFees, (key, alice)));
        _as(adapter, abi.encodeCall(vault.releaseToDepositor, (key, units / 4, _zeros())));
        _as(lpVaultSwap, abi.encodeCall(vault.unwind, (key, units / 4, _zeros(), lpVaultSwap)));
        _as(adapter, abi.encodeCall(vault.unwind, (key, units / 8, _zeros(), coll)));
        _as(adapter, abi.encodeCall(vault.returnPosition, (key)));
        assertEq(posm.ownerOf(uint256(key)), alice, "every exit reached the depositor");
    }

    // TEST-195 verifies: INV-045, REQ-VAULT-152
    /// @notice Three positions in two markets, one of them native ETH, return whole to their depositor with no
    /// MarketRegistry read; afterwards no custody call through any Lock session reaches them, so a later Adapter finds
    /// nothing.
    function test_TEST_195_threeNftsLeaveAndNothingRemains() public {
        vm.expectCall(registry, "", 0);
        bytes32[3] memory keys;
        PoolKey[3] memory pools = [stableKey, stableKey, ethKey];
        (keys[0],) = _pledge(alice, 1e15);
        (keys[1],) = _pledge(alice, 2e15);
        keys[2] = _mintFor(alice, ethKey, M2_LOWER, M2_UPPER, 1e18);
        _receive(M2, alice, keys[2]);
        uint128[3] memory liq;
        for (uint256 i = 0; i < 3; ++i) {
            liq[i] = _liquidity(pools[i], keys[i]);
            _as(adapter, abi.encodeCall(vault.returnPosition, (keys[i])));
        }
        for (uint256 i = 0; i < 3; ++i) {
            assertEq(posm.ownerOf(uint256(keys[i])), alice);
            assertEq(_liquidity(pools[i], keys[i]), liq[i], "returned whole");
            bytes[3] memory calls = [
                abi.encodeCall(vault.unwind, (keys[i], 1, _zeros(), lpVaultSwap)),
                abi.encodeCall(vault.returnPosition, (keys[i])),
                abi.encodeCall(vault.releaseToDepositor, (keys[i], 1, _zeros()))
            ];
            for (uint256 j = 0; j < 3; ++j) {
                _assertFails(adapter, coll, calls[j], NotInCustody.selector);
            }
        }
    }

    // ─── Fees, partial removal and top-up ───

    // TEST-017 verifies: REQ-VAULT-126, REQ-VAULT-064, REQ-AMM-CORE-010, REQ-AMM-V4-010
    /// @notice Only the depositor of record is paid fees (`NotDepositor` otherwise), only under the AaveAdapter's Lock
    /// (`LockNotHeld` without it or under LPVaultSwap's), and the collection pays exactly every owed amount.
    function test_TEST_017_collectFeesPaysEveryOwedAmountOnlyToTheDepositor() public {
        (bytes32 key,) = _pledge(alice, 1e15);
        _washV4(stableKey, 1e12);
        (uint256 f0, uint256 f1) = _owed(stableKey, key);
        assertGt(f0 + f1, 0);
        _assertFails(adapter, coll, abi.encodeCall(vault.collectFees, (key, bob)), NotDepositor.selector);
        _assertFails(lpVaultSwap, coll, abi.encodeCall(vault.collectFees, (key, alice)), LockNotHeld.selector);
        _assertFails(address(0), coll, abi.encodeCall(vault.collectFees, (key, alice)), LockNotHeld.selector);
        (uint256 a0, uint256 a1) = _balances(M1, alice);
        uint256[] memory fees = abi.decode(_as(adapter, abi.encodeCall(vault.collectFees, (key, alice))), (uint256[]));
        (uint256 b0, uint256 b1) = _balances(M1, alice);
        assertEq(fees[0], f0, "every owed amount");
        assertEq(fees[1], f1);
        assertEq(b0 - a0, f0, "paid to the depositor");
        assertEq(b1 - a1, f1);
        (uint256 g0, uint256 g1) = _owed(stableKey, key);
        assertEq(g0 + g1, 0, "nothing left owed");
    }

    // TEST-237 verifies: REQ-VAULT-150, REQ-AMM-CORE-008, SPEC-AMM-V4-003
    /// @notice `releaseToDepositor` removes exactly `units × 10^k` liquidity and pays the removed principal to the
    /// depositor of record alone; Collateralization and the Lock members receive nothing.
    function test_TEST_237_releaseToDepositorPaysOnlyTheDepositor() public {
        (bytes32 key, uint128 units) = _pledge(alice, 1e15);
        uint128 part = units / 4;
        uint256 left = _liquidity(stableKey, key) - uint256(part) * _scale();
        (uint256 a0, uint256 a1) = _balances(M1, alice);
        uint256[] memory amounts =
            abi.decode(_as(adapter, abi.encodeCall(vault.releaseToDepositor, (key, part, _zeros()))), (uint256[]));
        (uint256 b0, uint256 b1) = _balances(M1, alice);
        assertEq(b0 - a0, amounts[0], "principal to the depositor");
        assertEq(b1 - a1, amounts[1]);
        assertGt(amounts[0] + amounts[1], 0);
        address[3] memory others = [coll, lpVaultSwap, adapter];
        for (uint256 i = 0; i < 3; ++i) {
            (uint256 o0, uint256 o1) = _balances(M1, others[i]);
            assertEq(o0 + o1, 0, "nothing to Collateralization or a Lock member");
        }
        assertEq(_liquidity(stableKey, key), left, "exactly the released liquidity");
        assertEq(vault.unitsOf(key), units - part);
    }

    // TEST-238 verifies: REQ-AMM-V4-014, REQ-AMM-CORE-011
    /// @notice A pledged v4 position takes no re-credit: `topUpPosition` reverts `TopUpNotSupported` for
    /// Collateralization under the Lock and `NotCollateralization` for the depositor, and no one can add liquidity to the
    /// NFT through the PositionManager, so the credited units never change.
    function test_TEST_238_aPledgedV4PositionIsNeverRecredited() public {
        (bytes32 key, uint128 units) = _pledge(alice, 1e15);
        _assertFails(
            adapter, coll, abi.encodeCall(vault.topUpPosition, (key, alice, hex"01")), TopUpNotSupported.selector
        );
        _assertFails(
            adapter, alice, abi.encodeCall(vault.topUpPosition, (key, alice, hex"01")), NotCollateralization.selector
        );
        address[2] memory others = [alice, carol];
        for (uint256 i = 0; i < 2; ++i) {
            vm.prank(others[i]);
            vm.expectRevert();
            posm.modifyLiquidities(_increaseData(stableKey, uint256(key)), block.timestamp);
        }
        assertEq(vault.unitsOf(key), units, "nothing to re-credit");
        _assertBacked(key, alice, units);
    }

    // TEST-074 verifies: REQ-VAULT-095, SPEC-BACK-008, Q-061
    /// @notice Two equal positions at any spot: unwinding one in 2 to 12 pieces never returns more of either token than
    /// unwinding the other at once.
    function testFuzz_TEST_074_splitUnwindNeverReturnsMore(
        uint128 total,
        uint8 pieces,
        int24 tick
    ) public {
        _swapV4To(stableKey, ClPriceMath.sqrtRatioAtTick(int24(bound(tick, -60, 60))));
        total = uint128(bound(total, 1e3, 1e9));
        pieces = uint8(bound(pieces, 2, 12));
        (bytes32 a, uint128 ua) = _pledge(alice, total * _scale());
        (bytes32 b, uint128 ub) = _pledge(bob, total * _scale());
        assertEq(ua, ub);
        uint256[] memory whole =
            abi.decode(_as(lpVaultSwap, abi.encodeCall(vault.unwind, (a, ua, _zeros(), lpVaultSwap))), (uint256[]));
        uint256 s0;
        uint256 s1;
        uint128 left = ub;
        for (uint256 i = 0; i < pieces; ++i) {
            uint128 take = i + 1 == pieces ? left : ub / pieces;
            left -= take;
            if (take == 0) continue;
            uint256[] memory part = abi.decode(
                _as(lpVaultSwap, abi.encodeCall(vault.unwind, (b, take, _zeros(), lpVaultSwap))), (uint256[])
            );
            s0 += part[0];
            s1 += part[1];
        }
        assertLe(s0, whole[0], "token0");
        assertLe(s1, whole[1], "token1");
        assertEq(vault.unitsOf(b), 0);
    }

    // TEST-222 verifies: REQ-VAULT-067, REQ-VAULT-150, REQ-VAULT-151, ATTACK-092
    /// @notice A pool token with a transfer hook re-enters the LPVault while the PoolManager pays a removal: a custody
    /// view reverts `Locked`, a pledge and a fee collection revert `NotCollateralization`, and nothing changes.
    function test_TEST_222_reentryFromAPoolTokenDuringARemovalChangesNothing() public {
        (CollPoolToken t0,) = _bindHookMarket();
        bytes32 key = _mintFor(alice, feeKey, M1_LOWER, M1_UPPER, 1e15);
        uint128 units = _receive(M3, alice, key);
        bytes32 other = _mintFor(bob, feeKey, M1_LOWER, M1_UPPER, 1e12);
        uint128 step = units / 10;
        bytes[3] memory hooks = [
            abi.encodeCall(vault.depositorOf, (key)),
            abi.encodeCall(vault.receivePosition, (M3, bob, other)),
            abi.encodeCall(vault.collectFees, (key, alice))
        ];
        bytes4[3] memory errs = [Locked.selector, NotCollateralization.selector, NotCollateralization.selector];
        for (uint256 i = 0; i < 3; ++i) {
            t0.armHook(address(vault), hooks[i]);
            if (i == 2) _as(adapter, abi.encodeCall(vault.releaseToDepositor, (key, step, _zeros())));
            else _as(lpVaultSwap, abi.encodeCall(vault.unwind, (key, step, _zeros(), lpVaultSwap)));
            assertTrue(t0.hookFired(), "the hook ran mid-removal");
            assertFalse(t0.hookSucceeded(), "the re-entry was refused");
            assertEq(bytes4(t0.hookReturn()), errs[i]);
        }
        assertEq(posm.ownerOf(uint256(other)), bob, "the other NFT never moved");
        assertEq(vault.unitsOf(key), units - 3 * step);
        assertEq(vault.depositorOf(key), alice);
    }

    // ─── Approvals and operators ───

    // TEST-021 verifies: REQ-VAULT-097, REQ-VAULT-004, ATTACK-008
    /// @notice Across a pledge, a fee collection, a partial removal, a seizure and the return, the LPVault calls neither
    /// `approve`, `setApprovalForAll` nor `safeTransferFrom`; the approval set before the pledge is cleared, neither the
    /// previous owner nor its operator can move the NFT or its liquidity, and the LPVault has no ERC-1271.
    function test_TEST_021_noApprovalsAndNoOperatorRights() public {
        bytes32 key = _mintFor(alice, stableKey, M1_LOWER, M1_UPPER, 1e15);
        uint256 id = uint256(key);
        vm.prank(alice);
        IERC721(address(posm)).setApprovalForAll(bob, true);
        vm.expectCall(address(posm), abi.encodeWithSelector(IERC721.approve.selector), 0);
        vm.expectCall(address(posm), abi.encodeWithSelector(IERC721.setApprovalForAll.selector), 0);
        vm.expectCall(address(posm), abi.encodeWithSignature("safeTransferFrom(address,address,uint256)"), 0);
        vm.expectCall(address(posm), abi.encodeWithSignature("safeTransferFrom(address,address,uint256,bytes)"), 0);
        uint128 units = _receive(M1, alice, key);
        assertEq(IERC721(address(posm)).getApproved(id), address(0), "the pre-pledge approval is cleared");
        address[2] memory others = [alice, bob];
        for (uint256 i = 0; i < 2; ++i) {
            vm.prank(others[i]);
            vm.expectRevert();
            posm.transferFrom(address(vault), others[i], id);
            vm.prank(others[i]);
            vm.expectRevert();
            posm.modifyLiquidities(_decreaseData(stableKey, id, others[i]), block.timestamp);
        }
        _washV4(stableKey, 1e12);
        _as(adapter, abi.encodeCall(vault.collectFees, (key, alice)));
        _as(adapter, abi.encodeCall(vault.releaseToDepositor, (key, units / 4, _zeros())));
        _as(lpVaultSwap, abi.encodeCall(vault.unwind, (key, units / 4, _zeros(), lpVaultSwap)));
        _as(adapter, abi.encodeCall(vault.returnPosition, (key)));
        assertEq(posm.ownerOf(id), alice);
        (bool ok,) = address(vault).call(abi.encodeWithSignature("isValidSignature(bytes32,bytes)", bytes32(0), ""));
        assertFalse(ok, "no ERC-1271");
    }

    // TEST-291 verifies: INV-002, INV-007, REQ-VAULT-097, REQ-VAULT-004, ATTACK-003, ATTACK-008
    /// @notice A position whose owner set a `setApprovalForAll` operator before pledging is pledged; then the
    /// depositor and the operator try the PositionManager's transfers and liquidity removal, a re-pledge, every custody
    /// entry point outside Collateralization or the Lock, and the stray return. Every attempt fails and the position
    /// stays in custody with its depositor and at least its credited liquidity.
    function test_TEST_291_noPathReducesAPledgedPositionOrMovesItsNft() public {
        address operator = makeAddr("prePledgeOperator");
        bytes32 key = _mintFor(alice, stableKey, M1_LOWER, M1_UPPER, 1e15);
        vm.prank(alice);
        IERC721(address(posm)).setApprovalForAll(operator, true);
        uint128 units = _receive(M1, alice, key);
        address[2] memory actors = [alice, operator];
        for (uint256 i = 0; i < 2; ++i) {
            vm.startPrank(actors[i]);
            vm.expectRevert();
            posm.transferFrom(address(vault), actors[i], uint256(key));
            vm.expectRevert();
            IERC721(address(posm)).safeTransferFrom(address(vault), actors[i], uint256(key));
            vm.expectRevert();
            posm.modifyLiquidities(_decreaseData(stableKey, uint256(key), actors[i]), block.timestamp);
            vm.stopPrank();
            _assertBacked(key, alice, units);
        }
        address[2] memory owners = [alice, address(vault)];
        for (uint256 i = 0; i < 2; ++i) {
            (bool again,) = _try(adapter, coll, abi.encodeCall(vault.receivePosition, (M1, owners[i], key)));
            assertFalse(again, "no re-pledge");
        }
        bytes[5] memory calls = _entryPoints(key, key);
        for (uint256 i = 0; i < calls.length; ++i) {
            for (uint256 k = 0; k < 2; ++k) {
                (bool ok,) = _try(address(0), actors[k], calls[i]);
                assertFalse(ok, "custody entry point outside Collateralization");
            }
            (bool okColl,) = _try(address(0), coll, calls[i]);
            assertFalse(okColl, "custody entry point outside the Lock");
        }
        vm.prank(timelock);
        vm.expectRevert(NotStray.selector);
        vault.returnStray(key, operator);
        _assertBacked(key, alice, units);
    }

    // ─── The Lock ───

    // TEST-060 verifies: REQ-LOCK-028, REQ-VAULT-165, INV-091, REQ-VAULT-147, REQ-VAULT-148, REQ-VAULT-149
    /// @notice Without the Lock, Collateralization's custody calls revert `LockNotHeld`; under either member's Lock the
    /// member itself or an outsider gets `NotCollateralization`; from Collateralization under the Lock each succeeds.
    /// While the Lock is held `returnStray` reverts `Locked` even for the timelock and the custody views revert `Locked`
    /// for an outsider; once it is free the stray leaves.
    function test_TEST_060_valueMovesOnlyUnderTheLockFromCollateralization() public {
        (bytes32 key,) = _pledge(bob, 1e15);
        bytes32 fresh = _mintFor(alice, stableKey, M1_LOWER, M1_UPPER, 1e12);
        bytes[5] memory calls = _entryPoints(key, fresh);
        address[2] memory holders = [adapter, lpVaultSwap];
        for (uint256 i = 0; i < calls.length; ++i) {
            _assertFails(address(0), coll, calls[i], LockNotHeld.selector);
            for (uint256 h = 0; h < 2; ++h) {
                _assertFails(holders[h], holders[h], calls[i], NotCollateralization.selector);
                _assertFails(holders[h], alice, calls[i], NotCollateralization.selector);
            }
        }
        _as(adapter, calls[4]);
        _as(adapter, calls[3]);
        _as(lpVaultSwap, calls[2]);
        _as(adapter, calls[0]);
        assertEq(vault.depositorOf(fresh), alice, "received under the Lock");
        uint256 stray = _mintV4(carol, stableKey, M1_LOWER, M1_UPPER, 1e12);
        vm.prank(carol);
        posm.transferFrom(carol, address(vault), stray);
        _lock();
        vm.prank(timelock);
        vm.expectRevert(Locked.selector);
        vault.returnStray(bytes32(stray), carol);
        vm.prank(alice);
        vm.expectRevert(Locked.selector);
        vault.depositorOf(key);
        vm.prank(alice);
        vm.expectRevert(Locked.selector);
        vault.unitsOf(key);
        vm.prank(coll);
        assertGt(vault.unitsOf(key), 0, "Collateralization reads units under the Lock");
        _unlock();
        _as(adapter, calls[1]);
        assertEq(posm.ownerOf(uint256(key)), bob, "returned under the Lock");
        vm.prank(timelock);
        vault.returnStray(bytes32(stray), carol);
        assertEq(posm.ownerOf(stray), carol, "the stray leaves once the Lock is free");
    }

    // TEST-270 verifies: REQ-LOCK-028, INV-091, REQ-VAULT-165, REQ-VAULT-079
    /// @notice An EOA, a PositionProxy address, another v4 LPVault and the two Lock members themselves move nothing
    /// through the LPVault, with the Lock free or held by either member; `returnStray` refuses a position in custody; a
    /// second market takes a pledge, a seizure and a return with the same Lock and the same two members.
    function test_TEST_270_noOtherCallerMovesValueAndAnotherMarketUsesTheSameLock() public {
        (bytes32 key, uint128 units) = _pledge(bob, 1e15);
        bytes32 fresh = _mintFor(alice, stableKey, M1_LOWER, M1_UPPER, 1e12);
        address otherVault = deployCode(
            "UniswapV4Integration.sol:UniswapV4Integration",
            abi.encode(
                INTEGRATION + 1, coll, registry, address(lock), timelock, address(posm), address(factory), uint256(12)
            )
        );
        address[5] memory callers = [alice, makeAddr("positionProxy"), otherVault, adapter, lpVaultSwap];
        address[3] memory holders = [address(0), adapter, lpVaultSwap];
        bytes[5] memory calls = _entryPoints(key, fresh);
        for (uint256 i = 0; i < calls.length; ++i) {
            for (uint256 k = 0; k < callers.length; ++k) {
                for (uint256 h = 0; h < holders.length; ++h) {
                    (bool ok,) = _try(holders[h], callers[k], calls[i]);
                    assertFalse(ok, "no caller but Collateralization moves value");
                }
            }
        }
        _assertBacked(key, bob, units);
        vm.prank(timelock);
        vm.expectRevert(NotStray.selector);
        vault.returnStray(key, alice);
        bytes32 eth = _mintFor(alice, ethKey, M2_LOWER, M2_UPPER, 1e18);
        uint128 ethUnits = _receive(M2, alice, eth);
        _as(lpVaultSwap, abi.encodeCall(vault.unwind, (eth, ethUnits / 2, _zeros(), lpVaultSwap)));
        _as(adapter, abi.encodeCall(vault.returnPosition, (eth)));
        assertEq(posm.ownerOf(uint256(eth)), alice, "the second market runs on the same Lock");
    }

    // ─── Isolation and token edge cases ───

    // TEST-162 verifies: REQ-VAULT-005, REQ-VAULT-098, REQ-VAULT-039, REQ-VAULT-040, REQ-VAULT-041, REQ-VAULT-045, REQ-VAULT-096
    /// @notice With the MarketRegistry reverting on every call, a pledge, a fee collection, a partial removal, a seizure,
    /// a reconcile removal and the return all succeed without the LPVault calling the MarketRegistry, the AaveAdapter,
    /// LPVaultSwap, the timelock or Collateralization; it has no pause of its own and its code holds no vault-token
    /// mint, burn or proxy-registration selector.
    function test_TEST_162_lpVaultTouchesNoVaultTokenGateOrUpgradeableContract() public {
        vm.etch(registry, hex"60006000fd");
        address[5] memory denied = [registry, adapter, lpVaultSwap, timelock, coll];
        for (uint256 i = 0; i < denied.length; ++i) {
            vm.expectCall(denied[i], "", 0);
        }
        (bytes32 key, uint128 units) = _pledge(alice, 1e15);
        _washV4(stableKey, 1e12);
        _as(adapter, abi.encodeCall(vault.collectFees, (key, alice)));
        _as(adapter, abi.encodeCall(vault.releaseToDepositor, (key, units / 4, _zeros())));
        _as(lpVaultSwap, abi.encodeCall(vault.unwind, (key, units / 4, _zeros(), lpVaultSwap)));
        _as(adapter, abi.encodeCall(vault.unwind, (key, units / 8, _zeros(), coll)));
        _as(adapter, abi.encodeCall(vault.returnPosition, (key)));
        (bool hasPause,) = address(vault).call(abi.encodeWithSignature("pause()"));
        (bool hasPaused,) = address(vault).call(abi.encodeWithSignature("paused()"));
        assertFalse(hasPause || hasPaused, "no pause of its own");
        bytes memory code = address(vault).code;
        assertTrue(_pushes(code, posm.modifyLiquidities.selector), "the scan sees the PositionManager call");
        assertFalse(_pushes(code, IVaultToken.mint.selector), "no vault-token mint");
        assertFalse(_pushes(code, IVaultToken.burn.selector), "no vault-token burn");
        assertFalse(_pushes(code, IVaultToken.addValidProxy.selector), "no proxy registration");
    }

    // TEST-221 verifies: REQ-VAULT-164, REQ-VAULT-154
    /// @notice On a market whose token0 switched on a 1% transfer fee after listing, a fee collection, a seizure and a
    /// partial removal with per-token minimums equal to the seized amounts all succeed; each reports the PoolManager's
    /// amounts while the recipient receives 1% less of token0.
    function test_TEST_221_transferFeeOnAPayoutFailsNoLPVaultCheck() public {
        (CollPoolToken t0, CollPoolToken t1) = _bindHookMarket();
        bytes32 key = _mintFor(alice, feeKey, M1_LOWER, M1_UPPER, 1e15);
        uint128 units = _receive(M3, alice, key);
        _washV4(feeKey, 1e12);
        t0.setFeeBps(100);
        uint256 a0 = t0.balanceOf(alice);
        uint256[] memory fees = abi.decode(_as(adapter, abi.encodeCall(vault.collectFees, (key, alice))), (uint256[]));
        assertGt(fees[0], 0);
        assertEq(t0.balanceOf(alice) - a0, fees[0] - fees[0] / 100, "the depositor bears the fee");
        uint256 s0 = t0.balanceOf(lpVaultSwap);
        uint256 s1 = t1.balanceOf(lpVaultSwap);
        uint256[] memory got = abi.decode(
            _as(lpVaultSwap, abi.encodeCall(vault.unwind, (key, units / 4, _zeros(), lpVaultSwap))), (uint256[])
        );
        assertGt(got[0], 0);
        assertEq(t0.balanceOf(lpVaultSwap) - s0, got[0] - got[0] / 100, "the recipient bears the fee");
        assertEq(t1.balanceOf(lpVaultSwap) - s1, got[1]);
        a0 = t0.balanceOf(alice);
        uint256[] memory part =
            abi.decode(_as(adapter, abi.encodeCall(vault.releaseToDepositor, (key, units / 4, got))), (uint256[]));
        assertEq(t0.balanceOf(alice) - a0, part[0] - part[0] / 100, "the minimum checks the reported amount");
        assertEq(t0.balanceOf(address(vault)), 0, "nothing rests at the LPVault");
        assertEq(vault.depositorOf(key), alice);
    }

    // ─── Range and value ───

    // TEST-279 verifies: REQ-VAULT-008, REQ-VAULT-009, REQ-AMM-CORE-006, SPEC-AMM-V4-001
    /// @notice A position one tick spacing off the market's exact range on either side, on either market, is refused
    /// with `RangeMismatch`; at an oracle ratio beyond the range the composition is the clamped one-token amount.
    function test_TEST_279_exactRangeAndTheClampedComposition() public {
        int24[2] memory spacing = [int24(1), int24(10)];
        PoolKey[2] memory pools = [stableKey, ethKey];
        uint256[2] memory markets = [M1, M2];
        int24[2] memory lowers = [M1_LOWER, M2_LOWER];
        int24[2] memory uppers = [M1_UPPER, M2_UPPER];
        for (uint256 i = 0; i < 2; ++i) {
            int24 s = spacing[i];
            int24[2][4] memory off = [
                [lowers[i] - s, uppers[i]],
                [lowers[i] + s, uppers[i]],
                [lowers[i], uppers[i] - s],
                [lowers[i], uppers[i] + s]
            ];
            for (uint256 j = 0; j < 4; ++j) {
                bytes32 key = _mintFor(alice, pools[i], off[j][0], off[j][1], 1e15);
                vm.expectRevert(abi.encodeWithSelector(RangeMismatch.selector, off[j][0], off[j][1]));
                vault.validatePosition(markets[i], alice, key);
            }
        }
        (uint256[] memory high,) = vault.composition(M1, 1e9, _vec(2e8, 1e8));
        assertEq(high[0], 0, "above the range: token1 only");
        assertGt(high[1], 0);
        (uint256[] memory low,) = vault.composition(M1, 1e9, _vec(1e8, 2e8));
        assertGt(low[0], 0, "below the range: token0 only");
        assertEq(low[1], 0);
        (uint256[] memory mid,) = vault.composition(M1, 1e9, _vec(1e8, 1e8));
        assertGt(mid[0], 0, "inside the range: both tokens");
        assertGt(mid[1], 0);
    }

    // TEST-217 verifies: INV-078, REQ-AMM-CORE-006, REQ-AMM-CORE-007, SPEC-BACK-008
    /// @notice For any oracle price vector, any spot of the v4 pool and any removed share of a pledged position, the
    /// tokens `unwind` returns are worth at oracle prices at least the `composition` the LPVault reports for the same
    /// units at those prices.
    function testFuzz_TEST_217_removalAtAnySpotCoversTheComposition(
        uint256 p0,
        uint256 p1,
        int256 spot,
        uint256 shareBps
    ) public {
        (bytes32 key, uint128 units) = _pledge(bob, 1e15);
        uint256[] memory prices = _vec(bound(p0, 1e6, 2e8), bound(p1, 1e6, 2e8));
        uint128 x = uint128(uint256(units) * bound(shareBps, 1, 10_000) / 10_000);
        vm.assume(x > 0);
        (uint256[] memory comp,) = vault.composition(M1, x, prices);
        // forge-lint: disable-next-line(unsafe-typecast)
        _swapV4To(stableKey, ClPriceMath.sqrtRatioAtTick(int24(bound(spot, -5000, 5000))));
        uint256[] memory got =
            abi.decode(_as(lpVaultSwap, abi.encodeCall(vault.unwind, (key, x, _zeros(), lpVaultSwap))), (uint256[]));
        // Both pool tokens have 6 decimals.
        assertGe(got[0] * prices[0] + got[1] * prices[1], comp[0] * prices[0] + comp[1] * prices[1], "under-backed");
    }
}
