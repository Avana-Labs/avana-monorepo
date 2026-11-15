// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IUniswapV3Factory} from "../../interfaces/external/uniswap/IUniswapV3Factory.sol";
import {IUniswapV3Pool} from "../../interfaces/external/uniswap/IUniswapV3Pool.sol";
import {
    IUniswapV4PoolManager,
    UniswapV4PoolKey
} from "../../interfaces/external/uniswap-v4/IUniswapV4PoolManager.sol";
import {IUniswapV4PositionManager} from "../../interfaces/external/uniswap-v4/IUniswapV4PositionManager.sol";
import {LPPriceMath} from "../../oracle/lp-oracle/LPPriceMath.sol";
import {PositionShape} from "../../types/PositionShape.sol";
import {ShapeKind} from "../../types/ShapeKind.sol";
import {IAmmIntegration} from "../IAmmIntegration.sol";
import {IAmmIntegrationHooks} from "../IAmmIntegrationHooks.sol";
import {ClLPVaultBase} from "../concentrated-liquidity/ClLPVaultBase.sol";
import {ClLPVaultCustody} from "../concentrated-liquidity/ClLPVaultCustody.sol";
import {ClLPVaultMarkets} from "../concentrated-liquidity/ClLPVaultMarkets.sol";
import {ClPriceMath} from "../concentrated-liquidity/ClPriceMath.sol";
import {ClMarketConfig} from "../types/ClMarketConfig.sol";
import {FeeMode} from "../types/FeeMode.sol";
import {IntegrationCapabilities} from "../types/IntegrationCapabilities.sol";
import {PoolKeying} from "../types/PoolKeying.sol";
import {PricingMode} from "../types/PricingMode.sol";
import {RiskMetadata} from "../types/RiskMetadata.sol";
import {RiskStatus} from "../types/RiskStatus.sol";
import {IUniswapV4Integration} from "./IUniswapV4Integration.sol";
import {UniswapV4State} from "./UniswapV4State.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

/// @title UniswapV4Integration
/// @notice The Uniswap v4 LPVault: immutable custodian of PositionManager positions of hookless v4 pools in exact-range
/// markets keyed by `PoolId`, `AMM_PROTOCOL() = keccak256("UNISWAP_V4")`, `positionKey = bytes32(tokenId)`, units are
/// the position's liquidity read from the PoolManager.
/// @dev The AMM-neutral custody and pricing code is the shared concentrated-liquidity base
/// (`src/amm/concentrated-liquidity/`); this contract supplies what names Uniswap v4: PoolKey binding with the hook
/// mask, `getPoolAndPositionInfo` and PoolManager `extsload` reads, the `exttload` read guard, removal and fee
/// collection as one fixed `modifyLiquidities` batch each (fees to the depositor first, then the principal, native ETH
/// wrapped by the PositionManager), and the reference Uniswap v3 pool for the consistency read and the depth. The
/// LPVault never calls `subscribe`, `approve`, `setApprovalForAll`, `mint`, `increaseLiquidity` or `burn`, implements
/// no `unlockCallback` and never holds native ETH.
/// @custom:spec REQ-AMM-V4-001, REQ-AMM-V4-002, REQ-AMM-V4-003, REQ-AMM-V4-004, REQ-AMM-V4-005, REQ-AMM-V4-007, REQ-AMM-V4-008, REQ-AMM-V4-009, SPEC-AMM-V4-001, SPEC-AMM-V4-002, SPEC-AMM-V4-003, REQ-VAULT-155, REQ-AMM-CORE-002
// The removal events report what the batch removed; see `ClLPVaultCustody`.
// forge-lint: disable-start(reentrancy-events)
contract UniswapV4Integration is ClLPVaultCustody, ClLPVaultMarkets, IUniswapV4Integration {
    /// @notice `keccak256("UNISWAP_V4")`.
    bytes32 public constant UNISWAP_V4 = keccak256("UNISWAP_V4");
    /// @notice Largest block interval accepted, seconds: Ethereum's.
    uint256 public constant MAX_BLOCK_TIME = 12;
    /// @dev `BEFORE_REMOVE_LIQUIDITY | AFTER_REMOVE_LIQUIDITY | BEFORE_SWAP_RETURNS_DELTA | AFTER_SWAP_RETURNS_DELTA |
    /// AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA` (`REQ-AMM-V4-001`).
    uint160 internal constant _HOOK_MASK = (1 << 9) | (1 << 8) | (1 << 3) | (1 << 2) | (1 << 0);
    /// @dev Largest tick spacing a market accepts, as for Slipstream: the per-tick liquidity bound of every listed pool
    /// keeps a market's credited liquidity below 2^120.
    int24 internal constant MAX_TICK_SPACING = 6931;
    /// @dev Token supply bound at listing (`REQ-AMM-V4-009`).
    uint256 internal constant SUPPLY_BOUND = 1 << 127;
    /// @dev Bytes of `bindMarket`'s `integrationData`: `abi.encode(UniswapV4PoolKey key, address referencePool,
    /// uint256 price0, uint256 price1)`.
    uint256 internal constant INTEGRATION_DATA_LENGTH = 8 * 32;

    /// @dev PositionManager actions (v4-periphery 1.0.1 `Actions`) and constants (`ActionConstants`).
    uint8 internal constant DECREASE_LIQUIDITY = 0x01;
    uint8 internal constant TAKE = 0x0e;
    uint8 internal constant TAKE_PAIR = 0x11;
    uint8 internal constant SWEEP = 0x14;
    uint8 internal constant WRAP = 0x15;
    uint256 internal constant OPEN_DELTA = 0;
    uint256 internal constant CONTRACT_BALANCE = 1 << 255;
    address internal constant ADDRESS_THIS = address(2);

    /// @dev Pool key and reference pool of a `PoolId`, written by the pool's first `bindMarket`.
    mapping(bytes32 poolId => V4Market pool) internal _v4Pools;

    IUniswapV4PoolManager internal immutable _PM;
    IUniswapV4PositionManager internal immutable _POSM;
    address internal immutable _WETH;
    address internal immutable _REF_FACTORY;
    uint256 internal immutable _BLOCK_TIME;

    /// @notice Fixes the integration identifier, the Avana bindings, the PositionManager (and through it the PoolManager
    /// and the wrapped native token) and the reference Uniswap v3 factory.
    /// @dev Reverts `InvalidDeployment` for a zero or code-less PositionManager or factory, either equal to an Avana
    /// binding, a PositionManager whose PoolManager or WETH9 is zero, or a block time of 0, above 12 s, or other than
    /// the known interval of the chain (12 s on Ethereum and Sepolia, 2 s on Base, Base Sepolia and OP Mainnet, 1 s on
    /// Unichain).
    /// @param integrationId Identifier registered for this LPVault in the VaultTokenFactory.
    /// @param collateralization The chain's Collateralization.
    /// @param marketRegistry The chain's MarketRegistry proxy.
    /// @param lock The chain's Lock.
    /// @param timelock The chain's AvanaTimelock.
    /// @param positionManager Canonical Uniswap v4 PositionManager.
    /// @param referenceFactory Canonical Uniswap v3 factory of the chain.
    /// @param blockTime The chain's minimum block interval, seconds.
    /// @custom:spec REQ-VAULT-155, REQ-AMM-V4-007
    constructor(
        uint32 integrationId,
        address collateralization,
        address marketRegistry,
        address lock,
        address timelock,
        address positionManager,
        address referenceFactory,
        uint256 blockTime
    ) ClLPVaultBase(integrationId, collateralization, marketRegistry, lock, timelock) {
        uint256 known = _knownBlockTime(block.chainid);
        if (blockTime == 0 || blockTime > MAX_BLOCK_TIME || (known != 0 && blockTime != known)) {
            revert InvalidDeployment();
        }
        if (
            positionManager == address(0) || referenceFactory == address(0) || positionManager == referenceFactory
                || positionManager.code.length == 0 || referenceFactory.code.length == 0
        ) revert InvalidDeployment();
        if (
            positionManager == collateralization || positionManager == marketRegistry || positionManager == lock
                || positionManager == timelock || referenceFactory == collateralization
                || referenceFactory == marketRegistry || referenceFactory == lock || referenceFactory == timelock
        ) revert InvalidDeployment();
        address pm = IUniswapV4PositionManager(positionManager).poolManager();
        address weth = IUniswapV4PositionManager(positionManager).WETH9();
        if (pm == address(0) || weth == address(0) || pm.code.length == 0 || weth.code.length == 0) {
            revert InvalidDeployment();
        }
        _PM = IUniswapV4PoolManager(pm);
        _POSM = IUniswapV4PositionManager(positionManager);
        _WETH = weth;
        _REF_FACTORY = referenceFactory;
        _BLOCK_TIME = blockTime;
    }

    // ─── Immutable getters ───

    /// @inheritdoc IUniswapV4Integration
    function POOL_MANAGER() external view override returns (address) {
        return address(_PM);
    }

    /// @inheritdoc IUniswapV4Integration
    function POSITION_MANAGER() external view override returns (address) {
        return address(_POSM);
    }

    /// @inheritdoc IUniswapV4Integration
    function REFERENCE_FACTORY() external view override returns (address) {
        return _REF_FACTORY;
    }

    /// @inheritdoc IUniswapV4Integration
    function BLOCK_TIME() external view override returns (uint256) {
        return _BLOCK_TIME;
    }

    /// @inheritdoc IUniswapV4Integration
    function HOOK_MASK() external pure override returns (uint160) {
        return _HOOK_MASK;
    }

    /// @inheritdoc IAmmIntegration
    /// @custom:spec REQ-AMM-CORE-009
    function AMM_PROTOCOL() external pure override returns (bytes32) {
        return UNISWAP_V4;
    }

    // ─── Binding ───

    /// @inheritdoc IAmmIntegration
    /// @dev `pool` must be address(0) and `poolId` the hash of the PoolKey in `integrationData` (`abi.encode(key,
    /// referencePool, price0, price1)`, prices with 8 decimals). Refuses a hook outside the allowlist (`HookNotAllowed`),
    /// an uninitialized pool, a tick spacing outside `[1, 6931]`, an ETH/WETH pool, a token whose `totalSupply` is
    /// 2^127 or more (`REQ-AMM-V4-009`), a reference pool other than the factory's pool of the two tokens
    /// (`REQ-AMM-V4-007`), and later markets of the same pool naming another reference pool (`InvalidPool`).
    /// @custom:spec REQ-AMM-CORE-003, REQ-AMM-CORE-004, REQ-AMM-V4-001, REQ-AMM-V4-006, REQ-AMM-V4-007, REQ-AMM-V4-009, SPEC-BACK-001, SPEC-UNIT-001, SPEC-ORC-005
    function bindMarket(
        uint256 marketId,
        address pool,
        bytes32 poolId,
        PositionShape calldata shape,
        bytes calldata integrationData
    ) external override returns (address[] memory tokens, uint8 unitDecimals) {
        if (msg.sender != _MARKET_REGISTRY) revert NotMarketRegistry();
        if (marketId == 0 || _markets[marketId].poolRef != bytes32(0)) revert MarketBinding(marketId);
        if (pool != address(0) || poolId == bytes32(0) || integrationData.length != INTEGRATION_DATA_LENGTH) {
            revert InvalidPool();
        }
        if (shape.kind != ShapeKind.TickRange) revert InvalidShape();
        (UniswapV4PoolKey memory key, address ref, uint256 price0, uint256 price1) =
            abi.decode(integrationData, (UniswapV4PoolKey, address, uint256, uint256));
        if (keccak256(abi.encode(key)) != poolId) revert InvalidPool();
        if (!_hookAllowed(key.hooks)) revert HookNotAllowed(key.hooks);
        ClMarketConfig memory cfg = _poolConfig(key, poolId, ref);
        if (!ClPriceMath.isUsableRange(shape.tickLower, shape.tickUpper, cfg.tickSpacing)) revert InvalidShape();
        cfg.tickLower = shape.tickLower;
        cfg.tickUpper = shape.tickUpper;
        cfg.maxLiquidityPerTick = ClPriceMath.maxLiquidityPerTick(cfg.tickSpacing);
        unitDecimals = _storeMarket(marketId, poolId, cfg, price0, price1);
        V4Market storage stored = _v4Pools[poolId];
        if (stored.referencePool == address(0)) {
            (stored.key, stored.referencePool) = (key, ref);
        } else if (stored.referencePool != ref) {
            revert InvalidPool();
        }
        tokens = new address[](TOKEN_COUNT);
        (tokens[0], tokens[1]) = (cfg.token0, cfg.token1);
        // Every call before the event is a view of the PoolManager, the factory, the reference pool or a token.
        // forge-lint: disable-next-line(reentrancy-events)
        emit MarketBound(marketId, address(0), poolId, shape.tickLower, shape.tickUpper);
    }

    /// @inheritdoc IAmmIntegration
    /// @custom:spec REQ-AMM-CORE-004
    function marketOf(
        uint256 marketId
    )
        external
        view
        override
        returns (address pool, bytes32 poolId, PositionShape memory shape, address[] memory tokens)
    {
        Market storage m = _market(marketId);
        tokens = new address[](TOKEN_COUNT);
        (tokens[0], tokens[1]) = (m.cfg.token0, m.cfg.token1);
        shape = PositionShape({kind: ShapeKind.TickRange, tickLower: m.cfg.tickLower, tickUpper: m.cfg.tickUpper});
        return (address(0), m.poolRef, shape, tokens);
    }

    /// @inheritdoc IUniswapV4Integration
    function v4Market(
        uint256 marketId
    ) external view override returns (V4Market memory) {
        return _v4Pools[_market(marketId).poolRef];
    }

    /// @inheritdoc IAmmIntegration
    /// @dev `hasTwap` is true: the consistency read and the depth come from the reference pool (`REQ-AMM-V4-005`).
    /// @custom:spec REQ-AMM-CORE-009, REQ-AMM-CORE-010, REQ-AMM-V4-005
    function capabilities() external pure override returns (IntegrationCapabilities memory) {
        return IntegrationCapabilities({
            poolKeying: PoolKeying.Id,
            feeMode: FeeMode.Separate,
            pricingMode: PricingMode.ClosedForm,
            shapeKind: ShapeKind.TickRange,
            hasTwap: true,
            reentrancyGuarded: true,
            nativeToken: true,
            rateTokens: false
        });
    }

    // ─── Risk metadata and hooks ───

    /// @inheritdoc IAmmIntegration
    /// @dev `inRange` from the pool's `slot0` tick, `readSafe` false while the PoolManager is unlocked, `poolUnits` the
    /// pool's spot in-range liquidity in vault-token units.
    /// @custom:spec REQ-AMM-CORE-008, REQ-AMM-V4-003
    function riskMetadata(
        uint256 marketId,
        bytes32 positionKey
    ) external view override returns (RiskMetadata memory meta) {
        Market storage m = _market(marketId);
        (, int24 tick) = UniswapV4State.slot0(_PM, m.poolRef);
        meta.inRange = m.cfg.tickLower <= tick && tick < m.cfg.tickUpper;
        meta.readSafe = !UniswapV4State.isUnlocked(_PM);
        meta.poolUnits = _toUnits(m, UniswapV4State.liquidity(_PM, m.poolRef));
        if (positionKey != bytes32(0)) {
            (,,, uint128 live) = _readPosition(positionKey);
            // At most the position's uint128 liquidity.
            // forge-lint: disable-next-line(unsafe-typecast)
            meta.positionUnits = uint128(_toUnits(m, live));
        }
    }

    /// @inheritdoc IAmmIntegration
    /// @dev The reference pool's harmonic-mean in-range liquidity over `window` in vault-token units
    /// (`REQ-AMM-V4-008`); unavailable for a zero window, a failed `observe` or a zero seconds-per-liquidity
    /// difference.
    /// @custom:spec REQ-AMM-CORE-013, REQ-AMM-V4-008, SPEC-CAP-005, SPEC-UNIT-002
    function riskStatus(
        uint256 marketId,
        uint32 window
    ) external view override returns (RiskStatus memory status) {
        Market storage m = _market(marketId);
        if (window == 0) return status;
        (bool ok,, uint160 splDelta) = _observe(_v4Pools[m.poolRef].referencePool, window);
        if (!ok) return status;
        (status.depthUnits, status.depthAvailable) = ClPriceMath.harmonicMeanLiquidity(splDelta, window);
        status.depthUnits = _toUnits(m, status.depthUnits);
    }

    /// @inheritdoc IAmmIntegrationHooks
    /// @custom:spec REQ-AMM-CORE-013, REQ-AMM-V4-003
    function checkReadSafe(
        uint256 marketId
    ) external view override {
        _requireReadSafe(_market(marketId));
    }

    /// @inheritdoc IAmmIntegrationHooks
    /// @dev `SPEC-AMM-V4-002`: the larger of the spot gate `|tickSpot - tickRef|` and the reference pool's
    /// `|tickTwap - tickRef|`, the mean tick negated when the reference pool orders the tokens the other way.
    /// Unavailable for a zero window, a reference cardinality below `ceil(window / blockTime) + 1` or a failed
    /// `observe`.
    /// @custom:spec REQ-AMM-CORE-009, REQ-AMM-V4-005, SPEC-AMM-V4-002, SPEC-ORC-010, SPEC-ORC-022
    function consistencyDeviation(
        uint256 marketId,
        uint32 window,
        uint256[] calldata prices
    ) external view override returns (uint256 deviationBps, bool available) {
        Market storage m = _market(marketId);
        (uint256 p0, uint256 p1) = _prices(prices);
        if (window == 0) return (0, false);
        address ref = _v4Pools[m.poolRef].referencePool;
        // Only the observation cardinality is read.
        // forge-lint: disable-next-line(unused-return)
        (,,, uint16 cardinality,,,) = IUniswapV3Pool(ref).slot0();
        if (cardinality < LPPriceMath.minObservations(window, _BLOCK_TIME)) return (0, false);
        (bool ok, int56 tickDelta,) = _observe(ref, window);
        if (!ok) return (0, false);
        int256 twap = int256(ClPriceMath.meanTick(tickDelta, window));
        if (IUniswapV3Pool(ref).token0() != m.cfg.token0) twap = -twap;
        int256 tickRef =
            int256(ClPriceMath.tickAtSqrtRatio(ClPriceMath.oracleSqrtPrice(p0, p1, m.decimals0, m.decimals1)));
        (, int24 spot) = UniswapV4State.slot0(_PM, m.poolRef);
        uint256 a = _abs(int256(spot) - tickRef);
        uint256 b = _abs(twap - tickRef);
        deviationBps = a > b ? a : b;
        available = true;
    }

    /// @inheritdoc IAmmIntegrationHooks
    /// @custom:spec REQ-AMM-CORE-010
    function wrappedNative() external view override returns (address) {
        return _WETH;
    }

    /// @inheritdoc IAmmIntegrationHooks
    /// @dev The allowlist is empty: only `address(0)` is allowed (`REQ-AMM-V4-001`).
    /// @custom:spec REQ-AMM-CORE-014, REQ-AMM-V4-001
    function isAllowedPoolHook(
        address hooks
    ) external pure override returns (bool) {
        return _hookAllowed(hooks);
    }

    // ─── Hooks of the concentrated-liquidity base ───

    /// @dev Every position belongs to the one PositionManager.
    function _positionManager(
        bytes32
    ) internal view override returns (address) {
        return address(_POSM);
    }

    /// @dev `positionKey = bytes32(tokenId)`.
    function _tokenId(
        bytes32 positionKey
    ) internal pure override returns (uint256) {
        return uint256(positionKey);
    }

    /// @dev Only the PositionManager's NFTs are accepted.
    function _positionKeyOf(
        address manager,
        uint256 tokenId
    ) internal view override returns (bytes32, bool) {
        return (bytes32(tokenId), manager == address(_POSM));
    }

    /// @dev The PoolKey's hash and the ticks from `getPoolAndPositionInfo`, the liquidity from the PoolManager with the
    /// PositionManager as owner and `bytes32(tokenId)` as salt (`REQ-AMM-V4-003`); a token never minted reads as pool 0.
    /// @custom:spec REQ-AMM-V4-003, REQ-VAULT-008, REQ-VAULT-162
    function _readPosition(
        bytes32 positionKey
    ) internal view override returns (bytes32 poolRef, int24 tickLower, int24 tickUpper, uint128 liquidity) {
        (UniswapV4PoolKey memory key, uint256 info) = _POSM.getPoolAndPositionInfo(uint256(positionKey));
        if (info == 0) return (bytes32(0), 0, 0, 0);
        (tickLower, tickUpper) = _ticksOf(info);
        poolRef = keccak256(abi.encode(key));
        liquidity = UniswapV4State.positionLiquidity(
            _PM, poolRef, UniswapV4State.positionId(address(_POSM), tickLower, tickUpper, positionKey)
        );
    }

    /// @dev Never true: a position with a subscriber reverts `SubscribedPosition` (`REQ-AMM-V4-002`), and the market's
    /// hook is checked again (`HookNotAllowed`, `REQ-AMM-V4-001`).
    /// @custom:spec REQ-AMM-V4-001, REQ-AMM-V4-002, REQ-AMM-V4-006
    function _isEncumbered(
        Market storage market,
        bytes32 positionKey
    ) internal view override returns (bool) {
        (, uint256 info) = _POSM.getPoolAndPositionInfo(uint256(positionKey));
        if (info & 0xff != 0) revert SubscribedPosition();
        address hooks = _v4Pools[market.poolRef].key.hooks;
        if (!_hookAllowed(hooks)) revert HookNotAllowed(hooks);
        return false;
    }

    /// @dev The constructor's block interval.
    function _blockTime() internal view override returns (uint256) {
        return _BLOCK_TIME;
    }

    /// @dev `PoolLocked` while the PoolManager is unlocked (`REQ-AMM-V4-003`).
    /// @custom:spec REQ-AMM-V4-003, REQ-AMM-CORE-018
    function _requireReadSafe(
        Market storage
    ) internal view override {
        if (UniswapV4State.isUnlocked(_PM)) revert PoolLocked();
    }

    /// @dev `REQ-AMM-V4-004`: the amounts of `SPEC-AMM-V4-003` at the pool's `slot0`, checked against the minimums, then
    /// one batch: the fee step to `depositor` (when the position has liquidity) and the principal step to `recipient`.
    /// @custom:spec REQ-AMM-V4-004, SPEC-AMM-V4-003, SPEC-BACK-008
    function _removePrincipal(
        Market storage m,
        bytes32 positionKey,
        uint128 liquidity,
        uint256[] calldata minAmounts,
        address recipient,
        address depositor
    ) internal override returns (uint256[] memory amounts) {
        amounts = _principalAmounts(m, liquidity);
        if (amounts[0] < minAmounts[0]) revert BelowMinimum(0, amounts[0], minAmounts[0]);
        if (amounts[1] < minAmounts[1]) revert BelowMinimum(1, amounts[1], minAmounts[1]);
        (,,, uint128 live) = _readPosition(positionKey);
        Batch memory b = _batch(live != 0 ? 10 : 5);
        UniswapV4PoolKey storage key = _v4Pools[m.poolRef].key;
        if (live != 0) {
            _decrease(b, positionKey, 0, 0, 0);
            _takeTo(b, key, depositor);
        }
        _decrease(b, positionKey, liquidity, SafeCast.toUint128(minAmounts[0]), SafeCast.toUint128(minAmounts[1]));
        _takeTo(b, key, recipient);
        _run(b);
    }

    /// @dev `SPEC-AMM-V4-003`: the amounts removing `liquidity` credits at the pool's `slot0`, rounded down.
    function _principalAmounts(
        Market storage m,
        uint128 liquidity
    ) private view returns (uint256[] memory amounts) {
        (uint160 sqrtPriceX96,) = UniswapV4State.slot0(_PM, m.poolRef);
        (uint256 a0, uint256 a1) = ClPriceMath.amountsForLiquidity(
            sqrtPriceX96,
            ClPriceMath.sqrtRatioAtTick(m.cfg.tickLower),
            ClPriceMath.sqrtRatioAtTick(m.cfg.tickUpper),
            liquidity
        );
        amounts = _pair(a0, a1);
    }

    /// @dev `REQ-AMM-V4-004` step 1 alone; the fees the PoolManager credits are computed first with unchecked fee
    /// growth (`REQ-AMM-V4-010`). A position without liquidity accrues no fee and is not touched.
    /// @custom:spec REQ-AMM-V4-004, REQ-AMM-V4-010, REQ-VAULT-064
    function _collectAll(
        Market storage m,
        bytes32 positionKey,
        address depositor
    ) internal override returns (uint256 amount0, uint256 amount1) {
        bytes32 poolId = m.poolRef;
        bytes32 id =
            UniswapV4State.positionId(address(_POSM), m.cfg.tickLower, m.cfg.tickUpper, positionKey);
        UniswapV4State.PositionState memory p = UniswapV4State.position(_PM, poolId, id);
        if (p.liquidity == 0) return (0, 0);
        (uint256 in0, uint256 in1) = UniswapV4State.feeGrowthInside(_PM, poolId, m.cfg.tickLower, m.cfg.tickUpper);
        (amount0, amount1) = UniswapV4State.feesOwed(p, in0, in1);
        Batch memory b = _batch(5);
        _decrease(b, positionKey, 0, 0, 0);
        _takeTo(b, _v4Pools[poolId].key, depositor);
        _run(b);
    }

    // ─── Internal ───

    /// @dev A PositionManager action list being built.
    struct Batch {
        bytes actions;
        bytes[] params;
        uint256 n;
    }

    function _batch(
        uint256 capacity
    ) private pure returns (Batch memory b) {
        b.params = new bytes[](capacity);
    }

    function _push(
        Batch memory b,
        uint8 action,
        bytes memory params
    ) private pure {
        b.actions = abi.encodePacked(b.actions, action);
        b.params[b.n++] = params;
    }

    function _decrease(
        Batch memory b,
        bytes32 positionKey,
        uint256 liquidity,
        uint128 min0,
        uint128 min1
    ) private pure {
        _push(b, DECREASE_LIQUIDITY, abi.encode(uint256(positionKey), liquidity, min0, min1, bytes("")));
    }

    /// @dev Takes both currencies' credit to `to`; a native-ETH leg is taken to the PositionManager, wrapped there
    /// and swept to `to` as WETH, so no Avana contract receives ETH.
    function _takeTo(
        Batch memory b,
        UniswapV4PoolKey storage key,
        address to
    ) private view {
        address c0 = key.currency0;
        address c1 = key.currency1;
        if (c0 != address(0)) {
            _push(b, TAKE_PAIR, abi.encode(c0, c1, to));
            return;
        }
        _push(b, TAKE, abi.encode(address(0), ADDRESS_THIS, OPEN_DELTA));
        _push(b, WRAP, abi.encode(CONTRACT_BALANCE));
        _push(b, TAKE, abi.encode(c1, to, OPEN_DELTA));
        _push(b, SWEEP, abi.encode(_WETH, to));
    }

    function _run(
        Batch memory b
    ) private {
        bytes[] memory params = b.params;
        uint256 n = b.n;
        // Shrinks the array to the actions pushed.
        // solhint-disable-next-line no-inline-assembly
        assembly ("memory-safe") {
            mstore(params, n)
        }
        _POSM.modifyLiquidities(abi.encode(b.actions, params), block.timestamp);
    }

    /// @dev The market's configuration from a PoolKey checked at listing; reverts `InvalidPool`.
    function _poolConfig(
        UniswapV4PoolKey memory key,
        bytes32 poolId,
        address ref
    ) private view returns (ClMarketConfig memory cfg) {
        (uint160 sqrtPriceX96,) = UniswapV4State.slot0(_PM, poolId);
        if (sqrtPriceX96 == 0 || key.tickSpacing < 1 || key.tickSpacing > MAX_TICK_SPACING) revert InvalidPool();
        address t0 = key.currency0 == address(0) ? _WETH : key.currency0;
        address t1 = key.currency1;
        if (t1 == address(0) || t0 == t1 || !_supplyOk(t0) || !_supplyOk(t1)) revert InvalidPool();
        _checkReference(ref, t0, t1);
        cfg.positionManager = address(_POSM);
        cfg.factory = address(_PM);
        (cfg.token0, cfg.token1) = (t0, t1);
        cfg.fee = key.fee;
        cfg.tickSpacing = key.tickSpacing;
    }

    /// @dev `REQ-AMM-V4-007`: the factory's pool of the two tokens at the reference pool's own fee tier.
    function _checkReference(
        address ref,
        address t0,
        address t1
    ) private view {
        if (ref == address(0) || ref.code.length == 0) revert InvalidPool();
        (address a, address b) = t0 < t1 ? (t0, t1) : (t1, t0);
        uint24 fee;
        try IUniswapV3Pool(ref).fee() returns (uint24 f) {
            fee = f;
        } catch {
            revert InvalidPool();
        }
        IUniswapV3Pool p = IUniswapV3Pool(ref);
        if (IUniswapV3Factory(_REF_FACTORY).getPool(a, b, fee) != ref || p.token0() != a || p.token1() != b) {
            revert InvalidPool();
        }
    }

    /// @dev `totalSupply() < 2^127` (`REQ-AMM-V4-009`); false for a failed read.
    function _supplyOk(
        address token
    ) private view returns (bool) {
        try IERC20(token).totalSupply() returns (uint256 supply) {
            return supply < SUPPLY_BOUND;
        } catch {
            return false;
        }
    }

    /// @dev `REQ-AMM-V4-001`: the allowlist is empty, so only a hookless pool passes.
    function _hookAllowed(
        address hooks
    ) private pure returns (bool) {
        return hooks == address(0);
    }

    /// @dev `(tickLower, tickUpper)` of a packed `PositionInfo`.
    function _ticksOf(
        uint256 info
    ) private pure returns (int24 tickLower, int24 tickUpper) {
        // 24-bit two's-complement fields at offsets 8 and 32.
        // forge-lint: disable-next-line(unsafe-typecast)
        tickLower = int24(int256(info >> 8));
        // forge-lint: disable-next-line(unsafe-typecast)
        tickUpper = int24(int256(info >> 32));
    }

    function _abs(
        int256 x
    ) private pure returns (uint256) {
        // |x| of a tick difference, far inside int256.
        // forge-lint: disable-next-line(unsafe-typecast)
        return x < 0 ? uint256(-x) : uint256(x);
    }

    /// @dev The block interval of a chain Avana deploys on: 12 s for Ethereum (1) and Sepolia (11155111), 2 s for Base
    /// (8453), Base Sepolia (84532) and OP Mainnet (10), 1 s for Unichain (130); 0 for any other chain, where the constructor's
    /// value stands.
    function _knownBlockTime(
        uint256 chainId
    ) private pure returns (uint256) {
        if (chainId == 1 || chainId == 11_155_111) return 12;
        if (chainId == 8453 || chainId == 84_532 || chainId == 10) return 2;
        if (chainId == 130) return 1;
        return 0;
    }
}
// forge-lint: disable-end(reentrancy-events)
