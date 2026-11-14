// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

// IAaveV4ConfigEngine is taken through AaveV4Payload.sol's own import so both name one source unit.
import {AaveV4Payload, IAaveV4ConfigEngine} from "aave-v4/config-engine/AaveV4Payload.sol";

/// @notice The config-engine actions of one Avana AIP, plus the plain calls its `_postExecute` makes as the executor
/// (treasury funding and the loss layers' administration, which the engine has no action for).
struct AvanaAaveActions {
    IAaveV4ConfigEngine.RoleMembership[] roleMemberships;
    IAaveV4ConfigEngine.RoleUpdate[] roleUpdates;
    IAaveV4ConfigEngine.TargetFunctionRoleUpdate[] targetFunctionRoleUpdates;
    IAaveV4ConfigEngine.AssetListing[] assetListings;
    IAaveV4ConfigEngine.SpokeToAssetsAddition[] spokeToAssetsAdditions;
    IAaveV4ConfigEngine.SpokeConfigUpdate[] spokeConfigUpdates;
    IAaveV4ConfigEngine.ReserveListing[] reserveListings;
    IAaveV4ConfigEngine.ReserveConfigUpdate[] reserveConfigUpdates;
    IAaveV4ConfigEngine.LiquidationConfigUpdate[] liquidationConfigUpdates;
    AvanaPostCall[] postCalls;
    IAaveV4ConfigEngine.AssetConfigUpdate[] assetConfigUpdates;
}

/// @notice One call `_postExecute` makes from the executor.
struct AvanaPostCall {
    address target;
    bytes data;
}

/// @title AvanaAaveV4Payload
/// @notice An Aave V4 governance payload on Aave's own config engine (`AaveV4Payload`, a3ef63e): the governance executor
/// runs `execute()` by `delegatecall`, the engine applies the AccessManager, Hub and Spoke actions in its fixed order and
/// `_postExecute` makes the payload's plain calls, all from the executor. One reviewed contract serves every Avana AIP;
/// each instance reads its actions, ABI-encoded as `AvanaAaveActions`, from immutable data contracts (SSTORE2 chunks,
/// the code after a leading STOP byte), because a payload's storage is not readable inside the executor's context.
/// @dev On Ethereum and Base the AIP author ports the same actions into a literal payload in the Aave proposals
/// repository; the deploy scripts write the decoded action list next to the instance for that review.
contract AvanaAaveV4Payload is AaveV4Payload {
    uint256 internal constant MAX_CHUNKS = 4;

    address internal immutable CHUNK_0;
    address internal immutable CHUNK_1;
    address internal immutable CHUNK_2;
    address internal immutable CHUNK_3;
    uint256 internal immutable CHUNK_COUNT;

    error TooManyChunks();
    error PostCallFailed(uint256 index, bytes reason);

    /// @param configEngine_ The chain's `AaveV4ConfigEngine`.
    /// @param chunks Data contracts whose code, after the first byte, concatenates to `abi.encode(AvanaAaveActions)`.
    constructor(
        IAaveV4ConfigEngine configEngine_,
        address[] memory chunks
    ) AaveV4Payload(configEngine_) {
        if (chunks.length == 0 || chunks.length > MAX_CHUNKS) revert TooManyChunks();
        CHUNK_COUNT = chunks.length;
        CHUNK_0 = chunks[0];
        CHUNK_1 = chunks.length > 1 ? chunks[1] : address(0);
        CHUNK_2 = chunks.length > 2 ? chunks[2] : address(0);
        CHUNK_3 = chunks.length > 3 ? chunks[3] : address(0);
    }

    /// @notice The payload's actions.
    function actions() public view returns (AvanaAaveActions memory a) {
        bytes memory data;
        address[4] memory c = [CHUNK_0, CHUNK_1, CHUNK_2, CHUNK_3];
        for (uint256 i = 0; i < CHUNK_COUNT; ++i) {
            data = bytes.concat(data, _read(c[i]));
        }
        a = abi.decode(data, (AvanaAaveActions));
    }

    function accessManagerRoleMemberships() public view override returns (IAaveV4ConfigEngine.RoleMembership[] memory) {
        return actions().roleMemberships;
    }

    function accessManagerRoleUpdates() public view override returns (IAaveV4ConfigEngine.RoleUpdate[] memory) {
        return actions().roleUpdates;
    }

    function accessManagerTargetFunctionRoleUpdates()
        public
        view
        override
        returns (IAaveV4ConfigEngine.TargetFunctionRoleUpdate[] memory)
    {
        return actions().targetFunctionRoleUpdates;
    }

    function hubAssetListings() public view override returns (IAaveV4ConfigEngine.AssetListing[] memory) {
        return actions().assetListings;
    }

    function hubAssetConfigUpdates() public view override returns (IAaveV4ConfigEngine.AssetConfigUpdate[] memory) {
        return actions().assetConfigUpdates;
    }

    function hubSpokeToAssetsAdditions()
        public
        view
        override
        returns (IAaveV4ConfigEngine.SpokeToAssetsAddition[] memory)
    {
        return actions().spokeToAssetsAdditions;
    }

    function hubSpokeConfigUpdates() public view override returns (IAaveV4ConfigEngine.SpokeConfigUpdate[] memory) {
        return actions().spokeConfigUpdates;
    }

    function spokeReserveListings() public view override returns (IAaveV4ConfigEngine.ReserveListing[] memory) {
        return actions().reserveListings;
    }

    function spokeReserveConfigUpdates()
        public
        view
        override
        returns (IAaveV4ConfigEngine.ReserveConfigUpdate[] memory)
    {
        return actions().reserveConfigUpdates;
    }

    function spokeLiquidationConfigUpdates()
        public
        view
        override
        returns (IAaveV4ConfigEngine.LiquidationConfigUpdate[] memory)
    {
        return actions().liquidationConfigUpdates;
    }

    /// @dev The plain calls, in order, from the executor (this code runs by `delegatecall` in its context).
    function _postExecute() internal override {
        AvanaPostCall[] memory calls = actions().postCalls;
        for (uint256 i = 0; i < calls.length; ++i) {
            (bool ok, bytes memory ret) = calls[i].target.call(calls[i].data);
            if (!ok) revert PostCallFailed(i, ret);
        }
    }

    function _read(
        address pointer
    ) private view returns (bytes memory data) {
        uint256 size = pointer.code.length;
        if (size <= 1) return data;
        data = new bytes(size - 1);
        assembly ("memory-safe") {
            extcodecopy(pointer, add(data, 0x20), 1, sub(size, 1))
        }
    }
}
