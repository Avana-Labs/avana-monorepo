// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ILPVault} from "../../custody/lp-vault/ILPVault.sol";
import {ILock} from "../../lock/lock/ILock.sol";
import {LPPriceMath} from "../../oracle/lp-oracle/LPPriceMath.sol";
import {IAmmIntegration} from "../IAmmIntegration.sol";
import {IClIntegration} from "../IClIntegration.sol";
import {ClMarketConfig} from "../types/ClMarketConfig.sol";
import {ClPriceMath} from "./ClPriceMath.sol";
import {IClPositionManager} from "./IClPositionManager.sol";

/// @title ClLPVaultBase
/// @notice State, immutables, caller and Lock checks, and the position checks shared by every concentrated-liquidity
/// LPVault (Uniswap v3 on Ethereum, Aerodrome Slipstream on Base). AMM-protocol neutral: everything that names a
/// position manager's `positions` layout, a pool's `slot0` layout, a factory or a position-key encoding is an abstract
/// hook the integration implements.
/// @dev Immutable contract with plain storage: no proxy, owner, pause, `delegatecall`, `selfdestruct`, sweep or
/// rescue. Storage is the write-once market table and the two custody maps of 2.2; the LPVault keeps no record,
/// total, counter, timer or queue, and reads no balance of its own (`REQ-VAULT-085`). Every market has exactly two
/// tokens, in pool order.
/// @custom:spec REQ-VAULT-001, REQ-VAULT-002, REQ-VAULT-005, REQ-VAULT-150, REQ-VAULT-151, REQ-VAULT-155, REQ-VAULT-085, REQ-VAULT-152, REQ-AMM-CORE-001, INV-052, INV-091, Q-224, Q-226, Q-240, Q-291, Q-371
abstract contract ClLPVaultBase is IClIntegration {
    /// @notice A bound market: the configuration of `clMarket`, the token decimals the composition uses and the unit
    /// exponent `k`: one vault-token unit is `10^k` units of the position's liquidity (`SPEC-UNIT-002`).
    struct Market {
        // Write-once configuration.
        ClMarketConfig cfg;
        // Decimals of token0, read at listing.
        uint8 decimals0;
        // Decimals of token1, read at listing.
        uint8 decimals1;
        // Unit exponent k of the market's pool, fixed at the pool's first binding.
        uint8 unitExp;
    }

    /// @dev Pool tokens of every concentrated-liquidity market.
    uint256 internal constant TOKEN_COUNT = 2;
    /// @dev Largest token decimals a market accepts; keeps `p * 10^d` of `SPEC-ORC-009` far below 2^256.
    uint8 internal constant MAX_TOKEN_DECIMALS = 18;

    uint32 private immutable _INTEGRATION_ID;
    address internal immutable _COLLATERALIZATION;
    address internal immutable _MARKET_REGISTRY;
    address internal immutable _LOCK;
    address internal immutable _TIMELOCK;

    /// @dev Write-once market table (`bindMarket`); `cfg.pool == address(0)` means unbound.
    mapping(uint256 marketId => Market market) internal _markets;
    /// @dev Depositor of record of a position in custody for an open record; address(0) otherwise.
    mapping(bytes32 positionKey => address depositor) internal _depositorOf;
    /// @dev Market a custodied position was received for; 0 otherwise.
    mapping(bytes32 positionKey => uint256 marketId) internal _marketOfPosition;
    /// @dev Unit exponent of a pool plus 1, written by the pool's first `bindMarket` (0 = no market of the pool yet).
    /// Every market of one pool shares it, so Collateralization's per-pool unit counter and the pool's depth are in
    /// one unit (`SPEC-CAP-005`).
    // Written and read by `ClLPVaultMarkets.bindMarket`; the lint reads this abstract base alone.
    // forge-lint: disable-next-line(unused-state-variables)
    mapping(address pool => uint8 unitExpPlusOne) internal _poolUnitExp;

    /// @notice Fixes the integration identifier and the four Avana bindings; none of them needs code at deployment.
    /// @dev Reverts `InvalidDeployment` for a zero identifier, a zero address or two equal Avana bindings, so no
    /// misconfigured LPVault can be deployed (fail closed). The AMM protocol bindings are checked by the integration.
    /// @param integrationId Identifier registered for this LPVault in the VaultTokenFactory.
    /// @param collateralization The chain's Collateralization.
    /// @param marketRegistry The chain's MarketRegistry proxy.
    /// @param lock The chain's Lock.
    /// @param timelock The chain's AvanaTimelock.
    /// @custom:spec REQ-VAULT-155, REQ-VAULT-002
    constructor(
        uint32 integrationId,
        address collateralization,
        address marketRegistry,
        address lock,
        address timelock
    ) {
        if (
            integrationId == 0 || collateralization == address(0) || marketRegistry == address(0) || lock == address(0)
                || timelock == address(0)
        ) revert InvalidDeployment();
        if (
            collateralization == marketRegistry || collateralization == lock || collateralization == timelock
                || marketRegistry == lock || marketRegistry == timelock || lock == timelock
        ) revert InvalidDeployment();
        _INTEGRATION_ID = integrationId;
        _COLLATERALIZATION = collateralization;
        _MARKET_REGISTRY = marketRegistry;
        _LOCK = lock;
        _TIMELOCK = timelock;
    }

    // ─── Immutable getters ───

    /// @inheritdoc IAmmIntegration
    /// @custom:spec REQ-AMM-CORE-001, REQ-VAULT-155
    function INTEGRATION_ID() external view override returns (uint32) {
        return _INTEGRATION_ID;
    }

    /// @inheritdoc ILPVault
    /// @custom:spec REQ-VAULT-155, REQ-VAULT-002
    function COLLATERALIZATION() external view override returns (address) {
        return _COLLATERALIZATION;
    }

    /// @inheritdoc ILPVault
    /// @custom:spec REQ-VAULT-155, REQ-AMM-CORE-004
    function MARKET_REGISTRY() external view override returns (address) {
        return _MARKET_REGISTRY;
    }

    /// @inheritdoc ILPVault
    /// @custom:spec REQ-VAULT-155, REQ-VAULT-150
    function LOCK() external view override returns (address) {
        return _LOCK;
    }

    /// @inheritdoc ILPVault
    /// @custom:spec REQ-VAULT-155, REQ-VAULT-080
    function TIMELOCK() external view override returns (address) {
        return _TIMELOCK;
    }

    // ─── Integration hooks ───

    /// @dev Position manager of a position key (Uniswap v3: the NFPM; Slipstream: the key's generation).
    function _positionManager(
        bytes32 positionKey
    ) internal view virtual returns (address manager);

    /// @dev NFT token ID of a position key.
    function _tokenId(
        bytes32 positionKey
    ) internal pure virtual returns (uint256 tokenId);

    /// @dev Position key of an NFT of `manager`; `known` is false for a manager this LPVault does not accept.
    function _positionKeyOf(
        address manager,
        uint256 tokenId
    ) internal view virtual returns (bytes32 positionKey, bool known);

    /// @dev The position's pool, derived through the pinned factory from the position's own fields (address(0) when
    /// the factory has none), its ticks and its live liquidity, read from the position manager.
    function _readPosition(
        bytes32 positionKey
    ) internal view virtual returns (address pool, int24 tickLower, int24 tickUpper, uint128 liquidity);

    /// @dev The pool's current tick, observation cardinality and reentrancy flag, decoded with the AMM protocol's own
    /// `slot0` layout.
    function _slot0(
        address pool
    ) internal view virtual returns (int24 tick, uint16 observationCardinality, bool unlocked);

    /// @dev Validates a pool against the pinned factory at listing and returns its configuration (pool, position
    /// manager, factory, tokens, fee, tick spacing) and the listing valuation prices decoded from `integrationData`;
    /// reverts `InvalidPool` for anything else.
    function _validatePool(
        address pool,
        bytes calldata integrationData
    ) internal view virtual returns (ClMarketConfig memory cfg, uint256 price0, uint256 price1);

    /// @dev Whether a staking or gauge contract holds the position (`PositionEncumbered`); false for every Uniswap v3
    /// position, since a staked v3 NFT is owned by its staking contract and already fails the owner check.
    function _isEncumbered(
        Market storage market,
        bytes32 positionKey
    ) internal view virtual returns (bool encumbered);

    /// @dev The chain's minimum block interval in seconds (`SPEC-ORC-022`).
    function _blockTime() internal view virtual returns (uint256 seconds_);

    // ─── Checks ───

    /// @dev Custody and unwind functions: Collateralization only, inside a call tree opened by a Lock member. The Lock
    /// admits only its two members, the AaveAdapter and LPVaultSwap, so a non-zero holder is one of them. Fee collection
    /// narrows the holder to the AaveAdapter (`REQ-VAULT-064`).
    /// @custom:spec REQ-VAULT-150, REQ-VAULT-156, REQ-VAULT-157, INV-091
    function _onlyCustodyCaller() internal view {
        if (msg.sender != _COLLATERALIZATION) revert NotCollateralization();
        if (ILock(_LOCK).holder() == address(0)) revert LockNotHeld();
    }

    /// @dev Custody views: refused while the Lock is held, except to Collateralization.
    /// @custom:spec REQ-VAULT-151, REQ-VAULT-160
    function _custodyView() internal view {
        if (ILock(_LOCK).isLocked() && msg.sender != _COLLATERALIZATION) revert Locked();
    }

    /// @dev The bound market, or `MarketBinding(marketId)`.
    function _market(
        uint256 marketId
    ) internal view returns (Market storage m) {
        m = _markets[marketId];
        if (m.cfg.pool == address(0)) revert MarketBinding(marketId);
    }

    /// @dev `MarketBinding(marketId)` unless the market is bound.
    function _requireBound(
        uint256 marketId
    ) internal view {
        if (_markets[marketId].cfg.pool == address(0)) revert MarketBinding(marketId);
    }

    /// @dev The depositor of record and market of a custodied position, or `NotInCustody`.
    function _custodied(
        bytes32 positionKey
    ) internal view returns (address depositor, Market storage m) {
        depositor = _depositorOf[positionKey];
        if (depositor == address(0)) revert NotInCustody();
        m = _markets[_marketOfPosition[positionKey]];
    }

    /// @dev `PoolLocked` while the pool is inside its own reentrancy lock.
    /// @custom:spec REQ-AMM-V3-003, REQ-AMM-CORE-018, REQ-VAULT-010
    function _requireUnlocked(
        address pool
    ) internal view {
        (,, bool unlocked) = _slot0(pool);
        if (!unlocked) revert PoolLocked();
    }

    /// @dev Every check of a pledge that moves nothing, in the order of `REQ-AMM-CORE-005`: pool lock, owner, encumbrance,
    /// the key's position manager equal to the market's pinned one and the pool derived through it, exact range.
    /// @custom:spec REQ-AMM-CORE-005, REQ-AMM-CORE-006, REQ-VAULT-147, REQ-VAULT-008, REQ-VAULT-009, REQ-VAULT-101, REQ-AMM-SLIP-001, REQ-AMM-SLIP-007
    function _checkPosition(
        Market storage m,
        address owner,
        bytes32 positionKey
    ) internal view {
        _requireUnlocked(m.cfg.pool);
        if (owner == address(this) || _manager(positionKey).ownerOf(_tokenId(positionKey)) != owner) {
            revert NotTokenOwner();
        }
        if (_isEncumbered(m, positionKey)) revert PositionEncumbered();
        (address pool, int24 tickLower, int24 tickUpper,) = _readPosition(positionKey);
        if (_positionManager(positionKey) != m.cfg.positionManager || pool == address(0) || pool != m.cfg.pool) {
            revert PoolMismatch();
        }
        if (tickLower != m.cfg.tickLower || tickUpper != m.cfg.tickUpper) revert RangeMismatch(tickLower, tickUpper);
    }

    /// @dev `[p0, p1]` from an oracle price vector: `LengthMismatch` for a length other than 2, `InvalidPrices` for a
    /// price of 0 or above `MAX_ROUTE_ANSWER` ($10,000,000,000), the bound every LPOracle price respects.
    /// @custom:spec REQ-AMM-CORE-006, REQ-AMM-CORE-002
    function _prices(
        uint256[] calldata prices
    ) internal pure returns (uint256 p0, uint256 p1) {
        if (prices.length != TOKEN_COUNT) revert LengthMismatch(TOKEN_COUNT, prices.length);
        (p0, p1) = (prices[0], prices[1]);
        if (!_priceOk(p0) || !_priceOk(p1)) revert InvalidPrices();
    }

    /// @dev Raw amounts (`SPEC-ORC-006`, floored, no reduction) `liquidity` holds on `[tickLower, tickUpper]` at
    /// `sqrtOracleX96` clamped to the range.
    /// @custom:spec SPEC-ORC-006, SPEC-AMM-V3-001
    function _rawAmounts(
        int24 tickLower,
        int24 tickUpper,
        uint160 sqrtOracleX96,
        uint256 liquidity
    ) internal pure returns (uint256 amount0, uint256 amount1) {
        uint160 sa = ClPriceMath.sqrtRatioAtTick(tickLower);
        uint160 sb = ClPriceMath.sqrtRatioAtTick(tickUpper);
        return ClPriceMath.amountsForLiquidity(ClPriceMath.clamp(sqrtOracleX96, sa, sb), sa, sb, liquidity);
    }

    /// @dev Vault-token units of `liquidity` in market `m`: `⌊liquidity / 10^k⌋` (`SPEC-UNIT-002`); the remainder below
    /// one unit stays with the NFT and is never credited.
    /// @custom:spec SPEC-UNIT-002, SPEC-ORC-005
    function _toUnits(
        Market storage m,
        uint256 liquidity
    ) internal view returns (uint256) {
        return liquidity / 10 ** m.unitExp;
    }

    /// @dev Liquidity of `units` vault-token units in market `m`: `units * 10^k`, exact (`SPEC-UNIT-002`).
    /// @custom:spec SPEC-UNIT-002, SPEC-ORC-005
    function _toLiquidity(
        Market storage m,
        uint256 units
    ) internal view returns (uint256) {
        return units * 10 ** m.unitExp;
    }

    /// @dev The position manager of a key, typed for the custody calls.
    function _manager(
        bytes32 positionKey
    ) internal view returns (IClPositionManager) {
        return IClPositionManager(_positionManager(positionKey));
    }

    /// @dev A two-entry array in pool order.
    function _pair(
        uint256 a0,
        uint256 a1
    ) internal pure returns (uint256[] memory out) {
        out = new uint256[](TOKEN_COUNT);
        (out[0], out[1]) = (a0, a1);
    }

    function _priceOk(
        uint256 p
    ) private pure returns (bool) {
        return p != 0 && p <= LPPriceMath.MAX_ROUTE_ANSWER;
    }
}
