// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ILPVaultSwap} from "../../../src/liquidation/lp-vault-swap/ILPVaultSwap.sol";
import {ILPVaultSwapAdmin} from "../../../src/liquidation/lp-vault-swap/ILPVaultSwapAdmin.sol";
import {ILPVaultSwapErrors} from "../../../src/liquidation/lp-vault-swap/ILPVaultSwapErrors.sol";
import {LVSMarketRegistryMock} from "../../utils/mocks/LPVaultSwapMocks.sol";
import {CommonBase} from "forge-std/Base.sol";
import {StdUtils} from "forge-std/StdUtils.sol";

/// @title LPVaultSwapKeeperHandler
/// @notice Actions on LPVaultSwap's committed-operator registry: the timelock adds and removes any of 40 candidate
/// addresses, the MarketRegistry freezes and unfreezes them, and an outsider tries both admin calls. A ghost model
/// predicts the outcome of every call (success or the exact error, in the spec's order) from the spec: `addKeeper`
/// needs a new (`InvalidKeeper` first), unfrozen, non-zero keeper below `MAX_KEEPERS` (32); `removeKeeper` needs a registered keeper whose removal keeps the active
/// count at `keeperFloor` (1) or more. Any disagreement between the model and the contract is counted.
contract LPVaultSwapKeeperHandler is CommonBase, StdUtils {
    ILPVaultSwap public immutable LVS;
    LVSMarketRegistryMock public immutable REGISTRY;
    address public immutable TIMELOCK;
    uint256 internal constant CANDIDATES = 40;
    uint256 internal constant MAX_KEEPERS = 32;
    uint256 internal constant FLOOR = 1;

    mapping(address => bool) public modelRegistered;
    uint256 public modelCount;
    uint256 public mismatches;
    uint256 public outsiderSuccesses;
    uint256 public adds;
    uint256 public removes;

    constructor(
        ILPVaultSwap lvs,
        LVSMarketRegistryMock registry,
        address timelock,
        address initialKeeper
    ) {
        (LVS, REGISTRY, TIMELOCK) = (lvs, registry, timelock);
        modelRegistered[initialKeeper] = true;
        modelCount = 1;
    }

    function candidate(
        uint256 seed
    ) public pure returns (address) {
        return address(uint160(0xC000 + (seed % CANDIDATES)));
    }

    function modelActive() public view returns (uint256 n) {
        for (uint256 i = 0; i < CANDIDATES; ++i) {
            address k = candidate(i);
            if (modelRegistered[k] && !REGISTRY.isFrozenAddress(k)) ++n;
        }
    }

    function add(
        uint256 seed
    ) external {
        address k = candidate(seed);
        bytes memory expected;
        if (modelRegistered[k]) {
            expected = abi.encodeWithSelector(ILPVaultSwapErrors.InvalidKeeper.selector);
        } else if (REGISTRY.isFrozenAddress(k)) {
            expected = abi.encodeWithSelector(ILPVaultSwapErrors.AddressIsFrozen.selector, k);
        } else if (modelCount >= MAX_KEEPERS) {
            expected = abi.encodeWithSelector(ILPVaultSwapErrors.TooManyKeepers.selector, MAX_KEEPERS);
        }
        vm.prank(TIMELOCK);
        (bool ok, bytes memory ret) = address(LVS).call(abi.encodeCall(ILPVaultSwapAdmin.addKeeper, (k)));
        if (expected.length == 0) {
            if (!ok) ++mismatches;
            else (modelRegistered[k], modelCount, adds) = (true, modelCount + 1, adds + 1);
        } else if (ok || keccak256(ret) != keccak256(expected)) {
            ++mismatches;
        }
    }

    function remove(
        uint256 seed
    ) external {
        address k = candidate(seed);
        bytes memory expected;
        if (!modelRegistered[k]) {
            expected = abi.encodeWithSelector(ILPVaultSwapErrors.InvalidKeeper.selector);
        } else {
            uint256 active = modelActive();
            uint256 after_ = REGISTRY.isFrozenAddress(k) ? active : active - 1;
            if (after_ < FLOOR) {
                expected = abi.encodeWithSelector(ILPVaultSwapErrors.KeeperFloor.selector, after_, FLOOR);
            }
        }
        vm.prank(TIMELOCK);
        (bool ok, bytes memory ret) = address(LVS).call(abi.encodeCall(ILPVaultSwapAdmin.removeKeeper, (k)));
        if (expected.length == 0) {
            if (!ok) ++mismatches;
            else (modelRegistered[k], modelCount, removes) = (false, modelCount - 1, removes + 1);
        } else if (ok || keccak256(ret) != keccak256(expected)) {
            ++mismatches;
        }
    }

    /// @notice A freeze is the MarketRegistry's; it is applied only while it keeps one active committed operator (a
    /// freeze below the floor is the registry's PROP-071, outside this contract).
    function freeze(
        uint256 seed,
        bool frozen
    ) external {
        address k = candidate(seed);
        bool was = REGISTRY.isFrozenAddress(k);
        REGISTRY.setFrozen(k, frozen);
        if (modelActive() < FLOOR) REGISTRY.setFrozen(k, was);
    }

    function outsider(
        uint256 seed,
        address caller
    ) external {
        if (caller == TIMELOCK) return;
        address k = candidate(seed);
        vm.prank(caller);
        (bool okAdd,) = address(LVS).call(abi.encodeCall(ILPVaultSwapAdmin.addKeeper, (k)));
        vm.prank(caller);
        (bool okRemove,) = address(LVS).call(abi.encodeCall(ILPVaultSwapAdmin.removeKeeper, (k)));
        if (okAdd || okRemove) ++outsiderSuccesses;
    }
}
