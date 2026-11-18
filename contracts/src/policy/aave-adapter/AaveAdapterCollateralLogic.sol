// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ICollateralization} from "../../custody/collateralization/ICollateralization.sol";
import {IAaveV4Spoke} from "../../interfaces/external/aave/IAaveV4Spoke.sol";
import {ISequencerUptimeFeed} from "../../interfaces/external/chainlink/ISequencerUptimeFeed.sol";
import {ILPVaultSwap} from "../../liquidation/lp-vault-swap/ILPVaultSwap.sol";
import {DeleverageRequest} from "../../liquidation/lp-vault-swap/types/LPVaultSwapTypes.sol";
import {LPPriceMath} from "../../oracle/LPPriceMath.sol";
import {Market, PauseReason, PauseState} from "../../types/MarketTypes.sol";
import {PositionRef} from "../../types/PositionTypes.sol";
import {IVaultToken} from "../../vault-token/vault-token/IVaultToken.sol";
import {IMarketRegistry} from "../market-registry/IMarketRegistry.sol";
import {IParameterStore} from "../parameter-store/IParameterStore.sol";
import {IRiskModule} from "../risk-module/IRiskModule.sol";
import {IRiskModuleErrors} from "../risk-module/IRiskModuleErrors.sol";
import {RiskModuleMath} from "../risk-module/RiskModuleMath.sol";
import {AaveAdapterSteps} from "./AaveAdapterSteps.sol";
import {AaveAdapterStorage} from "./AaveAdapterStorage.sol";
import {IAaveAdapterLogic} from "./IAaveAdapterLogic.sol";
import {AaveAdapterImmutables, AdapterAccount, RepayWithCollateralParams} from "./types/AaveAdapterTypes.sol";

/// @title AaveAdapterCollateralLogic
/// @notice Bodies of `removeLiquidity`, `recredit` and `repayWithCollateral`.
// The router implements the IAaveAdapter pieces; this contract only carries bodies.
// solhint-disable comprehensive-interface
// Every call here runs under the Adapter's Lock, so no callee can re-enter before the following event.
// forge-lint: disable-start(reentrancy-events)
// forge-lint: disable-next-line(missing-inheritance)
contract AaveAdapterCollateralLogic is AaveAdapterSteps, IAaveAdapterLogic {
    uint256 internal constant SEQUENCER_CALL_GAS = 50_000;
    /// @dev ABI length of `latestRoundData()`: five words.
    uint256 internal constant ROUND_LENGTH = 160;

    constructor(
        AaveAdapterImmutables memory im
    ) AaveAdapterStorage(im) {}

    /// @inheritdoc IAaveAdapterLogic
    function logicConfig() external view override returns (bytes32 kind, bytes32 immutablesHash) {
        return (keccak256("AaveAdapterCollateralLogic"), _IMMUTABLES_HASH);
    }

    function removeLiquidity(
        uint256 marketId,
        PositionRef calldata position,
        uint128 units,
        uint256[] calldata minAmounts,
        uint256 deadline,
        uint256 minHealthFactor
    ) external returns (uint256[] memory amounts) {
        _onlyDelegated();
        _acquire();
        if (block.timestamp > deadline) revert DeadlineExpired(deadline);
        if (units == 0) revert ZeroAmount();
        (address proxy, AdapterAccount memory account) = _accountOf(msg.sender, marketId);
        _checkIntegration(marketId, account.vaultToken, position.integrationId);
        bool debtFree = _borrowCount(account.spoke, proxy) == 0;
        if (!debtFree) _withDebtGates(account.vaultToken, proxy);
        uint256 hf;
        (amounts, hf) = _reduce(proxy, account, position.positionKey, units, minAmounts, debtFree, minHealthFactor);
        emit CollateralReduced(
            msg.sender, marketId, account.vaultToken, position.positionKey, units, amounts, !debtFree, hf
        );
        _release();
    }

    function _reduce(
        address proxy,
        AdapterAccount memory account,
        bytes32 positionKey,
        uint128 units,
        uint256[] calldata minAmounts,
        bool debtFree,
        uint256 minHealthFactor
    ) private returns (uint256[] memory amounts, uint256 hf) {
        uint256 reserveId = _reserveIdOf(account.vaultToken);
        int256 gapBefore = _gap(account.vaultToken);
        _withdrawAndBurn(proxy, account.spoke, account.vaultToken, reserveId, units);
        uint128 remaining;
        (remaining, amounts) = ICollateralization(_COLLATERALIZATION)
            .releasePartial(proxy, account.vaultToken, positionKey, units, minAmounts);
        hf = type(uint256).max;
        if (debtFree) {
            _cleanup(proxy, account.spoke, reserveId);
        } else {
            IRiskModule(_RISK_MODULE).checkRemainingRecord(account.marketId, remaining);
            hf = IRiskModule(_RISK_MODULE).postHealthCheck(proxy, minHealthFactor);
        }
        _checkGap(account.vaultToken, gapBefore);
    }

    function recredit(
        uint256 marketId,
        PositionRef calldata position,
        bytes calldata topUp,
        uint256 deadline
    ) external returns (uint128 added) {
        _onlyDelegated();
        _acquire();
        if (block.timestamp > deadline) revert DeadlineExpired(deadline);
        (address proxy, AdapterAccount memory account) = _accountOf(msg.sender, marketId);
        Market memory m = IMarketRegistry(_MARKET_REGISTRY).getMarket(marketId);
        if (position.integrationId != m.integrationId) revert IntegrationMismatch(marketId, position.integrationId);
        bool requireRescue = _mintGate(m.hub, account.spoke, proxy);
        uint128 rescueUnits;
        (added, rescueUnits) = _credit(proxy, account, position.positionKey, topUp, requireRescue);
        uint256 recordId =
            ICollateralization(_COLLATERALIZATION).recordIdOf(position.integrationId, position.positionKey);
        emit CollateralRecredited(
            msg.sender, marketId, account.vaultToken, recordId, position.positionKey, added, rescueUnits
        );
        _release();
    }

    function _credit(
        address proxy,
        AdapterAccount memory account,
        bytes32 positionKey,
        bytes calldata topUp,
        bool requireRescue
    ) private returns (uint128 added, uint128 rescueUnits) {
        uint256 reserveId = _reserveIdOf(account.vaultToken);
        int256 gapBefore = _gap(account.vaultToken);
        (added, rescueUnits) = ICollateralization(_COLLATERALIZATION)
            .recredit(msg.sender, proxy, account.vaultToken, positionKey, topUp, requireRescue);
        if (added == 0) revert ZeroAmount();
        IVaultToken(account.vaultToken).mint(proxy, added);
        _supply(proxy, account.spoke, account.vaultToken, reserveId, account.marketId, added);
        _checkGap(account.vaultToken, gapBefore);
    }

    /// @dev Requires a rescue top-up under `Paused(General)` or for a frozen caller.
    function _mintGate(
        address hub,
        address spoke,
        address proxy
    ) private view returns (bool requireRescue) {
        (PauseState state, PauseReason reason) = _pauseOf(hub);
        if (state == PauseState.Paused && reason == PauseReason.MintPathSuspect) revert ApplicationPaused();
        if (state == PauseState.Frozen && _borrowCount(spoke, proxy) == 0) revert ApplicationFrozen();
        requireRescue = state == PauseState.Paused || _isFrozen(msg.sender);
    }

    /// @dev Values a repay with collateral reads before calling LPVaultSwap; `healthFactor` is filled in afterwards.
    struct Before {
        address proxy;
        address spoke;
        address vaultToken;
        uint256 reserveId;
        uint256 healthFactor;
        int256 gap;
        uint256 shares;
    }

    function repayWithCollateral(
        RepayWithCollateralParams calldata p
    ) external returns (uint256 debtRepaid, uint256 debtAssetToWallet) {
        _onlyDelegated();
        _acquire();
        Before memory b = _repayWithCollateralGates(p);
        _openSession(b.proxy, p.marketId, p.position.positionKey, p.units, p.debtReserveId, _minsHash(p));
        (debtRepaid, debtAssetToWallet) = ILPVaultSwap(_LP_VAULT_SWAP)
            .deleverage(
                DeleverageRequest({
                    proxy: b.proxy,
                    wallet: msg.sender,
                    spoke: b.spoke,
                    marketId: p.marketId,
                    vaultToken: b.vaultToken,
                    position: p.position,
                    units: p.units,
                    debtReserveId: p.debtReserveId,
                    minAmounts: p.minAmounts,
                    minDebtRepaid: p.minDebtRepaid
                })
            );
        uint256 hfAfter = _afterDeleverage(b, p.units, p.minHealthFactor);
        // Each swap leg may fill anywhere above its oracle minimum, so this bounds a sandwich on the leftover.
        if (debtAssetToWallet < p.minAssetOut) revert AssetOutBelowMinimum(debtAssetToWallet, p.minAssetOut);
        if (hfAfter == type(uint256).max) {
            ICollateralization(_COLLATERALIZATION).markDebtFree(b.proxy);
            _cleanup(b.proxy, b.spoke, b.reserveId);
        }
        _clearSession();
        emit RepaidWithCollateral(
            msg.sender,
            p.marketId,
            b.vaultToken,
            p.position.positionKey,
            p.units,
            p.debtReserveId,
            debtRepaid,
            debtAssetToWallet,
            b.healthFactor,
            hfAfter
        );
        _release();
    }

    /// @dev Hash of the unwind minimums; an empty array hashes as one zero per market token, as LPVaultSwap passes it.
    function _minsHash(
        RepayWithCollateralParams calldata p
    ) private view returns (bytes32) {
        if (p.minAmounts.length != 0) return keccak256(abi.encode(p.minAmounts));
        uint256 n = IMarketRegistry(_MARKET_REGISTRY).getMarket(p.marketId).tokens.length;
        return keccak256(abi.encode(new uint256[](n)));
    }

    /// @dev The health factor before is read later, in `deleverageRepay`, after LPVaultSwap's oracle pokes.
    function _repayWithCollateralGates(
        RepayWithCollateralParams calldata p
    ) private view returns (Before memory b) {
        if (block.timestamp > p.deadline) revert DeadlineExpired(p.deadline);
        if (p.units == 0) revert ZeroAmount();
        AdapterAccount memory account;
        (b.proxy, account) = _accountOf(msg.sender, p.marketId);
        (b.spoke, b.vaultToken) = (account.spoke, account.vaultToken);
        (PauseState state, PauseReason reason) = _pauseOf(IVaultToken(b.vaultToken).hub());
        if (state == PauseState.Paused && reason == PauseReason.MintPathSuspect) revert ApplicationPaused();
        _checkIntegration(p.marketId, b.vaultToken, p.position.integrationId);
        if (!IMarketRegistry(_MARKET_REGISTRY).isApprovedDebtReserve(b.spoke, p.debtReserveId)) {
            revert UnknownDebtReserve(b.spoke, p.debtReserveId);
        }
        IAaveV4Spoke sp = IAaveV4Spoke(b.spoke);
        if (sp.getUserTotalDebt(p.debtReserveId, b.proxy) == 0) revert NothingToRepay(p.debtReserveId);
        b.reserveId = _reserveIdOf(b.vaultToken);
        b.gap = _gap(b.vaultToken);
        b.shares = sp.getUserSuppliedShares(b.reserveId, b.proxy);
    }

    /// @dev Returns the health factor after, `type(uint256).max` once debt-free.
    function _afterDeleverage(
        Before memory b,
        uint256 units,
        uint256 minHealthFactor
    ) private view returns (uint256 hfAfter) {
        (,,,,,, uint256 steps) = _session();
        if (steps != STEP_REPAID | STEP_RELEASED) revert NoDeleverageSession();
        b.healthFactor = _hfBefore();
        IAaveV4Spoke sp = IAaveV4Spoke(b.spoke);
        uint256 sharesAfter = sp.getUserSuppliedShares(b.reserveId, b.proxy);
        uint256 fell = b.shares > sharesAfter ? b.shares - sharesAfter : 0;
        if (fell != units) revert UnitsMismatch(units, fell);
        IAaveV4Spoke.UserAccountData memory a = sp.getUserAccountData(b.proxy);
        hfAfter = type(uint256).max;
        if (a.borrowCount != 0) {
            hfAfter = a.healthFactor;
            uint256 required = b.healthFactor > minHealthFactor ? b.healthFactor : minHealthFactor;
            if (hfAfter < required) revert HealthFactorNotImproved(b.healthFactor, hfAfter);
        }
        _checkGap(b.vaultToken, b.gap);
    }
}
// forge-lint: disable-end(reentrancy-events)
