// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ILPVault} from "../../../src/vault/interfaces/ILPVault.sol";
import {IAaveV4Hub} from "../../../src/dependencies/aave/IAaveV4Hub.sol";
import {IAaveV4Spoke} from "../../../src/dependencies/aave/IAaveV4Spoke.sol";

/// @notice The LPVault's `listMarket` and `getMarket` for one pool of chosen tokens and spacing.
contract RiskTestVault {
    address public immutable token0;
    address public immutable token1;
    int24 public spacing;
    mapping(uint256 => ILPVault.Market) internal _markets;

    constructor(
        address t0,
        address t1,
        int24 spacing_
    ) {
        (token0, token1, spacing) = (t0, t1, spacing_);
    }

    function listMarket(
        uint256 marketId,
        bytes32 pool,
        int24 bandLower,
        int24 bandUpper
    ) external {
        if (_markets[marketId].pool != bytes32(0)) revert ILPVault.InvalidMarketId(marketId);
        if (bandLower >= bandUpper || bandLower % spacing != 0 || bandUpper % spacing != 0) {
            revert ILPVault.InvalidBand(bandLower, bandUpper);
        }
        _markets[marketId] = ILPVault.Market(pool, token0, token1, bandLower, bandUpper, 0);
    }

    function getMarket(
        uint256 marketId
    ) external view returns (ILPVault.Market memory) {
        return _markets[marketId];
    }
}

/// @notice A Hub with settable asset IDs and Spoke draw caps.
contract RiskTestHub {
    uint40 public constant MAX_ALLOWED_SPOKE_CAP = type(uint40).max;
    mapping(address => uint256) internal _assetId;
    mapping(address => bool) internal _listed;
    mapping(uint256 => mapping(address => uint40)) internal _drawCap;

    function setAsset(
        address underlying,
        uint256 assetId
    ) external {
        (_assetId[underlying], _listed[underlying]) = (assetId, true);
    }

    function setDrawCap(
        uint256 assetId,
        address spoke,
        uint40 cap
    ) external {
        _drawCap[assetId][spoke] = cap;
    }

    function getAssetId(
        address underlying
    ) external view returns (uint256) {
        require(_listed[underlying], "not listed");
        return _assetId[underlying];
    }

    function getSpokeConfig(
        uint256 assetId,
        address spoke
    ) external view returns (IAaveV4Hub.SpokeConfig memory c) {
        c.drawCap = _drawCap[assetId][spoke];
    }
}

/// @notice A Spoke with settable reserves, configs and oracle.
contract RiskTestSpoke {
    address public ORACLE;
    mapping(uint256 => IAaveV4Spoke.Reserve) internal _reserves;
    mapping(uint256 => IAaveV4Spoke.ReserveConfig) internal _configs;
    mapping(uint256 => IAaveV4Spoke.DynamicReserveConfig) internal _dynamic;
    mapping(address => mapping(uint256 => uint256)) internal _ids;
    mapping(address => mapping(uint256 => bool)) internal _has;

    function setOracle(
        address oracle
    ) external {
        ORACLE = oracle;
    }

    function setReserve(
        uint256 reserveId,
        address underlying,
        address hub,
        uint16 assetId
    ) external {
        _reserves[reserveId].underlying = underlying;
        _reserves[reserveId].hub = hub;
        _reserves[reserveId].assetId = assetId;
        _ids[hub][assetId] = reserveId;
        _has[hub][assetId] = true;
    }

    function setReceiveShares(
        uint256 reserveId,
        bool on
    ) external {
        _configs[reserveId].receiveSharesEnabled = on;
    }

    function setDynamic(
        uint256 reserveId,
        uint16 collateralFactor,
        uint16 liquidationFee
    ) external {
        _dynamic[reserveId] = IAaveV4Spoke.DynamicReserveConfig(collateralFactor, 10_500, liquidationFee);
    }

    function getReserve(
        uint256 reserveId
    ) external view returns (IAaveV4Spoke.Reserve memory) {
        return _reserves[reserveId];
    }

    function getReserveConfig(
        uint256 reserveId
    ) external view returns (IAaveV4Spoke.ReserveConfig memory) {
        return _configs[reserveId];
    }

    function getDynamicReserveConfig(
        uint256 reserveId,
        uint32
    ) external view returns (IAaveV4Spoke.DynamicReserveConfig memory) {
        return _dynamic[reserveId];
    }

    function getReserveId(
        address hub,
        uint256 assetId
    ) external view returns (uint256) {
        require(_has[hub][assetId], "no reserve");
        return _ids[hub][assetId];
    }
}

/// @notice The Spoke oracle's `getReserveSource`.
contract RiskTestAaveOracle {
    mapping(uint256 => address) public getReserveSource;

    function setSource(
        uint256 reserveId,
        address source
    ) external {
        getReserveSource[reserveId] = source;
    }
}

/// @notice A First-Loss Reserve with a settable funded balance.
contract RiskTestFirstLossReserve {
    address public immutable ASSET;
    address public immutable HUB;
    uint256 public fundedBalance;

    constructor(
        address asset,
        address hub
    ) {
        (ASSET, HUB) = (asset, hub);
    }

    function setFunded(
        uint256 amount
    ) external {
        fundedBalance = amount;
    }
}
