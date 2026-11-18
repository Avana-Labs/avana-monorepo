// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IUniswapV4Integration} from "../../src/amm/uniswap-v4/IUniswapV4Integration.sol";
import {UniswapV4Integration} from "../../src/amm/uniswap-v4/UniswapV4Integration.sol";
import {ILPVaultBase} from "../../src/custody/lp-vault/ILPVaultBase.sol";
import {UniswapV4PoolKey} from "../../src/interfaces/external/uniswap-v4/IUniswapV4PoolManager.sol";
import {Lock} from "../../src/lock/lock/Lock.sol";
import {PositionShape, ShapeKind} from "../../src/types/PositionTypes.sol";
import {V4StandInManager, V4StandInReference, V4StandInToken} from "../invariant/echidna/UniswapV4StandIns.sol";
import {Test} from "forge-std/Test.sol";

/// @title UniswapV4IntegrationHalmosTest
/// @notice Symbolic check of PROP-083 on the Uniswap v4 LPVault: a PositionManager position is accepted only when its
/// pool key hashes to its market's `PoolId`, both ticks equal the market's, no subscriber is set and it holds liquidity,
/// and then it is credited exactly its liquidity; every other position is refused with the error of the first check it
/// fails, in the order of `REQ-AMM-CORE-005`.
/// @dev Concrete market 1 on `[-50, 50]` of a hookless spacing-10 pool on `V4StandInManager` (v4-core's slot layout
/// served through `extsload`); the position's ticks, subscriber flag, liquidity and pool (the market's or another fee
/// tier) symbolic.
contract UniswapV4IntegrationHalmosTest is Test {
    address internal constant ADAPTER = address(0xADA9);
    address internal constant SWAP = address(0x5A9);
    address internal constant COLL = address(0xC011);
    address internal constant REGISTRY = address(0x4E6);
    address internal constant AUTHORITY = address(0x713E);
    address internal constant OWNER = address(0xA11CE);

    V4StandInManager internal manager;
    UniswapV4Integration internal vault;
    UniswapV4PoolKey internal key;

    function setUp() public {
        Lock lock = new Lock(ADAPTER, SWAP);
        V4StandInToken x = new V4StandInToken();
        V4StandInToken y = new V4StandInToken();
        (address a, address b) = address(x) < address(y) ? (address(x), address(y)) : (address(y), address(x));
        manager = new V4StandInManager(b);
        V4StandInReference ref = new V4StandInReference(a, b);
        key = UniswapV4PoolKey(a, b, 500, 10, address(0));
        bytes32 poolId = keccak256(abi.encode(key));
        manager.initialize(poolId, 0);
        vault =
            new UniswapV4Integration(1, COLL, REGISTRY, address(lock), AUTHORITY, address(manager), address(ref), 12);
        vm.prank(REGISTRY);
        vault.bindMarket(
            1,
            address(0),
            poolId,
            PositionShape(ShapeKind.TickRange, -50, 50),
            abi.encode(key, address(ref), uint256(1e8), uint256(1e8))
        );
    }

    // PROP-083 verifies: INV-005, REQ-AMM-CORE-005, REQ-AMM-CORE-006, REQ-AMM-V4-002, REQ-AMM-V4-003, REQ-VAULT-008, REQ-VAULT-009
    function check_PROP_083_v4ValidateAcceptsOnlyTheExactUnsubscribedPosition(
        int24 lower,
        int24 upper,
        bool subscribed,
        bool otherPool,
        uint128 liquidity
    ) public {
        UniswapV4PoolKey memory k = key;
        if (otherPool) k.fee = 3000;
        uint256 id = manager.mint(OWNER, k, lower, upper, liquidity, subscribed);
        (bool ok, bytes memory ret) =
            address(vault).staticcall(abi.encodeCall(vault.validatePosition, (1, OWNER, bytes32(id))));
        if (ok) {
            assert(!subscribed && !otherPool && lower == -50 && upper == 50 && liquidity > 0);
            assert(abi.decode(ret, (uint128)) == liquidity);
        } else if (subscribed) {
            assert(bytes4(ret) == IUniswapV4Integration.SubscribedPosition.selector);
        } else if (otherPool) {
            assert(bytes4(ret) == ILPVaultBase.PoolMismatch.selector);
        } else if (lower != -50 || upper != 50) {
            assert(
                keccak256(ret) == keccak256(abi.encodeWithSelector(ILPVaultBase.RangeMismatch.selector, lower, upper))
            );
        } else {
            assert(liquidity == 0 && bytes4(ret) == ILPVaultBase.ZeroUnits.selector);
        }
    }
}
