// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ClTickMath} from "../../amm/concentrated-liquidity/ClTickMath.sol";
import {IAvanaFirstLossReserve} from "../../coverage/first-loss-reserve/IAvanaFirstLossReserve.sol";
import {ILPVault} from "../../custody/lp-vault/ILPVault.sol";
import {FloorCreditMath} from "../../custody/lp-vault/libraries/FloorCreditMath.sol";
import {IAaveV4Hub} from "../../interfaces/external/aave/IAaveV4Hub.sol";
import {IAaveV4Spoke} from "../../interfaces/external/aave/IAaveV4Spoke.sol";
import {LPPriceMath} from "../../oracle/LPPriceMath.sol";
import {IVaultToken} from "../../vault-token/IVaultToken.sol";
import {IRiskModule} from "./IRiskModule.sol";
import {RiskModuleStorage} from "./RiskModuleStorage.sol";
import {AaveConfigLogic} from "./libraries/AaveConfigLogic.sol";
import {BandMath} from "./libraries/BandMath.sol";
import {AccessManaged} from "@openzeppelin/contracts/access/manager/AccessManaged.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

/// @title RiskModule
/// @notice Avana's rules on one chain: pool listings as two band markets, the Aave check at activation, eligibility
/// and floor credit, First-Loss coverage of draw caps, the Avana fee and the keeper registry.
/// @dev Not upgradeable; the AccessManager restricts every setter. It holds the LPVault role for `listMarket`. The
/// vault tokens are deployed outside (their market IDs are known before listing) and checked at activation: embedding
/// the VaultToken creation code would take this contract past EIP-170.
contract RiskModule is AccessManaged, RiskModuleStorage, IRiskModule {
    uint256 internal constant _BPS = 10_000;
    /// @dev Widest width side: the whole tick range.
    uint24 internal constant _MAX_WIDTH = uint24(uint256(int256(2 * ClTickMath.MAX_TICK)));

    /// @inheritdoc IRiskModule
    int24 public constant override MIN_BAND_SPACINGS = BandMath.MIN_BAND_SPACINGS;
    /// @inheritdoc IRiskModule
    uint256 public constant override MAX_KEEPERS = 16;
    /// @inheritdoc IRiskModule
    uint256 public constant override MAX_FEE_SHARE_BPS = 5000;

    /// @inheritdoc IRiskModule
    address public immutable override LP_VAULT;
    /// @inheritdoc IRiskModule
    address public immutable override LIQUIDATION_MODULE;

    /// @dev The listing price: both tokens' 8-decimal USD prices and decimals, and their fair square-root price.
    struct ListingPrice {
        uint256 p0;
        uint256 p1;
        uint8 d0;
        uint8 d1;
        uint160 sqrtPriceX96;
    }

    /// @dev Sets the default widths: Stable ±1%, Correlated ±5%, Volatile 0.345x to 2.898x of the listing price.
    /// Reverts `InvalidAddress` for a zero argument.
    constructor(
        address authority,
        address lpVault,
        address liquidationModule
    ) AccessManaged(authority) {
        if (authority == address(0) || lpVault == address(0) || liquidationModule == address(0)) {
            revert InvalidAddress(address(0));
        }
        LP_VAULT = lpVault;
        LIQUIDATION_MODULE = liquidationModule;
        _setWidth(SpokeKind.Stable, Width(101, 100));
        _setWidth(SpokeKind.Correlated, Width(513, 488));
        _setWidth(SpokeKind.Volatile, Width(10_643, 10_641));
    }

    /// @inheritdoc IRiskModule
    function registerSpoke(
        address spoke,
        address hub,
        SpokeKind kind
    ) external override restricted {
        if (spoke == address(0) || hub == address(0)) revert InvalidAddress(address(0));
        address recorded = _spokes[spoke].hub;
        if (kind == SpokeKind.None || (recorded != address(0) && recorded != hub)) revert InvalidSpoke(spoke);
        _spokes[spoke] = SpokeConfig(hub, kind);
        emit SpokeRegistered(spoke, hub, kind);
    }

    /// @inheritdoc IRiskModule
    function setSpokeWidth(
        SpokeKind kind,
        Width calldata width
    ) external override restricted {
        if (kind == SpokeKind.None) revert InvalidSpoke(address(0));
        _setWidth(kind, width);
    }

    /// @inheritdoc IRiskModule
    function listPool(
        ListPoolParams calldata p
    ) external override restricted returns (uint256 fullRange, uint256 customRange) {
        SpokeConfig memory sc = _spokes[p.spoke];
        if (sc.kind == SpokeKind.None) revert SpokeNotRegistered(p.spoke);
        if (p.ltvBps == 0 || p.ltvBps >= _BPS) revert InvalidLtv(p.ltvBps);
        int24[4] memory b = _bands(p, sc.kind);

        fullRange = _nextMarketId;
        customRange = fullRange + 1;
        _nextMarketId = fullRange + 2;
        ILPVault(LP_VAULT).listMarket(fullRange, p.pool, b[0], b[1]);
        ILPVault(LP_VAULT).listMarket(customRange, p.pool, b[2], b[3]);

        ListingPrice memory px = _listingPrice(p, fullRange);
        int24 tick = ClTickMath.getTickAtSqrtPrice(px.sqrtPriceX96);
        if (tick < b[2] || tick >= b[3]) revert PriceOutsideBand(tick, b[2], b[3]);

        _listMarket(fullRange, MarketKind.FullRange, b[0], b[1], p, px);
        _listMarket(customRange, MarketKind.CustomRange, b[2], b[3], p, px);
        _poolMarkets[p.pool] = PoolMarkets(fullRange, customRange);
        emit PoolListed(p.pool, p.spoke, fullRange, customRange, p.listingTick, p.ltvBps);
    }

    /// @inheritdoc IRiskModule
    function activateMarket(
        uint256 marketId,
        address vaultToken,
        address lpOracle
    ) external override restricted {
        Market storage m = _listed(marketId);
        if (m.active) revert MarketAlreadyActive(marketId);
        address hub = _spokes[m.spoke].hub;
        IVaultToken t = IVaultToken(vaultToken);
        if (
            vaultToken.code.length == 0 || t.marketId() != marketId || t.hub() != hub
                || t.liquidationModule() != LIQUIDATION_MODULE || t.decimals() != m.unitDecimals
                || AccessManaged(vaultToken).authority() != authority()
        ) revert ActivationCheckFailed(marketId, "vaultToken");
        m.vaultToken = vaultToken;
        uint256 reserveId = AaveConfigLogic.checkActivation(marketId, m, hub, lpOracle, LP_VAULT);
        m.lpOracle = lpOracle;
        m.reserveId = reserveId;
        m.active = true;
        emit MarketActivated(marketId, vaultToken, reserveId, lpOracle);
    }

    /// @inheritdoc IRiskModule
    function setDebtReserve(
        address spoke,
        uint256 reserveId,
        address firstLossReserve
    ) external override restricted {
        if (_spokes[spoke].kind == SpokeKind.None) revert SpokeNotRegistered(spoke);
        if (_debtReserves[spoke][reserveId].hub != address(0)) revert DebtReserveExists(spoke, reserveId);
        IAaveV4Spoke.Reserve memory r = IAaveV4Spoke(spoke).getReserve(reserveId);
        if (r.hub == address(0) || r.underlying == address(0)) revert DebtReserveNotListed(spoke, reserveId);
        address recorded = _firstLossReserveOf[r.hub][r.underlying];
        if (
            firstLossReserve == address(0) || (recorded != address(0) && recorded != firstLossReserve)
                || IAvanaFirstLossReserve(firstLossReserve).ASSET() != r.underlying
                || IAvanaFirstLossReserve(firstLossReserve).HUB() != r.hub
        ) revert InvalidFirstLossReserve(firstLossReserve);
        address[] storage spokes = _coverageSpokes[r.hub][r.underlying];
        if (_indexOf(spokes, spoke) != type(uint256).max) revert DebtReserveExists(spoke, reserveId);
        spokes.push(spoke);
        _firstLossReserveOf[r.hub][r.underlying] = firstLossReserve;
        _debtReserves[spoke][reserveId] = DebtReserve(r.hub, r.underlying, r.assetId, firstLossReserve);
        emit DebtReserveSet(spoke, reserveId, r.hub, r.underlying, firstLossReserve);
    }

    /// @inheritdoc IRiskModule
    function removeDebtReserve(
        address spoke,
        uint256 reserveId
    ) external override restricted {
        DebtReserve memory d = _debtReserves[spoke][reserveId];
        if (d.hub == address(0)) revert DebtReserveNotListed(spoke, reserveId);
        address[] storage spokes = _coverageSpokes[d.hub][d.asset];
        uint256 i = _indexOf(spokes, spoke);
        spokes[i] = spokes[spokes.length - 1];
        spokes.pop();
        delete _debtReserves[spoke][reserveId];
        emit DebtReserveRemoved(spoke, reserveId);
    }

    /// @inheritdoc IRiskModule
    function setCoverageRatio(
        uint256 ratioBps
    ) external override restricted {
        if (ratioBps > _BPS) revert InvalidCoverageRatio(ratioBps);
        // At most 10,000.
        // forge-lint: disable-next-line(unsafe-typecast)
        _coverageRatioBps = uint16(ratioBps);
        emit CoverageRatioSet(ratioBps);
    }

    /// @inheritdoc IRiskModule
    function setFee(
        uint256 shareBps,
        address recipient
    ) external override restricted {
        if (shareBps > MAX_FEE_SHARE_BPS || recipient == address(0)) revert InvalidFee(shareBps, recipient);
        // At most 5,000.
        // forge-lint: disable-next-line(unsafe-typecast)
        _feeShareBps = uint16(shareBps);
        _feeRecipient = recipient;
        emit FeeSet(shareBps, recipient);
    }

    /// @inheritdoc IRiskModule
    function addKeeper(
        address keeper
    ) external override restricted {
        if (keeper == address(0) || _isKeeper[keeper]) revert InvalidKeeper(keeper);
        if (_keepers.length >= MAX_KEEPERS) revert TooManyKeepers();
        _isKeeper[keeper] = true;
        _keepers.push(keeper);
        emit KeeperAdded(keeper);
    }

    /// @inheritdoc IRiskModule
    function removeKeeper(
        address keeper
    ) external override restricted {
        if (!_isKeeper[keeper]) revert InvalidKeeper(keeper);
        uint256 i = _indexOf(_keepers, keeper);
        _keepers[i] = _keepers[_keepers.length - 1];
        _keepers.pop();
        delete _isKeeper[keeper];
        emit KeeperRemoved(keeper);
    }

    /// @inheritdoc IRiskModule
    function checkBorrow(
        address spoke,
        uint256 reserveId
    ) external view override {
        DebtReserve memory d = _debtReserves[spoke][reserveId];
        if (d.hub == address(0)) revert DebtReserveNotListed(spoke, reserveId);
        if (_keepers.length == 0) revert NoActiveKeeper();
        (, uint256 required, uint256 funded) = _coverage(d.hub, d.asset);
        if (required > funded) revert CoverageBelowRatio(d.hub, d.asset, required, funded);
    }

    /// @inheritdoc IRiskModule
    function routeOf(
        bytes32 pool,
        int24 tickLower,
        int24 tickUpper
    ) external view override returns (uint256 marketId) {
        PoolMarkets memory pm = _poolMarkets[pool];
        if (pm.fullRange == 0) return 0;
        Market storage f = _markets[pm.fullRange];
        if (tickLower == f.bandLower && tickUpper == f.bandUpper) return pm.fullRange;
        if (_inside(_markets[pm.customRange], tickLower, tickUpper)) return pm.customRange;
    }

    /// @inheritdoc IRiskModule
    function isEligible(
        uint256 marketId,
        int24 tickLower,
        int24 tickUpper
    ) external view override returns (bool) {
        return _inside(_listed(marketId), tickLower, tickUpper);
    }

    /// @inheritdoc IRiskModule
    function creditOf(
        uint256 marketId,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity
    ) external view override returns (uint128) {
        Market storage m = _listed(marketId);
        return FloorCreditMath.credit(tickLower, tickUpper, m.bandLower, m.bandUpper, liquidity);
    }

    /// @inheritdoc IRiskModule
    function coverage(
        address hub,
        address asset
    ) external view override returns (uint256 drawCapSum, uint256 required, uint256 funded) {
        return _coverage(hub, asset);
    }

    /// @inheritdoc IRiskModule
    function getMarket(
        uint256 marketId
    ) external view override returns (Market memory) {
        return _markets[marketId];
    }

    /// @inheritdoc IRiskModule
    function marketsOf(
        bytes32 pool
    ) external view override returns (PoolMarkets memory) {
        return _poolMarkets[pool];
    }

    /// @inheritdoc IRiskModule
    function getSpoke(
        address spoke
    ) external view override returns (SpokeConfig memory) {
        return _spokes[spoke];
    }

    /// @inheritdoc IRiskModule
    function spokeWidth(
        SpokeKind kind
    ) external view override returns (Width memory) {
        return _widths[kind];
    }

    /// @inheritdoc IRiskModule
    function getDebtReserve(
        address spoke,
        uint256 reserveId
    ) external view override returns (DebtReserve memory) {
        return _debtReserves[spoke][reserveId];
    }

    /// @inheritdoc IRiskModule
    function coverageRatioBps() external view override returns (uint256) {
        return _coverageRatioBps;
    }

    /// @inheritdoc IRiskModule
    function feeShareBps() external view override returns (uint256) {
        return _feeShareBps;
    }

    /// @inheritdoc IRiskModule
    function feeRecipient() external view override returns (address) {
        return _feeRecipient;
    }

    /// @inheritdoc IRiskModule
    function isKeeper(
        address account
    ) external view override returns (bool) {
        return _isKeeper[account];
    }

    /// @inheritdoc IRiskModule
    function getKeepers() external view override returns (address[] memory) {
        return _keepers;
    }

    /// @dev Records one market with the decimals at which a whole vault token was worth at least $1 at listing.
    function _listMarket(
        uint256 id,
        MarketKind kind,
        int24 lower,
        int24 upper,
        ListPoolParams calldata p,
        ListingPrice memory px
    ) internal {
        uint8 d = BandMath.unitDecimals(px.sqrtPriceX96, lower, upper, px.p0, px.p1, px.d0, px.d1);
        if (d == 0) revert UnitValueTooLow(id);
        Market storage m = _markets[id];
        (m.pool, m.spoke, m.bandLower, m.bandUpper) = (p.pool, p.spoke, lower, upper);
        (m.ltvBps, m.unitDecimals, m.kind) = (p.ltvBps, d, kind);
        m.feedsHash = keccak256(abi.encode(p.token0.feeds, p.token1.feeds));
        emit MarketListed(id, p.pool, kind, lower, upper, d);
    }

    /// @dev The two bands: Full range `[b0, b1]` and Custom range `[b2, b3]`, with the pool's width or the kind's.
    function _bands(
        ListPoolParams calldata p,
        SpokeKind kind
    ) internal view returns (int24[4] memory b) {
        if (p.tickSpacing <= 0) revert InvalidTickSpacing(p.tickSpacing);
        Width memory w = p.width;
        if (w.below == 0 && w.above == 0) w = _widths[kind];
        _checkWidth(w);
        (b[0], b[1]) = BandMath.fullRange(p.tickSpacing);
        (b[2], b[3]) = BandMath.customRange(p.listingTick, w, p.tickSpacing);
    }

    /// @dev The Chainlink listing price of the pool's tokens, read from the LPVault's market.
    function _listingPrice(
        ListPoolParams calldata p,
        uint256 marketId
    ) internal view returns (ListingPrice memory px) {
        ILPVault.Market memory vm = ILPVault(LP_VAULT).getMarket(marketId);
        px.p0 = AaveConfigLogic.tokenPrice(p.token0);
        px.p1 = AaveConfigLogic.tokenPrice(p.token1);
        px.d0 = IERC20Metadata(vm.token0).decimals();
        px.d1 = IERC20Metadata(vm.token1).decimals();
        if (px.d0 > 18 || px.d1 > 18) revert InvalidAddress(px.d0 > 18 ? vm.token0 : vm.token1);
        px.sqrtPriceX96 = LPPriceMath.sqrtPriceX96(px.p0, px.p1, px.d0, px.d1);
    }

    function _coverage(
        address hub,
        address asset
    ) internal view returns (uint256 drawCapSum, uint256 required, uint256 funded) {
        address[] storage spokes = _coverageSpokes[hub][asset];
        if (spokes.length == 0) return (0, 0, 0);
        uint256 assetId = IAaveV4Hub(hub).getAssetId(asset);
        (drawCapSum, required) = AaveConfigLogic.coverage(hub, assetId, asset, spokes, _coverageRatioBps);
        address flr = _firstLossReserveOf[hub][asset];
        funded = flr == address(0) ? 0 : IAvanaFirstLossReserve(flr).fundedBalance();
    }

    function _setWidth(
        SpokeKind kind,
        Width memory width
    ) internal {
        _checkWidth(width);
        _widths[kind] = width;
        emit SpokeWidthSet(kind, width.below, width.above);
    }

    function _checkWidth(
        Width memory width
    ) internal pure {
        if (width.below == 0 || width.above == 0 || width.below > _MAX_WIDTH || width.above > _MAX_WIDTH) {
            revert InvalidWidth(width.below, width.above);
        }
    }

    function _listed(
        uint256 marketId
    ) internal view returns (Market storage m) {
        m = _markets[marketId];
        if (m.pool == bytes32(0)) revert MarketNotListed(marketId);
    }

    function _inside(
        Market storage m,
        int24 tickLower,
        int24 tickUpper
    ) internal view returns (bool) {
        return m.pool != bytes32(0) && m.bandLower <= tickLower && tickLower < tickUpper && tickUpper <= m.bandUpper;
    }

    /// @dev Index of `a` in `list`, or `type(uint256).max`.
    function _indexOf(
        address[] storage list,
        address a
    ) internal view returns (uint256) {
        for (uint256 i = 0; i < list.length; ++i) {
            if (list[i] == a) return i;
        }
        return type(uint256).max;
    }
}
