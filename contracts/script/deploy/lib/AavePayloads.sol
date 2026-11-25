// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {DeployBase} from "./DeployBase.sol";
import {console2} from "forge-std/console2.sol";
import {SSTORE2} from "solady/utils/SSTORE2.sol";

// ABI mirrors of Aave's config-engine structs (`IAaveV4ConfigEngine`, a3ef63e), field for field with contract types as
// addresses: the scripts build these, `abi.encode` them as `AvanaAaveActions`, and `AvanaAaveV4Payload` decodes the
// same bytes into Aave's own types. Keeping Aave's source units out of the scripts keeps one definition of each type.
struct AInterestRateData {
    uint16 optimalUsageRatio;
    uint32 baseDrawnRate;
    uint32 rateGrowthBeforeOptimal;
    uint32 rateGrowthAfterOptimal;
}

struct ATokenizationSpokeConfig {
    uint256 addCap;
    address proxyAdminOwner;
    string name;
    string symbol;
}

struct AAssetListing {
    address hubConfigurator;
    address hub;
    address underlying;
    address feeReceiver;
    uint256 liquidityFee;
    address irStrategy;
    AInterestRateData irData;
    ATokenizationSpokeConfig tokenization;
}

struct ASpokeConfig {
    uint40 addCap;
    uint40 drawCap;
    uint24 riskPremiumThreshold;
    bool active;
    bool halted;
}

struct ASpokeAssetConfig {
    address underlying;
    ASpokeConfig config;
}

struct ASpokeToAssetsAddition {
    address hubConfigurator;
    address hub;
    address spoke;
    ASpokeAssetConfig[] assets;
}

struct ASpokeConfigUpdate {
    address hubConfigurator;
    address hub;
    address underlying;
    address spoke;
    uint256 addCap;
    uint256 drawCap;
    uint256 riskPremiumThreshold;
    uint256 active;
    uint256 halted;
}

struct AReserveConfig {
    uint24 collateralRisk;
    bool paused;
    bool frozen;
    bool borrowable;
    bool receiveSharesEnabled;
}

struct ADynamicReserveConfig {
    uint16 collateralFactor;
    uint32 maxLiquidationBonus;
    uint16 liquidationFee;
}

struct AReserveListing {
    address spokeConfigurator;
    address spoke;
    address hub;
    address underlying;
    address priceSource;
    AReserveConfig config;
    ADynamicReserveConfig dynamicConfig;
}

struct AReserveConfigUpdate {
    address spokeConfigurator;
    address spoke;
    address hub;
    address underlying;
    address priceSource;
    uint256 collateralRisk;
    uint256 paused;
    uint256 frozen;
    uint256 borrowable;
    uint256 receiveSharesEnabled;
}

struct ALiquidationConfigUpdate {
    address spokeConfigurator;
    address spoke;
    uint256 targetHealthFactor;
    uint256 healthFactorForMaxBonus;
    uint256 liquidationBonusFactor;
}

struct ARoleMembership {
    address authority;
    uint64 roleId;
    address account;
    bool granted;
    uint32 executionDelay;
}

struct ARoleUpdate {
    address authority;
    uint64 roleId;
    uint64 admin;
    uint64 guardian;
    uint32 grantDelay;
    string label;
    bool labelUpdate;
}

struct ATargetFunctionRoleUpdate {
    address authority;
    address target;
    bytes4[] selectors;
    uint64 roleId;
}

/// @notice ABI mirror of `IAaveV4ConfigEngine.AssetConfigUpdate` (rate curve, fee and reinvestment of a Hub asset).
struct AAssetConfigUpdate {
    address hubConfigurator;
    address hub;
    address underlying;
    uint256 liquidityFee;
    address feeReceiver;
    address irStrategy;
    AInterestRateData irData;
    address reinvestmentController;
}

struct APostCall {
    address target;
    bytes data;
}

/// @notice ABI mirror of `AvanaAaveActions` (script/deploy/aave/AvanaAaveV4Payload.sol), same field order.
struct AActions {
    ARoleMembership[] roleMemberships;
    ARoleUpdate[] roleUpdates;
    ATargetFunctionRoleUpdate[] targetFunctionRoleUpdates;
    AAssetListing[] assetListings;
    ASpokeToAssetsAddition[] spokeToAssetsAdditions;
    ASpokeConfigUpdate[] spokeConfigUpdates;
    AReserveListing[] reserveListings;
    AReserveConfigUpdate[] reserveConfigUpdates;
    ALiquidationConfigUpdate[] liquidationConfigUpdates;
    APostCall[] postCalls;
    AAssetConfigUpdate[] assetConfigUpdates;
}

/// @notice The Hub limits a payload builder reads.
interface IAaveHubLimits {
    function MAX_ALLOWED_SPOKE_CAP() external view returns (uint40);
    function MAX_RISK_PREMIUM_THRESHOLD() external view returns (uint24);
    function getAssetId(
        address underlying
    ) external view returns (uint256);
}

/// @notice The Aave V4 views the AIP builders read to leave out what is already on chain.
interface IAaveListedViews {
    function isUnderlyingListed(
        address underlying
    ) external view returns (bool);
    function isSpokeListed(
        uint256 assetId,
        address spoke
    ) external view returns (bool);
    function getReserveConfig(
        uint256 reserveId
    ) external view returns (AReserveConfig memory);
    function getReserveId(
        address hub,
        uint256 assetId
    ) external view returns (uint256);
}

/// @notice Aave's `EngineFlags` sentinels (a3ef63e `src/config-engine/libraries/EngineFlags.sol`).
library AFlags {
    uint256 internal constant KEEP_CURRENT = type(uint256).max - 652;
    address internal constant KEEP_CURRENT_ADDRESS = address(type(uint160).max);
    uint64 internal constant KEEP_CURRENT_UINT64 = type(uint64).max - 46;
    uint32 internal constant KEEP_CURRENT_UINT32 = type(uint32).max - 23;
}

/// @notice Aave governance v3's executor entry point (`Executor.executeTransaction`).
interface IAaveExecutor {
    function executeTransaction(
        address target,
        uint256 value,
        string calldata signature,
        bytes calldata data,
        bool withDelegatecall
    ) external payable returns (bytes memory);
}

/// @title AavePayloads
/// @notice Builds, deploys and (on test networks) executes the Aave-side AIPs as Aave does: an `AvanaAaveV4Payload` on
/// Aave's config engine, run by the governance executor through `executeTransaction(payload, 0, "execute()", "", true)`
/// from the PayloadsController (on anvil a stand-in account). Each AIP's actions are also written to
/// `deployments-local/<network>/aip-<name>.json` for the review and for the literal payload of the Aave proposals
/// repository on Ethereum and Base.
/// @dev Actions are collected in fixed-capacity arrays and trimmed before encoding. The payload's data is split into
/// SSTORE2 chunks below EIP-170.
abstract contract AavePayloads is DeployBase {
    uint256 internal constant CAPACITY = 128;
    uint256 internal constant CHUNK_BYTES = 24_000;

    struct Builder {
        AActions a;
        uint256[11] n;
    }

    function _newBuilder() internal pure returns (Builder memory b) {
        b.a.roleMemberships = new ARoleMembership[](CAPACITY);
        b.a.roleUpdates = new ARoleUpdate[](CAPACITY);
        b.a.targetFunctionRoleUpdates = new ATargetFunctionRoleUpdate[](CAPACITY);
        b.a.assetListings = new AAssetListing[](CAPACITY);
        b.a.spokeToAssetsAdditions = new ASpokeToAssetsAddition[](CAPACITY);
        b.a.spokeConfigUpdates = new ASpokeConfigUpdate[](CAPACITY);
        b.a.reserveListings = new AReserveListing[](CAPACITY);
        b.a.reserveConfigUpdates = new AReserveConfigUpdate[](CAPACITY);
        b.a.liquidationConfigUpdates = new ALiquidationConfigUpdate[](CAPACITY);
        b.a.postCalls = new APostCall[](CAPACITY);
        b.a.assetConfigUpdates = new AAssetConfigUpdate[](CAPACITY);
    }

    function _roleMembership(
        Builder memory b,
        ARoleMembership memory x
    ) internal pure {
        b.a.roleMemberships[b.n[0]++] = x;
    }

    function _roleUpdate(
        Builder memory b,
        ARoleUpdate memory x
    ) internal pure {
        b.a.roleUpdates[b.n[1]++] = x;
    }

    function _targetFunctionRole(
        Builder memory b,
        ATargetFunctionRoleUpdate memory x
    ) internal pure {
        b.a.targetFunctionRoleUpdates[b.n[2]++] = x;
    }

    function _assetListing(
        Builder memory b,
        AAssetListing memory x
    ) internal pure {
        b.a.assetListings[b.n[3]++] = x;
    }

    function _spokeToAssets(
        Builder memory b,
        ASpokeToAssetsAddition memory x
    ) internal pure {
        b.a.spokeToAssetsAdditions[b.n[4]++] = x;
    }

    function _spokeConfigUpdate(
        Builder memory b,
        ASpokeConfigUpdate memory x
    ) internal pure {
        b.a.spokeConfigUpdates[b.n[5]++] = x;
    }

    function _reserveListing(
        Builder memory b,
        AReserveListing memory x
    ) internal pure {
        b.a.reserveListings[b.n[6]++] = x;
    }

    function _reserveConfigUpdate(
        Builder memory b,
        AReserveConfigUpdate memory x
    ) internal pure {
        b.a.reserveConfigUpdates[b.n[7]++] = x;
    }

    function _liquidationConfigUpdate(
        Builder memory b,
        ALiquidationConfigUpdate memory x
    ) internal pure {
        b.a.liquidationConfigUpdates[b.n[8]++] = x;
    }

    function _postCall(
        Builder memory b,
        address target,
        bytes memory data
    ) internal pure {
        b.a.postCalls[b.n[9]++] = APostCall(target, data);
    }

    /// @notice A `ReserveConfigUpdate` that changes nothing until its fields are set.
    function _keepReserveConfig() internal pure returns (AReserveConfigUpdate memory u) {
        u.priceSource = AFlags.KEEP_CURRENT_ADDRESS;
        u.collateralRisk = AFlags.KEEP_CURRENT;
        u.paused = AFlags.KEEP_CURRENT;
        u.frozen = AFlags.KEEP_CURRENT;
        u.borrowable = AFlags.KEEP_CURRENT;
        u.receiveSharesEnabled = AFlags.KEEP_CURRENT;
    }

    /// @notice A `SpokeConfigUpdate` that changes nothing until its fields are set.
    function _keepSpokeConfig() internal pure returns (ASpokeConfigUpdate memory u) {
        u.addCap = AFlags.KEEP_CURRENT;
        u.drawCap = AFlags.KEEP_CURRENT;
        u.riskPremiumThreshold = AFlags.KEEP_CURRENT;
        u.active = AFlags.KEEP_CURRENT;
        u.halted = AFlags.KEEP_CURRENT;
    }

    function _trim(
        Builder memory b
    ) internal pure returns (AActions memory a) {
        a = b.a;
        uint256[11] memory n = b.n;
        assembly ("memory-safe") {
            // Each field of `a` is a pointer to an array whose first word is its length.
            for { let i := 0 } lt(i, 11) { i := add(i, 1) } {
                mstore(mload(add(a, mul(i, 0x20))), mload(add(n, mul(i, 0x20))))
            }
        }
    }

    /// @notice On a test network (`execute`), deploys the AIP `name` (its data chunks and the payload, from `deployer`, the
    /// DAO-side deployer) and runs it through `executor` as `controller`; on Ethereum and Base only writes its actions.
    function _empty(
        Builder memory b,
        string memory name
    ) private pure returns (bool) {
        uint256 actions;
        for (uint256 i = 0; i < b.n.length; ++i) {
            actions += b.n[i];
        }
        if (actions == 0) {
            console2.log(string.concat("AIP ", name, ": nothing to propose, everything in the config is on chain"));
        }
        return actions == 0;
    }

    function _shipPayload(
        string memory name,
        Builder memory b,
        address configEngine,
        address executor,
        address controller,
        bool execute
    ) internal returns (address payload) {
        // Each AIP carries only what the config adds to Aave's side; with nothing new there is no AIP.
        if (_empty(b, name)) return address(0);
        bytes memory data = abi.encode(_trim(b));
        string memory k = string.concat("aip.", name);
        vm.serializeString(k, "name", name);
        vm.serializeAddress(k, "configEngine", configEngine);
        vm.serializeAddress(k, "executor", executor);
        if (!execute) {
            vm.writeJson(vm.serializeBytes(k, "actions", data), _outputPath(string.concat("aip-", name)));
            console2.log(string.concat("AIP ", name, ": actions written for the AIP author"), data.length);
            return address(0);
        }
        uint256 chunks = (data.length + CHUNK_BYTES - 1) / CHUNK_BYTES;
        address[] memory pointers = new address[](chunks);
        vm.startBroadcast(deployer);
        for (uint256 i = 0; i < chunks; ++i) {
            uint256 start = i * CHUNK_BYTES;
            uint256 end = start + CHUNK_BYTES > data.length ? data.length : start + CHUNK_BYTES;
            pointers[i] = SSTORE2.write(_slice(data, start, end));
        }
        payload = _deploy(
            string.concat("AIP.", name),
            bytes.concat(_artifact("AvanaAaveV4Payload.sol", "AvanaAaveV4Payload"), abi.encode(configEngine, pointers))
        );
        vm.stopBroadcast();
        vm.serializeAddress(k, "payload", payload);
        vm.serializeAddress(k, "dataChunks", pointers);
        string memory json = vm.serializeBytes(k, "actions", data);
        vm.writeJson(json, _outputPath(string.concat("aip-", name)));
        console2.log(string.concat("AIP ", name, " payload"), payload, data.length);
        vm.broadcast(controller);
        IAaveExecutor(executor).executeTransaction(payload, 0, "execute()", "", true);
        console2.log("executed by the governance executor", executor);
    }

    function _slice(
        bytes memory data,
        uint256 start,
        uint256 end
    ) private pure returns (bytes memory out) {
        out = new bytes(end - start);
        for (uint256 i = start; i < end; ++i) {
            out[i - start] = data[i];
        }
    }
}
