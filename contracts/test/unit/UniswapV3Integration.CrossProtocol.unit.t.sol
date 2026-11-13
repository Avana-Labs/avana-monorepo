// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {PositionShape} from "../../src/types/PositionShape.sol";
import {ShapeKind} from "../../src/types/ShapeKind.sol";
import {UniswapV3IntegrationFixture} from "../utils/fixtures/UniswapV3IntegrationFixture.sol";
import {MockCLFactory, MockCLPool, MockSlipstreamNPM} from "../utils/mocks/SlipstreamMocks.sol";

/// @title UniswapV3IntegrationCrossProtocolTest
/// @notice The Uniswap v3 LPVault against the Aerodrome Slipstream generation of the same pair: a position from the
/// Slipstream position manager and a pool from the Slipstream factory are refused, as the Slipstream LPVault refuses a
/// position or pool of another generation's factory (5.1 `TEST-265`).
/// forge-config: default.isolate = false
contract UniswapV3IntegrationCrossProtocolTest is UniswapV3IntegrationFixture {
    MockCLFactory internal clFactory;
    MockSlipstreamNPM internal clNpm;
    MockCLPool internal clPool;

    function setUp() public override {
        super.setUp();
        clFactory = new MockCLFactory();
        clNpm = new MockSlipstreamNPM(address(clFactory));
        clFactory.setNft(address(clNpm));
        clPool = MockCLPool(clFactory.createPool(address(usdc), address(usdt), 10));
    }

    // TEST-265 verifies: REQ-AMM-V3-008, REQ-VAULT-124, REQ-AMM-CORE-003, ATTACK-178
    // Sources: 5.1 TEST-265 (a position from one generation presented with another generation's factory is refused),
    // seen from the Uniswap v3 integration
    /// @notice A Slipstream NFT of the same pair, range and spacing sent to the Uniswap v3 LPVault reverts
    /// `UnsupportedNft` (only the canonical Uniswap v3 position manager may call its receiver hook); a market bound on
    /// the Slipstream pool reverts, since the pool is not at the address the Uniswap v3 factory and init code derive.
    function test_TEST_265_slipstreamPositionsAndPoolsRefusedByTheUniswapV3LPVault() public {
        uint256 id = clNpm.mint(alice, address(usdc), address(usdt), 10, M1_LOWER, M1_UPPER, 1e12);
        vm.prank(alice);
        vm.expectRevert(UnsupportedNft.selector);
        clNpm.safeTransferFrom(alice, address(vault), id);
        assertEq(clNpm.ownerOf(id), alice, "the Slipstream NFT never reached the LPVault");
        vm.prank(registry);
        vm.expectRevert();
        vault.bindMarket(
            7, address(clPool), bytes32(0), PositionShape(ShapeKind.TickRange, M1_LOWER, M1_UPPER), abi.encode(1e8, 1e8)
        );
    }
}
