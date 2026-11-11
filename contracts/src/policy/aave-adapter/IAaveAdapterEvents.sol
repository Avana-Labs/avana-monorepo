// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @title IAaveAdapterEvents
/// @notice Events of the AaveAdapter: proxy creation, pledge, re-credit, borrow, repay, withdrawal, partial removal,
/// repay with collateral and seized-unit burn. Accounts are named by market; positions by `positionKey`.
interface IAaveAdapterEvents {
    /// @notice The wallet's proxy for a market was created and bound.
    /// @param wallet The bound wallet.
    /// @param spoke The bound CDP Spoke.
    /// @param marketId The bound market.
    /// @param proxy The new proxy.
    /// @custom:spec REQ-ADAPTER-066, REQ-PROXY-056, Q-076, Q-225, Q-375
    event UserProxyCreated(address indexed wallet, address indexed spoke, uint256 indexed marketId, address proxy);

    /// @notice A position was pledged, credited, minted and supplied as collateral.
    /// @param wallet The depositor.
    /// @param marketId The market.
    /// @param vaultToken The market's vault token.
    /// @param proxy The account.
    /// @param recordId Collateralization record identifier.
    /// @param integrationId The position's AMM integration.
    /// @param positionKey The position.
    /// @param units Credited units minted and supplied.
    /// @custom:spec REQ-ADAPTER-065, Q-076
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
    /// @param wallet The borrowing wallet.
    /// @param marketId The account's market.
    /// @param debtReserveId The debt reserve borrowed.
    /// @param receiver Recipient of the asset.
    /// @param amount Amount drawn and forwarded, base units.
    /// @param nonce The consumed borrow nonce.
    /// @param healthFactorAfter Health factor after the borrow, WAD.
    /// @custom:spec REQ-PROXY-024, BOR-014, Q-076
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
    /// @param payer `msg.sender`, whose funds were pulled and refunded.
    /// @param borrower The account's wallet.
    /// @param marketId The account's market.
    /// @param debtReserveId The debt reserve repaid.
    /// @param spent Amount consumed by `Spoke.repay`, base units.
    /// @param debtAfter Remaining debt in the reserve, base units. The payer's refund is the pulled amount minus `spent`.
    /// @param repayAll Whether the call was a repay-all.
    /// @custom:spec REQ-PROXY-032, REQ-ADAPTER-085, REP-011, Q-076, Q-212, Q-269
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
    /// @param wallet The account's wallet.
    /// @param marketId The market.
    /// @param vaultToken The market's vault token.
    /// @param positionKey The released position.
    /// @param units Units withdrawn and burned.
    /// @param withDebt Whether the account had debt at the withdrawal step.
    /// @param healthFactorAfter Health factor after the withdrawal, WAD; `type(uint256).max` when debt-free.
    /// @custom:spec REQ-PROXY-039, WDR-018, Q-076
    event CollateralWithdrawn(
        address indexed wallet,
        uint256 indexed marketId,
        address indexed vaultToken,
        bytes32 positionKey,
        uint256 units,
        bool withDebt,
        uint256 healthFactorAfter
    );

    /// @notice Seized units were burned from LPVaultSwap.
    /// @param marketId The market.
    /// @param vaultToken The market's vault token.
    /// @param units Units burned.
    /// @custom:spec REQ-ADAPTER-070, Q-224
    event SeizedUnitsBurned(uint256 indexed marketId, address indexed vaultToken, uint256 units);

    /// @notice Units added to a pledged position were credited, minted and supplied.
    /// @param wallet The depositor of record.
    /// @param marketId The market.
    /// @param vaultToken The market's vault token.
    /// @param recordId Collateralization record identifier.
    /// @param positionKey The position.
    /// @param added Units credited.
    /// @param rescueUnits Units of `added` booked as rescue units.
    /// @custom:spec REQ-ADAPTER-079, Q-254
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
    /// @param wallet The account's wallet.
    /// @param marketId The market.
    /// @param vaultToken The market's vault token.
    /// @param positionKey The position.
    /// @param units Units withdrawn and burned.
    /// @param amounts Raw amount of each pool token paid, market token order.
    /// @param withDebt Whether the account had debt.
    /// @param healthFactorAfter Rescue-excluded health factor after the call, WAD; `type(uint256).max` when debt-free.
    /// @custom:spec REQ-ADAPTER-078, WDR-031, Q-254
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
    /// @param wallet The account's wallet, which received `debtAssetToWallet`.
    /// @param marketId The market.
    /// @param vaultToken The market's vault token.
    /// @param positionKey The position.
    /// @param units Units released.
    /// @param debtReserveId The debt reserve repaid.
    /// @param debtRepaid Debt repaid, base units.
    /// @param debtAssetToWallet Debt asset sent to the wallet, base units.
    /// @param healthFactorBefore Aave health factor before, WAD.
    /// @param healthFactorAfter Aave health factor after, WAD; `type(uint256).max` when debt-free.
    /// @custom:spec REQ-ADAPTER-080, REP-021, Q-255
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
    /// @param proxy The account.
    /// @param marketId The market.
    /// @param units Units supplied.
    /// @param shares Supplied shares the Spoke credited.
    /// @custom:spec REQ-PROXY-047
    event CollateralSupplied(address indexed proxy, uint256 indexed marketId, uint256 units, uint256 shares);

    /// @notice The vault-token reserve was disabled as collateral for a proxy whose supply reached 0.
    /// @param proxy The account.
    /// @param reserveId The vault-token reserve.
    /// @custom:spec REQ-PROXY-046
    event CollateralDisabled(address indexed proxy, uint256 reserveId);
}
