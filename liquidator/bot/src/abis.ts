// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// The calls the bot makes: Avana's from the ABIs generated in packages/protocol (the core contracts and the
// FlashLiquidator), the Aave V4 Spoke views, ERC-20 and SwapRouter02 as minimal fragments.

import { parseAbi } from "viem";

export { aaveAdapterAbi as adapterAbi, flashLiquidatorAbi, liquidationModuleAbi, lpVaultAbi, riskModuleAbi } from "@avana/protocol/abis";

export const spokeAbi = parseAbi([
  "function getUserAccountData(address user) view returns ((uint256 riskPremium, uint256 avgCollateralFactor, uint256 healthFactor, uint256 totalCollateralValue, uint256 totalDebtValueRay, uint256 activeCollateralCount, uint256 borrowCount))",
  "function getUserTotalDebt(uint256 reserveId, address user) view returns (uint256)",
  "function getReserve(uint256 reserveId) view returns ((address underlying, address hub, uint16 assetId, uint8 decimals, uint24 collateralRisk, uint8 flags, uint32 dynamicConfigKey))",
]);

export const erc20Abi = parseAbi([
  "function balanceOf(address) view returns (uint256)",
  "function allowance(address owner, address spender) view returns (uint256)",
  "function approve(address spender, uint256 amount) returns (bool)",
]);

/** Uniswap SwapRouter02 `exactInputSingle` (no deadline field). */
export const swapRouter02Abi = parseAbi([
  "function exactInputSingle((address tokenIn, address tokenOut, uint24 fee, address recipient, uint256 amountIn, uint256 amountOutMinimum, uint160 sqrtPriceLimitX96) params) payable returns (uint256 amountOut)",
]);
