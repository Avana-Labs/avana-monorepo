// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ILPVault} from "../../custody/lp-vault/ILPVault.sol";
import {IAaveV3FlashLoanReceiver} from "../../interfaces/external/aave/IAaveV3FlashLoanReceiver.sol";
import {IAaveV3Pool} from "../../interfaces/external/aave/IAaveV3Pool.sol";
import {IAaveV4Spoke} from "../../interfaces/external/aave/IAaveV4Spoke.sol";
import {IAaveAdapter} from "../../policy/aave-adapter/IAaveAdapter.sol";
import {IWithdrawReceiver} from "../../policy/aave-adapter/IWithdrawReceiver.sol";
import {IRiskModule} from "../../policy/risk-module/IRiskModule.sol";
import {SwapCalls} from "../libraries/SwapCalls.sol";
import {IFlashloanRepay} from "./IFlashloanRepay.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {TransientSlot} from "@openzeppelin/contracts/utils/TransientSlot.sol";

/// @title FlashloanRepay
/// @notice Repays a wallet's debt with part of its pledged position, in one call the wallet opens through
/// `AaveAdapter.allowWithdraw`.
/// @dev Not upgradeable, no admin. Holds tokens only inside the call and sends what is left to the wallet; it takes no
/// recipient. Swaps may not target the adapter, the LPVault or the Pool.
contract FlashloanRepay is IFlashloanRepay, IWithdrawReceiver, IAaveV3FlashLoanReceiver {
    using SafeERC20 for IERC20;
    using TransientSlot for *;

    /// @inheritdoc IFlashloanRepay
    address public immutable override ADAPTER;
    /// @inheritdoc IFlashloanRepay
    address public immutable override POOL;
    /// @inheritdoc IFlashloanRepay
    address public immutable override LP_VAULT;
    /// @inheritdoc IFlashloanRepay
    address public immutable override RISK_MODULE;

    /// @dev Transient hash of the open loan's context (`keccak256("avana.flashloanrepay.context")`).
    bytes32 private constant CONTEXT_SLOT = 0xa6bd6a693a7e7640866e0db3ac7216400efefced20da5775447e772cfb692c15;

    /// @dev What the flash-loan callback needs, bound to the open loan by hash.
    struct Context {
        address wallet;
        bytes32 positionKey;
        uint256 marketId;
        uint256 amount;
        RepayParams params;
    }

    /// @dev Reads the RiskModule and the LPVault from the adapter. Reverts `InvalidAddress` for a zero address.
    constructor(
        address adapter,
        address pool
    ) {
        if (adapter == address(0)) revert InvalidAddress(adapter);
        if (pool == address(0)) revert InvalidAddress(pool);
        ADAPTER = adapter;
        POOL = pool;
        RISK_MODULE = IAaveAdapter(adapter).RISK_MODULE();
        LP_VAULT = IAaveAdapter(adapter).LP_VAULT();
    }

    /// @inheritdoc IWithdrawReceiver
    /// @dev Sizes the loan at the debt now (at most `params.amount`), takes it, and sends what is left to the wallet.
    function onWithdrawAllowed(
        address wallet,
        bytes32 positionKey,
        uint128, /* maxLiquidity: the adapter enforces it */
        bytes calldata data
    ) external override {
        if (msg.sender != ADAPTER) revert NotAdapter(msg.sender);
        Context memory c;
        c.wallet = wallet;
        c.positionKey = positionKey;
        c.params = abi.decode(data, (RepayParams));
        ILPVault.Position memory pos = ILPVault(LP_VAULT).getPosition(positionKey);
        c.marketId = pos.marketId;
        IAaveV4Spoke spoke = IAaveV4Spoke(IRiskModule(RISK_MODULE).getMarket(c.marketId).spoke);
        uint256 debt = spoke.getUserTotalDebt(c.params.reserveId, pos.account);
        if (debt == 0) revert NothingToRepay(pos.account, c.params.reserveId);
        c.amount = c.params.amount < debt ? c.params.amount : debt;
        address asset = spoke.getReserve(c.params.reserveId).underlying;

        bytes memory ctx = abi.encode(c);
        CONTEXT_SLOT.asBytes32().tstore(keccak256(ctx));
        address[] memory assets = new address[](1);
        assets[0] = asset;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = c.amount;
        IAaveV3Pool(POOL).flashLoan(address(this), assets, amounts, new uint256[](1), address(this), ctx, 0);
        if (CONTEXT_SLOT.asBytes32().tload() != bytes32(0)) revert InvalidFlashCallback();

        ILPVault.Market memory m = ILPVault(LP_VAULT).getMarket(c.marketId);
        _sweep(asset, wallet);
        if (m.token0 != asset) _sweep(m.token0, wallet);
        if (m.token1 != asset) _sweep(m.token1, wallet);
    }

    /// @inheritdoc IAaveV3FlashLoanReceiver
    /// @dev Repays the wallet's debt, withdraws, swaps, and approves the Pool for the loan and its premium.
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
        _repayAndSwap(abi.decode(params, (Context)), assets[0], amounts[0], premiums[0]);
        return true;
    }

    /// @dev Inside the loan: repays the wallet's debt, withdraws, swaps, and approves the Pool for `amount + premium`.
    function _repayAndSwap(
        Context memory c,
        address asset,
        uint256 amount,
        uint256 premium
    ) internal {
        IERC20(asset).forceApprove(ADAPTER, amount);
        uint256 repaid = IAaveAdapter(ADAPTER).repay(c.marketId, c.params.reserveId, amount, c.wallet);
        IERC20(asset).forceApprove(ADAPTER, 0);
        // The burned vault-token count is not needed: the tokens received are.
        // forge-lint: disable-next-line(unused-return)
        IAaveAdapter(ADAPTER)
            .withdraw(c.positionKey, c.params.liquidity, c.params.amount0Min, c.params.amount1Min, address(this));
        address[] memory forbidden = new address[](3);
        (forbidden[0], forbidden[1], forbidden[2]) = (ADAPTER, LP_VAULT, POOL);
        SwapCalls.run(c.params.swaps, forbidden);

        uint256 owed = amount + premium;
        uint256 balance = IERC20(asset).balanceOf(address(this));
        if (balance < owed) revert InsufficientProceeds(balance, owed);
        IERC20(asset).forceApprove(POOL, owed);
        emit RepaidWithCollateral(c.wallet, c.positionKey, asset, repaid, premium, c.params.liquidity);
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
