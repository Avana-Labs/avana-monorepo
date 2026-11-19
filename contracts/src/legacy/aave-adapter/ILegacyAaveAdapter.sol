// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {PositionRef} from "../../types/PositionTypes.sol";
import {IAaveAdapterBase} from "./IAaveAdapterBase.sol";
import {RepayWithCollateralParams} from "./types/AaveAdapterTypes.sol";
import {IAccessManaged} from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";

/// @title ILegacyAaveAdapter
/// @notice The chain's single entry point for every borrower action on every CDP Spoke.
/// @dev UUPS proxy; only the AccessManager's governance role can upgrade it. Holds no tokens between calls.
interface ILegacyAaveAdapter is IAaveAdapterBase, IAccessManaged {
    /// @notice Initializes the proxy storage.
    /// @dev Runs once; sets the AccessManager that authorizes upgrades.
    function initialize(
        address authority
    ) external;

    /// @notice Removes part of one record's credited units; the position stays in custody.
    /// @param units Credited units removed; must be below the record's credited units.
    /// @param minHealthFactor Caller's minimum rescue-excluded health factor after a removal with debt, WAD.
    /// @return amounts Raw amount of each pool token paid to the depositor of record.
    function removeLiquidity(
        uint256 marketId,
        PositionRef calldata position,
        uint128 units,
        uint256[] calldata minAmounts,
        uint256 deadline,
        uint256 minHealthFactor
    ) external returns (uint256[] memory amounts);

    /// @notice Credits units added to a pledged position.
    /// @dev Depositor of record only.
    /// @param topUp Integration-encoded LP amount for a fungible-share position; empty for an NFT position.
    function recredit(
        uint256 marketId,
        PositionRef calldata position,
        bytes calldata topUp,
        uint256 deadline
    ) external returns (uint128 added);

    /// @notice Repays one debt reserve with units released from one record, via LPVaultSwap's flash deleverage.
    /// @dev While debt remains, reverts unless the health factor ends >= `max(before, minHealthFactor)`.
    function repayWithCollateral(
        RepayWithCollateralParams calldata p
    ) external returns (uint256 debtRepaid, uint256 debtAssetToWallet);

    /// @notice Burns `units` of a market's vault token from LPVaultSwap's balance.
    /// @dev Only LPVaultSwap while it holds the Lock.
    function burnSeized(
        uint256 marketId,
        address vaultToken,
        uint256 units
    ) external;

    /// @notice Repays `amount` of the session's debt reserve on the session's proxy with funds from LPVaultSwap.
    /// @dev Only LPVaultSwap inside the Adapter's open deleverage session.
    /// @param amount Debt asset LPVaultSwap provides, base units.
    function deleverageRepay(
        address proxy,
        uint256 debtReserveId,
        uint256 amount
    ) external returns (uint256 repaid);

    /// @notice Withdraws and burns the session's units and has Collateralization release them to LPVaultSwap.
    /// @dev Same caller and session checks as `deleverageRepay`; runs only after it.
    /// @param minAmounts Least raw amount of each pool token, market token order.
    function deleverageRelease(
        address proxy,
        PositionRef calldata position,
        uint128 units,
        uint256[] calldata minAmounts
    ) external returns (uint256[] memory amounts, bool closed);

    /// @notice Pledges one AMM position into a market, creating the wallet's proxy for that market if needed.
    function pledge(
        uint256 marketId,
        PositionRef calldata position,
        uint256 deadline
    ) external returns (address proxy, uint256 recordId, uint128 credited);

    /// @notice Borrows `amount` of an approved debt asset on the caller's account and sends it to `receiver`.
    /// @dev Consumes `expectedNonce`.
    /// @param minHealthFactor Caller's minimum health factor after the borrow, WAD; 0 for none.
    function borrow(
        uint256 marketId,
        uint256 debtReserveId,
        uint256 amount,
        address receiver,
        uint256 deadline,
        uint256 minHealthFactor,
        uint256 expectedNonce
    ) external returns (uint256 drawn);

    /// @notice Repays one debt reserve of `borrower`'s account for a market with the caller's funds.
    /// @dev Any caller pays; reads no MarketRegistry or price, so repay always works.
    /// @param maxRepaySpend Most the payer allows to be pulled, base units.
    /// @param repayAll True to clear the reserve's whole debt or revert.
    function repay(
        address borrower,
        uint256 marketId,
        uint256 debtReserveId,
        uint256 maxRepaySpend,
        bool repayAll,
        uint256 deadline
    ) external returns (uint256 spent);

    /// @notice Withdraws one record's units, burns them and returns the whole position to its depositor of record.
    /// @param units The record's credited units after reconcile.
    /// @param minHealthFactor Caller's minimum health factor after a with-debt withdrawal, WAD.
    function withdraw(
        uint256 marketId,
        PositionRef calldata position,
        uint256 units,
        uint256 deadline,
        uint256 minHealthFactor
    ) external;

    /// @notice Repays every named debt reserve in full, then makes a debt-free withdrawal of one record.
    /// @dev Reverts `DebtRemaining` if any debt reserve of the account is still borrowed.
    /// @param units The record's credited units after reconcile.
    /// @param maxRepaySpends Cap for each listed reserve, base units of its asset.
    function repayAllAndWithdraw(
        uint256 marketId,
        PositionRef calldata position,
        uint256 units,
        uint256[] calldata debtReserveIds,
        uint256[] calldata maxRepaySpends,
        uint256 deadline
    ) external;

    /// @notice Returns the position of a record at 0 credited units to its depositor of record.
    /// @dev Depositor of record only.
    function releaseZeroCredit(
        uint256 marketId,
        PositionRef calldata position,
        uint256 deadline
    ) external;

    /// @notice Collects fees a custodied position earned and pays them to the depositor of record.
    /// @dev Depositor of record only. Reverts `FeesRolledIn` for AMM protocols that roll fees into the position.
    /// @return fees Fees paid to the depositor, raw units of each pool token in the market's token order.
    function collectFees(
        uint256 marketId,
        PositionRef calldata position,
        uint256 deadline
    ) external returns (uint256[] memory fees);

    /// @notice Clears a proxy's stale indebted mark once its Spoke account has no debt.
    function refreshDebtMark(
        address proxy
    ) external;

    /// @notice Returns the wallet's proxy for a market.
    /// @return proxy The proxy, or `address(0)` before the wallet's first pledge to the market.
    function proxyOf(
        address wallet,
        uint256 marketId
    ) external view returns (address proxy);

    /// @notice Returns the wallet bound to a proxy.
    /// @return wallet The bound wallet, or `address(0)` if `proxy` was not created by this Adapter.
    function walletOf(
        address proxy
    ) external view returns (address wallet);

    /// @notice Returns the binding the Adapter stored for a proxy at creation.
    /// @return spoke The bound CDP Spoke, or `address(0)` if `proxy` was not created by this Adapter.
    function accountOf(
        address proxy
    ) external view returns (address spoke, uint256 marketId, address vaultToken, uint256 reserveId);

    /// @notice Returns the CREATE2 address of `(wallet, market)`'s proxy, deployed or not.
    function predictProxy(
        address wallet,
        uint256 marketId
    ) external view returns (address proxy);

    /// @notice Returns the next expected borrow nonce of a proxy.
    /// @dev Starts at 0 and rises by 1 per successful borrow of any asset.
    function borrowNonce(
        address proxy
    ) external view returns (uint256 nonce);

    /// @notice Returns the ProxyManager (implementation immutable).
    function PROXY_MANAGER() external view returns (address proxyManager);

    /// @notice Returns Collateralization (implementation immutable).
    function COLLATERALIZATION() external view returns (address collateralization);

    /// @notice Returns the LegacyRiskModule (implementation immutable).
    function RISK_MODULE() external view returns (address riskModule);

    /// @notice Returns the MarketRegistry (implementation immutable).
    function MARKET_REGISTRY() external view returns (address marketRegistry);

    /// @notice Returns the ParameterStore (implementation immutable).
    function PARAMETER_STORE() external view returns (address parameterStore);

    /// @notice Returns the chain's LPVaultSwap, the only caller of `burnSeized` (implementation immutable).
    function LP_VAULT_SWAP() external view returns (address lpVaultSwap);

    /// @notice Returns the protocol Lock (implementation immutable).
    function LOCK() external view returns (address lock);

    /// @notice Returns the chain's VaultTokenFactory (implementation immutable).
    function VAULT_TOKEN_FACTORY() external view returns (address vaultTokenFactory);
}
