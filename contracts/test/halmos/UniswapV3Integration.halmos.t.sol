// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ClPriceMath} from "../../src/amm/concentrated-liquidity/ClPriceMath.sol";
import {ILPVaultErrors} from "../../src/custody/lp-vault/ILPVaultErrors.sol";
import {Lock} from "../../src/lock/lock/Lock.sol";
import {PositionShape} from "../../src/types/PositionShape.sol";
import {ShapeKind} from "../../src/types/ShapeKind.sol";
import {UniswapV3IntegrationHarness} from "../utils/harness/UniswapV3IntegrationHarness.sol";
import {MintableToken, MockNFPM, MockV3Factory, MockV3Pool} from "../utils/mocks/UniswapV3Mocks.sol";
import {Test} from "forge-std/Test.sol";

/// @title UniswapV3IntegrationHalmosTest
/// @notice Symbolic checks of PROP-083 on the Uniswap v3 LPVault (mock-factory harness): a position is accepted, as a
/// view and in custody, only when its pool and both ticks equal its market's; the clamp keeps the price inside the
/// range and an out-of-range price holds one token only; the composition's token1 amount never exceeds the exact
/// holding at the clamped price.
/// @dev Concrete market 1 on `[-50, 50]` of a spacing-10 pool; position ticks, owners, units and prices symbolic.
contract UniswapV3IntegrationHalmosTest is Test {
    address internal constant ADAPTER = address(0xADA9);
    address internal constant SWAP = address(0x5A9);
    address internal constant COLL = address(0xC011);
    address internal constant REGISTRY = address(0x4E6);
    address internal constant TIMELOCK = address(0x713E);
    address internal constant OWNER = address(0xA11CE);

    Lock internal lock;
    MockNFPM internal nfpm;
    MockV3Pool internal pool;
    UniswapV3IntegrationHarness internal vault;
    uint160 internal sa;
    uint160 internal sb;

    function setUp() public {
        lock = new Lock(ADAPTER, SWAP);
        MockV3Factory factory = new MockV3Factory();
        nfpm = new MockNFPM(address(factory));
        MintableToken a = new MintableToken("A", 6);
        MintableToken b = new MintableToken("B", 6);
        pool = MockV3Pool(factory.createPool(address(a), address(b), 500, 10));
        vault = new UniswapV3IntegrationHarness(
            1, COLL, REGISTRY, address(lock), TIMELOCK, address(nfpm), address(factory), factory.poolInitCodeHash()
        );
        vm.prank(REGISTRY);
        vault.bindMarket(
            1, address(pool), bytes32(0), PositionShape(ShapeKind.TickRange, -50, 50), abi.encode(1e8, 1e8)
        );
        sa = ClPriceMath.sqrtRatioAtTick(-50);
        sb = ClPriceMath.sqrtRatioAtTick(50);
    }

    // PROP-083 verifies: INV-005, REQ-AMM-CORE-006, REQ-AMM-CORE-016, REQ-VAULT-009
    function check_PROP_083_validateAcceptsOnlyTheExactRange(
        int24 lower,
        int24 upper,
        uint128 liquidity
    ) public {
        uint256 id = nfpm.mint(OWNER, pool.token0(), pool.token1(), 500, lower, upper, liquidity);
        (bool ok, bytes memory ret) =
            address(vault).staticcall(abi.encodeCall(vault.validatePosition, (1, OWNER, bytes32(id))));
        if (ok) {
            assert(lower == -50 && upper == 50 && liquidity > 0);
            assert(abi.decode(ret, (uint128)) == liquidity);
        } else if (lower != -50 || upper != 50) {
            assert(
                keccak256(ret) == keccak256(abi.encodeWithSelector(ILPVaultErrors.RangeMismatch.selector, lower, upper))
            );
        }
    }

    // PROP-083 verifies: INV-005, REQ-AMM-CORE-006, REQ-VAULT-008, REQ-VAULT-147
    function check_PROP_083_receiveTakesOnlyTheExactRangeOfTheMarketPool(
        int24 lower,
        int24 upper,
        uint24 fee
    ) public {
        uint256 id = nfpm.mint(OWNER, pool.token0(), pool.token1(), fee, lower, upper, 1e9);
        vm.prank(OWNER);
        nfpm.approve(address(vault), id);
        vm.prank(ADAPTER);
        lock.acquire();
        vm.prank(COLL);
        (bool ok,) = address(vault).call(abi.encodeCall(vault.receivePosition, (1, OWNER, bytes32(id))));
        if (ok) {
            assert(lower == -50 && upper == 50 && fee == 500);
            assert(nfpm.ownerOf(id) == address(vault));
        } else {
            assert(nfpm.ownerOf(id) == OWNER);
        }
    }

    // PROP-083 verifies: SPEC-ORC-006, SPEC-AMM-V3-001
    function check_PROP_083_clampStaysInTheRange(
        uint160 s
    ) public view {
        uint160 c = ClPriceMath.clamp(s, sa, sb);
        assert(c >= sa && c <= sb);
        if (s >= sa && s <= sb) assert(c == s);
        if (s < sa) assert(c == sa);
        if (s > sb) assert(c == sb);
    }

    // PROP-083 verifies: SPEC-ORC-006, SPEC-AMM-V3-001, INV-078
    function check_PROP_083_outOfRangeHoldsOneToken(
        uint160 s,
        uint64 units
    ) public view {
        vm.assume(s <= sa || s >= sb);
        (uint256 a0, uint256 a1) = ClPriceMath.amountsForLiquidity(s, sa, sb, units);
        if (s <= sa) assert(a1 == 0);
        if (s >= sb) assert(a0 == 0);
    }

    // PROP-083 verifies: SPEC-ORC-006, SPEC-AMM-V3-001, INV-078
    function check_PROP_083_token1NeverAboveTheExactHolding(
        uint160 s,
        uint64 units
    ) public view {
        vm.assume(s > sa && s < sb);
        (, uint256 a1) = ClPriceMath.amountsForLiquidity(s, sa, sb, units);
        assert(a1 * ClPriceMath.Q96 <= uint256(units) * uint256(s - sa));
    }
}
