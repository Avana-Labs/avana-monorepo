// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAaveV4Hub} from "../../interfaces/external/aave/IAaveV4Hub.sol";
import {IAaveV4Oracle} from "../../interfaces/external/aave/IAaveV4Oracle.sol";
import {IAaveV4PriceFeed} from "../../interfaces/external/aave/IAaveV4PriceFeed.sol";
import {IAaveV4Spoke} from "../../interfaces/external/aave/IAaveV4Spoke.sol";
import {SettlementMath} from "../../liquidation/lp-vault-swap/SettlementMath.sol";
import {ILock} from "../../lock/lock/ILock.sol";
import {IDebtOracle} from "../../oracle/debt-oracle/IDebtOracle.sol";
import {DebtPriceView as OracleDebtView} from "../../oracle/debt-oracle/types/DebtPriceView.sol";
import {IAaveAdapterViews} from "../../policy/aave-adapter/IAaveAdapterViews.sol";
import {IMarketRegistry} from "../../policy/market-registry/IMarketRegistry.sol";
import {IMarketRegistryErrors} from "../../policy/market-registry/IMarketRegistryErrors.sol";
import {DebtReserveDef} from "../../policy/market-registry/types/DebtReserveDef.sol";
import {IParameterStore} from "../../policy/parameter-store/IParameterStore.sol";
import {IProxyManager} from "../../proxy/proxy-manager/IProxyManager.sol";
import {Market} from "../../types/Market.sol";
import {PriceState} from "../../types/PriceState.sol";
import {TokenPriceView} from "../../types/TokenPriceView.sol";
import {ILensErrors} from "./ILensErrors.sol";
import {LensConstants} from "./LensConstants.sol";
import {DebtPriceView} from "./types/DebtPriceView.sol";
import {PriceInput} from "./types/PriceInput.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title LensBase
/// @notice Constructor immutables, their getters, the lock check, market resolution and the price reads every Lens
/// piece shares.
/// @dev No storage: the nine core addresses are immutables and every other value is read in the call. No Hub, Spoke,
/// LPVault or pool address is an immutable; each comes from the MarketRegistry's record of the market.
/// @custom:spec REQ-LENS-001, REQ-LENS-005, REQ-LENS-006, REQ-LENS-007, REQ-LENS-021, REQ-LENS-022, REQ-LENS-040
// View calls in loops over listings bounded by governance (Spokes, debt reserves, markets, pool tokens), one
// page of at most LENS_MAX_PAGE records or the caller's own arrays (REQ-LENS-020).
// forge-lint: disable-start(calls-loop)
abstract contract LensBase is ILensErrors {
    /// @dev A Hub `addCap` or `drawCap` at this value has no limit (Aave's `MAX_ALLOWED_SPOKE_CAP`).
    uint256 internal constant UNLIMITED_CAP = type(uint40).max;

    /// @dev Collateralization.
    address internal immutable _COLLATERALIZATION;
    /// @dev ProxyManager.
    address internal immutable _PROXY_MANAGER;
    /// @dev AaveAdapter fixed proxy.
    address internal immutable _ADAPTER;
    /// @dev The chain's Lock.
    address internal immutable _LOCK;
    /// @dev MarketRegistry fixed proxy.
    address internal immutable _MARKET_REGISTRY;
    /// @dev ParameterStore fixed proxy.
    address internal immutable _PARAMETER_STORE;
    /// @dev RiskModule fixed proxy.
    address internal immutable _RISK_MODULE;
    /// @dev LPVaultSwap fixed proxy.
    address internal immutable _LP_VAULT_SWAP;
    /// @dev PayoutEscrow.
    address internal immutable _PAYOUT_ESCROW;

    /// @notice Fixes the chain's core addresses from the verified deployment manifest.
    /// @param core `[collateralization, proxyManager, adapter, lock, marketRegistry, parameterStore, riskModule,
    /// lpVaultSwap, payoutEscrow]`.
    /// @custom:spec REQ-LENS-001, REQ-LENS-002, REQ-LENS-040
    constructor(
        address[9] memory core
    ) {
        (_COLLATERALIZATION, _PROXY_MANAGER, _ADAPTER) = (core[0], core[1], core[2]);
        (_LOCK, _MARKET_REGISTRY, _PARAMETER_STORE) = (core[3], core[4], core[5]);
        (_RISK_MODULE, _LP_VAULT_SWAP, _PAYOUT_ESCROW) = (core[6], core[7], core[8]);
    }

    // ------------------------------------------------------------------------------------------------------- getters

    /// @notice The largest page size the paged views accept (`LensConstants.LENS_MAX_PAGE`).
    /// @custom:spec REQ-LENS-020
    function LENS_MAX_PAGE() external pure returns (uint256 maxPage) {
        maxPage = LensConstants.LENS_MAX_PAGE;
    }

    /// @notice The whole-debt margin of `previewLiquidation` (`LensConstants.LENS_DUST_MARGIN_BPS`).
    /// @custom:spec REQ-LENS-028
    function LENS_DUST_MARGIN_BPS() external pure returns (uint256 marginBps) {
        marginBps = LensConstants.LENS_DUST_MARGIN_BPS;
    }

    /// @notice Collateralization.
    /// @custom:spec REQ-LENS-001
    function COLLATERALIZATION() external view returns (address collateralization) {
        collateralization = _COLLATERALIZATION;
    }

    /// @notice The ProxyManager.
    /// @custom:spec REQ-LENS-001
    function PROXY_MANAGER() external view returns (address proxyManager) {
        proxyManager = _PROXY_MANAGER;
    }

    /// @notice The AaveAdapter fixed proxy.
    /// @custom:spec REQ-LENS-001
    function ADAPTER() external view returns (address adapter) {
        adapter = _ADAPTER;
    }

    /// @notice The Lock.
    /// @custom:spec REQ-LENS-001
    function LOCK() external view returns (address lock) {
        lock = _LOCK;
    }

    /// @notice The MarketRegistry fixed proxy.
    /// @custom:spec REQ-LENS-001
    function MARKET_REGISTRY() external view returns (address marketRegistry) {
        marketRegistry = _MARKET_REGISTRY;
    }

    /// @notice The ParameterStore fixed proxy.
    /// @custom:spec REQ-LENS-001
    function PARAMETER_STORE() external view returns (address parameterStore) {
        parameterStore = _PARAMETER_STORE;
    }

    /// @notice The RiskModule fixed proxy.
    /// @custom:spec REQ-LENS-001
    function RISK_MODULE() external view returns (address riskModule) {
        riskModule = _RISK_MODULE;
    }

    /// @notice The LPVaultSwap fixed proxy.
    /// @custom:spec REQ-LENS-001
    function LP_VAULT_SWAP() external view returns (address lpVaultSwap) {
        lpVaultSwap = _LP_VAULT_SWAP;
    }

    /// @notice The PayoutEscrow.
    /// @custom:spec REQ-LENS-001
    function PAYOUT_ESCROW() external view returns (address payoutEscrow) {
        payoutEscrow = _PAYOUT_ESCROW;
    }

    // ------------------------------------------------------------------------------------------------------ internal

    /// @dev Reverts with `Locked()` while an Avana call holds the Lock.
    /// @custom:spec REQ-LENS-006, REQ-LENS-021
    function _unlocked() internal view {
        if (ILock(_LOCK).isLocked()) revert Locked();
    }

    /// @dev Applies the page rules: `LimitTooHigh` above `LENS_MAX_PAGE`; true (empty page) for 0.
    /// @custom:spec REQ-LENS-023
    function _emptyPage(
        uint256 limit
    ) internal pure returns (bool empty) {
        if (limit > LensConstants.LENS_MAX_PAGE) revert LimitTooHigh(limit);
        empty = limit == 0;
    }

    /// @dev The MarketRegistry's record of `marketId`; `UnknownMarket` for an unlisted ID.
    /// @custom:spec REQ-LENS-022, REQ-LENS-040
    function _market(
        uint256 marketId
    ) internal view returns (Market memory m) {
        m = _registry().getMarket(marketId);
        // forge-lint: disable-next-line(require-revert-in-loop)
        if (m.vaultToken == address(0)) revert IMarketRegistryErrors.UnknownMarket(marketId);
    }

    /// @dev The market of a vault token; `UnknownMarket(0)` for an address that is no market's vault token.
    /// @custom:spec REQ-LENS-022, REQ-LENS-040
    function _marketOfToken(
        address vaultToken
    ) internal view returns (uint256 marketId, Market memory m) {
        marketId = _registry().marketOfVaultToken(vaultToken);
        m = _market(marketId);
    }

    /// @dev The stored proxy of `(wallet, marketId)` when non-zero, else the ProxyManager's CREATE2 prediction.
    /// @custom:spec REQ-LENS-008
    function _proxy(
        address wallet,
        uint256 marketId,
        address spoke
    ) internal view returns (address proxy, bool deployed) {
        proxy = IAaveAdapterViews(_ADAPTER).proxyOf(wallet, marketId);
        deployed = proxy != address(0);
        if (!deployed) proxy = IProxyManager(_PROXY_MANAGER).predictProxy(wallet, spoke, marketId);
    }

    /// @dev The approved debt reserve `debtReserveId` of `spoke`; `UnknownDebtReserve` otherwise.
    /// @custom:spec REQ-LENS-030, REQ-LENS-032
    function _debtReserve(
        address spoke,
        uint256 debtReserveId
    ) internal view returns (DebtReserveDef memory def) {
        if (!_registry().isApprovedDebtReserve(spoke, debtReserveId)) revert UnknownDebtReserve(spoke, debtReserveId);
        def = _registry().getDebtReserve(spoke, debtReserveId);
    }

    /// @dev `Pc` of SPEC-LIQ-004: the smaller of the AaveOracle price of the vault-token reserve and the market's
    /// LPOracle `latestAnswer()` (a non-positive answer counts 0).
    /// @custom:spec SPEC-LIQ-004, REQ-LENS-016
    function _collateralPrice(
        Market memory m
    ) internal view returns (uint256 price) {
        price = IAaveV4Oracle(IAaveV4Spoke(m.spoke).ORACLE()).getReservePrice(m.reserveId);
        int256 lp = IAaveV4PriceFeed(m.lpOracle).latestAnswer();
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 lpPrice = lp > 0 ? uint256(lp) : 0;
        if (lpPrice < price) price = lpPrice;
    }

    /// @dev `Pdebt` of SPEC-LIQ-004: the larger of the AaveOracle price and the DebtOracle's answer (a fixed-price
    /// reserve: the AaveOracle price).
    /// @custom:spec SPEC-LIQ-004, REQ-LENS-016
    function _debtPrice(
        address spoke,
        DebtReserveDef memory def
    ) internal view returns (uint256 price) {
        price = IAaveV4Oracle(IAaveV4Spoke(spoke).ORACLE()).getReservePrice(def.reserveId);
        if (!def.fixedPrice) {
            int256 answer = IDebtOracle(def.priceSource).latestAnswer();
            // forge-lint: disable-next-line(unsafe-typecast)
            if (answer > 0 && uint256(answer) > price) price = uint256(answer);
        }
    }

    /// @dev The debt-reserve price report of REQ-LENS-030, without the block stamp.
    /// @custom:spec REQ-LENS-030, Q-247, Q-248
    function _debtView(
        address spoke,
        DebtReserveDef memory def
    ) internal view returns (DebtPriceView memory v) {
        address oracle = IAaveV4Spoke(spoke).ORACLE();
        v.debtReserveId = def.reserveId;
        v.source = IAaveV4Oracle(oracle).getReserveSource(def.reserveId);
        v.price = IAaveV4Oracle(oracle).getReservePrice(def.reserveId);
        v.fixedPrice = def.fixedPrice;
        if (def.fixedPrice) {
            (v.state, v.acceptedPrice, v.updatedAt) = (PriceState.Live, v.price, block.timestamp);
            (v.borrowFresh, v.liquidationFresh) = (true, true);
            return v;
        }
        IDebtOracle debtOracle = IDebtOracle(def.priceSource);
        OracleDebtView memory r = debtOracle.getPriceState();
        v.state = r.state;
        (v.acceptedPrice, v.updatedAt) = debtOracle.lastAcceptedPrice();
        v.age = block.timestamp > v.updatedAt ? block.timestamp - v.updatedAt : 0;
        // The smallest borrowPriceMaxAge and liquidationPriceMaxAge over the route's non-zero feeds, read from the
        // ParameterStore in this call.
        (uint256 borrowAge, uint256 liquidationAge) = (type(uint256).max, type(uint256).max);
        for (uint256 i = 0; i < 2; ++i) {
            if (r.legFeeds[i] == address(0)) continue;
            borrowAge = Math.min(borrowAge, _store().borrowPriceMaxAge(r.legFeeds[i]));
            liquidationAge = Math.min(liquidationAge, _store().liquidationPriceMaxAge(r.legFeeds[i]));
        }
        // A route that names no feed has no source age to check, so it is never reported fresh.
        bool live = r.state == PriceState.Live && (r.legFeeds[0] != address(0) || r.legFeeds[1] != address(0));
        // The oracle's own gates close borrowing (sequencer not ready, second source unconfirmed) and liquidation
        // (sequencer down, a serving alternate past its borrow age) while the state can still be Live and fresh.
        v.borrowFresh = live && r.borrowAllowed && v.age <= borrowAge;
        v.liquidationFresh = live && !r.liquidationPaused && v.age <= liquidationAge;
        v.stressPriced = v.price > v.acceptedPrice;
    }

    /// @dev `drawCap` headroom of `spoke` on one debt reserve's funding Hub asset, base units.
    /// @custom:spec REQ-LENS-019, REQ-LENS-035
    function _drawHeadroom(
        address spoke,
        DebtReserveDef memory def
    ) internal view returns (uint256 headroom) {
        IAaveV4Hub hub = IAaveV4Hub(def.fundingHub);
        uint256 cap = hub.getSpokeConfig(def.hubAssetId, spoke).drawCap;
        if (cap == UNLIMITED_CAP) return type(uint256).max;
        uint256 owed = hub.getSpokeTotalOwed(def.hubAssetId, spoke);
        uint256 deficit = Math.ceilDiv(hub.getSpokeDeficitRay(def.hubAssetId, spoke), 1e27);
        uint256 limit = cap * 10 ** def.decimals;
        headroom = limit > owed ? _room(limit - owed, deficit) : 0;
    }

    /// @dev SPEC-LIQ-004 value of `units` in the debt asset, rounded down; 0 when either price is 0, so a price state
    /// never makes a view revert (REQ-LENS-007).
    /// @custom:spec SPEC-LIQ-004, REQ-LENS-007, REQ-LENS-026
    function _oracleValue(
        uint256 units,
        uint256 collateralPrice,
        uint8 vaultDecimals,
        uint8 debtDecimals,
        uint256 debtPrice
    ) internal pure returns (uint256 value) {
        if (units == 0 || collateralPrice == 0 || debtPrice == 0) return 0;
        value = SettlementMath.seizedValue(units, collateralPrice, vaultDecimals, debtDecimals, debtPrice);
    }

    /// @dev `amount × price × 10^to / (10^from × quote)` as `SettlementMath` values a leg (`SPEC-LIQ-004`,
    /// `SPEC-LIQ-005`), rounded down or up, with the price checks done by the caller (both prices non-zero), so a loop
    /// over pool tokens never reverts on a price state (REQ-LENS-007).
    /// @custom:spec SPEC-LIQ-004, SPEC-LIQ-005, REQ-LENS-007
    function _tokenValue(
        uint256 amount,
        uint256 price,
        uint8 fromDecimals,
        uint8 toDecimals,
        uint256 quote,
        bool up
    ) internal pure returns (uint256) {
        return Math.mulDiv(
            amount, price * 10 ** toDecimals, 10 ** fromDecimals * quote, up ? Math.Rounding.Ceil : Math.Rounding.Floor
        );
    }

    /// @dev Vault-token `addCap` headroom of the CDP Spoke on the market's Hub, vault-token base units:
    /// `max(0, addCap × 10^d − addedAssetsUp)`, with one unit added to the Spoke's added assets while the asset's added
    /// shares differ from its added assets; unlimited for Aave's maximum cap.
    /// @custom:spec REQ-LENS-019
    function _addHeadroom(
        Market memory m
    ) internal view returns (uint256 headroom) {
        IAaveV4Hub hub = IAaveV4Hub(m.hub);
        uint256 cap = hub.getSpokeConfig(m.hubAssetId, m.spoke).addCap;
        if (cap == UNLIMITED_CAP) return type(uint256).max;
        uint256 added = hub.getSpokeAddedAssets(m.hubAssetId, m.spoke);
        if (hub.getAddedShares(m.hubAssetId) != hub.getAddedAssets(m.hubAssetId)) ++added;
        headroom = _room(cap * 10 ** m.decimals, added);
    }

    /// @dev `cap − used`, floored at 0.
    function _room(
        uint256 cap,
        uint256 used
    ) internal pure returns (uint256) {
        return cap > used ? cap - used : 0;
    }

    /// @dev One `PriceInput` per Chainlink leg of the route each token is served from, in pool order, with both age
    /// limits read from the ParameterStore in this call.
    /// @custom:spec REQ-LENS-015
    function _inputs(
        TokenPriceView[] memory tokens
    ) internal view returns (PriceInput[] memory inputs) {
        uint256 n = 0;
        for (uint256 i = 0; i < tokens.length; ++i) {
            for (uint256 j = 0; j < 2; ++j) {
                if (tokens[i].legFeeds[j] != address(0)) ++n;
            }
        }
        inputs = new PriceInput[](n);
        n = 0;
        for (uint256 i = 0; i < tokens.length; ++i) {
            for (uint256 j = 0; j < 2; ++j) {
                address feed = tokens[i].legFeeds[j];
                if (feed == address(0)) continue;
                inputs[n++] = _input(feed, tokens[i].legUpdatedAt[j]);
            }
        }
    }

    /// @dev One input with its age and both freshness flags.
    function _input(
        address feed,
        uint256 updatedAt
    ) internal view returns (PriceInput memory p) {
        (p.feed, p.updatedAt) = (feed, updatedAt);
        p.age = block.timestamp > updatedAt ? block.timestamp - updatedAt : 0;
        p.borrowPriceMaxAge = _store().borrowPriceMaxAge(feed);
        p.liquidationPriceMaxAge = _store().liquidationPriceMaxAge(feed);
        p.borrowFresh = p.age <= p.borrowPriceMaxAge;
        p.liquidationFresh = p.age <= p.liquidationPriceMaxAge;
    }

    /// @dev The MarketRegistry.
    function _registry() internal view returns (IMarketRegistry) {
        return IMarketRegistry(_MARKET_REGISTRY);
    }

    /// @dev The ParameterStore.
    function _store() internal view returns (IParameterStore) {
        return IParameterStore(_PARAMETER_STORE);
    }
}
// forge-lint: disable-end(calls-loop)
