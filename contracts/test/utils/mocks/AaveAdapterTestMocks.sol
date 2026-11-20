// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAaveV4Spoke} from "../../../src/interfaces/external/aave/IAaveV4Spoke.sol";
import {IRiskModule} from "../../../src/policy/risk-module/IRiskModule.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice The RiskModule calls the AaveAdapter makes, with the RiskModule's routing rule over set markets.
contract AdapterTestRiskModule {
    address public immutable LP_VAULT;
    mapping(uint256 marketId => IRiskModule.Market market) internal _markets;
    mapping(bytes32 pool => IRiskModule.PoolMarkets markets) internal _pools;
    bool public borrowBlocked;

    constructor(
        address lpVault
    ) {
        LP_VAULT = lpVault;
    }

    function setMarket(
        uint256 marketId,
        IRiskModule.Market memory m
    ) external {
        _markets[marketId] = m;
        if (m.kind == IRiskModule.MarketKind.FullRange) _pools[m.pool].fullRange = marketId;
        else _pools[m.pool].customRange = marketId;
    }

    function setBorrowBlocked(
        bool blocked
    ) external {
        borrowBlocked = blocked;
    }

    function getMarket(
        uint256 marketId
    ) external view returns (IRiskModule.Market memory) {
        return _markets[marketId];
    }

    /// @dev The same rule as `RiskModule.routeOf`.
    function routeOf(
        bytes32 pool,
        int24 tickLower,
        int24 tickUpper
    ) external view returns (uint256) {
        IRiskModule.PoolMarkets memory pm = _pools[pool];
        if (pm.fullRange == 0) return 0;
        IRiskModule.Market memory f = _markets[pm.fullRange];
        if (tickLower == f.bandLower && tickUpper == f.bandUpper) return pm.fullRange;
        IRiskModule.Market memory c = _markets[pm.customRange];
        if (c.pool != bytes32(0) && tickLower >= c.bandLower && tickUpper <= c.bandUpper && tickLower < tickUpper) {
            return pm.customRange;
        }
        return 0;
    }

    function checkBorrow(
        address spoke,
        uint256 reserveId
    ) external view {
        if (borrowBlocked) revert IRiskModule.NoActiveKeeper();
        spoke;
        reserveId;
    }
}

/// @notice Holds a Spoke's assets and pays out on its order.
contract AdapterTestHub {
    address public spoke;

    function setSpoke(
        address s
    ) external {
        spoke = s;
    }

    function pay(
        address token,
        address to,
        uint256 amount
    ) external {
        require(msg.sender == spoke, "only spoke");
        IERC20(token).transfer(to, amount);
    }
}

/// @notice A small Aave V4 Spoke: position managers, supply, withdraw, borrow, repay, and a health check where each
/// collateral base unit is worth `collateralPrice` debt base units at `cfBps`.
contract AdapterTestSpoke {
    error Unauthorized();
    error HealthFactorBelowOne();
    error SupplyCapExceeded();

    AdapterTestHub public immutable HUB;
    mapping(uint256 reserveId => address underlying) public underlyingOf;
    mapping(uint256 reserveId => uint256 price) public collateralPrice;
    mapping(uint256 reserveId => uint256 cf) public cfBps;
    mapping(address manager => mapping(address user => bool approved)) public approval;
    mapping(address manager => bool active) public managerActive;
    mapping(address user => mapping(uint256 reserveId => uint256 amount)) public supplied;
    mapping(address user => mapping(uint256 reserveId => uint256 amount)) public debt;
    mapping(address user => mapping(uint256 reserveId => bool on)) public usingAsCollateral;
    mapping(address user => uint256[] reserveIds) internal _collaterals;
    uint256[] internal _debtReserves;
    uint256 public supplyCap = type(uint256).max;
    /// @dev Units lost on each supply, like share rounding.
    uint256 public supplyHaircut;

    constructor(
        AdapterTestHub hub
    ) {
        HUB = hub;
    }

    function setReserve(
        uint256 reserveId,
        address underlying,
        uint256 price,
        uint256 cf
    ) external {
        underlyingOf[reserveId] = underlying;
        collateralPrice[reserveId] = price;
        cfBps[reserveId] = cf;
        if (price == 0) _debtReserves.push(reserveId);
    }

    function setManagerActive(
        address manager,
        bool active
    ) external {
        managerActive[manager] = active;
    }

    function setSupplyCap(
        uint256 cap
    ) external {
        supplyCap = cap;
    }

    function setSupplyHaircut(
        uint256 haircut
    ) external {
        supplyHaircut = haircut;
    }

    function setPrice(
        uint256 reserveId,
        uint256 price
    ) external {
        collateralPrice[reserveId] = price;
    }

    function setUserPositionManager(
        address positionManager,
        bool approve
    ) external {
        approval[positionManager][msg.sender] = approve;
    }

    function supply(
        uint256 reserveId,
        uint256 amount,
        address onBehalfOf
    ) external returns (uint256, uint256) {
        _onlyManager(onBehalfOf);
        if (supplied[onBehalfOf][reserveId] + amount > supplyCap) revert SupplyCapExceeded();
        IERC20(underlyingOf[reserveId]).transferFrom(msg.sender, address(HUB), amount);
        uint256 credited = amount > supplyHaircut ? amount - supplyHaircut : 0;
        supplied[onBehalfOf][reserveId] += credited;
        return (credited, amount);
    }

    function withdraw(
        uint256 reserveId,
        uint256 amount,
        address onBehalfOf
    ) external returns (uint256, uint256) {
        _onlyManager(onBehalfOf);
        uint256 s = supplied[onBehalfOf][reserveId];
        if (amount > s) amount = s;
        supplied[onBehalfOf][reserveId] = s - amount;
        HUB.pay(underlyingOf[reserveId], msg.sender, amount);
        _checkHealth(onBehalfOf);
        return (amount, amount);
    }

    function borrow(
        uint256 reserveId,
        uint256 amount,
        address onBehalfOf
    ) external returns (uint256, uint256) {
        _onlyManager(onBehalfOf);
        debt[onBehalfOf][reserveId] += amount;
        HUB.pay(underlyingOf[reserveId], msg.sender, amount);
        _checkHealth(onBehalfOf);
        return (amount, amount);
    }

    function repay(
        uint256 reserveId,
        uint256 amount,
        address onBehalfOf
    ) external returns (uint256, uint256) {
        _onlyManager(onBehalfOf);
        uint256 d = debt[onBehalfOf][reserveId];
        if (amount > d) amount = d;
        IERC20(underlyingOf[reserveId]).transferFrom(msg.sender, address(HUB), amount);
        debt[onBehalfOf][reserveId] = d - amount;
        return (amount, amount);
    }

    function setUsingAsCollateral(
        uint256 reserveId,
        bool on,
        address onBehalfOf
    ) external {
        _onlyManager(onBehalfOf);
        if (usingAsCollateral[onBehalfOf][reserveId] == on) return;
        usingAsCollateral[onBehalfOf][reserveId] = on;
        if (on) _collaterals[onBehalfOf].push(reserveId);
    }

    function getReserve(
        uint256 reserveId
    ) external view returns (IAaveV4Spoke.Reserve memory r) {
        r.underlying = underlyingOf[reserveId];
        r.hub = address(HUB);
    }

    function getUserSuppliedAssets(
        uint256 reserveId,
        address user
    ) external view returns (uint256) {
        return supplied[user][reserveId];
    }

    function getUserTotalDebt(
        uint256 reserveId,
        address user
    ) external view returns (uint256) {
        return debt[user][reserveId];
    }

    /// @notice The health factor (18 decimals): borrowing power over debt; the largest value with no debt.
    function getUserAccountData(
        address user
    ) external view returns (IAaveV4Spoke.UserAccountData memory d) {
        (uint256 power, uint256 owed) = headroom(user);
        d.healthFactor = owed == 0 ? type(uint256).max : power * 1e18 / owed;
    }

    /// @notice Borrowing power left, in debt base units.
    function headroom(
        address user
    ) public view returns (uint256 power, uint256 owed) {
        uint256[] memory c = _collaterals[user];
        for (uint256 i; i < c.length; ++i) {
            if (!usingAsCollateral[user][c[i]]) continue;
            power += supplied[user][c[i]] * collateralPrice[c[i]] * cfBps[c[i]] / 10_000;
        }
        for (uint256 i; i < _debtReserves.length; ++i) {
            owed += debt[user][_debtReserves[i]];
        }
    }

    function _checkHealth(
        address user
    ) internal view {
        (uint256 power, uint256 owed) = headroom(user);
        if (owed > power) revert HealthFactorBelowOne();
    }

    function _onlyManager(
        address user
    ) internal view {
        if (user != msg.sender && !(managerActive[msg.sender] && approval[msg.sender][user])) revert Unauthorized();
    }
}
