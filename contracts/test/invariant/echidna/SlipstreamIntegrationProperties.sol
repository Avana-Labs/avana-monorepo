// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {SlipstreamIntegration} from "../../../src/amm/slipstream/SlipstreamIntegration.sol";
import {Lock} from "../../../src/lock/lock/Lock.sol";
import {PositionShape} from "../../../src/types/PositionShape.sol";
import {ShapeKind} from "../../../src/types/ShapeKind.sol";
import {EchidnaToken, IHarnessReceiver} from "./UniswapV3IntegrationProperties.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";

/// @title SlipstreamIntegrationProperties
/// @notice Echidna and Medusa harness of the production Slipstream LPVault over four generations and five NFTs: four of
/// market 1's generation (2) and one of generation 0 with the same token ID as the first. The harness is both
/// Collateralization and the Lock's AaveAdapter, so every custody call runs as it does in production.
/// @dev Properties: every NFT with a depositor of record is held by the LPVault on its own generation's manager and its
/// market is 1 (INV-002, INV-007, REQ-AMM-SLIP-001); the generation-0 NFT is never recorded; the live units of a
/// recorded NFT never fall below the units credited at its pledge minus the units unwound (INV-002); the Lock is free
/// between transactions. Assertion entry points: `pledge`, `pledgeOtherGeneration`, `unwind`, `returnIt`, `collect`,
/// `donateLiquidity`, `push`, `stealAttempt`; each selects one of four NFTs by `i % 4`.
contract SlipstreamIntegrationProperties {
    address internal constant SWAP = address(0x5A9);
    address internal constant TIMELOCK = address(0x713E);
    address internal constant RECIPIENT = address(0xBEEF);
    uint8 internal constant GEN = 2;

    Lock internal lock;
    EchidnaSlipNpm[4] internal npms;
    EchidnaCLPool internal pool;
    SlipstreamIntegration internal vault;
    SlipRegistrar internal registrar;
    uint256[4] internal ids;
    uint256 internal otherGenId;
    mapping(uint256 => uint128) internal backed;

    constructor() {
        lock = new Lock(address(this), SWAP);
        address[4] memory n;
        address[4] memory f;
        EchidnaCLFactory gen2Factory;
        for (uint256 g = 0; g < 4; ++g) {
            EchidnaCLFactory factory = new EchidnaCLFactory();
            npms[g] = new EchidnaSlipNpm(address(factory));
            (n[g], f[g]) = (address(npms[g]), address(factory));
            if (g == GEN) gen2Factory = factory;
        }
        EchidnaToken a = new EchidnaToken();
        EchidnaToken b = new EchidnaToken();
        pool = EchidnaCLPool(gen2Factory.createPool(address(a), address(b), address(npms[GEN])));
        registrar = new SlipRegistrar();
        vault = new SlipstreamIntegration(1, address(this), address(registrar), address(lock), TIMELOCK, n, f);
        registrar.bind(vault, address(pool));
        for (uint256 i = 0; i < 4; ++i) {
            ids[i] = npms[GEN].mint(address(this), pool.token0(), pool.token1(), -50, 50, uint128(1e12 * (i + 1)));
        }
        otherGenId = npms[0].mint(address(this), pool.token0(), pool.token1(), -50, 50, 1e12);
    }

    function onERC721Received(
        address,
        address,
        uint256,
        bytes calldata
    ) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }

    // ─── Properties ───

    function property_recordedNftsAreHeldAndBacked() external view returns (bool) {
        for (uint256 i = 0; i < 4; ++i) {
            bytes32 key = _key(i);
            if (vault.depositorOf(key) != address(0)) {
                if (npms[GEN].ownerOf(ids[i]) != address(vault) || vault.marketOfPosition(key) != 1) return false;
                if (vault.unitsOf(key) < backed[i]) return false;
            } else if (vault.marketOfPosition(key) != 0) {
                return false;
            }
        }
        return vault.depositorOf(bytes32(otherGenId)) == address(0);
    }

    function property_lockFreeBetweenTransactions() external view returns (bool) {
        return !lock.isLocked();
    }

    // ─── Assertion entry points ───

    function pledge(
        uint8 i
    ) external {
        uint256 id = ids[i % 4];
        bool ownedHere = npms[GEN].ownerOf(id) == address(this);
        if (ownedHere) npms[GEN].approve(address(vault), id);
        lock.acquire();
        try vault.receivePosition(1, address(this), _key(i % 4)) returns (uint128 units) {
            assert(ownedHere && units > 0);
            assert(npms[GEN].ownerOf(id) == address(vault));
            backed[i % 4] = units;
        } catch {
            assert(!ownedHere || vault.depositorOf(_key(i % 4)) == address(0));
        }
        lock.release();
    }

    function pledgeOtherGeneration() external {
        if (npms[0].ownerOf(otherGenId) == address(this)) npms[0].approve(address(vault), otherGenId);
        lock.acquire();
        try vault.receivePosition(1, address(this), bytes32(otherGenId)) {
            assert(false);
        } catch {}
        lock.release();
    }

    function unwind(
        uint8 i,
        uint128 units
    ) external {
        bytes32 key = _key(i % 4);
        lock.acquire();
        bool custodied = vault.depositorOf(key) != address(0);
        uint128 live = custodied ? vault.unitsOf(key) : 0;
        try vault.unwind(key, units, new uint256[](2), RECIPIENT) {
            assert(custodied && vault.unitsOf(key) == live - units);
            backed[i % 4] = units >= backed[i % 4] ? 0 : backed[i % 4] - units;
        } catch {}
        lock.release();
    }

    function returnIt(
        uint8 i
    ) external {
        bytes32 key = _key(i % 4);
        lock.acquire();
        address depositor = vault.depositorOf(key);
        try vault.returnPosition(key) returns (address d) {
            assert(d == depositor && d != address(0) && npms[GEN].ownerOf(ids[i % 4]) == d);
            backed[i % 4] = 0;
        } catch {
            assert(depositor == address(0));
        }
        lock.release();
    }

    function collect(
        uint8 i,
        uint128 fee0
    ) external {
        bytes32 key = _key(i % 4);
        npms[GEN].accrue(ids[i % 4], fee0 % 1e18, 0);
        lock.acquire();
        uint128 before = vault.depositorOf(key) == address(0) ? 0 : vault.unitsOf(key);
        try vault.collectFees(key, address(this)) {
            assert(vault.unitsOf(key) == before);
        } catch {}
        lock.release();
    }

    function donateLiquidity(
        uint8 i,
        uint64 amount
    ) external {
        bytes32 key = _key(i % 4);
        address depositor = vault.depositorOf(key);
        npms[GEN].increaseLiquidity(ids[i % 4], amount);
        assert(vault.depositorOf(key) == depositor);
    }

    function push(
        uint8 i
    ) external {
        uint256 id = ids[i % 4];
        if (npms[GEN].ownerOf(id) != address(this)) return;
        npms[GEN].safeTransferFrom(address(this), address(vault), id);
        assert(vault.depositorOf(_key(i % 4)) == address(0));
    }

    /// @notice The harness as the former owner tries to move or reduce a custodied NFT on the manager directly.
    function stealAttempt(
        uint8 i
    ) external {
        uint256 id = ids[i % 4];
        if (npms[GEN].ownerOf(id) != address(vault)) return;
        try npms[GEN].transferFrom(address(vault), address(this), id) {
            assert(false);
        } catch {}
        try npms[GEN].decreaseLiquidity(EchidnaSlipNpm.DecreaseLiquidityParams(id, 1, 0, 0, block.timestamp)) {
            assert(false);
        } catch {}
    }

    function _key(
        uint256 i
    ) internal view returns (bytes32) {
        return bytes32((uint256(GEN) << 248) | ids[i]);
    }
}

/// @notice Stands in for the MarketRegistry: binds market 1 on `[-50, 50]` of generation 2's pool.
contract SlipRegistrar {
    function bind(
        SlipstreamIntegration vault,
        address pool
    ) external {
        vault.bindMarket(
            1,
            pool,
            bytes32(0),
            PositionShape(ShapeKind.TickRange, -50, 50),
            abi.encode(uint256(2), uint256(1e8), uint256(1e8))
        );
    }
}

/// @notice Minimal Slipstream pool for the harness, deployed as an EIP-1167 clone and initialized once: the
/// immutables the listing check reads and the 6-field `slot0` (unlocked, cardinality 1); it has no `gauge()`, so the
/// LPVault's gauge read fails and counts as no gauge.
contract EchidnaCLPool {
    address public factory;
    address public token0;
    address public token1;
    address public nft;

    function initialize(
        address token0_,
        address token1_,
        address nft_
    ) external {
        require(factory == address(0), "initialized");
        (factory, token0, token1, nft) = (msg.sender, token0_, token1_, nft_);
    }

    function tickSpacing() external pure returns (int24) {
        return 1;
    }

    function slot0() external pure returns (uint160, int24, uint16, uint16, uint16, bool) {
        return (uint160(1) << 96, 0, 0, 1, 1, true);
    }
}

/// @notice Minimal Slipstream factory for the harness: clones one `EchidnaCLPool` of spacing 1, the only spacing enabled;
/// `getPool` returns it for spacing 1 (every position of the harness is of its pair).
contract EchidnaCLFactory {
    address public immutable poolImplementation = address(new EchidnaCLPool());
    address internal pool;

    function createPool(
        address tokenA,
        address tokenB,
        address nft
    ) external returns (address p) {
        (address t0, address t1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        p = Clones.clone(poolImplementation);
        EchidnaCLPool(p).initialize(t0, t1, nft);
        pool = p;
    }

    function getPool(
        address,
        address,
        int24 spacing
    ) external view returns (address) {
        return spacing == 1 ? pool : address(0);
    }

    function tickSpacingToFee(
        int24 spacing
    ) external pure returns (uint24) {
        return spacing == 1 ? 100 : 0;
    }
}

/// @notice Minimal Slipstream NPM for the harness (no OpenZeppelin, to keep the harness under the initcode limit):
/// `factory()`, ownership with per-token approval cleared on transfer, a receiver hook on `safeTransferFrom`, the
/// 12-field `positions` with tick spacing 1 in field 5, a permissionless `increaseLiquidity`, `decreaseLiquidity`
/// owing 1 raw unit of each token per 1,000 units, and `collect` paying up to the owed amounts by minting.
contract EchidnaSlipNpm {
    struct Position {
        address token0;
        address token1;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
        uint128 owed0;
        uint128 owed1;
    }

    struct DecreaseLiquidityParams {
        uint256 tokenId;
        uint128 liquidity;
        uint256 amount0Min;
        uint256 amount1Min;
        uint256 deadline;
    }

    struct CollectParams {
        uint256 tokenId;
        address recipient;
        uint128 amount0Max;
        uint128 amount1Max;
    }

    address public immutable factory;
    uint256 internal next = 1;
    mapping(uint256 => address) internal owners;
    mapping(uint256 => address) public getApproved;
    mapping(uint256 => Position) internal pos;

    constructor(
        address factory_
    ) {
        factory = factory_;
    }

    function mint(
        address to,
        address token0,
        address token1,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity
    ) external returns (uint256 id) {
        id = next++;
        owners[id] = to;
        pos[id] = Position(token0, token1, tickLower, tickUpper, liquidity, 0, 0);
    }

    function ownerOf(
        uint256 id
    ) public view returns (address o) {
        o = owners[id];
        require(o != address(0), "nonexistent");
    }

    function approve(
        address to,
        uint256 id
    ) external {
        require(msg.sender == ownerOf(id), "owner");
        getApproved[id] = to;
    }

    function transferFrom(
        address from,
        address to,
        uint256 id
    ) public {
        require(ownerOf(id) == from && (msg.sender == from || msg.sender == getApproved[id]), "auth");
        owners[id] = to;
        delete getApproved[id];
    }

    function safeTransferFrom(
        address from,
        address to,
        uint256 id
    ) external {
        transferFrom(from, to, id);
        bytes4 r = IHarnessReceiver(to).onERC721Received(msg.sender, from, id, "");
        require(r == IHarnessReceiver.onERC721Received.selector, "receiver");
    }

    function positions(
        uint256 id
    )
        external
        view
        returns (uint96, address, address, address, int24, int24, int24, uint128, uint256, uint256, uint128, uint128)
    {
        Position memory p = pos[id];
        require(p.token0 != address(0), "Invalid token ID");
        return (0, address(0), p.token0, p.token1, 1, p.tickLower, p.tickUpper, p.liquidity, 0, 0, p.owed0, p.owed1);
    }

    function increaseLiquidity(
        uint256 id,
        uint128 liquidity
    ) external {
        pos[id].liquidity += liquidity;
    }

    function accrue(
        uint256 id,
        uint128 amount0,
        uint128 amount1
    ) external {
        pos[id].owed0 += amount0;
        pos[id].owed1 += amount1;
    }

    function decreaseLiquidity(
        DecreaseLiquidityParams calldata p
    ) external returns (uint256 a0, uint256 a1) {
        require(msg.sender == ownerOf(p.tokenId) && p.liquidity > 0, "auth");
        Position storage x = pos[p.tokenId];
        x.liquidity -= p.liquidity;
        a0 = p.liquidity / 1000;
        a1 = a0;
        require(a0 >= p.amount0Min && a1 >= p.amount1Min, "Price slippage check");
        x.owed0 += uint128(a0);
        x.owed1 += uint128(a1);
    }

    function collect(
        CollectParams calldata p
    ) external returns (uint256 c0, uint256 c1) {
        require(msg.sender == ownerOf(p.tokenId), "auth");
        Position storage x = pos[p.tokenId];
        c0 = x.owed0 < p.amount0Max ? x.owed0 : p.amount0Max;
        c1 = x.owed1 < p.amount1Max ? x.owed1 : p.amount1Max;
        x.owed0 -= uint128(c0);
        x.owed1 -= uint128(c1);
        EchidnaToken(x.token0).mint(p.recipient, c0);
        EchidnaToken(x.token1).mint(p.recipient, c1);
    }
}
