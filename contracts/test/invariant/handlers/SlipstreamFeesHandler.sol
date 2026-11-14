// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {SlipstreamIntegration} from "../../../src/amm/slipstream/SlipstreamIntegration.sol";
import {Lock} from "../../../src/lock/lock/Lock.sol";
import {MockCLPool, MockSlipstreamNPM} from "../../utils/mocks/SlipstreamMocks.sol";
import {MintableToken} from "../../utils/mocks/UniswapV3Mocks.sol";
import {CommonBase} from "forge-std/Base.sol";
import {StdUtils} from "forge-std/StdUtils.sol";

/// @title SlipstreamFeesHandler
/// @notice Actor handler of TEST-091 on the Slipstream LPVault (the twin of `LPVaultFeesHandler`, on the Slipstream
/// position manager of market 1's generation, whose position keys carry the generation in their top byte): two depositors pledge positions of market 1 through
/// Collateralization (under the AaveAdapter's Lock), the pool accrues fees to them, LPVaultSwap's seizures unwind any
/// part of a position's units to LPVaultSwap, and fee collections name the depositor, the other depositor or an
/// attacker. Ghosts record the fees accrued and paid per position, every fee token that reached anyone but the
/// position's depositor during a collection, and every unwind that lowered a position's owed fees.
contract SlipstreamFeesHandler is CommonBase, StdUtils {
    /// @notice A call that found nothing to act on, or that the contract refused: reverting keeps it out of the
    /// campaign's success count, so the metrics show the calls that did real work.
    error Skipped();

    uint256 internal constant MARKET = 1;
    uint256 internal constant MAX_POSITIONS = 8;

    SlipstreamIntegration public immutable VAULT;
    MockSlipstreamNPM public immutable NFPM;
    MockCLPool public immutable POOL;
    uint256 public immutable GEN;
    Lock public immutable LOCK;
    address public immutable ADAPTER;
    address public immutable COLL;
    address public immutable SWAP;
    address public immutable ATTACKER;
    MintableToken internal immutable T0;
    MintableToken internal immutable T1;
    address[2] internal depositors;

    bytes32[] public keys;
    mapping(bytes32 key => address depositor) public depositorOfKey;
    mapping(bytes32 key => uint256[2] amounts) internal _accrued;
    mapping(bytes32 key => uint256[2] amounts) internal _paid;

    /// @notice Fee tokens a collection delivered to anyone but the position's depositor.
    uint256 public paidToOthers;
    /// @notice A collection that paid the depositor other than every owed amount, or left fees owed.
    uint256 public wrongCollections;
    /// @notice A collection naming someone other than the depositor that succeeded.
    uint256 public foreignCollections;
    /// @notice An unwind that lowered the position's owed fees.
    uint256 public feesCut;
    uint256 public unwinds;
    uint256 public collections;

    constructor(
        SlipstreamIntegration vault,
        MockSlipstreamNPM nfpm,
        MockCLPool pool,
        uint256 gen,
        Lock lock,
        address[4] memory roles,
        address[2] memory depositors_
    ) {
        (VAULT, NFPM, POOL, LOCK, GEN) = (vault, nfpm, pool, lock, gen);
        (ADAPTER, COLL, SWAP, ATTACKER) = (roles[0], roles[1], roles[2], roles[3]);
        T0 = MintableToken(pool.token0());
        T1 = MintableToken(pool.token1());
        depositors = depositors_;
    }

    function keyCount() external view returns (uint256) {
        return keys.length;
    }

    function accrued(
        bytes32 key
    ) external view returns (uint256, uint256) {
        return (_accrued[key][0], _accrued[key][1]);
    }

    function paid(
        bytes32 key
    ) external view returns (uint256, uint256) {
        return (_paid[key][0], _paid[key][1]);
    }

    /// @notice Owed amounts of the position on the position manager.
    function owed(
        bytes32 key
    ) public view returns (uint256 o0, uint256 o1) {
        (,,,,,,,,,, uint128 a, uint128 b) = NFPM.positions(_id(key));
        return (a, b);
    }

    function _asColl(
        bytes memory data
    ) internal returns (bool ok, bytes memory ret) {
        vm.prank(ADAPTER);
        LOCK.acquire();
        vm.prank(COLL);
        (ok, ret) = address(VAULT).call(data);
        vm.prank(ADAPTER);
        LOCK.release();
    }

    function _id(
        bytes32 key
    ) internal pure returns (uint256) {
        return uint256(key) & ((uint256(1) << 248) - 1);
    }

    function _key(
        uint256 seed
    ) internal view returns (bytes32) {
        return keys[seed % keys.length];
    }

    function pledge(
        uint256 who,
        uint128 liquidity
    ) external {
        if (keys.length >= MAX_POSITIONS) revert Skipped();
        address owner = depositors[who % 2];
        liquidity = uint128(bound(liquidity, 1e6, 1e15));
        uint256 id = NFPM.mint(owner, address(T0), address(T1), POOL.tickSpacing(), -50, 50, liquidity);
        vm.prank(owner);
        NFPM.approve(address(VAULT), id);
        bytes32 key = bytes32((GEN << 248) | id);
        (bool ok,) = _asColl(abi.encodeCall(VAULT.receivePosition, (MARKET, owner, key)));
        require(ok, "pledge");
        keys.push(key);
        depositorOfKey[key] = owner;
    }

    function accrue(
        uint256 keySeed,
        uint128 a0,
        uint128 a1
    ) external {
        if (keys.length == 0) revert Skipped();
        bytes32 key = _key(keySeed);
        a0 = uint128(bound(a0, 0, 1e12));
        a1 = uint128(bound(a1, 0, 1e12));
        NFPM.accrue(_id(key), a0, a1);
        _accrued[key][0] += a0;
        _accrued[key][1] += a1;
    }

    function moveSpot(
        int24 tick
    ) external {
        POOL.setPrice(int24(bound(int256(tick), -2000, 2000)));
    }

    /// @notice LPVaultSwap's seizure of `units` of the position: Collateralization has the LPVault unwind them to
    /// LPVaultSwap.
    function seize(
        uint256 keySeed,
        uint256 unitsSeed
    ) external {
        if (keys.length == 0) revert Skipped();
        bytes32 key = _key(keySeed);
        uint128 held = VAULT.unitsOf(key);
        if (held == 0) revert Skipped();
        // Bounded by the position's units, so it fits uint128.
        uint128 units = uint128(bound(unitsSeed, 1, held));
        (uint256 o0, uint256 o1) = owed(key);
        (bool ok,) = _asColl(abi.encodeCall(VAULT.unwind, (key, units, new uint256[](2), SWAP)));
        require(ok, "unwind");
        (uint256 n0, uint256 n1) = owed(key);
        if (n0 < o0 || n1 < o1) ++feesCut;
        ++unwinds;
    }

    function collect(
        uint256 keySeed,
        uint256 callerSeed
    ) external {
        if (keys.length == 0) revert Skipped();
        bytes32 key = _key(keySeed);
        uint256 pick = callerSeed % 3;
        address named = pick == 2 ? ATTACKER : depositors[pick];
        _snapshotBalances();
        (uint256 o0, uint256 o1) = owed(key);
        (bool ok, bytes memory ret) = _asColl(abi.encodeCall(VAULT.collectFees, (key, named)));
        _countPaidToOthers(depositorOfKey[key]);
        if (!ok) revert Skipped();
        if (named != depositorOfKey[key]) ++foreignCollections;
        uint256[] memory amounts = abi.decode(ret, (uint256[]));
        (uint256 n0, uint256 n1) = owed(key);
        if (amounts[0] != o0 || amounts[1] != o1 || n0 != 0 || n1 != 0) ++wrongCollections;
        _paid[key][0] += amounts[0];
        _paid[key][1] += amounts[1];
        ++collections;
    }

    /// @dev Everyone a collection could pay: both depositors, the attacker, LPVaultSwap and the LPVault.
    function _actors() internal view returns (address[5] memory a) {
        a = [depositors[0], depositors[1], ATTACKER, SWAP, address(VAULT)];
    }

    uint256[5] internal _before0;
    uint256[5] internal _before1;

    function _snapshotBalances() internal {
        address[5] memory a = _actors();
        for (uint256 i = 0; i < 5; ++i) {
            (_before0[i], _before1[i]) = (T0.balanceOf(a[i]), T1.balanceOf(a[i]));
        }
    }

    function _countPaidToOthers(
        address depositor
    ) internal {
        address[5] memory a = _actors();
        for (uint256 i = 0; i < 5; ++i) {
            if (a[i] == depositor) continue;
            paidToOthers += (T0.balanceOf(a[i]) - _before0[i]) + (T1.balanceOf(a[i]) - _before1[i]);
        }
    }
}
