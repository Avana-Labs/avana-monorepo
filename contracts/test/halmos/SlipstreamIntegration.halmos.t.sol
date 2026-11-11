// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {SlipstreamIntegration} from "../../src/amm/slipstream/SlipstreamIntegration.sol";
import {ILPVaultErrors} from "../../src/custody/lp-vault/ILPVaultErrors.sol";
import {Lock} from "../../src/lock/lock/Lock.sol";
import {PositionShape} from "../../src/types/PositionShape.sol";
import {ShapeKind} from "../../src/types/ShapeKind.sol";
import {MockCLFactory, MockCLPool, MockSlipstreamNPM} from "../utils/mocks/SlipstreamMocks.sol";
import {MintableToken} from "../utils/mocks/UniswapV3Mocks.sol";
import {Test} from "forge-std/Test.sol";

/// @title SlipstreamIntegrationHalmosTest
/// @notice Symbolic checks of PROP-083 on the production Slipstream LPVault over four mock generations: a position is
/// accepted, as a view and in custody, only when its pool (derived by tick spacing on its own generation's factory)
/// and both ticks equal its market's; a position of any other generation is refused, even when that generation's
/// factory resolves the market's pool; the key encoding round-trips.
/// @dev Concrete market 1 on `[-50, 50]` of generation 2's spacing-10 pool; ticks, spacing, owners, units, token IDs
/// and generations symbolic.
contract SlipstreamIntegrationHalmosTest is Test {
    address internal constant ADAPTER = address(0xADA9);
    address internal constant SWAP = address(0x5A9);
    address internal constant COLL = address(0xC011);
    address internal constant REGISTRY = address(0x4E6);
    address internal constant TIMELOCK = address(0x713E);
    address internal constant OWNER = address(0xA11CE);
    uint8 internal constant GEN = 2;

    Lock internal lock;
    MockSlipstreamNPM[4] internal npms;
    MockCLFactory[4] internal facts;
    MockCLPool internal pool;
    SlipstreamIntegration internal vault;

    function setUp() public {
        lock = new Lock(ADAPTER, SWAP);
        address[4] memory n;
        address[4] memory f;
        MockCLFactory[4] memory factories;
        for (uint256 g = 0; g < 4; ++g) {
            factories[g] = new MockCLFactory();
            npms[g] = new MockSlipstreamNPM(address(factories[g]));
            factories[g].setNft(address(npms[g]));
            (n[g], f[g]) = (address(npms[g]), address(factories[g]));
            facts[g] = factories[g];
        }
        MintableToken a = new MintableToken("A", 6);
        MintableToken b = new MintableToken("B", 6);
        factories[GEN].enableTickSpacing(10, 500);
        pool = MockCLPool(factories[GEN].createPool(address(a), address(b), 10));
        vault = new SlipstreamIntegration(1, COLL, REGISTRY, address(lock), TIMELOCK, n, f);
        vm.prank(REGISTRY);
        vault.bindMarket(
            1,
            address(pool),
            bytes32(0),
            PositionShape(ShapeKind.TickRange, -50, 50),
            abi.encode(uint256(GEN), uint256(1e8), uint256(1e8))
        );
    }

    // PROP-083 verifies: INV-005, REQ-AMM-CORE-006, REQ-AMM-SLIP-018, REQ-VAULT-009, REQ-AMM-SLIP-003
    function check_PROP_083_validateAcceptsOnlyTheExactRange(
        int24 lower,
        int24 upper,
        uint128 liquidity
    ) public {
        uint256 id = npms[GEN].mint(OWNER, pool.token0(), pool.token1(), 10, lower, upper, liquidity);
        bytes32 key = bytes32((uint256(GEN) << 248) | id);
        (bool ok, bytes memory ret) = address(vault).staticcall(abi.encodeCall(vault.validatePosition, (1, OWNER, key)));
        if (ok) {
            assert(lower == -50 && upper == 50 && liquidity > 0);
            assert(abi.decode(ret, (uint128)) == liquidity);
        } else if (lower != -50 || upper != 50) {
            assert(
                keccak256(ret) == keccak256(abi.encodeWithSelector(ILPVaultErrors.RangeMismatch.selector, lower, upper))
            );
        }
    }

    // PROP-083 verifies: INV-005, REQ-AMM-CORE-006, REQ-AMM-SLIP-002, REQ-AMM-SLIP-003, REQ-VAULT-008, REQ-VAULT-147
    function check_PROP_083_receiveTakesOnlyTheExactRangeOfTheMarketPool(
        int24 lower,
        int24 upper,
        int24 spacing
    ) public {
        uint256 id = npms[GEN].mint(OWNER, pool.token0(), pool.token1(), spacing, lower, upper, 1e9);
        bytes32 key = bytes32((uint256(GEN) << 248) | id);
        vm.prank(OWNER);
        npms[GEN].approve(address(vault), id);
        vm.prank(ADAPTER);
        lock.acquire();
        vm.prank(COLL);
        (bool ok,) = address(vault).call(abi.encodeCall(vault.receivePosition, (1, OWNER, key)));
        if (ok) {
            assert(lower == -50 && upper == 50 && spacing == 10);
            assert(npms[GEN].ownerOf(id) == address(vault));
        } else {
            assert(npms[GEN].ownerOf(id) == OWNER);
        }
    }

    // PROP-083 verifies: INV-005, INV-017, REQ-AMM-SLIP-001, REQ-AMM-SLIP-018
    function check_PROP_083_anotherGenerationIsNeverAccepted(
        uint8 gen,
        int24 lower,
        int24 upper
    ) public {
        vm.assume(gen < 4 && gen != GEN);
        MockSlipstreamNPM npm = gen == 0 ? npms[0] : gen == 1 ? npms[1] : npms[3];
        uint256 id = npm.mint(OWNER, pool.token0(), pool.token1(), 10, lower, upper, 1e9);
        bytes32 key = bytes32((uint256(gen) << 248) | id);
        (bool ok,) = address(vault).staticcall(abi.encodeCall(vault.validatePosition, (1, OWNER, key)));
        assert(!ok);
    }

    // PROP-083 verifies: INV-005, REQ-AMM-SLIP-001, REQ-AMM-SLIP-007, REQ-AMM-SLIP-018
    // Review CL-02: the refusal holds even when the other generation's factory resolves the market's pool.
    function check_PROP_083_anotherGenerationIsRefusedEvenWhenItsFactoryResolvesThePool(
        uint8 gen,
        uint128 units
    ) public {
        vm.assume(gen < 4 && gen != GEN && units > 0);
        MockCLFactory f = gen == 0 ? facts[0] : gen == 1 ? facts[1] : facts[3];
        MockSlipstreamNPM npm = gen == 0 ? npms[0] : gen == 1 ? npms[1] : npms[3];
        f.register(pool.token0(), pool.token1(), 10, address(pool));
        uint256 id = npm.mint(OWNER, pool.token0(), pool.token1(), 10, -50, 50, units);
        bytes32 key = bytes32((uint256(gen) << 248) | id);
        (bool ok,) = address(vault).staticcall(abi.encodeCall(vault.validatePosition, (1, OWNER, key)));
        assert(!ok);
    }

    // PROP-083 verifies: REQ-AMM-SLIP-001, SPEC-AMM-CORE-002
    function check_PROP_083_keyEncodingRoundTrips(
        uint8 gen,
        uint256 tokenId
    ) public view {
        (bool ok, bytes memory ret) = address(vault).staticcall(abi.encodeCall(vault.positionKeyOf, (gen, tokenId)));
        if (gen < 4 && tokenId < (uint256(1) << 248)) {
            assert(ok);
            bytes32 key = abi.decode(ret, (bytes32));
            assert(uint256(key) >> 248 == gen);
            assert(vault.tokenIdOf(key) == tokenId);
        } else {
            assert(!ok);
        }
    }
}
