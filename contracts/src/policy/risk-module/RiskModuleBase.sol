// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAaveV4Spoke} from "../../interfaces/external/aave/IAaveV4Spoke.sol";
import {ISequencerUptimeFeed} from "../../interfaces/external/chainlink/ISequencerUptimeFeed.sol";
import {ILPOracle} from "../../oracle/lp-oracle/ILPOracle.sol";
import {LPPriceMath} from "../../oracle/lp-oracle/LPPriceMath.sol";
import {IPositionProxy} from "../../proxy/position-proxy/IPositionProxy.sol";
import {Market} from "../../types/MarketTypes.sol";
import {IMarketRegistry} from "../market-registry/IMarketRegistry.sol";
import {IParameterStore} from "../parameter-store/IParameterStore.sol";
import {IRiskModuleErrors} from "./IRiskModuleErrors.sol";
import {IRiskModuleLogic} from "./IRiskModuleLogic.sol";
import {RiskModuleMath} from "./RiskModuleMath.sol";
import {RiskModuleImmutables} from "./types/RiskModuleTypes.sol";

/// @title RiskModuleBase
/// @notice Implementation immutables and the reads shared by the RiskModule and its logic contracts.
/// @dev Holds no state.
abstract contract RiskModuleBase is IRiskModuleErrors {
    uint256 internal constant SEQUENCER_CALL_GAS = 50_000;
    /// @dev ABI length of `latestRoundData()`: five words.
    uint256 internal constant ROUND_LENGTH = 160;
    uint8 internal constant SEQUENCER_UP = 0;
    uint8 internal constant SEQUENCER_DOWN = 1;
    uint8 internal constant SEQUENCER_GRACE = 2;
    /// @dev LPOracle market reason bits that make a market Drifting, and the USD-band breach bit.
    uint256 internal constant PRICE_DRIFTING_BITS = 0x7c;
    uint256 internal constant PRICE_USD_BAND = 1 << 3;
    /// @dev LPOracle token reason bits SECOND_SOURCE_DISAGREE and SECOND_SOURCE_UNAVAILABLE.
    uint32 internal constant TOKEN_SECOND_SOURCE_BITS = (1 << 4) | (1 << 5);
    /// @dev LPOracle market reason bit: some token's second source unconfirmed.
    uint256 internal constant PRICE_SECOND_SOURCE_BIT = 1 << 16;
    /// @dev A pool-share cap of 10,000 bps is no limit.
    uint256 internal constant NO_POOL_SHARE_CAP = 10_000;

    address internal immutable _MARKET_REGISTRY;
    address internal immutable _PARAMETER_STORE;
    address internal immutable _COLLATERALIZATION;
    address internal immutable _ADAPTER;
    address internal immutable _LP_VAULT_SWAP;
    address internal immutable _TIMELOCK;
    /// @dev `keccak256(abi.encode(im))`, compared between the RiskModule and its logic contracts.
    bytes32 internal immutable _IMMUTABLES_HASH;

    constructor(
        RiskModuleImmutables memory im
    ) {
        _MARKET_REGISTRY = im.marketRegistry;
        _PARAMETER_STORE = im.parameterStore;
        _COLLATERALIZATION = im.collateralization;
        _ADAPTER = im.adapter;
        _LP_VAULT_SWAP = im.lpVaultSwap;
        _TIMELOCK = im.timelock;
        _IMMUTABLES_HASH = keccak256(abi.encode(im));
    }

    function _requireLogic(
        address logic,
        bytes32 kind
    ) internal view {
        (bytes32 k, bytes32 h) = IRiskModuleLogic(logic).logicConfig();
        if (k != kind || h != _IMMUTABLES_HASH) revert InvalidLogic(logic);
    }

    function _registry() internal view returns (IMarketRegistry) {
        return IMarketRegistry(_MARKET_REGISTRY);
    }

    function _store() internal view returns (IParameterStore) {
        return IParameterStore(_PARAMETER_STORE);
    }

    function _market(
        uint256 marketId
    ) internal view returns (Market memory m) {
        // The MarketRegistry is an Avana contract; callers loop over bounded market and reserve lists.
        // forge-lint: disable-next-line(calls-loop)
        m = _registry().getMarket(marketId);
    }

    /// @dev The account's Spoke and market: the proxy's immutables (one proxy per wallet and market).
    function _account(
        address proxy
    ) internal view returns (address spoke, uint256 marketId) {
        spoke = IPositionProxy(proxy).SPOKE();
        marketId = IPositionProxy(proxy).MARKET_ID();
    }

    function _accountData(
        address spoke,
        address proxy
    ) internal view returns (IAaveV4Spoke.UserAccountData memory a) {
        a = IAaveV4Spoke(spoke).getUserAccountData(proxy);
    }

    /// @dev Pool key of the market's pool, as Collateralization keys `poolUnits`.
    function _poolKey(
        Market memory m
    ) internal pure returns (bytes32 key) {
        key = keccak256(abi.encode(m.integrationId, m.pool, m.poolId));
    }

    /// @dev The LPOracle's last accepted price, 8 decimals.
    function _accepted(
        address lpOracle
    ) internal view returns (uint256 price8) {
        // The time of the accepted price is not used.
        // forge-lint: disable-next-line(unused-return)
        (price8,) = ILPOracle(lpOracle).lastAcceptedPrice();
    }

    function _capPrice(
        address lpOracle
    ) internal view returns (uint256 price8) {
        int256 fresh = ILPOracle(lpOracle).getPriceState().freshAnswer;
        // A positive int256 is cast; a failed market's 0 keeps the accepted price.
        // forge-lint: disable-next-line(unsafe-typecast)
        price8 = RiskModuleMath.capPrice(_accepted(lpOracle), fresh > 0 ? uint256(fresh) : 0);
    }

    /// @dev The LPOracle's served price, 8 decimals, at least 1.
    function _served(
        address lpOracle
    ) internal view returns (uint256 price8) {
        int256 a = ILPOracle(lpOracle).latestAnswer();
        // `latestAnswer` is at least 1 in every state; a non-positive value reads as 1.
        // forge-lint: disable-next-line(unsafe-typecast)
        price8 = a > 0 ? uint256(a) : 1;
    }

    /// @dev Sequencer gate: `Down` while the feed reports down, is unreadable or answers other than 160 bytes.
    function _sequencerState() internal view returns (uint8 state, uint256 graceEndsAt) {
        (address feed, uint32 gracePeriod) = _store().sequencer();
        if (feed == address(0)) return (SEQUENCER_UP, 0);
        (bool ok, bytes memory ret) = RiskModuleMath.staticRead(
            feed, SEQUENCER_CALL_GAS, abi.encodeCall(ISequencerUptimeFeed.latestRoundData, ()), ROUND_LENGTH + 1
        );
        ok = ok && ret.length == ROUND_LENGTH;
        (, uint256 answerWord) = RiskModuleMath.wordAt(ret, 32);
        (, uint256 startedAt) = RiskModuleMath.wordAt(ret, 64);
        // A two's-complement word read as int256: 0 is up, 1 is down, anything else is unknown.
        // forge-lint: disable-next-line(unsafe-typecast)
        int256 answer = int256(answerWord);
        (bool up,,, bool inGrace,) =
            LPPriceMath.sequencerStatus(true, ok, answer, startedAt, block.timestamp, gracePeriod);
        if (!up) return (SEQUENCER_DOWN, 0);
        if (inGrace) return (SEQUENCER_GRACE, startedAt + gracePeriod);
        return (SEQUENCER_UP, 0);
    }

    function _requireSequencerUp() internal view {
        (uint8 state, uint256 graceEndsAt) = _sequencerState();
        if (state == SEQUENCER_DOWN) revert SequencerDown();
        if (state == SEQUENCER_GRACE) revert SequencerGrace(graceEndsAt);
    }

    /// @dev Collateral factor of the market's reserve on its latest dynamic key, bps.
    function _latestCf(
        address spoke,
        Market memory m
    ) internal view returns (uint256 cfBps) {
        IAaveV4Spoke sp = IAaveV4Spoke(spoke);
        cfBps = sp.getDynamicReserveConfig(m.reserveId, sp.getReserve(m.reserveId).dynamicConfigKey).collateralFactor;
    }

    /// @dev Breaker key of a debt reserve, as the MarketRegistry keys it.
    function _debtKey(
        address spoke,
        uint256 debtReserveId
    ) internal pure returns (bytes32 key) {
        key = keccak256(abi.encode(spoke, debtReserveId));
    }
}
