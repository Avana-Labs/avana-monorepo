// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {PoolKeying} from "../../../src/amm/types/AmmTypes.sol";
import {ICollateralization} from "../../../src/legacy/ICollateralization.sol";
import {ILegacyLPVault} from "../../../src/legacy/ILegacyLPVault.sol";
import {ILegacyVaultToken} from "../../../src/legacy/ILegacyVaultToken.sol";
import {ILegacyVaultTokenFactory} from "../../../src/legacy/ILegacyVaultTokenFactory.sol";
import {RouteMath} from "../../../src/liquidation/settlement-routes/RouteMath.sol";
import {VaultTokenBindings} from "../../../src/types/MarketTypes.sol";
import {PositionShape, ShapeKind} from "../../../src/types/PositionTypes.sol";
import {LegacyVaultToken} from "./LegacyVaultToken.sol";
import {AccessManaged} from "@openzeppelin/contracts/access/manager/AccessManaged.sol";
import {IAccessManaged} from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import {CREATE3} from "solady/utils/CREATE3.sol";

/// @title LegacyVaultTokenFactory
/// @notice Append-only registry of AMM integrations and vault tokens; the only deployer of vault tokens (CREATE3).
/// @dev Test stand-in for the pre-refactor factory, kept so the legacy MarketRegistry and LegacyRiskModule tests run until
/// step 4 folds vault-token deployment into the LegacyRiskModule.
contract LegacyVaultTokenFactory is ILegacyVaultTokenFactory, AccessManaged {
    uint8 private constant MIN_DECIMALS = 6;
    uint8 private constant MAX_DECIMALS = 18;
    uint256 private constant MARKET_ID_LIMIT = 1 << 32;
    uint256 private constant MAX_NAME_LENGTH = 128;
    uint256 private constant MAX_SYMBOL_LENGTH = 32;
    /// @dev ABI size of `IntegrationCapabilities`: eight static words.
    uint256 private constant CAPABILITIES_SIZE = 256;
    /// @dev Gas each getter read runs with; a getter that needs more fails the read, which fails closed.
    uint256 private constant READ_GAS = 30_000;

    address private immutable _ADAPTER;
    address private immutable _LP_VAULT_SWAP;
    address private immutable _COLLATERALIZATION;
    address private immutable _MARKET_REGISTRY;

    mapping(uint32 integrationId => address lpVault) private _lpVaultOf;
    /// @dev Registered LPVaults and the identifier of each, so one LPVault is registered under one identifier.
    mapping(address lpVault => uint32 integrationId) private _integrationIdOf;
    mapping(address spoke => mapping(bytes32 marketKey => address vaultToken)) private _tokenOf;
    mapping(address vaultToken => bool deployed) private _isVaultToken;
    mapping(uint32 integrationId => PoolKeying keying) private _poolKeyingOf;
    /// @dev Never `None` once registered.
    mapping(uint32 integrationId => ShapeKind kind) private _shapeKindOf;

    constructor(
        address adapter,
        address lpVaultSwap,
        address collateralization,
        address authority,
        address marketRegistry
    ) AccessManaged(authority) {
        if (
            adapter == address(0) || lpVaultSwap == address(0) || collateralization == address(0)
                || authority == address(0) || marketRegistry == address(0)
        ) revert ZeroAddress();
        if (adapter == lpVaultSwap || adapter == collateralization || lpVaultSwap == collateralization) {
            revert ILegacyVaultToken.InvalidBinding();
        }
        _ADAPTER = adapter;
        _LP_VAULT_SWAP = lpVaultSwap;
        _COLLATERALIZATION = collateralization;
        _MARKET_REGISTRY = marketRegistry;
    }

    /// @inheritdoc ILegacyVaultTokenFactory
    /// @dev A getter that reverts, returns a malformed answer or has no code fails closed.
    function registerIntegration(
        uint32 integrationId,
        address lpVault
    ) external override restricted {
        if (
            integrationId == 0 || lpVault == address(0) || _isFactoryBinding(lpVault)
                || _lpVaultOf[integrationId] != address(0) || _integrationIdOf[lpVault] != 0
        ) revert InvalidIntegration();
        _checkCore();
        bytes32 ammProtocol = _checkVaultIdentity(integrationId, lpVault);
        (PoolKeying keying, ShapeKind kind) = _readCapabilities(lpVault);
        _lpVaultOf[integrationId] = lpVault;
        _integrationIdOf[lpVault] = integrationId;
        _poolKeyingOf[integrationId] = keying;
        _shapeKindOf[integrationId] = kind;
        // The only calls before this event are bounded static reads, which cannot re-enter.
        // forge-lint: disable-next-line(reentrancy-events)
        emit IntegrationRegistered(integrationId, lpVault, ammProtocol, keying, kind);
    }

    /// @inheritdoc ILegacyVaultTokenFactory
    /// @dev `public` with `name` and `symbol` in memory: the calldata decoder of eleven parameters overflows the stack.
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
    ) public override restricted returns (address vaultToken) {
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

    /// @inheritdoc ILegacyVaultTokenFactory
    function marketKeyOf(
        uint32 integrationId,
        address pool,
        bytes32 poolId,
        PositionShape calldata shape
    ) external view override returns (bytes32 marketKey) {
        marketKey = _marketKey(integrationId, pool, poolId, shape);
    }

    /// @inheritdoc ILegacyVaultTokenFactory
    function tokenOf(
        address spoke,
        bytes32 marketKey
    ) external view override returns (address vaultToken) {
        vaultToken = _tokenOf[spoke][marketKey];
    }

    /// @inheritdoc ILegacyVaultTokenFactory
    function isVaultToken(
        address vaultToken
    ) external view override returns (bool deployed) {
        deployed = _isVaultToken[vaultToken];
    }

    /// @inheritdoc ILegacyVaultTokenFactory
    function lpVaultOf(
        uint32 integrationId
    ) external view override returns (address lpVault) {
        lpVault = _lpVaultOf[integrationId];
    }

    /// @inheritdoc ILegacyVaultTokenFactory
    function integrationIdOf(
        address lpVault
    ) external view override returns (uint32 integrationId) {
        integrationId = _integrationIdOf[lpVault];
    }

    /// @inheritdoc ILegacyVaultTokenFactory
    function integrationKindOf(
        uint32 integrationId
    ) external view override returns (PoolKeying poolKeying, ShapeKind shapeKind) {
        poolKeying = _poolKeyingOf[integrationId];
        shapeKind = _shapeKindOf[integrationId];
    }

    /// @inheritdoc ILegacyVaultTokenFactory
    function predictAddress(
        address spoke,
        bytes32 marketKey
    ) external view override returns (address predicted) {
        predicted = _predict(_salt(spoke, marketKey));
    }

    /// @inheritdoc ILegacyVaultTokenFactory
    function ADAPTER() external view override returns (address adapter) {
        adapter = _ADAPTER;
    }

    /// @inheritdoc ILegacyVaultTokenFactory
    function LP_VAULT_SWAP() external view override returns (address lpVaultSwap) {
        lpVaultSwap = _LP_VAULT_SWAP;
    }

    /// @inheritdoc ILegacyVaultTokenFactory
    function COLLATERALIZATION() external view override returns (address collateralization) {
        collateralization = _COLLATERALIZATION;
    }

    /// @inheritdoc ILegacyVaultTokenFactory
    function MARKET_REGISTRY() external view override returns (address marketRegistry) {
        marketRegistry = _MARKET_REGISTRY;
    }

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

    /// @notice Refuses shared bindings, writes both registries for the predicted address, then deploys with CREATE3.
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
        // The only call before this event is the CREATE3 address prediction (pure math); the deployment follows it.
        // forge-lint: disable-start(reentrancy-events)
        emit VaultTokenDeployed(predicted, b.marketId, b.spoke, b, pool, poolId, shape);
        // forge-lint: disable-end(reentrancy-events)
        vaultToken = CREATE3.deployDeterministic(bytes.concat(type(LegacyVaultToken).creationCode, abi.encode(b)), salt);
    }

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

    /// @notice Reverts `InvalidIntegration` unless Collateralization names this factory, `ADAPTER` and `LP_VAULT_SWAP`.
    function _checkCore() private view {
        address coll = _COLLATERALIZATION;
        if (
            _readAddress(coll, abi.encodeCall(ICollateralization.VAULT_TOKEN_FACTORY, ())) != address(this)
                || _readAddress(coll, abi.encodeCall(ICollateralization.ADAPTER, ())) != _ADAPTER
                || _readAddress(coll, abi.encodeCall(ICollateralization.LP_VAULT_SWAP, ())) != _LP_VAULT_SWAP
        ) revert InvalidIntegration();
    }

    function _checkVaultIdentity(
        uint32 integrationId,
        address lpVault
    ) private view returns (bytes32 ammProtocol) {
        (bool idOk, uint256 id) = _readWord(lpVault, abi.encodeCall(ILegacyLPVault.INTEGRATION_ID, ()));
        bool protocolOk;
        uint256 protocol;
        (protocolOk, protocol) = _readWord(lpVault, abi.encodeCall(ILegacyLPVault.AMM_PROTOCOL, ()));
        address lock = _readAddress(_COLLATERALIZATION, abi.encodeCall(ICollateralization.LOCK, ()));
        if (
            !idOk || id != integrationId || !protocolOk || protocol == 0 || lock == address(0)
                || _readAddress(lpVault, abi.encodeCall(ILegacyLPVault.COLLATERALIZATION, ())) != _COLLATERALIZATION
                || _readAddress(lpVault, abi.encodeCall(ILegacyLPVault.LOCK, ())) != lock
                || _readAddress(lpVault, abi.encodeCall(IAccessManaged.authority, ())) != authority()
                || _readAddress(lpVault, abi.encodeCall(ILegacyLPVault.MARKET_REGISTRY, ())) != _MARKET_REGISTRY
        ) revert InvalidIntegration();
        ammProtocol = bytes32(protocol);
    }

    /// @notice The integration's pool keying and shape kind from `capabilities()`, else `InvalidIntegration`.
    function _readCapabilities(
        address lpVault
    ) private view returns (PoolKeying keying, ShapeKind kind) {
        (bool ok, bytes memory ret) = _read(lpVault, abi.encodeCall(ILegacyLPVault.capabilities, ()), CAPABILITIES_SIZE);
        if (!ok) revert InvalidIntegration();
        (uint256 keyingWord,,, uint256 kindWord) = abi.decode(ret, (uint256, uint256, uint256, uint256));
        if (
            keyingWord > uint256(type(PoolKeying).max) || kindWord == uint256(ShapeKind.None)
                || kindWord > uint256(type(ShapeKind).max)
        ) revert InvalidIntegration();
        keying = PoolKeying(keyingWord);
        kind = ShapeKind(kindWord);
    }

    /// @dev An address getter's answer, or `address(0)` when the read fails or the word is not an address.
    function _readAddress(
        address target,
        bytes memory data
    ) private view returns (address value) {
        (bool ok, uint256 word) = _readWord(target, data);
        // Range-checked: a word above 160 bits reads as address(0), which never matches a binding.
        // forge-lint: disable-next-line(unsafe-typecast)
        if (ok && word <= type(uint160).max) value = address(uint160(word));
    }

    function _readWord(
        address target,
        bytes memory data
    ) private view returns (bool ok, uint256 word) {
        bytes memory ret;
        (ok, ret) = _read(target, data, 32);
        if (ok) word = abi.decode(ret, (uint256));
    }

    /// @dev A static call with `READ_GAS` whose answer must be exactly `size` bytes; copies at most `size + 32`.
    function _read(
        address target,
        bytes memory data,
        uint256 size
    ) private view returns (bool ok, bytes memory ret) {
        (ok, ret) = RouteMath._staticRead(target, READ_GAS, data, size + 32);
        ok = ok && ret.length == size;
    }

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

    function _salt(
        address spoke,
        bytes32 marketKey
    ) private pure returns (bytes32 salt) {
        salt = keccak256(abi.encode(spoke, marketKey));
    }

    function _predict(
        bytes32 salt
    ) private view returns (address predicted) {
        predicted = CREATE3.predictDeterministicAddress(salt);
    }

    /// @dev The fixed bindings are already distinct, so only the three listing addresses need comparing.
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
        ) revert ILegacyVaultToken.InvalidBinding();
    }

    function _isBoundElsewhere(
        address account,
        address lpVault,
        address token
    ) private view returns (bool bound) {
        bound = account == lpVault || account == token || _isFactoryBinding(account);
    }

    function _isFactoryBinding(
        address account
    ) private view returns (bool bound) {
        bound = account == _ADAPTER || account == _LP_VAULT_SWAP || account == _COLLATERALIZATION;
    }
}
