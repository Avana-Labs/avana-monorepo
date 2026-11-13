// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {INonfungiblePositionManager} from "../../interfaces/external/uniswap/INonfungiblePositionManager.sol";
import {IUniswapV3Factory} from "../../interfaces/external/uniswap/IUniswapV3Factory.sol";
import {IUniswapV3Pool} from "../../interfaces/external/uniswap/IUniswapV3Pool.sol";
import {IAmmIntegration} from "../IAmmIntegration.sol";
import {ClLPVaultBase} from "../concentrated-liquidity/ClLPVaultBase.sol";
import {ClLPVaultCustody} from "../concentrated-liquidity/ClLPVaultCustody.sol";
import {ClLPVaultMarkets} from "../concentrated-liquidity/ClLPVaultMarkets.sol";
import {ClMarketConfig} from "../types/ClMarketConfig.sol";
import {IUniswapV3Integration} from "./IUniswapV3Integration.sol";

/// @title UniswapV3Integration
/// @notice The Uniswap v3 LPVault: immutable custodian of canonical NonfungiblePositionManager positions in
/// exact-range markets, `AMM_PROTOCOL() = keccak256("UNISWAP_V3")`, `positionKey = bytes32(tokenId)`, units are the
/// position's liquidity.
/// @dev The AMM-neutral custody, binding and pricing code is the shared concentrated-liquidity base
/// (`src/amm/concentrated-liquidity/`); this contract supplies what names Uniswap v3: the NFPM and factory immutables,
/// the 12-field `positions` and 7-field `slot0` layouts, the pool derivation `FACTORY.getPool(token0, token1, fee)`,
/// and the listing check of a pool against the factory, its CREATE2 address and the standard fee tiers.
/// @custom:spec REQ-AMM-V3-001, REQ-AMM-V3-002, REQ-AMM-V3-003, REQ-AMM-V3-004, REQ-AMM-V3-005, REQ-AMM-V3-006, REQ-AMM-V3-007, REQ-AMM-V3-012, REQ-VAULT-155, REQ-VAULT-174, REQ-AMM-CORE-002, Q-226, Q-291, Q-305, Q-371
contract UniswapV3Integration is ClLPVaultCustody, ClLPVaultMarkets, IUniswapV3Integration {
    /// @notice `keccak256("UNISWAP_V3")`.
    bytes32 public constant UNISWAP_V3 = keccak256("UNISWAP_V3");
    /// @notice Init code hash of the canonical Uniswap v3 pool, from which `FACTORY` derives every pool address.
    bytes32 public constant POOL_INIT_CODE_HASH = 0xe34f199b19b2b4f47f68442619d555527d244f78a3297ea89325f843f87b8b54;
    /// @notice Largest block interval accepted, seconds: Ethereum's.
    uint256 public constant MAX_BLOCK_TIME = 12;
    address private immutable _NFPM;
    address private immutable _FACTORY;
    /// @dev The chain's minimum block interval, seconds (`SPEC-ORC-022`, `REQ-AMM-V3-012`).
    uint256 private immutable _BLOCK_TIME;

    /// @notice Fixes the integration identifier, the Avana bindings and the canonical NFPM and factory.
    /// @dev Reverts `InvalidDeployment` for a zero NFPM or factory, either equal to an Avana binding, an NFPM whose
    /// `factory()` is not `factory` (`REQ-AMM-V3-001`), or a block time of 0, above 12 s, or other than the known
    /// interval of the chain Avana deploys on (12 s on Ethereum and Sepolia, 2 s on Base, Base Sepolia and OP
    /// Mainnet; `REQ-AMM-V3-012`).
    /// @param integrationId Identifier registered for this LPVault in the VaultTokenFactory.
    /// @param collateralization The chain's Collateralization.
    /// @param marketRegistry The chain's MarketRegistry proxy.
    /// @param lock The chain's Lock.
    /// @param timelock The chain's AvanaTimelock.
    /// @param nfpm Canonical Uniswap v3 NonfungiblePositionManager.
    /// @param factory Canonical Uniswap v3 factory.
    /// @param blockTime The chain's minimum block interval, seconds.
    /// @custom:spec REQ-AMM-V3-001, REQ-AMM-V3-012, REQ-VAULT-155
    constructor(
        uint32 integrationId,
        address collateralization,
        address marketRegistry,
        address lock,
        address timelock,
        address nfpm,
        address factory,
        uint256 blockTime
    ) ClLPVaultBase(integrationId, collateralization, marketRegistry, lock, timelock) {
        uint256 known = _knownBlockTime(block.chainid);
        if (blockTime == 0 || blockTime > MAX_BLOCK_TIME || (known != 0 && blockTime != known)) {
            revert InvalidDeployment();
        }
        if (nfpm == address(0) || factory == address(0) || nfpm == factory) revert InvalidDeployment();
        if (
            nfpm == collateralization || nfpm == marketRegistry || nfpm == lock || nfpm == timelock
                || factory == collateralization || factory == marketRegistry || factory == lock || factory == timelock
        ) revert InvalidDeployment();
        if (nfpm.code.length == 0 || INonfungiblePositionManager(nfpm).factory() != factory) {
            revert InvalidDeployment();
        }
        _NFPM = nfpm;
        _FACTORY = factory;
        _BLOCK_TIME = blockTime;
    }

    /// @inheritdoc IUniswapV3Integration
    /// @custom:spec REQ-AMM-V3-012, SPEC-ORC-022
    function BLOCK_TIME() external view override returns (uint256) {
        return _BLOCK_TIME;
    }

    /// @inheritdoc IUniswapV3Integration
    /// @custom:spec REQ-AMM-V3-001, REQ-VAULT-155
    function NFPM() external view override returns (address) {
        return _NFPM;
    }

    /// @inheritdoc IUniswapV3Integration
    /// @custom:spec REQ-AMM-V3-002, REQ-VAULT-155
    function FACTORY() external view override returns (address) {
        return _FACTORY;
    }

    /// @inheritdoc IAmmIntegration
    /// @custom:spec REQ-AMM-CORE-009
    function AMM_PROTOCOL() external pure override returns (bytes32) {
        return UNISWAP_V3;
    }

    // ─── Hooks of the concentrated-liquidity base ───

    /// @dev Every Uniswap v3 position belongs to the one canonical NFPM.
    function _positionManager(
        bytes32
    ) internal view override returns (address) {
        return _NFPM;
    }

    /// @dev `positionKey = bytes32(tokenId)` (`SPEC-AMM-CORE-002`).
    function _tokenId(
        bytes32 positionKey
    ) internal pure override returns (uint256) {
        return uint256(positionKey);
    }

    /// @dev Only the canonical NFPM's NFTs are accepted.
    function _positionKeyOf(
        address manager,
        uint256 tokenId
    ) internal view override returns (bytes32, bool) {
        return (bytes32(tokenId), manager == _NFPM);
    }

    /// @dev The 12-field `positions` layout; the pool is `FACTORY.getPool(token0, token1, fee)` of the position's own
    /// fields, never a caller-supplied pool (`REQ-VAULT-008`).
    /// @custom:spec REQ-VAULT-008, REQ-VAULT-162, REQ-AMM-V3-003
    function _readPosition(
        bytes32 positionKey
    ) internal view override returns (address pool, int24 tickLower, int24 tickUpper, uint128 liquidity) {
        address token0;
        address token1;
        uint24 fee;
        // The 12-field layout of REQ-AMM-V3-003; only the pair, fee, ticks and liquidity are used.
        // forge-lint: disable-start(unused-return)
        (,, token0, token1, fee, tickLower, tickUpper, liquidity,,,,) =
            INonfungiblePositionManager(_NFPM).positions(uint256(positionKey));
        // forge-lint: disable-end(unused-return)
        pool = IUniswapV3Factory(_FACTORY).getPool(token0, token1, fee);
    }

    /// @dev The 7-field Uniswap v3 `slot0` layout (`REQ-AMM-V3-003`).
    function _slot0(
        address pool
    ) internal view override returns (int24 tick, uint16 observationCardinality, bool unlocked) {
        // The 7-field layout of REQ-AMM-V3-003; only the tick, the cardinality and the lock flag are used.
        // forge-lint: disable-next-line(unused-return)
        (, tick,, observationCardinality,,, unlocked) = IUniswapV3Pool(pool).slot0();
    }

    /// @dev `REQ-AMM-V3-002`: `pool.factory() == FACTORY`, `FACTORY.getPool(token0, token1, fee) == pool`, `pool` is the
    /// CREATE2 address of `(token0, token1, fee)` under the pool init code hash, and the tick spacing is the standard
    /// spacing of the fee tier. `integrationData = abi.encode(uint256 price0, uint256 price1)`, the listing valuation
    /// prices (8 decimals).
    /// @custom:spec REQ-AMM-V3-002, REQ-AMM-V3-008, REQ-AMM-CORE-017
    function _validatePool(
        address pool,
        bytes calldata integrationData
    ) internal view override returns (ClMarketConfig memory cfg, uint256 price0, uint256 price1) {
        if (integrationData.length != 64) revert InvalidPool();
        (price0, price1) = abi.decode(integrationData, (uint256, uint256));
        IUniswapV3Pool p = IUniswapV3Pool(pool);
        cfg.pool = pool;
        cfg.positionManager = _NFPM;
        cfg.factory = _FACTORY;
        cfg.token0 = p.token0();
        cfg.token1 = p.token1();
        cfg.fee = p.fee();
        cfg.tickSpacing = p.tickSpacing();
        if (
            p.factory() != _FACTORY || cfg.token0 >= cfg.token1
                || IUniswapV3Factory(_FACTORY).getPool(cfg.token0, cfg.token1, cfg.fee) != pool
                || _poolAddress(cfg.token0, cfg.token1, cfg.fee) != pool || cfg.tickSpacing != _standardSpacing(cfg.fee)
        ) revert InvalidPool();
    }

    /// @dev No Uniswap v3 position is encumbered from the LPVault's view: a staked NFT is owned by its staking
    /// contract and fails the owner check.
    function _isEncumbered(
        Market storage,
        bytes32
    ) internal pure override returns (bool) {
        return false;
    }

    /// @dev The constructor's block interval (`REQ-AMM-V3-012`).
    function _blockTime() internal view override returns (uint256) {
        return _BLOCK_TIME;
    }

    /// @dev The block interval of a chain Avana deploys on: 12 s for Ethereum (1) and Sepolia (11155111), 2 s for Base
    /// (8453), Base Sepolia (84532) and OP Mainnet (10); 0 for any other chain, where the constructor's value stands.
    function _knownBlockTime(
        uint256 chainId
    ) private pure returns (uint256) {
        if (chainId == 1 || chainId == 11_155_111) return 12;
        if (chainId == 8453 || chainId == 84_532 || chainId == 10) return 2;
        return 0;
    }

    /// @dev The CREATE2 address `FACTORY` deploys the pool of `(token0, token1, fee)` at, Uniswap v3-periphery
    /// `PoolAddress.computeAddress`.
    function _poolAddress(
        address token0,
        address token1,
        uint24 fee
    ) internal view virtual returns (address) {
        bytes32 h = keccak256(
            abi.encodePacked(hex"ff", _FACTORY, keccak256(abi.encode(token0, token1, fee)), _poolInitCodeHash())
        );
        return address(uint160(uint256(h)));
    }

    /// @dev The canonical pool init code hash; a test harness on a mock factory overrides it.
    function _poolInitCodeHash() internal view virtual returns (bytes32) {
        return POOL_INIT_CODE_HASH;
    }

    /// @dev Tick spacing of the standard fee tiers: 100 → 1, 500 → 10, 3,000 → 60, 10,000 → 200; 0 for any other.
    function _standardSpacing(
        uint24 fee
    ) private pure returns (int24) {
        if (fee == 100) return 1;
        if (fee == 500) return 10;
        if (fee == 3000) return 60;
        if (fee == 10_000) return 200;
        return 0;
    }
}

