// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAaveV4Spoke} from "../../interfaces/external/aave/IAaveV4Spoke.sol";
import {ISequencerUptimeFeed} from "../../interfaces/external/chainlink/ISequencerUptimeFeed.sol";
import {ILPOracle} from "../../oracle/lp-oracle/ILPOracle.sol";
import {LPPriceMath} from "../../oracle/lp-oracle/LPPriceMath.sol";
import {IPositionProxy} from "../../proxy/position-proxy/IPositionProxy.sol";
import {Market} from "../../types/Market.sol";
import {IMarketRegistry} from "../market-registry/IMarketRegistry.sol";
import {IParameterStore} from "../parameter-store/IParameterStore.sol";
import {IRiskModuleErrors} from "./IRiskModuleErrors.sol";
import {IRiskModuleLogic} from "./IRiskModuleLogic.sol";
import {RiskModuleCalls} from "./RiskModuleCalls.sol";
import {RiskModuleMath} from "./RiskModuleMath.sol";
import {RiskModuleImmutables} from "./types/RiskModuleImmutables.sol";

/// @title RiskModuleBase
/// @notice Implementation immutables and the reads shared by the RiskModule and its logic contracts: the market record,
/// the account's Spoke and market, the sequencer gate and the LPOracle prices.
/// @dev Holds no state. Every Hub, Spoke, integration, pool and token comes from the MarketRegistry market record, never
/// from a caller (REQ-RISK-029); every value from the ParameterStore or the MarketRegistry is read at the current
/// block and never copied (REQ-RISK-055).
/// @custom:spec REQ-RISK-029, REQ-RISK-055, REQ-RISK-081, REQ-RISK-084, Q-313
abstract contract RiskModuleBase is IRiskModuleErrors {
    /// @dev Gas given to the sequencer-uptime read (the LPOracle's `FEED_CALL_GAS`).
    uint256 internal constant SEQUENCER_CALL_GAS = 50_000;
    /// @dev ABI length of `latestRoundData()`: five words.
    uint256 internal constant ROUND_LENGTH = 160;
    /// @dev Sequencer gate states.
    uint8 internal constant SEQUENCER_UP = 0;
    uint8 internal constant SEQUENCER_DOWN = 1;
    uint8 internal constant SEQUENCER_GRACE = 2;
    /// @dev LPOracle market reason bits 2 to 6 make a market that is not failed Drifting; bit 3 is the USD-band breach
    /// (`PriceStateView`).
    uint256 internal constant PRICE_DRIFTING_BITS = 0x7c;
    uint256 internal constant PRICE_USD_BAND = 1 << 3;
    /// @dev LPOracle token reason bits 4 SECOND_SOURCE_DISAGREE and 5 SECOND_SOURCE_UNAVAILABLE (`TokenPriceView`).
    uint32 internal constant TOKEN_SECOND_SOURCE_BITS = (1 << 4) | (1 << 5);
    /// @dev LPOracle market reason bit 16: some token unconfirmed, evaluated while Live or Drifting (REQ-ORACLE-100).
    uint256 internal constant PRICE_SECOND_SOURCE_BIT = 1 << 16;
    /// @dev A pool-share cap of 10,000 bps is no limit (SPEC-CAP-005, Q-403).
    uint256 internal constant NO_POOL_SHARE_CAP = 10_000;

    /// @dev The MarketRegistry fixed proxy.
    address internal immutable _MARKET_REGISTRY;
    /// @dev The ParameterStore fixed proxy.
    address internal immutable _PARAMETER_STORE;
    /// @dev Collateralization.
    address internal immutable _COLLATERALIZATION;
    /// @dev The AaveAdapter fixed proxy.
    address internal immutable _ADAPTER;
    /// @dev LPVaultSwap fixed proxy.
    address internal immutable _LP_VAULT_SWAP;
    /// @dev The AvanaTimelock.
    address internal immutable _TIMELOCK;
    /// @dev `keccak256(abi.encode(im))`, compared between the RiskModule and its logic contracts.
    bytes32 internal immutable _IMMUTABLES_HASH;

    /// @notice Fixes the implementation immutables.
    /// @param im The per-chain Avana addresses.
    /// @custom:spec REQ-RISK-002, REQ-RISK-055
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

    /// @dev Reverts `InvalidLogic` unless `logic` reports `kind` and the same implementation immutables, so a zero,
    /// foreign or differently configured address cannot be wired in as a logic contract (REQ-RISK-002).
    function _requireLogic(
        address logic,
        bytes32 kind
    ) internal view {
        (bytes32 k, bytes32 h) = IRiskModuleLogic(logic).logicConfig();
        if (k != kind || h != _IMMUTABLES_HASH) revert InvalidLogic(logic);
    }

    /// @dev The MarketRegistry.
    function _registry() internal view returns (IMarketRegistry) {
        return IMarketRegistry(_MARKET_REGISTRY);
    }

    /// @dev The ParameterStore.
    function _store() internal view returns (IParameterStore) {
        return IParameterStore(_PARAMETER_STORE);
    }

    /// @dev The market record (REQ-RISK-029).
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

    /// @dev `spoke.getUserAccountData(proxy)` at the current block (REQ-RISK-028).
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

    /// @dev The LPOracle's last accepted price, 8 decimals (REQ-RISK-026).
    function _accepted(
        address lpOracle
    ) internal view returns (uint256 price8) {
        // The time of the accepted price is not part of the check (REQ-RISK-026).
        // forge-lint: disable-next-line(unused-return)
        (price8,) = ILPOracle(lpOracle).lastAcceptedPrice();
    }

    /// @dev The booking price of a pledge (REQ-RISK-026): `min(fresh, accepted)`, from one `getPriceState()` read.
    function _bookingPrice(
        address lpOracle
    ) internal view returns (uint256 price8) {
        int256 fresh = ILPOracle(lpOracle).getPriceState().freshAnswer;
        // A positive int256 is cast; a failed market's 0 keeps the accepted price.
        // forge-lint: disable-next-line(unsafe-typecast)
        price8 = RiskModuleMath.bookingPrice(_accepted(lpOracle), fresh > 0 ? uint256(fresh) : 0);
    }

    /// @dev The LPOracle's served price, 8 decimals, at least 1.
    function _served(
        address lpOracle
    ) internal view returns (uint256 price8) {
        int256 a = ILPOracle(lpOracle).latestAnswer();
        // `latestAnswer` is at least 1 in every state (SPEC-ORC-017); a non-positive value reads as 1.
        // forge-lint: disable-next-line(unsafe-typecast)
        price8 = a > 0 ? uint256(a) : 1;
    }

    /// @dev Sequencer gate of the chain (REQ-RISK-081): `Up` on a chain without a feed; `Down` while the feed reports 1,
    /// cannot be read or answers other than exactly 160 bytes (the read copies at most 161 bytes, so a longer answer is
    /// seen and refused); `Grace` until `startedAt + gracePeriod`, returned as `graceEndsAt`.
    function _sequencerState() internal view returns (uint8 state, uint256 graceEndsAt) {
        (address feed, uint32 gracePeriod) = _store().sequencer();
        if (feed == address(0)) return (SEQUENCER_UP, 0);
        (bool ok, bytes memory ret) = RiskModuleCalls.staticRead(
            feed, SEQUENCER_CALL_GAS, abi.encodeCall(ISequencerUptimeFeed.latestRoundData, ()), ROUND_LENGTH + 1
        );
        ok = ok && ret.length == ROUND_LENGTH;
        (, uint256 answerWord) = RiskModuleCalls.wordAt(ret, 32);
        (, uint256 startedAt) = RiskModuleCalls.wordAt(ret, 64);
        // A two's-complement word read as int256: 0 is up, 1 is down, anything else is unknown.
        // forge-lint: disable-next-line(unsafe-typecast)
        int256 answer = int256(answerWord);
        (bool up,,, bool inGrace,) =
            LPPriceMath.sequencerStatus(true, ok, answer, startedAt, block.timestamp, gracePeriod);
        if (!up) return (SEQUENCER_DOWN, 0);
        if (inGrace) return (SEQUENCER_GRACE, startedAt + gracePeriod);
        return (SEQUENCER_UP, 0);
    }

    /// @dev Reverts `SequencerDown()` or `SequencerGrace(graceEndsAt)` unless the gate is `Up` (REQ-RISK-081).
    function _requireSequencerUp() internal view {
        (uint8 state, uint256 graceEndsAt) = _sequencerState();
        if (state == SEQUENCER_DOWN) revert SequencerDown();
        if (state == SEQUENCER_GRACE) revert SequencerGrace(graceEndsAt);
    }

    /// @dev Collateral factor of the market's reserve on its latest dynamic key, bps (SPEC-CAP-003).
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
