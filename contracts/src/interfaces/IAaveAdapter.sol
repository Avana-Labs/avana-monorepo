// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @title IAaveAdapter
/// @notice The only door for users. It pledges NFT positions to the band market they fit, adds liquidity, withdraws a
/// whole NFT or part of one, borrows, repays and collects fees. Each wallet gets one account per market: a thin proxy
/// that is the Aave user and approves this adapter as its position manager in its constructor.
/// @dev Not upgradeable and holds no admin role. It owns no funds between calls: vault tokens are minted to it and
/// supplied in the same call, and withdrawn vault tokens are burned in the same call. Aave's own health check guards
/// every withdraw and borrow. The design record is `contracts/design/adapter.md`.
interface IAaveAdapter {
    /// @notice A zero address, or an address the call cannot take.
    error InvalidAddress(address account);
    /// @notice A zero amount.
    error InvalidAmount();
    /// @notice No market of the pool takes a position on these ticks: it is neither full range nor inside the Custom
    /// range band. The app suggests Full range.
    error NoMarketFits(bytes32 pool, int24 tickLower, int24 tickUpper);
    /// @notice The market is listed but its Aave reserve has not passed activation.
    error MarketNotActive(uint256 marketId);
    /// @notice The wallet has no account in the market.
    error NoAccount(address wallet, uint256 marketId);
    /// @notice The position is not pledged by the caller's account.
    error NotPositionOwner(bytes32 positionKey, address wallet);
    /// @notice There is no debt to repay.
    error NoDebt(address account, uint256 reserveId);
    /// @notice A withdrawal allowance is already open in this call.
    error AllowanceOpen();
    /// @notice The operator may not withdraw this: another position, more than allowed, or the whole NFT.
    error WithdrawNotAllowed(bytes32 positionKey, uint128 liquidity);
    /// @notice The account's health factor after an allowed withdrawal is below what it was before.
    error HealthFactorDecreased(uint256 before, uint256 afterCall);

    /// @notice A wallet's account in a market was deployed.
    event AccountCreated(address indexed wallet, uint256 indexed marketId, address account);
    /// @notice A position was pledged and its credit supplied to Aave as vault tokens.
    event Pledged(address indexed wallet, uint256 indexed marketId, bytes32 indexed positionKey, uint128 credit);
    /// @notice Liquidity was added to a pledged position and the new credit supplied.
    event LiquidityAdded(address indexed wallet, bytes32 indexed positionKey, uint128 liquidity, uint128 credit);
    /// @notice A position was withdrawn, whole (`liquidity == 0`) or in part, and `burned` vault tokens left Aave.
    event Withdrawn(
        address indexed wallet,
        bytes32 indexed positionKey,
        address indexed recipient,
        uint128 liquidity,
        uint256 burned
    );
    /// @notice A wallet let `operator` withdraw up to `maxLiquidity` of a position for one call.
    event WithdrawAllowed(
        address indexed wallet, bytes32 indexed positionKey, address indexed operator, uint128 maxLiquidity
    );
    /// @notice A wallet borrowed `amount` of a debt reserve.
    event Borrowed(
        address indexed wallet, uint256 indexed marketId, uint256 indexed reserveId, uint256 amount, address recipient
    );
    /// @notice `payer` repaid `amount` of a wallet's debt.
    event Repaid(
        address indexed wallet, uint256 indexed marketId, uint256 indexed reserveId, uint256 amount, address payer
    );

    /// @notice Pledges a position to the market it fits and supplies its floor credit to Aave as collateral.
    /// @dev Routing: a full-range position goes to the pool's Full range market; any other position to its Custom range
    /// market if fully inside that band; else `NoMarketFits`. Deploys the caller's account on its first pledge in the
    /// market. The caller approves the LPVault for the NFT first. Pledging works at any health factor; a full supply
    /// cap or a frozen reserve stops it in Aave.
    /// @param positionKey The position (the NFT's token ID for an NFPM, or the AMM's key).
    /// @return marketId The market the position went to.
    /// @return credit The credit supplied, in band units.
    function pledge(
        bytes32 positionKey
    ) external returns (uint256 marketId, uint128 credit);

    /// @notice Adds liquidity to one of the caller's pledged positions and supplies the new credit.
    /// @dev The caller approves the LPVault for both tokens; what the AMM does not use is refunded.
    /// @return liquidity Liquidity added.
    /// @return credit Credit added.
    /// @return amount0 Token0 used.
    /// @return amount1 Token1 used.
    function addLiquidity(
        bytes32 positionKey,
        uint256 amount0Desired,
        uint256 amount1Desired,
        uint256 amount0Min,
        uint256 amount1Min
    ) external returns (uint128 liquidity, uint128 credit, uint256 amount0, uint256 amount1);

    /// @notice Withdraws one of the caller's positions: the whole NFT, or part of its liquidity as tokens.
    /// @dev The operator of an open `allowWithdraw` may also call it for that position, in part only and within its
    /// allowance. `liquidity` of zero, or at least the record's, sends the whole NFT and its held fees to `recipient`. Any
    /// other amount removes that liquidity and sends both tokens. The account's supply then drops to its remaining
    /// credit, and Aave reverts the call if the health factor would fall below one.
    /// @param positionKey The position.
    /// @param liquidity Liquidity to remove; zero for the whole NFT.
    /// @param amount0Min Least token0 for a partial withdraw.
    /// @param amount1Min Least token1 for a partial withdraw.
    /// @param recipient Receiver of the NFT or the tokens.
    /// @return burned Vault tokens withdrawn from Aave and burned.
    function withdraw(
        bytes32 positionKey,
        uint128 liquidity,
        uint256 amount0Min,
        uint256 amount1Min,
        address recipient
    ) external returns (uint256 burned);

    /// @notice Lets `operator` withdraw up to `maxLiquidity` of the caller's position, in part only, while it runs
    /// `IWithdrawReceiver(operator).onWithdrawAllowed`; the allowance ends when that call returns.
    /// @dev Repay with collateral: the operator repays the debt (anyone may), then calls `withdraw` for the position.
    /// No allowance outlives the call, and the call reverts `HealthFactorDecreased` unless the account's health
    /// factor afterwards is at least what it was before. `AllowanceOpen` when called inside another allowance.
    /// @param operator The contract that receives the callback and may withdraw.
    /// @param positionKey The caller's position.
    /// @param maxLiquidity Most liquidity the operator may remove, over all its `withdraw` calls.
    /// @param data Passed unchanged to the operator.
    function allowWithdraw(
        address operator,
        bytes32 positionKey,
        uint128 maxLiquidity,
        bytes calldata data
    ) external;

    /// @notice Borrows a debt reserve of the market's Spoke against the caller's account and sends it to `recipient`.
    /// @dev The RiskModule's `checkBorrow` gates it (registered reserve, a keeper, First-Loss coverage); Aave checks
    /// the health factor.
    function borrow(
        uint256 marketId,
        uint256 reserveId,
        uint256 amount,
        address recipient
    ) external;

    /// @notice Repays up to `amount` of `wallet`'s debt in the market, paid by the caller.
    /// @dev Anyone may repay for anyone. Pulls only what is owed, so `type(uint256).max` repays all.
    /// @return repaid The amount repaid.
    function repay(
        uint256 marketId,
        uint256 reserveId,
        uint256 amount,
        address wallet
    ) external returns (uint256 repaid);

    /// @notice Collects the fees of the caller's named positions in a market and sends them to the caller.
    /// @return amounts0 Token0 fees per position.
    /// @return amounts1 Token1 fees per position.
    function collectFees(
        uint256 marketId,
        bytes32[] calldata positionKeys
    ) external returns (uint256[] memory amounts0, uint256[] memory amounts1);

    /// @notice The wallet's account in a market; zero before its first pledge.
    function accountOf(
        address wallet,
        uint256 marketId
    ) external view returns (address account);

    /// @notice The address the wallet's account in a market has, or will have once deployed.
    function predictAccount(
        address wallet,
        uint256 marketId
    ) external view returns (address account);

    /// @notice The RiskModule that routes pledges and gates borrows.
    function RISK_MODULE() external view returns (address riskModule);

    /// @notice The LPVault that holds the NFTs.
    function LP_VAULT() external view returns (address lpVault);
}
