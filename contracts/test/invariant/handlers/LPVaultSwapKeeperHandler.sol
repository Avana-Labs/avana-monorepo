// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ILPVaultSwap} from "../../../src/legacy/lp-vault-swap/ILPVaultSwap.sol";
import {ILPVaultSwapBase} from "../../../src/legacy/lp-vault-swap/ILPVaultSwapBase.sol";
import {CommonBase} from "forge-std/Base.sol";
import {StdUtils} from "forge-std/StdUtils.sol";

/// @title LPVaultSwapKeeperHandler
/// @notice Actions on LPVaultSwap's committed-operator registry: the governance role adds and removes any of 40 candidate
/// addresses, and an outsider tries both admin calls. A ghost model predicts the outcome of every call (success or the
/// exact error, in the spec's order) from the spec: `addKeeper` needs a new (`InvalidKeeper` first), non-zero keeper
/// below `MAX_KEEPERS` (32); `removeKeeper` needs a registered keeper whose removal keeps the count at `keeperFloor`
/// (1) or more. Any disagreement between the model and the contract is counted.
contract LPVaultSwapKeeperHandler is CommonBase, StdUtils {
    /// @notice A call that found nothing to act on, or that the contract refused: reverting keeps it out of the
    /// campaign's success count, so the metrics show the calls that did real work.
    error Skipped();

    ILPVaultSwap public immutable LVS;
    address public immutable GOVERNOR;
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
        address governor,
        address initialKeeper
    ) {
        (LVS, GOVERNOR) = (lvs, governor);
        modelRegistered[initialKeeper] = true;
        modelCount = 1;
    }

    function candidate(
        uint256 seed
    ) public pure returns (address) {
        return address(uint160(0xC000 + (seed % CANDIDATES)));
    }

    function add(
        uint256 seed
    ) external {
        address k = candidate(seed);
        bytes memory expected;
        if (modelRegistered[k]) {
            expected = abi.encodeWithSelector(ILPVaultSwapBase.InvalidKeeper.selector);
        } else if (modelCount >= MAX_KEEPERS) {
            expected = abi.encodeWithSelector(ILPVaultSwapBase.TooManyKeepers.selector, MAX_KEEPERS);
        }
        vm.prank(GOVERNOR);
        (bool ok, bytes memory ret) = address(LVS).call(abi.encodeCall(ILPVaultSwap.addKeeper, (k)));
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
            expected = abi.encodeWithSelector(ILPVaultSwapBase.InvalidKeeper.selector);
        } else {
            uint256 after_ = modelCount - 1;
            if (after_ < FLOOR) {
                expected = abi.encodeWithSelector(ILPVaultSwapBase.KeeperFloor.selector, after_, FLOOR);
            }
        }
        vm.prank(GOVERNOR);
        (bool ok, bytes memory ret) = address(LVS).call(abi.encodeCall(ILPVaultSwap.removeKeeper, (k)));
        if (expected.length == 0) {
            if (!ok) ++mismatches;
            else (modelRegistered[k], modelCount, removes) = (false, modelCount - 1, removes + 1);
        } else if (ok || keccak256(ret) != keccak256(expected)) {
            ++mismatches;
        }
    }

    function outsider(
        uint256 seed,
        address caller
    ) external {
        if (caller == GOVERNOR) revert Skipped();
        address k = candidate(seed);
        vm.prank(caller);
        (bool okAdd,) = address(LVS).call(abi.encodeCall(ILPVaultSwap.addKeeper, (k)));
        vm.prank(caller);
        (bool okRemove,) = address(LVS).call(abi.encodeCall(ILPVaultSwap.removeKeeper, (k)));
        if (okAdd || okRemove) ++outsiderSuccesses;
    }
}
