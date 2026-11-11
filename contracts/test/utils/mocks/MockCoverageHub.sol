// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title MockCoverageHub
/// @notice One-asset model of the Aave V4 Hub (a3ef63e) for the symbolic and fuzzing harnesses, which cannot load the
/// pinned Hub from `out-aave/`: added shares with the 1e6 virtual offset, `add` rounding shares down, `remove` and
/// `eliminateDeficit` rounding them up, Spoke deficits in RAY counted in total added assets, and the Hub's checks
/// (`active`, `halted`, zero amounts, liquidity, the caller's `uint120`-style share subtraction).
/// @dev Total added assets `A = liquidity + drawn + ceil(deficitRayTotal / RAY)`; `drawAndReport` moves liquidity to a
/// recorded deficit of a Spoke without changing `A`, as `draw` followed by `reportDeficit` does. Every state-changing
/// Spoke call records its asset ID, so a harness can check that no call names another asset. Unit tests use the real
/// Hub through `AaveV4Fixture`.
contract MockCoverageHub {
    using SafeERC20 for IERC20;

    error InvalidAmount();
    error InvalidShares();
    error InvalidAddress();
    error SpokeNotActive();
    error SpokeHalted();
    error InsufficientLiquidity(uint256 liquidity);
    error InsufficientTransferred(uint256 liquidityNeeded);
    error AssetNotListed();
    error Underflow();

    uint256 internal constant VIRTUAL = 1e6;
    uint256 internal constant RAY = 1e27;

    address public immutable UNDERLYING;
    uint8 public immutable DECIMALS;
    uint256 public immutable ASSET_ID;

    uint256 public liquidity;
    uint256 public drawn;
    uint256 public addedShares;
    uint256 public deficitRayTotal;
    mapping(address spoke => uint256 shares) public spokeShares;
    mapping(address spoke => uint256 ray) public spokeDeficitRay;
    mapping(address spoke => bool listed) public listed;
    mapping(address spoke => bool active) public active;
    mapping(address spoke => bool halted) public halted;
    /// @dev Every Spoke ever listed, in listing order, as the Hub's per-asset Spoke set enumerates them.
    address[] internal _spokeList;

    uint256 public eliminateCalls;
    uint256 public lastEliminateAmount;
    address public lastEliminateSpoke;
    uint256 public addCalls;
    uint256 public removeCalls;
    bool public otherAssetTouched;

    constructor(
        address underlying,
        uint8 decimals_,
        uint256 assetId
    ) {
        UNDERLYING = underlying;
        DECIMALS = decimals_;
        ASSET_ID = assetId;
    }

    // ─── Test controls ───

    function setSpoke(
        address spoke,
        bool isListed,
        bool isActive,
        bool isHalted
    ) external {
        if (isListed && !listed[spoke]) _spokeList.push(spoke);
        listed[spoke] = isListed;
        active[spoke] = isActive;
        halted[spoke] = isHalted;
    }

    /// @notice Lends `amount` of liquidity to `spoke` and reports it all as a deficit (A is unchanged).
    function drawAndReport(
        address spoke,
        uint256 amount
    ) external {
        if (amount > liquidity) revert InsufficientLiquidity(liquidity);
        liquidity -= amount;
        spokeDeficitRay[spoke] += amount * RAY;
        deficitRayTotal += amount * RAY;
    }

    /// @notice Sets a Spoke's recorded deficit directly (any RAY value), adjusting the asset total with it.
    function setDeficitRay(
        address spoke,
        uint256 ray
    ) external {
        deficitRayTotal = deficitRayTotal - spokeDeficitRay[spoke] + ray;
        spokeDeficitRay[spoke] = ray;
    }

    /// @notice Adds `amount` of interest to the drawn total (supply yield for every share).
    function accrue(
        uint256 amount
    ) external {
        drawn += amount;
    }

    // ─── Hub Spoke functions ───

    function add(
        uint256 assetId,
        uint256 amount
    ) external returns (uint256 shares) {
        _touch(assetId);
        if (amount == 0) revert InvalidAmount();
        if (!active[msg.sender]) revert SpokeNotActive();
        if (halted[msg.sender]) revert SpokeHalted();
        uint256 needed = liquidity + amount;
        uint256 balance = IERC20(UNDERLYING).balanceOf(address(this));
        if (balance < needed) revert InsufficientTransferred(needed - balance);
        shares = Math.mulDiv(amount, addedShares + VIRTUAL, totalAddedAssets() + VIRTUAL);
        if (shares == 0) revert InvalidShares();
        addedShares += shares;
        spokeShares[msg.sender] += shares;
        liquidity = needed;
        ++addCalls;
    }

    function remove(
        uint256 assetId,
        uint256 amount,
        address to
    ) external returns (uint256 shares) {
        _touch(assetId);
        if (to == address(this)) revert InvalidAddress();
        if (amount == 0) revert InvalidAmount();
        if (!active[msg.sender]) revert SpokeNotActive();
        if (halted[msg.sender]) revert SpokeHalted();
        if (amount > liquidity) revert InsufficientLiquidity(liquidity);
        shares = Math.mulDiv(amount, addedShares + VIRTUAL, totalAddedAssets() + VIRTUAL, Math.Rounding.Ceil);
        _burn(msg.sender, shares);
        liquidity -= amount;
        ++removeCalls;
        IERC20(UNDERLYING).safeTransfer(to, amount);
    }

    function eliminateDeficit(
        uint256 assetId,
        uint256 amount,
        address spoke
    ) external returns (uint256 shares, uint256 eliminated) {
        _touch(assetId);
        uint256 deficitRay = spokeDeficitRay[spoke];
        uint256 dRay = amount < Math.ceilDiv(deficitRay, RAY) ? amount * RAY : deficitRay;
        if (!active[msg.sender]) revert SpokeNotActive();
        if (dRay == 0) revert InvalidAmount();
        eliminated = Math.ceilDiv(dRay, RAY);
        shares = Math.mulDiv(eliminated, addedShares + VIRTUAL, totalAddedAssets() + VIRTUAL, Math.Rounding.Ceil);
        _burn(msg.sender, shares);
        deficitRayTotal -= dRay;
        spokeDeficitRay[spoke] = deficitRay - dRay;
        ++eliminateCalls;
        lastEliminateAmount = amount;
        lastEliminateSpoke = spoke;
    }

    // ─── Hub views ───

    function totalAddedAssets() public view returns (uint256) {
        return liquidity + drawn + Math.ceilDiv(deficitRayTotal, RAY);
    }

    function getAssetUnderlyingAndDecimals(
        uint256 assetId
    ) external view returns (address, uint8) {
        if (assetId != ASSET_ID) return (address(0), 0);
        return (UNDERLYING, DECIMALS);
    }

    function getSpokeAddedAssets(
        uint256 assetId,
        address spoke
    ) external view returns (uint256) {
        if (assetId != ASSET_ID) return 0;
        return Math.mulDiv(spokeShares[spoke], totalAddedAssets() + VIRTUAL, addedShares + VIRTUAL);
    }

    function getSpokeAddedShares(
        uint256 assetId,
        address spoke
    ) external view returns (uint256) {
        if (assetId != ASSET_ID) return 0;
        return spokeShares[spoke];
    }

    function getSpokeDeficitRay(
        uint256 assetId,
        address spoke
    ) external view returns (uint256) {
        if (assetId != ASSET_ID) return 0;
        return spokeDeficitRay[spoke];
    }

    function getSpokeCount(
        uint256 assetId
    ) external view returns (uint256) {
        return assetId == ASSET_ID ? _spokeList.length : 0;
    }

    function getSpokeAddress(
        uint256 assetId,
        uint256 index
    ) external view returns (address) {
        if (assetId != ASSET_ID) revert AssetNotListed();
        return _spokeList[index];
    }

    function isSpokeListed(
        uint256 assetId,
        address spoke
    ) external view returns (bool) {
        return assetId == ASSET_ID && listed[spoke];
    }

    // ─── Internal ───

    function _touch(
        uint256 assetId
    ) internal {
        if (assetId != ASSET_ID) {
            otherAssetTouched = true;
            revert AssetNotListed();
        }
    }

    function _burn(
        address spoke,
        uint256 shares
    ) internal {
        uint256 held = spokeShares[spoke];
        if (shares > held) revert Underflow();
        spokeShares[spoke] = held - shares;
        addedShares -= shares;
    }
}
