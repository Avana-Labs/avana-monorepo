// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {AvanaRoles} from "../../governance/roles/AvanaRoles.sol";
import {IMarketRegistry} from "../../policy/market-registry/IMarketRegistry.sol";
import {OracleConfig, PriceState, PriceStateView} from "../../types/OracleTypes.sol";
import {ILPOracle} from "./ILPOracle.sol";
import {ILPOracleLogic} from "./ILPOracleLogic.sol";
import {LPOracleCalls} from "./LPOracleCalls.sol";
import {LPOracleListing} from "./LPOracleListing.sol";
import {LPOracleStorage} from "./LPOracleStorage.sol";
import {InitParams, LPOracleLogicSet} from "./LPOracleTypes.sol";
import {LPPriceMath} from "./LPPriceMath.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

// Every external call is a static call or a delegatecall into this feed's own logic, so none can reenter.
// forge-lint: disable-start(reentrancy-events)
/// @title LPOracle
/// @notice AMM-neutral price-state core of one market's price feed.
/// @dev UUPS proxy; only the timelock can upgrade it. Only `initialize` and `poke()` write price state.
abstract contract LPOracle is ILPOracle, AccessControlUpgradeable, UUPSUpgradeable, LPOracleListing {
    address internal immutable _POKE_LOGIC;
    address internal immutable _LISTING_LOGIC;
    address internal immutable _INIT_LOGIC;
    address internal immutable _VIEW_LOGIC;

    /// @notice Sets the chain constants and logic contracts, and disables initializers on the implementation.
    /// @dev Reverts `MarketMismatch(0)` unless every logic contract reports the same chain constants.
    constructor(
        address timelock,
        uint32 chainBlockTime,
        uint32 pokeMinGasFloor,
        uint32 pokeMinGasCeiling,
        bool hasSequencer,
        LPOracleLogicSet memory logics
    ) LPOracleStorage(timelock, chainBlockTime, pokeMinGasFloor, pokeMinGasCeiling, hasSequencer) {
        bytes32 config =
            keccak256(abi.encode(timelock, chainBlockTime, pokeMinGasFloor, pokeMinGasCeiling, hasSequencer));
        if (
            !_logicOk(logics.pokeLogic, config) || !_logicOk(logics.initLogic, config)
                || !_logicOk(logics.listingLogic, config) || !_logicOk(logics.viewLogic, config)
        ) revert MarketMismatch(0);
        (_POKE_LOGIC, _INIT_LOGIC, _LISTING_LOGIC, _VIEW_LOGIC) =
        (logics.pokeLogic, logics.initLogic, logics.listingLogic, logics.viewLogic);
        _disableInitializers();
    }

    function _logicOk(
        address logic,
        bytes32 config
    ) private view returns (bool) {
        return logic.code.length != 0 && ILPOracleLogic(logic).logicConfig() == config;
    }

    /// @inheritdoc ILPOracle
    function initialize(
        InitParams calldata params
    ) external override initializer {
        if (params.timelock != _TIMELOCK) revert AdminRoleOnlyTimelock(DEFAULT_ADMIN_ROLE, params.timelock);
        if (params.pokeMinGas < _POKE_MIN_GAS_FLOOR || params.pokeMinGas > _POKE_MIN_GAS_CEILING) {
            revert PokeMinGasOutOfBounds(params.pokeMinGas);
        }
        __AccessControl_init();
        __UUPSUpgradeable_init();
        _grantRole(DEFAULT_ADMIN_ROLE, _TIMELOCK);
        _grantRole(AvanaRoles.APPLICATION_ADMIN, _TIMELOCK);
        _storeMarket(params);
        Address.functionDelegateCall(_INIT_LOGIC, bytes.concat(ILPOracleLogic.initializeMarket.selector, msg.data[4:]));
    }

    /// @dev Reverts `MarketMismatch` for a malformed market.
    function _storeMarket(
        InitParams calldata params
    ) private {
        OracleConfig calldata config = params.config;
        uint256 n = config.tokens.length;
        if (
            params.marketId == 0 || config.marketId != params.marketId || n < 2 || n > 8
                || params.isUsdStable.length != n || params.parameterStore == address(0)
                || params.marketRegistry == address(0) || params.integration == address(0)
        ) revert MarketMismatch(params.marketId);
        Layout storage $ = _s();
        ($.parameterStore, $.marketRegistry, $.integration) =
        (params.parameterStore, params.marketRegistry, params.integration);
        ($.marketId, $.pokeMinGas, $.descriptionText) = (params.marketId, params.pokeMinGas, params.description);
        bool ok = true;
        for (uint256 i = 0; i < n; ++i) {
            address token = config.tokens[i].token;
            uint8 dec = 0;
            bool readable = false;
            if (token != address(0)) (readable, dec) = _tokenDecimals(token);
            for (uint256 j = 0; j < i; ++j) {
                if ($.tokens[j] == token) readable = false;
            }
            ok = ok && readable;
            $.tokens.push(token);
            $.tokenDecimals.push(dec);
            $.isUsdStable.push(params.isUsdStable[i]);
            $.routeVersion[i] = _routeVersion(token);
        }
        if (!ok || !_initMarket(params.market, _tokenList())) revert MarketMismatch(params.marketId);
        $.decimalsCheckedAt = _now64();
    }

    /// @dev The registry's route version of `token`, 0 when it cannot be read.
    function _routeVersion(
        address token
    ) private view returns (uint64 version) {
        (bool ok, bytes memory ret) = LPOracleCalls.staticRead(
            _s().marketRegistry, CONFIG_CALL_GAS, abi.encodeCall(IMarketRegistry.priceRouteVersion, (token)), WORD
        );
        uint256 value = 0;
        if (ok) (ok, value) = LPOracleCalls.uintAt(ret, 0, type(uint64).max);
        if (ok) version = SafeCast.toUint64(value);
    }

    /// @inheritdoc ILPOracle
    function latestAnswer() external view override returns (int256 answer) {
        _forward(_VIEW_LOGIC);
        return answer;
    }

    /// @inheritdoc ILPOracle
    function decimals() external pure override returns (uint8) {
        return DECIMALS;
    }

    /// @inheritdoc ILPOracle
    function description() external view override returns (string memory) {
        return _s().descriptionText;
    }

    /// @inheritdoc ILPOracle
    function latestRoundData()
        external
        view
        override
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        _forward(_VIEW_LOGIC);
        return (roundId, answer, startedAt, updatedAt, answeredInRound);
    }

    /// @inheritdoc ILPOracle
    function getPriceState() external view override returns (PriceStateView memory report) {
        _forward(_VIEW_LOGIC);
        return report;
    }

    /// @inheritdoc ILPOracle
    function getTokenPrices()
        external
        view
        override
        returns (uint256[] memory prices, uint64 servedUpdatedAt, PriceState state)
    {
        _forward(_VIEW_LOGIC);
        return (prices, servedUpdatedAt, state);
    }

    /// @inheritdoc ILPOracle
    function borrowPriceMaxAge() external view override returns (uint32 age) {
        _forward(_VIEW_LOGIC);
        return age;
    }

    /// @inheritdoc ILPOracle
    function liquidationPriceMaxAge() external view override returns (uint32 age) {
        _forward(_VIEW_LOGIC);
        return age;
    }

    /// @inheritdoc ILPOracle
    function poke() external override returns (PriceState state) {
        uint32 minGas = _s().pokeMinGas;
        if (gasleft() < minGas) revert InsufficientGas(gasleft(), minGas);
        state = abi.decode(Address.functionDelegateCall(_POKE_LOGIC, msg.data), (PriceState));
    }

    /// @inheritdoc ILPOracle
    function lastAcceptedPrice() external view override returns (uint256 price8, uint64 updatedAt) {
        Accepted storage a = _s().accepted;
        // forge-lint: disable-next-line(unsafe-typecast)
        (price8, updatedAt) = (uint256(a.answer), a.updatedAt);
    }

    /// @inheritdoc ILPOracle
    function priceCheckpoint() external view override returns (uint256 price8, uint64 at) {
        Checkpoint storage c = _s().checkpoint;
        (price8, at) = (c.price8, c.at);
    }

    /// @inheritdoc ILPOracle
    function checkConfig(
        OracleConfig calldata
    ) external view override returns (uint256 failedChecks) {
        _forward(_LISTING_LOGIC);
        return failedChecks;
    }

    /// @dev Delegatecalls the calldata into `logic` and ends the call with its return or revert data; never returns.
    function _forward(
        address logic
    ) internal view {
        _asView(_delegateAndReturn)(logic);
    }

    function _delegateAndReturn(
        address logic
    ) internal {
        bytes4 insufficient = InsufficientGas.selector;
        // Ends the call with the logic's raw return or revert data, which Solidity's call syntax would re-encode.
        // solhint-disable-next-line no-inline-assembly
        assembly {
            calldatacopy(0, 0, calldatasize())
            let ok := delegatecall(gas(), logic, 0, calldatasize(), 0, 0)
            let size := returndatasize()
            if iszero(ok) {
                if iszero(size) {
                    mstore(0, insufficient)
                    mstore(4, gas())
                    mstore(36, 0)
                    revert(0, 68)
                }
                returndatacopy(0, 0, size)
                revert(0, size)
            }
            returndatacopy(0, 0, size)
            return(0, size)
        }
    }

    /// @dev `fn` typed as a view; `_forward` forwards only view entry points.
    function _asView(
        function(address) internal fn
    ) private pure returns (function(address) internal view out) {
        // Reinterprets the function pointer; the code it points to is unchanged.
        // solhint-disable-next-line no-inline-assembly
        assembly ("memory-safe") {
            out := fn
        }
    }

    /// @inheritdoc ILPOracle
    function POKE_LOGIC() external view override returns (address logic) {
        logic = _POKE_LOGIC;
    }

    /// @inheritdoc ILPOracle
    function LISTING_LOGIC() external view override returns (address logic) {
        logic = _LISTING_LOGIC;
    }

    /// @inheritdoc ILPOracle
    function INIT_LOGIC() external view override returns (address logic) {
        logic = _INIT_LOGIC;
    }

    /// @inheritdoc ILPOracle
    function VIEW_LOGIC() external view override returns (address logic) {
        logic = _VIEW_LOGIC;
    }

    /// @inheritdoc ILPOracle
    function setPokeMinGas(
        uint32 value
    ) external override onlyRole(AvanaRoles.APPLICATION_ADMIN) {
        if (value < _POKE_MIN_GAS_FLOOR || value > _POKE_MIN_GAS_CEILING) revert PokeMinGasOutOfBounds(value);
        Layout storage $ = _s();
        uint32 previous = $.pokeMinGas;
        $.pokeMinGas = value;
        emit PokeMinGasUpdated(previous, value);
    }

    /// @dev Either admin role can be held only by `TIMELOCK`.
    function _grantRole(
        bytes32 role,
        address account
    ) internal override returns (bool granted) {
        if ((role == DEFAULT_ADMIN_ROLE || role == AvanaRoles.APPLICATION_ADMIN) && account != _TIMELOCK) {
            revert AdminRoleOnlyTimelock(role, account);
        }
        granted = super._grantRole(role, account);
    }

    function _authorizeUpgrade(
        address
    ) internal view override onlyRole(AvanaRoles.APPLICATION_ADMIN) {}

    /// @inheritdoc ILPOracle
    function pokeMinGas() external view override returns (uint32 value) {
        value = _s().pokeMinGas;
    }

    /// @inheritdoc ILPOracle
    function decimalsStatus() external view override returns (bool invalid, uint64 verifiedAt) {
        Layout storage $ = _s();
        (invalid, verifiedAt) = ($.decimalsInvalid, $.decimalsCheckedAt);
    }

    /// @inheritdoc ILPOracle
    function marketId() external view override returns (uint256 id) {
        id = _s().marketId;
    }

    /// @inheritdoc ILPOracle
    function integration() external view override returns (address amm) {
        amm = _s().integration;
    }

    /// @inheritdoc ILPOracle
    function tokens() external view override returns (address[] memory list) {
        list = _s().tokens;
    }

    /// @inheritdoc ILPOracle
    function parameterStore() external view override returns (address store) {
        store = _s().parameterStore;
    }

    /// @inheritdoc ILPOracle
    function marketRegistry() external view override returns (address registry) {
        registry = _s().marketRegistry;
    }

    /// @inheritdoc ILPOracle
    function stableCeilingUsd() external pure override returns (uint256 value) {
        value = LPPriceMath.STABLE_CEILING_USD;
    }

    /// @inheritdoc ILPOracle
    function TIMELOCK() external view override returns (address timelock) {
        timelock = _TIMELOCK;
    }

    function _tokenList() private view returns (address[] memory list) {
        list = _s().tokens;
    }
}
// forge-lint: disable-end(reentrancy-events)
