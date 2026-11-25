// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @title IRiskModule
/// @notice Avana's rules on one chain. It lists each pool as two band markets in one call (Full range and Custom
/// range, one LTV), checks each market's vault token, oracle and Aave reserve at activation, says which positions a market
/// accepts and what floor credit they earn, and keeps the debt side's First-Loss coverage, the Avana fee and the
/// keeper registry.
/// @dev Not upgradeable. Every setter is restricted through the AccessManager, which maps each to its role. A
/// market's band, LTV and vault token never change after listing. The design record is `contracts/design/risk.md`.
interface IRiskModule {
    /// @notice The kind of a CDP Spoke, which sets the default Custom range width of the pools listed on it.
    enum SpokeKind {
        None,
        Stable,
        Correlated,
        Volatile
    }

    /// @notice The two markets of a pool.
    enum MarketKind {
        FullRange,
        CustomRange
    }

    /// @notice A Custom range width, in ticks below and above the listing tick (1 tick = 0.01% of price).
    struct Width {
        uint24 below;
        uint24 above;
    }

    /// @notice A registered CDP Spoke.
    /// @param hub The Aave V4 Hub that holds the Spoke's vault-token supplies.
    /// @param kind The Spoke's kind; `None` means not registered.
    /// @param priceSpoke The Aave V4 Spoke whose `AaveOracle` prices the tokens of every pool listed on this Spoke: the
    /// Spoke whose token collateral factors and liquidation settings this Spoke's LP markets copy.
    struct SpokeConfig {
        address hub;
        SpokeKind kind;
        address priceSpoke;
    }

    /// @notice Arguments of `listPool`.
    /// @param pool The pool address as a word, or the pool ID of a singleton AMM.
    /// @param spoke The registered CDP Spoke the two reserves are listed on.
    /// @param tickSpacing The pool's tick spacing (the LPVault rejects a band off it).
    /// @param listingTick The tick of the listing price written in the proposal; the Custom range band centres on it.
    /// @param ltvBps The LTV of both markets, basis points: the lower of the two tokens' LTVs on that Spoke.
    /// @param width A per-pool Custom range width; all zero takes the Spoke kind's default.
    /// @param reserveId0 The price Spoke's reserve of the pool's token0, the one the markets' LPOracles read.
    /// @param reserveId1 The price Spoke's reserve of the pool's token1.
    struct ListPoolParams {
        bytes32 pool;
        address spoke;
        int24 tickSpacing;
        int24 listingTick;
        uint16 ltvBps;
        Width width;
        uint256 reserveId0;
        uint256 reserveId1;
    }

    /// @notice A listed band market; its ID is also its LPVault market ID.
    /// @param pool The pool; zero means not listed.
    /// @param spoke The CDP Spoke of its reserve.
    /// @param vaultToken The market's collateral ERC-20, set at activation.
    /// @param lpOracle The market's price source, set at activation.
    /// @param reserveId The Spoke reserve of the vault token, set at activation.
    /// @param priceReserveId0 The price Spoke's reserve of token0 given at listing; the LPOracle must read the same.
    /// @param priceReserveId1 The price Spoke's reserve of token1 given at listing.
    /// @param bandLower Lower band tick.
    /// @param bandUpper Upper band tick.
    /// @param ltvBps The LTV the Aave reserve must carry, basis points.
    /// @param unitDecimals The vault token's decimals: a whole token was worth at least $1 at listing.
    /// @param kind Full range or Custom range.
    /// @param active Whether the Aave reserve passed the activation check.
    struct Market {
        bytes32 pool;
        address spoke;
        address vaultToken;
        address lpOracle;
        uint256 reserveId;
        uint256 priceReserveId0;
        uint256 priceReserveId1;
        int24 bandLower;
        int24 bandUpper;
        uint16 ltvBps;
        uint8 unitDecimals;
        MarketKind kind;
        bool active;
    }

    /// @notice The latest pair of markets listed for a pool.
    struct PoolMarkets {
        uint256 fullRange;
        uint256 customRange;
    }

    /// @notice A borrowable debt reserve of a CDP Spoke.
    /// @param hub The Hub the asset is drawn from; zero means not registered.
    /// @param asset The underlying.
    /// @param assetId The asset's ID on the Hub.
    /// @param firstLossReserve The First-Loss Reserve of `(hub, asset)`.
    struct DebtReserve {
        address hub;
        address asset;
        uint256 assetId;
        address firstLossReserve;
    }

    /// @notice A zero address, or an address the call cannot take.
    error InvalidAddress(address account);
    /// @notice The Spoke is not registered as a CDP Spoke.
    error SpokeNotRegistered(address spoke);
    /// @notice A Spoke kind of `None`, or a Spoke re-registered on another Hub or price Spoke.
    error InvalidSpoke(address spoke);
    /// @notice A width with a zero side or wider than the tick range.
    error InvalidWidth(uint24 below, uint24 above);
    /// @notice An LTV of zero or at least 100%.
    error InvalidLtv(uint256 ltvBps);
    /// @notice A tick spacing of zero or below.
    error InvalidTickSpacing(int24 tickSpacing);
    /// @notice Aave's price at execution is outside the Custom range band.
    error PriceOutsideBand(int24 tick, int24 bandLower, int24 bandUpper);
    /// @notice The Custom range band is fewer than `MIN_BAND_SPACINGS` tick spacings wide.
    error BandTooNarrow(int24 bandLower, int24 bandUpper);
    /// @notice The Custom range band reaches the pool's usable tick range.
    error BandNotNarrowerThanFullRange(int24 bandLower, int24 bandUpper);
    /// @notice The price Spoke's reserve is not the pool's token in pool order with its decimals, the Spoke's oracle is
    /// not its 8-decimal one, or Aave's price of it is above `LPPriceMath.MAX_PRICE`.
    error InvalidPriceReserve(uint256 reserveId);
    /// @notice Even 10^18 units of the band are worth less than $1 at the listing price.
    error UnitValueTooLow(uint256 marketId);
    /// @notice The market is not listed.
    error MarketNotListed(uint256 marketId);
    /// @notice The market is already active.
    error MarketAlreadyActive(uint256 marketId);
    /// @notice The activation check failed on `reason`.
    error ActivationCheckFailed(uint256 marketId, bytes32 reason);
    /// @notice The debt reserve is not registered.
    error DebtReserveNotListed(address spoke, uint256 reserveId);
    /// @notice The debt reserve is already registered, or the Spoke already has a reserve of the same Hub asset.
    error DebtReserveExists(address spoke, uint256 reserveId);
    /// @notice The First-Loss Reserve does not belong to the reserve's Hub and asset, or another one already does.
    error InvalidFirstLossReserve(address firstLossReserve);
    /// @notice The First-Loss Reserve holds less than the coverage ratio of the summed draw caps.
    error CoverageBelowRatio(address hub, address asset, uint256 required, uint256 funded);
    /// @notice No keeper is registered, so no borrowing.
    error NoActiveKeeper();
    /// @notice `addKeeper` of zero or a keeper, or `removeKeeper` of a non-keeper.
    error InvalidKeeper(address keeper);
    /// @notice The registry already holds `MAX_KEEPERS` keepers.
    error TooManyKeepers();
    /// @notice A fee share above `MAX_FEE_SHARE_BPS`, or a zero recipient.
    error InvalidFee(uint256 shareBps, address recipient);
    /// @notice A coverage ratio above 100%.
    error InvalidCoverageRatio(uint256 ratioBps);

    /// @notice A CDP Spoke was registered or its kind changed.
    event SpokeRegistered(address indexed spoke, address indexed hub, SpokeKind kind, address priceSpoke);
    /// @notice A Spoke kind's default Custom range width was set.
    event SpokeWidthSet(SpokeKind indexed kind, uint24 below, uint24 above);
    /// @notice A pool was listed as two markets.
    event PoolListed(
        bytes32 indexed pool,
        address indexed spoke,
        uint256 fullRange,
        uint256 customRange,
        int24 listingTick,
        uint16 ltvBps
    );
    /// @notice A band market was listed; its vault token must have `unitDecimals` decimals.
    event MarketListed(
        uint256 indexed marketId,
        bytes32 indexed pool,
        MarketKind kind,
        int24 bandLower,
        int24 bandUpper,
        uint8 unitDecimals
    );
    /// @notice A market's vault token, oracle and Aave reserve passed the activation check.
    event MarketActivated(uint256 indexed marketId, address vaultToken, uint256 reserveId, address lpOracle);
    /// @notice A debt reserve was registered.
    event DebtReserveSet(
        address indexed spoke, uint256 indexed reserveId, address hub, address asset, address firstLossReserve
    );
    /// @notice A debt reserve was removed.
    event DebtReserveRemoved(address indexed spoke, uint256 indexed reserveId);
    /// @notice The coverage ratio was set.
    event CoverageRatioSet(uint256 ratioBps);
    /// @notice The Avana fee share and recipient were set.
    event FeeSet(uint256 shareBps, address indexed recipient);
    /// @notice A keeper was added.
    event KeeperAdded(address indexed keeper);
    /// @notice A keeper was removed.
    event KeeperRemoved(address indexed keeper);

    /// @notice Registers a CDP Spoke with its Hub, kind and price Spoke, or changes its kind.
    /// @dev Restricted. Reverts `InvalidSpoke` for kind `None`, or a different Hub or price Spoke than the ones
    /// recorded.
    function registerSpoke(
        address spoke,
        address hub,
        SpokeKind kind,
        address priceSpoke
    ) external;

    /// @notice Sets a Spoke kind's default Custom range width; pools listed later use it.
    /// @dev Restricted. Reverts `InvalidWidth` for a zero side or a side above the tick range.
    function setSpokeWidth(
        SpokeKind kind,
        Width calldata width
    ) external;

    /// @notice Lists a pool as two band markets, Full range and Custom range, at one LTV.
    /// @dev Restricted. Full range: the pool's usable tick range. Custom range: the width (the pool's, else the Spoke
    /// kind's) around `listingTick`, rounded outward to the tick spacing. Reverts `InvalidPriceReserve` unless each
    /// reserve ID is the pool's token on the Spoke's price Spoke, and reverts unless the Custom range band contains
    /// Aave's price now, is at least `MIN_BAND_SPACINGS` spacings wide and lies strictly inside the usable range.
    /// A pool listed again gets a new pair; the old markets keep working for their positions.
    /// @return fullRange The Full range market ID.
    /// @return customRange The Custom range market ID.
    function listPool(
        ListPoolParams calldata p
    ) external returns (uint256 fullRange, uint256 customRange);

    /// @notice Activates a market once Aave lists its reserve: checks and binds its vault token and LPOracle.
    /// @dev Restricted. Reverts `ActivationCheckFailed` unless the vault token is this market's (ID, Hub,
    /// LiquidationModule, decimals, AccessManager), the oracle prices this market from the price Spoke's listed reserves
    /// with the listed unit, the Spoke reserve holds the vault token on the Spoke's Hub with the oracle as source, the
    /// vault token's draw cap is 0, receive-shares is off, the liquidation fee is 0, the collateral factor is the market's
    /// LTV, the max liquidation bonus is the higher of the two tokens' on the price Spoke, and the CDP Spoke's liquidation
    /// config (target health factor, health factor for the max bonus, bonus factor) is the price Spoke's.
    function activateMarket(
        uint256 marketId,
        address vaultToken,
        address lpOracle
    ) external;

    /// @notice Registers a borrowable debt reserve of a CDP Spoke and its First-Loss Reserve.
    /// @dev Restricted. Reads the Hub, asset and asset ID from the Spoke. One First-Loss Reserve per `(hub, asset)`.
    function setDebtReserve(
        address spoke,
        uint256 reserveId,
        address firstLossReserve
    ) external;

    /// @notice Removes a debt reserve; its Spoke's draw cap leaves the coverage sum.
    /// @dev Restricted.
    function removeDebtReserve(
        address spoke,
        uint256 reserveId
    ) external;

    /// @notice Sets the share of the summed draw caps the First-Loss Reserve must hold, basis points.
    /// @dev Restricted. At most 10,000.
    function setCoverageRatio(
        uint256 ratioBps
    ) external;

    /// @notice Sets Avana's share of the liquidation bonus and its recipient.
    /// @dev Restricted. At most `MAX_FEE_SHARE_BPS`; the recipient is nonzero.
    function setFee(
        uint256 shareBps,
        address recipient
    ) external;

    /// @notice Adds a keeper.
    /// @dev Restricted. At most `MAX_KEEPERS`.
    function addKeeper(
        address keeper
    ) external;

    /// @notice Removes a keeper; with none left, borrowing stops.
    /// @dev Restricted.
    function removeKeeper(
        address keeper
    ) external;

    /// @notice Reverts unless a borrow of `reserveId` on `spoke` may go out now: the reserve is registered, a keeper is
    /// registered, and the First-Loss Reserve covers the summed draw caps at the coverage ratio.
    function checkBorrow(
        address spoke,
        uint256 reserveId
    ) external view;

    /// @notice The market of `pool` a position on `[tickLower, tickUpper]` goes to: Full range for exactly the usable
    /// range, else Custom range if inside its band, else 0.
    function routeOf(
        bytes32 pool,
        int24 tickLower,
        int24 tickUpper
    ) external view returns (uint256 marketId);

    /// @notice Whether a position on `[tickLower, tickUpper]` is fully inside the market's band.
    function isEligible(
        uint256 marketId,
        int24 tickLower,
        int24 tickUpper
    ) external view returns (bool eligible);

    /// @notice The floor credit of `liquidity` on `[tickLower, tickUpper]` in the market, in band units.
    /// @dev Reverts `MarketNotListed`, or `NotInsideBand` (FloorCreditMath) for an ineligible position.
    function creditOf(
        uint256 marketId,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity
    ) external view returns (uint128 credit);

    /// @notice First-Loss coverage of `(hub, asset)`.
    /// @return drawCapSum Summed draw caps of the registered debt reserves' Spokes, whole tokens.
    /// @return required The balance they require, base units, rounded up.
    /// @return funded The First-Loss Reserve's funded balance.
    function coverage(
        address hub,
        address asset
    ) external view returns (uint256 drawCapSum, uint256 required, uint256 funded);

    /// @notice A market; `pool == 0` when not listed.
    function getMarket(
        uint256 marketId
    ) external view returns (Market memory market);

    /// @notice The latest markets of a pool; zeros when never listed.
    function marketsOf(
        bytes32 pool
    ) external view returns (PoolMarkets memory markets);

    /// @notice A Spoke's registration.
    function getSpoke(
        address spoke
    ) external view returns (SpokeConfig memory config);

    /// @notice A Spoke kind's default Custom range width.
    function spokeWidth(
        SpokeKind kind
    ) external view returns (Width memory width);

    /// @notice A debt reserve's registration; `hub == 0` when none.
    function getDebtReserve(
        address spoke,
        uint256 reserveId
    ) external view returns (DebtReserve memory reserve);

    /// @notice The coverage ratio, basis points.
    function coverageRatioBps() external view returns (uint256 ratioBps);

    /// @notice Avana's share of the liquidation bonus, basis points.
    function feeShareBps() external view returns (uint256 shareBps);

    /// @notice The receiver of Avana's fee share.
    function feeRecipient() external view returns (address recipient);

    /// @notice Whether `account` is a keeper.
    function isKeeper(
        address account
    ) external view returns (bool);

    /// @notice The registered keepers.
    function getKeepers() external view returns (address[] memory keepers);

    /// @notice The LPVault the markets are listed in.
    function LP_VAULT() external view returns (address lpVault);

    /// @notice The only receiver of seized vault tokens.
    function LIQUIDATION_MODULE() external view returns (address liquidationModule);

    /// @notice Fewest tick spacings a Custom range band spans.
    function MIN_BAND_SPACINGS() external view returns (int24 spacings);

    /// @notice Most keepers the registry holds.
    function MAX_KEEPERS() external view returns (uint256 maxKeepers);

    /// @notice Highest Avana fee share, basis points.
    function MAX_FEE_SHARE_BPS() external view returns (uint256 maxShareBps);
}
