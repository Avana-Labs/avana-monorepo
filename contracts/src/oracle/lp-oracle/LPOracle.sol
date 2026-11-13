// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {AvanaRoles} from "../../governance/roles/AvanaRoles.sol";
import {IMarketRegistryStandby} from "../../policy/market-registry/IMarketRegistryStandby.sol";
import {OracleConfig} from "../../types/OracleConfig.sol";
import {PriceState} from "../../types/PriceState.sol";
import {PriceStateView} from "../../types/PriceStateView.sol";
import {ILPOracle} from "./ILPOracle.sol";
import {ILPOracleLogic} from "./ILPOracleLogic.sol";
import {ILPOracleRouter} from "./ILPOracleRouter.sol";
import {LPOracleCalls} from "./LPOracleCalls.sol";
import {LPOracleListing} from "./LPOracleListing.sol";
import {LPOracleStorage} from "./LPOracleStorage.sol";
import {LPPriceMath} from "./LPPriceMath.sol";
import {InitParams} from "./types/InitParams.sol";
import {LPOracleLogicSet} from "./types/LPOracleLogicSet.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

// Every external call of the LPOracle is a static call (STATICCALL, or a delegatecall into its own logic, which makes
// only static calls), so no call can reenter and reorder the events emitted after it (REQ-ORACLE-025).
// forge-lint: disable-start(reentrancy-events)
/// @title LPOracle
/// @notice AMM-neutral price-state core of one market's price feed (2.10): validates Chainlink legs, selects a quote per
/// token with automatic failover, checks agreement, the USD band, the pricing module's consistency check, second
/// sources and the sequencer, serves the USD value of one whole vault token with 8 decimals to the CDP Spoke's
/// AaveOracle, and reports the price state the RiskModule and LPVaultSwap enforce their gates from.
/// @dev Abstract: each AMM protocol's LPOracle implementation (concentrated liquidity: `LPOracleCL`) inherits it and
/// supplies the pricing-module hooks of `LPOracleStorage`. UUPS behind one ERC-1967 proxy per market; `_authorizeUpgrade`
/// requires `APPLICATION_ADMIN`, held only by `TIMELOCK`. Only `initialize` and `poke()` write price, timer, latch,
/// route-version or checkpoint storage; views never revert except `InsufficientGas` and return the same result for
/// every caller in a block. No token, ETH or approval moves through it. Example: a USDC/USDT market at $1.00 per
/// token holding 1 USDC + 1 USDT per whole vault token serves 200,000,000 ($2.00) while Live; once Cached it serves
/// the accepted price, once Expired 1.
/// @custom:spec REQ-ORACLE-106, REQ-ORACLE-107, REQ-ORACLE-016, REQ-ORACLE-020, REQ-ORACLE-040, REQ-ORACLE-041, REQ-ORACLE-042, REQ-ORACLE-043, REQ-ORACLE-044, REQ-ORACLE-045, REQ-ORACLE-058, REQ-ORACLE-059, REQ-ORACLE-060, REQ-ORACLE-061, REQ-ORACLE-062, REQ-ORACLE-063, REQ-ORACLE-064, REQ-ORACLE-078, REQ-ORACLE-080, REQ-ORACLE-082, REQ-ORACLE-087, REQ-ORACLE-088, REQ-ORACLE-097, REQ-ORACLE-101, Q-128, Q-247, Q-259, Q-321
abstract contract LPOracle is ILPOracle, ILPOracleRouter, AccessControlUpgradeable, UUPSUpgradeable, LPOracleListing {
    /// @dev Poke logic contract (`LPOraclePokeLogic` with this implementation's pricing module).
    address internal immutable _POKE_LOGIC;
    /// @dev Listing logic contract (`LPOracleListingLogic` with this implementation's pricing module): `checkConfig`.
    address internal immutable _LISTING_LOGIC;
    /// @dev Initialization logic contract: `initialize`'s market part (the listing logic itself where both fit one
    /// contract).
    address internal immutable _INIT_LOGIC;
    /// @dev View logic contract (`LPOracleViewLogic` with this implementation's pricing module).
    address internal immutable _VIEW_LOGIC;

    /// @notice Fixes the implementation constants of the chain and the three logic contracts, and disables initializers
    /// on the implementation.
    /// @dev Reverts `MarketMismatch(0)` unless the three logic contracts report the same chain constants (`logicConfig`).
    /// @param timelock The chain's AvanaTimelock (`TIMELOCK`).
    /// @param chainBlockTime Seconds per block (12 on Ethereum, 2 on Base).
    /// @param pokeMinGasFloor `POKE_MIN_GAS_FLOOR`.
    /// @param pokeMinGasCeiling `POKE_MIN_GAS_CEILING`.
    /// @param hasSequencer True on an L2 with a sequencer-uptime feed.
    /// @param logics The poke, initialization, listing and view logic contracts.
    /// @custom:spec REQ-ORACLE-078, REQ-ORACLE-080, REQ-ORACLE-097
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

    /// @dev `logic` has code and reports the chain constants `config`.
    function _logicOk(
        address logic,
        bytes32 config
    ) private view returns (bool) {
        return logic.code.length != 0 && ILPOracleLogic(logic).logicConfig() == config;
    }

    /// @inheritdoc ILPOracle
    /// @dev Grants the admin roles here, then runs the market part in the listing logic (`LPOracleListingLogic`): the
    /// market from the arguments (`MKT-019`), `d` (`SPEC-ORC-005`), `checkConfig == 0`, a Live seed evaluation and the
    /// seeded accepted price and checkpoint.
    /// @custom:spec REQ-ORACLE-010, REQ-ORACLE-047, REQ-ORACLE-058, REQ-ORACLE-059, REQ-ORACLE-076, REQ-ORACLE-088, REQ-ORACLE-097, SPEC-ORC-005
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

    /// @dev Stores the market identity from `params`; reverts `MarketMismatch` for a malformed market.
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

    /// @dev The registry's route version of `token`, 0 when it cannot be read (a token not yet listed).
    function _routeVersion(
        address token
    ) private view returns (uint64 version) {
        (bool ok, bytes memory ret) = LPOracleCalls.staticRead(
            _s().marketRegistry,
            CONFIG_CALL_GAS,
            abi.encodeCall(IMarketRegistryStandby.priceRouteVersion, (token)),
            WORD
        );
        uint256 value = 0;
        if (ok) (ok, value) = LPOracleCalls.uintAt(ret, 0, type(uint64).max);
        if (ok) version = SafeCast.toUint64(value);
    }

    // ─── Aave price feed and price state: evaluated in the view logic, run by `_forward` ───

    /// @inheritdoc ILPOracle
    /// @custom:spec REQ-ORACLE-020, REQ-ORACLE-060, REQ-ORACLE-061, REQ-ORACLE-085, REQ-ORACLE-086, SPEC-ORC-017
    function latestAnswer() external view override returns (int256 answer) {
        _forward(_VIEW_LOGIC);
        return answer;
    }

    /// @inheritdoc ILPOracle
    /// @custom:spec REQ-ORACLE-040
    function decimals() external pure override returns (uint8) {
        return DECIMALS;
    }

    /// @inheritdoc ILPOracle
    /// @custom:spec REQ-ORACLE-040
    function description() external view override returns (string memory) {
        return _s().descriptionText;
    }

    /// @inheritdoc ILPOracle
    /// @custom:spec REQ-ORACLE-041, REQ-ORACLE-021
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
    /// @custom:spec REQ-ORACLE-042
    function getPriceState() external view override returns (PriceStateView memory report) {
        _forward(_VIEW_LOGIC);
        return report;
    }

    /// @inheritdoc ILPOracle
    /// @custom:spec REQ-ORACLE-044, REQ-ORACLE-009
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
    /// @custom:spec REQ-ORACLE-043, SPEC-ORC-015
    function borrowPriceMaxAge() external view override returns (uint32 age) {
        _forward(_VIEW_LOGIC);
        return age;
    }

    /// @inheritdoc ILPOracle
    /// @custom:spec REQ-ORACLE-043, REQ-ORACLE-090, SPEC-ORC-015
    function liquidationPriceMaxAge() external view override returns (uint32 age) {
        _forward(_VIEW_LOGIC);
        return age;
    }

    /// @inheritdoc ILPOracle
    /// @custom:spec REQ-ORACLE-024, REQ-ORACLE-025, REQ-ORACLE-026, REQ-ORACLE-082
    function poke() external override returns (PriceState state) {
        uint32 minGas = _s().pokeMinGas;
        if (gasleft() < minGas) revert InsufficientGas(gasleft(), minGas);
        state = abi.decode(Address.functionDelegateCall(_POKE_LOGIC, msg.data), (PriceState));
    }

    /// @inheritdoc ILPOracle
    /// @custom:spec REQ-ORACLE-087
    function lastAcceptedPrice() external view override returns (uint256 price8, uint64 updatedAt) {
        Accepted storage a = _s().accepted;
        // The accepted answer is a positive price8.
        // forge-lint: disable-next-line(unsafe-typecast)
        (price8, updatedAt) = (uint256(a.answer), a.updatedAt);
    }

    /// @inheritdoc ILPOracle
    /// @custom:spec REQ-ORACLE-088
    function priceCheckpoint() external view override returns (uint256 price8, uint64 at) {
        Checkpoint storage c = _s().checkpoint;
        (price8, at) = (c.price8, c.at);
    }

    /// @inheritdoc ILPOracle
    /// @custom:spec REQ-ORACLE-046, REQ-ORACLE-100
    function checkConfig(
        OracleConfig calldata
    ) external view override returns (uint256 failedChecks) {
        _forward(_LISTING_LOGIC);
        return failedChecks;
    }

    /// @dev Runs the current view's calldata in `logic` (the view logic, or the listing logic for `checkConfig`) by
    /// delegatecall in this feed's storage and ends the call with the logic's return data. A failed call re-raises its
    /// revert data; a call that ran out of gas with no revert data reverts `InsufficientGas`, the only revert a view
    /// may produce (`REQ-ORACLE-061`). Only view entry points are forwarded, and a view body of a logic contract writes
    /// nothing and makes only static calls, so the call stays read-only whatever the caller's call type.
    /// The call never comes back here, so the `return` after each `_forward` only names the view's return values.
    /// @custom:spec REQ-ORACLE-039, REQ-ORACLE-061, REQ-ORACLE-106
    function _forward(
        address logic
    ) internal view {
        _asView(_delegateAndReturn)(logic);
    }

    /// @dev The delegatecall of `_forward`; it never returns to its caller.
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

    /// @dev `fn` typed as a view: `_delegateAndReturn` runs only the view entry points of a logic contract (`_forward`).
    function _asView(
        function(address) internal fn
    ) private pure returns (function(address) internal view out) {
        // Reinterprets the function pointer; the code it points to is unchanged.
        // solhint-disable-next-line no-inline-assembly
        assembly ("memory-safe") {
            out := fn
        }
    }

    /// @inheritdoc ILPOracleRouter
    /// @custom:spec REQ-ORACLE-080
    function POKE_LOGIC() external view override returns (address logic) {
        logic = _POKE_LOGIC;
    }

    /// @inheritdoc ILPOracleRouter
    /// @custom:spec REQ-ORACLE-080
    function LISTING_LOGIC() external view override returns (address logic) {
        logic = _LISTING_LOGIC;
    }

    /// @inheritdoc ILPOracleRouter
    /// @custom:spec REQ-ORACLE-080
    function INIT_LOGIC() external view override returns (address logic) {
        logic = _INIT_LOGIC;
    }

    /// @inheritdoc ILPOracleRouter
    /// @custom:spec REQ-ORACLE-080
    function VIEW_LOGIC() external view override returns (address logic) {
        logic = _VIEW_LOGIC;
    }

    // ─── Governance ───

    /// @inheritdoc ILPOracle
    /// @custom:spec REQ-ORACLE-038
    function setPokeMinGas(
        uint32 value
    ) external override onlyRole(AvanaRoles.APPLICATION_ADMIN) {
        if (value < _POKE_MIN_GAS_FLOOR || value > _POKE_MIN_GAS_CEILING) revert PokeMinGasOutOfBounds(value);
        Layout storage $ = _s();
        uint32 previous = $.pokeMinGas;
        $.pokeMinGas = value;
        emit PokeMinGasUpdated(previous, value);
    }

    /// @dev Either admin role can be held only by `TIMELOCK` (`REQ-ORACLE-097`).
    /// @custom:spec REQ-ORACLE-097, Q-259
    function _grantRole(
        bytes32 role,
        address account
    ) internal override returns (bool granted) {
        if ((role == DEFAULT_ADMIN_ROLE || role == AvanaRoles.APPLICATION_ADMIN) && account != _TIMELOCK) {
            revert AdminRoleOnlyTimelock(role, account);
        }
        granted = super._grantRole(role, account);
    }

    /// @dev Upgrades require `APPLICATION_ADMIN`, the timelock at the normal delay (`REQ-ORACLE-078`).
    /// @custom:spec REQ-ORACLE-078
    function _authorizeUpgrade(
        address
    ) internal view override onlyRole(AvanaRoles.APPLICATION_ADMIN) {}

    // ─── Identity ───

    /// @inheritdoc ILPOracle
    /// @custom:spec REQ-ORACLE-038
    function pokeMinGas() external view override returns (uint32 value) {
        value = _s().pokeMinGas;
    }

    /// @inheritdoc ILPOracle
    /// @custom:spec REQ-ORACLE-107
    function decimalsStatus() external view override returns (bool invalid, uint64 verifiedAt) {
        Layout storage $ = _s();
        (invalid, verifiedAt) = ($.decimalsInvalid, $.decimalsCheckedAt);
    }

    /// @inheritdoc ILPOracle
    /// @custom:spec REQ-ORACLE-014
    function marketId() external view override returns (uint256 id) {
        id = _s().marketId;
    }

    /// @inheritdoc ILPOracle
    /// @custom:spec REQ-ORACLE-014
    function integration() external view override returns (address amm) {
        amm = _s().integration;
    }

    /// @inheritdoc ILPOracle
    /// @custom:spec REQ-ORACLE-048
    function tokens() external view override returns (address[] memory list) {
        list = _s().tokens;
    }

    /// @inheritdoc ILPOracle
    /// @custom:spec REQ-ORACLE-017
    function parameterStore() external view override returns (address store) {
        store = _s().parameterStore;
    }

    /// @inheritdoc ILPOracle
    /// @custom:spec REQ-ORACLE-094
    function marketRegistry() external view override returns (address registry) {
        registry = _s().marketRegistry;
    }

    /// @inheritdoc ILPOracle
    /// @custom:spec SPEC-ORC-004
    function stableCeilingUsd() external pure override returns (uint256 value) {
        value = LPPriceMath.STABLE_CEILING_USD;
    }

    /// @inheritdoc ILPOracle
    /// @custom:spec REQ-ORACLE-097
    function TIMELOCK() external view override returns (address timelock) {
        timelock = _TIMELOCK;
    }

    /// @dev The stored tokens as a memory copy.
    function _tokenList() private view returns (address[] memory list) {
        list = _s().tokens;
    }
}
// forge-lint: disable-end(reentrancy-events)
