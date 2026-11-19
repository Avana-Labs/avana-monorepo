// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// The calls the bot makes, written from the Solidity interfaces in ../contracts/src and ../src (the generated ABIs in
// packages/protocol still name the replaced contracts until the services step).

import { parseAbi } from "viem";

export const adapterAbi = parseAbi(["event AccountCreated(address indexed wallet, uint256 indexed marketId, address account)"]);

export const riskModuleAbi = parseAbi([
  "function getMarket(uint256 marketId) view returns ((bytes32 pool, address spoke, address vaultToken, address lpOracle, uint256 reserveId, bytes32 feedsHash, int24 bandLower, int24 bandUpper, uint16 ltvBps, uint8 unitDecimals, uint8 kind, bool active))",
]);

export const spokeAbi = parseAbi([
  "function getUserAccountData(address user) view returns ((uint256 riskPremium, uint256 avgCollateralFactor, uint256 healthFactor, uint256 totalCollateralValue, uint256 totalDebtValueRay, uint256 activeCollateralCount, uint256 borrowCount))",
  "function getUserTotalDebt(uint256 reserveId, address user) view returns (uint256)",
  "function getReserve(uint256 reserveId) view returns ((address underlying, address hub, uint16 assetId, uint8 decimals, uint24 collateralRisk, uint8 flags, uint32 dynamicConfigKey))",
]);

export const lpVaultAbi = parseAbi([
  "function getMarket(uint256 marketId) view returns ((bytes32 pool, address token0, address token1, int24 bandLower, int24 bandUpper, uint128 totalCredit))",
]);

const params =
  "(uint256 marketId, uint256 debtReserveId, address account, uint256 debtToCover, uint256 minAmount0, uint256 minAmount1, address receiver)";
const result =
  "(uint256 debtRepaid, uint256 seized, uint256 feeUnits, uint256 creditUnwound, uint256 amount0, uint256 amount1, uint256 fee0, uint256 fee1)";

export const liquidationModuleAbi = parseAbi([
  `function liquidate(${params} p) returns (${result} r)`,
  "function RISK_MODULE() view returns (address)",
  "function LP_VAULT() view returns (address)",
]);

export const flashLiquidatorAbi = parseAbi([
  `function flashLiquidate((${params} params, uint256 flashAmount, (address tokenIn, address target, bytes data, uint256 amountInOffset)[] swaps, uint256 maxTopUp, uint256 minProfit, address recipient) request) returns (uint256 profit)`,
  "function isFlashBorrower() view returns (bool)",
  "function flashPremium(uint256 amount) view returns (uint256)",
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
