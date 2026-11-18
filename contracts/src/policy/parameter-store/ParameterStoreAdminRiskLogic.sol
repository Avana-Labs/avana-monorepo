// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {RouteMath} from "../../liquidation/settlement-routes/RouteMath.sol";
import {IPositionProxy} from "../../proxy/position-proxy/IPositionProxy.sol";
import {IProxyManager} from "../../proxy/proxy-manager/IProxyManager.sol";
import {Market} from "../../types/MarketTypes.sol";
import {IMarketRegistry} from "../market-registry/IMarketRegistry.sol";
import {DebtReserveDef} from "../market-registry/types/MarketRegistryTypes.sol";
import {IParameterStoreLogic} from "./IParameterStoreLogic.sol";
import {ParameterStoreRisk} from "./ParameterStoreRisk.sol";
import {ParameterStoreStorage} from "./ParameterStoreStorage.sol";
import {GlobalParams, MarketParams} from "./types/ParameterStoreTypes.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title ParameterStoreAdminRiskLogic
/// @notice Bodies of the structural risk setters and the initial parameter write.
/// @dev Reached only by delegatecall from the ParameterStore, which checks the caller's role.
// Bodies of selectors the ParameterStore declares; only fully implemented pieces are inherited.
// solhint-disable comprehensive-interface
// Every external call here is a view (STATICCALL), so none can re-enter the store or reorder its events.
// forge-lint: disable-start(reentrancy-events)
contract ParameterStoreAdminRiskLogic is ParameterStoreRisk, IParameterStoreLogic {
    /// @dev Gas per fee-recipient probe; a probe starved by the gas limit leaves the setter too little gas to finish.
    uint256 private constant PROBE_GAS = 30_000;

    /// @notice Fixes the implementation immutables; they must equal the ParameterStore's.
    constructor(
        address timelock,
        address marketRegistry,
        uint32 chainBlockTime
    ) ParameterStoreStorage(timelock, marketRegistry, chainBlockTime) {}

    /// @inheritdoc IParameterStoreLogic
    function logicConfig()
        external
        view
        override
        returns (bytes32 kind, address timelock, address marketRegistry, uint32 chainBlockTime)
    {
        return (keccak256("ParameterStoreAdminRiskLogic"), _TIMELOCK, address(_REGISTRY), _BLOCK_TIME);
    }

    /// @notice Body of `IParameterStore.initialize`: checks and writes the global values.
    function initialize(
        address,
        GlobalParams calldata params
    ) external {
        _onlyDelegated();
        if (
            params.maxFlashFeeBps > FLASH_FEE_MAX_BPS || params.avanaFeeShareBps > FEE_SHARE_MAX_BPS
                || params.gateRecoverySeconds < GATE_RECOVERY_MIN || params.gateRecoverySeconds > GATE_RECOVERY_MAX
                || params.maxShortfallBps > SHORTFALL_MAX_BPS
        ) revert OutOfBounds();
        _requireFeeRecipient(params.feeRecipient);
        _s().g = params;
    }

    /// @notice Body of `IParameterStore.setPoolRiskFactor`.
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

    /// @notice Body of `IParameterStore.setAvanaFeeShareBps`.
    function setAvanaFeeShareBps(
        uint16 value
    ) external {
        _onlyDelegated();
        if (value > FEE_SHARE_MAX_BPS) revert OutOfBounds();
        uint16 old = _s().g.avanaFeeShareBps;
        if (value > old) _requireFeeBoundEverywhere(value);
        _s().g.avanaFeeShareBps = value;
        emit ParameterSet("avanaFeeShareBps", bytes32(0), old, value);
    }

    /// @notice Body of `IParameterStore.setFeeRecipient`.
    function setFeeRecipient(
        address recipient
    ) external {
        _onlyDelegated();
        _requireFeeRecipient(recipient);
        address old = _s().g.feeRecipient;
        _s().g.feeRecipient = recipient;
        emit ParameterSet("feeRecipient", bytes32(0), uint160(old), uint160(recipient));
    }

    /// @notice Body of `IParameterStore.setTokenCollateralFactorBps`.
    function setTokenCollateralFactorBps(
        address token,
        uint16 value
    ) external {
        _onlyDelegated();
        _requireListedToken(token);
        if (value == 0 || value > COLLATERAL_FACTOR_MAX) revert OutOfBounds();
        uint16 old = _s().tokenCollateralFactorBps[token];
        _s().tokenCollateralFactorBps[token] = value;
        // A higher factor thins the listing margin of every market holding the token; a lower one only widens it.
        if (value > old) _recheckMargins(SCOPE_TOKEN, token);
        emit ParameterSet("tokenCollateralFactorBps", _a(token), old, value);
    }

    /// @notice Body of `IParameterStore.setStressFloorUsd`.
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

    /// @dev Registry checks run only once the MarketRegistry holds code, so `initialize` can run before it.
    function _requireFeeRecipient(
        address r
    ) internal view {
        IMarketRegistry reg = _REGISTRY;
        bool bad = r == address(0) || r == address(this) || r == _TIMELOCK || r == address(reg);
        if (!bad && address(reg).code.length != 0) {
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

    // Loop lengths are the registry's size, which only timelock operations grow.
    // forge-lint: disable-start(calls-loop)
    function _isReserveContract(
        IMarketRegistry reg,
        address r
    ) private view returns (bool found) {
        address[] memory spokes = reg.getSpokes();
        for (uint256 s = 0; s < spokes.length; ++s) {
            uint256[] memory ids = reg.getDebtReserveIds(spokes[s]);
            for (uint256 i = 0; i < ids.length; ++i) {
                DebtReserveDef memory d = reg.getDebtReserve(spokes[s], ids[i]);
                if (r == d.firstLossReserve || r == d.priceSource) found = true;
            }
        }
    }

    // forge-lint: disable-end(calls-loop)

    /// @dev Whether `r` reports this chain's timelock or MarketRegistry, or answers `logicConfig()` at all.
    function _reportsAvana(
        address r
    ) private view returns (bool) {
        if (r.code.length == 0) return false;
        // Only the probe's success and the length of its first word are read.
        (bool logic, bytes memory ret) =
            RouteMath._staticRead(r, PROBE_GAS, abi.encodeWithSignature("logicConfig()"), 32);
        return (logic && ret.length == 32) || _word(r, abi.encodeWithSignature("TIMELOCK()")) == uint160(_TIMELOCK)
            || _word(r, abi.encodeWithSignature("MARKET_REGISTRY()")) == uint160(address(_REGISTRY));
    }

    /// @dev `ADAPTER()` is the AaveAdapter, or the ProxyManager's `predictProxy` of its bindings is `r`.
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

    /// @dev One-word answer of a probe, 0 unless it returns exactly 32 bytes; copies at most 64 bytes of return data.
    function _word(
        address target,
        bytes memory data
    ) private view returns (uint256 value) {
        (bool ok, bytes memory ret) = RouteMath._staticRead(target, PROBE_GAS, data, 64);
        if (ok && ret.length == 32) value = abi.decode(ret, (uint256));
    }
}
// forge-lint: disable-end(reentrancy-events)
