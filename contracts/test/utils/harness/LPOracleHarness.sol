// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {LPOracle} from "../../../src/oracle/lp-oracle/LPOracle.sol";
import {LPOracleListingLogic} from "../../../src/oracle/lp-oracle/LPOracleListingLogic.sol";
import {LPOracleLogicBase} from "../../../src/oracle/lp-oracle/LPOracleLogicBase.sol";
import {LPOraclePokeLogic} from "../../../src/oracle/lp-oracle/LPOraclePokeLogic.sol";
import {LPOracleStorage} from "../../../src/oracle/lp-oracle/LPOracleStorage.sol";
import {LPOracleViewLogic} from "../../../src/oracle/lp-oracle/LPOracleViewLogic.sol";
import {LPOracleLogicSet} from "../../../src/oracle/lp-oracle/types/LPOracleLogicSet.sol";
import {OracleConfig} from "../../../src/types/OracleConfig.sol";
import {SecondSource} from "../../../src/types/SecondSource.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title LPOracleHarnessModule
/// @notice A minimal pricing module for the LPOracle base's tests: a linear composition `a_i = floor(units * c_i /
/// 10^18)` (price independent, so the fair composition is the same at every price) and switchable module answers: a
/// failed composition, the pool lock, the consistency check and clamp, the pool-TWAP second source, the market's own
/// pool reference and listing failures. Its state sits at a fixed slot of the proxy, shared by the implementation and
/// both logic contracts.
abstract contract LPOracleHarnessModule is LPOracleStorage {
    struct ModuleState {
        uint256[] coefficients;
        bool compositionFails;
        bool lockReadFails;
        bool locked;
        bool consistencyUnavailable;
        bool consistencyFails;
        bool clamped;
        uint256 deviation;
        uint256 listingFailures;
        mapping(uint256 index => uint256 value) twapValue;
        bytes32 ownPool;
        // A composition at a price of token `failIndex` below `failBelow` fails (0: never).
        uint256 failIndex;
        uint256 failBelow;
    }

    bytes32 private constant MODULE_SLOT = keccak256("avana.test.LPOracleHarnessModule");

    function _m() internal pure returns (ModuleState storage m) {
        bytes32 slot = MODULE_SLOT;
        assembly {
            m.slot := slot
        }
    }

    function _initMarket(
        bytes calldata market,
        address[] memory tokens_
    ) internal override returns (bool ok) {
        uint256[] memory c = abi.decode(market, (uint256[]));
        if (c.length != tokens_.length) return false;
        _m().coefficients = c;
        return true;
    }

    function _composition(
        uint256 units,
        uint256[] memory prices
    ) internal view override returns (bool ok, uint256[] memory amounts) {
        ModuleState storage m = _m();
        if (m.compositionFails) return (false, amounts);
        if (m.failBelow != 0 && m.failIndex < prices.length && prices[m.failIndex] < m.failBelow) {
            return (false, amounts);
        }
        uint256 n = m.coefficients.length;
        amounts = new uint256[](n);
        for (uint256 i = 0; i < n; ++i) {
            amounts[i] = Math.mulDiv(units, m.coefficients[i], 1e18);
        }
        return (true, amounts);
    }

    function _poolCheck(
        uint256[] memory,
        uint256[] memory,
        uint32,
        uint16
    ) internal view override returns (PoolCheck memory p) {
        ModuleState storage m = _m();
        (p.readOk, p.locked) = (!m.lockReadFails, m.locked);
        (p.available, p.pass, p.deviationBps, p.clamped) =
        (!m.consistencyUnavailable, !m.consistencyFails, m.deviation, m.clamped);
    }

    function _poolTwapPrice(
        uint256 index,
        SecondSource memory,
        uint256[] memory
    ) internal view override returns (bool ok, uint256 value) {
        value = _m().twapValue[index];
        ok = value != 0;
    }

    function _listingChecks(
        OracleConfig calldata,
        uint256[] memory
    ) internal view override returns (uint256 failedChecks) {
        return _m().listingFailures;
    }

    /// @dev The harness market's pool reference (`setOwnPool`); unset (0) names no pool.
    function _isOwnPool(
        bytes32 poolRef
    ) internal view override returns (bool own) {
        bytes32 pool = _m().ownPool;
        return pool != bytes32(0) && poolRef == pool;
    }
}

/// @notice The harness module's poke logic.
contract LPOracleHarnessPokeLogic is LPOraclePokeLogic, LPOracleHarnessModule {
    constructor(
        address timelock,
        uint32 chainBlockTime,
        uint32 pokeMinGasFloor,
        uint32 pokeMinGasCeiling,
        bool hasSequencer
    ) LPOracleLogicBase(timelock, chainBlockTime, pokeMinGasFloor, pokeMinGasCeiling, hasSequencer) {}
}

/// @notice The harness module's listing logic.
contract LPOracleHarnessListingLogic is LPOracleListingLogic, LPOracleHarnessModule {
    constructor(
        address timelock,
        uint32 chainBlockTime,
        uint32 pokeMinGasFloor,
        uint32 pokeMinGasCeiling,
        bool hasSequencer
    ) LPOracleLogicBase(timelock, chainBlockTime, pokeMinGasFloor, pokeMinGasCeiling, hasSequencer) {}
}

/// @notice The harness module's view logic.
contract LPOracleHarnessViewLogic is LPOracleViewLogic, LPOracleHarnessModule {
    constructor(
        address timelock,
        uint32 chainBlockTime,
        uint32 pokeMinGasFloor,
        uint32 pokeMinGasCeiling,
        bool hasSequencer
    ) LPOracleLogicBase(timelock, chainBlockTime, pokeMinGasFloor, pokeMinGasCeiling, hasSequencer) {}
}

/// @title LPOracleHarness
/// @notice Minimal concrete LPOracle implementation for the base's tests, with the harness module and its two logic
/// contracts, plus module switches and storage getters.
contract LPOracleHarness is LPOracle, LPOracleHarnessModule {
    constructor(
        address timelock,
        uint32 chainBlockTime,
        uint32 pokeMinGasFloor,
        uint32 pokeMinGasCeiling,
        bool hasSequencer,
        address pokeLogic,
        address listingLogic,
        address viewLogic
    )
        LPOracle(
            timelock,
            chainBlockTime,
            pokeMinGasFloor,
            pokeMinGasCeiling,
            hasSequencer,
            LPOracleLogicSet(pokeLogic, listingLogic, listingLogic, viewLogic)
        )
    {}

    function setCoefficients(
        uint256[] calldata c
    ) external {
        _m().coefficients = c;
    }

    function setCompositionFails(
        bool v
    ) external {
        _m().compositionFails = v;
    }

    /// @notice Fails every composition whose price of token `index` is below `price` (`price` 0: never).
    function setCompositionFailsBelow(
        uint256 index,
        uint256 price
    ) external {
        (_m().failIndex, _m().failBelow) = (index, price);
    }

    function setLock(
        bool readFails,
        bool isLocked
    ) external {
        (_m().lockReadFails, _m().locked) = (readFails, isLocked);
    }

    function setConsistency(
        bool unavailable,
        bool fails,
        uint256 deviationBps,
        bool isClamped
    ) external {
        ModuleState storage m = _m();
        (m.consistencyUnavailable, m.consistencyFails, m.deviation, m.clamped) =
        (unavailable, fails, deviationBps, isClamped);
    }

    function setListingFailures(
        uint256 bits
    ) external {
        _m().listingFailures = bits;
    }

    function setOwnPool(
        bytes32 poolRef
    ) external {
        _m().ownPool = poolRef;
    }

    function setTwapValue(
        uint256 index,
        uint256 value
    ) external {
        _m().twapValue[index] = value;
    }

    function vaultDecimals() external view returns (uint8) {
        return _s().vaultDecimals;
    }

    function storedTimers()
        external
        view
        returns (uint64 failedSince, uint64 disagreeSince, bool expiredLatched, uint64 recoveredAt)
    {
        Layout storage $ = _s();
        return ($.failedSince, $.disagreeSince, $.expiredLatched, $.recoveredAt);
    }

    function storedRouteVersion(
        uint256 i
    ) external view returns (uint64) {
        return _s().routeVersion[i];
    }

    function storedSeen(
        uint256 i,
        uint256 r,
        uint256 l
    ) external view returns (address feed, uint80 roundId, uint64 updatedAt) {
        Seen storage s = _s().seen[i][r][l];
        return (s.feed, s.roundId, s.updatedAt);
    }
}

/// @notice Deploys the harness implementation with its three logic contracts.
library LPOracleHarnessDeployer {
    function deploy(
        address timelock,
        uint32 chainBlockTime,
        uint32 pokeMinGasFloor,
        uint32 pokeMinGasCeiling,
        bool hasSequencer
    ) internal returns (LPOracleHarness) {
        address poke = address(
            new LPOracleHarnessPokeLogic(timelock, chainBlockTime, pokeMinGasFloor, pokeMinGasCeiling, hasSequencer)
        );
        address listing = address(
            new LPOracleHarnessListingLogic(timelock, chainBlockTime, pokeMinGasFloor, pokeMinGasCeiling, hasSequencer)
        );
        address views = address(
            new LPOracleHarnessViewLogic(timelock, chainBlockTime, pokeMinGasFloor, pokeMinGasCeiling, hasSequencer)
        );
        return new LPOracleHarness(
            timelock, chainBlockTime, pokeMinGasFloor, pokeMinGasCeiling, hasSequencer, poke, listing, views
        );
    }
}
