// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @title IAaveAdapterEvents
/// @notice Events of the AaveAdapter. Accounts are named by market; positions by `positionKey`.
interface IAaveAdapterEvents {
    /// @notice The wallet's proxy for a market was created and bound.
    event UserProxyCreated(address indexed wallet, address indexed spoke, uint256 indexed marketId, address proxy);

    /// @notice A position was pledged, credited, minted and supplied as collateral.
    event CollateralAdded(
        address indexed wallet,
        uint256 indexed marketId,
        address indexed vaultToken,
        address proxy,
        uint256 recordId,
        uint32 integrationId,
        bytes32 positionKey,
        uint128 units
    );

    /// @notice A debt asset was borrowed and sent to `receiver`.
    /// @param healthFactorAfter Health factor after the borrow, WAD.
    event Borrowed(
        address indexed wallet,
        uint256 indexed marketId,
        uint256 indexed debtReserveId,
        address receiver,
        uint256 amount,
        uint256 nonce,
        uint256 healthFactorAfter
    );

    /// @notice A payer repaid one debt reserve of a borrower's account.
    /// @dev Emitted only when funds moved; `payer != borrower` marks a third-party repay.
    /// @param spent Amount consumed by `Spoke.repay`, base units.
    event Repaid(
        address indexed payer,
        address indexed borrower,
        uint256 indexed marketId,
        uint256 debtReserveId,
        uint256 spent,
        uint256 debtAfter,
        bool repayAll
    );

    /// @notice A record's units were withdrawn and burned and its position returned to the depositor.
    /// @param healthFactorAfter Health factor after the withdrawal, WAD; `type(uint256).max` when debt-free.
    event CollateralWithdrawn(
        address indexed wallet,
        uint256 indexed marketId,
        address indexed vaultToken,
        bytes32 positionKey,
        uint256 units,
        bool withDebt,
        uint256 healthFactorAfter
    );

    event SeizedUnitsBurned(uint256 indexed marketId, address indexed vaultToken, uint256 units);

    /// @notice Units added to a pledged position were credited, minted and supplied.
    event CollateralRecredited(
        address indexed wallet,
        uint256 indexed marketId,
        address indexed vaultToken,
        uint256 recordId,
        bytes32 positionKey,
        uint128 added,
        uint128 rescueUnits
    );

    /// @notice Part of a record's units was removed and its principal paid to the depositor of record.
    /// @param amounts Raw amount of each pool token paid, market token order.
    /// @param healthFactorAfter Rescue-excluded health factor after the call, WAD; `type(uint256).max` when debt-free.
    event CollateralReduced(
        address indexed wallet,
        uint256 indexed marketId,
        address indexed vaultToken,
        bytes32 positionKey,
        uint128 units,
        uint256[] amounts,
        bool withDebt,
        uint256 healthFactorAfter
    );

    /// @notice A debt reserve was repaid with units released from a record.
    /// @param healthFactorBefore Aave health factor before, WAD.
    /// @param healthFactorAfter Aave health factor after, WAD; `type(uint256).max` when debt-free.
    event RepaidWithCollateral(
        address indexed wallet,
        uint256 indexed marketId,
        address indexed vaultToken,
        bytes32 positionKey,
        uint128 units,
        uint256 debtReserveId,
        uint256 debtRepaid,
        uint256 debtAssetToWallet,
        uint256 healthFactorBefore,
        uint256 healthFactorAfter
    );

    /// @notice Vault-token units were supplied to the Spoke for a proxy.
    event CollateralSupplied(address indexed proxy, uint256 indexed marketId, uint256 units, uint256 shares);

    /// @notice The vault-token reserve was disabled as collateral for a proxy whose supply reached 0.
    event CollateralDisabled(address indexed proxy, uint256 reserveId);
}
