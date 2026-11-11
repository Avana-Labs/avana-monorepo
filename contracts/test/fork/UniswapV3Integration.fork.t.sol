// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ClMarketConfig} from "../../src/amm/types/ClMarketConfig.sol";
import {UniswapV3Integration} from "../../src/amm/uniswap-v3/UniswapV3Integration.sol";
import {ILPVaultErrors} from "../../src/custody/lp-vault/ILPVaultErrors.sol";
import {Lock} from "../../src/lock/lock/Lock.sol";
import {PositionShape} from "../../src/types/PositionShape.sol";
import {ShapeKind} from "../../src/types/ShapeKind.sol";
import {AvanaTest} from "../utils/AvanaTest.sol";
import {ForkConstants} from "../utils/fixtures/ForkConstants.sol";

/// @title UniswapV3IntegrationForkTest
/// @notice TEST-264 on an Ethereum fork: the production Uniswap v3 LPVault against the canonical NFPM, factory and
/// pools, with the canonical pool init code hash. Runs at `ForkConstants.MAINNET_FORK_BLOCK`; skipped without
/// `RPC_MAINNET` or a pinned block; the remaining TEST-264 assertions (custody of a live NFT, unwind at a moved spot,
/// fees) stay open until the archive RPC is available.
/// @dev Run with `FOUNDRY_PROFILE=fork forge test --match-contract UniswapV3IntegrationForkTest`.
contract UniswapV3IntegrationForkTest is AvanaTest {
    address internal constant NFPM = 0xC36442b4a4522E871399CD717aBDD847Ab11FE88;
    address internal constant FACTORY = 0x1F98431c8aD98523631AE4a59f267346ea31F984;
    /// @dev USDC/USDT 0.01% pool (fee 100, spacing 1).
    address internal constant USDC_USDT_100 = 0x3416cF6C708Da44DB2624D63ea0AAef7113527C6;

    UniswapV3Integration internal vault;
    address internal registry = makeAddr("marketRegistry");

    function setUp() public {
        string memory rpc = vm.envOr("RPC_MAINNET", string(""));
        uint256 blockNumber = ForkConstants.mainnetForkBlock();
        if (bytes(rpc).length == 0 || blockNumber == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpc, blockNumber);
        Lock lock = new Lock(makeAddr("aaveAdapter"), makeAddr("lpVaultSwap"));
        vault = new UniswapV3Integration(
            1, makeAddr("collateralization"), registry, address(lock), makeAddr("timelock"), NFPM, FACTORY
        );
    }

    // TEST-264 verifies: REQ-AMM-V3-001, REQ-AMM-V3-002, SPEC-BACK-001, SPEC-UNIT-001
    function test_TEST_264_bindsTheCanonicalPoolWithTheCanonicalInitCodeHash() public {
        vm.prank(registry);
        (address[] memory tokens, uint8 d) = vault.bindMarket(
            1, USDC_USDT_100, bytes32(0), PositionShape(ShapeKind.TickRange, -887_272, 887_272), abi.encode(1e8, 1e8)
        );
        assertEq(d, 6, "full-range USDC/USDT");
        assertEq(tokens.length, 2);
        ClMarketConfig memory cfg = vault.clMarket(1);
        assertEq(cfg.tickSpacing, 1);
        assertEq(cfg.fee, 100);
        vm.prank(registry);
        vm.expectRevert(ILPVaultErrors.InvalidShape.selector);
        vault.bindMarket(
            2, USDC_USDT_100, bytes32(0), PositionShape(ShapeKind.TickRange, -887_273, 887_272), abi.encode(1e8, 1e8)
        );
    }
}
