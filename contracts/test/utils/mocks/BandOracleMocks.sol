// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAaveV4Spoke} from "../../../src/dependencies/aave/IAaveV4Spoke.sol";
import {ILPVault} from "../../../src/interfaces/ILPVault.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Vm} from "forge-std/Vm.sol";

/// @notice A Chainlink-style price source with a settable answer and round time, readable as an Aave V4 source
/// (`latestAnswer`) or a Chainlink feed (`latestRoundData`); `setReverting` makes every read revert.
contract BandTestFeed {
    uint8 public immutable decimals;
    int256 public answer;
    uint256 public updatedAt;
    bool public reverting;

    constructor(
        uint8 decimals_,
        int256 answer_
    ) {
        decimals = decimals_;
        set(answer_);
    }

    function set(
        int256 answer_
    ) public {
        answer = answer_;
        updatedAt = block.timestamp;
    }

    function setReverting(
        bool on
    ) external {
        reverting = on;
    }

    function latestAnswer() external view returns (int256) {
        require(!reverting, "source down");
        return answer;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        require(!reverting, "source down");
        return (1, answer, updatedAt, updatedAt, 1);
    }
}

/// @notice The two `AaveOracle` calls a price Spoke stand-in makes.
interface IAaveOracleAdmin {
    function setSpoke(
        address spoke
    ) external;
    function setReserveSource(
        uint256 reserveId,
        address source
    ) external;
}

/// @notice An Aave V4 price Spoke stand-in on the real pinned `AaveOracle` (its bytecode from `out-aave/`): reserves
/// with an underlying, decimals, a price source, a dynamic config and a Spoke-wide liquidation config. Only the reads
/// Avana makes are served; the prices are Aave's own code path (`getReservePrice`, `> 0`, source decimals 8).
/// @dev Call `init` once after deployment: the oracle binds to a Spoke only once the Spoke's `ORACLE()` is readable.
contract BandTestPriceSpoke {
    Vm private constant VM = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    address public immutable ORACLE;
    uint256 public getReserveCount;
    mapping(uint256 reserveId => IAaveV4Spoke.Reserve) internal _reserves;
    mapping(uint256 reserveId => IAaveV4Spoke.DynamicReserveConfig) internal _dynamic;
    IAaveV4Spoke.LiquidationConfig internal _liquidation;

    /// @param oracleDecimals The AaveOracle's decimals: 8 on every real Spoke (`SpokeUtils.ORACLE_DECIMALS`).
    constructor(
        uint8 oracleDecimals
    ) {
        bytes memory code =
            abi.encodePacked(VM.getCode("out-aave/AaveOracle.sol/AaveOracle.json"), abi.encode(oracleDecimals));
        address oracle;
        assembly ("memory-safe") {
            oracle := create(0, add(code, 0x20), mload(code))
        }
        require(oracle != address(0), "AaveOracle not deployed");
        ORACLE = oracle;
    }

    function init() external {
        IAaveOracleAdmin(ORACLE).setSpoke(address(this));
    }

    /// @notice Lists a reserve as `Spoke.addReserve` does: the next ID, the source set through the oracle.
    function addReserve(
        address underlying,
        uint8 decimals,
        address source
    ) external returns (uint256 reserveId) {
        reserveId = getReserveCount++;
        _reserves[reserveId] = IAaveV4Spoke.Reserve({
            underlying: underlying,
            hub: address(0xB0B),
            // forge-lint: disable-next-line(unsafe-typecast)
            assetId: uint16(reserveId),
            decimals: decimals,
            collateralRisk: 0,
            flags: 0,
            dynamicConfigKey: 0
        });
        IAaveOracleAdmin(ORACLE).setReserveSource(reserveId, source);
    }

    /// @notice `Spoke.updateReservePriceSource`: Aave governance repoints a reserve.
    function updateReservePriceSource(
        uint256 reserveId,
        address source
    ) external {
        require(reserveId < getReserveCount, "ReserveNotListed");
        IAaveOracleAdmin(ORACLE).setReserveSource(reserveId, source);
    }

    function setDynamicReserveConfig(
        uint256 reserveId,
        IAaveV4Spoke.DynamicReserveConfig calldata config
    ) external {
        _dynamic[reserveId] = config;
    }

    function setLiquidationConfig(
        IAaveV4Spoke.LiquidationConfig calldata config
    ) external {
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
        return _dynamic[reserveId];
    }

    function getLiquidationConfig() external view returns (IAaveV4Spoke.LiquidationConfig memory) {
        return _liquidation;
    }
}

/// @notice An ERC-20 with chosen decimals.
contract BandTestToken is ERC20 {
    uint8 internal immutable _DECIMALS;

    constructor(
        string memory symbol,
        uint8 decimals_
    ) ERC20(symbol, symbol) {
        _DECIMALS = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _DECIMALS;
    }
}

/// @notice Serves `getMarket` as the LPVault would after `listMarket`.
contract BandTestVault {
    mapping(uint256 => ILPVault.Market) internal _markets;

    function setMarket(
        uint256 marketId,
        address token0,
        address token1,
        int24 bandLower,
        int24 bandUpper
    ) external {
        _markets[marketId] = ILPVault.Market({
            pool: bytes32(uint256(0xB001)),
            token0: token0,
            token1: token1,
            bandLower: bandLower,
            bandUpper: bandUpper,
            totalCredit: 0
        });
    }

    function getMarket(
        uint256 marketId
    ) external view returns (ILPVault.Market memory) {
        return _markets[marketId];
    }
}
