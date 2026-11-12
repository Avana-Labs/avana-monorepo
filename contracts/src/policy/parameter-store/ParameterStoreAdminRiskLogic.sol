// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {RouteReads} from "../../liquidation/settlement-routes/RouteReads.sol";
import {IPositionProxy} from "../../proxy/position-proxy/IPositionProxy.sol";
import {IProxyManager} from "../../proxy/proxy-manager/IProxyManager.sol";
import {Market} from "../../types/Market.sol";
import {SecondSource} from "../../types/SecondSource.sol";
import {SecondSourceKind} from "../../types/SecondSourceKind.sol";
import {IMarketRegistry} from "../market-registry/IMarketRegistry.sol";
import {DebtReserveDef} from "../market-registry/types/DebtReserveDef.sol";
import {TokenDef} from "../market-registry/types/TokenDef.sol";
import {IParameterStoreChain} from "./IParameterStoreChain.sol";
import {IParameterStoreLogic} from "./IParameterStoreLogic.sol";
import {ParameterStoreRisk} from "./ParameterStoreRisk.sol";
import {ParameterStoreStorage} from "./ParameterStoreStorage.sol";
import {GlobalParams} from "./types/GlobalParams.sol";
import {MarketParams} from "./types/MarketParams.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title ParameterStoreAdminRiskLogic
/// @notice Bodies of the structural setters of the risk configuration (pool risk factor, Avana's surplus share and recipient, the flash-fee ceiling, second sources and their standby, the slippage floor, token collateral factors, the stress floor) and of the initial parameter write.
/// @dev Normal delay; `useStandbySecondSource` is the one ParameterStore function a guardian (`APPLICATION_PAUSE_GUARDIAN`) calls directly, and the ParameterStore checks that role before delegating. Reached only by delegatecall from the ParameterStore, which checks the caller's role; see
/// `IParameterStoreLogic`.
/// @custom:spec REQ-CONFIG-049, REQ-CONFIG-054, REQ-CONFIG-056, REQ-PSTORE-010, REQ-PSTORE-021, REQ-PSTORE-024, REQ-PSTORE-028, REQ-PSTORE-029, REQ-PSTORE-034, REQ-RISK-045
// Each function here carries the body of a selector declared in an IParameterStore piece, which the ParameterStore
// itself implements; this contract inherits only a piece it implements in full, since each other piece also declares
// functions another contract serves.
// solhint-disable comprehensive-interface
// Every external call made by these setters is a view (STATICCALL), so none can re-enter the store or reorder its
// events; the events follow the checks that need those reads.
// forge-lint: disable-start(reentrancy-events)
contract ParameterStoreAdminRiskLogic is ParameterStoreRisk, IParameterStoreLogic {
    /// @dev Gas each identity probe of a fee-recipient candidate runs with. An Avana getter, behind its proxy
    /// included, costs under 10,000; a candidate that needs more, or answers with a huge buffer, runs out inside the
    /// probe, which then reads as no answer. A probe starved below this by the transaction's own gas limit leaves the
    /// setter at most `⌈64 × PROBE_GAS / 63⌉ / 64` (under 480) gas, less than the recipient write needs, so the
    /// setter can never complete on a starved probe.
    uint256 private constant PROBE_GAS = 30_000;

    /// @notice Fixes the implementation immutables; they must equal the ParameterStore's.
    /// @param timelock The chain's AvanaTimelock.
    /// @param marketRegistry The chain's MarketRegistry proxy.
    /// @param chainBlockTime Seconds per block.
    /// @param hasSequencer Whether the chain runs an L2 sequencer.
    /// @custom:spec REQ-PSTORE-001
    constructor(
        address timelock,
        address marketRegistry,
        uint32 chainBlockTime,
        bool hasSequencer
    ) ParameterStoreStorage(timelock, marketRegistry, chainBlockTime, hasSequencer) {}

    /// @inheritdoc IParameterStoreLogic
    /// @custom:spec REQ-PSTORE-001
    function logicConfig()
        external
        view
        override
        returns (bytes32 kind, address timelock, address marketRegistry, uint32 chainBlockTime, bool hasSequencer)
    {
        return (keccak256("ParameterStoreAdminRiskLogic"), _TIMELOCK, address(_REGISTRY), _BLOCK_TIME, _HAS_SEQUENCER);
    }

    /// @notice Body of `IParameterStoreAdmin.initialize`: checks and writes the chain and global values; the
    /// ParameterStore has already run `initializer` and granted the admin roles to `TIMELOCK`.
    /// @dev `initialDepositorUsdCap` must be 0: depositor caps are per Hub and `setInitialHubCaps` writes each one.
    /// The sequencer check starts empty (`address(0)`, 0), Ethereum's value; on an L2 the first batch calls
    /// `setSequencer`.
    /// @custom:spec REQ-PSTORE-001, REQ-CONFIG-050, REQ-PSTORE-016, REQ-PSTORE-018, REQ-PSTORE-023, REQ-PSTORE-030
    function initialize(
        address,
        GlobalParams calldata params,
        uint256 initialDepositorUsdCap,
        uint16 initialPoolShareMaxBps
    ) external {
        _onlyDelegated();
        if (params.disagreementPauseMax > DISAGREEMENT_PAUSE_MAX || params.graceDuration > GRACE_DURATION_MAX) {
            revert LivenessBound();
        }
        if (params.graceHealthFactor < GRACE_HF_MIN || params.graceHealthFactor >= WAD) revert LivenessBound();
        if (
            params.cachedWindow == 0 || params.usdBandLow >= ONE_USD || params.usdBandHigh <= ONE_USD
                || params.maxFlashFeeBps > FLASH_FEE_MAX_BPS || params.avanaFeeShareBps > FEE_SHARE_MAX_BPS
                || params.feedAgreementMarginBps > BPS || params.gateRecoverySeconds < GATE_RECOVERY_MIN
                || params.gateRecoverySeconds > GATE_RECOVERY_MAX || params.maxShortfallBps > SHORTFALL_MAX_BPS
                || initialDepositorUsdCap != 0 || initialPoolShareMaxBps == 0 || initialPoolShareMaxBps > BPS
        ) revert OutOfBounds();
        _requireFeeRecipient(params.feeRecipient);
        _s().g = params;
        _s().poolShareMaxBps = initialPoolShareMaxBps;
        emit IParameterStoreChain.SequencerSet(address(0), 0);
    }

    /// @notice Body of `IParameterStoreAdmin.setPoolRiskFactor`; the ParameterStore checks the caller's role first.
    /// @custom:spec REQ-CONFIG-015, REQ-CONFIG-054, SPEC-CF-004
    function setPoolRiskFactor(
        uint256 marketId,
        uint16 value
    ) external {
        _onlyDelegated();
        Market memory m = _market(marketId);
        if (value == 0 || value > POOL_RISK_FACTOR_MAX) revert OutOfBounds();
        MarketParams storage p = _s().market[marketId];
        uint16 old = p.poolRiskFactor;
        if (value > old) _checkListingMargin(m, value);
        p.poolRiskFactor = value;
        emit ParameterSet("poolRiskFactor", bytes32(marketId), old, value);
    }

    /// @notice Body of `IParameterStoreAdmin.setAvanaFeeShareBps`; the ParameterStore checks the caller's role first.
    /// @custom:spec REQ-PSTORE-010, Q-097
    function setAvanaFeeShareBps(
        uint16 value
    ) external {
        _onlyDelegated();
        if (value > FEE_SHARE_MAX_BPS) revert OutOfBounds();
        uint16 old = _s().g.avanaFeeShareBps;
        _s().g.avanaFeeShareBps = value;
        emit ParameterSet("avanaFeeShareBps", bytes32(0), old, value);
    }

    /// @notice Body of `IParameterStoreAdmin.setFeeRecipient`; the ParameterStore checks the caller's role first.
    /// @custom:spec REQ-CONFIG-056
    function setFeeRecipient(
        address recipient
    ) external {
        _onlyDelegated();
        _requireFeeRecipient(recipient);
        address old = _s().g.feeRecipient;
        _s().g.feeRecipient = recipient;
        emit ParameterSet("feeRecipient", bytes32(0), uint160(old), uint160(recipient));
    }

    /// @notice Body of `IParameterStoreAdmin.setMaxFlashFeeBps`; the ParameterStore checks the caller's role first.
    /// @custom:spec REQ-PSTORE-021, REQ-PSTORE-024, REQ-CONFIG-052, Q-335
    function setMaxFlashFeeBps(
        uint16 value
    ) external {
        _onlyDelegated();
        if (value > FLASH_FEE_MAX_BPS) revert OutOfBounds();
        uint16 old = _s().g.maxFlashFeeBps;
        if (value > old) _requireLivenessEverywhere(value);
        _s().g.maxFlashFeeBps = value;
        emit ParameterSet("maxFlashFeeBps", bytes32(0), old, value);
    }

    /// @notice Body of `IParameterStoreAdmin.setSecondSource`; the ParameterStore checks the caller's role first.
    /// @dev Every word `getOracleInputs(..., true)` serves for either source is checked here, so the store never
    /// serves a second-source word an LPOracle or DebtOracle reads as out of range (`_wellFormed`); an empty standby
    /// has every field zero. Once written, neither source may read the pool of a market holding the token, and each
    /// window must fit the sequencer grace period (`_recheck` with `fit`).
    /// @custom:spec REQ-PSTORE-028, REQ-PSTORE-029, REQ-PSTORE-009, REQ-PSTORE-033, REQ-PSTORE-034, SPEC-ORC-020
    function setSecondSource(
        address token,
        SecondSource calldata src,
        SecondSource calldata standby
    ) external {
        _onlyDelegated();
        _requireListedToken(token);
        bool debtOracle = _s().debtStressRiseBps[token] != 0;
        SecondSource memory s = src;
        SecondSource memory b = standby;
        if (!_wellFormed(s, debtOracle) || _sharesRoute(token, s.source)) revert OutOfBounds();
        bool hasStandby = b.kind != SecondSourceKind.None;
        if (hasStandby ? !_wellFormed(b, debtOracle) || _shares(token, s, b) : !_empty(b)) revert OutOfBounds();
        Layout storage $ = _s();
        address oldSource = $.secondSource[token].source;
        address oldStandby = $.standby[token].source;
        $.secondSource[token] = s;
        $.standby[token] = b;
        bool wasOnStandby = $.onStandby[token];
        $.onStandby[token] = false;
        _recheck(SCOPE_TOKEN, token, false, true);
        if (hasStandby) {
            // Check the standby as a guardian would put it in force, then return to the recorded source.
            $.onStandby[token] = true;
            _recheck(SCOPE_TOKEN, token, false, false);
            $.onStandby[token] = false;
        }
        emit ParameterSet("secondSource", _a(token), uint160(oldSource), uint160(s.source));
        emit ParameterSet("standbySecondSource", _a(token), uint160(oldStandby), uint160(b.source));
        if (wasOnStandby) emit SecondSourceSwitched(token, false, msg.sender);
    }

    /// @notice Body of `IParameterStoreAdmin.useStandbySecondSource`; the ParameterStore checks the caller's role first.
    /// @dev The standby must still share no feed or pool with the recorded source or the token's recorded routes
    /// (`OutOfBounds`): a route change after `setSecondSource` could have made it depend on the failure it replaces.
    /// With the standby in force, every market holding the token must still fit it (`_recheck` with `fit`,
    /// `OutOfBounds`) and pass its LPOracle's `checkConfig` (`OracleConfigRejected`), so a change made after
    /// `setSecondSource` cannot leave the guardian a switch to a configuration the oracles refuse.
    /// @custom:spec REQ-PSTORE-029, REQ-PSTORE-009, REQ-PSTORE-034, EMG-103
    function useStandbySecondSource(
        address token
    ) external {
        _onlyDelegated();
        SecondSource memory b = _s().standby[token];
        if (b.kind == SecondSourceKind.None) revert NoStandby(token);
        if (_s().onStandby[token]) revert StandbyActive(token);
        SecondSource memory recorded = _s().secondSource[token];
        if (_shares(token, recorded, b)) revert OutOfBounds();
        _s().onStandby[token] = true;
        _recheck(SCOPE_TOKEN, token, false, true);
        emit SecondSourceSwitched(token, true, msg.sender);
    }

    /// @notice Body of `IParameterStoreAdmin.restoreSecondSource`; the ParameterStore checks the caller's role first.
    /// @dev No effect and no event while the recorded source is already in force; otherwise it puts the recorded
    /// source back and re-runs `checkConfig` of every market holding the token (`OracleConfigRejected`).
    /// @custom:spec REQ-PSTORE-029, REQ-PSTORE-009, EMG-103
    function restoreSecondSource(
        address token
    ) external {
        _onlyDelegated();
        if (!_s().onStandby[token]) return;
        _s().onStandby[token] = false;
        _recheck(SCOPE_TOKEN, token, false, false);
        emit SecondSourceSwitched(token, false, msg.sender);
    }

    /// @notice Body of `IParameterStoreAdmin.setSlippageAllowanceMinBps`; the ParameterStore checks the caller's role first.
    /// @custom:spec REQ-CONFIG-041, REQ-PSTORE-015, REQ-PSTORE-021, Q-261
    function setSlippageAllowanceMinBps(
        uint256 marketId,
        uint16 value
    ) external {
        _onlyDelegated();
        Market memory m = _market(marketId);
        MarketParams storage p = _s().market[marketId];
        uint16 old = p.slippageAllowanceMinBps;
        if (p.slippageAllowanceBps < value) revert LivenessBound();
        if (value > old && _live(m.status)) _requireLiveness(m, value, _s().g.maxFlashFeeBps);
        p.slippageAllowanceMinBps = value;
        emit ParameterSet("slippageAllowanceMinBps", bytes32(marketId), old, value);
    }

    /// @notice Body of `IParameterStoreAdmin.setTokenCollateralFactorBps`; the ParameterStore checks the caller's role first.
    /// @custom:spec REQ-CONFIG-019, REQ-CONFIG-020, SPEC-CF-004
    function setTokenCollateralFactorBps(
        address token,
        uint16 value
    ) external {
        _onlyDelegated();
        _requireListedToken(token);
        if (value == 0 || value > COLLATERAL_FACTOR_MAX) revert OutOfBounds();
        uint16 old = _s().tokenCollateralFactorBps[token];
        _s().tokenCollateralFactorBps[token] = value;
        // A higher factor thins the SPEC-CF-004 margin of every market holding the token; a lower one only widens it.
        if (value > old) _recheckMargins(SCOPE_TOKEN, token);
        emit ParameterSet("tokenCollateralFactorBps", _a(token), old, value);
    }

    /// @notice Body of `IParameterStoreAdmin.setStressFloorUsd`; the ParameterStore checks the caller's role first.
    /// @custom:spec REQ-RISK-045, SPEC-CAP-006
    function setStressFloorUsd(
        uint256 marketId,
        uint256 value
    ) external {
        _onlyDelegated();
        Market memory m = _market(marketId);
        if (value == 0 || value > USD_CAP_MAX) revert OutOfBounds();
        uint256 old = _s().stressFloorUsd[marketId];
        if (value < old) _requireAddCap(m, _s().marketUsdCap[marketId], _s().topUpSliceUsd[marketId], value);
        if (value > old && IERC20(m.vaultToken).totalSupply() != 0) revert SupplyNotZero(marketId);
        _s().stressFloorUsd[marketId] = value;
        emit StressFloorSet(marketId, old, value);
    }

    /// @dev REQ-CONFIG-056: not the zero address, this store, the timelock, the MarketRegistry or any Avana contract
    /// it records: its immutables (AaveAdapter, Collateralization, ProxyManager, LPVaultSwap, VaultTokenFactory,
    /// RiskModule, Lock, PayoutEscrow, this store, the flash liquidation helper, the standard Spoke implementation),
    /// the flash source, a Hub, a CDP Spoke, an LPVault, a vault token, an LPOracle, the Coverage Spoke or price source
    /// of a debt reserve; not a contract that reports this chain's timelock as `TIMELOCK()` or the MarketRegistry as
    /// `MARKET_REGISTRY()`, or answers `logicConfig()` (every other Avana contract and logic contract); and not a
    /// PositionProxy: a contract whose `ADAPTER()` is the AaveAdapter, or whose `(WALLET(), SPOKE(), MARKET_ID())` the
    /// ProxyManager's `predictProxy` maps to it. The registry checks run once the MarketRegistry holds code, so `initialize` can run before it.
    /// Every identity probe is a static call with `PROBE_GAS` that copies at most one word beyond the answer it
    /// accepts (`_word`), so a candidate answering with a huge buffer costs at most `PROBE_GAS` per probe.
    /// @custom:spec REQ-CONFIG-056
    function _requireFeeRecipient(
        address r
    ) internal view {
        IMarketRegistry reg = _REGISTRY;
        bool bad = r == address(0) || r == address(this) || r == _TIMELOCK || r == address(reg);
        if (!bad && address(reg).code.length != 0) {
            // The registry's recorded addresses, read in turn by one call site.
            function() external view returns (address)[12] memory recorded = [
                reg.AAVE_ADAPTER,
                reg.COLLATERALIZATION,
                reg.PROXY_MANAGER,
                reg.LP_VAULT_SWAP,
                reg.VAULT_TOKEN_FACTORY,
                reg.RISK_MODULE,
                reg.LOCK,
                reg.PAYOUT_ESCROW,
                reg.PARAMETER_STORE,
                reg.FLASH_LIQUIDATOR,
                reg.STANDARD_SPOKE_IMPLEMENTATION,
                reg.flashSource
            ];
            for (uint256 i = 0; i < recorded.length; ++i) {
                // Twelve view calls of the MarketRegistry, a fixed count.
                // forge-lint: disable-next-line(calls-loop)
                if (r == recorded[i]()) bad = true;
            }
            bad = bad || reg.isRecordedHub(r) || reg.getSpoke(r).approved || reg.integrationIdOf(r) != 0
                || reg.marketOfVaultToken(r) != 0 || reg.marketOfLpOracle(r) != 0 || _isReserveContract(reg, r)
                || _reportsAvana(r) || _isProxy(reg, r);
        }
        if (bad) revert InvalidFeeRecipient(r);
    }

    // The walk reads the MarketRegistry's Spokes and debt reserves with view calls at execution of a governance setter;
    // its length is the registry's size, which only timelock operations grow.
    // forge-lint: disable-start(calls-loop)
    /// @dev Whether `r` is the Coverage Spoke or the price source of a debt reserve of any CDP Spoke.
    function _isReserveContract(
        IMarketRegistry reg,
        address r
    ) private view returns (bool found) {
        address[] memory spokes = reg.getSpokes();
        for (uint256 s = 0; s < spokes.length; ++s) {
            uint256[] memory ids = reg.getDebtReserveIds(spokes[s]);
            for (uint256 i = 0; i < ids.length; ++i) {
                DebtReserveDef memory d = reg.getDebtReserve(spokes[s], ids[i]);
                if (r == d.coverageSpoke || r == d.priceSource) found = true;
            }
        }
    }

    // forge-lint: disable-end(calls-loop)

    /// @dev Whether `r` holds code and answers `TIMELOCK()` with this chain's timelock or `MARKET_REGISTRY()` with
    /// the MarketRegistry, as the upgradeable Avana contracts and the contracts bound to the registry do, or answers
    /// `logicConfig()` at all, as every logic contract of the ParameterStore, MarketRegistry, RiskModule and LPOracle
    /// does.
    function _reportsAvana(
        address r
    ) private view returns (bool) {
        if (r.code.length == 0) return false;
        // Only the probe's success and the length of its first word are read.
        (bool logic, bytes memory ret) =
            RouteReads._staticRead(r, PROBE_GAS, abi.encodeWithSignature("logicConfig()"), 32);
        return (logic && ret.length == 32) || _word(r, abi.encodeWithSignature("TIMELOCK()")) == uint160(_TIMELOCK)
            || _word(r, abi.encodeWithSignature("MARKET_REGISTRY()")) == uint160(address(_REGISTRY));
    }

    /// @dev A PositionProxy of the chain: `ADAPTER()` is the AaveAdapter, or `predictProxy(WALLET(), SPOKE(),
    /// MARKET_ID())` of the ProxyManager is `r` itself.
    function _isProxy(
        IMarketRegistry reg,
        address r
    ) private view returns (bool) {
        if (r.code.length == 0) return false;
        if (_word(r, abi.encodeCall(IPositionProxy.ADAPTER, ())) == uint160(reg.AAVE_ADAPTER())) return true;
        uint256 wallet = _word(r, abi.encodeCall(IPositionProxy.WALLET, ()));
        uint256 spoke = _word(r, abi.encodeCall(IPositionProxy.SPOKE, ()));
        uint256 marketId = _word(r, abi.encodeCall(IPositionProxy.MARKET_ID, ()));
        if (wallet == 0 || spoke == 0 || wallet > type(uint160).max || spoke > type(uint160).max) return false;
        // Range-checked above: the word fits 160 bits.
        // forge-lint: disable-next-line(unsafe-typecast)
        address w = address(uint160(wallet));
        // Range-checked above: the word fits 160 bits.
        // forge-lint: disable-next-line(unsafe-typecast)
        address sp = address(uint160(spoke));
        return _word(reg.PROXY_MANAGER(), abi.encodeCall(IProxyManager.predictProxy, (w, sp, marketId))) == uint160(r);
    }

    /// @dev The one-word answer of a probe (a static call with `PROBE_GAS`): 0 when the call fails, runs out of its
    /// gas or returns anything but exactly 32 bytes. At most 64 bytes of the answer are copied, so a longer answer is
    /// told apart from a word without copying the rest.
    function _word(
        address target,
        bytes memory data
    ) private view returns (uint256 value) {
        (bool ok, bytes memory ret) = RouteReads._staticRead(target, PROBE_GAS, data, 64);
        if (ok && ret.length == 32) value = abi.decode(ret, (uint256));
    }

    /// @dev A second source the oracles can read: `0 < toleranceBps ≤ 500` and a source holding code; an
    /// `OracleNetwork` source with `maxAge > 0`, no window or pool reference, and a feed definition (`setFeed`) whose
    /// pinned decimals and bounds `getOracleInputs` serves with it; a `PoolTwap` source with `twapWindow > 0`, a
    /// non-zero pool reference, no `maxAge` and a window within the sequencer grace period, never for a debt asset
    /// with a DebtOracle (`debtOracle`), which reads only an oracle network. `None` is not well formed.
    /// @custom:spec REQ-PSTORE-028, REQ-PSTORE-029, REQ-PSTORE-034, SPEC-ORC-020
    function _wellFormed(
        SecondSource memory s,
        bool debtOracle
    ) private view returns (bool) {
        if (s.toleranceBps == 0 || s.toleranceBps > SECOND_SOURCE_TOLERANCE_MAX_BPS || s.source.code.length == 0) {
            return false;
        }
        if (s.kind == SecondSourceKind.OracleNetwork) {
            return s.maxAge != 0 && s.twapWindow == 0 && s.poolRef == bytes32(0) && _s().feeds[s.source].decimals != 0;
        }
        return s.kind == SecondSourceKind.PoolTwap && !debtOracle && s.twapWindow != 0 && s.maxAge == 0
            && s.poolRef != bytes32(0) && _withinGrace(s.twapWindow);
    }

    /// @dev Whether every field of `s` is zero, the only form of an empty (`None`) standby.
    /// @custom:spec REQ-PSTORE-029
    function _empty(
        SecondSource memory s
    ) private pure returns (bool) {
        return s.kind == SecondSourceKind.None
            && uint256(uint160(s.source)) | uint256(s.poolRef) | s.maxAge | s.twapWindow | s.toleranceBps == 0;
    }

    /// @dev Whether `source` is a feed of the token's recorded primary, alternate or standby route.
    function _sharesRoute(
        address token,
        address source
    ) private view returns (bool) {
        TokenDef memory def = _REGISTRY.getToken(token);
        return _contains(def.primaryRoute, source) || _contains(def.alternateRoute, source)
            || _contains(def.standbyRoute, source);
    }

    /// @dev Whether the standby shares a feed or pool with the recorded source or a feed with the token's routes.
    function _shares(
        address token,
        SecondSource memory src,
        SecondSource memory standby
    ) private view returns (bool) {
        if (standby.source == src.source) return true;
        if (
            standby.kind == SecondSourceKind.PoolTwap && src.kind == SecondSourceKind.PoolTwap
                && standby.poolRef == src.poolRef
        ) return true;
        return _sharesRoute(token, standby.source);
    }
}
// forge-lint: disable-end(reentrancy-events)
