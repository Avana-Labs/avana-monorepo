// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ICollateralizationAdapter} from "../../custody/collateralization/ICollateralizationAdapter.sol";
import {ICollateralizationDebtMark} from "../../custody/collateralization/ICollateralizationDebtMark.sol";
import {IAaveV4Hub} from "../../interfaces/external/aave/IAaveV4Hub.sol";
import {IAaveV4Spoke} from "../../interfaces/external/aave/IAaveV4Spoke.sol";
import {IProxyManager} from "../../proxy/proxy-manager/IProxyManager.sol";
import {Market} from "../../types/Market.sol";
import {PauseReason} from "../../types/PauseReason.sol";
import {PauseState} from "../../types/PauseState.sol";
import {PositionRef} from "../../types/PositionRef.sol";
import {IVaultTokenFactory} from "../../vault-token/vault-token-factory/IVaultTokenFactory.sol";
import {IVaultToken} from "../../vault-token/vault-token/IVaultToken.sol";
import {IMarketRegistryHubs} from "../market-registry/IMarketRegistryHubs.sol";
import {IMarketRegistryRouteViews} from "../market-registry/IMarketRegistryRouteViews.sol";
import {IMarketRegistryViews} from "../market-registry/IMarketRegistryViews.sol";
import {DebtReserveDef} from "../market-registry/types/DebtReserveDef.sol";
import {IRiskModuleChecks} from "../risk-module/IRiskModuleChecks.sol";
import {AaveAdapterSteps} from "./AaveAdapterSteps.sol";
import {AaveAdapterStorage} from "./AaveAdapterStorage.sol";
import {IAaveAdapterLogic} from "./IAaveAdapterLogic.sol";
import {AaveAdapterImmutables} from "./types/AaveAdapterImmutables.sol";
import {AdapterAccount} from "./types/AdapterAccount.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title AaveAdapterUserLogic
/// @notice Bodies of the borrower entry points `pledge`, `borrow` and `repay`.
/// @dev Reached only by `delegatecall` from the AaveAdapter router (`IAaveAdapterLogic`); every body takes the Lock
/// first and releases it last. New activity (`pledge`, `borrow`) reads the MarketRegistry; repay reads only the
/// Adapter's own binding and Aave (Q-260).
/// @custom:spec REQ-ADAPTER-065, REQ-ADAPTER-066, REQ-ADAPTER-067, REQ-ADAPTER-068, REQ-ADAPTER-069, REQ-ADAPTER-071, REQ-ADAPTER-082, REQ-ADAPTER-083, REQ-ADAPTER-085, REQ-ADAPTER-096, REQ-ADAPTER-097, REQ-ADAPTER-103, REQ-ADAPTER-104, REQ-PROXY-015, REQ-PROXY-017, REQ-PROXY-019, REQ-PROXY-021, REQ-PROXY-022, REQ-PROXY-024, REQ-PROXY-027, REQ-PROXY-028, REQ-PROXY-029, REQ-PROXY-031, REQ-PROXY-032, REQ-PROXY-033, REQ-PROXY-034, REQ-PROXY-035, REQ-PROXY-036, REQ-PROXY-038, REQ-PROXY-039, REQ-PROXY-048
// Each function carries the body of a selector declared in an IAaveAdapter piece that the router implements; this
// contract inherits no piece, since each piece also declares functions another logic contract serves.
// solhint-disable comprehensive-interface
// Every call made here runs under the Adapter's Lock, which no callee can take again, so none can re-enter the Adapter
// between a call and the event that follows it.
// forge-lint: disable-start(reentrancy-events)
contract AaveAdapterUserLogic is AaveAdapterSteps, IAaveAdapterLogic {
    /// @notice Fixes the implementation immutables; they must equal the router's.
    /// @param im The chain's dependencies.
    /// @custom:spec REQ-ADAPTER-004, REQ-ADAPTER-074
    constructor(
        AaveAdapterImmutables memory im
    ) AaveAdapterStorage(im) {}

    /// @inheritdoc IAaveAdapterLogic
    /// @custom:spec REQ-ADAPTER-004
    function logicConfig() external view override returns (bytes32 kind, bytes32 immutablesHash) {
        return (keccak256("AaveAdapterUserLogic"), _IMMUTABLES_HASH);
    }

    // ─── Pledge ───

    /// @notice Body of `pledge` (REQ-ADAPTER-065).
    /// @custom:spec REQ-ADAPTER-065, REQ-ADAPTER-066, REQ-ADAPTER-068, REQ-ADAPTER-069, REQ-ADAPTER-077, REQ-ADAPTER-083, REQ-ADAPTER-103
    function pledge(
        uint256 marketId,
        PositionRef calldata position,
        uint256 deadline
    ) external returns (address proxy, uint256 recordId, uint128 credited) {
        _onlyDelegated();
        _acquire();
        if (block.timestamp > deadline) revert DeadlineExpired(deadline);
        (Market memory m, PauseState state) = _pledgeGates(marketId, position.integrationId);
        uint256 reserveId;
        (proxy, reserveId) = _proxyForPledge(marketId, m.spoke, m.vaultToken);
        if (state == PauseState.Frozen && _borrowCount(m.spoke, proxy) == 0) revert ApplicationFrozen();
        // Paused here has reason General (MintPathSuspect reverted in the gates): only a rescue top-up passes, as for
        // a frozen wallet (REQ-ADAPTER-083).
        bool requireRescue = state == PauseState.Paused || _isFrozen(msg.sender);
        (recordId, credited) = _custodyAndSupply(proxy, m, reserveId, position.positionKey, requireRescue);
        emit CollateralAdded(
            msg.sender, marketId, m.vaultToken, proxy, recordId, position.integrationId, position.positionKey, credited
        );
        _release();
    }

    /// @dev The pledge gates before the proxy (REQ-ADAPTER-065): the market and its vault token, `ApplicationPaused`
    /// under `Paused(MintPathSuspect)`, the approved Spoke and the integration. Returns the Hub's pause state.
    function _pledgeGates(
        uint256 marketId,
        uint32 integrationId
    ) private view returns (Market memory m, PauseState state) {
        m = _marketForPledge(marketId);
        PauseReason reason;
        (state, reason) = _pauseOf(m.hub);
        if (state == PauseState.Paused && reason == PauseReason.MintPathSuspect) revert ApplicationPaused();
        if (!IMarketRegistryViews(_MARKET_REGISTRY).getSpoke(m.spoke).approved) revert UnknownSpoke(m.spoke);
        if (integrationId != m.integrationId) revert IntegrationMismatch(marketId, integrationId);
    }

    /// @dev Registration of the proxy on the vault token, custody and credit through Collateralization, mint of exactly
    /// `credited` and the supply step, between the two backing-gap reads (REQ-ADAPTER-068, REQ-ADAPTER-069).
    function _custodyAndSupply(
        address proxy,
        Market memory m,
        uint256 reserveId,
        bytes32 positionKey,
        bool requireRescue
    ) private returns (uint256 recordId, uint128 credited) {
        IVaultToken vt = IVaultToken(m.vaultToken);
        if (!vt.isValidProxy(proxy)) vt.addValidProxy(proxy);
        int256 gapBefore = _gap(m.vaultToken);
        (recordId, credited) = ICollateralizationAdapter(_COLLATERALIZATION)
            .pledge(msg.sender, proxy, m.vaultToken, positionKey, requireRescue);
        if (credited == 0) revert ZeroAmount();
        vt.mint(proxy, credited);
        _supply(proxy, m.spoke, m.vaultToken, reserveId, vt.marketId(), credited);
        _checkGap(m.vaultToken, gapBefore);
    }

    /// @dev The registry's record of the market, refused (`UnknownMarket`) unless its vault token is a token of the
    /// VaultTokenFactory whose own market, Spoke and Hub are the record's (REQ-ADAPTER-065, INV-017).
    function _marketForPledge(
        uint256 marketId
    ) private view returns (Market memory m) {
        m = IMarketRegistryViews(_MARKET_REGISTRY).getMarket(marketId);
        address vt = m.vaultToken;
        if (
            vt == address(0) || !IVaultTokenFactory(_VAULT_TOKEN_FACTORY).isVaultToken(vt)
                || IVaultToken(vt).marketId() != marketId || IVaultToken(vt).spoke() != m.spoke
                || IVaultToken(vt).hub() != m.hub
        ) revert UnknownMarket(marketId);
    }

    /// @dev The caller's proxy for the market, created on its first pledge (REQ-ADAPTER-066) with an empty Spoke
    /// account (REQ-ADAPTER-103); also the vault token's reserve, derived from its immutables and Aave.
    function _proxyForPledge(
        uint256 marketId,
        address spoke,
        address vaultToken
    ) private returns (address proxy, uint256 reserveId) {
        reserveId = _reserveIdOf(vaultToken);
        proxy = _s().proxyOf[msg.sender][marketId];
        if (proxy != address(0)) return (proxy, reserveId);
        proxy = IProxyManager(_PROXY_MANAGER).deployProxy(msg.sender, spoke, marketId);
        IAaveV4Spoke.UserAccountData memory a = IAaveV4Spoke(spoke).getUserAccountData(proxy);
        if (
            a.borrowCount != 0 || a.activeCollateralCount != 0
                || IAaveV4Spoke(spoke).getUserSuppliedShares(reserveId, proxy) != 0
        ) revert AccountNotEmpty(proxy);
        Layout storage l = _s();
        l.proxyOf[msg.sender][marketId] = proxy;
        l.walletOf[proxy] = msg.sender;
        l.accountOf[proxy] =
            AdapterAccount({spoke: spoke, marketId: marketId, vaultToken: vaultToken, reserveId: reserveId});
        emit UserProxyCreated(msg.sender, spoke, marketId, proxy);
    }

    // ─── Borrow ───

    /// @notice Body of `borrow` (REQ-PROXY-015).
    /// @custom:spec REQ-PROXY-015, REQ-PROXY-016, REQ-PROXY-017, REQ-PROXY-019, REQ-PROXY-021, REQ-PROXY-022, REQ-PROXY-023, REQ-PROXY-024, REQ-ADAPTER-067, REQ-ADAPTER-082, SPEC-PROXY-004
    function borrow(
        uint256 marketId,
        uint256 debtReserveId,
        uint256 amount,
        address receiver,
        uint256 deadline,
        uint256 minHealthFactor,
        uint256 expectedNonce
    ) external returns (uint256 drawn) {
        _onlyDelegated();
        _acquire();
        if (block.timestamp > deadline) revert DeadlineExpired(deadline);
        if (amount == 0) revert ZeroAmount();
        DebtReserveDef memory def = _borrowPauseGate(marketId, debtReserveId);
        (address proxy, AdapterAccount memory account) = _accountOf(msg.sender, marketId);
        if (!IMarketRegistryRouteViews(_MARKET_REGISTRY).isApprovedDebtReserve(account.spoke, debtReserveId)) {
            revert UnknownDebtReserve(account.spoke, debtReserveId);
        }
        _checkReceiver(receiver, def);
        if (_isFrozen(msg.sender)) revert AddressIsFrozen(msg.sender);
        if (_isFrozen(receiver)) revert AddressIsFrozen(receiver);
        uint256 nonce = _s().borrowNonce[proxy];
        if (nonce != expectedNonce) revert BadNonce(nonce, expectedNonce);
        _s().borrowNonce[proxy] = nonce + 1;
        IRiskModuleChecks(_RISK_MODULE).preBorrowCheck(proxy, debtReserveId, amount);
        ICollateralizationDebtMark(_COLLATERALIZATION).markIndebted(proxy);
        _borrowStep(proxy, account.spoke, debtReserveId, amount, receiver);
        uint256 hf = IRiskModuleChecks(_RISK_MODULE).postHealthCheck(proxy, minHealthFactor);
        emit Borrowed(msg.sender, marketId, debtReserveId, receiver, amount, nonce, hf);
        _release();
        drawn = amount;
    }

    /// @dev `ApplicationFrozen` or `ApplicationPaused` unless the market's Hub and, for a cross-Hub reserve, the
    /// funding Hub are both None; returns the reserve's record for the receiver rule.
    function _borrowPauseGate(
        uint256 marketId,
        uint256 debtReserveId
    ) private view returns (DebtReserveDef memory def) {
        Market memory m = IMarketRegistryViews(_MARKET_REGISTRY).getMarket(marketId);
        _requireNone(m.hub);
        def = IMarketRegistryRouteViews(_MARKET_REGISTRY).getDebtReserve(m.spoke, debtReserveId);
        if (def.fundingHub != m.hub) _requireNone(def.fundingHub);
    }

    /// @dev `ApplicationFrozen` under Frozen, `ApplicationPaused` under Paused (either reason).
    function _requireNone(
        address hub
    ) private view {
        (PauseState state,) = _pauseOf(hub);
        if (state == PauseState.Frozen) revert ApplicationFrozen();
        if (state == PauseState.Paused) revert ApplicationPaused();
    }

    /// @dev Receiver rule (REQ-PROXY-017): `InvalidReceiver` for zero, a registered proxy, an Avana contract the Adapter
    /// knows, a registered LPVault, the PayoutEscrow, the flash source, a recorded Hub, an approved CDP Spoke, a Spoke
    /// listed on the borrowed asset of the funding Hub, and any token listed on that Hub.
    function _checkReceiver(
        address receiver,
        DebtReserveDef memory def
    ) private view {
        bool refused = receiver == address(0) || _s().walletOf[receiver] != address(0) || receiver == address(this)
            || receiver == _COLLATERALIZATION || receiver == _LP_VAULT_SWAP || receiver == _TIMELOCK
            || receiver == _MARKET_REGISTRY || receiver == _PARAMETER_STORE || receiver == _RISK_MODULE
            || receiver == _PROXY_MANAGER;
        if (!refused) {
            address reg = _MARKET_REGISTRY;
            refused = IMarketRegistryHubs(reg).integrationIdOf(receiver) != 0
                || receiver == IMarketRegistryViews(reg).PAYOUT_ESCROW()
                || receiver == IMarketRegistryViews(reg).flashSource()
                || IMarketRegistryHubs(reg).isRecordedHub(receiver)
                || IMarketRegistryViews(reg).getSpoke(receiver).approved
                || IAaveV4Hub(def.fundingHub).isSpokeListed(def.hubAssetId, receiver)
                || IAaveV4Hub(def.fundingHub).isUnderlyingListed(receiver);
        }
        if (refused) revert InvalidReceiver(receiver);
    }

    /// @dev Borrow step (REQ-PROXY-087, SPEC-PROXY-004): the proxy borrows on its own account, the drawn amount is its
    /// balance delta (`UnitsMismatch` unless `amount`) and it forwards exactly that to the receiver, ending where it began.
    function _borrowStep(
        address proxy,
        address spoke,
        uint256 debtReserveId,
        uint256 amount,
        address receiver
    ) private {
        address asset = IAaveV4Spoke(spoke).getReserve(debtReserveId).underlying;
        uint256 balanceBefore = IERC20(asset).balanceOf(proxy);
        _exec(proxy, spoke, abi.encodeCall(IAaveV4Spoke.borrow, (debtReserveId, amount, proxy)));
        uint256 balanceAfter = IERC20(asset).balanceOf(proxy);
        uint256 drawn = balanceAfter > balanceBefore ? balanceAfter - balanceBefore : 0;
        if (drawn != amount) revert UnitsMismatch(amount, drawn);
        _tokenCall(proxy, asset, abi.encodeCall(IERC20.transfer, (receiver, drawn)));
        // The proxy ending at its start balance is the step's postcondition (REQ-PROXY-087).
        // forge-lint: disable-next-line(incorrect-strict-equality)
        if (IERC20(asset).balanceOf(proxy) != balanceBefore) revert BalanceDeltaMismatch();
    }

    // ─── Repay ───

    /// @notice Body of `repay` (REQ-PROXY-027): any payer, no MarketRegistry, pause, freeze, breaker or price read.
    /// @custom:spec REQ-PROXY-027, REQ-PROXY-028, REQ-PROXY-029, REQ-PROXY-030, REQ-PROXY-031, REQ-PROXY-032, REQ-PROXY-083, REQ-PROXY-084, REQ-ADAPTER-085, SPEC-PROXY-003, SPEC-PROXY-007
    function repay(
        address borrower,
        uint256 marketId,
        uint256 debtReserveId,
        uint256 maxRepaySpend,
        bool repayAll,
        uint256 deadline
    ) external returns (uint256 spent) {
        _onlyDelegated();
        _acquire();
        if (block.timestamp > deadline) revert DeadlineExpired(deadline);
        (address proxy, AdapterAccount memory account) = _accountOf(borrower, marketId);
        if (!repayAll && maxRepaySpend == 0) revert ZeroAmount();
        (uint256 paid, uint256 debtAfter, bool moved) =
            _repayDebt(msg.sender, proxy, account.spoke, debtReserveId, maxRepaySpend, repayAll);
        if (moved) {
            emit Repaid(msg.sender, borrower, marketId, debtReserveId, paid, debtAfter, repayAll);
            // The reserve at zero debt is the only way this repay can leave `borrowCount == 0`; Collateralization
            // reads `borrowCount` itself and clears the mark only at 0 (REQ-PROXY-032).
            if (debtAfter == 0) ICollateralizationDebtMark(_COLLATERALIZATION).markDebtFree(proxy);
        }
        _release();
        spent = paid;
    }
}
// forge-lint: disable-end(reentrancy-events)
