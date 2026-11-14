// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {DebtReserveDef} from "../../../src/policy/market-registry/types/DebtReserveDef.sol";
import {MarketStatus} from "../../../src/policy/market-registry/types/MarketStatus.sol";
import {SpokeDef} from "../../../src/policy/market-registry/types/SpokeDef.sol";
import {TokenDef} from "../../../src/policy/market-registry/types/TokenDef.sol";
import {Market} from "../../../src/types/Market.sol";
import {RouteSlot} from "../../../src/types/RouteSlot.sol";

/// @title MockMarketRegistry
/// @notice The MarketRegistry views the ParameterStore reads, backed by settable storage: a stand-in for the
/// MarketRegistry in these tests that answers with the record shapes of `IMarketRegistry`.
contract MockMarketRegistry {
    mapping(uint256 => Market) internal _markets;
    mapping(address => TokenDef) internal _tokens;
    mapping(address => SpokeDef) internal _spokes;
    mapping(address => uint256[]) internal _marketsOfSpoke;
    mapping(address => uint256) internal _marketOfLpOracle;
    mapping(address => uint256) internal _marketOfVaultToken;
    mapping(address => bool) internal _hubs;
    mapping(address => uint256[]) internal _reserveIds;
    mapping(address => mapping(uint256 => DebtReserveDef)) internal _reserves;
    mapping(address => address[]) internal _primary;
    mapping(address => address[]) internal _alternate;
    mapping(address => uint32) internal _integrationIds;
    address[] internal _spokeList;
    uint256 public marketCount;

    address public COLLATERALIZATION;
    address public AAVE_ADAPTER = address(0xADA);
    address public PROXY_MANAGER = address(0xBEEF01);
    address public LP_VAULT_SWAP = address(0xBEEF02);
    address public VAULT_TOKEN_FACTORY = address(0xBEEF03);
    address public RISK_MODULE = address(0xBEEF04);
    address public LOCK = address(0xBEEF05);
    address public PAYOUT_ESCROW = address(0xBEEF06);
    address public flashSource = address(0xBEEF07);
    /// @dev Swap-route records `(marketId, token, debtAsset, kind) → route`, as the MarketRegistry's `getRoute` serves.
    mapping(bytes32 => address) internal _routeOf;
    /// @dev `getRoute` answers only once a suite turns it on (the flash helper's suites); every other suite keeps the
    /// registry without route reads, so a contract that tries the read takes its failure path as before.
    bool public routeReads;
    /// @dev `priceRouteVersion` per token; 0 unless a suite sets one.
    mapping(address => uint64) internal _priceRouteVersion;

    function setRouteReads(
        bool on
    ) external {
        routeReads = on;
    }

    function setRouteRecord(
        uint256 marketId,
        address token,
        address debtAsset,
        uint8 kind,
        address route
    ) external {
        _routeOf[keccak256(abi.encode(marketId, token, debtAsset, kind))] = route;
    }

    function getRoute(
        uint256 marketId,
        address token,
        address debtAsset,
        uint8 kind
    ) external view returns (address route, bool usable) {
        require(routeReads, "no route reads");
        route = _routeOf[keccak256(abi.encode(marketId, token, debtAsset, kind))];
        usable = route != address(0);
    }
    address public PARAMETER_STORE = address(0xBEEF08);
    address public FLASH_LIQUIDATOR = address(0xBEEF09);
    address public STANDARD_SPOKE_IMPLEMENTATION = address(0xBEEF0A);

    function setProxyManager(
        address p
    ) external {
        PROXY_MANAGER = p;
    }

    function setCollateralization(
        address c
    ) external {
        COLLATERALIZATION = c;
    }

    function setMarket(
        uint256 id,
        Market memory m
    ) external {
        Market storage s = _markets[id];
        s.chainId = m.chainId;
        s.hub = m.hub;
        s.spoke = m.spoke;
        s.integrationId = m.integrationId;
        s.integration = m.integration;
        s.pool = m.pool;
        s.poolId = m.poolId;
        s.shape = m.shape;
        s.tokens = m.tokens;
        s.tokenDecimals = m.tokenDecimals;
        s.vaultToken = m.vaultToken;
        s.decimals = m.decimals;
        s.lpOracle = m.lpOracle;
        s.hubAssetId = m.hubAssetId;
        s.reserveId = m.reserveId;
        s.status = m.status;
        if (id > marketCount) marketCount = id;
        _marketOfLpOracle[m.lpOracle] = id;
        _marketOfVaultToken[m.vaultToken] = id;
        _marketsOfSpoke[m.spoke].push(id);
    }

    function setStatus(
        uint256 id,
        MarketStatus status
    ) external {
        _markets[id].status = status;
    }

    function setToken(
        address token,
        address[] memory primary,
        address[] memory alternate,
        address[] memory standby
    ) external {
        TokenDef storage t = _tokens[token];
        t.listed = true;
        t.decimals = 6;
        t.isUsdStable = true;
        t.primaryRoute = primary;
        t.alternateRoute = alternate;
        t.standbyRoute = standby;
        _primary[token] = primary;
        _alternate[token] = alternate;
    }

    function setUsdStable(
        address token,
        bool stable
    ) external {
        _tokens[token].isUsdStable = stable;
    }

    function setActiveRoutes(
        address token,
        address[] memory primary,
        address[] memory alternate
    ) external {
        _primary[token] = primary;
        _alternate[token] = alternate;
    }

    function setHub(
        address hub,
        bool recorded
    ) external {
        _hubs[hub] = recorded;
    }

    function setSpoke(
        address spoke,
        address hub
    ) external {
        _spokes[spoke].approved = true;
        _spokes[spoke].hub = hub;
        _spokeList.push(spoke);
    }

    function setDebtReserve(
        address spoke,
        DebtReserveDef memory d
    ) external {
        if (_reserves[spoke][d.reserveId].asset == address(0)) _reserveIds[spoke].push(d.reserveId);
        _reserves[spoke][d.reserveId] = d;
    }

    function setIntegrationId(
        address lpVault,
        uint32 id
    ) external {
        _integrationIds[lpVault] = id;
    }

    function getMarket(
        uint256 id
    ) external view returns (Market memory) {
        return _markets[id];
    }

    function getToken(
        address token
    ) external view returns (TokenDef memory) {
        return _tokens[token];
    }

    function getSpoke(
        address spoke
    ) external view returns (SpokeDef memory) {
        return _spokes[spoke];
    }

    function getSpokes() external view returns (address[] memory) {
        return _spokeList;
    }

    function marketsOfSpoke(
        address spoke
    ) external view returns (uint256[] memory) {
        return _marketsOfSpoke[spoke];
    }

    function marketOfLpOracle(
        address lpOracle
    ) external view returns (uint256) {
        return _marketOfLpOracle[lpOracle];
    }

    function marketOfVaultToken(
        address vaultToken
    ) external view returns (uint256) {
        return _marketOfVaultToken[vaultToken];
    }

    function isRecordedHub(
        address hub
    ) external view returns (bool) {
        return _hubs[hub];
    }

    function integrationIdOf(
        address lpVault
    ) external view returns (uint32) {
        return _integrationIds[lpVault];
    }

    function getDebtReserveIds(
        address spoke
    ) external view returns (uint256[] memory) {
        return _reserveIds[spoke];
    }

    function getDebtReserve(
        address spoke,
        uint256 id
    ) external view returns (DebtReserveDef memory) {
        return _reserves[spoke][id];
    }

    function isApprovedDebtReserve(
        address spoke,
        uint256 id
    ) external view returns (bool) {
        return _reserves[spoke][id].approved;
    }

    function activePriceRoutes(
        address token
    ) external view virtual returns (address[] memory, address[] memory, RouteSlot) {
        return (_primary[token], _alternate[token], RouteSlot.None);
    }

    /// @notice Route version read by the LPOracle on every evaluation; this mock never changes routes after setup, so
    /// the version stays 0 unless a test sets one (to tell it apart from the words next to it in a view).
    function priceRouteVersion(
        address token
    ) external view virtual returns (uint64) {
        return _priceRouteVersion[token];
    }

    function setPriceRouteVersion(
        address token,
        uint64 version
    ) external {
        _priceRouteVersion[token] = version;
    }
}
