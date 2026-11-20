// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @title ILPVault
/// @notice Custody of concentrated-liquidity NFT positions pledged to band markets. One record per position holds its
/// owner account, market, recorded liquidity and floor credit. Credit is fixed at pledge from the position's ticks and
/// liquidity and never reads a pool price. Fees are never collateral: they are paid out per position.
/// @dev Every mutating function is restricted through the AccessManager and runs under one transient reentrancy guard.
/// The LPVault applies no health check: the caller checks the account after any credit decrease.
interface ILPVault {
    /// @notice A band market: one pool and its fixed band ticks `[bandLower, bandUpper]`.
    /// @param pool The pool address as a word, or the pool ID of a singleton AMM; zero means not listed.
    /// @param token0 The pool's first token (the wrapped native token for a native leg).
    /// @param token1 The pool's second token.
    /// @param bandLower Lower band tick `A`.
    /// @param bandUpper Upper band tick `B`.
    /// @param totalCredit Sum of the credit of the market's open records.
    struct Market {
        bytes32 pool;
        address token0;
        address token1;
        int24 bandLower;
        int24 bandUpper;
        uint128 totalCredit;
    }

    /// @notice The record of a pledged position.
    /// @param account The owner account; zero means no record.
    /// @param marketId The band market the position is pledged to.
    /// @param liquidity Liquidity the record holds; live liquidity can only be higher.
    /// @param credit Floor credit of `liquidity`, in band-liquidity units.
    struct Position {
        address account;
        uint96 marketId;
        uint128 liquidity;
        uint128 credit;
    }

    /// @notice A constructor argument is zero or inconsistent.
    error InvalidDeployment();
    /// @notice The market ID is zero, already listed, or above `type(uint96).max`.
    error InvalidMarketId(uint256 marketId);
    /// @notice The market is not listed.
    error MarketNotListed(uint256 marketId);
    /// @notice The pool is not a canonical pool of the AMM, or it is not usable.
    error InvalidPool(bytes32 pool);
    /// @notice The band is empty, off the pool's tick spacing or outside the tick range.
    error InvalidBand(int24 bandLower, int24 bandUpper);
    /// @notice `from` does not own the NFT, or the NFT did not arrive.
    error NotTokenOwner(bytes32 positionKey);
    /// @notice The position belongs to another pool than the market's.
    error PoolMismatch(bytes32 positionKey, bytes32 pool);
    /// @notice The position is already pledged.
    error AlreadyPledged(bytes32 positionKey);
    /// @notice The position has no record.
    error NotPledged(bytes32 positionKey);
    /// @notice The account already holds `MAX_POSITIONS` positions.
    error TooManyPositions(address account);
    /// @notice The position's floor credit is zero.
    error ZeroCredit(bytes32 positionKey);
    /// @notice A liquidity or credit amount is zero, or above what the record holds.
    error InvalidAmount(bytes32 positionKey, uint256 amount);
    /// @notice The position belongs to another account.
    error NotPositionAccount(bytes32 positionKey, address account);
    /// @notice A token amount is below its minimum.
    /// @param index 0 for token0, 1 for token1.
    error BelowMinimum(uint256 index, uint256 received, uint256 minimum);
    /// @notice The account or recipient is the zero address or the LPVault.
    error InvalidAddress(address account);

    /// @notice A band market was listed.
    event MarketListed(
        uint256 indexed marketId, bytes32 indexed pool, address token0, address token1, int24 bandLower, int24 bandUpper
    );
    /// @notice A position was pledged.
    event PositionPledged(
        bytes32 indexed positionKey,
        address indexed account,
        uint256 indexed marketId,
        address from,
        uint128 liquidity,
        uint128 credit
    );
    /// @notice Liquidity was added to a pledged position.
    event LiquidityAdded(
        bytes32 indexed positionKey,
        address indexed payer,
        uint128 liquidity,
        uint128 credit,
        uint256 amount0,
        uint256 amount1
    );
    /// @notice Part of a pledged position's liquidity was removed for its account.
    event LiquidityRemoved(
        bytes32 indexed positionKey,
        address indexed recipient,
        uint128 liquidity,
        uint128 credit,
        uint256 amount0,
        uint256 amount1
    );
    /// @notice A position's record was closed and the NFT sent to `recipient`.
    event PositionReleased(
        bytes32 indexed positionKey,
        address indexed account,
        address indexed recipient,
        uint128 liquidity,
        uint128 credit
    );
    /// @notice Liquidity worth `credit` was unwound for a liquidation.
    event PositionUnwound(
        bytes32 indexed positionKey,
        address indexed recipient,
        uint128 liquidity,
        uint128 credit,
        uint256 amount0,
        uint256 amount1
    );
    /// @notice A position's fees were paid out.
    event FeesCollected(bytes32 indexed positionKey, address indexed recipient, uint256 amount0, uint256 amount1);
    /// @notice Fees an AMM paid out with a liquidity removal were kept for the position.
    event FeesHeld(bytes32 indexed positionKey, uint256 amount0, uint256 amount1);

    /// @notice Lists a band market for a pool. Write-once per market ID.
    /// @dev Reverts `InvalidMarketId`, `InvalidPool` or `InvalidBand`. A pool can have several markets (a full-range band
    /// and wider or narrower ones); a position chooses its market at pledge.
    /// @param marketId The market ID, nonzero and at most `type(uint96).max`.
    /// @param pool The pool address as a word, or the pool ID of a singleton AMM.
    /// @param bandLower Lower band tick, a multiple of the pool's tick spacing.
    /// @param bandUpper Upper band tick, a multiple of the pool's tick spacing.
    function listMarket(
        uint256 marketId,
        bytes32 pool,
        int24 bandLower,
        int24 bandUpper
    ) external;

    /// @notice Takes custody of an NFT from `from` and records it for `account` with its floor credit.
    /// @dev No health check. Accepts any position fully inside the band, in range or not; a position on exactly the
    /// band's ticks is credited its liquidity. `from` must have approved
    /// the LPVault for the NFT. Reverts `NotInsideBand` (FloorCreditMath) for a position outside the band.
    /// @param from The NFT's current owner.
    /// @param account The owner account of the record.
    /// @param marketId The band market.
    /// @param positionKey The position.
    /// @return credit The credit of the position.
    function pledge(
        address from,
        address account,
        uint256 marketId,
        bytes32 positionKey
    ) external returns (uint128 credit);

    /// @notice Adds liquidity to a pledged position, paid by `payer`, and raises its credit by the new liquidity's.
    /// @dev No health check. Pulls the desired amounts from `payer` and refunds what the AMM did not use.
    /// @param positionKey The pledged position.
    /// @param payer The address the tokens are pulled from; it must have approved the LPVault.
    /// @param amount0Desired Most token0 to add.
    /// @param amount1Desired Most token1 to add.
    /// @param amount0Min Least token0 to add.
    /// @param amount1Min Least token1 to add.
    /// @return liquidity Liquidity added.
    /// @return credit Credit added.
    /// @return amount0 Token0 added.
    /// @return amount1 Token1 added.
    function addLiquidity(
        bytes32 positionKey,
        address payer,
        uint256 amount0Desired,
        uint256 amount1Desired,
        uint256 amount0Min,
        uint256 amount1Min
    ) external returns (uint128 liquidity, uint128 credit, uint256 amount0, uint256 amount1);

    /// @notice Removes part of a pledged position's liquidity to `recipient`; credit drops in proportion.
    /// @dev The caller checks the account's health afterwards. Fees the AMM pays out are kept for the position.
    /// @param positionKey The pledged position.
    /// @param liquidity Liquidity to remove, at most the record's.
    /// @param amount0Min Least token0 to receive.
    /// @param amount1Min Least token1 to receive.
    /// @param recipient Receiver of the principal.
    /// @return credit Credit removed.
    /// @return amount0 Token0 sent.
    /// @return amount1 Token1 sent.
    function removeLiquidity(
        bytes32 positionKey,
        uint128 liquidity,
        uint256 amount0Min,
        uint256 amount1Min,
        address recipient
    ) external returns (uint128 credit, uint256 amount0, uint256 amount1);

    /// @notice Closes a position's record and sends the whole NFT and its held fees to `recipient`.
    /// @dev The caller checks the account's health afterwards.
    /// @param positionKey The pledged position.
    /// @param recipient Receiver of the NFT.
    /// @return credit Credit removed.
    function release(
        bytes32 positionKey,
        address recipient
    ) external returns (uint128 credit);

    /// @notice Unwinds the liquidity worth `credit` of a position, both tokens to `recipient`. Liquidation only.
    /// @dev Removes `ceil(credit · liquidity / recordCredit)` liquidity, capped at the record's, and lowers the
    /// record's credit in proportion, so the credit removed is at least `credit` when the cap does not apply.
    /// @param positionKey The pledged position.
    /// @param credit Credit to unwind.
    /// @param amount0Min Least token0 to receive.
    /// @param amount1Min Least token1 to receive.
    /// @param recipient Receiver of both tokens.
    /// @return liquidity Liquidity removed.
    /// @return creditRemoved Credit removed.
    /// @return amount0 Token0 sent.
    /// @return amount1 Token1 sent.
    function unwind(
        bytes32 positionKey,
        uint128 credit,
        uint256 amount0Min,
        uint256 amount1Min,
        address recipient
    ) external returns (uint128 liquidity, uint128 creditRemoved, uint256 amount0, uint256 amount1);

    /// @notice Collects the fees of the named positions of `account`, each paid to `recipient`.
    /// @param account The owner account of every named position.
    /// @param positionKeys The positions.
    /// @param recipient Receiver of the fees.
    /// @return amounts0 Token0 fees per position.
    /// @return amounts1 Token1 fees per position.
    function collectFees(
        address account,
        bytes32[] calldata positionKeys,
        address recipient
    ) external returns (uint256[] memory amounts0, uint256[] memory amounts1);

    /// @notice Most positions one account can hold.
    function MAX_POSITIONS() external view returns (uint256 maxPositions);

    /// @notice Returns a market; `pool == 0` when not listed.
    function getMarket(
        uint256 marketId
    ) external view returns (Market memory market);

    /// @notice Returns a position's record; `account == 0` when none.
    function getPosition(
        bytes32 positionKey
    ) external view returns (Position memory position);

    /// @notice Returns the positions of an account, in no fixed order.
    function positionsOf(
        address account
    ) external view returns (bytes32[] memory positionKeys);

    /// @notice Returns the summed credit of an account's positions in a market.
    function accountCredit(
        address account,
        uint256 marketId
    ) external view returns (uint256 credit);

    /// @notice Reads a position from its AMM: its pool (zero when none), ticks and live liquidity.
    /// @dev The AaveAdapter routes a pledge from these, before any record exists.
    function positionInfo(
        bytes32 positionKey
    ) external view returns (bytes32 pool, int24 tickLower, int24 tickUpper, uint128 liquidity);

    /// @notice Returns the credit a position would get if pledged to `marketId` now.
    /// @dev Reverts like `pledge` for a position of another pool or outside the band.
    function previewCredit(
        uint256 marketId,
        bytes32 positionKey
    ) external view returns (uint128 credit);

    /// @notice Returns the fees a position would pay out now: held fees plus the AMM's uncollected fees.
    function feesOf(
        bytes32 positionKey
    ) external view returns (uint256 amount0, uint256 amount1);

    /// @notice Whether a guarded call is running; integrators can refuse reads while it is.
    function locked() external view returns (bool isLocked);
}
