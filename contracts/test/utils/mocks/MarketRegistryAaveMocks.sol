// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAaveV4Hub} from "../../../src/interfaces/external/aave/IAaveV4Hub.sol";
import {IAaveV4Spoke} from "../../../src/interfaces/external/aave/IAaveV4Spoke.sol";

/// @title RegistryHubMock
/// @notice The Aave V4 Hub reads the MarketRegistry makes, backed by settable storage. The local Aave V4 fixture has
/// no asset or reserve configured yet, so reserve-level reads use this mock; the Spoke-implementation checks run on the
/// fixture's real Spoke.
contract RegistryHubMock {
    mapping(address => uint256) public assetIdOf;
    mapping(address => bool) public listed;
    mapping(uint256 => mapping(address => IAaveV4Hub.SpokeConfig)) internal _spokeCfg;
    mapping(uint256 => IAaveV4Hub.AssetConfig) internal _assetCfg;
    mapping(uint256 => mapping(address => uint256)) public owed;
    mapping(uint256 => mapping(address => uint256)) public deficit;

    function setAsset(
        address underlying,
        uint256 id
    ) external {
        assetIdOf[underlying] = id;
        listed[underlying] = true;
    }

    function setSpokeConfig(
        uint256 assetId,
        address spoke,
        uint40 addCap,
        uint40 drawCap
    ) external {
        _spokeCfg[assetId][spoke].addCap = addCap;
        _spokeCfg[assetId][spoke].drawCap = drawCap;
    }

    function setLiquidityFee(
        uint256 assetId,
        uint16 fee
    ) external {
        _assetCfg[assetId].liquidityFee = fee;
    }

    function setReinvestment(
        uint256 assetId,
        address controller
    ) external {
        _assetCfg[assetId].reinvestmentController = controller;
    }

    function setOwed(
        uint256 assetId,
        address spoke,
        uint256 o,
        uint256 d
    ) external {
        owed[assetId][spoke] = o;
        deficit[assetId][spoke] = d;
    }

    function getAssetId(
        address underlying
    ) external view returns (uint256) {
        require(listed[underlying], "AssetNotListed");
        return assetIdOf[underlying];
    }

    function getSpokeConfig(
        uint256 assetId,
        address spoke
    ) external view returns (IAaveV4Hub.SpokeConfig memory) {
        return _spokeCfg[assetId][spoke];
    }

    function getAssetConfig(
        uint256 assetId
    ) external view returns (IAaveV4Hub.AssetConfig memory) {
        return _assetCfg[assetId];
    }

    function getSpokeTotalOwed(
        uint256 assetId,
        address spoke
    ) external view returns (uint256) {
        return owed[assetId][spoke];
    }

    function getSpokeDeficitRay(
        uint256 assetId,
        address spoke
    ) external view returns (uint256) {
        return deficit[assetId][spoke];
    }

    function MAX_ALLOWED_UNDERLYING_DECIMALS() external pure returns (uint8) {
        return 18;
    }

    function MIN_ALLOWED_UNDERLYING_DECIMALS() external pure returns (uint8) {
        return 6;
    }

    function MAX_ALLOWED_SPOKE_CAP() external pure returns (uint40) {
        return type(uint40).max;
    }
}

/// @title RegistrySpokeImplMock
/// @notice Stands for the audited standard Spoke implementation: its code hash is what `deployCdpSpoke` compares.
contract RegistrySpokeImplMock {
    function version() external pure returns (uint256) {
        return 1;
    }
}

/// @title RegistrySpokeMock
/// @notice The Aave V4 Spoke reads the MarketRegistry makes, backed by settable storage.
contract RegistrySpokeMock {
    address public ORACLE;
    bytes32 public implSlotValue;
    mapping(uint256 => IAaveV4Spoke.Reserve) internal _reserves;
    mapping(uint256 => IAaveV4Spoke.ReserveConfig) internal _configs;
    mapping(uint256 => mapping(uint32 => IAaveV4Spoke.DynamicReserveConfig)) internal _dynamic;
    mapping(address => mapping(uint256 => uint256)) internal _reserveIdOf;
    mapping(address => mapping(uint256 => bool)) internal _hasReserve;
    IAaveV4Spoke.LiquidationConfig internal _liq;
    bool internal _extSloadReverts;

    function setOracle(
        address o
    ) external {
        ORACLE = o;
    }

    function setImplementation(
        address impl
    ) external {
        implSlotValue = bytes32(uint256(uint160(impl)));
    }

    function setReserve(
        uint256 id,
        IAaveV4Spoke.Reserve memory r,
        IAaveV4Spoke.ReserveConfig memory c,
        IAaveV4Spoke.DynamicReserveConfig memory d
    ) external {
        _reserves[id] = r;
        _configs[id] = c;
        _dynamic[id][r.dynamicConfigKey] = d;
        _reserveIdOf[r.hub][r.assetId] = id;
        _hasReserve[r.hub][r.assetId] = true;
    }

    function setConfig(
        uint256 id,
        IAaveV4Spoke.ReserveConfig memory c
    ) external {
        _configs[id] = c;
    }

    function setDynamic(
        uint256 id,
        IAaveV4Spoke.DynamicReserveConfig memory d
    ) external {
        _dynamic[id][_reserves[id].dynamicConfigKey] = d;
    }

    function setLiquidationConfig(
        uint128 target,
        uint16 bonusFactor
    ) external {
        _liq.targetHealthFactor = target;
        _liq.liquidationBonusFactor = bonusFactor;
    }

    function setRevertExtSload(
        bool on
    ) external {
        _extSloadReverts = on;
    }

    function extSload(
        bytes32
    ) external view returns (bytes32) {
        require(!_extSloadReverts, "extSload");
        return implSlotValue;
    }

    function getReserve(
        uint256 id
    ) external view returns (IAaveV4Spoke.Reserve memory) {
        require(_reserves[id].underlying != address(0), "ReserveNotListed");
        return _reserves[id];
    }

    function getReserveConfig(
        uint256 id
    ) external view returns (IAaveV4Spoke.ReserveConfig memory) {
        return _configs[id];
    }

    function getDynamicReserveConfig(
        uint256 id,
        uint32 key
    ) external view returns (IAaveV4Spoke.DynamicReserveConfig memory) {
        return _dynamic[id][key];
    }

    function getReserveId(
        address hub,
        uint256 assetId
    ) external view returns (uint256) {
        require(_hasReserve[hub][assetId], "ReserveNotListed");
        return _reserveIdOf[hub][assetId];
    }

    function getLiquidationConfig() external view returns (IAaveV4Spoke.LiquidationConfig memory) {
        return _liq;
    }
}

/// @title RegistryAaveOracleMock
/// @notice An AaveOracle: the Spoke it serves, its decimals and per-reserve sources.
contract RegistryAaveOracleMock {
    address public spoke;
    uint8 public decimals = 8;
    mapping(uint256 => address) public getReserveSource;

    function setSpoke(
        address s
    ) external {
        spoke = s;
    }

    function setDecimals(
        uint8 d
    ) external {
        decimals = d;
    }

    function setSource(
        uint256 reserveId,
        address source
    ) external {
        getReserveSource[reserveId] = source;
    }
}
