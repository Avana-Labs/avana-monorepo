/* eslint-disable */
/**
 * Generated `api` utility.
 *
 * THIS CODE IS AUTOMATICALLY GENERATED.
 *
 * To regenerate, run `npx convex dev`.
 * @module
 */

import type * as allocation from "../allocation.js";
import type * as askAI from "../askAI.js";
import type * as askAIAgent from "../askAIAgent.js";
import type * as askAIAgentTools from "../askAIAgentTools.js";
import type * as askAIIngestion from "../askAIIngestion.js";
import type * as askAIRag from "../askAIRag.js";
import type * as askAITelemetry from "../askAITelemetry.js";
import type * as askAITools from "../askAITools.js";
import type * as askAiModeRun from "../askAiModeRun.js";
import type * as askAiRuns from "../askAiRuns.js";
import type * as borrow_assets from "../borrow/assets.js";
import type * as borrow_cashflow from "../borrow/cashflow.js";
import type * as borrow_content from "../borrow/content.js";
import type * as borrow_dailyStats from "../borrow/dailyStats.js";
import type * as borrow_dexes from "../borrow/dexes.js";
import type * as borrow_interestRateModel from "../borrow/interestRateModel.js";
import type * as borrow_liquidationRisk from "../borrow/liquidationRisk.js";
import type * as borrow_markets from "../borrow/markets.js";
import type * as borrow_poolBorrowables from "../borrow/poolBorrowables.js";
import type * as borrow_riskAssessment from "../borrow/riskAssessment.js";
import type * as borrow_riskParameters from "../borrow/riskParameters.js";
import type * as borrow_spokes from "../borrow/spokes.js";
import type * as cashflowHelpers from "../cashflowHelpers.js";
import type * as codedError from "../codedError.js";
import type * as contractAddresses from "../contractAddresses.js";
import type * as crons from "../crons.js";
import type * as detailHydration from "../detailHydration.js";
import type * as fx from "../fx.js";
import type * as legacyMarketCoverage from "../legacyMarketCoverage.js";
import type * as lend_cashflow from "../lend/cashflow.js";
import type * as lend_content from "../lend/content.js";
import type * as lend_dailyStats from "../lend/dailyStats.js";
import type * as lend_interestRateModel from "../lend/interestRateModel.js";
import type * as lend_markets from "../lend/markets.js";
import type * as lend_riskAssessment from "../lend/riskAssessment.js";
import type * as lend_riskParameters from "../lend/riskParameters.js";
import type * as liquidity from "../liquidity.js";
import type * as markets from "../markets.js";
import type * as multiply_allocation from "../multiply/allocation.js";
import type * as multiply_cashflow from "../multiply/cashflow.js";
import type * as multiply_content from "../multiply/content.js";
import type * as multiply_dailyStats from "../multiply/dailyStats.js";
import type * as multiply_interestRateModel from "../multiply/interestRateModel.js";
import type * as multiply_liquidationRisk from "../multiply/liquidationRisk.js";
import type * as multiply_markets from "../multiply/markets.js";
import type * as multiply_riskAssessment from "../multiply/riskAssessment.js";
import type * as multiply_riskParameters from "../multiply/riskParameters.js";
import type * as multiply_tokenParameters from "../multiply/tokenParameters.js";
import type * as parameterChanges from "../parameterChanges.js";
import type * as prices from "../prices.js";
import type * as rateLimits from "../rateLimits.js";
import type * as sandbox_auth from "../sandbox/auth.js";
import type * as sandbox_collateralUsd from "../sandbox/collateralUsd.js";
import type * as sandbox_dev from "../sandbox/dev.js";
import type * as sandbox_liquidation from "../sandbox/liquidation.js";
import type * as sandbox_migrations from "../sandbox/migrations.js";
import type * as sandbox_onboarding from "../sandbox/onboarding.js";
import type * as sandbox_oraclePrice from "../sandbox/oraclePrice.js";
import type * as sandbox_rewards from "../sandbox/rewards.js";
import type * as sandbox_rewards_catalog from "../sandbox/rewards_catalog.js";
import type * as sandbox_starterAllocation from "../sandbox/starterAllocation.js";
import type * as sandbox_swap from "../sandbox/swap.js";
import type * as sandbox_swapQuoteEngine from "../sandbox/swapQuoteEngine.js";
import type * as sandbox_transactionInvariants from "../sandbox/transactionInvariants.js";
import type * as sandbox_transactions from "../sandbox/transactions.js";
import type * as sandbox_umbrella from "../sandbox/umbrella.js";
import type * as sandbox_writeBackPrice from "../sandbox/writeBackPrice.js";
import type * as seed from "../seed.js";
import type * as seedAdmin from "../seedAdmin.js";
import type * as silo_cashflow from "../silo/cashflow.js";
import type * as silo_content from "../silo/content.js";
import type * as silo_dailyStats from "../silo/dailyStats.js";
import type * as silo_interestRateModel from "../silo/interestRateModel.js";
import type * as silo_kindField from "../silo/kindField.js";
import type * as silo_liquidationRisk from "../silo/liquidationRisk.js";
import type * as silo_markets from "../silo/markets.js";
import type * as silo_riskAssessment from "../silo/riskAssessment.js";
import type * as silo_riskParameters from "../silo/riskParameters.js";
import type * as starterTestMarkets from "../starterTestMarkets.js";
import type * as support from "../support.js";
import type * as usageReport from "../usageReport.js";
import type * as wallet_balances from "../wallet/balances.js";
import type * as wallet_claimPositions from "../wallet/claimPositions.js";
import type * as wallet_collateralPositions from "../wallet/collateralPositions.js";
import type * as wallet_debts from "../wallet/debts.js";
import type * as wallet_feeApyWads from "../wallet/feeApyWads.js";
import type * as wallet_lpTokenPrices from "../wallet/lpTokenPrices.js";
import type * as wallet_productBalances from "../wallet/productBalances.js";
import type * as wallet_profiles from "../wallet/profiles.js";
import type * as wallet_sessions from "../wallet/sessions.js";
import type * as writeRateLimit from "../writeRateLimit.js";

import type {
  ApiFromModules,
  FilterApi,
  FunctionReference,
} from "convex/server";

declare const fullApi: ApiFromModules<{
  allocation: typeof allocation;
  askAI: typeof askAI;
  askAIAgent: typeof askAIAgent;
  askAIAgentTools: typeof askAIAgentTools;
  askAIIngestion: typeof askAIIngestion;
  askAIRag: typeof askAIRag;
  askAITelemetry: typeof askAITelemetry;
  askAITools: typeof askAITools;
  askAiModeRun: typeof askAiModeRun;
  askAiRuns: typeof askAiRuns;
  "borrow/assets": typeof borrow_assets;
  "borrow/cashflow": typeof borrow_cashflow;
  "borrow/content": typeof borrow_content;
  "borrow/dailyStats": typeof borrow_dailyStats;
  "borrow/dexes": typeof borrow_dexes;
  "borrow/interestRateModel": typeof borrow_interestRateModel;
  "borrow/liquidationRisk": typeof borrow_liquidationRisk;
  "borrow/markets": typeof borrow_markets;
  "borrow/poolBorrowables": typeof borrow_poolBorrowables;
  "borrow/riskAssessment": typeof borrow_riskAssessment;
  "borrow/riskParameters": typeof borrow_riskParameters;
  "borrow/spokes": typeof borrow_spokes;
  cashflowHelpers: typeof cashflowHelpers;
  codedError: typeof codedError;
  contractAddresses: typeof contractAddresses;
  crons: typeof crons;
  detailHydration: typeof detailHydration;
  fx: typeof fx;
  legacyMarketCoverage: typeof legacyMarketCoverage;
  "lend/cashflow": typeof lend_cashflow;
  "lend/content": typeof lend_content;
  "lend/dailyStats": typeof lend_dailyStats;
  "lend/interestRateModel": typeof lend_interestRateModel;
  "lend/markets": typeof lend_markets;
  "lend/riskAssessment": typeof lend_riskAssessment;
  "lend/riskParameters": typeof lend_riskParameters;
  liquidity: typeof liquidity;
  markets: typeof markets;
  "multiply/allocation": typeof multiply_allocation;
  "multiply/cashflow": typeof multiply_cashflow;
  "multiply/content": typeof multiply_content;
  "multiply/dailyStats": typeof multiply_dailyStats;
  "multiply/interestRateModel": typeof multiply_interestRateModel;
  "multiply/liquidationRisk": typeof multiply_liquidationRisk;
  "multiply/markets": typeof multiply_markets;
  "multiply/riskAssessment": typeof multiply_riskAssessment;
  "multiply/riskParameters": typeof multiply_riskParameters;
  "multiply/tokenParameters": typeof multiply_tokenParameters;
  parameterChanges: typeof parameterChanges;
  prices: typeof prices;
  rateLimits: typeof rateLimits;
  "sandbox/auth": typeof sandbox_auth;
  "sandbox/collateralUsd": typeof sandbox_collateralUsd;
  "sandbox/dev": typeof sandbox_dev;
  "sandbox/liquidation": typeof sandbox_liquidation;
  "sandbox/migrations": typeof sandbox_migrations;
  "sandbox/onboarding": typeof sandbox_onboarding;
  "sandbox/oraclePrice": typeof sandbox_oraclePrice;
  "sandbox/rewards": typeof sandbox_rewards;
  "sandbox/rewards_catalog": typeof sandbox_rewards_catalog;
  "sandbox/starterAllocation": typeof sandbox_starterAllocation;
  "sandbox/swap": typeof sandbox_swap;
  "sandbox/swapQuoteEngine": typeof sandbox_swapQuoteEngine;
  "sandbox/transactionInvariants": typeof sandbox_transactionInvariants;
  "sandbox/transactions": typeof sandbox_transactions;
  "sandbox/umbrella": typeof sandbox_umbrella;
  "sandbox/writeBackPrice": typeof sandbox_writeBackPrice;
  seed: typeof seed;
  seedAdmin: typeof seedAdmin;
  "silo/cashflow": typeof silo_cashflow;
  "silo/content": typeof silo_content;
  "silo/dailyStats": typeof silo_dailyStats;
  "silo/interestRateModel": typeof silo_interestRateModel;
  "silo/kindField": typeof silo_kindField;
  "silo/liquidationRisk": typeof silo_liquidationRisk;
  "silo/markets": typeof silo_markets;
  "silo/riskAssessment": typeof silo_riskAssessment;
  "silo/riskParameters": typeof silo_riskParameters;
  starterTestMarkets: typeof starterTestMarkets;
  support: typeof support;
  usageReport: typeof usageReport;
  "wallet/balances": typeof wallet_balances;
  "wallet/claimPositions": typeof wallet_claimPositions;
  "wallet/collateralPositions": typeof wallet_collateralPositions;
  "wallet/debts": typeof wallet_debts;
  "wallet/feeApyWads": typeof wallet_feeApyWads;
  "wallet/lpTokenPrices": typeof wallet_lpTokenPrices;
  "wallet/productBalances": typeof wallet_productBalances;
  "wallet/profiles": typeof wallet_profiles;
  "wallet/sessions": typeof wallet_sessions;
  writeRateLimit: typeof writeRateLimit;
}>;

/**
 * A utility for referencing Convex functions in your app's public API.
 *
 * Usage:
 * ```js
 * const myFunctionReference = api.myModule.myFunction;
 * ```
 */
export declare const api: FilterApi<
  typeof fullApi,
  FunctionReference<any, "public">
>;

/**
 * A utility for referencing Convex functions in your app's internal API.
 *
 * Usage:
 * ```js
 * const myFunctionReference = internal.myModule.myFunction;
 * ```
 */
export declare const internal: FilterApi<
  typeof fullApi,
  FunctionReference<any, "internal">
>;

export declare const components: {
  agent: import("@convex-dev/agent/_generated/component.js").ComponentApi<"agent">;
  rag: import("@convex-dev/rag/_generated/component.js").ComponentApi<"rag">;
  rateLimiter: import("@convex-dev/rate-limiter/_generated/component.js").ComponentApi<"rateLimiter">;
};
