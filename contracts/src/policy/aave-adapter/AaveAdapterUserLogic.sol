// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAaveV4Hub} from "../../interfaces/external/aave/IAaveV4Hub.sol";
import {IAaveV4Spoke} from "../../interfaces/external/aave/IAaveV4Spoke.sol";
import {ICollateralization} from "../../legacy/ICollateralization.sol";
import {ILegacyVaultToken} from "../../legacy/ILegacyVaultToken.sol";
import {ILegacyVaultTokenFactory} from "../../legacy/ILegacyVaultTokenFactory.sol";
import {ILegacyRiskModule} from "../../legacy/risk-module/ILegacyRiskModule.sol";
import {IProxyManager} from "../../proxy/proxy-manager/IProxyManager.sol";
import {Market} from "../../types/MarketTypes.sol";
import {PositionRef} from "../../types/PositionTypes.sol";
import {IMarketRegistry} from "../market-registry/IMarketRegistry.sol";
import {DebtReserveDef} from "../market-registry/types/MarketRegistryTypes.sol";
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
        Market memory m = _pledgeGates(marketId, position.integrationId);
        uint256 reserveId;
        (proxy, reserveId) = _proxyForPledge(marketId, m.spoke, m.vaultToken);
        (recordId, credited) = _custodyAndSupply(proxy, m, reserveId, position.positionKey);
        emit CollateralAdded(
            msg.sender, marketId, m.vaultToken, proxy, recordId, position.integrationId, position.positionKey, credited
        );
        _release();
    }

    /// @dev Pledge gates checked before the proxy exists.
    function _pledgeGates(
        uint256 marketId,
        uint32 integrationId
    ) private view returns (Market memory m) {
        m = _marketForPledge(marketId);
        if (!IMarketRegistry(_MARKET_REGISTRY).getSpoke(m.spoke).approved) revert UnknownSpoke(m.spoke);
        if (integrationId != m.integrationId) revert IntegrationMismatch(marketId, integrationId);
    }

    function _custodyAndSupply(
        address proxy,
        Market memory m,
        uint256 reserveId,
        bytes32 positionKey
    ) private returns (uint256 recordId, uint128 credited) {
        ILegacyVaultToken vt = ILegacyVaultToken(m.vaultToken);
        if (!vt.isValidProxy(proxy)) vt.addValidProxy(proxy);
        int256 gapBefore = _gap(m.vaultToken);
        (recordId, credited) =
            ICollateralization(_COLLATERALIZATION).pledge(msg.sender, proxy, m.vaultToken, positionKey, false);
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
            vt == address(0) || !ILegacyVaultTokenFactory(_VAULT_TOKEN_FACTORY).isVaultToken(vt)
                || ILegacyVaultToken(vt).marketId() != marketId || ILegacyVaultToken(vt).spoke() != m.spoke
                || ILegacyVaultToken(vt).hub() != m.hub
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
        (address proxy, AdapterAccount memory account) = _accountOf(msg.sender, marketId);
        DebtReserveDef memory def = IMarketRegistry(_MARKET_REGISTRY).getDebtReserve(account.spoke, debtReserveId);
        if (!def.approved) revert UnknownDebtReserve(account.spoke, debtReserveId);
        _checkReceiver(receiver, def);
        uint256 nonce = _s().borrowNonce[proxy];
        if (nonce != expectedNonce) revert BadNonce(nonce, expectedNonce);
        _s().borrowNonce[proxy] = nonce + 1;
        ILegacyRiskModule(_RISK_MODULE).preBorrowCheck(proxy, debtReserveId, amount);
        ICollateralization(_COLLATERALIZATION).markIndebted(proxy);
        _borrowStep(proxy, account.spoke, debtReserveId, amount, receiver);
        uint256 hf = ILegacyRiskModule(_RISK_MODULE).postHealthCheck(proxy, minHealthFactor);
        emit Borrowed(msg.sender, marketId, debtReserveId, receiver, amount, nonce, hf);
        _release();
        drawn = amount;
    }

    function _checkReceiver(
        address receiver,
        DebtReserveDef memory def
    ) private view {
        bool refused = receiver == address(0) || _s().walletOf[receiver] != address(0) || receiver == address(this)
            || receiver == _COLLATERALIZATION || receiver == _LP_VAULT_SWAP || receiver == _authority()
            || receiver == _MARKET_REGISTRY || receiver == _PARAMETER_STORE || receiver == _RISK_MODULE
            || receiver == _PROXY_MANAGER;
        if (!refused) {
            address reg = _MARKET_REGISTRY;
            refused = ILegacyVaultTokenFactory(_VAULT_TOKEN_FACTORY).integrationIdOf(receiver) != 0
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
            if (debtAfter == 0) ICollateralization(_COLLATERALIZATION).markDebtFree(proxy);
        }
        _release();
        spent = paid;
    }
}
// forge-lint: disable-end(reentrancy-events)
