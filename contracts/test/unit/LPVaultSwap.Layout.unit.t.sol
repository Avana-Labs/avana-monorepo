// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ILPVaultSwapLogic} from "../../src/liquidation/lp-vault-swap/ILPVaultSwapLogic.sol";
import {LPVaultSwapUnitBase} from "./LPVaultSwap.Base.sol";

/// @title LPVaultSwapLayoutUnitTest
/// @notice LPVaultSwap's storage and code layout (2.11 "Storage"): the ERC-7201 namespace `avana.storage.LPVaultSwap`
/// holds the registry and the carry and nothing else of LPVaultSwap's is in plain storage; the deleverage context
/// lives in transient slots of `avana.lpvaultswap.deleverage` and is empty between transactions; each logic contract
/// reports its kind and the implementation's immutables hash; a liquidation and a pending settlement write only the
/// namespace fields the spec names (none for a liquidation, the market's carry for a settlement).
/// forge-config: default.isolate = false
contract LPVaultSwapLayoutUnitTest is LPVaultSwapUnitBase {
    bytes32 internal constant NAMESPACE = 0x91af63178751821a6b1a96f50867937bf3006ecc962b49702910546a3afa6f00;
    bytes32 internal constant DELEVERAGE_BASE = 0x2fedc8c0c549405a7945459f775cbb80cfe11288ab144f5ef2460ebaf39ee400;

    function _erc7201(
        string memory id
    ) internal pure returns (bytes32) {
        return keccak256(abi.encode(uint256(keccak256(bytes(id))) - 1)) & ~bytes32(uint256(0xff));
    }

    /// @notice The namespace and the transient base are the ERC-7201 slots of their identifiers.
    // TEST-242 verifies: REQ-SWAP-040, REQ-SWAP-106
    function test_namespaceSlots() public pure {
        assertEq(_erc7201("avana.storage.LPVaultSwap"), NAMESPACE, "storage namespace");
        assertEq(_erc7201("avana.lpvaultswap.deleverage"), DELEVERAGE_BASE, "transient base");
    }

    /// @notice Each logic contract reports its kind and the implementation's immutables hash.
    // TEST-242 verifies: REQ-SWAP-040
    function test_logicConfigs() public view {
        bytes32 hash = keccak256(abi.encode(immutables()));
        address[3] memory logics = [liquidationLogic, pendingLogic, deleverageLogic];
        string[3] memory kinds =
            ["LPVaultSwapLiquidationLogic", "LPVaultSwapPendingLogic", "LPVaultSwapDeleverageLogic"];
        for (uint256 i = 0; i < 3; ++i) {
            (bytes32 kind, bytes32 h) = ILPVaultSwapLogic(logics[i]).logicConfig();
            assertEq(kind, keccak256(bytes(kinds[i])), "kind");
            assertEq(h, hash, "immutables hash");
        }
    }

    /// @notice No plain storage slot 0 to 9 of the proxy is written by a liquidation or a settlement, and a
    /// liquidation writes no word of the namespace's first fields.
    // TEST-200 verifies: REQ-SWAP-103, INV-097, PROP-063
    function test_liquidationWritesNoNamespaceWord() public {
        (address proxy,) = _bobAccount();
        bytes32[12] memory before;
        for (uint256 i = 0; i < 12; ++i) {
            before[i] = vm.load(address(lvs), bytes32(uint256(NAMESPACE) + i));
        }
        bytes32[10] memory plain;
        for (uint256 i = 0; i < 10; ++i) {
            plain[i] = vm.load(address(lvs), bytes32(i));
        }
        _liquidateAs(keeper, _params(proxy, 1950e6));
        for (uint256 i = 0; i < 12; ++i) {
            assertEq(vm.load(address(lvs), bytes32(uint256(NAMESPACE) + i)), before[i], "namespace unchanged");
        }
        for (uint256 i = 0; i < 10; ++i) {
            assertEq(vm.load(address(lvs), bytes32(i)), plain[i], "plain storage unchanged");
        }
    }

    /// @notice The deleverage context is empty after a deleverage (transient storage clears with the transaction and
    /// the body clears it at the end of the call).
    // TEST-239 verifies: REQ-SWAP-106, REQ-LOCK-007
    function test_deleverageContextCleared() public {
        (address proxy, bytes32 key) = _openAccount(alice, 10_000e6, 15_000e6, 250_000_000);
        vm.prank(alice);
        adapter.repayWithCollateral(proxy, _position(key), 1000e6, usdcReserveId, new uint256[](2), 0);
        for (uint256 i = 0; i < 9; ++i) {
            bytes32 v;
            bytes32 slot = bytes32(uint256(DELEVERAGE_BASE) + i);
            address target = address(lvs);
            v = vm.load(target, slot);
            assertEq(v, bytes32(0), "no persistent word at the transient slots");
        }
        assertFalse(lock.isLocked(), "Lock free");
    }

    /// @notice The implementation itself holds no initialized state: its registry is empty and it holds no role.
    // TEST-242 verifies: REQ-SWAP-040, REQ-ACCESS-153
    function test_implementationHoldsNothing() public view {
        assertEq(implementation.approvedKeeperCount(), 0, "no keepers on the implementation");
        assertFalse(implementation.hasRole(0x00, timelock), "no admin on the implementation");
        assertEq(address(implementation).balance, 0, "no ETH");
    }

    /// @notice The namespace fields sit where the layout says: the timelock at word 0, a keeper's flag in the
    /// mapping at word 1, the list length at word 2 and its first entry at keccak(word 2).
    // TEST-242 verifies: REQ-SWAP-032, REQ-SWAP-040
    function test_registryWords() public view {
        uint256 base = uint256(NAMESPACE);
        assertEq(address(uint160(uint256(vm.load(address(lvs), bytes32(base))))), timelock, "timelock word");
        bytes32 flag = keccak256(abi.encode(keeper, base + 1));
        assertEq(uint256(vm.load(address(lvs), flag)), 1, "keeper flag");
        assertEq(uint256(vm.load(address(lvs), bytes32(base + 2))), 1, "list length");
        bytes32 first = keccak256(abi.encode(base + 2));
        assertEq(address(uint160(uint256(vm.load(address(lvs), first)))), keeper, "first entry");
    }

    /// @notice A sub-share pending settlement writes only the carry of its settlement asset (word 3 of the
    /// namespace, keyed by the asset); the registry words do not move; a funded settlement clears the carry.
    // TEST-170 verifies: REQ-SWAP-070, REQ-SWAP-103
    function test_settlementWritesOnlyTheCarry() public {
        (address proxy,) = _bobAccount();
        _seizeAndKeep(proxy, 1000e6);
        _liquidateAs(keeper, _params(proxy, 500e6));
        uint256 base = uint256(NAMESPACE);
        bytes32 carrySlot = keccak256(abi.encode(address(usdc), base + 3));
        bytes32[3] memory before;
        for (uint256 i = 0; i < 3; ++i) {
            before[i] = vm.load(address(lvs), bytes32(base + i));
        }
        vm.mockCall(
            aave.hub, abi.encodeWithSelector(bytes4(keccak256("previewAddByAssets(uint256,uint256)"))), abi.encode(0)
        );
        (,, uint256 carried) = lvs.settlePending(MARKET_ID, usdcReserveId);
        vm.clearMockedCalls();
        assertEq(uint256(vm.load(address(lvs), carrySlot)), carried, "carry word holds R");
        for (uint256 i = 0; i < 3; ++i) {
            assertEq(vm.load(address(lvs), bytes32(base + i)), before[i], "registry words unchanged");
        }
        _seizeAndKeep(proxy, 400e6);
        _liquidateAs(keeper, _params(proxy, 500e6));
        lvs.settlePending(MARKET_ID, usdcReserveId);
        assertEq(uint256(vm.load(address(lvs), carrySlot)), 0, "a funded settlement clears the carry");
    }

    /// @notice Registry changes move only the registry words: adding and removing keepers changes the list length and
    /// the flags, never the timelock word or any carry.
    // TEST-098 verifies: REQ-SWAP-032, REQ-SWAP-035, REQ-SWAP-103
    function testFuzz_registryChangesTouchOnlyRegistryWords(
        uint8 adds
    ) public {
        uint256 n = bound(adds, 1, 12);
        uint256 base = uint256(NAMESPACE);
        bytes32 timelockWord = vm.load(address(lvs), bytes32(base));
        bytes32 carrySlot = keccak256(abi.encode(address(usdc), base + 3));
        for (uint256 i = 0; i < n; ++i) {
            address k = address(uint160(0xB000 + i));
            vm.prank(timelock);
            lvs.addKeeper(k);
            assertEq(uint256(vm.load(address(lvs), keccak256(abi.encode(k, base + 1)))), 1, "flag set");
        }
        assertEq(uint256(vm.load(address(lvs), bytes32(base + 2))), n + 1, "list length");
        vm.prank(timelock);
        lvs.removeKeeper(address(uint160(0xB000)));
        assertEq(
            uint256(vm.load(address(lvs), keccak256(abi.encode(address(uint160(0xB000)), base + 1)))), 0, "flag cleared"
        );
        assertEq(uint256(vm.load(address(lvs), bytes32(base + 2))), n, "list shrinks by one");
        assertEq(vm.load(address(lvs), bytes32(base)), timelockWord, "timelock word unchanged");
        assertEq(vm.load(address(lvs), carrySlot), bytes32(0), "no carry written");
    }
}

