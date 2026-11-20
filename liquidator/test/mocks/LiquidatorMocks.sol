// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ILPVault} from "avana/vault/interfaces/ILPVault.sol";
import {IAaveV3FlashLoanReceiver} from "avana/dependencies/aave/IAaveV3FlashLoanReceiver.sol";
import {IAaveV4Spoke} from "avana/dependencies/aave/IAaveV4Spoke.sol";
import {ILiquidationModule} from "avana/liquidation/interfaces/ILiquidationModule.sol";
import {IRiskModule} from "avana/risk/interfaces/IRiskModule.sol";

contract TestToken is ERC20 {
    constructor(
        string memory symbol
    ) ERC20(symbol, symbol) {}

    function mint(
        address to,
        uint256 amount
    ) external {
        _mint(to, amount);
    }
}

/// @notice An Aave V3 Pool stand-in that is also its own addresses provider and ACL manager.
contract MockAaveV3Pool {
    error CallbackFailed();

    uint256 public premiumBps = 5;
    mapping(address borrower => bool) public isFlashBorrower;

    function setPremiumBps(
        uint256 bps
    ) external {
        premiumBps = bps;
    }

    function setFlashBorrower(
        address borrower,
        bool on
    ) external {
        isFlashBorrower[borrower] = on;
    }

    function FLASHLOAN_PREMIUM_TOTAL() external view returns (uint128) {
        return uint128(premiumBps);
    }

    function ADDRESSES_PROVIDER() external view returns (address) {
        return address(this);
    }

    function getACLManager() external view returns (address) {
        return address(this);
    }

    function flashLoan(
        address receiver,
        address[] calldata assets,
        uint256[] calldata amounts,
        uint256[] calldata,
        address,
        bytes calldata params,
        uint16
    ) external {
        uint256[] memory premiums = new uint256[](1);
        premiums[0] = isFlashBorrower[msg.sender] ? 0 : (amounts[0] * premiumBps + 9999) / 10_000;
        IERC20(assets[0]).transfer(receiver, amounts[0]);
        if (!IAaveV3FlashLoanReceiver(receiver).executeOperation(assets, amounts, premiums, msg.sender, params)) {
            revert CallbackFailed();
        }
        IERC20(assets[0]).transferFrom(receiver, address(this), amounts[0] + premiums[0]);
    }
}

/// @notice The RiskModule, Spoke and LPVault reads the liquidator makes, in one stand-in.
contract MockMarketReads {
    address public spoke;
    address public debtAsset;
    address public token0;
    address public token1;

    constructor(
        address debtAsset_,
        address token0_,
        address token1_
    ) {
        (spoke, debtAsset, token0, token1) = (address(this), debtAsset_, token0_, token1_);
    }

    function getMarket(
        uint256
    ) external view returns (IRiskModule.Market memory m) {
        m.spoke = spoke;
        m.active = true;
    }

    function getReserve(
        uint256
    ) external view returns (IAaveV4Spoke.Reserve memory r) {
        r.underlying = debtAsset;
    }
}

/// @notice An LPVault stand-in naming the market's pool tokens.
contract MockVaultMarkets {
    address public immutable TOKEN0;
    address public immutable TOKEN1;

    constructor(
        address token0,
        address token1
    ) {
        (TOKEN0, TOKEN1) = (token0, token1);
    }

    function getMarket(
        uint256
    ) external view returns (ILPVault.Market memory m) {
        m.token0 = TOKEN0;
        m.token1 = TOKEN1;
    }
}

/// @notice A LiquidationModule stand-in: takes up to `debtCap` of the offered debt and pays the receiver half its value
/// plus `bonusBps` in each pool token (each token worth one debt unit).
contract MockLiquidationModule {
    address public immutable RISK_MODULE;
    address public immutable LP_VAULT;
    TestToken public immutable DEBT;
    TestToken public immutable TOKEN0;
    TestToken public immutable TOKEN1;
    uint256 public debtCap = type(uint256).max;
    uint256 public bonusBps = 500;

    constructor(
        address riskModule,
        address lpVault,
        TestToken debt,
        TestToken token0,
        TestToken token1
    ) {
        (RISK_MODULE, LP_VAULT, DEBT, TOKEN0, TOKEN1) = (riskModule, lpVault, debt, token0, token1);
    }

    function set(
        uint256 cap,
        uint256 bonus
    ) external {
        (debtCap, bonusBps) = (cap, bonus);
    }

    function liquidate(
        ILiquidationModule.LiquidationParams calldata p
    ) external returns (ILiquidationModule.LiquidationResult memory r) {
        r.debtRepaid = p.debtToCover < debtCap ? p.debtToCover : debtCap;
        DEBT.transferFrom(msg.sender, address(this), r.debtRepaid);
        uint256 half = r.debtRepaid * (10_000 + bonusBps) / 20_000;
        (r.amount0, r.amount1) = (half, half);
        TOKEN0.mint(p.receiver, half);
        TOKEN1.mint(p.receiver, half);
    }
}

/// @notice A router stand-in: takes `amountIn` of `tokenIn` and mints `tokenOut` at `rateBps` of it.
contract MockRouter {
    function swap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 rateBps
    ) external returns (uint256 out) {
        IERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn);
        out = amountIn * rateBps / 10_000;
        TestToken(tokenOut).mint(msg.sender, out);
    }
}
