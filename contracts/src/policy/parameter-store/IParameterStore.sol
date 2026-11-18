// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IParameterStoreBase} from "./IParameterStoreBase.sol";
import {IParameterStoreListing} from "./IParameterStoreListing.sol";
import {IParameterStoreLoosen} from "./IParameterStoreLoosen.sol";
import {IParameterStoreTighten} from "./IParameterStoreTighten.sol";
import {
    DebtReserveParams,
    FeedDef,
    GlobalParams,
    MarketDynamicCap,
    MarketParams
} from "./types/ParameterStoreTypes.sol";
import {IAccessManaged} from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";

/// @title IParameterStore
/// @notice Every Avana risk parameter of one chain, with its hard bounds, liveness bounds and change direction.
/// @dev UUPS proxy; only the AccessManager's governance role can upgrade it. Holds no funds.
interface IParameterStore is
    IAccessManaged,
    IParameterStoreBase,
    IParameterStoreTighten,
    IParameterStoreLoosen,
    IParameterStoreListing
{
    /// @notice Initializes the proxy storage.
    /// @dev Sets the AccessManager that authorizes every governed call.
    function initialize(
        address authority,
        GlobalParams calldata params
    ) external;

    /// @notice Sets a feed's `borrowPriceMaxAge` in either direction.
    /// @dev Reverts `OutOfBounds` unless `0 < value <= feedMaxAge`.
    /// @param value New age limit, seconds.
    function setBorrowPriceMaxAge(
        address feed,
        uint32 value
    ) external;

    /// @notice Sets a market's `poolRiskFactor` in either direction.
    /// @param value New factor, bps.
    function setPoolRiskFactor(
        uint256 marketId,
        uint16 value
    ) external;

    /// @notice Sets `avanaFeeShareBps` in either direction.
    /// @dev Takes the tighten role, so the risk steward may call it at once; a rise reverts `OutOfBounds` unless the fee bound holds.
    function setAvanaFeeShareBps(
        uint16 value
    ) external;

    /// @notice Sets `feeRecipient`.
    /// @dev Reverts `InvalidFeeRecipient` for the zero address, an Avana contract, a Hub, a Spoke or a PositionProxy.
    function setFeeRecipient(
        address recipient
    ) external;

    /// @notice Sets `maxFlashFeeBps`.
    /// @dev A raise reverts `LivenessBound` unless liquidation liveness holds for every live market.
    function setMaxFlashFeeBps(
        uint16 value
    ) external;

    /// @notice Lowers `maxFlashFeeBps` (tighten role: the governance Safe after 12 hours, the risk steward at once).
    /// @dev A lower ceiling can move liquidations to the caller-funded path, never stop them.
    function tightenMaxFlashFeeBps(
        uint16 value
    ) external;

    /// @notice Sets a feed's `liquidationPriceMaxAge`.
    /// @dev Reverts `LivenessBound` below the feed's `feedHeartbeat`.
    /// @param value New age limit, seconds.
    function setLiquidationPriceMaxAge(
        address feed,
        uint32 value
    ) external;

    /// @notice Sets a feed's `feedMaxAge`, the maximum age of a valid answer in LPOracle state evaluation.
    /// @dev Reverts `OutOfBounds` unless `value == feedHeartbeat + heartbeatMargin`.
    /// @param value New maximum age, seconds.
    function setFeedMaxAge(
        address feed,
        uint32 value
    ) external;

    /// @notice Sets a market's `slippageAllowanceMinBps`.
    /// @dev A raise on a live market reverts `LivenessBound` unless liquidation liveness still holds.
    function setSlippageAllowanceMinBps(
        uint256 marketId,
        uint16 value
    ) external;

    /// @notice Sets a token's collateral-factor input (`tokenCollateralFactorBps`).
    function setTokenCollateralFactorBps(
        address token,
        uint16 value
    ) external;

    /// @notice Changes a market's stress floor.
    /// @dev Raising reverts `SupplyNotZero` unless the market's vault-token supply is 0.
    /// @param value New floor, 8-decimal USD per whole vault token.
    function setStressFloorUsd(
        uint256 marketId,
        uint256 value
    ) external;

    /// @notice Hub deficit of a debt asset above which the debt breaker's `DEFICIT` condition holds.
    /// @return value Asset base units; 0 when none is written.
    function deficitMax(
        address hub,
        address asset
    ) external view returns (uint256 value);

    /// @notice Lowers a debt asset's `deficitMax(hub, asset)` (more sensitive).
    /// @dev Reverts `UnknownHub` unless the MarketRegistry records `hub`.
    /// @param value New maximum, asset base units.
    function tightenDeficitMax(
        address hub,
        address asset,
        uint256 value
    ) external;

    /// @notice Raises a debt asset's `deficitMax(hub, asset)`.
    /// @dev Reverts `OutOfBounds` above the `firstLossReserveMinimum()` of a matching debt reserve.
    /// @param value New maximum, asset base units.
    function loosenDeficitMax(
        address hub,
        address asset,
        uint256 value
    ) external;

    /// @notice Seconds per block on this chain, an implementation immutable.
    function CHAIN_BLOCK_TIME() external view returns (uint32 value);

    /// @notice Heartbeat margin of a feed, written by `setFeed` with the rest of its `FeedDef`.
    /// @return margin Seconds.
    function heartbeatMargin(
        address feed
    ) external view returns (uint32 margin);

    /// @notice First-loss coverage ratio agreed in the funding ARFC.
    /// @return value bps within [0, 10,000]; 0 until `setCoverageRatioBps` writes it.
    function coverageRatioBps() external view returns (uint16 value);

    /// @notice Sets `coverageRatioBps`, in either direction.
    /// @dev Reverts `OutOfBounds` above 10,000.
    function setCoverageRatioBps(
        uint16 value
    ) external;

    /// @notice Whether the smallest liquidation bonus covers the slippage floor and the flash premium.
    /// @dev False when the market, its reserve or the debt reserve is unknown.
    function liquidationLivenessHolds(
        address spoke,
        uint256 marketId,
        uint256 debtReserveId
    ) external view returns (bool holds);

    /// @notice Largest per-leg slippage raise a caller shortfall top-up can buy.
    function maxShortfallBps() external view returns (uint16 value);

    /// @notice Lowers `maxShortfallBps`.
    function tightenMaxShortfallBps(
        uint16 value
    ) external;

    /// @notice Raises `maxShortfallBps`.
    function loosenMaxShortfallBps(
        uint16 value
    ) external;

    /// @notice Stress rise the DebtOracle applies to a debt asset's accepted price once it has expired.
    /// @return value bps; 0 when none is written.
    function debtStressRiseBps(
        address asset
    ) external view returns (uint16 value);

    /// @notice Raises a debt asset's `debtStressRiseBps`; the listing batch writes the first value with it.
    function tightenDebtStressRiseBps(
        address asset,
        uint16 value
    ) external;

    /// @notice Lowers a debt asset's `debtStressRiseBps`.
    function loosenDebtStressRiseBps(
        address asset,
        uint16 value
    ) external;

    /// @notice Regular pledge budget of a market.
    /// @return value 8-decimal USD.
    function marketUsdCap(
        uint256 marketId
    ) external view returns (uint256 value);

    /// @notice Rescue top-up budget of a market.
    /// @return value 8-decimal USD.
    function topUpSliceUsd(
        uint256 marketId
    ) external view returns (uint256 value);

    /// @notice Stress floor of a market.
    /// @return value 8-decimal USD per whole vault token.
    function stressFloorUsd(
        uint256 marketId
    ) external view returns (uint256 value);

    /// @notice Aggregate exposure cap of an underlying token across every market of a Hub on the chain.
    /// @return value 8-decimal USD.
    function tokenUsdCap(
        address hub,
        address token
    ) external view returns (uint256 value);

    /// @notice Minimum value of one pledge into a market; the RiskModule reverts `BelowMinPledge` below it.
    /// @return value 8-decimal USD.
    function minPledgeUsd(
        uint256 marketId
    ) external view returns (uint256 value);

    /// @notice Settlement parameters of one debt asset.
    /// @return p Rounding allowance, base units of `asset` (zeros for an unknown asset).
    function debtAssetParams(
        address asset
    ) external view returns (DebtReserveParams memory p);

    /// @notice Smallest input a swap-route slot must absorb within the slippage allowance to count as usable.
    /// @param token Pool token sold.
    /// @param debtAsset Debt asset bought.
    /// @param kind 0 primary, 1 backup.
    /// @return value Base units of `debtAsset` (0 for an unknown slot).
    function routeDepthThreshold(
        uint256 marketId,
        address token,
        address debtAsset,
        uint8 kind
    ) external view returns (uint256 value);

    /// @notice MarketRegistry fixed proxy address (implementation immutable).
    function MARKET_REGISTRY() external view returns (address registry);

    /// @notice A market's dynamic borrow cap terms changed.
    event MarketDynamicCapSet(
        uint256 indexed marketId, MarketDynamicCap oldTerms, MarketDynamicCap newTerms, bool tightened
    );

    /// @notice A market's dynamic borrow cap terms: interval, alpha and the buffer bounds.
    function marketDynamicCap(
        uint256 marketId
    ) external view returns (MarketDynamicCap memory terms);

    /// @notice Tightens a market's dynamic borrow cap terms: no field looser, one strictly tighter.
    function tightenMarketDynamicCap(
        uint256 marketId,
        MarketDynamicCap calldata terms
    ) external;

    /// @notice Loosens a market's dynamic borrow cap terms, or writes the first value: no field tighter, one looser.
    function loosenMarketDynamicCap(
        uint256 marketId,
        MarketDynamicCap calldata terms
    ) external;

    /// @notice Returns a market's parameters.
    function getMarketParams(
        uint256 marketId
    ) external view returns (MarketParams memory params);

    /// @notice Collateral-factor input of a token.
    function tokenCollateralFactorBps(
        address token
    ) external view returns (uint16 bps);

    /// @notice Returns a feed definition.
    function getFeed(
        address feed
    ) external view returns (FeedDef memory def);

    /// @notice Liveness floor of a market's `slippageAllowanceBps`.
    function slippageAllowanceMinBps(
        uint256 marketId
    ) external view returns (uint16 bps);

    /// @notice Borrow age limit of a Chainlink feed, never above its `feedMaxAge`.
    /// @return age Seconds.
    function borrowPriceMaxAge(
        address feed
    ) external view returns (uint32 age);

    /// @notice Liquidation age limit of a Chainlink feed: `feedHeartbeat + heartbeatMargin`.
    /// @return age Seconds.
    function liquidationPriceMaxAge(
        address feed
    ) external view returns (uint32 age);

    /// @notice Most flash premium the chain's IFlashSource may charge, as bps of the amount lent.
    function maxFlashFeeBps() external view returns (uint16 value);

    /// @notice Avana's share of realized liquidation surplus.
    function avanaFeeShareBps() external view returns (uint16 value);

    /// @notice Recipient of Avana's share.
    function feeRecipient() external view returns (address recipient);

    /// @notice Allowance subtracted from the recovery floor of a liquidation repaid in `asset`.
    /// @return value Base units of `asset`.
    function floorRoundingAllowance(
        address asset
    ) external view returns (uint256 value);

    /// @notice Upper bound of every feed's `heartbeatMargin` (implementation constant).
    /// @return value Seconds.
    function MAX_HEARTBEAT_MARGIN() external pure returns (uint32 value);

    /// @notice Timestamp of the last loosening of a step-limited parameter.
    /// @param paramKey `keccak256(abi.encode(name, scope))`, with `name` and `scope` as in `ParameterLoosened`.
    /// @return at Seconds (0 if never loosened).
    function lastLoosenedAt(
        bytes32 paramKey
    ) external view returns (uint64 at);

    /// @notice Largest ratio of a USD cap after one loosening to the cap before it (implementation constant).
    function LOOSEN_CAP_STEP_BPS() external pure returns (uint16 value);

    /// @notice Largest increase of `slippageAllowanceBps` in one loosening (implementation constant).
    function LOOSEN_SLIPPAGE_STEP_BPS() external pure returns (uint16 value);
}
