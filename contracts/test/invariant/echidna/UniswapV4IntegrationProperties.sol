// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {UniswapV4Integration} from "../../../src/amm/uniswap-v4/UniswapV4Integration.sol";
import {UniswapV4PoolKey} from "../../../src/interfaces/external/uniswap-v4/IUniswapV4PoolManager.sol";
import {Lock} from "../../../src/lock/lock/Lock.sol";
import {PositionShape} from "../../../src/types/PositionShape.sol";
import {ShapeKind} from "../../../src/types/ShapeKind.sol";
import {V4StandInManager, V4StandInReference, V4StandInToken} from "./UniswapV4StandIns.sol";

/// @title UniswapV4IntegrationProperties
/// @notice Echidna and Medusa harness of the Uniswap v4 LPVault over four NFTs of one hookless market (USDC-like
/// token A and token B, fee 500, spacing 10, range `[-50, 50]`, price at tick 0), on `V4StandInManager`, which keeps
/// pool state in v4-core's slot layout so the LPVault reads it through `extsload` as on the real PoolManager. The
/// harness is both Collateralization and the Lock's AaveAdapter, and the depositor of every pledge, so every custody
/// call runs as it does in production: inside a Lock session, from Collateralization. Token A can blocklist the
/// harness, the case of the LPVault's fallback removal (`REQ-AMM-V4-013`). NFTs 1 and 2 are pledged and owe fees at
/// deployment, so hevm's single-transaction proofs start from custodied positions.
/// @dev Properties: every NFT with a depositor of record is held by the LPVault in market 1 with live liquidity, and
/// every other has no market (INV-002, INV-007, REQ-VAULT-152); the LPVault holds no token; for every NFT, the fees
/// owed plus the fees paid to the depositor plus the fees of fallback removals equal the fees accrued (INV-033,
/// REQ-AMM-V4-004, REQ-AMM-V4-013); the Lock is free between transactions. Assertion entry points: `pledge`, `unwind`,
/// `release`, `returnIt`, `collect`, `accrue`, `push`, `blocklist`; each selects one of four NFTs by `i % 4`. The
/// real PoolManager and PositionManager run in `UniswapV4Integration.FeesCustody.invariant.t.sol`.
contract UniswapV4IntegrationProperties {
    address internal constant SWAP = address(0x5A9);
    address internal constant TIMELOCK = address(0x713E);
    address internal constant RECIPIENT = address(0xBEEF);
    uint256 internal constant MARKET = 1;

    Lock internal lock;
    V4StandInManager internal manager;
    V4StandInToken internal tokenA;
    V4StandInToken internal tokenB;
    UniswapV4Integration internal vault;
    UniswapV4PoolKey internal key;
    bytes32 internal poolId;
    uint256[4] internal ids;

    /// @dev Per NFT and token: fees accrued, paid to the depositor, sent to the recipient by a fallback removal.
    mapping(uint256 id => uint256[2] amounts) internal accrued;
    mapping(uint256 id => uint256[2] amounts) internal paid;
    mapping(uint256 id => uint256[2] amounts) internal forfeited;

    constructor() {
        lock = new Lock(address(this), SWAP);
        V4StandInToken x = new V4StandInToken();
        V4StandInToken y = new V4StandInToken();
        (tokenA, tokenB) = address(x) < address(y) ? (x, y) : (y, x);
        manager = new V4StandInManager(address(tokenB));
        V4StandInReference ref = new V4StandInReference(address(tokenA), address(tokenB));
        key = UniswapV4PoolKey(address(tokenA), address(tokenB), 500, 10, address(0));
        poolId = keccak256(abi.encode(key));
        manager.initialize(poolId, 0);
        V4Registrar registrar = new V4Registrar();
        vault = new UniswapV4Integration(
            1, address(this), address(registrar), address(lock), TIMELOCK, address(manager), address(ref), 12
        );
        registrar.bind(vault, poolId, abi.encode(key, address(ref), uint256(1e8), uint256(1e8)));
        for (uint256 i = 0; i < 4; ++i) {
            ids[i] = manager.mint(address(this), key, -50, 50, uint128(1e12 * (i + 1)), false);
        }
        for (uint256 i = 0; i < 2; ++i) {
            manager.approve(address(vault), ids[i]);
            lock.acquire();
            vault.receivePosition(MARKET, address(this), bytes32(ids[i]));
            lock.release();
        }
        _accrue(1 << 120, 1 << 119);
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
            bytes32 k = bytes32(ids[i]);
            if (vault.depositorOf(k) != address(0)) {
                if (manager.ownerOf(ids[i]) != address(vault) || vault.marketOfPosition(k) != MARKET) return false;
            } else if (vault.marketOfPosition(k) != 0) {
                return false;
            }
        }
        return true;
    }

    function property_vaultHoldsNoToken() external view returns (bool) {
        return tokenA.balanceOf(address(vault)) == 0 && tokenB.balanceOf(address(vault)) == 0;
    }

    function property_feesOwedPlusPaidEqualAccrued() external view returns (bool) {
        for (uint256 i = 0; i < 4; ++i) {
            uint256 id = ids[i];
            (uint256 o0, uint256 o1) = manager.feesOwed(id);
            if (o0 + paid[id][0] + forfeited[id][0] != accrued[id][0]) return false;
            if (o1 + paid[id][1] + forfeited[id][1] != accrued[id][1]) return false;
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
        bool ownedHere = manager.ownerOf(id) == address(this);
        if (ownedHere) manager.approve(address(vault), id);
        lock.acquire();
        try vault.receivePosition(MARKET, address(this), bytes32(id)) returns (uint128 units) {
            assert(ownedHere && units > 0);
            assert(manager.ownerOf(id) == address(vault));
        } catch {
            assert(!ownedHere || vault.depositorOf(bytes32(id)) == address(0));
        }
        lock.release();
    }

    /// @notice A removal to another recipient (a seizure): the depositor receives exactly the owed fees and the
    /// recipient the returned amounts, or, while token A refuses the depositor and fees in token A are owed, the
    /// depositor receives nothing and the returned amounts cover the fees (`REQ-AMM-V4-013`).
    function unwind(
        uint8 i,
        uint128 units
    ) external {
        uint256 id = ids[i % 4];
        bytes32 k = bytes32(id);
        lock.acquire();
        bool custodied = vault.depositorOf(k) != address(0);
        uint128 live = custodied ? vault.unitsOf(k) : 0;
        (uint256 o0, uint256 o1) = manager.feesOwed(id);
        uint256[4] memory b = _balances();
        try vault.unwind(k, units, new uint256[](2), RECIPIENT) returns (uint256[] memory amounts) {
            assert(custodied && units <= live && vault.unitsOf(k) == live - units);
            uint256[4] memory a = _balances();
            assert(a[2] - b[2] == amounts[0] && a[3] - b[3] == amounts[1]);
            if (tokenA.blocked(address(this)) && o0 > 0) {
                assert(a[0] == b[0] && a[1] == b[1] && amounts[0] >= o0 && amounts[1] >= o1);
                _book(forfeited, id, o0, o1);
            } else {
                assert(a[0] - b[0] == o0 && a[1] - b[1] == o1);
                _book(paid, id, o0, o1);
            }
        } catch {
            assert(!custodied || units > live || units == 0);
        }
        lock.release();
    }

    /// @notice A release to the depositor pays the principal and exactly the owed fees.
    function release(
        uint8 i,
        uint128 units
    ) external {
        uint256 id = ids[i % 4];
        bytes32 k = bytes32(id);
        lock.acquire();
        (uint256 o0, uint256 o1) = manager.feesOwed(id);
        uint256[4] memory b = _balances();
        try vault.releaseToDepositor(k, units, new uint256[](2)) returns (uint256[] memory amounts) {
            uint256[4] memory a = _balances();
            assert(a[0] - b[0] == amounts[0] + o0 && a[1] - b[1] == amounts[1] + o1);
            _book(paid, id, o0, o1);
        } catch {}
        lock.release();
    }

    function returnIt(
        uint8 i
    ) external {
        bytes32 k = bytes32(ids[i % 4]);
        lock.acquire();
        address depositor = vault.depositorOf(k);
        try vault.returnPosition(k) returns (address d) {
            assert(d == depositor && d != address(0) && manager.ownerOf(uint256(k)) == d);
        } catch {
            assert(depositor == address(0));
        }
        lock.release();
    }

    /// @notice A fee collection pays the depositor exactly the owed fees and leaves none owed; units never move.
    function collect(
        uint8 i
    ) external {
        uint256 id = ids[i % 4];
        bytes32 k = bytes32(id);
        lock.acquire();
        uint128 before = vault.depositorOf(k) == address(0) ? 0 : vault.unitsOf(k);
        (uint256 o0, uint256 o1) = manager.feesOwed(id);
        uint256[4] memory b = _balances();
        try vault.collectFees(k, address(this)) returns (uint256[] memory amounts) {
            uint256[4] memory a = _balances();
            assert(amounts[0] == o0 && amounts[1] == o1 && a[0] - b[0] == o0 && a[1] - b[1] == o1);
            (uint256 n0, uint256 n1) = manager.feesOwed(id);
            assert(n0 == 0 && n1 == 0 && vault.unitsOf(k) == before);
            _book(paid, id, o0, o1);
        } catch {}
        lock.release();
    }

    /// @notice Pool fees accrue: fee growth rises by up to 2^120 per unit of liquidity (Q128) in each token.
    function accrue(
        uint128 g0,
        uint128 g1
    ) external {
        _accrue(g0 >> 8, g1 >> 8);
    }

    function push(
        uint8 i
    ) external {
        uint256 id = ids[i % 4];
        if (manager.ownerOf(id) != address(this)) return;
        manager.safeTransferFrom(address(this), address(vault), id);
        assert(vault.depositorOf(bytes32(id)) == address(0));
    }

    /// @notice Token A blocklists the depositor, or lifts it.
    function blocklist(
        bool on
    ) external {
        tokenA.setBlocked(address(this), on);
    }

    // ─── Internal ───

    /// @dev Fee growth rises for every NFT; each NFT's accrued ghost takes its owed increase (every NFT is the harness's,
    /// in custody or not, so every fee it accrues is the depositor's).
    function _accrue(
        uint256 g0,
        uint256 g1
    ) internal {
        uint256[2][4] memory o;
        for (uint256 i = 0; i < 4; ++i) {
            (o[i][0], o[i][1]) = manager.feesOwed(ids[i]);
        }
        manager.accrue(poolId, g0, g1);
        for (uint256 i = 0; i < 4; ++i) {
            (uint256 n0, uint256 n1) = manager.feesOwed(ids[i]);
            _book(accrued, ids[i], n0 - o[i][0], n1 - o[i][1]);
        }
    }

    function _book(
        mapping(uint256 => uint256[2]) storage ledger,
        uint256 id,
        uint256 a0,
        uint256 a1
    ) internal {
        ledger[id][0] += a0;
        ledger[id][1] += a1;
    }

    /// @dev Token A and B of the depositor (this harness), then of the recipient.
    function _balances() internal view returns (uint256[4] memory b) {
        b = [
            tokenA.balanceOf(address(this)),
            tokenB.balanceOf(address(this)),
            tokenA.balanceOf(RECIPIENT),
            tokenB.balanceOf(RECIPIENT)
        ];
    }
}

/// @notice Stands in for the MarketRegistry, the only caller of `bindMarket`: binds market 1 on `[-50, 50]`.
contract V4Registrar {
    function bind(
        UniswapV4Integration vault,
        bytes32 poolId,
        bytes calldata data
    ) external {
        vault.bindMarket(1, address(0), poolId, PositionShape(ShapeKind.TickRange, -50, 50), data);
    }
}
