// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IntegrationCapabilities} from "../../../src/amm/types/IntegrationCapabilities.sol";
import {PoolKeying} from "../../../src/amm/types/PoolKeying.sol";
import {ShapeKind} from "../../../src/types/ShapeKind.sol";

/// @title LPVaultIdentityMock
/// @notice Stand-in LPVault for the VaultTokenFactory: answers only the identity getters `registerIntegration` reads
/// (`INTEGRATION_ID`, `COLLATERALIZATION`, `LOCK`, `TIMELOCK`, `MARKET_REGISTRY`, `AMM_PROTOCOL`, `capabilities`).
/// @dev The identity is set at construction; `setTimelock`, `setRegistry` and `setKind` let a test build a mis-wired
/// LPVault. Defaults: a pool-address keyed `TickRange` integration.
contract LPVaultIdentityMock {
    uint32 public immutable INTEGRATION_ID;
    address public immutable COLLATERALIZATION;
    address public immutable LOCK;
    bytes32 public immutable AMM_PROTOCOL;
    address public TIMELOCK;
    address public MARKET_REGISTRY;
    PoolKeying internal _keying = PoolKeying.Address;
    ShapeKind internal _kind = ShapeKind.TickRange;
    /// @dev When set, `capabilities()` answers these raw bytes (a malformed answer); `rawRevert` makes it revert.
    bytes internal _raw;
    bool internal _rawRevert;

    constructor(
        uint32 integrationId,
        address collateralization,
        address lock,
        bytes32 ammProtocol,
        address timelock,
        address marketRegistry
    ) {
        INTEGRATION_ID = integrationId;
        COLLATERALIZATION = collateralization;
        LOCK = lock;
        AMM_PROTOCOL = ammProtocol;
        TIMELOCK = timelock;
        MARKET_REGISTRY = marketRegistry;
    }

    function setTimelock(
        address timelock
    ) external {
        TIMELOCK = timelock;
    }

    function setRegistry(
        address marketRegistry
    ) external {
        MARKET_REGISTRY = marketRegistry;
    }

    function setKind(
        PoolKeying keying,
        ShapeKind kind
    ) external {
        _keying = keying;
        _kind = kind;
    }

    function setRawCapabilities(
        bytes calldata raw,
        bool doRevert
    ) external {
        _raw = raw;
        _rawRevert = doRevert;
    }

    function capabilities() external view returns (IntegrationCapabilities memory caps) {
        if (_rawRevert) revert("capabilities");
        bytes memory raw = _raw;
        if (raw.length != 0) {
            // A malformed answer of any length, returned as is.
            assembly ("memory-safe") {
                return(add(raw, 0x20), mload(raw))
            }
        }
        caps.poolKeying = _keying;
        caps.shapeKind = _kind;
        caps.hasTwap = true;
    }
}
