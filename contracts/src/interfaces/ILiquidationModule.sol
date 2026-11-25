// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @title ILiquidationModule
/// @notice Partial liquidation in kind. Anyone repays part of an account's debt through Aave's standard
/// `liquidationCall`; Aave sizes the repayment and seizes vault tokens with its dynamic bonus; this module burns the
/// seized tokens and unwinds only the liquidity worth them at oracle prices, starting with the position that has the
/// least excess value. Both pool tokens go to the liquidator, and Avana's share of the bonus goes to the fee recipient
/// in the same tokens. Works the same for the Full range and the Custom range market of a pool.
/// @dev Not upgradeable, no admin, no funds between calls. It is every vault token's only receiver of seized units, so a
/// direct `liquidationCall` from any other address reverts. Needs the AccessManager roles for `LPVault.unwind` and each
/// vault token's `burn`. The design record is `contracts/design/liquidation.md`.
interface ILiquidationModule {
    /// @notice Arguments of `liquidate`.
    /// @param marketId The band market of the account (Full range or Custom range).
    /// @param debtReserveId The Spoke reserve of the debt to repay.
    /// @param account The Aave user: the wallet's account proxy in the market.
    /// @param debtToCover Most debt to repay, pulled from the caller; Aave may take less and the rest is refunded.
    /// @param minAmount0 Least token0 the receiver must get.
    /// @param minAmount1 Least token1 the receiver must get.
    /// @param receiver Receiver of the liquidator's pool tokens.
    struct LiquidationParams {
        uint256 marketId;
        uint256 debtReserveId;
        address account;
        uint256 debtToCover;
        uint256 minAmount0;
        uint256 minAmount1;
        address receiver;
    }

    /// @notice What a liquidation did.
    /// @param debtRepaid Debt Aave took from the caller.
    /// @param seized Vault-token units Aave seized and this module burned.
    /// @param feeUnits The part of `seized` paid to the fee recipient.
    /// @param creditUnwound Credit the LPVault removed from the account's positions.
    /// @param amount0 Token0 sent to the receiver.
    /// @param amount1 Token1 sent to the receiver.
    /// @param fee0 Token0 sent to the fee recipient.
    /// @param fee1 Token1 sent to the fee recipient.
    struct LiquidationResult {
        uint256 debtRepaid;
        uint256 seized;
        uint256 feeUnits;
        uint256 creditUnwound;
        uint256 amount0;
        uint256 amount1;
        uint256 fee0;
        uint256 fee1;
    }

    /// @notice One step of the unwind plan.
    /// @param positionKey The position.
    /// @param credit Credit to unwind from it.
    /// @param units Seized units its liquidity covers.
    struct UnwindStep {
        bytes32 positionKey;
        uint128 credit;
        uint256 units;
    }

    /// @notice A zero address, or an address the call cannot take.
    error InvalidAddress(address account);
    /// @notice A zero `debtToCover`.
    error InvalidAmount();
    /// @notice The market's Aave reserve has not passed activation.
    error MarketNotActive(uint256 marketId);
    /// @notice Aave seized nothing.
    error NothingSeized(address account);
    /// @notice The receiver's token amount is below its minimum.
    /// @param index 0 for token0, 1 for token1.
    error BelowMinimum(uint256 index, uint256 received, uint256 minimum);
    /// @notice The RiskModule names another LiquidationModule, or has no LPVault.
    error InvalidDeployment();

    /// @notice An account was liquidated.
    event Liquidated(
        address indexed account,
        uint256 indexed marketId,
        address indexed liquidator,
        uint256 debtReserveId,
        uint256 debtRepaid,
        uint256 seized,
        uint256 creditUnwound,
        uint256 amount0,
        uint256 amount1
    );
    /// @notice Avana's share of a liquidation's bonus was paid in the pool's tokens.
    event FeePaid(
        address indexed account,
        uint256 indexed marketId,
        address indexed recipient,
        uint256 units,
        uint256 fee0,
        uint256 fee1
    );

    /// @notice Liquidates `p.account` in `p.marketId`: repays debt through Aave, unwinds the seized credit, pays out
    /// both pool tokens.
    /// @dev Open to anyone. Reverts with Aave's errors when the account is healthy, and `NothingSeized`,
    /// `BelowMinimum`, `MarketNotActive`, `InvalidAddress` or `InvalidAmount`. A small account whose credit is a few
    /// units below its supply (Hub share rounding) pays the shortfall out of the liquidator's tokens.
    function liquidate(
        LiquidationParams calldata p
    ) external returns (LiquidationResult memory r);

    /// @notice The unwind plan for `units` seized from `account` in `marketId` at the oracle price now: positions with
    /// the least excess value first, each covering at most its worth.
    /// @return steps The positions to unwind, in order.
    /// @return shortfall Units no position covers (only Hub rounding dust in practice).
    function previewUnwind(
        address account,
        uint256 marketId,
        uint256 units
    ) external view returns (UnwindStep[] memory steps, uint256 shortfall);

    /// @notice The RiskModule that lists the markets and holds the fee settings.
    function RISK_MODULE() external view returns (address riskModule);

    /// @notice The LPVault that holds the positions.
    function LP_VAULT() external view returns (address lpVault);
}
