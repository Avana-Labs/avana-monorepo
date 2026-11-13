// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IMarketRegistry} from "../../../src/policy/market-registry/IMarketRegistry.sol";
import {IParameterStore} from "../../../src/policy/parameter-store/IParameterStore.sol";
import {FeedDef} from "../../../src/policy/parameter-store/types/FeedDef.sol";
import {OracleLeg} from "../../../src/types/OracleLeg.sol";
import {OracleRoute} from "../../../src/types/OracleRoute.sol";
import {SecondSource} from "../../../src/types/SecondSource.sol";
import {SecondSourceKind} from "../../../src/types/SecondSourceKind.sol";
import {DeployBase} from "./DeployBase.sol";
import {TimelockOperations} from "./TimelockOperations.sol";

interface IPoolTokens {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function tickSpacing() external view returns (int24);
}

interface IReserveIds {
    function getReserveId(
        address hub,
        uint256 assetId
    ) external view returns (uint256);
}

interface IHubAssetIds {
    function getAssetId(
        address underlying
    ) external view returns (uint256);
}

/// @title ListingBase
/// @notice Shared reads of the listing steps (`09_ListMarkets`, `10_AaveListingPayload`): the network config's
/// `listing` section, Avana's deploy output and the feed, route and second-source definitions every listed token gets.
/// Every token, feed, pool, Hub and Spoke address comes from the config, as a literal on a network where the Aave DAO
/// deployed Aave V4 itself or as a `$aave:` / `$world:` reference to the test-network deployment, so the Avana
/// listing never depends on how Aave's side was deployed.
/// @dev Feed roles in `world.json`: `primary`, `alternate` and `standby` are the token's three price routes (one feed
/// each, no feed shared, `REQ-CONFIG-018`); `second` is its oracle-network second source, a feed in none of its routes.
abstract contract ListingBase is TimelockOperations, DeployBase {
    string internal cfg;
    string internal avanaJson;
    address internal timelock;
    IMarketRegistry internal registry;
    IParameterStore internal store;

    function _loadListing() internal {
        cfg = vm.readFile(string.concat(vm.projectRoot(), "/script/deploy/config/", _network(), ".json"));
        avanaJson = vm.readFile(_outputPath("avana"));
        timelock = vm.parseJsonAddress(avanaJson, ".timelock");
        registry = IMarketRegistry(vm.parseJsonAddress(avanaJson, ".marketRegistry.proxy"));
        store = IParameterStore(vm.parseJsonAddress(avanaJson, ".parameterStore.proxy"));
        release = vm.parseJsonString(avanaJson, ".release");
    }

    // ─── Config and outputs ───

    function _str(
        string memory path
    ) internal view returns (string memory) {
        return vm.parseJsonString(cfg, path);
    }

    function _uint(
        string memory path
    ) internal view returns (uint256) {
        return vm.parseJsonUint(cfg, path);
    }

    function _bool(
        string memory path
    ) internal view returns (bool) {
        return vm.parseJsonBool(cfg, path);
    }

    function _at(
        string memory list,
        uint256 i
    ) internal pure returns (string memory) {
        return string.concat(".listing.", list, "[", vm.toString(i), "]");
    }

    /// @notice The `listing.tokens` or `listing.debtAssets` entry of a symbol.
    function _symbolKey(
        string memory symbol
    ) internal view returns (string memory) {
        string[2] memory lists = ["tokens", "debtAssets"];
        for (uint256 l = 0; l < 2; ++l) {
            uint256 n = _count(cfg, string.concat(".listing.", lists[l]));
            for (uint256 i = 0; i < n; ++i) {
                if (_eq(_str(string.concat(_at(lists[l], i), ".symbol")), symbol)) return _at(lists[l], i);
            }
        }
        revert(string.concat("no listing entry for ", symbol));
    }

    /// @notice A listed token's address: a literal in the config, or a `$world:` reference on test networks.
    function _token(
        string memory symbol
    ) internal view returns (address) {
        return _addr(cfg, string.concat(_symbolKey(symbol), ".address"));
    }

    /// @notice A listed token's Chainlink feed of `role` (`primary`, `alternate`, `standby`, `second`).
    function _feed(
        string memory symbol,
        string memory role
    ) internal view returns (address) {
        return _addr(cfg, string.concat(_symbolKey(symbol), ".feeds.", role));
    }

    /// @notice An Avana Hub by its config label (`aave.hubs[].label`).
    function _hub(
        string memory label
    ) internal view returns (address) {
        uint256 n = _count(cfg, ".aave.hubs");
        for (uint256 i = 0; i < n; ++i) {
            string memory k = string.concat(".aave.hubs[", vm.toString(i), "]");
            if (_eq(_str(string.concat(k, ".label")), label)) return _addr(cfg, string.concat(k, ".hub"));
        }
        revert(string.concat("no aave.hubs entry for ", label));
    }

    /// @notice A CDP Spoke by its label (`listing.spokes[].spoke`): Aave's deployment, Avana only records it.
    function _spokeAddr(
        string memory label
    ) internal view returns (address) {
        return _addr(cfg, string.concat(_spokeKey(label), ".spoke"));
    }

    /// @notice The implementation behind a Spoke's ERC-1967 proxy, read from the chain.
    function _implementationOf(
        address proxy
    ) internal view returns (address) {
        return address(
            uint160(uint256(vm.load(proxy, 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc)))
        );
    }

    /// @notice The `listing.spokes` entry of a CDP Spoke label.
    function _spokeKey(
        string memory label
    ) internal view returns (string memory) {
        uint256 n = _count(cfg, ".listing.spokes");
        for (uint256 i = 0; i < n; ++i) {
            if (_eq(_str(string.concat(_at("spokes", i), ".label")), label)) return _at("spokes", i);
        }
        revert(string.concat("no listing.spokes entry for ", label));
    }

    function _hubOfSpoke(
        string memory label
    ) internal view returns (string memory) {
        return _str(string.concat(_spokeKey(label), ".hub"));
    }

    /// @notice A pool by name (`listing.pools`).
    function _pool(
        string memory name
    ) internal view returns (address) {
        return _addr(cfg, string.concat(".listing.pools['", name, "']"));
    }

    /// @notice The current 8-decimal answer of a token's primary feed (the listing valuation price).
    function _price8(
        address token
    ) internal view returns (uint256) {
        (, int256 answer,,,) = IFeedRead(_feedOfToken(token)).latestRoundData();
        return uint256(answer);
    }

    function _feedOfToken(
        address token
    ) internal view returns (address) {
        string[3] memory symbols = _listedSymbols();
        for (uint256 i = 0; i < symbols.length; ++i) {
            if (_token(symbols[i]) == token) return _feed(symbols[i], "primary");
        }
        revert("token is not a listed pool token");
    }

    function _listedSymbols() internal view returns (string[3] memory s) {
        require(_count(cfg, ".listing.tokens") == 3, "listing.tokens: three pool tokens");
        for (uint256 i = 0; i < 3; ++i) {
            s[i] = _str(string.concat(_at("tokens", i), ".symbol"));
        }
    }

    /// @notice The `listing.tokens` key of a pool token, or "" when it is not one.
    function _tokenKey(
        address token
    ) internal view returns (string memory) {
        uint256 n = _count(cfg, ".listing.tokens");
        for (uint256 i = 0; i < n; ++i) {
            if (_token(_str(string.concat(_at("tokens", i), ".symbol"))) == token) return _at("tokens", i);
        }
        return "";
    }

    // ─── Feed, route and second-source definitions ───

    function _maxAge() internal view returns (uint32) {
        return uint32(_uint(".listing.feed.heartbeat") + _uint(".listing.feed.heartbeatMargin"));
    }

    /// @notice The ParameterStore feed definition of one feed (`setFeed`): heartbeat, margin and their sum as every
    /// age; decimals and answer bounds are read on-chain by the store.
    function _feedDef(
        uint16 deviationBps
    ) internal view returns (FeedDef memory d) {
        d.decimals = 8;
        d.minAnswer = 1;
        d.maxAnswer = 1e18;
        d.feedHeartbeat = uint32(_uint(".listing.feed.heartbeat"));
        d.heartbeatMargin = uint32(_uint(".listing.feed.heartbeatMargin"));
        d.feedMaxAge = _maxAge();
        d.feedDeviationThresholdBps = deviationBps;
        d.heartbeatDriftBps = uint16(_uint(".listing.feed.driftBps"));
        d.borrowPriceMaxAge = _maxAge();
        d.liquidationPriceMaxAge = _maxAge();
        d.maxAnswerCap = int256(vm.parseUint(_str(".listing.feed.maxAnswerCap")));
    }

    /// @notice A one-leg LPOracle route over `feed`, matching its ParameterStore definition.
    function _route(
        address feed,
        uint16 deviationBps
    ) internal view returns (OracleRoute memory r) {
        r.legCount = 1;
        r.legs[0] = OracleLeg({
            aggregator: feed,
            decimals: 8,
            heartbeat: uint32(_uint(".listing.feed.heartbeat")),
            heartbeatMargin: uint16(_uint(".listing.feed.heartbeatMargin")),
            feedDeviationThresholdBps: deviationBps,
            minAnswer: 1,
            maxAnswer: 1e18,
            borrowPriceMaxAge: _maxAge(),
            liquidationPriceMaxAge: _maxAge()
        });
    }

    /// @notice The oracle-network second source of a pool token: its `second` feed.
    function _secondSource(
        string memory key
    ) internal view returns (SecondSource memory s) {
        s = SecondSource({
            kind: SecondSourceKind.OracleNetwork,
            source: _feed(_str(string.concat(key, ".symbol")), "second"),
            poolRef: bytes32(0),
            maxAge: _maxAge(),
            twapWindow: 0,
            toleranceBps: uint16(_uint(string.concat(key, ".secondToleranceBps")))
        });
    }

    function _one(
        address a
    ) internal pure returns (address[] memory list) {
        list = new address[](1);
        list[0] = a;
    }

    /// @notice The Hub asset and the CDP Spoke reserve of `asset`.
    function _reserveOf(
        string memory spokeLabel,
        address asset
    ) internal view returns (address hub, uint256 assetId, uint256 reserveId) {
        hub = _hub(_hubOfSpoke(spokeLabel));
        assetId = IHubAssetIds(hub).getAssetId(asset);
        reserveId = IReserveIds(_spokeAddr(spokeLabel)).getReserveId(hub, assetId);
    }
}

interface IFeedRead {
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80);
}
