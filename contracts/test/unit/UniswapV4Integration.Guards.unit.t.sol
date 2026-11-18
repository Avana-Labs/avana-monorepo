// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {RiskMetadata} from "../../src/amm/types/AmmTypes.sol";
import {IUniswapV4Integration} from "../../src/amm/uniswap-v4/IUniswapV4Integration.sol";
import {IUniswapV3Pool} from "../../src/interfaces/external/uniswap/IUniswapV3Pool.sol";
import {PositionShape, ShapeKind} from "../../src/types/PositionTypes.sol";
import {UniswapV4IntegrationFixture} from "../utils/fixtures/UniswapV4IntegrationFixture.sol";

/// @notice A PositionManager stand-in whose PoolManager or WETH9 is missing.
contract V4ManagerStub {
    address public poolManager;
    address public WETH9;

    constructor(
        address pm,
        address weth
    ) {
        (poolManager, WETH9) = (pm, weth);
    }
}

/// @notice The Uniswap v4 LPVault's guards: deployment checks, binding refusals, the shared custody checks reached
/// through v4 (zero units, minimum lengths and minimums), reads of an unknown position, the reference pool's failed or
/// malformed reads, and fee collection on an emptied position and below the range.
/// forge-config: default.isolate = false
contract UniswapV4IntegrationGuardsUnitTest is UniswapV4IntegrationFixture {
    address internal recipient = makeAddr("recipient");

    // ─── Deployment ───

    /// @dev Deploys the LPVault from its artifact and re-raises the constructor's revert data.
    function _deploy(
        address manager,
        address refFactory,
        uint256 blockTime
    ) internal returns (address a) {
        bytes memory code = abi.encodePacked(
            vm.getCode("UniswapV4Integration.sol:UniswapV4Integration"),
            abi.encode(
                INTEGRATION, coll, registry, address(lock), address(accessManager), manager, refFactory, blockTime
            )
        );
        assembly {
            a := create(0, add(code, 0x20), mload(code))
            if iszero(a) {
                returndatacopy(0, 0, returndatasize())
                revert(0, returndatasize())
            }
        }
    }

    function _expectDeployRefused(
        address manager,
        address refFactory,
        uint256 blockTime
    ) internal {
        vm.expectRevert(InvalidDeployment.selector);
        this.deployExternal(manager, refFactory, blockTime);
    }

    /// @dev `_deploy` behind an external call, so `vm.expectRevert` sees the creation revert.
    function deployExternal(
        address manager,
        address refFactory,
        uint256 blockTime
    ) external returns (address) {
        return _deploy(manager, refFactory, blockTime);
    }

    // TEST-331 verifies: REQ-VAULT-155, REQ-AMM-V4-007
    function test_TEST_331_deploymentRefusesBadBindings() public {
        _expectDeployRefused(address(posm), address(factory), 0);
        _expectDeployRefused(address(posm), address(factory), 13);
        _expectDeployRefused(address(posm), address(posm), 12);
        _expectDeployRefused(address(0), address(factory), 12);
        _expectDeployRefused(coll, address(factory), 12);
        _expectDeployRefused(address(posm), address(accessManager), 12);
        // A PositionManager or factory with code that is one of the Avana bindings (the Lock).
        _expectDeployRefused(address(lock), address(factory), 12);
        _expectDeployRefused(address(posm), address(lock), 12);
        _expectDeployRefused(address(new V4ManagerStub(address(0), address(weth))), address(factory), 12);
        _expectDeployRefused(address(new V4ManagerStub(address(pm), address(0))), address(factory), 12);
        _expectDeployRefused(address(new V4ManagerStub(address(pm), makeAddr("noCode"))), address(factory), 12);
        assertTrue(_deploy(address(posm), address(factory), 7) != address(0), "any interval on an unknown chain");
    }

    // TEST-331 verifies: REQ-VAULT-155
    function test_TEST_331_deploymentChecksTheKnownBlockInterval() public {
        vm.chainId(1);
        _expectDeployRefused(address(posm), address(factory), 2);
        assertTrue(_deploy(address(posm), address(factory), 12) != address(0));
        vm.chainId(8453);
        _expectDeployRefused(address(posm), address(factory), 12);
        assertTrue(_deploy(address(posm), address(factory), 2) != address(0));
        vm.chainId(130);
        _expectDeployRefused(address(posm), address(factory), 2);
        assertTrue(_deploy(address(posm), address(factory), 1) != address(0));
    }

    // ─── Binding ───

    function _bindRaw(
        uint256 marketId,
        bytes32 poolId,
        PositionShape memory shape,
        bytes memory data
    ) internal {
        vm.prank(registry);
        vault.bindMarket(marketId, address(0), poolId, shape, data);
    }

    // TEST-331 verifies: REQ-AMM-CORE-003, REQ-AMM-V4-007
    function test_TEST_331_bindRefusesCallersIdsShapesAndReferences() public {
        bytes memory data = _bindData(stableKey, address(stableRef), ONE, ONE);
        bytes32 id = _poolId(stableKey);
        PositionShape memory ok = PositionShape(ShapeKind.TickRange, -10, 10);
        vm.expectRevert(NotMarketRegistry.selector);
        vault.bindMarket(9, address(0), id, ok, data);
        vm.expectRevert(abi.encodeWithSelector(MarketBinding.selector, uint256(0)));
        _bindRaw(0, id, ok, data);
        vm.expectRevert(abi.encodeWithSelector(MarketBinding.selector, M1));
        _bindRaw(M1, id, ok, data);
        vm.expectRevert(InvalidShape.selector);
        _bindRaw(9, id, PositionShape(ShapeKind.FullPool, 0, 0), data);
        vm.expectRevert(InvalidShape.selector);
        _bindRaw(9, id, PositionShape(ShapeKind.TickRange, 10, -10), data);
        vm.expectRevert(InvalidPool.selector);
        _bindRaw(9, id, ok, _bindData(stableKey, address(0), ONE, ONE));
        vm.expectRevert(InvalidPool.selector);
        _bindRaw(9, id, ok, _bindData(stableKey, address(usdc), ONE, ONE));
        vm.expectRevert(InvalidPool.selector);
        _bindRaw(9, id, ok, hex"00");
    }

    // ─── Custody through v4 ───

    // TEST-341 verifies: REQ-AMM-CORE-005, REQ-VAULT-012, REQ-VAULT-107
    function test_TEST_341_zeroUnitsAreRefused() public {
        uint8 k = vault.unitExponent(M1);
        if (k == 0) return;
        bytes32 key = _mintFor(alice, stableKey, M1_LOWER, M1_UPPER, uint128(10 ** k - 1));
        vm.expectRevert(ZeroUnits.selector);
        vault.validatePosition(M1, alice, key);
    }

    // TEST-342 verifies: REQ-AMM-CORE-007, REQ-AMM-V4-004
    function test_TEST_342_releaseChecksLengthsAndMinimums() public {
        bytes32 key = _mintFor(alice, stableKey, M1_LOWER, M1_UPPER, 1e15);
        uint128 units = _receive(M1, alice, key);
        _lock();
        vm.startPrank(coll);
        uint256[] memory three = new uint256[](3);
        vm.expectRevert(abi.encodeWithSelector(LengthMismatch.selector, uint256(2), uint256(3)));
        vault.releaseToDepositor(key, units, three);
        vm.expectRevert();
        vault.releaseToDepositor(key, units, _vec(0, type(uint128).max));
        uint256[] memory out = vault.releaseToDepositor(key, units / 2, _zeros());
        vm.stopPrank();
        _unlock();
        assertGt(out[0] + out[1], 0, "principal released to the depositor");
    }

    // TEST-342 verifies: REQ-AMM-V4-004, REQ-AMM-V4-010
    function test_TEST_342_collectOnAnEmptiedPositionPaysNothing() public {
        uint8 k = vault.unitExponent(M1);
        bytes32 key = _mintFor(alice, stableKey, M1_LOWER, M1_UPPER, uint128(1000 * 10 ** k));
        uint128 units = _receive(M1, alice, key);
        _unwind(key, units, _zeros(), recipient);
        _lock();
        vm.prank(coll);
        uint256[] memory fees = vault.collectFees(key, alice);
        _unlock();
        assertEq(fees[0] + fees[1], 0);
    }

    // TEST-342 verifies: REQ-AMM-V4-010
    function test_TEST_342_feesBelowTheRange() public {
        bytes32 key = _mintFor(alice, ethKey, M2_LOWER, M2_UPPER, 1e18);
        _receive(M2, alice, key);
        v4Actor.swap(ethKey, true, -1e16, 4_295_128_740);
        v4Actor.swap(ethKey, false, -20e6, 1_461_446_703_485_210_103_287_273_052_203_988_822_378_723_970_341);
        // Sell ETH until the price is below the range: the fee growth inside is then lower minus upper outside.
        v4Actor.swap(ethKey, true, -1e30, 4_295_128_740);
        (, int24 tick) = _slot0V4(ethKey);
        assertLt(tick, M2_LOWER, "below the range");
        _lock();
        vm.prank(coll);
        uint256[] memory fees = vault.collectFees(key, alice);
        _unlock();
        assertGt(fees[0] + fees[1], 0);
    }

    // ─── Reads ───

    // TEST-341 verifies: REQ-AMM-CORE-008, REQ-AMM-V4-003
    function test_TEST_341_unknownPositionReadsAsNoUnits() public view {
        RiskMetadata memory meta = vault.riskMetadata(M1, bytes32(uint256(999_999)));
        assertEq(meta.positionUnits, 0);
    }

    // TEST-341 verifies: REQ-AMM-V4-005, REQ-AMM-V4-008, REQ-AMM-CORE-013
    function test_TEST_341_failedOrMalformedReferenceReads() public {
        _observe(stableRef, 10);
        (, bool ok) = vault.consistencyDeviation(M1, 0, _vec(ONE, ONE));
        assertFalse(ok, "zero window");
        vm.mockCallRevert(address(stableRef), abi.encodeWithSelector(IUniswapV3Pool.observe.selector), "OLD");
        (, ok) = vault.consistencyDeviation(M1, 60, _vec(ONE, ONE));
        assertFalse(ok, "observe fails");
        vm.clearMockedCalls();
        int56[] memory t = new int56[](1);
        uint160[] memory s = new uint160[](1);
        vm.mockCall(address(stableRef), abi.encodeWithSelector(IUniswapV3Pool.observe.selector), abi.encode(t, s));
        assertFalse(vault.riskStatus(M1, 60).depthAvailable, "malformed observe");
        vm.clearMockedCalls();
    }
}
