// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {Lock} from "../../../src/lock/lock/Lock.sol";
import {PositionShape} from "../../../src/types/PositionShape.sol";
import {ShapeKind} from "../../../src/types/ShapeKind.sol";
import {UniswapV3IntegrationHarness} from "../../utils/harness/UniswapV3IntegrationHarness.sol";
import {MockV3Factory, MockV3Pool} from "../../utils/mocks/UniswapV3Mocks.sol";

/// @title UniswapV3IntegrationProperties
/// @notice Echidna and Medusa harness of the Uniswap v3 LPVault (mock-factory harness) over four NFTs of one market.
/// The harness is both Collateralization and the Lock's AaveAdapter, so every custody call runs as it does in
/// production: inside a Lock session, from Collateralization.
/// @dev Properties: every NFT with a depositor of record is held by the LPVault and its market is 1 (INV-002, INV-007,
/// REQ-VAULT-152); the Lock is free between transactions. Assertion entry points: `pledge`, `unwind`, `returnIt`,
/// `collect`, `donateLiquidity`, `push`; each selects one of four NFTs by `i % 4`. The harness stays under the
/// 49,152-byte initcode limit with a minimal NFPM and token; donations and `returnStray` are covered by the unit suites.
contract UniswapV3IntegrationProperties {
    address internal constant SWAP = address(0x5A9);
    address internal constant TIMELOCK = address(0x713E);
    address internal constant RECIPIENT = address(0xBEEF);

    Lock internal lock;
    EchidnaNfpm internal nfpm;
    MockV3Pool internal pool;
    UniswapV3IntegrationHarness internal vault;
    Registrar internal registrar;
    uint256[4] internal ids;

    constructor() {
        lock = new Lock(address(this), SWAP);
        MockV3Factory factory = new MockV3Factory();
        nfpm = new EchidnaNfpm(address(factory));
        EchidnaToken a = new EchidnaToken();
        EchidnaToken b = new EchidnaToken();
        pool = MockV3Pool(factory.createPool(address(a), address(b), 500, 10));
        registrar = new Registrar();
        vault = new UniswapV3IntegrationHarness(
            1,
            address(this),
            address(registrar),
            address(lock),
            TIMELOCK,
            address(nfpm),
            address(factory),
            factory.poolInitCodeHash()
        );
        registrar.bind(vault, address(pool));
        for (uint256 i = 0; i < 4; ++i) {
            ids[i] = nfpm.mint(address(this), pool.token0(), pool.token1(), 500, -50, 50, uint128(1e12 * (i + 1)));
        }
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

    function property_recordedNftsAreHeld() external view returns (bool) {
        for (uint256 i = 0; i < 4; ++i) {
            bytes32 key = bytes32(ids[i]);
            if (vault.depositorOf(key) != address(0)) {
                if (nfpm.ownerOf(ids[i]) != address(vault) || vault.marketOfPosition(key) != 1) return false;
            } else if (vault.marketOfPosition(key) != 0) {
                return false;
            }
        }
        return true;
    }

    function property_lockFreeBetweenTransactions() external view returns (bool) {
        return !lock.isLocked();
    }

    // ─── Assertion entry points ───

    function pledge(
        uint8 i
    ) external {
        uint256 id = ids[i % 4];
        bool ownedHere = nfpm.ownerOf(id) == address(this);
        if (ownedHere) nfpm.approve(address(vault), id);
        lock.acquire();
        try vault.receivePosition(1, address(this), bytes32(id)) returns (uint128 units) {
            assert(ownedHere && units > 0);
            assert(nfpm.ownerOf(id) == address(vault));
        } catch {
            assert(!ownedHere || vault.depositorOf(bytes32(id)) == address(0));
        }
        lock.release();
    }

    function unwind(
        uint8 i,
        uint128 units
    ) external {
        bytes32 key = bytes32(ids[i % 4]);
        lock.acquire();
        bool custodied = vault.depositorOf(key) != address(0);
        uint128 live = custodied ? vault.unitsOf(key) : 0;
        try vault.unwind(key, units, new uint256[](2), RECIPIENT) {
            assert(custodied && vault.unitsOf(key) == live - units);
        } catch {}
        lock.release();
    }

    function returnIt(
        uint8 i
    ) external {
        bytes32 key = bytes32(ids[i % 4]);
        lock.acquire();
        address depositor = vault.depositorOf(key);
        try vault.returnPosition(key) returns (address d) {
            assert(d == depositor && d != address(0) && nfpm.ownerOf(uint256(key)) == d);
        } catch {
            assert(depositor == address(0));
        }
        lock.release();
    }

    function collect(
        uint8 i,
        uint128 fee0
    ) external {
        bytes32 key = bytes32(ids[i % 4]);
        nfpm.accrue(uint256(key), fee0 % 1e18, 0);
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
        bytes32 key = bytes32(ids[i % 4]);
        address depositor = vault.depositorOf(key);
        nfpm.increaseLiquidity(uint256(key), amount);
        assert(vault.depositorOf(key) == depositor);
    }

    function push(
        uint8 i
    ) external {
        uint256 id = ids[i % 4];
        if (nfpm.ownerOf(id) != address(this)) return;
        nfpm.safeTransferFrom(address(this), address(vault), id);
        assert(vault.depositorOf(bytes32(id)) == address(0));
    }
}

/// @notice Stands in for the MarketRegistry, the only caller of `bindMarket`: binds market 1 on `[-50, 50]`.
contract Registrar {
    function bind(
        UniswapV3IntegrationHarness vault,
        address pool
    ) external {
        vault.bindMarket(1, pool, bytes32(0), PositionShape(ShapeKind.TickRange, -50, 50), abi.encode(1e8, 1e8));
    }
}

/// @notice Minimal ERC-20 for the harness: decimals, open mint and balances (pool tokens of the market).
contract EchidnaToken {
    mapping(address => uint256) public balanceOf;

    function decimals() external pure returns (uint8) {
        return 6;
    }

    function mint(
        address to,
        uint256 amount
    ) external {
        balanceOf[to] += amount;
    }
}

/// @notice Minimal Uniswap v3 NFPM for the harness (no OpenZeppelin, to keep the harness under the initcode limit):
/// ownership with per-token approval cleared on transfer, a receiver hook on `safeTransferFrom`, the 12-field
/// `positions`, a permissionless `increaseLiquidity`, `decreaseLiquidity` owing 1 raw unit of each token per 1,000
/// units, and `collect` paying up to the owed amounts by minting to the recipient.
contract EchidnaNfpm {
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
        uint24,
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
        returns (uint96, address, address, address, uint24, int24, int24, uint128, uint256, uint256, uint128, uint128)
    {
        Position memory p = pos[id];
        require(p.token0 != address(0), "Invalid token ID");
        return (0, address(0), p.token0, p.token1, 500, p.tickLower, p.tickUpper, p.liquidity, 0, 0, p.owed0, p.owed1);
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

interface IHarnessReceiver {
    function onERC721Received(
        address operator,
        address from,
        uint256 tokenId,
        bytes calldata data
    ) external returns (bytes4);
}
