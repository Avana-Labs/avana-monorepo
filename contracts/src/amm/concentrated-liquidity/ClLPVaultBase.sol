// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ILPVault} from "../../custody/lp-vault/ILPVault.sol";
import {ILock} from "../../lock/lock/ILock.sol";
import {LPPriceMath} from "../../oracle/LPPriceMath.sol";
import {IClIntegration} from "../IClIntegration.sol";
import {ClMarketConfig} from "../types/AmmTypes.sol";
import {ClPriceMath} from "./ClPriceMath.sol";
import {IClPositionManager} from "./IClPositionManager.sol";

/// @title ClLPVaultBase
/// @notice Shared state, caller and Lock checks and position checks of every concentrated-liquidity LPVault.
/// @dev Immutable: no proxy, owner or pause. Reads no token balance of its own.
abstract contract ClLPVaultBase is IClIntegration {
    struct Market {
        ClMarketConfig cfg;
        uint8 decimals0;
        uint8 decimals1;
        // Unit exponent k of the market's pool, fixed at the pool's first binding.
        uint8 unitExp;
        // The pool address as a word, or the `PoolId`; zero means unbound.
        bytes32 poolRef;
    }

    uint256 internal constant TOKEN_COUNT = 2;
    /// @dev Largest token decimals a market accepts; keeps price math far below 2^256.
    uint8 internal constant MAX_TOKEN_DECIMALS = 18;

    uint32 private immutable _INTEGRATION_ID;
    address internal immutable _COLLATERALIZATION;
    address internal immutable _MARKET_REGISTRY;
    address internal immutable _LOCK;
    address internal immutable _TIMELOCK;

    /// @dev Write-once market table (`bindMarket`); `poolRef == 0` means unbound.
    mapping(uint256 marketId => Market market) internal _markets;
    /// @dev Depositor of record of a position in custody for an open record; address(0) otherwise.
    mapping(bytes32 positionKey => address depositor) internal _depositorOf;
    /// @dev Market a custodied position was received for; 0 otherwise.
    mapping(bytes32 positionKey => uint256 marketId) internal _marketOfPosition;
    /// @dev Unit exponent of a pool plus 1 (0 = no market of the pool yet); shared by every market of the pool.
    // Used by `ClLPVaultMarkets._storeMarket`; the lint reads this abstract base alone.
    // forge-lint: disable-next-line(unused-state-variables)
    mapping(bytes32 poolRef => uint8 unitExpPlusOne) internal _poolUnitExp;

    /// @notice Fixes the integration identifier and the four Avana bindings.
    /// @dev Reverts `InvalidDeployment` for a zero identifier, a zero address or two equal bindings.
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

    /// @inheritdoc ILPVault
    function INTEGRATION_ID() external view override returns (uint32) {
        return _INTEGRATION_ID;
    }

    /// @inheritdoc ILPVault
    function COLLATERALIZATION() external view override returns (address) {
        return _COLLATERALIZATION;
    }

    /// @inheritdoc ILPVault
    function MARKET_REGISTRY() external view override returns (address) {
        return _MARKET_REGISTRY;
    }

    /// @inheritdoc ILPVault
    function LOCK() external view override returns (address) {
        return _LOCK;
    }

    /// @inheritdoc ILPVault
    function TIMELOCK() external view override returns (address) {
        return _TIMELOCK;
    }

    function _positionManager(
        bytes32 positionKey
    ) internal view virtual returns (address manager);

    function _tokenId(
        bytes32 positionKey
    ) internal pure virtual returns (uint256 tokenId);

    /// @dev Position key of an NFT of `manager`; `known` is false for a manager this LPVault does not accept.
    function _positionKeyOf(
        address manager,
        uint256 tokenId
    ) internal view virtual returns (bytes32 positionKey, bool known);

    /// @dev The position's pool reference (zero when there is none), ticks and live liquidity.
    function _readPosition(
        bytes32 positionKey
    ) internal view virtual returns (bytes32 poolRef, int24 tickLower, int24 tickUpper, uint128 liquidity);

    /// @dev `PoolLocked` while the market's pool, or its singleton, is inside its own reentrancy lock.
    function _requireReadSafe(
        Market storage market
    ) internal view virtual;

    /// @dev Removes exactly `liquidity`, principal to `recipient`, any fee paid out to `depositor`.
    function _removePrincipal(
        Market storage market,
        bytes32 positionKey,
        uint128 liquidity,
        uint256[] calldata minAmounts,
        address recipient,
        address depositor
    ) internal virtual returns (uint256[] memory amounts);

    function _collectAll(
        Market storage market,
        bytes32 positionKey,
        address depositor
    ) internal virtual returns (uint256 amount0, uint256 amount1);

    /// @dev Whether a staking or gauge contract holds the position.
    function _isEncumbered(
        Market storage market,
        bytes32 positionKey
    ) internal view virtual returns (bool encumbered);

    function _blockTime() internal view virtual returns (uint256 seconds_);

    /// @dev Collateralization only, while the Lock is held (only its two members can hold it).
    function _onlyCustodyCaller() internal view {
        if (msg.sender != _COLLATERALIZATION) revert NotCollateralization();
        if (ILock(_LOCK).holder() == address(0)) revert LockNotHeld();
    }

    /// @dev Custody views: refused while the Lock is held, except to Collateralization.
    function _custodyView() internal view {
        if (ILock(_LOCK).isLocked() && msg.sender != _COLLATERALIZATION) revert Locked();
    }

    function _market(
        uint256 marketId
    ) internal view returns (Market storage m) {
        m = _markets[marketId];
        if (m.poolRef == bytes32(0)) revert MarketBinding(marketId);
    }

    function _requireBound(
        uint256 marketId
    ) internal view {
        if (_markets[marketId].poolRef == bytes32(0)) revert MarketBinding(marketId);
    }

    function _custodied(
        bytes32 positionKey
    ) internal view returns (address depositor, Market storage m) {
        depositor = _depositorOf[positionKey];
        if (depositor == address(0)) revert NotInCustody();
        m = _markets[_marketOfPosition[positionKey]];
    }

    /// @dev Every pledge check that moves nothing: pool lock, owner, encumbrance, position manager and pool, range.
    function _checkPosition(
        Market storage m,
        address owner,
        bytes32 positionKey
    ) internal view {
        _requireReadSafe(m);
        if (owner == address(this) || _manager(positionKey).ownerOf(_tokenId(positionKey)) != owner) {
            revert NotTokenOwner();
        }
        if (_isEncumbered(m, positionKey)) revert PositionEncumbered();
        (bytes32 poolRef, int24 tickLower, int24 tickUpper,) = _readPosition(positionKey);
        if (_positionManager(positionKey) != m.cfg.positionManager || poolRef == bytes32(0) || poolRef != m.poolRef) {
            revert PoolMismatch();
        }
        if (tickLower != m.cfg.tickLower || tickUpper != m.cfg.tickUpper) revert RangeMismatch(tickLower, tickUpper);
    }

    /// @dev `[p0, p1]` from an oracle price vector; `InvalidPrices` for 0 or above `MAX_ROUTE_ANSWER`.
    function _prices(
        uint256[] calldata prices
    ) internal pure returns (uint256 p0, uint256 p1) {
        if (prices.length != TOKEN_COUNT) revert LengthMismatch(TOKEN_COUNT, prices.length);
        (p0, p1) = (prices[0], prices[1]);
        if (!_priceOk(p0) || !_priceOk(p1)) revert InvalidPrices();
    }

    /// @dev Floored amounts `liquidity` holds on the range at `sqrtOracleX96` clamped to it.
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

    /// @dev Vault-token units of `liquidity`, floored; the remainder stays with the NFT uncredited.
    function _toUnits(
        Market storage m,
        uint256 liquidity
    ) internal view returns (uint256) {
        return liquidity / 10 ** m.unitExp;
    }

    function _toLiquidity(
        Market storage m,
        uint256 units
    ) internal view returns (uint256) {
        return units * 10 ** m.unitExp;
    }

    function _manager(
        bytes32 positionKey
    ) internal view returns (IClPositionManager) {
        return IClPositionManager(_positionManager(positionKey));
    }

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
