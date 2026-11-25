// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAaveV4Spoke} from "../../../src/dependencies/aave/IAaveV4Spoke.sol";

/// @notice The two `AaveOracle` calls the stand-in makes.
interface IAaveOracleSpokeAdmin {
    function setReserveSource(
        uint256 reserveId,
        address source
    ) external;
}

/// @title AaveV4PriceSpokeStandIn
/// @notice Test-network stand-in for Aave's main V4 Spoke, the price Spoke of every CDP Spoke: the real pinned
/// `AaveOracle` (deployed from `out-aave/` and bound to this contract) prices each world token's reserve from the
/// token's primary feed, each reserve carries the dynamic config (collateral factor, max liquidation bonus) and the
/// Spoke carries the liquidation config Avana's listing copies. Only the reads Avana makes are served. Listed as a
/// stand-in in `contracts/deployments/README.md`; on Ethereum and Base the price Spokes are Aave's own.
/// @dev Reserve IDs are assigned in order as `Spoke.addReserve` does. Only the owner (the world's deployer) lists.
contract AaveV4PriceSpokeStandIn {
    address public immutable ORACLE;
    address public immutable OWNER;
    uint256 public getReserveCount;
    mapping(uint256 reserveId => IAaveV4Spoke.Reserve) internal _reserves;
    mapping(uint256 reserveId => IAaveV4Spoke.DynamicReserveConfig) internal _dynamic;
    IAaveV4Spoke.LiquidationConfig internal _liquidation;

    constructor(
        address oracle,
        address owner
    ) {
        ORACLE = oracle;
        OWNER = owner;
    }

    modifier onlyOwner() {
        require(msg.sender == OWNER, "owner");
        _;
    }

    /// @notice Lists `underlying` with `decimals` priced by `source` (set through the AaveOracle, which checks its
    /// decimals and price) and its dynamic config.
    function addReserve(
        address underlying,
        uint8 decimals,
        address source,
        IAaveV4Spoke.DynamicReserveConfig calldata config
    ) external onlyOwner returns (uint256 reserveId) {
        reserveId = getReserveCount++;
        _reserves[reserveId] = IAaveV4Spoke.Reserve({
            underlying: underlying,
            hub: address(0),
            // forge-lint: disable-next-line(unsafe-typecast)
            assetId: uint16(reserveId),
            decimals: decimals,
            collateralRisk: 0,
            flags: 0,
            dynamicConfigKey: 0
        });
        _dynamic[reserveId] = config;
        IAaveOracleSpokeAdmin(ORACLE).setReserveSource(reserveId, source);
    }

    /// @notice `Spoke.updateReservePriceSource`, for drills of a source Aave governance swaps.
    function updateReservePriceSource(
        uint256 reserveId,
        address source
    ) external onlyOwner {
        require(reserveId < getReserveCount, "ReserveNotListed");
        IAaveOracleSpokeAdmin(ORACLE).setReserveSource(reserveId, source);
    }

    function setLiquidationConfig(
        IAaveV4Spoke.LiquidationConfig calldata config
    ) external onlyOwner {
        _liquidation = config;
    }

    function getReserve(
        uint256 reserveId
    ) external view returns (IAaveV4Spoke.Reserve memory) {
        require(reserveId < getReserveCount, "ReserveNotListed");
        return _reserves[reserveId];
    }

    function getDynamicReserveConfig(
        uint256 reserveId,
        uint32
    ) external view returns (IAaveV4Spoke.DynamicReserveConfig memory) {
        require(reserveId < getReserveCount, "ReserveNotListed");
        return _dynamic[reserveId];
    }

    function getLiquidationConfig() external view returns (IAaveV4Spoke.LiquidationConfig memory) {
        return _liquidation;
    }
}
