// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ICollateralizationAdapter} from "../../custody/collateralization/ICollateralizationAdapter.sol";
import {ICollateralizationDebtMark} from "../../custody/collateralization/ICollateralizationDebtMark.sol";
import {ICollateralizationViews} from "../../custody/collateralization/ICollateralizationViews.sol";
import {IAaveV4Spoke} from "../../interfaces/external/aave/IAaveV4Spoke.sol";
import {ISequencerUptimeFeed} from "../../interfaces/external/chainlink/ISequencerUptimeFeed.sol";
import {ILPVaultSwapDeleverage} from "../../liquidation/lp-vault-swap/ILPVaultSwapDeleverage.sol";
import {DeleverageRequest} from "../../liquidation/lp-vault-swap/types/DeleverageRequest.sol";
import {LPPriceMath} from "../../oracle/lp-oracle/LPPriceMath.sol";
import {Market} from "../../types/Market.sol";
import {PauseReason} from "../../types/PauseReason.sol";
import {PauseState} from "../../types/PauseState.sol";
import {PositionRef} from "../../types/PositionRef.sol";
import {IVaultToken} from "../../vault-token/vault-token/IVaultToken.sol";
import {IMarketRegistryRouteViews} from "../market-registry/IMarketRegistryRouteViews.sol";
import {IMarketRegistryViews} from "../market-registry/IMarketRegistryViews.sol";
import {IParameterStoreChain} from "../parameter-store/IParameterStoreChain.sol";
import {IRiskModuleChecks} from "../risk-module/IRiskModuleChecks.sol";
import {IRiskModuleErrors} from "../risk-module/IRiskModuleErrors.sol";
import {RiskModuleCalls} from "../risk-module/RiskModuleCalls.sol";
import {AaveAdapterSteps} from "./AaveAdapterSteps.sol";
import {AaveAdapterStorage} from "./AaveAdapterStorage.sol";
import {IAaveAdapterLogic} from "./IAaveAdapterLogic.sol";
import {AaveAdapterImmutables} from "./types/AaveAdapterImmutables.sol";
import {AdapterAccount} from "./types/AdapterAccount.sol";
import {RepayWithCollateralParams} from "./types/RepayWithCollateralParams.sol";

/// @title AaveAdapterCollateralLogic
/// @notice Bodies of the entry points that change a pledged record in place: `removeLiquidity`, `recredit` and
/// `repayWithCollateral`.
/// @dev Reached only by `delegatecall` from the AaveAdapter router (`IAaveAdapterLogic`); every body takes the Lock
/// first and releases it last and keeps the market's backing gap unchanged (SPEC-PROXY-008). `repayWithCollateral`
/// holds the Lock across LPVaultSwap's `deleverage` and the two callbacks it makes into the Adapter, which run in the
/// transient session opened here and closed before the Lock is released.
/// @custom:spec REQ-ADAPTER-069, REQ-ADAPTER-078, REQ-ADAPTER-079, REQ-ADAPTER-080, REQ-ADAPTER-082, REQ-ADAPTER-083, REQ-ADAPTER-086, SPEC-PROXY-008, SPEC-PROXY-009, REQ-PROXY-048, REQ-LOCK-007, REQ-LOCK-030
// Each function carries the body of a selector declared in an IAaveAdapter piece that the router implements; this
// contract inherits no piece, since each piece also declares functions another logic contract serves.
// solhint-disable comprehensive-interface
// Every call made here runs under the Adapter's Lock, which no callee can take again, so none can re-enter the Adapter
// between a call and the event that follows it.
// forge-lint: disable-start(reentrancy-events)
// The router implements IAaveAdapterCollateral; this logic contract carries its bodies only (see above).
// forge-lint: disable-next-line(missing-inheritance)
contract AaveAdapterCollateralLogic is AaveAdapterSteps, IAaveAdapterLogic {
    /// @dev Gas given to the sequencer-uptime read, as the RiskModule's and the LPOracle's.
    uint256 internal constant SEQUENCER_CALL_GAS = 50_000;
    /// @dev ABI length of `latestRoundData()`: five words.
    uint256 internal constant ROUND_LENGTH = 160;

    /// @notice Fixes the implementation immutables; they must equal the router's.
    /// @param im The chain's dependencies.
    /// @custom:spec REQ-ADAPTER-004, REQ-ADAPTER-074
    constructor(
        AaveAdapterImmutables memory im
    ) AaveAdapterStorage(im) {}

    /// @inheritdoc IAaveAdapterLogic
    /// @custom:spec REQ-ADAPTER-004
    function logicConfig() external view override returns (bytes32 kind, bytes32 immutablesHash) {
        return (keccak256("AaveAdapterCollateralLogic"), _IMMUTABLES_HASH);
    }

    // ─── Partial removal ───

    /// @notice Body of `removeLiquidity` (REQ-ADAPTER-078).
    /// @custom:spec REQ-ADAPTER-078, REQ-ADAPTER-089, REQ-RISK-070
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

    /// @dev Body of a partial removal after its gates: backing gap, withdrawal and burn, Collateralization
    /// `releasePartial` (length, reconcile, `0 < units < credited`, debit, unwind to the depositor), then the cleanup
    /// when debt-free or the remaining-record and health checks with debt, then the backing check.
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
        (remaining, amounts) = ICollateralizationAdapter(_COLLATERALIZATION)
            .releasePartial(proxy, account.vaultToken, positionKey, units, minAmounts);
        hf = type(uint256).max;
        if (debtFree) {
            _cleanup(proxy, account.spoke, reserveId);
        } else {
            IRiskModuleChecks(_RISK_MODULE).checkRemainingRecord(account.marketId, remaining);
            hf = IRiskModuleChecks(_RISK_MODULE).postHealthCheck(proxy, minHealthFactor);
        }
        _checkGap(account.vaultToken, gapBefore);
    }

    // ─── Re-credit ───

    /// @notice Body of `recredit` (REQ-ADAPTER-079).
    /// @custom:spec REQ-ADAPTER-079, REQ-ADAPTER-083, REQ-ADAPTER-090
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
        Market memory m = IMarketRegistryViews(_MARKET_REGISTRY).getMarket(marketId);
        if (position.integrationId != m.integrationId) revert IntegrationMismatch(marketId, position.integrationId);
        bool requireRescue = _mintGate(m.hub, account.spoke, proxy);
        uint128 rescueUnits;
        (added, rescueUnits) = _credit(proxy, account, position.positionKey, topUp, requireRescue);
        uint256 recordId =
            ICollateralizationViews(_COLLATERALIZATION).recordIdOf(position.integrationId, position.positionKey);
        emit CollateralRecredited(
            msg.sender, marketId, account.vaultToken, recordId, position.positionKey, added, rescueUnits
        );
        _release();
    }

    /// @dev Body of a re-credit after its gates: backing gap, Collateralization `recredit`, mint of exactly `added`,
    /// supply step, backing check.
    function _credit(
        address proxy,
        AdapterAccount memory account,
        bytes32 positionKey,
        bytes calldata topUp,
        bool requireRescue
    ) private returns (uint128 added, uint128 rescueUnits) {
        uint256 reserveId = _reserveIdOf(account.vaultToken);
        int256 gapBefore = _gap(account.vaultToken);
        (added, rescueUnits) = ICollateralizationAdapter(_COLLATERALIZATION)
            .recredit(msg.sender, proxy, account.vaultToken, positionKey, topUp, requireRescue);
        if (added == 0) revert ZeroAmount();
        IVaultToken(account.vaultToken).mint(proxy, added);
        _supply(proxy, account.spoke, account.vaultToken, reserveId, account.marketId, added);
        _checkGap(account.vaultToken, gapBefore);
    }

    /// @dev REQ-ADAPTER-083 for a re-credit: `ApplicationPaused` under `Paused(MintPathSuspect)`, `ApplicationFrozen`
    /// under Frozen for an account with no debt; a rescue top-up is required under `Paused(General)` or for a frozen
    /// caller.
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

    // ─── Repay with collateral ───

    /// @dev The account and the values a repay with collateral reads before it calls LPVaultSwap; `healthFactor` is the
    /// session's `hfBefore`, which `deleverageRepay` reads after LPVaultSwap's pokes.
    struct Before {
        address proxy;
        address spoke;
        address vaultToken;
        uint256 reserveId;
        uint256 healthFactor;
        int256 gap;
        uint256 shares;
    }

    /// @notice Body of `repayWithCollateral` (REQ-ADAPTER-080).
    /// @custom:spec REQ-ADAPTER-080, REQ-ADAPTER-067, REQ-ADAPTER-091, SPEC-PROXY-009, REQ-COLL-040
    function repayWithCollateral(
        RepayWithCollateralParams calldata p
    ) external returns (uint256 debtRepaid, uint256 debtAssetToWallet) {
        _onlyDelegated();
        _acquire();
        Before memory b = _repayWithCollateralGates(p);
        _openSession(b.proxy, p.marketId, p.position.positionKey, p.units, p.debtReserveId, _minsHash(p));
        (debtRepaid, debtAssetToWallet) = ILPVaultSwapDeleverage(_LP_VAULT_SWAP)
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
        // The borrower's own bound on what the call pays it (REQ-ADAPTER-080): each swap leg may fill anywhere above
        // its oracle minimum, so without it a sandwich could take up to the slippage allowance out of the leftover.
        if (debtAssetToWallet < p.minAssetOut) revert AssetOutBelowMinimum(debtAssetToWallet, p.minAssetOut);
        // REQ-COLL-040: a repay with collateral that leaves no Aave borrow clears the indebted mark, and, as after every
        // other debt-free exit, the collateral cleanup runs (REQ-PROXY-089, REQ-PROXY-046).
        if (hfAfter == type(uint256).max) {
            ICollateralizationDebtMark(_COLLATERALIZATION).markDebtFree(b.proxy);
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

    /// @dev The hash the session binds for the unwind minimums: of `p.minAmounts`, or of one zero per market token when
    /// it is empty, the array LPVaultSwap passes to `deleverageRelease` in that case (REQ-SWAP-106), so both sides hash
    /// the same normalised array.
    function _minsHash(
        RepayWithCollateralParams calldata p
    ) private view returns (bytes32) {
        if (p.minAmounts.length != 0) return keccak256(abi.encode(p.minAmounts));
        uint256 n = IMarketRegistryViews(_MARKET_REGISTRY).getMarket(p.marketId).tokens.length;
        return keccak256(abi.encode(new uint256[](n)));
    }

    /// @dev The gates of a repay with collateral in the order of REQ-ADAPTER-080, then the reads before the session:
    /// backing gap and supplied shares. Reads no breaker and no freeze. The health factor before is not read here: a
    /// poke by LPVaultSwap can move the price Aave reads within the block (the LPOracle verifies token decimals only in
    /// `poke()`, REQ-ORACLE-107), so `deleverageRepay` reads it after the pokes, at the prices `hfAfter` is read at.
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
        _requireSequencerNotDown();
        _checkIntegration(p.marketId, b.vaultToken, p.position.integrationId);
        if (!IMarketRegistryRouteViews(_MARKET_REGISTRY).isApprovedDebtReserve(b.spoke, p.debtReserveId)) {
            revert UnknownDebtReserve(b.spoke, p.debtReserveId);
        }
        IAaveV4Spoke sp = IAaveV4Spoke(b.spoke);
        if (sp.getUserTotalDebt(p.debtReserveId, b.proxy) == 0) revert NothingToRepay(p.debtReserveId);
        b.reserveId = _reserveIdOf(b.vaultToken);
        b.gap = _gap(b.vaultToken);
        b.shares = sp.getUserSuppliedShares(b.reserveId, b.proxy);
    }

    /// @dev After LPVaultSwap returns: both session steps ran (`NoDeleverageSession`), the supplied shares fell by
    /// exactly `units` (`UnitsMismatch`), while debt remains Aave's health factor is at least `max(hfBefore,
    /// minHealthFactor)` (`HealthFactorNotImproved`, SPEC-PROXY-009), and the backing gap is unchanged. Returns the
    /// health factor after, `type(uint256).max` once debt-free.
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

    /// @dev `SequencerDown()` while the chain's sequencer gate is Down (REQ-ADAPTER-080): the feed reports down, cannot
    /// be read or answers other than exactly one `latestRoundData` round. The grace period after a restart does not
    /// stop a repay with collateral. A chain without a feed is always Up.
    function _requireSequencerNotDown() private view {
        // The grace period does not stop a repay with collateral, so only the feed is read.
        // forge-lint: disable-next-line(unused-return)
        (address feed,) = IParameterStoreChain(_PARAMETER_STORE).sequencer();
        if (feed == address(0)) return;
        (bool ok, bytes memory ret) = RiskModuleCalls.staticRead(
            feed, SEQUENCER_CALL_GAS, abi.encodeCall(ISequencerUptimeFeed.latestRoundData, ()), ROUND_LENGTH + 1
        );
        ok = ok && ret.length == ROUND_LENGTH;
        (, uint256 answerWord) = RiskModuleCalls.wordAt(ret, 32);
        (, uint256 startedAt) = RiskModuleCalls.wordAt(ret, 64);
        // A two's-complement word read as int256: 0 is up, 1 is down, anything else is unknown.
        // forge-lint: disable-next-line(unsafe-typecast)
        int256 answer = int256(answerWord);
        (bool up,,,,) = LPPriceMath.sequencerStatus(true, ok, answer, startedAt, block.timestamp, 0);
        if (!up) revert IRiskModuleErrors.SequencerDown();
    }
}
// forge-lint: disable-end(reentrancy-events)
