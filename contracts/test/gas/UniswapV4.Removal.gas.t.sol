// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {LPOracleV4Fixture} from "../utils/fixtures/LPOracleV4Fixture.sol";
import {UniswapV4IntegrationFixture} from "../utils/fixtures/UniswapV4IntegrationFixture.sol";

/// @notice Gas of the Uniswap v4 LPVault's removal batch on the local v4 world (snapshot group `UniswapV4Removal`):
/// pledge, a seizure-sized unwind (fee step plus principal step) on an ERC-20 pool and on a native-ETH pool, a full
/// unwind, and fee collection. Each value is the LPVault call alone, as Collateralization makes it under the Lock; the
/// whole-account seizure budget per record (`REQ-AMM-CORE-015`) is checked against these on a fork before listing.
/// forge-config: default.isolate = false
/// forge-config: gas.isolate = false
contract UniswapV4RemovalGasTest is UniswapV4IntegrationFixture {
    address internal owner = makeAddr("owner");
    address internal to = makeAddr("lpVaultSwapStandIn");

    // TEST-334 verifies: REQ-AMM-CORE-015, REQ-AMM-V4-004
    function test_TEST_334_removalGasErc20Pool() public {
        bytes32 key = _mintFor(owner, stableKey, M1_LOWER, M1_UPPER, 1e15);
        _lock();
        vm.prank(coll);
        uint128 units = vault.receivePosition(M1, owner, key);
        vm.snapshotGasLastCall("UniswapV4Removal", "receivePosition_erc20");
        _unlock();
        _washV4(stableKey, 1e12);
        _lock();
        vm.prank(coll);
        vault.unwind(key, units / 2, _zeros(), to);
        vm.snapshotGasLastCall("UniswapV4Removal", "unwind_half_erc20");
        vm.prank(coll);
        vault.unwind(key, units - units / 2, _zeros(), to);
        vm.snapshotGasLastCall("UniswapV4Removal", "unwind_rest_erc20");
        _unlock();
    }

    // TEST-334 verifies: REQ-AMM-CORE-015, REQ-AMM-V4-004, REQ-AMM-CORE-010
    function test_TEST_334_removalGasNativeEthPool() public {
        bytes32 key = _mintFor(owner, ethKey, M2_LOWER, M2_UPPER, 1e18);
        _lock();
        vm.prank(coll);
        uint128 units = vault.receivePosition(M2, owner, key);
        _unlock();
        v4Actor.swap(ethKey, true, -1e16, 4_295_128_740);
        v4Actor.swap(ethKey, false, -20e6, 1_461_446_703_485_210_103_287_273_052_203_988_822_378_723_970_341);
        _lock();
        vm.prank(coll);
        vault.collectFees(key, owner);
        vm.snapshotGasLastCall("UniswapV4Removal", "collectFees_native");
        vm.prank(coll);
        vault.unwind(key, units / 2, _zeros(), to);
        vm.snapshotGasLastCall("UniswapV4Removal", "unwind_half_native");
        _unlock();
    }
}

/// @notice Gas of the v4 LPOracle's evaluation and `poke()` (snapshot group `UniswapV4Oracle`): the PoolManager lock and
/// `slot0` reads plus the reference pool's TWAP read.
/// forge-config: default.isolate = false
/// forge-config: gas.isolate = false
contract LPOracleV4GasTest is LPOracleV4Fixture {
    function setUp() public {
        _deployV4Market();
    }

    // TEST-335 verifies: SPEC-ORC-023, REQ-AMM-V4-005
    function test_TEST_335_oracleGas() public {
        oracle.poke();
        vm.snapshotGasLastCall("UniswapV4Oracle", "poke");
        oracle.getPriceState();
        vm.snapshotGasLastCall("UniswapV4Oracle", "getPriceState");
        oracle.latestAnswer();
        vm.snapshotGasLastCall("UniswapV4Oracle", "latestAnswer");
    }
}
