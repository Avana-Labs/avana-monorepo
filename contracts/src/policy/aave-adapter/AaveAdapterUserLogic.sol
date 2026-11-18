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
import {IMarketRegistry} from "../market-registry/IMarketRegistry.sol";
import {DebtReserveDef} from "../market-registry/types/MarketRegistryTypes.sol";
import {IRiskModule} from "../risk-module/IRiskModule.sol";
import {AaveAdapterSteps} from "./AaveAdapterSteps.sol";
import {AaveAdapterStorage} from "./AaveAdapterStorage.sol";
import {IAaveAdapterLogic} from "./IAaveAdapterLogic.sol";
import {AaveAdapterImmutables, AdapterAccount} from "./types/AaveAdapterTypes.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title AaveAdapterUserLogic
/// @notice Bodies of the borrower entry points `pledge`, `borrow` and `repay`.
// The router implements the IAaveAdapter pieces; this contract only carries bodies.
// solhint-disable comprehensive-interface
// Every call here runs under the Adapter's Lock, so no callee can re-enter before the following event.
// forge-lint: disable-start(reentrancy-events)
contract AaveAdapterUserLogic is AaveAdapterSteps, IAaveAdapterLogic {
    constructor(
        AaveAdapterImmutables memory im
    ) AaveAdapterStorage(im) {}

    /// @inheritdoc IAaveAdapterLogic
    function logicConfig() external view override returns (bytes32 kind, bytes32 immutablesHash) {
        return (keccak256("AaveAdapterUserLogic"), _IMMUTABLES_HASH);
    }

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
        // Paused here means reason General: only a rescue top-up passes, as for a frozen wallet.
        bool requireRescue = state == PauseState.Paused || _isFrozen(msg.sender);
        (recordId, credited) = _custodyAndSupply(proxy, m, reserveId, position.positionKey, requireRescue);
        emit CollateralAdded(
            msg.sender, marketId, m.vaultToken, proxy, recordId, position.integrationId, position.positionKey, credited
        );
        _release();
    }

    /// @dev Pledge gates checked before the proxy exists; returns the Hub's pause state.
    function _pledgeGates(
        uint256 marketId,
        uint32 integrationId
    ) private view returns (Market memory m, PauseState state) {
        m = _marketForPledge(marketId);
        PauseReason reason;
        (state, reason) = _pauseOf(m.hub);
        if (state == PauseState.Paused && reason == PauseReason.MintPathSuspect) revert ApplicationPaused();
        if (!IMarketRegistry(_MARKET_REGISTRY).getSpoke(m.spoke).approved) revert UnknownSpoke(m.spoke);
        if (integrationId != m.integrationId) revert IntegrationMismatch(marketId, integrationId);
    }

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

    function _marketForPledge(
        uint256 marketId
    ) private view returns (Market memory m) {
        m = IMarketRegistry(_MARKET_REGISTRY).getMarket(marketId);
        address vt = m.vaultToken;
        if (
            vt == address(0) || !IVaultTokenFactory(_VAULT_TOKEN_FACTORY).isVaultToken(vt)
                || IVaultToken(vt).marketId() != marketId || IVaultToken(vt).spoke() != m.spoke
                || IVaultToken(vt).hub() != m.hub
        ) revert UnknownMarket(marketId);
    }

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
        if (!IMarketRegistry(_MARKET_REGISTRY).isApprovedDebtReserve(account.spoke, debtReserveId)) {
            revert UnknownDebtReserve(account.spoke, debtReserveId);
        }
        _checkReceiver(receiver, def);
        if (_isFrozen(msg.sender)) revert AddressIsFrozen(msg.sender);
        if (_isFrozen(receiver)) revert AddressIsFrozen(receiver);
        uint256 nonce = _s().borrowNonce[proxy];
        if (nonce != expectedNonce) revert BadNonce(nonce, expectedNonce);
        _s().borrowNonce[proxy] = nonce + 1;
        IRiskModule(_RISK_MODULE).preBorrowCheck(proxy, debtReserveId, amount);
        ICollateralizationDebtMark(_COLLATERALIZATION).markIndebted(proxy);
        _borrowStep(proxy, account.spoke, debtReserveId, amount, receiver);
        uint256 hf = IRiskModule(_RISK_MODULE).postHealthCheck(proxy, minHealthFactor);
        emit Borrowed(msg.sender, marketId, debtReserveId, receiver, amount, nonce, hf);
        _release();
        drawn = amount;
    }

    function _borrowPauseGate(
        uint256 marketId,
        uint256 debtReserveId
    ) private view returns (DebtReserveDef memory def) {
        Market memory m = IMarketRegistry(_MARKET_REGISTRY).getMarket(marketId);
        _requireNone(m.hub);
        def = IMarketRegistry(_MARKET_REGISTRY).getDebtReserve(m.spoke, debtReserveId);
        if (def.fundingHub != m.hub) _requireNone(def.fundingHub);
    }

    function _requireNone(
        address hub
    ) private view {
        (PauseState state,) = _pauseOf(hub);
        if (state == PauseState.Frozen) revert ApplicationFrozen();
        if (state == PauseState.Paused) revert ApplicationPaused();
    }

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
            refused = IMarketRegistry(reg).integrationIdOf(receiver) != 0
                || receiver == IMarketRegistry(reg).PAYOUT_ESCROW() || receiver == IMarketRegistry(reg).flashSource()
                || IMarketRegistry(reg).isRecordedHub(receiver) || IMarketRegistry(reg).getSpoke(receiver).approved
                || IAaveV4Hub(def.fundingHub).isSpokeListed(def.hubAssetId, receiver)
                || IAaveV4Hub(def.fundingHub).isUnderlyingListed(receiver);
        }
        if (refused) revert InvalidReceiver(receiver);
    }

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
        // The proxy must end at its start balance.
        // forge-lint: disable-next-line(incorrect-strict-equality)
        if (IERC20(asset).balanceOf(proxy) != balanceBefore) revert BalanceDeltaMismatch();
    }

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
            // Collateralization reads `borrowCount` itself and clears the mark only at 0.
            if (debtAfter == 0) ICollateralizationDebtMark(_COLLATERALIZATION).markDebtFree(proxy);
        }
        _release();
        spent = paid;
    }
}
// forge-lint: disable-end(reentrancy-events)
