// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IFlashLiquidator} from "./IFlashLiquidator.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {TransientSlot} from "@openzeppelin/contracts/utils/TransientSlot.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IAaveV3ACLManager} from "avana/dependencies/aave/IAaveV3ACLManager.sol";
import {IAaveV3FlashLoanReceiver} from "avana/dependencies/aave/IAaveV3FlashLoanReceiver.sol";
import {IAaveV3Pool} from "avana/dependencies/aave/IAaveV3Pool.sol";
import {IAaveV3PoolAddressesProvider} from "avana/dependencies/aave/IAaveV3PoolAddressesProvider.sol";
import {IAaveV4Spoke} from "avana/dependencies/aave/IAaveV4Spoke.sol";
import {ILiquidationModule} from "avana/liquidation/interfaces/ILiquidationModule.sol";
import {SwapCalls} from "avana/periphery/libraries/SwapCalls.sol";
import {IRiskModule} from "avana/risk/interfaces/IRiskModule.sol";
import {ILPVault} from "avana/vault/interfaces/ILPVault.sol";

/// @title FlashLiquidator
/// @notice Flash loan, liquidation in kind, sale of the pool tokens, repayment, profit to the bot.
/// @dev Not upgradeable, no admin. Holds tokens only inside `flashLiquidate` and sends what is left to the recipient.
contract FlashLiquidator is IFlashLiquidator, IAaveV3FlashLoanReceiver {
    using SafeERC20 for IERC20;
    using TransientSlot for *;

    /// @inheritdoc IFlashLiquidator
    address public immutable override POOL;
    /// @inheritdoc IFlashLiquidator
    address public immutable override LIQUIDATION_MODULE;
    /// @inheritdoc IFlashLiquidator
    address public immutable override RISK_MODULE;
    /// @inheritdoc IFlashLiquidator
    address public immutable override LP_VAULT;
    /// @inheritdoc IFlashLiquidator
    address public immutable override OPERATOR;

    /// @dev Transient hash of the open loan's request (`keccak256("avana.flashliquidator.context")`; the next two slots follow it).
    bytes32 private constant CONTEXT_SLOT = 0x968b1f2ee55a8bb84b957ed334786776b74022b9dd7500b6860f590307485e1c;
    /// @dev Transient debt repaid and top-up of the open loan, for the event.
    bytes32 private constant REPAID_SLOT = 0x968b1f2ee55a8bb84b957ed334786776b74022b9dd7500b6860f590307485e1d;
    bytes32 private constant TOP_UP_SLOT = 0x968b1f2ee55a8bb84b957ed334786776b74022b9dd7500b6860f590307485e1e;

    /// @dev Reads the RiskModule and the LPVault from the module. Reverts `InvalidAddress` for a zero address.
    constructor(
        address pool,
        address liquidationModule,
        address operator
    ) {
        if (pool == address(0)) revert InvalidAddress(pool);
        if (liquidationModule == address(0)) revert InvalidAddress(liquidationModule);
        if (operator == address(0)) revert InvalidAddress(operator);
        POOL = pool;
        LIQUIDATION_MODULE = liquidationModule;
        OPERATOR = operator;
        RISK_MODULE = ILiquidationModule(liquidationModule).RISK_MODULE();
        LP_VAULT = ILiquidationModule(liquidationModule).LP_VAULT();
    }

    /// @inheritdoc IFlashLiquidator
    function flashLiquidate(
        Request calldata request
    ) external override returns (uint256 profit) {
        if (msg.sender != OPERATOR) revert NotOperator(msg.sender);
        if (request.flashAmount == 0) revert InvalidAmount();
        address asset = _debtAsset(request.params.marketId, request.params.debtReserveId);
        bytes memory data = abi.encode(request);
        CONTEXT_SLOT.asBytes32().tstore(keccak256(data));
        REPAID_SLOT.asUint256().tstore(0);
        TOP_UP_SLOT.asUint256().tstore(0);

        uint256 premium = flashPremium(request.flashAmount);
        address[] memory assets = new address[](1);
        assets[0] = asset;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = request.flashAmount;
        IAaveV3Pool(POOL).flashLoan(address(this), assets, amounts, new uint256[](1), address(this), data, 0);
        if (CONTEXT_SLOT.asBytes32().tload() != bytes32(0)) revert InvalidFlashCallback();

        address to = request.recipient == address(0) ? OPERATOR : request.recipient;
        profit = IERC20(asset).balanceOf(address(this));
        if (profit < request.minProfit) revert ProfitTooLow(profit, request.minProfit);
        ILPVault.Market memory m = ILPVault(LP_VAULT).getMarket(request.params.marketId);
        _sweep(asset, to);
        if (m.token0 != asset) _sweep(m.token0, to);
        if (m.token1 != asset) _sweep(m.token1, to);
        // The operator's own call; the event reports what the loan did once it is closed.
        // forge-lint: disable-start(reentrancy-events)
        emit FlashLiquidated(
            request.params.account,
            request.params.marketId,
            asset,
            request.flashAmount,
            premium,
            REPAID_SLOT.asUint256().tload(),
            TOP_UP_SLOT.asUint256().tload(),
            profit
        );
        // forge-lint: disable-end(reentrancy-events)
    }

    /// @inheritdoc IAaveV3FlashLoanReceiver
    /// @dev Liquidates, sells, tops up from the operator if the sale falls short, and approves the Pool.
    function executeOperation(
        address[] calldata assets,
        uint256[] calldata amounts,
        uint256[] calldata premiums,
        address initiator,
        bytes calldata params
    ) external override returns (bool) {
        if (
            msg.sender != POOL || initiator != address(this) || assets.length != 1
                || CONTEXT_SLOT.asBytes32().tload() != keccak256(params)
        ) revert InvalidFlashCallback();
        CONTEXT_SLOT.asBytes32().tstore(bytes32(0));
        Request memory request = abi.decode(params, (Request));
        IERC20 asset = IERC20(assets[0]);

        ILiquidationModule.LiquidationParams memory p = request.params;
        p.debtToCover = amounts[0];
        p.receiver = address(this);
        asset.forceApprove(LIQUIDATION_MODULE, amounts[0]);
        ILiquidationModule.LiquidationResult memory r = ILiquidationModule(LIQUIDATION_MODULE).liquidate(p);
        asset.forceApprove(LIQUIDATION_MODULE, 0);
        REPAID_SLOT.asUint256().tstore(r.debtRepaid);

        address[] memory forbidden = new address[](2);
        (forbidden[0], forbidden[1]) = (LIQUIDATION_MODULE, POOL);
        SwapCalls.run(request.swaps, forbidden);

        uint256 owed = amounts[0] + premiums[0];
        uint256 balance = asset.balanceOf(address(this));
        if (balance < owed) {
            uint256 topUp = owed - balance;
            if (topUp > request.maxTopUp) revert TopUpExceeded(topUp, request.maxTopUp);
            TOP_UP_SLOT.asUint256().tstore(topUp);
            // The operator approves this contract for top-ups; only the operator can start a loan.
            // forge-lint: disable-next-line(arbitrary-send-erc20)
            asset.safeTransferFrom(OPERATOR, address(this), topUp);
        }
        asset.forceApprove(POOL, owed);
        return true;
    }

    /// @inheritdoc IFlashLiquidator
    function flashPremium(
        uint256 amount
    ) public view override returns (uint256) {
        if (isFlashBorrower()) return 0;
        return Math.mulDiv(amount, IAaveV3Pool(POOL).FLASHLOAN_PREMIUM_TOTAL(), 10_000, Math.Rounding.Ceil);
    }

    /// @inheritdoc IFlashLiquidator
    function isFlashBorrower() public view override returns (bool) {
        address acl = IAaveV3PoolAddressesProvider(IAaveV3Pool(POOL).ADDRESSES_PROVIDER()).getACLManager();
        return IAaveV3ACLManager(acl).isFlashBorrower(address(this));
    }

    /// @dev The underlying of a debt reserve of the market's Spoke.
    function _debtAsset(
        uint256 marketId,
        uint256 debtReserveId
    ) internal view returns (address) {
        address spoke = IRiskModule(RISK_MODULE).getMarket(marketId).spoke;
        return IAaveV4Spoke(spoke).getReserve(debtReserveId).underlying;
    }

    /// @dev Sends this contract's whole balance of `token` to `to`.
    function _sweep(
        address token,
        address to
    ) internal {
        uint256 amount = IERC20(token).balanceOf(address(this));
        if (amount != 0) IERC20(token).safeTransfer(to, amount);
    }
}
