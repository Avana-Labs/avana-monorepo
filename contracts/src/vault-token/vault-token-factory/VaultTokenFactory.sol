// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAmmIntegration} from "../../amm/IAmmIntegration.sol";
import {PoolKeying} from "../../amm/types/PoolKeying.sol";
import {ICollateralizationViews} from "../../custody/collateralization/ICollateralizationViews.sol";
import {ILPVault} from "../../custody/lp-vault/ILPVault.sol";
import {PositionShape} from "../../types/PositionShape.sol";
import {ShapeKind} from "../../types/ShapeKind.sol";
import {VaultTokenBindings} from "../../types/VaultTokenBindings.sol";
import {IVaultToken} from "../vault-token/IVaultToken.sol";
import {VaultToken} from "../vault-token/VaultToken.sol";
import {IVaultTokenFactory} from "./IVaultTokenFactory.sol";
import {CREATE3} from "solady/utils/CREATE3.sol";

/// @title VaultTokenFactory
/// @notice The chain's append-only registry of AMM integrations (one LPVault per integration identifier) and of vault
/// tokens (one per CDP Spoke and market key), and the only deployer of vault tokens, each at the CREATE3 address of
/// `salt = keccak256(abi.encode(spoke, marketKey))`.
/// @dev Immutable, with no owner, admin, role, setter, pause, upgrade path, fallback or `selfdestruct`. The AvanaTimelock
/// is the only caller of the two writing functions. The factory holds no power over a token once deployed: the token
/// never learns the factory's address. It calls no AMM integration on deployment (the MarketRegistry calls
/// `bindMarket` in the same listing batch); it reads the LPVault's and Collateralization's identity getters only in
/// `registerIntegration`, each with a length-checked `STATICCALL`. The CREATE3 proxy returns no revert data from the
/// token's constructor, so `deployVaultToken` checks every constructor condition of `REQ-VTOKEN-046` first and reverts
/// with the token's own errors (`marketKey != 0` holds because it is a keccak output and `integrationId != 0` because
/// only registered identifiers pass).
/// @custom:spec REQ-VTOKEN-019, REQ-VTOKEN-020, REQ-VTOKEN-021, REQ-VTOKEN-022, REQ-VTOKEN-023, REQ-VTOKEN-024, REQ-VTOKEN-028, REQ-VTOKEN-038, REQ-VTOKEN-044, REQ-VTOKEN-049, REQ-VTOKEN-050, REQ-AMM-CORE-001, INV-052, Q-068, Q-228, Q-299, Q-355, Q-374
contract VaultTokenFactory is IVaultTokenFactory {
    /// @dev Lowest and highest decimals `d` of `SPEC-UNIT-001`.
    uint8 private constant MIN_DECIMALS = 6;
    uint8 private constant MAX_DECIMALS = 18;
    /// @dev `marketId` lies below `2^32` (REQ-CONFIG-006).
    uint256 private constant MARKET_ID_LIMIT = 1 << 32;
    /// @dev Longest token name and symbol, bytes.
    uint256 private constant MAX_NAME_LENGTH = 128;
    uint256 private constant MAX_SYMBOL_LENGTH = 32;
    /// @dev ABI size of `IntegrationCapabilities`: eight static words.
    uint256 private constant CAPABILITIES_SIZE = 256;

    /// @dev The chain's AaveAdapter fixed proxy address, bound into every token as minter and burner.
    address private immutable _ADAPTER;
    /// @dev The chain's LPVaultSwap fixed proxy address, bound into every token.
    address private immutable _LP_VAULT_SWAP;
    /// @dev The chain's Collateralization, bound into every token and into every registered LPVault.
    address private immutable _COLLATERALIZATION;
    /// @dev The chain's AvanaTimelock, the only caller of `registerIntegration` and `deployVaultToken`.
    address private immutable _TIMELOCK;
    /// @dev The chain's MarketRegistry, which every registered LPVault must name.
    address private immutable _MARKET_REGISTRY;

    /// @dev LPVault of each registered integration identifier; written once.
    mapping(uint32 integrationId => address lpVault) private _lpVaultOf;
    /// @dev True for every registered LPVault, so one LPVault is registered under one identifier.
    mapping(address lpVault => bool registered) private _isLpVault;
    /// @dev Vault token of each (CDP Spoke, market key) pair; written once.
    mapping(address spoke => mapping(bytes32 marketKey => address vaultToken)) private _tokenOf;
    /// @dev True exactly for the tokens this factory deployed.
    mapping(address vaultToken => bool deployed) private _isVaultToken;
    /// @dev Pool keying of each registered integration; written once with `_lpVaultOf`.
    mapping(uint32 integrationId => PoolKeying keying) private _poolKeyingOf;
    /// @dev Shape kind of each registered integration, never `None` once registered; written once with `_lpVaultOf`.
    mapping(uint32 integrationId => ShapeKind kind) private _shapeKindOf;

    /// @notice Fixes the bindings passed to every token, the only caller of the writing functions and the
    /// MarketRegistry every LPVault must name; none of them needs code at deployment.
    /// @dev Reverts `ZeroAddress` for a zero argument and the token's `InvalidBinding` unless `adapter`, `lpVaultSwap`
    /// and `collateralization` are pairwise distinct, because every token would refuse such bindings.
    /// @param adapter The chain's AaveAdapter fixed proxy address.
    /// @param lpVaultSwap The chain's LPVaultSwap fixed proxy address.
    /// @param collateralization The chain's Collateralization.
    /// @param timelock The chain's AvanaTimelock.
    /// @param marketRegistry The chain's MarketRegistry fixed proxy address.
    /// @custom:spec REQ-VTOKEN-023, REQ-VTOKEN-044, REQ-VTOKEN-046
    constructor(
        address adapter,
        address lpVaultSwap,
        address collateralization,
        address timelock,
        address marketRegistry
    ) {
        if (
            adapter == address(0) || lpVaultSwap == address(0) || collateralization == address(0)
                || timelock == address(0) || marketRegistry == address(0)
        ) revert ZeroAddress();
        if (adapter == lpVaultSwap || adapter == collateralization || lpVaultSwap == collateralization) {
            revert IVaultToken.InvalidBinding();
        }
        _ADAPTER = adapter;
        _LP_VAULT_SWAP = lpVaultSwap;
        _COLLATERALIZATION = collateralization;
        _TIMELOCK = timelock;
        _MARKET_REGISTRY = marketRegistry;
    }

    /// @custom:spec REQ-VTOKEN-019, REQ-VTOKEN-037, REQ-VTOKEN-044, REQ-VTOKEN-045
    modifier onlyTimelock() {
        if (msg.sender != _TIMELOCK) revert NotTimelock();
        _;
    }

    // ─── Timelock-only ───

    /// @inheritdoc IVaultTokenFactory
    /// @dev Also refuses (`InvalidIntegration`) a zero LPVault and an LPVault equal to `ADAPTER`, `LP_VAULT_SWAP` or
    /// `COLLATERALIZATION`, which no token could bind. The getters are read with `STATICCALL` after the storage checks
    /// and before the writes; a getter that reverts, returns a short or malformed answer or has no code fails closed.
    /// @custom:spec REQ-VTOKEN-023, REQ-VTOKEN-044, REQ-VTOKEN-045, REQ-VTOKEN-049, REQ-AMM-CORE-001, Q-291, Q-374
    function registerIntegration(
        uint32 integrationId,
        address lpVault
    ) external override onlyTimelock {
        if (
            integrationId == 0 || lpVault == address(0) || _isFactoryBinding(lpVault)
                || _lpVaultOf[integrationId] != address(0) || _isLpVault[lpVault]
        ) revert InvalidIntegration();
        _checkCore();
        bytes32 ammProtocol = _checkVaultIdentity(integrationId, lpVault);
        (PoolKeying keying, ShapeKind kind) = _readCapabilities(lpVault);
        _lpVaultOf[integrationId] = lpVault;
        _isLpVault[lpVault] = true;
        _poolKeyingOf[integrationId] = keying;
        _shapeKindOf[integrationId] = kind;
        emit IntegrationRegistered(integrationId, lpVault, ammProtocol, keying, kind);
    }

    /// @inheritdoc IVaultTokenFactory
    /// @dev After the listed checks, reverts with the token's `InvalidBinding` unless the seven address bindings are
    /// pairwise distinct and none is the predicted token address. Writes both registries for the predicted address,
    /// then deploys; the token's constructor calls nothing, and a failed deployment (`DeploymentFailed`) reverts the
    /// writes. The factory calls no integration. `public` with `name` and `symbol` in memory: the calldata decoder of
    /// eleven parameters with two calldata strings does not fit the EVM stack.
    /// @custom:spec REQ-VTOKEN-004, REQ-VTOKEN-019, REQ-VTOKEN-020, REQ-VTOKEN-021, REQ-VTOKEN-022, REQ-VTOKEN-024, REQ-VTOKEN-028, REQ-VTOKEN-035, REQ-VTOKEN-036, REQ-VTOKEN-037, REQ-VTOKEN-038, REQ-VTOKEN-046, REQ-VTOKEN-049, REQ-VTOKEN-050, SPEC-UNIT-001, Q-191, Q-228, Q-299, Q-374
    function deployVaultToken(
        uint32 integrationId,
        address pool,
        bytes32 poolId,
        PositionShape calldata shape,
        address hub,
        address spoke,
        uint256 marketId,
        address lpOracle,
        uint8 decimals,
        string memory name,
        string memory symbol
    ) public override onlyTimelock returns (address vaultToken) {
        VaultTokenBindings memory b =
            _checkListing(integrationId, pool, poolId, shape, hub, spoke, marketId, lpOracle, decimals);
        uint256 nameLength = bytes(name).length;
        uint256 symbolLength = bytes(symbol).length;
        if (nameLength == 0 || nameLength > MAX_NAME_LENGTH || symbolLength == 0 || symbolLength > MAX_SYMBOL_LENGTH) {
            revert InvalidTokenMetadata();
        }
        b.name = name;
        b.symbol = symbol;
        vaultToken = _deployToken(b, pool, poolId, shape);
    }

    // ─── Views ───

    /// @inheritdoc IVaultTokenFactory
    /// @custom:spec REQ-VTOKEN-020, SPEC-AMM-CORE-002
    function marketKeyOf(
        uint32 integrationId,
        address pool,
        bytes32 poolId,
        PositionShape calldata shape
    ) external view override returns (bytes32 marketKey) {
        marketKey = _marketKey(integrationId, pool, poolId, shape);
    }

    /// @inheritdoc IVaultTokenFactory
    /// @custom:spec REQ-VTOKEN-021
    function tokenOf(
        address spoke,
        bytes32 marketKey
    ) external view override returns (address vaultToken) {
        vaultToken = _tokenOf[spoke][marketKey];
    }

    /// @inheritdoc IVaultTokenFactory
    /// @custom:spec REQ-VTOKEN-021
    function isVaultToken(
        address vaultToken
    ) external view override returns (bool deployed) {
        deployed = _isVaultToken[vaultToken];
    }

    /// @inheritdoc IVaultTokenFactory
    /// @custom:spec REQ-VTOKEN-044, REQ-AMM-CORE-001
    function lpVaultOf(
        uint32 integrationId
    ) external view override returns (address lpVault) {
        lpVault = _lpVaultOf[integrationId];
    }

    /// @inheritdoc IVaultTokenFactory
    /// @custom:spec REQ-VTOKEN-049
    function integrationKindOf(
        uint32 integrationId
    ) external view override returns (PoolKeying poolKeying, ShapeKind shapeKind) {
        poolKeying = _poolKeyingOf[integrationId];
        shapeKind = _shapeKindOf[integrationId];
    }

    /// @inheritdoc IVaultTokenFactory
    /// @custom:spec REQ-VTOKEN-020
    function predictAddress(
        address spoke,
        bytes32 marketKey
    ) external view override returns (address predicted) {
        predicted = _predict(_salt(spoke, marketKey));
    }

    /// @inheritdoc IVaultTokenFactory
    /// @custom:spec REQ-VTOKEN-023
    function ADAPTER() external view override returns (address adapter) {
        adapter = _ADAPTER;
    }

    /// @inheritdoc IVaultTokenFactory
    /// @custom:spec REQ-VTOKEN-023
    function LP_VAULT_SWAP() external view override returns (address lpVaultSwap) {
        lpVaultSwap = _LP_VAULT_SWAP;
    }

    /// @inheritdoc IVaultTokenFactory
    /// @custom:spec REQ-VTOKEN-023
    function COLLATERALIZATION() external view override returns (address collateralization) {
        collateralization = _COLLATERALIZATION;
    }

    /// @inheritdoc IVaultTokenFactory
    /// @custom:spec REQ-VTOKEN-019, REQ-VTOKEN-023
    function TIMELOCK() external view override returns (address timelock) {
        timelock = _TIMELOCK;
    }

    /// @inheritdoc IVaultTokenFactory
    /// @custom:spec REQ-VTOKEN-023, REQ-VTOKEN-044
    function MARKET_REGISTRY() external view override returns (address marketRegistry) {
        marketRegistry = _MARKET_REGISTRY;
    }

    // ─── Internal ───

    /// @notice The listing checks of `REQ-VTOKEN-022` in their order up to `TokenExistsForMarket`, returning the token's
    /// bindings without name and symbol.
    /// @custom:spec REQ-VTOKEN-021, REQ-VTOKEN-022, REQ-VTOKEN-035, REQ-VTOKEN-036, REQ-VTOKEN-049, SPEC-UNIT-001
    function _checkListing(
        uint32 integrationId,
        address pool,
        bytes32 poolId,
        PositionShape calldata shape,
        address hub,
        address spoke,
        uint256 marketId,
        address lpOracle,
        uint8 decimals
    ) private view returns (VaultTokenBindings memory b) {
        address lpVault = _lpVaultOf[integrationId];
        if (lpVault == address(0)) revert UnknownIntegration(integrationId);
        bool byAddress = _poolKeyingOf[integrationId] == PoolKeying.Address;
        bool keyed = byAddress ? pool != address(0) && poolId == bytes32(0) : pool == address(0) && poolId != bytes32(0);
        if (!keyed || hub == address(0) || spoke == address(0) || lpOracle == address(0)) revert ZeroAddress();
        _checkShape(_shapeKindOf[integrationId], shape);
        if (decimals < MIN_DECIMALS || decimals > MAX_DECIMALS) revert DecimalsOutOfRange();
        if (marketId == 0 || marketId >= MARKET_ID_LIMIT) revert InvalidMarketId();
        bytes32 key = _marketKey(integrationId, pool, poolId, shape);
        if (_tokenOf[spoke][key] != address(0)) revert TokenExistsForMarket();
        b.marketKey = key;
        b.integrationId = integrationId;
        b.integration = lpVault;
        b.hub = hub;
        b.spoke = spoke;
        b.marketId = marketId;
        b.lpOracle = lpOracle;
        b.adapter = _ADAPTER;
        b.lpVaultSwap = _LP_VAULT_SWAP;
        b.collateralization = _COLLATERALIZATION;
        b.decimals = decimals;
    }

    /// @notice Refuses shared bindings, writes both registries for the predicted address, emits `VaultTokenDeployed`
    /// with the bindings and the market definition, and deploys with CREATE3.
    /// @dev Every effect precedes the deployment, the only external call; the token's constructor calls nothing, and a
    /// failed deployment reverts the effects and the event. Solady's `deployDeterministic` returns the address derived
    /// from the salt, which is the predicted one.
    /// @custom:spec REQ-VTOKEN-020, REQ-VTOKEN-021, REQ-VTOKEN-022, REQ-VTOKEN-024, REQ-VTOKEN-046
    function _deployToken(
        VaultTokenBindings memory b,
        address pool,
        bytes32 poolId,
        PositionShape calldata shape
    ) private returns (address vaultToken) {
        bytes32 salt = _salt(b.spoke, b.marketKey);
        address predicted = _predict(salt);
        _checkDistinct(b.integration, b.hub, b.spoke, b.lpOracle, predicted);
        _tokenOf[b.spoke][b.marketKey] = predicted;
        _isVaultToken[predicted] = true;
        // The only call before this event is the internal CREATE3 address prediction (pure math), which forge-lint
        // counts as an external call; the deployment, the one external call, follows the event.
        // forge-lint: disable-start(reentrancy-events)
        emit VaultTokenDeployed(predicted, b.marketId, b.spoke, b, pool, poolId, shape);
        // forge-lint: disable-end(reentrancy-events)
        vaultToken = CREATE3.deployDeterministic(bytes.concat(type(VaultToken).creationCode, abi.encode(b)), salt);
    }

    /// @notice Reverts `InvalidShape` unless `shape` is a canonical shape of the integration's kind: the same kind,
    /// both ticks 0 for `FullPool`, and `tickLower < tickUpper` for `TickRange`. Tick spacing and the usable range are
    /// the integration's `bindMarket` checks.
    /// @custom:spec REQ-VTOKEN-049, REQ-AMM-CORE-003, REQ-AMM-CORE-004
    function _checkShape(
        ShapeKind kind,
        PositionShape calldata shape
    ) private pure {
        if (
            shape.kind != kind
                || (kind == ShapeKind.FullPool
                        ? shape.tickLower != 0 || shape.tickUpper != 0
                        : shape.tickLower >= shape.tickUpper)
        ) revert InvalidShape();
    }

    /// @notice Reverts `InvalidIntegration` unless Collateralization names this factory, `ADAPTER` and
    /// `LP_VAULT_SWAP`.
    /// @custom:spec REQ-VTOKEN-044
    function _checkCore() private view {
        address coll = _COLLATERALIZATION;
        if (
            _readAddress(coll, abi.encodeCall(ICollateralizationViews.VAULT_TOKEN_FACTORY, ())) != address(this)
                || _readAddress(coll, abi.encodeCall(ICollateralizationViews.ADAPTER, ())) != _ADAPTER
                || _readAddress(coll, abi.encodeCall(ICollateralizationViews.LP_VAULT_SWAP, ())) != _LP_VAULT_SWAP
        ) revert InvalidIntegration();
    }

    /// @notice Reverts `InvalidIntegration` unless the LPVault's identity matches the chain's core: its identifier,
    /// Collateralization, Lock (Collateralization's), timelock and MarketRegistry, and a non-zero AMM protocol, which
    /// it returns.
    /// @custom:spec REQ-VTOKEN-044, REQ-AMM-CORE-001
    function _checkVaultIdentity(
        uint32 integrationId,
        address lpVault
    ) private view returns (bytes32 ammProtocol) {
        (bool idOk, uint256 id) = _readWord(lpVault, abi.encodeCall(IAmmIntegration.INTEGRATION_ID, ()));
        bool protocolOk;
        uint256 protocol;
        (protocolOk, protocol) = _readWord(lpVault, abi.encodeCall(IAmmIntegration.AMM_PROTOCOL, ()));
        address lock = _readAddress(_COLLATERALIZATION, abi.encodeCall(ICollateralizationViews.LOCK, ()));
        if (
            !idOk || id != integrationId || !protocolOk || protocol == 0 || lock == address(0)
                || _readAddress(lpVault, abi.encodeCall(ILPVault.COLLATERALIZATION, ())) != _COLLATERALIZATION
                || _readAddress(lpVault, abi.encodeCall(ILPVault.LOCK, ())) != lock
                || _readAddress(lpVault, abi.encodeCall(ILPVault.TIMELOCK, ())) != _TIMELOCK
                || _readAddress(lpVault, abi.encodeCall(ILPVault.MARKET_REGISTRY, ())) != _MARKET_REGISTRY
        ) revert InvalidIntegration();
        ammProtocol = bytes32(protocol);
    }

    /// @notice The integration's pool keying and shape kind from `capabilities()`: a 256-byte answer whose first word
    /// is a valid `PoolKeying` and fourth word a `ShapeKind` other than `None`, else `InvalidIntegration`.
    /// @custom:spec REQ-VTOKEN-049, REQ-AMM-CORE-009, REQ-AMM-CORE-010
    function _readCapabilities(
        address lpVault
    ) private view returns (PoolKeying keying, ShapeKind kind) {
        // A view of the candidate LPVault; the answer is length- and range-checked before it is read.
        // solhint-disable-next-line avoid-low-level-calls
        (bool ok, bytes memory ret) = lpVault.staticcall(abi.encodeCall(IAmmIntegration.capabilities, ()));
        if (!ok || ret.length != CAPABILITIES_SIZE) revert InvalidIntegration();
        (uint256 keyingWord,,, uint256 kindWord) = abi.decode(ret, (uint256, uint256, uint256, uint256));
        if (
            keyingWord > uint256(type(PoolKeying).max) || kindWord == uint256(ShapeKind.None)
                || kindWord > uint256(type(ShapeKind).max)
        ) revert InvalidIntegration();
        keying = PoolKeying(keyingWord);
        kind = ShapeKind(kindWord);
    }

    /// @dev An address getter's answer, or `address(0)` when the call fails, returns other than 32 bytes or a word
    /// above 160 bits; every caller compares the result with a non-zero expected address.
    function _readAddress(
        address target,
        bytes memory data
    ) private view returns (address value) {
        (bool ok, uint256 word) = _readWord(target, data);
        // Range-checked: a word above 160 bits reads as address(0), which never matches a binding.
        // forge-lint: disable-next-line(unsafe-typecast)
        if (ok && word <= type(uint160).max) value = address(uint160(word));
    }

    /// @dev A one-word view answer: `ok` is false when the call fails or returns other than 32 bytes.
    function _readWord(
        address target,
        bytes memory data
    ) private view returns (bool ok, uint256 word) {
        // A view of a candidate contract; the answer is length-checked before it is read.
        // solhint-disable-next-line avoid-low-level-calls
        (bool success, bytes memory ret) = target.staticcall(data);
        if (success && ret.length == 32) {
            ok = true;
            word = abi.decode(ret, (uint256));
        }
    }

    /// @custom:spec REQ-VTOKEN-020, SPEC-AMM-CORE-002
    function _marketKey(
        uint32 integrationId,
        address pool,
        bytes32 poolId,
        PositionShape calldata shape
    ) private view returns (bytes32 key) {
        key = keccak256(
            abi.encode(block.chainid, integrationId, pool, poolId, shape.kind, shape.tickLower, shape.tickUpper)
        );
    }

    /// @custom:spec REQ-VTOKEN-020
    function _salt(
        address spoke,
        bytes32 marketKey
    ) private pure returns (bytes32 salt) {
        salt = keccak256(abi.encode(spoke, marketKey));
    }

    /// @notice The CREATE3 address of `salt` for this factory: a CREATE2 proxy at `keccak256(0xff ‖ factory ‖ salt ‖
    /// PROXY_INITCODE_HASH)` that creates the token with nonce 1.
    /// @custom:spec REQ-VTOKEN-020
    function _predict(
        bytes32 salt
    ) private view returns (address predicted) {
        predicted = CREATE3.predictDeterministicAddress(salt);
    }

    /// @notice Reverts with the token's `InvalidBinding` unless the seven address bindings are pairwise distinct and
    /// none is the predicted token address.
    /// @dev The three factory bindings are distinct (constructor) and differ from every registered LPVault
    /// (`registerIntegration`), so only the three listing addresses need comparing: with each other, with the four
    /// fixed bindings and with the token address. A registered LPVault has code and the predicted address has none, so
    /// they differ.
    /// @custom:spec REQ-VTOKEN-022, REQ-VTOKEN-046
    function _checkDistinct(
        address lpVault,
        address hub,
        address spoke,
        address lpOracle,
        address token
    ) private view {
        if (
            hub == spoke || hub == lpOracle || spoke == lpOracle || _isBoundElsewhere(hub, lpVault, token)
                || _isBoundElsewhere(spoke, lpVault, token) || _isBoundElsewhere(lpOracle, lpVault, token)
        ) revert IVaultToken.InvalidBinding();
    }

    /// @custom:spec REQ-VTOKEN-022, REQ-VTOKEN-046
    function _isBoundElsewhere(
        address account,
        address lpVault,
        address token
    ) private view returns (bool bound) {
        bound = account == lpVault || account == token || _isFactoryBinding(account);
    }

    /// @custom:spec REQ-VTOKEN-023, REQ-VTOKEN-044
    function _isFactoryBinding(
        address account
    ) private view returns (bool bound) {
        bound = account == _ADAPTER || account == _LP_VAULT_SWAP || account == _COLLATERALIZATION;
    }
}
